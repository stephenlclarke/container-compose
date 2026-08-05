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

"""Deterministic host TCP sink for paired logging-driver performance probes."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import socket
import tempfile
import time


MARKER_PATTERN = re.compile(rb"perf-record-(\d{6})")


def parse_arguments() -> argparse.Namespace:
    """Parse the isolated sink configuration."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--result-file", required=True, type=Path)
    parser.add_argument("--stop-file", type=Path)
    parser.add_argument("--stall-seconds", default=0.0, type=float)
    parser.add_argument("--receive-buffer-bytes", default=4096, type=int)
    parser.add_argument("--accept-timeout-seconds", default=30.0, type=float)
    parser.add_argument("--idle-timeout-seconds", default=2.0, type=float)
    return parser.parse_args()


def write_atomic(path: Path, content: str) -> None:
    """Publish one small control/result file without exposing a partial value."""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def receive(arguments: argparse.Namespace) -> dict[str, object]:
    """Receive sequential syslog TCP connections until idle or stopped."""

    started = time.monotonic()
    payload = bytearray()
    connection_count = 0
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_RCVBUF,
            arguments.receive_buffer_bytes,
        )
        listener.bind(("0.0.0.0", 0))
        listener.listen(4)
        listener.settimeout(min(0.1, arguments.accept_timeout_seconds))
        write_atomic(arguments.port_file, f"{listener.getsockname()[1]}\n")

        first_connection = True
        accept_deadline = started + arguments.accept_timeout_seconds
        while True:
            if arguments.stop_file is not None and arguments.stop_file.exists():
                break
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                if first_connection and time.monotonic() >= accept_deadline:
                    raise
                if arguments.stop_file is None and not first_connection:
                    break
                continue
            first_connection = False
            connection_count += 1
            with connection:
                connection.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_RCVBUF,
                    arguments.receive_buffer_bytes,
                )
                if arguments.stall_seconds:
                    time.sleep(arguments.stall_seconds)
                connection.settimeout(
                    min(0.1, arguments.idle_timeout_seconds)
                    if arguments.stop_file is not None
                    else arguments.idle_timeout_seconds
                )
                while True:
                    try:
                        chunk = connection.recv(65536)
                    except TimeoutError:
                        if (
                            arguments.stop_file is not None
                            and arguments.stop_file.exists()
                        ):
                            break
                        if arguments.stop_file is None:
                            break
                        continue
                    if not chunk:
                        break
                    payload.extend(chunk)
            if arguments.stop_file is None:
                listener.settimeout(arguments.idle_timeout_seconds)
    finally:
        listener.close()

    markers = [int(value) for value in MARKER_PATTERN.findall(payload)]
    unique_markers = sorted(set(markers))
    return {
        "byteCount": len(payload),
        "connectionCount": connection_count,
        "durationSeconds": round(time.monotonic() - started, 9),
        "firstRecord": unique_markers[0] if unique_markers else None,
        "lastRecord": unique_markers[-1] if unique_markers else None,
        "recordCount": len(markers),
        "recordsAreOrdered": markers == sorted(markers),
        "recordsAreUnique": len(markers) == len(unique_markers),
    }


def main() -> None:
    """Run the sink and publish its deterministic summary."""

    arguments = parse_arguments()
    if arguments.stall_seconds < 0:
        raise SystemExit("--stall-seconds must be zero or positive")
    if arguments.receive_buffer_bytes <= 0:
        raise SystemExit("--receive-buffer-bytes must be positive")
    if arguments.accept_timeout_seconds <= 0:
        raise SystemExit("--accept-timeout-seconds must be positive")
    if arguments.idle_timeout_seconds <= 0:
        raise SystemExit("--idle-timeout-seconds must be positive")

    result = receive(arguments)
    write_atomic(
        arguments.result_file,
        json.dumps(result, indent=2, sort_keys=True) + "\n",
    )


if __name__ == "__main__":
    main()
