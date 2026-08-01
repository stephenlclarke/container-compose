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
import time
from typing import Any
from urllib.parse import quote, urlencode
import uuid


REQUIRED_CONTEXT = "colima"
REQUIRED_ENGINE_VERSION = "29.2.1"
REQUIRED_API_VERSION = "1.53"
REQUIRED_IMAGE = "alpine:3.20"
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

    metadata = {
        "apiVersion": version["ApiVersion"],
        "architecture": version["Arch"],
        "context": selected_context,
        "defaultLoggingDriver": info["LoggingDriver"],
        "engineVersion": version["Version"],
        "image": REQUIRED_IMAGE,
        "imageRepoDigests": sorted(image.get("RepoDigests", [])),
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

        return {
            "cases": cases,
            "metadata": metadata,
            "schemaVersion": 1,
        }
    finally:
        oracle.close()


def render_fixture(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def compare_fixture(expected_path: Path, actual: str) -> bool:
    if not expected_path.is_file():
        raise OracleFailure(f"expected fixture is missing: {expected_path}")
    expected = expected_path.read_text(encoding="utf-8")
    if expected == actual:
        print(f"Docker logging oracle matches {expected_path}")
        return True
    sys.stderr.writelines(
        difflib.unified_diff(
            expected.splitlines(keepends=True),
            actual.splitlines(keepends=True),
            fromfile=str(expected_path),
            tofile="captured-docker-logging-oracle",
        )
    )
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
