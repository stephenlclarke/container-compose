#!/usr/bin/env python3
#===----------------------------------------------------------------------===#
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
#===----------------------------------------------------------------------===#

"""Run one command with a wall-clock deadline and process-group cleanup."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
from collections.abc import Sequence

TIMEOUT_EXIT_STATUS = 124


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--grace-seconds", type=float, default=10.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    parsed = parser.parse_args(arguments)
    if parsed.command[:1] == ["--"]:
        parsed.command = parsed.command[1:]
    if parsed.seconds <= 0:
        parser.error("--seconds must be greater than zero")
    if parsed.grace_seconds < 0:
        parser.error("--grace-seconds must be non-negative")
    if not parsed.command:
        parser.error("a command is required after --")
    return parsed


def signal_process_group(process: subprocess.Popen[bytes], number: int) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        pass


def normalized_exit_status(return_code: int) -> int:
    if return_code < 0:
        return 128 - return_code
    return return_code


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    try:
        process = subprocess.Popen(options.command, start_new_session=True)
    except FileNotFoundError:
        print(f"command was not found: {options.command[0]}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"command is not executable: {options.command[0]}", file=sys.stderr)
        return 126

    previous_handlers: dict[int, signal.Handlers] = {}

    def forward_signal(number: int, _frame: object) -> None:
        signal_process_group(process, number)

    for number in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[number] = signal.signal(number, forward_signal)

    try:
        try:
            return normalized_exit_status(process.wait(timeout=options.seconds))
        except subprocess.TimeoutExpired:
            print(
                f"command exceeded {options.seconds:g}-second deadline: "
                + options.command[0],
                file=sys.stderr,
            )
            signal_process_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=options.grace_seconds)
            except subprocess.TimeoutExpired:
                signal_process_group(process, signal.SIGKILL)
                process.wait()
            return TIMEOUT_EXIT_STATUS
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
