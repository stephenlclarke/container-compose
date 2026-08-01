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
import difflib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import socket
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
        labels: dict[str, str] | None = None,
        expected_status: int = 201,
    ) -> tuple[str | None, dict[str, Any]]:
        name = self.name(suffix)
        request: dict[str, Any] = {
            "Cmd": command,
            "Image": self.image,
            "Tty": tty,
        }
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
            "schemaVersion": 2,
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
