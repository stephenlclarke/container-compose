#!/usr/bin/env python3
# ===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------===#

"""Capture deterministic Docker Engine logging-driver behavior on Colima."""

from __future__ import annotations

import argparse
import base64
import difflib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any
from urllib.parse import quote, urlencode
import uuid


REQUIRED_CONTEXT = "colima"
REQUIRED_ENGINE_VERSION = "29.2.1"
REQUIRED_API_VERSION = "1.53"
REQUIRED_COMPOSE_VERSION = "5.3.1"
REQUIRED_IMAGE = "alpine:3.20"
REQUIRED_HOST_ARCHITECTURE = "arm64"
REQUIRED_HOST_MODEL = "Mac17,9"
REQUIRED_MACOS_VERSION = "26.5.2"
RFC3339_NANO_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"
)
UNSUPPORTED_READER_MESSAGE = "configured logging driver does not support reading"

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = (
    REPO_ROOT
    / "Tests/ComposeCoreTests/Fixtures/logging/docker-engine-29.2.1-logging.json"
)


class PrerequisiteUnavailable(RuntimeError):
    """Raised when the pinned local Docker oracle cannot run."""


class OracleFailure(RuntimeError):
    """Raised when Docker returns an unexpected response during capture."""


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP/1.1 connection over a Docker Unix-domain socket."""

    def __init__(self, socket_path: str, timeout: float = 30.0) -> None:
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        connection.connect(self.socket_path)
        self.sock = connection


class DockerEngine:
    """Small API 1.53 client used only by the logging oracle."""

    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path

    def request(
        self,
        method: str,
        endpoint: str,
        *,
        payload: dict[str, Any] | None = None,
        timeout: float = 30.0,
    ) -> tuple[int, str, bytes]:
        body = None
        headers: dict[str, str] = {}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
            headers = {
                "Content-Length": str(len(body)),
                "Content-Type": "application/json",
            }

        connection = UnixHTTPConnection(self.socket_path, timeout=timeout)
        try:
            connection.request(method, endpoint, body=body, headers=headers)
            response = connection.getresponse()
            content_type = response.getheader("Content-Type", "").split(";", 1)[0]
            return response.status, content_type, response.read()
        finally:
            connection.close()

    def request_json(
        self,
        method: str,
        endpoint: str,
        *,
        payload: dict[str, Any] | None = None,
        expected_status: int | None = None,
        timeout: float = 30.0,
    ) -> tuple[int, dict[str, Any]]:
        status, _, body = self.request(
            method,
            endpoint,
            payload=payload,
            timeout=timeout,
        )
        decoded = json.loads(body) if body else {}
        if expected_status is not None and status != expected_status:
            raise OracleFailure(
                f"{method} {endpoint} returned HTTP {status}, expected "
                f"{expected_status}: {decoded}"
            )
        return status, decoded


class LoggingOracle:
    """Runs isolated logging probes and removes every created container."""

    def __init__(self, engine: DockerEngine, image: str, prefix: str) -> None:
        self.engine = engine
        self.image = image
        self.prefix = prefix
        self.container_names: set[str] = set()

    def close(self) -> None:
        failures: list[str] = []
        for name in sorted(self.container_names):
            status, _, body = self.engine.request(
                "DELETE",
                f"/v{REQUIRED_API_VERSION}/containers/{quote(name, safe='')}?force=1&v=1",
            )
            if status not in (204, 404):
                failures.append(f"{name}: HTTP {status} {body!r}")
        for name in sorted(self.container_names):
            if self.exists(name):
                failures.append(f"{name}: container still exists")
        if failures:
            raise OracleFailure("Docker oracle cleanup failed: " + "; ".join(failures))

    def name(self, suffix: str) -> str:
        name = f"{self.prefix}-{suffix}"
        self.container_names.add(name)
        return name

    def create(
        self,
        suffix: str,
        *,
        command: list[str],
        log_config: dict[str, Any] | None = None,
        tty: bool = False,
        environment: list[str] | None = None,
        labels: dict[str, str] | None = None,
        expected_status: int = 201,
    ) -> tuple[str | None, dict[str, Any]]:
        name = self.name(suffix)
        request: dict[str, Any] = {
            "Cmd": command,
            "Image": self.image,
            "Tty": tty,
        }
        if environment is not None:
            request["Env"] = environment
        if labels is not None:
            request["Labels"] = labels
        if log_config is not None:
            request["HostConfig"] = {"LogConfig": log_config}

        status, response = self.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/create?name={quote(name, safe='')}",
            payload=request,
        )
        if status != expected_status:
            raise OracleFailure(
                f"container create for {suffix} returned HTTP {status}, "
                f"expected {expected_status}: {response}"
            )
        return response.get("Id"), {
            "httpStatus": status,
            "message": response.get("message"),
            "warnings": response.get("Warnings", []),
        }

    def inspect(self, identifier: str) -> dict[str, Any]:
        _, response = self.engine.request_json(
            "GET",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/json",
            expected_status=200,
        )
        return response

    def exists(self, identifier: str) -> bool:
        status, _, _ = self.engine.request(
            "GET",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/json",
        )
        return status == 200

    def start(self, identifier: str, expected_status: int = 204) -> dict[str, Any]:
        status, response = self.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/start",
        )
        if status != expected_status:
            raise OracleFailure(
                f"container start returned HTTP {status}, expected "
                f"{expected_status}: {response}"
            )
        return {"httpStatus": status, "message": response.get("message")}

    def wait(self, identifier: str, expected_exit: int = 0) -> dict[str, Any]:
        _, response = self.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/wait?condition=not-running",
            expected_status=200,
            timeout=60.0,
        )
        exit_code = response.get("StatusCode")
        if exit_code != expected_exit:
            raise OracleFailure(
                f"container {identifier} exited {exit_code}, expected {expected_exit}: {response}"
            )
        return {"exitCode": exit_code}

    def stop(self, identifier: str) -> int:
        status, _, body = self.engine.request(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/stop?t=0",
        )
        if status != 204:
            raise OracleFailure(f"container stop returned HTTP {status}: {body!r}")
        return status

    def restart(self, identifier: str) -> int:
        status, _, body = self.engine.request(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/restart?t=0",
            timeout=60.0,
        )
        if status != 204:
            raise OracleFailure(f"container restart returned HTTP {status}: {body!r}")
        return status

    def logs(
        self,
        identifier: str,
        *,
        tty: bool,
        stdout: bool = True,
        stderr: bool = True,
        follow: bool = False,
    ) -> dict[str, Any]:
        query = urlencode(
            {
                "details": "0",
                "follow": "1" if follow else "0",
                "stderr": "1" if stderr else "0",
                "stdout": "1" if stdout else "0",
                "tail": "all",
                "timestamps": "0",
            }
        )
        status, content_type, body = self.engine.request(
            "GET",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/logs?{query}",
            timeout=10.0,
        )
        result: dict[str, Any] = {
            "contentType": content_type,
            "httpStatus": status,
        }
        if status != 200:
            decoded = json.loads(body) if body else {}
            result["message"] = decoded.get("message")
            return result

        if tty:
            result.update(
                {
                    "bytes": body.decode("utf-8"),
                    "framing": "raw",
                }
            )
            return result

        observed_frames = parse_multiplexed_frames(body)
        stdout_bytes = "".join(
            frame["bytes"]
            for frame in observed_frames
            if frame["stream"] == "stdout"
        )
        stderr_bytes = "".join(
            frame["bytes"]
            for frame in observed_frames
            if frame["stream"] == "stderr"
        )
        frames = normalized_stream_frames(stdout_bytes, stderr_bytes)
        result.update(
            {
                "frames": frames,
                "framing": "docker-multiplexed-8-byte-header",
                "normalization": (
                    "preserve per-stream bytes; do not assert cross-stream order "
                    "or transport chunk boundaries"
                ),
                "stderr": stderr_bytes,
                "stdout": stdout_bytes,
            }
        )
        return result

    def wait_for_log_text(
        self,
        identifier: str,
        expected: str,
        *,
        timeout: float = 10.0,
    ) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            output = self.logs(identifier, tty=False)
            if output.get("httpStatus") == 200 and expected in output.get("stdout", ""):
                return
            time.sleep(0.05)
        raise OracleFailure(f"timed out waiting for log marker {expected!r}")

    def wait_for_container_path(
        self,
        identifier: str,
        path: str,
        *,
        timeout: float = 10.0,
    ) -> float:
        """Wait for a container path and return monotonic elapsed seconds."""

        started = time.monotonic()
        deadline = started + timeout
        query = urlencode({"path": path})
        while time.monotonic() < deadline:
            status, _, _ = self.engine.request(
                "GET",
                f"/v{REQUIRED_API_VERSION}/containers/"
                f"{quote(identifier, safe='')}/archive?{query}",
                timeout=2.0,
            )
            if status == 200:
                return time.monotonic() - started
            if status not in (400, 404):
                raise OracleFailure(
                    f"container archive probe returned HTTP {status} for {path!r}"
                )
            time.sleep(0.02)
        raise OracleFailure(f"timed out waiting for container path {path!r}")

    def create_start_probe(
        self,
        suffix: str,
        *,
        driver: str,
        options: dict[str, str],
    ) -> dict[str, Any]:
        """Capture create/start validation without assuming either phase."""

        name = self.name(suffix)
        status, response = self.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/create?name={quote(name, safe='')}",
            payload={
                "Cmd": ["true"],
                "HostConfig": {
                    "LogConfig": {
                        "Config": options,
                        "Type": driver,
                    }
                },
                "Image": self.image,
            },
        )
        result: dict[str, Any] = {
            "create": {
                "httpStatus": status,
                "message": response.get("message"),
                "warnings": response.get("Warnings", []),
            },
            "requestedLogConfig": {
                "Config": options,
                "Type": driver,
            },
        }
        identifier = response.get("Id")
        if status != 201 or identifier is None:
            result["containerResidue"] = self.exists(name)
            return result

        result["inspectAfterCreate"] = normalized_inspect(self.inspect(identifier))
        start_status, start_response = self.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(identifier, safe='')}/start",
        )
        result["start"] = {
            "httpStatus": start_status,
            "message": start_response.get("message"),
        }
        if start_status == 204:
            result["wait"] = self.wait(identifier)
        result["inspectAfterStart"] = normalized_inspect(self.inspect(identifier))
        return result


def parse_multiplexed_frames(body: bytes) -> list[dict[str, Any]]:
    """Decode Docker's eight-byte stdout/stderr frame headers."""

    frames: list[dict[str, Any]] = []
    offset = 0
    streams = {1: "stdout", 2: "stderr"}
    while offset < len(body):
        if len(body) - offset < 8:
            raise OracleFailure("truncated Docker multiplex header")
        stream_id = body[offset]
        if body[offset + 1 : offset + 4] != b"\x00\x00\x00":
            raise OracleFailure("non-zero Docker multiplex header padding")
        if stream_id not in streams:
            raise OracleFailure(f"unexpected Docker multiplex stream {stream_id}")
        size = int.from_bytes(body[offset + 4 : offset + 8], "big")
        offset += 8
        payload = body[offset : offset + size]
        if len(payload) != size:
            raise OracleFailure("truncated Docker multiplex payload")
        offset += size
        frames.append(
            {
                "bytes": payload.decode("utf-8"),
                "header": {
                    "padding": [0, 0, 0],
                    "payloadLength": size,
                    "streamID": stream_id,
                },
                "stream": streams[stream_id],
            }
        )
    return frames


def normalized_stream_frames(
    stdout_bytes: str, stderr_bytes: str
) -> list[dict[str, Any]]:
    """Represent framing deterministically without inventing cross-stream order."""

    frames: list[dict[str, Any]] = []
    for stream, stream_id, payload in (
        ("stdout", 1, stdout_bytes),
        ("stderr", 2, stderr_bytes),
    ):
        if not payload:
            continue
        frames.append(
            {
                "bytes": payload,
                "header": {
                    "padding": [0, 0, 0],
                    "payloadLength": len(payload.encode("utf-8")),
                    "streamID": stream_id,
                },
                "stream": stream,
            }
        )
    return frames


def normalized_inspect(inspect: dict[str, Any]) -> dict[str, Any]:
    identifier = inspect["Id"]
    log_path = inspect.get("LogPath", "")
    if log_path:
        log_path = log_path.replace(identifier, "<container-id>")
    return {
        "logConfig": inspect["HostConfig"]["LogConfig"],
        "logPath": log_path,
        "state": {
            "error": inspect["State"].get("Error", ""),
            "status": inspect["State"]["Status"],
        },
        "tty": inspect["Config"]["Tty"],
    }


def read_json_file_records(identifier: str, log_path: str) -> list[dict[str, Any]]:
    expected_prefix = f"/var/lib/docker/containers/{identifier}/"
    if not log_path.startswith(expected_prefix) or "\n" in log_path:
        raise OracleFailure(f"unexpected Docker json-file path: {log_path!r}")
    result = subprocess.run(
        ["colima", "ssh", "--", "sudo", "cat", "--", log_path],
        check=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
        timeout=30,
    )
    records: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        record = json.loads(line)
        timestamp = record.get("time", "")
        if not RFC3339_NANO_PATTERN.fullmatch(timestamp):
            raise OracleFailure(f"unexpected json-file timestamp: {timestamp!r}")
        normalized: dict[str, Any] = {
            "keys": list(record.keys()),
            "log": record["log"],
            "stream": record["stream"],
            "time": "<rfc3339-nano-utc>",
        }
        if "attrs" in record:
            normalized["attrs"] = record["attrs"]
        records.append(normalized)
    return sorted(records, key=lambda record: record["stream"])


def monotonic_timing(started: float) -> dict[str, Any]:
    """Return a machine-readable monotonic fixture duration."""

    return {
        "clock": "time.monotonic",
        "durationSeconds": round(time.monotonic() - started, 6),
    }


def numbered_record_command(
    *,
    count: int,
    digits: int,
    payload_bytes: int,
    completion_path: str | None = None,
    sleep_after: float | None = None,
) -> list[str]:
    """Build a deterministic Alpine command that emits numbered records."""

    suffix = ""
    if completion_path is not None:
        suffix += f"; printf complete >{completion_path}"
    if sleep_after is not None:
        suffix += f"; sleep {sleep_after}"
    payload = "x" * payload_bytes
    return [
        "sh",
        "-c",
        f"i=1; while [ $i -le {count} ]; do "
        f"printf 'record-%0{digits}d:{payload}\\n' $i; "
        f"i=$((i+1)); done{suffix}",
    ]


def parse_numbered_records(
    output: str,
    *,
    digits: int,
    payload_bytes: int,
) -> list[int]:
    """Validate deterministic numbered output and return its record numbers."""

    pattern = re.compile(rf"^record-(\d{{{digits}}}):(x{{{payload_bytes}}})$")
    records: list[int] = []
    for line in output.splitlines():
        match = pattern.fullmatch(line)
        if match is None:
            raise OracleFailure(f"unexpected numbered log record: {line[:80]!r}")
        records.append(int(match.group(1)))
    return records


def summarized_numbered_read(
    read: dict[str, Any],
    *,
    digits: int,
    payload_bytes: int,
) -> dict[str, Any]:
    """Summarize a large logs response without committing repeated payload bytes."""

    if read.get("httpStatus") != 200:
        raise OracleFailure(f"numbered logs read failed: {read}")
    records = parse_numbered_records(
        read.get("stdout", ""),
        digits=digits,
        payload_bytes=payload_bytes,
    )
    return {
        "firstRecord": records[0] if records else None,
        "httpStatus": read["httpStatus"],
        "lastRecord": records[-1] if records else None,
        "recordCount": len(records),
        "recordsAreContiguous": all(
            following == current + 1
            for current, following in zip(records, records[1:])
        ),
    }


def docker_container_root(identifier: str) -> str:
    """Return the validated daemon-side root for a Docker container."""

    if re.fullmatch(r"[0-9a-f]{64}", identifier) is None:
        raise OracleFailure(f"unexpected Docker container ID: {identifier!r}")
    return f"/var/lib/docker/containers/{identifier}"


def colima_file_bytes(path: str, *, compressed: bool) -> bytes:
    """Read one validated daemon-side logging file through Colima."""

    command = ["gzip", "-cd", "--", path] if compressed else ["cat", "--", path]
    result = subprocess.run(
        ["colima", "ssh", "--", "sudo", *command],
        check=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
        timeout=30,
    )
    return result.stdout


def capture_rotation_files(
    identifier: str,
    *,
    driver: str,
    configured_maximum: int,
) -> tuple[list[dict[str, Any]], dict[str, list[int]] | None, bool]:
    """Capture stable file names, compression, and JSON segment order."""

    root = docker_container_root(identifier)
    if driver == "json-file":
        relative_paths = [
            f"{identifier}-json.log",
            f"{identifier}-json.log.1.gz",
            f"{identifier}-json.log.2.gz",
        ]
        normalized_paths = [
            "<container-id>-json.log",
            "<container-id>-json.log.1.gz",
            "<container-id>-json.log.2.gz",
        ]
    elif driver == "local":
        relative_paths = [
            "local-logs/container.log",
            "local-logs/container.log.1.gz",
            "local-logs/container.log.2.gz",
        ]
        normalized_paths = relative_paths
    else:
        raise OracleFailure(f"unsupported rotation probe driver: {driver}")

    expected = set(relative_paths)
    deadline = time.monotonic() + 10.0
    observed: set[str] = set()
    while time.monotonic() < deadline:
        listing = subprocess.run(
            [
                "colima",
                "ssh",
                "--",
                "sudo",
                "find",
                root,
                "-maxdepth",
                "3",
                "-type",
                "f",
                "-printf",
                "%P\\n",
            ],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "LC_ALL": "C"},
            timeout=10,
        )
        observed = {
            line
            for line in listing.stdout.splitlines()
            if line.startswith(f"{identifier}-json.log")
            or line.startswith("local-logs/container.log")
        }
        if observed == expected:
            gzip_valid = all(
                subprocess.run(
                    [
                        "colima",
                        "ssh",
                        "--",
                        "sudo",
                        "gzip",
                        "-t",
                        "--",
                        f"{root}/{relative_path}",
                    ],
                    capture_output=True,
                    check=False,
                    timeout=10,
                ).returncode
                == 0
                for relative_path in relative_paths[1:]
            )
            if gzip_valid:
                break
        time.sleep(0.05)
    else:
        raise OracleFailure(
            f"timed out waiting for {driver} rotation files: {sorted(observed)}"
        )

    active_size = int(
        subprocess.run(
            [
                "colima",
                "ssh",
                "--",
                "sudo",
                "stat",
                "-c",
                "%s",
                "--",
                f"{root}/{relative_paths[0]}",
            ],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "LC_ALL": "C"},
            timeout=10,
        ).stdout.strip()
    )
    inventory: list[dict[str, Any]] = []
    for index, normalized_path in enumerate(normalized_paths):
        entry: dict[str, Any] = {
            "compression": "gzip" if index else "none",
            "path": normalized_path,
        }
        if index:
            entry["gzipStreamValid"] = True
        inventory.append(entry)

    segment_records: dict[str, list[int]] | None = None
    if driver == "json-file":
        segment_records = {}
        for index, relative_path in enumerate(relative_paths):
            content = colima_file_bytes(
                f"{root}/{relative_path}",
                compressed=index > 0,
            )
            records: list[int] = []
            for line in content.splitlines():
                record = json.loads(line)
                marker = parse_numbered_records(
                    record["log"],
                    digits=3,
                    payload_bytes=900,
                )
                if len(marker) != 1:
                    raise OracleFailure("json-file segment did not contain one record")
                records.append(marker[0])
            segment_records[["active", "rotated1", "rotated2"][index]] = records

    return inventory, segment_records, active_size > configured_maximum


def capture_rotation_case(
    oracle: LoggingOracle,
    *,
    driver: str,
) -> dict[str, Any]:
    """Capture sustained rotation and compression for one built-in driver."""

    identifier, create = oracle.create(
        f"{driver}-rotation",
        command=numbered_record_command(count=40, digits=3, payload_bytes=900),
        log_config={
            "Type": driver,
            "Config": {
                "compress": "true",
                "max-file": "3",
                "max-size": "4k",
            },
        },
    )
    assert identifier is not None
    oracle.start(identifier)
    oracle.wait(identifier)
    inventory, segments, active_exceeds_maximum = capture_rotation_files(
        identifier,
        driver=driver,
        configured_maximum=4000,
    )
    result: dict[str, Any] = {
        "activeFileExceedsConfiguredMaximum": active_exceeds_maximum,
        "configuredMaximumBytes": 4000,
        "create": create,
        "files": inventory,
        "inspectAfterExit": normalized_inspect(oracle.inspect(identifier)),
        "retainedRead": summarized_numbered_read(
            oracle.logs(identifier, tty=False),
            digits=3,
            payload_bytes=900,
        ),
    }
    if segments is not None:
        result["segmentRecords"] = segments
    return result


PRESSURE_SINK_SCRIPT = r"""
import json
import os
import re
import socket
import sys
import time

socket_path, result_path, pid_path, stall_text = sys.argv[1:]
for path in (socket_path, result_path, pid_path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
with open(pid_path, "w", encoding="ascii") as pid_file:
    pid_file.write(str(os.getpid()))
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
server.bind(socket_path)
server.listen(1)
connection, _ = server.accept()
time.sleep(float(stall_text))
received = bytearray()
while True:
    chunk = connection.recv(65536)
    if not chunk:
        break
    received.extend(chunk)
markers = [
    int(value)
    for value in re.findall(rb"record-(\d{5})", bytes(received))
]
with open(result_path, "w", encoding="utf-8") as result_file:
    json.dump({"markers": markers}, result_file, separators=(",", ":"))
connection.close()
server.close()
"""


def colima_path_exists(path: str, *, socket_path: bool = False) -> bool:
    """Check one exact Colima path without following shell interpolation."""

    predicate = "-S" if socket_path else "-e"
    return (
        subprocess.run(
            ["colima", "ssh", "--", "test", predicate, path],
            capture_output=True,
            check=False,
            timeout=10,
        ).returncode
        == 0
    )


def stop_pressure_sink(
    process: subprocess.Popen[str],
    *,
    socket_path: str,
    result_path: str,
    pid_path: str,
) -> None:
    """Stop one exact pressure sink and remove all of its VM-side state."""

    if process.poll() is None and colima_path_exists(pid_path):
        cleanup_script = (
            "import os,signal,sys; "
            "pid=int(open(sys.argv[1],encoding='ascii').read()); "
            "cmd=open(f'/proc/{pid}/cmdline','rb').read(); "
            "os.kill(pid,signal.SIGTERM) if sys.argv[2].encode() in cmd else None"
        )
        subprocess.run(
            [
                "colima",
                "ssh",
                "--",
                "python3",
                "-c",
                cleanup_script,
                pid_path,
                socket_path,
            ],
            capture_output=True,
            check=False,
            timeout=10,
        )
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    subprocess.run(
        [
            "colima",
            "ssh",
            "--",
            "rm",
            "-f",
            socket_path,
            result_path,
            pid_path,
        ],
        check=True,
        capture_output=True,
        timeout=10,
    )
    residue = [
        path
        for path in (socket_path, result_path, pid_path)
        if colima_path_exists(path)
    ]
    if residue:
        raise OracleFailure(f"pressure sink cleanup left state: {residue}")


def capture_nonblocking_pressure(
    oracle: LoggingOracle,
) -> dict[str, Any]:
    """Prove observable non-blocking drops with a locally controlled slow sink."""

    socket_path = f"/tmp/{oracle.prefix}-pressure.sock"
    result_path = f"/tmp/{oracle.prefix}-pressure.json"
    pid_path = f"/tmp/{oracle.prefix}-pressure.pid"
    stall_seconds = 2.0
    process = subprocess.Popen(
        [
            "colima",
            "ssh",
            "--",
            "python3",
            "-c",
            PRESSURE_SINK_SCRIPT,
            socket_path,
            result_path,
            pid_path,
            str(stall_seconds),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    try:
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if colima_path_exists(socket_path, socket_path=True):
                break
            if process.poll() is not None:
                _, stderr = process.communicate()
                raise OracleFailure(f"pressure sink exited before ready: {stderr}")
            time.sleep(0.05)
        else:
            raise OracleFailure("timed out waiting for pressure sink socket")

        source_count = 5000
        identifier, create = oracle.create(
            "nonblocking-pressure",
            command=numbered_record_command(
                count=source_count,
                digits=5,
                payload_bytes=900,
                completion_path="/oracle-write-complete",
                sleep_after=3.0,
            ),
            log_config={
                "Type": "syslog",
                "Config": {
                    "cache-disabled": "true",
                    "max-buffer-size": "4k",
                    "mode": "non-blocking",
                    "syslog-address": f"unix://{socket_path}",
                },
            },
        )
        assert identifier is not None
        oracle.start(identifier)
        write_completion_seconds = oracle.wait_for_container_path(
            identifier,
            "/oracle-write-complete",
        )
        oracle.wait(identifier)
        try:
            _, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired as error:
            raise OracleFailure("pressure sink did not terminate after container exit") from error
        if process.returncode != 0:
            raise OracleFailure(f"pressure sink failed: {stderr}")
        result = json.loads(
            subprocess.run(
                ["colima", "ssh", "--", "cat", result_path],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            ).stdout
        )
        markers = result.get("markers", [])
        if not markers or not all(isinstance(marker, int) for marker in markers):
            raise OracleFailure(f"pressure sink returned invalid markers: {result}")
        inspect = normalized_inspect(oracle.inspect(identifier))
        inspect["logConfig"]["Config"]["syslog-address"] = (
            "unix://<unique-colima-pressure-socket>"
        )
        return {
            "configuredBufferBytes": 4096,
            "create": create,
            "inspectAfterExit": inspect,
            "receiver": {
                "deliveredFewerThanSource": len(markers) < source_count,
                "dropGapObserved": any(
                    following != current + 1
                    for current, following in zip(markers, markers[1:])
                ),
                "firstRecord": markers[0],
                "recordsAreOrdered": markers == sorted(markers),
                "recordsAreUnique": len(markers) == len(set(markers)),
                "sourceFinalRecordWasDropped": source_count not in markers,
            },
            "receiverStallSeconds": stall_seconds,
            "sourceRecordCount": source_count,
            "workloadWriteCompletedBeforeReceiverRelease": (
                write_completion_seconds < stall_seconds
            ),
        }
    finally:
        stop_pressure_sink(
            process,
            socket_path=socket_path,
            result_path=result_path,
            pid_path=pid_path,
        )


REMOTE_LOG_RECEIVER_SCRIPT = r"""
import json
import os
import socket
import ssl
import struct
import sys


class IncompleteMessagePack(Exception):
    pass


def need(data, offset, count):
    if offset + count > len(data):
        raise IncompleteMessagePack()


def sized_node(kind, started, ended, **fields):
    return {"byteCount": ended - started, "type": kind, **fields}


def decode_string(data, offset, size, kind, started):
    need(data, offset, size)
    raw = bytes(data[offset : offset + size])
    ended = offset + size
    try:
        return sized_node(
            kind,
            started,
            ended,
            byteCountValue=size,
            utf8=raw.decode("utf-8"),
        ), ended
    except UnicodeDecodeError:
        return sized_node(
            kind,
            started,
            ended,
            byteCountValue=size,
            invalidUTF8Hex=raw.hex(),
        ), ended


def decode_messagepack(data, offset=0):
    started = offset
    need(data, offset, 1)
    prefix = data[offset]
    offset += 1

    if prefix <= 0x7f:
        return sized_node("positive-fixint", started, offset, value=prefix), offset
    if prefix >= 0xe0:
        return sized_node("negative-fixint", started, offset, value=prefix - 256), offset
    if 0xa0 <= prefix <= 0xbf:
        return decode_string(data, offset, prefix & 0x1f, "fixstr", started)
    if 0x90 <= prefix <= 0x9f:
        count = prefix & 0x0f
        items = []
        for _ in range(count):
            item, offset = decode_messagepack(data, offset)
            items.append(item)
        return sized_node("fixarray", started, offset, items=items), offset
    if 0x80 <= prefix <= 0x8f:
        count = prefix & 0x0f
        entries = []
        for _ in range(count):
            key, offset = decode_messagepack(data, offset)
            value, offset = decode_messagepack(data, offset)
            entries.append({"key": key, "value": value})
        return sized_node("fixmap", started, offset, entries=entries), offset

    if prefix == 0xc0:
        return sized_node("nil", started, offset, value=None), offset
    if prefix in (0xc2, 0xc3):
        return sized_node("bool", started, offset, value=prefix == 0xc3), offset

    binary_sizes = {0xc4: (1, "bin8"), 0xc5: (2, "bin16"), 0xc6: (4, "bin32")}
    if prefix in binary_sizes:
        width, kind = binary_sizes[prefix]
        need(data, offset, width)
        size = int.from_bytes(data[offset : offset + width], "big")
        offset += width
        need(data, offset, size)
        raw = bytes(data[offset : offset + size])
        offset += size
        return sized_node(
            kind, started, offset, byteCountValue=size, binaryHex=raw.hex()
        ), offset

    extension_sizes = {0xc7: (1, "ext8"), 0xc8: (2, "ext16"), 0xc9: (4, "ext32")}
    if prefix in extension_sizes:
        width, kind = extension_sizes[prefix]
        need(data, offset, width)
        size = int.from_bytes(data[offset : offset + width], "big")
        offset += width
        need(data, offset, size + 1)
        extension_type = data[offset]
        if extension_type >= 128:
            extension_type -= 256
        offset += 1
        raw = bytes(data[offset : offset + size])
        offset += size
        return sized_node(
            kind,
            started,
            offset,
            byteCountValue=size,
            extensionType=extension_type,
            extensionHex=raw.hex(),
        ), offset

    if prefix in (0xca, 0xcb):
        width, kind, fmt = (4, "float32", ">f") if prefix == 0xca else (8, "float64", ">d")
        need(data, offset, width)
        value = struct.unpack(fmt, bytes(data[offset : offset + width]))[0]
        offset += width
        return sized_node(kind, started, offset, value=value), offset

    integer_formats = {
        0xcc: (1, "uint8", ">B"),
        0xcd: (2, "uint16", ">H"),
        0xce: (4, "uint32", ">I"),
        0xcf: (8, "uint64", ">Q"),
        0xd0: (1, "int8", ">b"),
        0xd1: (2, "int16", ">h"),
        0xd2: (4, "int32", ">i"),
        0xd3: (8, "int64", ">q"),
    }
    if prefix in integer_formats:
        width, kind, fmt = integer_formats[prefix]
        need(data, offset, width)
        value = struct.unpack(fmt, bytes(data[offset : offset + width]))[0]
        offset += width
        return sized_node(kind, started, offset, value=value), offset

    fixed_extensions = {
        0xd4: (1, "fixext1"),
        0xd5: (2, "fixext2"),
        0xd6: (4, "fixext4"),
        0xd7: (8, "fixext8"),
        0xd8: (16, "fixext16"),
    }
    if prefix in fixed_extensions:
        size, kind = fixed_extensions[prefix]
        need(data, offset, size + 1)
        extension_type = data[offset]
        if extension_type >= 128:
            extension_type -= 256
        offset += 1
        raw = bytes(data[offset : offset + size])
        offset += size
        return sized_node(
            kind,
            started,
            offset,
            byteCountValue=size,
            extensionType=extension_type,
            extensionHex=raw.hex(),
        ), offset

    string_sizes = {0xd9: (1, "str8"), 0xda: (2, "str16"), 0xdb: (4, "str32")}
    if prefix in string_sizes:
        width, kind = string_sizes[prefix]
        need(data, offset, width)
        size = int.from_bytes(data[offset : offset + width], "big")
        offset += width
        return decode_string(data, offset, size, kind, started)

    collection_sizes = {
        0xdc: (2, "array16", "array"),
        0xdd: (4, "array32", "array"),
        0xde: (2, "map16", "map"),
        0xdf: (4, "map32", "map"),
    }
    if prefix in collection_sizes:
        width, kind, collection = collection_sizes[prefix]
        need(data, offset, width)
        count = int.from_bytes(data[offset : offset + width], "big")
        offset += width
        if collection == "array":
            items = []
            for _ in range(count):
                item, offset = decode_messagepack(data, offset)
                items.append(item)
            return sized_node(kind, started, offset, items=items), offset
        entries = []
        for _ in range(count):
            key, offset = decode_messagepack(data, offset)
            value, offset = decode_messagepack(data, offset)
            entries.append({"key": key, "value": value})
        return sized_node(kind, started, offset, entries=entries), offset

    raise ValueError(f"unsupported MessagePack prefix 0x{prefix:02x}")


def node_string_bytes(node):
    if "utf8" in node:
        return node["utf8"].encode("utf-8")
    if "invalidUTF8Hex" in node:
        return bytes.fromhex(node["invalidUTF8Hex"])
    if "binaryHex" in node:
        return bytes.fromhex(node["binaryHex"])
    return None


def map_value(node, wanted):
    for entry in node.get("entries", []):
        key = node_string_bytes(entry["key"])
        if key == wanted:
            return entry["value"]
    return None


def chunk_node(node):
    items = node.get("items", [])
    if not items:
        return None
    return map_value(items[-1], b"chunk")


def encode_string(raw):
    size = len(raw)
    if size < 32:
        return bytes([0xa0 | size]) + raw
    if size <= 0xff:
        return b"\xd9" + bytes([size]) + raw
    if size <= 0xffff:
        return b"\xda" + size.to_bytes(2, "big") + raw
    return b"\xdb" + size.to_bytes(4, "big") + raw


def encode_ack(chunk):
    raw = node_string_bytes(chunk)
    if raw is None:
        raise ValueError("Fluentd chunk identifier is not a string or binary value")
    if "binaryHex" in chunk:
        size = len(raw)
        if size <= 0xff:
            encoded = b"\xc4" + bytes([size]) + raw
        elif size <= 0xffff:
            encoded = b"\xc5" + size.to_bytes(2, "big") + raw
        else:
            encoded = b"\xc6" + size.to_bytes(4, "big") + raw
    else:
        encoded = encode_string(raw)
    return b"\x81\xa3ack" + encoded


(
    mode,
    ready_path,
    result_path,
    pid_path,
    socket_path,
    cert_path,
    key_path,
    expected_text,
) = sys.argv[1:]
expected = int(expected_text)
for path in (ready_path, result_path, pid_path, socket_path):
    if path == "-":
        continue
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
with open(pid_path, "w", encoding="ascii") as pid_file:
    pid_file.write(str(os.getpid()))

server = None
connection = None
try:
    if mode.endswith("-udp"):
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
    elif mode.endswith("-unix"):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        server.listen(1)
    else:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
    server.settimeout(20.0)

    ready = {"mode": mode}
    if mode.endswith("-unix"):
        ready["socketPath"] = socket_path
    else:
        ready["host"] = "127.0.0.1"
        ready["port"] = server.getsockname()[1]
    with open(ready_path, "w", encoding="utf-8") as ready_file:
        json.dump(ready, ready_file, separators=(",", ":"), sort_keys=True)

    if mode.endswith("-udp"):
        datagrams = []
        for _ in range(expected):
            datagram, _ = server.recvfrom(1024 * 1024)
            datagrams.append(datagram.hex())
        result = {
            "datagramsHex": datagrams,
            "mode": mode,
            "peerClosed": None,
        }
    else:
        connection, _ = server.accept()
        if mode.endswith("-tls"):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certfile=cert_path, keyfile=key_path)
            connection = context.wrap_socket(connection, server_side=True)
        connection.settimeout(20.0)
        received = bytearray()
        peer_closed = False
        if mode.startswith("syslog-"):
            while True:
                try:
                    chunk = connection.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    peer_closed = True
                    break
                received.extend(chunk)
            result = {
                "mode": mode,
                "peerClosed": peer_closed,
                "streamHex": bytes(received).hex(),
            }
        else:
            objects = []
            decoded_offset = 0
            acknowledgements = []
            while True:
                while len(objects) < expected:
                    try:
                        node, next_offset = decode_messagepack(received, decoded_offset)
                    except IncompleteMessagePack:
                        break
                    objects.append(node)
                    decoded_offset = next_offset
                    chunk = chunk_node(node)
                    if chunk is not None:
                        connection.sendall(encode_ack(chunk))
                        acknowledgements.append(chunk["type"])
                try:
                    chunk = connection.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    peer_closed = True
                    break
                received.extend(chunk)
            while len(objects) < expected:
                node, next_offset = decode_messagepack(received, decoded_offset)
                objects.append(node)
                decoded_offset = next_offset
                chunk = chunk_node(node)
                if chunk is not None:
                    connection.sendall(encode_ack(chunk))
                    acknowledgements.append(chunk["type"])
            if len(objects) != expected:
                raise ValueError(
                    f"received {len(objects)} Fluentd objects, expected {expected}"
                )
            result = {
                "acknowledgedChunkTypes": acknowledgements,
                "decodedByteCount": decoded_offset,
                "mode": mode,
                "objects": objects,
                "peerClosed": peer_closed,
                "rawByteCount": len(received),
                "trailingByteCount": len(received) - decoded_offset,
            }
    with open(result_path, "w", encoding="utf-8") as result_file:
        json.dump(result, result_file, separators=(",", ":"), sort_keys=True)
finally:
    if connection is not None:
        connection.close()
    if server is not None:
        server.close()
"""


def read_colima_json(path: str) -> dict[str, Any]:
    """Read one exact JSON result produced inside the Colima VM."""

    completed = subprocess.run(
        ["colima", "ssh", "--", "cat", path],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    result = json.loads(completed.stdout)
    if not isinstance(result, dict):
        raise OracleFailure(f"Colima receiver result is not an object: {result!r}")
    return result


def start_colima_log_receiver(
    oracle: LoggingOracle,
    *,
    label: str,
    mode: str,
    expected_messages: int,
) -> dict[str, Any]:
    """Start one bounded receiver with unique, exact VM-side state paths."""

    stem = f"/tmp/{oracle.prefix}-{label}"
    ready_path = f"{stem}.ready.json"
    result_path = f"{stem}.result.json"
    pid_path = f"{stem}.pid"
    socket_path = f"{stem}.sock" if mode.endswith("-unix") else "-"
    cert_path = f"{stem}.crt" if mode.endswith("-tls") else "-"
    key_path = f"{stem}.key" if mode.endswith("-tls") else "-"
    paths = [ready_path, result_path, pid_path]
    paths.extend(path for path in (socket_path, cert_path, key_path) if path != "-")
    subprocess.run(
        ["colima", "ssh", "--", "rm", "-f", *paths],
        check=True,
        capture_output=True,
        timeout=10,
    )
    process: subprocess.Popen[str] | None = None
    receiver: dict[str, Any] | None = None
    try:
        if mode.endswith("-tls"):
            subprocess.run(
                [
                    "colima",
                    "ssh",
                    "--",
                    "openssl",
                    "req",
                    "-x509",
                    "-nodes",
                    "-newkey",
                    "rsa:2048",
                    "-keyout",
                    key_path,
                    "-out",
                    cert_path,
                    "-days",
                    "1",
                    "-subj",
                    "/CN=127.0.0.1",
                    "-addext",
                    "subjectAltName=IP:127.0.0.1",
                ],
                check=True,
                capture_output=True,
                timeout=20,
            )

        process = subprocess.Popen(
            [
                "colima",
                "ssh",
                "--",
                "python3",
                "-u",
                "-c",
                REMOTE_LOG_RECEIVER_SCRIPT,
                mode,
                ready_path,
                result_path,
                pid_path,
                socket_path,
                cert_path,
                key_path,
                str(expected_messages),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "LC_ALL": "C"},
        )
        receiver = {
            "certPath": cert_path,
            "keyPath": key_path,
            "paths": paths,
            "pidPath": pid_path,
            "process": process,
            "readyPath": ready_path,
            "resultPath": result_path,
            "socketPath": socket_path,
        }
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if colima_path_exists(ready_path):
                try:
                    receiver["ready"] = read_colima_json(ready_path)
                except (json.JSONDecodeError, subprocess.CalledProcessError):
                    time.sleep(0.05)
                    continue
                return receiver
            if process.poll() is not None:
                _, stderr = process.communicate()
                raise OracleFailure(f"{mode} receiver exited before ready: {stderr}")
            time.sleep(0.05)
        raise OracleFailure(f"timed out waiting for {mode} receiver")
    except BaseException:
        if receiver is not None:
            cleanup_colima_log_receiver(receiver)
        else:
            subprocess.run(
                ["colima", "ssh", "--", "rm", "-f", *paths],
                check=False,
                capture_output=True,
                timeout=10,
            )
        raise


def finish_colima_log_receiver(receiver: dict[str, Any]) -> dict[str, Any]:
    """Wait for one bounded receiver and return its exact result."""

    process: subprocess.Popen[str] = receiver["process"]
    try:
        _, stderr = process.communicate(timeout=25)
    except subprocess.TimeoutExpired as error:
        raise OracleFailure("remote logging receiver did not terminate") from error
    if process.returncode != 0:
        raise OracleFailure(f"remote logging receiver failed: {stderr}")
    if not colima_path_exists(receiver["resultPath"]):
        raise OracleFailure("remote logging receiver did not write a result")
    return read_colima_json(receiver["resultPath"])


def cleanup_colima_log_receiver(receiver: dict[str, Any]) -> dict[str, Any]:
    """Stop one exact receiver, remove its paths, and prove zero VM residue."""

    process: subprocess.Popen[str] = receiver["process"]
    pid_path: str = receiver["pidPath"]
    if process.poll() is None and colima_path_exists(pid_path):
        cleanup_script = (
            "import os,signal,sys; "
            "pid=int(open(sys.argv[1],encoding='ascii').read()); "
            "cmd=open(f'/proc/{pid}/cmdline','rb').read(); "
            "os.kill(pid,signal.SIGTERM) if sys.argv[2].encode() in cmd else None"
        )
        subprocess.run(
            [
                "colima",
                "ssh",
                "--",
                "python3",
                "-c",
                cleanup_script,
                pid_path,
                receiver["readyPath"],
            ],
            capture_output=True,
            check=False,
            timeout=10,
        )
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    subprocess.run(
        ["colima", "ssh", "--", "rm", "-f", *receiver["paths"]],
        check=True,
        capture_output=True,
        timeout=10,
    )
    residue = [
        path for path in receiver["paths"] if colima_path_exists(path)
    ]
    if residue:
        raise OracleFailure(f"remote logging receiver cleanup left state: {residue}")
    return {
        "receiverProcessRunning": False,
        "vmPathsRemaining": [],
    }


REMOTE_LOG_COMMAND = [
    "sh",
    "-c",
    "printf 'stdout-ascii\\n'; sleep 0.2; "
    "printf 'stderr-utf8-\\342\\230\\203\\n' >&2; sleep 0.2; "
    "printf 'stdout-binary-\\377\\000-end\\n'",
]
REMOTE_LOG_MARKERS = (
    b"stdout-ascii",
    "stderr-utf8-☃".encode(),
    b"stdout-binary-\xff\x00-end",
)
SYSLOG_MESSAGE_PATTERN = re.compile(
    rb"^<(\d+)>1 (\S+) (\S+) (\S+) (\d+) (\S+) - (.*)$",
    re.DOTALL,
)


def receiver_address(receiver: dict[str, Any], scheme: str) -> str:
    """Build a Docker logging address from one ready receiver."""

    ready = receiver["ready"]
    if scheme in ("unix", "unixgram"):
        return f"{scheme}://{ready['socketPath']}"
    return f"{scheme}://{ready['host']}:{ready['port']}"


def parse_syslog_frames(mode: str, raw: dict[str, Any]) -> tuple[list[bytes], dict[str, Any]]:
    """Split syslog transport bytes without preserving read chunk boundaries."""

    if mode == "syslog-udp":
        frames = [bytes.fromhex(value) for value in raw["datagramsHex"]]
        return frames, {
            "datagramBoundariesAreMessageBoundaries": True,
            "framing": "one RFC 5424 message per UDP datagram; no delimiter",
        }

    stream = bytes.fromhex(raw["streamHex"])
    if mode == "syslog-tls":
        frames: list[bytes] = []
        prefixes: list[int] = []
        offset = 0
        while offset < len(stream):
            separator = stream.find(b" ", offset)
            if separator < 0:
                raise OracleFailure("TLS syslog stream has no octet-count separator")
            prefix = stream[offset:separator]
            if not prefix.isdigit():
                raise OracleFailure(f"invalid TLS syslog octet count: {prefix!r}")
            size = int(prefix)
            started = separator + 1
            ended = started + size
            if ended > len(stream):
                raise OracleFailure("TLS syslog octet count exceeds stream length")
            frames.append(stream[started:ended])
            prefixes.append(size)
            offset = ended
        return frames, {
            "framing": "RFC 6587 octet counting",
            "octetCounts": prefixes,
            "trailingByteCount": len(stream) - offset,
        }

    if stream and not stream.endswith(b"\n"):
        raise OracleFailure(f"{mode} syslog stream is not LF terminated")
    frames = stream[:-1].split(b"\n") if stream else []
    return frames, {
        "framing": "RFC 6587 non-transparent LF delimiter",
        "streamEndsWithLF": stream.endswith(b"\n"),
    }


def normalize_syslog_wire(
    raw: dict[str, Any],
    *,
    mode: str,
    container_id: str,
    container_name: str,
) -> dict[str, Any]:
    """Normalize only volatile syslog fields while retaining exact bytes."""

    frames, framing = parse_syslog_frames(mode, raw)
    normalized_frames: list[dict[str, Any]] = []
    for frame in frames:
        match = SYSLOG_MESSAGE_PATTERN.match(frame)
        if match is None:
            raise OracleFailure(f"invalid RFC 5424 syslog payload: {frame!r}")
        priority = int(match.group(1))
        timestamp = match.group(2).decode("ascii")
        if re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|[+-]\d{2}:\d{2})",
            timestamp,
        ) is None:
            raise OracleFailure(f"invalid RFC 5424 microsecond timestamp: {timestamp}")
        hostname, tag, pid, message_id, content = match.group(3, 4, 5, 6, 7)
        dynamic_replacements = (
            (container_id.encode(), b"<container-id>"),
            (container_id[:12].encode(), b"<container-id-short>"),
            (container_name.lstrip("/").encode(), b"<container-name>"),
        )

        def normalized(value: bytes) -> bytes:
            for actual, replacement in dynamic_replacements:
                value = value.replace(actual, replacement)
            return value

        normalized_hostname = normalized(hostname)
        normalized_tag = normalized(tag)
        normalized_message_id = normalized(message_id)
        normalized_message = (
            f"<{priority}>1 <rfc3339-micro-utc> ".encode()
            + normalized_hostname
            + b" "
            + normalized_tag
            + b" <daemon-pid> "
            + normalized_message_id
            + b" - "
            + content
        )
        try:
            content_utf8: str | None = content.decode("utf-8")
        except UnicodeDecodeError:
            content_utf8 = None
        normalized_frames.append(
            {
                "appName": normalized_tag.decode("ascii"),
                "contentBase64": base64.b64encode(content).decode("ascii"),
                "contentHex": content.hex(),
                "contentUTF8": content_utf8,
                "facility": priority >> 3,
                "hostname": normalized_hostname.decode("ascii"),
                "messageID": normalized_message_id.decode("ascii"),
                "normalizedMessageByteCount": len(normalized_message),
                "normalizedMessageHex": normalized_message.hex(),
                "priority": priority,
                "processID": "<daemon-pid>",
                "severity": priority & 7,
                "structuredData": "-",
                "timestamp": "<rfc3339-micro-utc>",
                "timestampFractionDigits": 6,
                "version": 1,
            }
        )
    observed_content = [
        bytes.fromhex(frame["contentHex"]).removesuffix(b"\n")
        for frame in normalized_frames
    ]
    if observed_content != list(REMOTE_LOG_MARKERS):
        raise OracleFailure(
            f"syslog receiver observed unexpected content order: {observed_content!r}"
        )
    if mode == "syslog-tls":
        original_counts = framing.pop("octetCounts")
        framing["octetCountsMatchPayloadByteCounts"] = original_counts == [
            len(frame) for frame in frames
        ]
        framing["normalizedOctetCounts"] = [
            frame["normalizedMessageByteCount"] for frame in normalized_frames
        ]
    return {
        "frames": normalized_frames,
        "framing": framing,
        "peerClosedAfterContainerExit": raw["peerClosed"],
        "readChunkBoundariesNormalizedAway": True,
    }


def capture_syslog_wire_transport(
    oracle: LoggingOracle,
    *,
    label: str,
    mode: str,
    scheme: str,
) -> dict[str, Any]:
    """Capture one exact Docker syslog wire transport inside Colima."""

    receiver = start_colima_log_receiver(
        oracle,
        label=label,
        mode=mode,
        expected_messages=len(REMOTE_LOG_MARKERS),
    )
    result: dict[str, Any] | None = None
    try:
        address = receiver_address(receiver, scheme)
        options = {
            "cache-disabled": "true",
            "syslog-address": address,
            "syslog-facility": "local1",
            "syslog-format": "rfc5424micro",
            "tag": "oracle-{{.Name}}-{{.ID}}",
        }
        if mode == "syslog-tls":
            options["syslog-tls-ca-cert"] = receiver["certPath"]
        identifier, create = oracle.create(
            f"syslog-wire-{label}",
            command=REMOTE_LOG_COMMAND,
            log_config={"Type": "syslog", "Config": options},
        )
        assert identifier is not None
        inspect_before = oracle.inspect(identifier)
        start = oracle.start(identifier)
        wait = oracle.wait(identifier)
        raw = finish_colima_log_receiver(receiver)
        inspect = normalized_inspect(oracle.inspect(identifier))
        inspect_options = inspect["logConfig"]["Config"]
        inspect_options["syslog-address"] = f"{scheme}://<colima-oracle-receiver>"
        if "syslog-tls-ca-cert" in inspect_options:
            inspect_options["syslog-tls-ca-cert"] = "<unique-colima-ca-cert>"
        result = {
            "create": create,
            "inspectAfterExit": inspect,
            "phase": {
                "configurationAcceptedAtCreate": create["httpStatus"] == 201,
                "connectionEstablishedAtStart": start["httpStatus"] == 204,
                "containerExitCode": wait["exitCode"],
            },
            "requestedTransport": scheme,
            "wire": normalize_syslog_wire(
                raw,
                mode=mode,
                container_id=identifier,
                container_name=inspect_before["Name"],
            ),
        }
    finally:
        cleanup = cleanup_colima_log_receiver(receiver)
    assert result is not None
    result["cleanup"] = cleanup
    return result


def node_utf8(node: dict[str, Any]) -> str | None:
    value = node.get("utf8")
    return value if isinstance(value, str) else None


def messagepack_map_value(node: dict[str, Any], key: str) -> dict[str, Any] | None:
    for entry in node.get("entries", []):
        if node_utf8(entry["key"]) == key:
            return entry["value"]
    return None


def normalize_messagepack_node(
    node: dict[str, Any],
    *,
    replacements: tuple[tuple[str, str], ...],
) -> dict[str, Any]:
    """Normalize dynamic strings and map order while retaining wire scalar types."""

    normalized = dict(node)
    value = normalized.get("utf8")
    if isinstance(value, str):
        for actual, replacement in replacements:
            value = value.replace(actual, replacement)
        normalized["utf8"] = value
    if "items" in normalized:
        normalized["items"] = [
            normalize_messagepack_node(item, replacements=replacements)
            for item in normalized["items"]
        ]
    if "entries" in normalized:
        entries = [
            {
                "key": normalize_messagepack_node(
                    entry["key"], replacements=replacements
                ),
                "value": normalize_messagepack_node(
                    entry["value"], replacements=replacements
                ),
            }
            for entry in normalized["entries"]
        ]
        entries.sort(
            key=lambda entry: json.dumps(
                entry["key"], separators=(",", ":"), sort_keys=True
            )
        )
        normalized["entries"] = entries
    return normalized


def recompute_normalized_messagepack_byte_counts(node: dict[str, Any]) -> int:
    """Recompute canonical sizes after volatile scalar values are normalized."""

    kind = node["type"]
    if "items" in node:
        header = 1 if kind == "fixarray" else 3 if kind == "array16" else 5
        node["byteCount"] = header + sum(
            recompute_normalized_messagepack_byte_counts(item)
            for item in node["items"]
        )
        return node["byteCount"]
    if "entries" in node:
        header = 1 if kind == "fixmap" else 3 if kind == "map16" else 5
        node["byteCount"] = header + sum(
            recompute_normalized_messagepack_byte_counts(entry["key"])
            + recompute_normalized_messagepack_byte_counts(entry["value"])
            for entry in node["entries"]
        )
        return node["byteCount"]
    if "utf8" in node:
        size = len(node["utf8"].encode("utf-8"))
        node["byteCountValue"] = size
        header = 1 if kind == "fixstr" else 2 if kind == "str8" else 3 if kind == "str16" else 5
        node["byteCount"] = header + size
        return node["byteCount"]
    if "invalidUTF8Hex" in node:
        size = len(bytes.fromhex(node["invalidUTF8Hex"]))
        node["byteCountValue"] = size
        header = 1 if kind == "fixstr" else 2 if kind == "str8" else 3 if kind == "str16" else 5
        node["byteCount"] = header + size
        return node["byteCount"]
    if "binaryHex" in node and node["binaryHex"] != "<chunk-id-bytes>":
        size = len(bytes.fromhex(node["binaryHex"]))
        node["byteCountValue"] = size
        header = 2 if kind == "bin8" else 3 if kind == "bin16" else 5
        node["byteCount"] = header + size
        return node["byteCount"]
    if node.get("binaryHex") == "<chunk-id-bytes>":
        size = len(b"<chunk-id-bytes>")
        node["byteCountValue"] = size
        header = 2 if kind == "bin8" else 3 if kind == "bin16" else 5
        node["byteCount"] = header + size
        return node["byteCount"]
    return node["byteCount"]


def messagepack_plain_value(node: dict[str, Any]) -> Any:
    if "utf8" in node:
        return node["utf8"]
    if "invalidUTF8Hex" in node:
        return {"invalidUTF8StringHex": node["invalidUTF8Hex"]}
    if "binaryHex" in node:
        return {"binaryHex": node["binaryHex"]}
    if "value" in node:
        return node["value"]
    if "items" in node:
        return [messagepack_plain_value(item) for item in node["items"]]
    if "entries" in node:
        return {
            str(messagepack_plain_value(entry["key"])): messagepack_plain_value(
                entry["value"]
            )
            for entry in node["entries"]
        }
    if "extensionHex" in node:
        return {
            "extensionHex": node["extensionHex"],
            "extensionType": node["extensionType"],
        }
    raise OracleFailure(f"unsupported normalized MessagePack node: {node}")


def normalize_fluentd_wire(
    raw: dict[str, Any],
    *,
    container_id: str,
    container_name: str,
) -> dict[str, Any]:
    """Normalize Fluent Forward envelopes while retaining MessagePack wire types."""

    replacements = (
        (container_id, "<container-id>"),
        (container_id[:12], "<container-id-short>"),
        (container_name, "<container-name>"),
        (container_name.lstrip("/"), "<container-name>"),
    )
    records: list[dict[str, Any]] = []
    for original in raw["objects"]:
        items = original.get("items", [])
        if len(items) not in (3, 4):
            raise OracleFailure(f"unexpected Fluentd envelope shape: {original}")
        timestamp_node = items[1]
        timestamp: dict[str, Any]
        if "extensionHex" in timestamp_node:
            encoded = bytes.fromhex(timestamp_node["extensionHex"])
            if timestamp_node.get("extensionType") != 0 or len(encoded) != 8:
                raise OracleFailure(f"unexpected Fluentd EventTime value: {timestamp_node}")
            seconds, nanoseconds = struct.unpack(">II", encoded)
            if nanoseconds >= 1_000_000_000:
                raise OracleFailure("Fluentd EventTime nanoseconds are out of range")
            timestamp = {
                "encoding": "MessagePack EventTime extension type 0",
                "nanosecondsInRange": True,
                "secondsArePositive": seconds > 0,
                "wireType": timestamp_node["type"],
            }
        elif isinstance(timestamp_node.get("value"), int):
            timestamp = {
                "encoding": "MessagePack integer Unix seconds",
                "secondsArePositive": timestamp_node["value"] > 0,
                "wireType": timestamp_node["type"],
            }
        else:
            raise OracleFailure(f"unsupported Fluentd timestamp: {timestamp_node}")

        normalized = normalize_messagepack_node(
            original,
            replacements=replacements,
        )
        normalized_timestamp = normalized["items"][1]
        if "extensionHex" in normalized_timestamp:
            normalized_timestamp["extensionHex"] = "<event-time-bytes>"
        else:
            normalized_timestamp["value"] = "<unix-seconds>"

        chunk_type: str | None = None
        if len(items) == 4:
            original_chunk = messagepack_map_value(items[3], "chunk")
            normalized_chunk = messagepack_map_value(normalized["items"][3], "chunk")
            if original_chunk is not None and normalized_chunk is not None:
                chunk_type = original_chunk["type"]
                if "utf8" in normalized_chunk:
                    normalized_chunk["utf8"] = "<chunk-id>"
                elif "binaryHex" in normalized_chunk:
                    normalized_chunk["binaryHex"] = "<chunk-id-bytes>"
                else:
                    raise OracleFailure(
                        f"unsupported Fluentd chunk identifier: {original_chunk}"
                    )

        normalized_byte_count = recompute_normalized_messagepack_byte_counts(
            normalized
        )

        semantic = messagepack_plain_value(normalized)
        records.append(
            {
                "chunkIdentifierWireType": chunk_type,
                "normalizedMessagePackByteCount": normalized_byte_count,
                "semanticEnvelope": semantic,
                "timestamp": timestamp,
                "wireEnvelope": normalized,
            }
        )

    payloads = [record["semanticEnvelope"][2] for record in records]
    observed_content: list[bytes] = []
    for payload in payloads:
        log_value = payload["log"]
        if isinstance(log_value, str):
            observed_content.append(log_value.encode().removesuffix(b"\n"))
        else:
            observed_content.append(
                bytes.fromhex(log_value["invalidUTF8StringHex"]).removesuffix(b"\n")
            )
        if payload.get("oracle.label") != "alpha" or payload.get("ORACLE_ENV") != "bravo":
            raise OracleFailure(f"Fluentd metadata is incomplete: {payload}")
    if observed_content != list(REMOTE_LOG_MARKERS):
        raise OracleFailure(
            f"Fluentd receiver observed unexpected content order: {observed_content!r}"
        )
    return {
        "acknowledgedChunkTypes": raw["acknowledgedChunkTypes"],
        "decodedByteCountEqualsRawByteCount": (
            raw["decodedByteCount"] == raw["rawByteCount"]
        ),
        "framing": "concatenated self-delimiting MessagePack objects",
        "mapEntryOrderNormalizedAway": True,
        "peerClosedAfterContainerExit": raw["peerClosed"],
        "records": records,
        "topLevelObjectCount": len(records),
        "trailingByteCount": raw["trailingByteCount"],
    }


def capture_fluentd_wire_transport(
    oracle: LoggingOracle,
    *,
    label: str,
    mode: str,
    scheme: str,
    request_ack: bool,
    sub_second_precision: bool,
) -> dict[str, Any]:
    """Capture one exact Docker Fluentd Forward transport inside Colima."""

    receiver = start_colima_log_receiver(
        oracle,
        label=label,
        mode=mode,
        expected_messages=len(REMOTE_LOG_MARKERS),
    )
    result: dict[str, Any] | None = None
    try:
        address = receiver_address(receiver, scheme)
        identifier, create = oracle.create(
            f"fluentd-wire-{label}",
            command=REMOTE_LOG_COMMAND,
            environment=["ORACLE_ENV=bravo"],
            labels={"oracle.label": "alpha"},
            log_config={
                "Type": "fluentd",
                "Config": {
                    "cache-disabled": "true",
                    "env": "ORACLE_ENV",
                    "fluentd-address": address,
                    "fluentd-request-ack": str(request_ack).lower(),
                    "fluentd-sub-second-precision": str(sub_second_precision).lower(),
                    "labels": "oracle.label",
                    "tag": "oracle.{{.Name}}.{{.ID}}",
                },
            },
        )
        assert identifier is not None
        inspect_before = oracle.inspect(identifier)
        start = oracle.start(identifier)
        wait = oracle.wait(identifier)
        raw = finish_colima_log_receiver(receiver)
        inspect = normalized_inspect(oracle.inspect(identifier))
        inspect["logConfig"]["Config"]["fluentd-address"] = (
            f"{scheme}://<colima-oracle-receiver>"
        )
        result = {
            "ackRequested": request_ack,
            "create": create,
            "inspectAfterExit": inspect,
            "phase": {
                "configurationAcceptedAtCreate": create["httpStatus"] == 201,
                "connectionEstablishedAtStart": start["httpStatus"] == 204,
                "containerExitCode": wait["exitCode"],
            },
            "requestedTransport": scheme,
            "subSecondPrecisionRequested": sub_second_precision,
            "wire": normalize_fluentd_wire(
                raw,
                container_id=identifier,
                container_name=inspect_before["Name"],
            ),
        }
    finally:
        cleanup = cleanup_colima_log_receiver(receiver)
    assert result is not None
    result["cleanup"] = cleanup
    return result


def capture_fluentd_async_reconnect(oracle: LoggingOracle) -> dict[str, Any]:
    """Prove buffered async delivery after an initially absent Unix receiver."""

    label = "async-reconnect"
    socket_path = f"/tmp/{oracle.prefix}-{label}.sock"
    subprocess.run(
        ["colima", "ssh", "--", "rm", "-f", socket_path],
        check=True,
        capture_output=True,
        timeout=10,
    )
    receiver: dict[str, Any] | None = None
    result: dict[str, Any] | None = None
    try:
        identifier, create = oracle.create(
            "fluentd-wire-async-reconnect",
            command=[*REMOTE_LOG_COMMAND[:-1], REMOTE_LOG_COMMAND[-1] + "; sleep 2"],
            environment=["ORACLE_ENV=bravo"],
            labels={"oracle.label": "alpha"},
            log_config={
                "Type": "fluentd",
                "Config": {
                    "cache-disabled": "true",
                    "env": "ORACLE_ENV",
                    "fluentd-address": f"unix://{socket_path}",
                    "fluentd-async": "true",
                    "fluentd-async-reconnect-interval": "100ms",
                    "fluentd-request-ack": "false",
                    "fluentd-sub-second-precision": "false",
                    "labels": "oracle.label",
                    "tag": "oracle.{{.Name}}.{{.ID}}",
                },
            },
        )
        assert identifier is not None
        inspect_before = oracle.inspect(identifier)
        receiver_absent_at_start = not colima_path_exists(
            socket_path,
            socket_path=True,
        )
        start = oracle.start(identifier)
        listener_delay_seconds = 0.75
        time.sleep(listener_delay_seconds)
        receiver = start_colima_log_receiver(
            oracle,
            label=label,
            mode="fluentd-unix",
            expected_messages=len(REMOTE_LOG_MARKERS),
        )
        wait = oracle.wait(identifier)
        raw = finish_colima_log_receiver(receiver)
        inspect = normalized_inspect(oracle.inspect(identifier))
        inspect["logConfig"]["Config"]["fluentd-address"] = (
            "unix://<colima-oracle-receiver>"
        )
        wire = normalize_fluentd_wire(
            raw,
            container_id=identifier,
            container_name=inspect_before["Name"],
        )
        result = {
            "ackRequested": False,
            "create": create,
            "inspectAfterExit": inspect,
            "phase": {
                "configurationAcceptedAtCreate": create["httpStatus"] == 201,
                "containerExitCode": wait["exitCode"],
                "listenerDelaySeconds": listener_delay_seconds,
                "receiverSocketAbsentAtStart": receiver_absent_at_start,
                "startSucceededWithoutReceiver": start["httpStatus"] == 204,
            },
            "requestedTransport": "unix",
            "subSecondPrecisionRequested": False,
            "wire": wire,
        }
    finally:
        if receiver is not None:
            cleanup = cleanup_colima_log_receiver(receiver)
        else:
            subprocess.run(
                ["colima", "ssh", "--", "rm", "-f", socket_path],
                check=True,
                capture_output=True,
                timeout=10,
            )
            if colima_path_exists(socket_path):
                raise OracleFailure(
                    "Fluentd reconnect cleanup left its receiver socket"
                )
            cleanup = {
                "receiverProcessRunning": False,
                "vmPathsRemaining": [],
            }
    assert result is not None
    result["cleanup"] = cleanup
    return result


def capture_fluentd_tls_trust_gap(oracle: LoggingOracle) -> dict[str, Any]:
    """Freeze why a self-contained Fluentd TLS wire oracle cannot authenticate."""

    receiver = start_colima_log_receiver(
        oracle,
        label="fluentd-tls-gap",
        mode="fluentd-tls",
        expected_messages=1,
    )
    result: dict[str, Any] | None = None
    try:
        identifier, create = oracle.create(
            "fluentd-wire-tls-gap",
            command=["sh", "-c", "printf 'tls-gap\\n'"],
            log_config={
                "Type": "fluentd",
                "Config": {
                    "cache-disabled": "true",
                    "fluentd-address": receiver_address(receiver, "tls"),
                    "fluentd-max-retries": "0",
                },
            },
        )
        assert identifier is not None
        start_status, start_response = oracle.engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{identifier}/start",
            timeout=15,
        )
        start_message = start_response.get("message")
        expected_message = (
            "failed to create task for container: failed to initialize logging driver: "
            "tls: failed to verify certificate: x509: certificate signed by unknown authority"
        )
        if start_status != 500 or start_message != expected_message:
            raise OracleFailure(
                "unexpected Fluentd TLS trust result: "
                f"HTTP {start_status} {start_message!r}"
            )
        process: subprocess.Popen[str] = receiver["process"]
        try:
            _, receiver_stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            receiver_stderr = ""
        inspect = normalized_inspect(oracle.inspect(identifier))
        inspect["logConfig"]["Config"]["fluentd-address"] = (
            "tls://<colima-oracle-receiver>"
        )
        result = {
            "create": create,
            "evidenceGap": {
                "decryptedPayloadCaptured": False,
                "reason": (
                    "Docker Fluentd exposes no CA-file or skip-verification log option; "
                    "capturing this local self-signed endpoint would require mutating "
                    "the Colima trust store"
                ),
            },
            "inspectAfterFailedStart": inspect,
            "phase": {
                "configurationAcceptedAtCreate": create["httpStatus"] == 201,
                "containerStateAfterFailedStart": inspect["state"]["status"],
                "startHTTPStatus": start_status,
                "startMessage": start_message,
            },
            "receiverObservedBadCertificateAlert": (
                "SSLV3_ALERT_BAD_CERTIFICATE" in receiver_stderr.upper()
            ),
            "requestedTransport": "tls",
        }
    finally:
        cleanup = cleanup_colima_log_receiver(receiver)
    assert result is not None
    result["cleanup"] = cleanup
    return result


FOREGROUND_MARKERS = ("early-out", "early-err", "late-out")


def compose_marker_summary(stdout: str, stderr: str) -> dict[str, Any]:
    """Normalize Compose foreground or historical output to marker counts."""

    combined = stdout + stderr
    return {
        "allMarkersExactlyOnce": all(combined.count(marker) == 1 for marker in FOREGROUND_MARKERS),
        "counts": {marker: combined.count(marker) for marker in FOREGROUND_MARKERS},
        "stderrMarkers": {
            marker: stderr.count(marker) for marker in FOREGROUND_MARKERS
        },
        "stdoutMarkers": {
            marker: stdout.count(marker) for marker in FOREGROUND_MARKERS
        },
    }


def capture_compose_foreground_case(
    engine: DockerEngine,
    *,
    prefix: str,
    label: str,
    driver: str,
    options: dict[str, str],
) -> dict[str, Any]:
    """Capture Docker Compose foreground attachment and later read-back."""

    project = f"ccfg{uuid.uuid4().hex[:12]}"
    container_id: str | None = None
    with tempfile.TemporaryDirectory(prefix=f"{prefix}-{label}-") as directory:
        compose_path = Path(directory) / "compose.json"
        compose_path.write_text(
            json.dumps(
                {
                    "services": {
                        "probe": {
                            "command": [
                                "sh",
                                "-c",
                                "printf 'early-out\\n'; "
                                "printf 'early-err\\n' >&2; "
                                "sleep 0.2; printf 'late-out\\n'",
                            ],
                            "image": REQUIRED_IMAGE,
                            "logging": {
                                "driver": driver,
                                "options": options,
                            },
                        }
                    }
                },
                separators=(",", ":"),
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        base = [
            "docker",
            "compose",
            "--project-name",
            project,
            "--file",
            str(compose_path),
            "--ansi",
            "never",
        ]
        environment = {
            **os.environ,
            "COMPOSE_ANSI": "never",
            "LC_ALL": "C",
        }
        try:
            foreground = subprocess.run(
                [
                    *base,
                    "up",
                    "--abort-on-container-exit",
                    "--exit-code-from",
                    "probe",
                    "--no-color",
                ],
                capture_output=True,
                check=False,
                text=True,
                env=environment,
                timeout=30,
            )
            container_id = subprocess.run(
                [*base, "ps", "--quiet", "--all", "probe"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
                timeout=10,
            ).stdout.strip()
            if re.fullmatch(r"[0-9a-f]{64}", container_id) is None:
                raise OracleFailure(
                    f"Compose foreground probe returned invalid container ID: {container_id!r}"
                )
            historical = subprocess.run(
                [*base, "logs", "--no-color"],
                capture_output=True,
                check=False,
                text=True,
                env=environment,
                timeout=10,
            )
            _, inspect = engine.request_json(
                "GET",
                f"/v{REQUIRED_API_VERSION}/containers/{container_id}/json",
                expected_status=200,
            )
            return {
                "foreground": {
                    "exitCode": foreground.returncode,
                    "markers": compose_marker_summary(
                        foreground.stdout,
                        foreground.stderr,
                    ),
                },
                "historicalRead": {
                    "exitCode": historical.returncode,
                    "markers": compose_marker_summary(
                        historical.stdout,
                        historical.stderr,
                    ),
                    "unsupportedReaderWarning": (
                        UNSUPPORTED_READER_MESSAGE in historical.stderr
                    ),
                },
                "inspectAfterExit": normalized_inspect(inspect),
            }
        finally:
            cleanup = subprocess.run(
                [
                    *base,
                    "down",
                    "--volumes",
                    "--remove-orphans",
                    "--timeout",
                    "0",
                ],
                capture_output=True,
                check=False,
                text=True,
                env=environment,
                timeout=30,
            )
            if cleanup.returncode != 0:
                raise OracleFailure(
                    f"Compose foreground cleanup failed for {label}: {cleanup.stderr}"
                )
            if container_id is not None:
                status, _, _ = engine.request(
                    "GET",
                    f"/v{REQUIRED_API_VERSION}/containers/{container_id}/json",
                )
                if status != 404:
                    raise OracleFailure(
                        f"Compose foreground cleanup retained container {container_id}"
                    )
            network_status, _, _ = engine.request(
                "GET",
                f"/v{REQUIRED_API_VERSION}/networks/"
                f"{quote(f'{project}_default', safe='')}",
            )
            if network_status != 404:
                raise OracleFailure(
                    f"Compose foreground cleanup retained network {project}_default"
                )


def capture_compose_foreground(engine: DockerEngine, prefix: str) -> dict[str, Any]:
    """Capture foreground behavior for readable and unreadable loggers."""

    return {
        "jsonFileReadable": capture_compose_foreground_case(
            engine,
            prefix=prefix,
            label="json-file",
            driver="json-file",
            options={},
        ),
        "none": capture_compose_foreground_case(
            engine,
            prefix=prefix,
            label="none",
            driver="none",
            options={},
        ),
        "syslogCacheDisabled": capture_compose_foreground_case(
            engine,
            prefix=prefix,
            label="syslog-disabled",
            driver="syslog",
            options={
                "cache-disabled": "true",
                "syslog-address": "udp://127.0.0.1:55144",
            },
        ),
    }


def docker_context_socket() -> str:
    result = subprocess.run(
        ["docker", "context", "inspect", REQUIRED_CONTEXT],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    context = json.loads(result.stdout)[0]
    host = context["Endpoints"]["docker"]["Host"]
    if not host.startswith("unix://"):
        raise PrerequisiteUnavailable(
            f"Docker context {REQUIRED_CONTEXT} is not a Unix socket: {host}"
        )
    socket_path = host.removeprefix("unix://")
    if not Path(socket_path).is_socket():
        raise PrerequisiteUnavailable(f"Docker socket is unavailable: {socket_path}")
    return socket_path


def check_prerequisites() -> tuple[DockerEngine, dict[str, Any]]:
    for command in ("colima", "docker"):
        if shutil.which(command) is None:
            raise PrerequisiteUnavailable(f"{command} is not installed")

    selected_context = subprocess.run(
        ["docker", "context", "show"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    if selected_context != REQUIRED_CONTEXT:
        raise PrerequisiteUnavailable(
            f"Docker context is {selected_context!r}; expected {REQUIRED_CONTEXT!r}"
        )

    compose_version = subprocess.run(
        ["docker", "compose", "version", "--short"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    if compose_version != REQUIRED_COMPOSE_VERSION:
        raise PrerequisiteUnavailable(
            f"Docker Compose is {compose_version!r}; expected {REQUIRED_COMPOSE_VERSION!r}"
        )

    host_architecture = subprocess.run(
        ["uname", "-m"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    host_model = subprocess.run(
        ["sysctl", "-n", "hw.model"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    macos_version = subprocess.run(
        ["sw_vers", "-productVersion"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    expected_host = (
        REQUIRED_HOST_ARCHITECTURE,
        REQUIRED_HOST_MODEL,
        REQUIRED_MACOS_VERSION,
    )
    actual_host = (host_architecture, host_model, macos_version)
    if actual_host != expected_host:
        raise PrerequisiteUnavailable(
            f"evidence host is {actual_host!r}; expected {expected_host!r}"
        )

    engine = DockerEngine(docker_context_socket())
    _, version = engine.request_json(
        "GET", f"/v{REQUIRED_API_VERSION}/version", expected_status=200
    )
    if version["Version"] != REQUIRED_ENGINE_VERSION:
        raise PrerequisiteUnavailable(
            f"Docker Engine is {version['Version']}; expected {REQUIRED_ENGINE_VERSION}"
        )
    if version["ApiVersion"] != REQUIRED_API_VERSION:
        raise PrerequisiteUnavailable(
            f"Docker API is {version['ApiVersion']}; expected {REQUIRED_API_VERSION}"
        )

    _, info = engine.request_json(
        "GET", f"/v{REQUIRED_API_VERSION}/info", expected_status=200
    )
    image_status, image = engine.request_json(
        "GET",
        f"/v{REQUIRED_API_VERSION}/images/{quote(REQUIRED_IMAGE, safe='')}/json",
    )
    if image_status != 200:
        raise PrerequisiteUnavailable(
            f"required preloaded image is unavailable: {REQUIRED_IMAGE}"
        )

    docker_client_version = subprocess.run(
        ["docker", "version", "--format", "{{.Client.Version}}"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    colima_version = subprocess.run(
        ["colima", "version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.splitlines()[0].removeprefix("colima version ").strip()

    metadata = {
        "apiVersion": version["ApiVersion"],
        "architecture": version["Arch"],
        "colimaVersion": colima_version,
        "composeVersion": compose_version,
        "context": selected_context,
        "defaultLoggingDriver": info["LoggingDriver"],
        "dockerClientVersion": docker_client_version,
        "engineGitCommit": version["GitCommit"],
        "engineGoVersion": version["GoVersion"],
        "engineKernelVersion": version["KernelVersion"],
        "engineVersion": version["Version"],
        "hostArchitecture": host_architecture,
        "hostModel": host_model,
        "image": REQUIRED_IMAGE,
        "imageRepoDigests": sorted(image.get("RepoDigests", [])),
        "macOSVersion": macos_version,
        "minimumAPIVersion": version["MinAPIVersion"],
        "operatingSystem": version["Os"],
        "registeredLoggingDrivers": sorted(info["Plugins"]["Log"]),
    }
    return engine, metadata


def capture_oracle(engine: DockerEngine, metadata: dict[str, Any]) -> dict[str, Any]:
    prefix = f"cc-log-oracle-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    oracle = LoggingOracle(engine, REQUIRED_IMAGE, prefix)
    try:
        cases: dict[str, Any] = {}
        timings: dict[str, Any] = {}

        case_started = time.monotonic()
        omitted_id, omitted_create = oracle.create(
            "omitted",
            command=["true"],
        )
        assert omitted_id is not None
        omitted_before = normalized_inspect(oracle.inspect(omitted_id))
        omitted_read = oracle.logs(omitted_id, tty=False, follow=True)
        cases["omittedDefault"] = {
            "create": omitted_create,
            "inspectAfterCreatedRead": normalized_inspect(oracle.inspect(omitted_id)),
            "inspectBeforeRead": omitted_before,
            "requestedLogConfig": "omitted",
            "runningWasStarted": False,
            "createdFollowRead": omitted_read,
        }
        timings["omittedDefault"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["emptyDriver"] = oracle.create_start_probe(
            "empty-driver",
            driver="",
            options={},
        )
        timings["emptyDriver"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        json_id, json_create = oracle.create(
            "json",
            command=[
                "sh",
                "-c",
                'printf "stdout-line\\n"; printf "stderr-line\\n" >&2',
            ],
            labels={"oracle.label": "alpha"},
            log_config={
                "Type": "json-file",
                "Config": {"labels": "oracle.label"},
            },
        )
        assert json_id is not None
        json_before = normalized_inspect(oracle.inspect(json_id))
        oracle.start(json_id)
        oracle.wait(json_id)
        json_inspect_raw = oracle.inspect(json_id)
        cases["jsonFileStoppedReadAndFraming"] = {
            "combinedRead": oracle.logs(json_id, tty=False),
            "create": json_create,
            "inspectAfterExit": normalized_inspect(json_inspect_raw),
            "inspectBeforeStart": json_before,
            "jsonFileRecords": read_json_file_records(
                json_id, json_inspect_raw["LogPath"]
            ),
            "stderrOnlyRead": oracle.logs(
                json_id, tty=False, stdout=False, stderr=True
            ),
            "stdoutOnlyRead": oracle.logs(
                json_id, tty=False, stdout=True, stderr=False
            ),
        }
        timings["jsonFileStoppedReadAndFraming"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        local_id, local_create = oracle.create(
            "local",
            command=["sh", "-c", 'printf "local-line\\n"'],
            log_config={
                "Type": "local",
                "Config": {
                    "compress": "true",
                    "max-file": "2",
                    "max-size": "1m",
                },
            },
        )
        assert local_id is not None
        oracle.start(local_id)
        oracle.wait(local_id)
        cases["localNativeReader"] = {
            "create": local_create,
            "inspectAfterExit": normalized_inspect(oracle.inspect(local_id)),
            "stoppedRead": oracle.logs(local_id, tty=False),
        }
        timings["localNativeReader"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["jsonFileSustainedRotationCompression"] = capture_rotation_case(
            oracle,
            driver="json-file",
        )
        timings["jsonFileSustainedRotationCompression"] = monotonic_timing(
            case_started
        )

        case_started = time.monotonic()
        cases["localSustainedRotationCompression"] = capture_rotation_case(
            oracle,
            driver="local",
        )
        timings["localSustainedRotationCompression"] = monotonic_timing(
            case_started
        )

        case_started = time.monotonic()
        none_id, none_create = oracle.create(
            "none-options",
            command=["sh", "-c", 'printf "not-retained\\n"'],
            log_config={
                "Type": "none",
                "Config": {
                    "max-size": "1m",
                    "opaque-option": "opaque-value",
                },
            },
        )
        assert none_id is not None
        oracle.start(none_id)
        oracle.wait(none_id)
        cases["noneArbitraryOptions"] = {
            "create": none_create,
            "inspectAfterExit": normalized_inspect(oracle.inspect(none_id)),
            "requestTransport": "Docker Engine API",
            "stoppedRead": oracle.logs(none_id, tty=False),
        }
        timings["noneArbitraryOptions"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        invalid_local_name = oracle.name("invalid-local")
        invalid_local_status, invalid_local_response = engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/create?name={quote(invalid_local_name, safe='')}",
            payload={
                "Cmd": ["true"],
                "HostConfig": {
                    "LogConfig": {
                        "Config": {"opaque-option": "opaque-value"},
                        "Type": "local",
                    }
                },
                "Image": REQUIRED_IMAGE,
            },
        )

        invalid_json_id, invalid_json_create = oracle.create(
            "invalid-json",
            command=["true"],
            log_config={
                "Type": "json-file",
                "Config": {"max-file": "bogus"},
            },
        )
        assert invalid_json_id is not None
        invalid_json_before = normalized_inspect(oracle.inspect(invalid_json_id))
        invalid_json_start_status, invalid_json_start = engine.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/{invalid_json_id}/start",
        )
        cases["validationPhases"] = {
            "createTimeUnknownLocalOption": {
                "containerResidue": oracle.exists(invalid_local_name),
                "httpStatus": invalid_local_status,
                "message": invalid_local_response.get("message"),
            },
            "startTimeInvalidJSONFileValue": {
                "create": invalid_json_create,
                "inspectAfterFailedStart": normalized_inspect(
                    oracle.inspect(invalid_json_id)
                ),
                "inspectBeforeStart": invalid_json_before,
                "start": {
                    "httpStatus": invalid_json_start_status,
                    "message": invalid_json_start.get("message"),
                },
            },
        }
        timings["validationPhases"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        option_semantics: dict[str, Any] = {
            "mode": {},
            "compress": {},
            "maxSize": {},
            "maxFile": {},
            "maxBufferSize": {},
            "cacheDisabled": {},
            "cachePrefixRetention": {},
            "sizeUnits": {
                "cachePrefixedLocalOptions": "retained-but-ignored",
                "cacheLocalDefaults": {
                    "compress": True,
                    "maxFile": 5,
                    "maxSizeBytes": 20 * 1024 * 1024,
                },
                "maxBufferSize4kBytes": 4096,
                "maxBufferSizeParser": "units.RAMInBytes",
                "maxSize4kBytes": 4000,
                "maxSizeParser": "units.FromHumanSize",
            },
        }
        for label, value in {
            "blocking": "blocking",
            "nonBlocking": "non-blocking",
            "empty": "",
            "uppercase": "BLOCKING",
        }.items():
            option_semantics["mode"][label] = oracle.create_start_probe(
                f"mode-{label}",
                driver="json-file",
                options={"mode": value},
            )

        for label, value in {
            "trueMixed": "True",
            "falseUpper": "FALSE",
            "trueOne": "1",
            "falseZero": "0",
            "trueShort": "t",
            "falseShort": "f",
            "invalid": "yes",
            "empty": "",
        }.items():
            option_semantics["compress"][label] = oracle.create_start_probe(
                f"compress-{label}",
                driver="json-file",
                options={
                    "compress": value,
                    "max-file": "2",
                    "max-size": "1m",
                },
            )
        option_semantics["compress"]["missingRotation"] = (
            oracle.create_start_probe(
                "compress-missing-rotation",
                driver="json-file",
                options={"compress": "true"},
            )
        )

        for label, value in {
            "bytes": "1",
            "zero": "0",
            "negative": "-1",
            "fractionalUnit": "1.5k",
            "binaryUnit": "1KiB",
            "spaceSeparator": "1 k",
            "outerWhitespace": " 1k ",
            "leadingPlus": "+1m",
            "leadingFraction": ".5m",
            "exponent": "1e3",
        }.items():
            option_semantics["maxSize"][label] = oracle.create_start_probe(
                f"max-size-{label}",
                driver="json-file",
                options={"max-size": value},
            )

        for label, value in {
            "one": "1",
            "zero": "0",
            "negative": "-1",
            "leadingPlus": "+1",
            "leadingZero": "01",
            "fractional": "1.5",
            "outerWhitespace": " 1 ",
        }.items():
            option_semantics["maxFile"][label] = oracle.create_start_probe(
                f"max-file-{label}",
                driver="json-file",
                options={"max-file": value},
            )

        for label, value in {
            "zero": "0",
            "fractionalUnit": "1.5k",
            "upperUnit": "1KB",
            "outerWhitespace": " 1k ",
            "negative": "-1",
        }.items():
            option_semantics["maxBufferSize"][label] = oracle.create_start_probe(
                f"max-buffer-{label}",
                driver="json-file",
                options={
                    "max-buffer-size": value,
                    "mode": "non-blocking",
                },
            )

        for label, value in {
            "trueMixed": "True",
            "falseUpper": "FALSE",
            "trueOne": "1",
            "falseZero": "0",
            "trueShort": "t",
            "falseShort": "f",
            "invalid": "yes",
            "empty": "",
        }.items():
            option_semantics["cacheDisabled"][label] = oracle.create_start_probe(
                f"cache-disabled-{label}",
                driver="syslog",
                options={
                    "cache-disabled": value,
                    "syslog-address": "udp://127.0.0.1:55142",
                },
            )

        option_semantics["cachePrefixRetention"]["syslogArbitrary"] = (
            oracle.create_start_probe(
                "cache-prefix-syslog",
                driver="syslog",
                options={
                    "cache-compress": "not-a-boolean",
                    "cache-max-file": "not-an-integer",
                    "cache-max-size": "not-a-size",
                    "syslog-address": "udp://127.0.0.1:55143",
                },
            )
        )
        option_semantics["cachePrefixRetention"]["jsonFileArbitrary"] = (
            oracle.create_start_probe(
                "cache-prefix-json-file",
                driver="json-file",
                options={
                    "cache-compress": "not-a-boolean",
                    "cache-max-file": "not-an-integer",
                    "cache-max-size": "not-a-size",
                },
            )
        )
        cases["optionSemantics"] = option_semantics
        timings["optionSemantics"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["nonBlockingPressureDrop"] = capture_nonblocking_pressure(oracle)
        timings["nonBlockingPressureDrop"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["syslogRemoteWire"] = {
            "tcp": capture_syslog_wire_transport(
                oracle,
                label="tcp",
                mode="syslog-tcp",
                scheme="tcp",
            ),
            "tls": capture_syslog_wire_transport(
                oracle,
                label="tls",
                mode="syslog-tls",
                scheme="tcp+tls",
            ),
            "udp": capture_syslog_wire_transport(
                oracle,
                label="udp",
                mode="syslog-udp",
                scheme="udp",
            ),
            "unix": capture_syslog_wire_transport(
                oracle,
                label="unix",
                mode="syslog-unix",
                scheme="unix",
            ),
        }
        timings["syslogRemoteWire"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["fluentdRemoteWire"] = {
            "tlsLocalTrustFailure": capture_fluentd_tls_trust_gap(oracle),
            "unixAsyncReconnect": capture_fluentd_async_reconnect(oracle),
            "tcpAcknowledgedEventTime": capture_fluentd_wire_transport(
                oracle,
                label="tcp-ack",
                mode="fluentd-tcp",
                scheme="tcp",
                request_ack=True,
                sub_second_precision=True,
            ),
            "unixIntegerTime": capture_fluentd_wire_transport(
                oracle,
                label="unix",
                mode="fluentd-unix",
                scheme="unix",
                request_ack=False,
                sub_second_precision=False,
            ),
        }
        timings["fluentdRemoteWire"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        tty_id, tty_create = oracle.create(
            "tty",
            command=[
                "sh",
                "-c",
                'printf "stdout-line\\n"; printf "stderr-line\\n" >&2',
            ],
            log_config={"Type": "json-file", "Config": {}},
            tty=True,
        )
        assert tty_id is not None
        oracle.start(tty_id)
        oracle.wait(tty_id)
        cases["ttyRawMergedFraming"] = {
            "combinedRead": oracle.logs(tty_id, tty=True),
            "create": tty_create,
            "inspectAfterExit": normalized_inspect(oracle.inspect(tty_id)),
            "stderrOnlyRead": oracle.logs(
                tty_id, tty=True, stdout=False, stderr=True
            ),
            "stdoutOnlyRead": oracle.logs(
                tty_id, tty=True, stdout=True, stderr=False
            ),
        }
        timings["ttyRawMergedFraming"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        restart_id, restart_create = oracle.create(
            "restart",
            command=[
                "sh",
                "-c",
                "count=$(cat /oracle-run-count 2>/dev/null || printf 0); "
                "count=$((count + 1)); printf '%s' \"$count\" >/oracle-run-count; "
                "printf 'restart-%s\\n' \"$count\"; sleep 30",
            ],
            log_config={"Type": "json-file", "Config": {}},
        )
        assert restart_id is not None
        oracle.start(restart_id)
        oracle.wait_for_log_text(restart_id, "restart-1\n")
        restart_status = oracle.restart(restart_id)
        oracle.wait_for_log_text(restart_id, "restart-2\n")
        stop_status = oracle.stop(restart_id)
        cases["restartRetention"] = {
            "create": restart_create,
            "inspectAfterStop": normalized_inspect(oracle.inspect(restart_id)),
            "restartHTTPStatus": restart_status,
            "retainedRead": oracle.logs(restart_id, tty=False),
            "stopHTTPStatus": stop_status,
        }
        timings["restartRetention"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cached_id, cached_create = oracle.create(
            "syslog-cache",
            command=[
                "sh",
                "-c",
                'printf "cached-out\\n"; printf "cached-err\\n" >&2',
            ],
            log_config={
                "Type": "syslog",
                "Config": {"syslog-address": "udp://127.0.0.1:55140"},
            },
        )
        assert cached_id is not None
        oracle.start(cached_id)
        oracle.wait(cached_id)

        disabled_id, disabled_create = oracle.create(
            "syslog-no-cache",
            command=["sh", "-c", 'printf "not-cached\\n"'],
            log_config={
                "Type": "syslog",
                "Config": {
                    "cache-disabled": "true",
                    "syslog-address": "udp://127.0.0.1:55141",
                },
            },
        )
        assert disabled_id is not None
        oracle.start(disabled_id)
        oracle.wait(disabled_id)
        cases["nonReaderDualCache"] = {
            "cacheDisabled": {
                "create": disabled_create,
                "inspectAfterExit": normalized_inspect(oracle.inspect(disabled_id)),
                "stoppedRead": oracle.logs(disabled_id, tty=False),
            },
            "defaultCache": {
                "create": cached_create,
                "inspectAfterExit": normalized_inspect(oracle.inspect(cached_id)),
                "stoppedRead": oracle.logs(cached_id, tty=False),
            },
        }
        timings["nonReaderDualCache"] = monotonic_timing(case_started)

        case_started = time.monotonic()
        cases["composeForeground"] = capture_compose_foreground(engine, prefix)
        timings["composeForeground"] = monotonic_timing(case_started)

        return {
            "cases": cases,
            "metadata": metadata,
            "schemaVersion": 3,
            "timings": timings,
        }
    finally:
        oracle.close()


def render_fixture(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def normalize_timing_comparison(
    expected: dict[str, Any],
    actual: dict[str, Any],
) -> tuple[list[str], list[str]]:
    """Normalize raw timings while enforcing timeout and 10x regression rules."""

    expected_timings = expected.get("timings", {})
    actual_timings = actual.get("timings", {})
    if not isinstance(expected_timings, dict) or not isinstance(actual_timings, dict):
        return [], ["oracle timings are not objects"]

    observations: list[str] = []
    failures: list[str] = []
    for name in sorted(set(expected_timings) & set(actual_timings)):
        expected_timing = expected_timings[name]
        actual_timing = actual_timings[name]
        if not isinstance(expected_timing, dict) or not isinstance(actual_timing, dict):
            failures.append(f"{name}: timing record is not an object")
            continue
        baseline = expected_timing.get("durationSeconds")
        captured = actual_timing.get("durationSeconds")
        if (
            not isinstance(baseline, (int, float))
            or isinstance(baseline, bool)
            or baseline <= 0
            or not isinstance(captured, (int, float))
            or isinstance(captured, bool)
            or captured <= 0
        ):
            failures.append(f"{name}: timing durations must be positive numbers")
            continue
        ratio = captured / baseline
        observations.append(
            f"{name}: {captured:.6f}s monotonic ({ratio:.2f}x captured baseline)"
        )
        if ratio >= 10.0:
            failures.append(
                f"{name}: {captured:.6f}s is {ratio:.2f}x the "
                f"{baseline:.6f}s baseline"
            )
        actual_timing["durationSeconds"] = baseline
    return observations, failures


def compare_fixture(expected_path: Path, actual: str) -> bool:
    if not expected_path.is_file():
        raise OracleFailure(f"expected fixture is missing: {expected_path}")
    expected_value = json.loads(expected_path.read_text(encoding="utf-8"))
    actual_value = json.loads(actual)
    timing_observations, timing_failures = normalize_timing_comparison(
        expected_value,
        actual_value,
    )
    expected = render_fixture(expected_value)
    normalized_actual = render_fixture(actual_value)
    if expected == normalized_actual and not timing_failures:
        print(f"Docker logging oracle matches {expected_path}")
        for observation in timing_observations:
            print(f"timing {observation}")
        return True
    sys.stderr.writelines(
        difflib.unified_diff(
            expected.splitlines(keepends=True),
            normalized_actual.splitlines(keepends=True),
            fromfile=str(expected_path),
            tofile="captured-docker-logging-oracle",
        )
    )
    for failure in timing_failures:
        print(f"timing failure: {failure}", file=sys.stderr)
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Capture Docker Engine 29.2.1 logging behavior from the selected "
            "Colima context and compare it with the committed fixture."
        )
    )
    parser.add_argument(
        "--expected",
        type=Path,
        default=DEFAULT_FIXTURE,
        help="fixture to compare or update",
    )
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument(
        "--output",
        type=Path,
        help="write captured JSON to this path instead of comparing",
    )
    output_group.add_argument(
        "--update",
        action="store_true",
        help="replace the expected fixture with the captured JSON",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail instead of skipping when the pinned local oracle is unavailable",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        engine, metadata = check_prerequisites()
        captured = render_fixture(capture_oracle(engine, metadata))
    except PrerequisiteUnavailable as error:
        if args.strict:
            print(f"error: {error}", file=sys.stderr)
            return 1
        print(f"warning: {error}; skipping Docker logging oracle", file=sys.stderr)
        return 0
    except (OracleFailure, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.output is not None:
        args.output.write_text(captured, encoding="utf-8")
        print(f"wrote {args.output}")
        return 0
    if args.update:
        args.expected.parent.mkdir(parents=True, exist_ok=True)
        args.expected.write_text(captured, encoding="utf-8")
        print(f"updated {args.expected}")
        return 0
    return 0 if compare_fixture(args.expected, captured) else 1


if __name__ == "__main__":
    raise SystemExit(main())
