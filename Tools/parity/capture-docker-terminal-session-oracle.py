#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Capture Docker-compatible live TTY resize and detach/re-attach semantics."""

from __future__ import annotations

import argparse
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from typing import Any
from urllib.parse import quote
import uuid


REQUIRED_CONTEXT = "colima"
REQUIRED_ENGINE_VERSION = "29.2.1"
REQUIRED_ENGINE_COMMIT = "6bc6209"
REQUIRED_API_VERSION = "1.53"
REQUIRED_IMAGE = "alpine:3.20"
DURATION_KEY = "durationSeconds"
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = (
    REPO_ROOT
    / "Tests/ComposeCoreTests/Fixtures/logging/"
    "docker-engine-29.2.1-terminal-session.json"
)
WORKLOAD = (
    "printf 'READY\\n'; "
    "while IFS= read -r line; do "
    'case "$line" in '
    "size) set -- $(stty size); printf 'SIZE:%s:%s\\n' \"$1\" \"$2\";; "
    "after) printf 'AFTER\\n';; "
    "exit) printf 'BYE\\n'; exit 0;; "
    "esac; done"
)


class PrerequisiteUnavailable(RuntimeError):
    """Raised when the pinned reference or selected candidate is unavailable."""


class OracleFailure(RuntimeError):
    """Raised when a terminal-session behavior differs from the contract."""


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP/1.1 connection over one Unix-domain socket."""

    def __init__(self, socket_path: str, timeout: float = 20.0) -> None:
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        connection.connect(self.socket_path)
        self.sock = connection


class EngineClient:
    """Bounded Docker Engine API client for lifecycle and inspection requests."""

    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path

    def request(
        self,
        method: str,
        endpoint: str,
        *,
        payload: dict[str, Any] | None = None,
        expected_status: int | tuple[int, ...] | None = None,
        timeout: float = 20.0,
    ) -> tuple[int, bytes]:
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
            content = response.read()
            if expected_status is not None:
                expected = (
                    (expected_status,)
                    if isinstance(expected_status, int)
                    else expected_status
                )
                if response.status not in expected:
                    raise OracleFailure(
                        f"{method} {endpoint} returned HTTP {response.status}, "
                        f"expected {expected}: {content!r}"
                    )
            return response.status, content
        finally:
            connection.close()

    def request_json(
        self,
        method: str,
        endpoint: str,
        *,
        payload: dict[str, Any] | None = None,
        expected_status: int,
    ) -> tuple[int, dict[str, Any]]:
        status, body = self.request(
            method,
            endpoint,
            payload=payload,
            expected_status=expected_status,
        )
        try:
            decoded = json.loads(body) if body else {}
        except json.JSONDecodeError as error:
            raise OracleFailure(
                f"{method} {endpoint} returned invalid JSON: {body!r}"
            ) from error
        if not isinstance(decoded, dict):
            raise OracleFailure(f"{method} {endpoint} returned a non-object JSON body")
        return status, decoded


class HijackedTTY:
    """One bounded raw-stream Engine attach connection."""

    def __init__(self, socket_path: str, container_id: str) -> None:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(10.0)
        connection.connect(socket_path)
        self.connection = connection
        endpoint = (
            f"/v{REQUIRED_API_VERSION}/containers/"
            f"{quote(container_id, safe='')}/attach"
            "?logs=0&stream=1&stdin=1&stdout=1&stderr=1&detachKeys=ctrl-x"
        )
        request = (
            f"POST {endpoint} HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: tcp\r\n"
            "Content-Length: 0\r\n\r\n"
        )
        connection.sendall(request.encode("ascii"))
        head, self.buffer = self._read_head()
        self.handshake = self._parse_head(head)

    def close(self) -> None:
        self.connection.close()

    def send(self, value: bytes) -> None:
        self.connection.sendall(value)

    def read_until(self, marker: bytes) -> bytes:
        deadline = time.monotonic() + 10.0
        while marker not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise OracleFailure(
                    f"attach output did not contain {marker!r}: {self.buffer!r}"
                )
            self.connection.settimeout(remaining)
            try:
                chunk = self.connection.recv(64 * 1024)
            except TimeoutError as error:
                raise OracleFailure(
                    f"attach output did not contain {marker!r}: {self.buffer!r}"
                ) from error
            if not chunk:
                raise OracleFailure(
                    f"attach closed before {marker!r}: {self.buffer!r}"
                )
            self.buffer += chunk
        return self.buffer

    def expect_eof(self) -> bool:
        if self.buffer:
            raise OracleFailure(f"unexpected unread attach bytes before EOF: {self.buffer!r}")
        self.connection.settimeout(10.0)
        trailing = self.connection.recv(1)
        if trailing:
            raise OracleFailure(f"attach returned bytes instead of EOF: {trailing!r}")
        return True

    def take_lines(self) -> list[str]:
        try:
            decoded = self.buffer.decode("utf-8")
        except UnicodeDecodeError as error:
            raise OracleFailure(f"TTY output is not UTF-8: {self.buffer!r}") from error
        if not decoded.endswith("\r\n"):
            raise OracleFailure(f"TTY output lacks the expected CRLF ending: {decoded!r}")
        self.buffer = b""
        return decoded.removesuffix("\r\n").split("\r\n")

    def _read_head(self) -> tuple[bytes, bytes]:
        value = b""
        while b"\r\n\r\n" not in value:
            chunk = self.connection.recv(64 * 1024)
            if not chunk:
                raise OracleFailure("attach closed before its HTTP upgrade response")
            value += chunk
            if len(value) > 64 * 1024:
                raise OracleFailure("attach HTTP response head exceeded 64 KiB")
        return tuple(value.split(b"\r\n\r\n", 1))  # type: ignore[return-value]

    @staticmethod
    def _parse_head(value: bytes) -> dict[str, Any]:
        lines = value.decode("iso-8859-1").split("\r\n")
        status_match = re.fullmatch(r"HTTP/1\.[01] (\d{3})(?: .*)?", lines[0])
        if status_match is None:
            raise OracleFailure(f"invalid attach status line: {lines[0]!r}")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, separator, header_value = line.partition(":")
            if not separator:
                raise OracleFailure(f"invalid attach response header: {line!r}")
            headers[name.lower()] = header_value.strip().lower()
        result = {
            "connection": headers.get("connection"),
            "contentType": headers.get("content-type"),
            "httpStatus": int(status_match.group(1)),
            "upgrade": headers.get("upgrade"),
        }
        expected = {
            "connection": "upgrade",
            "contentType": "application/vnd.docker.raw-stream",
            "httpStatus": 101,
            "upgrade": "tcp",
        }
        if result != expected:
            raise OracleFailure(f"attach upgrade = {result!r}, expected {expected!r}")
        return result


def inspect(client: EngineClient, container_id: str) -> dict[str, Any]:
    _, document = client.request_json(
        "GET",
        f"/v{REQUIRED_API_VERSION}/containers/{quote(container_id, safe='')}/json",
        expected_status=200,
    )
    state = document.get("State")
    if not isinstance(state, dict):
        raise OracleFailure("container inspection has no State object")
    return state


def wait_for_exit(client: EngineClient, container_id: str) -> dict[str, Any]:
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        state = inspect(client, container_id)
        if state.get("Running") is False:
            exit_code = state.get("ExitCode")
            if not isinstance(exit_code, int):
                raise OracleFailure(f"terminal ExitCode is not an integer: {state!r}")
            return {"exitCode": exit_code, "running": False}
        time.sleep(0.1)
    raise OracleFailure("terminal workload did not stop within 20 seconds")


def capture_terminal_session(socket_path: str) -> dict[str, Any]:
    """Capture one exact, residue-free live terminal lifecycle."""

    started = time.monotonic()
    client = EngineClient(socket_path)
    name = f"cc-terminal-oracle-{uuid.uuid4().hex[:12]}"
    container_id: str | None = None
    cleanup: dict[str, Any] = {}
    stage = "create"
    try:
        create_status, created = client.request_json(
            "POST",
            f"/v{REQUIRED_API_VERSION}/containers/create?name={quote(name, safe='')}",
            payload={
                "AttachStderr": True,
                "AttachStdin": True,
                "AttachStdout": True,
                "Cmd": ["sh", "-c", WORKLOAD],
                "Image": REQUIRED_IMAGE,
                "OpenStdin": True,
                "StdinOnce": False,
                "Tty": True,
            },
            expected_status=201,
        )
        identifier = created.get("Id")
        if not isinstance(identifier, str) or not identifier:
            raise OracleFailure(f"container create returned no Id: {created!r}")
        container_id = identifier

        stage = "first attach upgrade"
        first = HijackedTTY(socket_path, container_id)
        try:
            stage = "start"
            start_status, _ = client.request(
                "POST",
                f"/v{REQUIRED_API_VERSION}/containers/{container_id}/start",
                expected_status=204,
            )
            stage = "initial terminal output"
            first.read_until(b"READY\r\n")
            initial_lines = first.take_lines()
            stage = "resize"
            resize_status, _ = client.request(
                "POST",
                f"/v{REQUIRED_API_VERSION}/containers/{container_id}/resize?h=48&w=132",
                expected_status=200,
            )
            stage = "resized terminal output"
            first.send(b"size\n")
            first.read_until(b"SIZE:48:132\r\n")
            resized_lines = first.take_lines()
            stage = "detach"
            first.send(b"\x18")
            detached_eof = first.expect_eof()
        finally:
            first.close()

        stage = "post-detach inspect"
        state_after_detach = inspect(client, container_id)
        if state_after_detach.get("Running") is not True:
            raise OracleFailure(
                f"detach stopped the workload: {state_after_detach!r}"
            )

        stage = "reattach upgrade"
        second = HijackedTTY(socket_path, container_id)
        try:
            stage = "reattached terminal output"
            second.send(b"after\n")
            second.read_until(b"AFTER\r\n")
            reattached_lines = second.take_lines()
            stage = "terminal exit output"
            second.send(b"exit\n")
            second.read_until(b"BYE\r\n")
            exit_lines = second.take_lines()
            reattached_eof = second.expect_eof()
        finally:
            second.close()

        stage = "terminal exit inspection"
        terminal_state = wait_for_exit(client, container_id)
        if terminal_state["exitCode"] != 0:
            raise OracleFailure(f"terminal workload exited nonzero: {terminal_state!r}")

        result = {
            "create": {"httpStatus": create_status},
            "firstAttach": {
                "handshake": first.handshake,
                "initialLines": initial_lines,
                "resize": {
                    "height": 48,
                    "httpStatus": resize_status,
                    "observedLines": resized_lines,
                    "width": 132,
                },
                "detach": {
                    "eof": detached_eof,
                    "sequenceBytes": [24],
                    "workloadRunning": True,
                },
            },
            "reattach": {
                "exitLines": exit_lines,
                "handshake": second.handshake,
                "observedLines": reattached_lines,
                "terminalEOF": reattached_eof,
            },
            "start": {"httpStatus": start_status},
            "terminalState": terminal_state,
        }
    except TimeoutError as error:
        raise OracleFailure(f"timed out during {stage}") from error
    finally:
        target = container_id or name
        delete_status, _ = client.request(
            "DELETE",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(target, safe='')}?force=1&v=1",
            expected_status=(204, 404),
        )
        absent_status, _ = client.request(
            "GET",
            f"/v{REQUIRED_API_VERSION}/containers/{quote(target, safe='')}/json",
            expected_status=404,
        )
        cleanup = {
            "absentAfterDelete": absent_status == 404,
            "deleteStatus": delete_status,
        }
    result["cleanup"] = cleanup
    result[DURATION_KEY] = round(time.monotonic() - started, 6)
    return result


def pinned_reference() -> tuple[str, dict[str, Any]]:
    """Resolve and validate the exact same-host Docker reference."""

    context = subprocess.run(
        ["docker", "context", "show"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    if context != REQUIRED_CONTEXT:
        raise PrerequisiteUnavailable(
            f"Docker context is {context!r}, expected {REQUIRED_CONTEXT!r}"
        )
    version_text = subprocess.run(
        ["docker", "version", "--format", "{{json .Server}}"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout
    version = json.loads(version_text)
    actual_version = version.get("Version")
    actual_api = version.get("ApiVersion")
    actual_commit = version.get("GitCommit")
    if actual_version != REQUIRED_ENGINE_VERSION:
        raise PrerequisiteUnavailable(
            f"Docker Engine is {actual_version}, expected {REQUIRED_ENGINE_VERSION}"
        )
    if actual_api != REQUIRED_API_VERSION:
        raise PrerequisiteUnavailable(
            f"Docker API is {actual_api}, expected {REQUIRED_API_VERSION}"
        )
    if actual_commit != REQUIRED_ENGINE_COMMIT:
        raise PrerequisiteUnavailable(
            f"Docker Engine commit is {actual_commit}, expected {REQUIRED_ENGINE_COMMIT}"
        )
    context_text = subprocess.run(
        ["docker", "context", "inspect", REQUIRED_CONTEXT],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout
    host = json.loads(context_text)[0]["Endpoints"]["docker"]["Host"]
    if not host.startswith("unix://"):
        raise PrerequisiteUnavailable(f"Docker reference is not a Unix socket: {host}")
    socket_path = host.removeprefix("unix://")
    if not Path(socket_path).is_socket():
        raise PrerequisiteUnavailable(f"Docker socket is unavailable: {socket_path}")
    subprocess.run(
        ["docker", "image", "inspect", REQUIRED_IMAGE],
        check=True,
        capture_output=True,
        timeout=10,
    )
    return socket_path, {
        "apiVersion": actual_api,
        "context": context,
        "engineGitCommit": actual_commit,
        "engineVersion": actual_version,
        "image": REQUIRED_IMAGE,
    }


def render(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def expected_document(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise OracleFailure(f"missing expected fixture: {path}") from error
    if not isinstance(value, dict):
        raise OracleFailure(f"expected fixture is not an object: {path}")
    return value


def case_duration(document: dict[str, Any]) -> float:
    """Read one finite, positive monotonic case duration."""

    case = document.get("case")
    if not isinstance(case, dict):
        raise OracleFailure("terminal-session document has no case object")
    value = case.get(DURATION_KEY)
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise OracleFailure(f"terminal-session duration is invalid: {value!r}")
    return float(value)


def semantic_document(document: dict[str, Any], *, case_only: bool) -> dict[str, Any]:
    """Remove ordinary timing variance while preserving every semantic field."""

    case = document.get("case")
    if not isinstance(case, dict):
        raise OracleFailure("terminal-session document has no case object")
    semantic_case = dict(case)
    semantic_case.pop(DURATION_KEY, None)
    if case_only:
        return semantic_case
    semantic = dict(document)
    semantic["case"] = semantic_case
    return semantic


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Capture the pinned Docker live terminal oracle, or compare one "
            "Docker-compatible candidate Unix socket with that oracle."
        )
    )
    parser.add_argument("--expected", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument(
        "--socket",
        help="candidate Docker-compatible Unix socket; skips reference fingerprint checks",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--output", type=Path)
    output.add_argument("--update", action="store_true")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail instead of skipping when a prerequisite is unavailable",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.socket is not None and args.update:
        print("error: --update cannot be used with a candidate --socket", file=sys.stderr)
        return 2
    try:
        if args.socket is not None:
            socket_path = os.path.abspath(os.path.expanduser(args.socket))
            if not Path(socket_path).is_socket():
                raise PrerequisiteUnavailable(
                    f"candidate Unix socket is unavailable: {socket_path}"
                )
            document = {
                "case": capture_terminal_session(socket_path),
                "schemaVersion": 1,
            }
        else:
            socket_path, metadata = pinned_reference()
            document = {
                "case": capture_terminal_session(socket_path),
                "metadata": metadata,
                "schemaVersion": 1,
            }
    except PrerequisiteUnavailable as error:
        if args.strict:
            print(f"error: {error}", file=sys.stderr)
            return 1
        print(f"warning: {error}; skipping terminal-session oracle", file=sys.stderr)
        return 0
    except (OracleFailure, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    rendered = render(document)
    if args.output is not None:
        args.output.write_text(rendered, encoding="utf-8")
        print(f"wrote {args.output}")
        return 0
    if args.update:
        args.expected.parent.mkdir(parents=True, exist_ok=True)
        args.expected.write_text(rendered, encoding="utf-8")
        print(f"updated {args.expected}")
        return 0

    try:
        expected = expected_document(args.expected)
    except OracleFailure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    try:
        expected_duration = case_duration(expected)
        actual_duration = case_duration(document)
        comparable = semantic_document(expected, case_only=args.socket is not None)
        actual = semantic_document(document, case_only=args.socket is not None)
    except OracleFailure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if actual != comparable:
        print("error: terminal-session oracle differs from the fixture", file=sys.stderr)
        print(render({"actual": actual, "expected": comparable}), file=sys.stderr)
        return 1
    if actual_duration >= expected_duration * 10:
        print(
            "error: terminal-session oracle took "
            f"{actual_duration:.6f}s, at least 10x its "
            f"{expected_duration:.6f}s reference",
            file=sys.stderr,
        )
        return 1
    implementation = "candidate" if args.socket is not None else "Docker reference"
    print(
        f"{implementation} TTY resize and detach/re-attach oracle passed "
        f"in {actual_duration:.6f}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
