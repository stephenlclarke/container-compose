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

"""Run one command with a wall-clock deadline and process-group cleanup."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
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


def signal_process_group(process_group_id: int, number: int) -> None:
    try:
        os.killpg(process_group_id, number)
    except ProcessLookupError:
        pass


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def normalized_exit_status(return_code: int) -> int:
    if return_code < 0:
        return 128 - return_code
    return return_code


def start_detached_cleanup_watchdog(
    process_group_id: int, grace_seconds: float
) -> int:
    """Keep cleanup alive if a parent deadline kills this runner."""
    watchdog_pid = os.fork()
    if watchdog_pid != 0:
        return watchdog_pid

    try:
        os.setsid()
        for descriptor in (sys.stdin.fileno(), sys.stdout.fileno(), sys.stderr.fileno()):
            try:
                os.close(descriptor)
            except OSError:
                pass
        cleanup_deadline = time.monotonic() + grace_seconds
        while process_group_exists(process_group_id):
            remaining = cleanup_deadline - time.monotonic()
            if remaining <= 0:
                signal_process_group(process_group_id, signal.SIGKILL)
                break
            time.sleep(min(0.05, remaining))
    finally:
        os._exit(0)


def wait_for_watchdog(watchdog_pid: int) -> None:
    while True:
        try:
            os.waitpid(watchdog_pid, 0)
            return
        except InterruptedError:
            continue
        except ChildProcessError:
            return


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    forwarded_signal: int | None = None
    previous_handlers: dict[int, signal.Handlers] = {}
    forwarded_signals = {signal.SIGINT, signal.SIGTERM}
    previous_signal_mask = signal.pthread_sigmask(
        signal.SIG_BLOCK, forwarded_signals
    )

    def restore_child_signal_mask() -> None:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

    try:
        process = subprocess.Popen(
            options.command,
            start_new_session=True,
            preexec_fn=restore_child_signal_mask,
        )
    except FileNotFoundError:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        print(f"command was not found: {options.command[0]}", file=sys.stderr)
        return 127
    except PermissionError:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        print(f"command is not executable: {options.command[0]}", file=sys.stderr)
        return 126

    def forward_signal(number: int, _frame: object) -> None:
        nonlocal forwarded_signal
        if forwarded_signal is None:
            forwarded_signal = number
        signal_process_group(process.pid, number)

    for number in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[number] = signal.signal(number, forward_signal)

    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        deadline = time.monotonic() + options.seconds
        while True:
            if forwarded_signal is not None:
                watchdog_pid = start_detached_cleanup_watchdog(
                    process.pid, options.grace_seconds
                )
                wait_for_watchdog(watchdog_pid)
                process.wait()
                return 128 + forwarded_signal

            return_code = process.poll()
            if return_code is not None:
                return normalized_exit_status(return_code)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(
                    f"command exceeded {options.seconds:g}-second deadline: "
                    + options.command[0],
                    file=sys.stderr,
                )
                signal_process_group(process.pid, signal.SIGTERM)
                grace_deadline = time.monotonic() + options.grace_seconds
                while True:
                    process.poll()
                    if not process_group_exists(process.pid):
                        break
                    grace_remaining = grace_deadline - time.monotonic()
                    if grace_remaining <= 0:
                        signal_process_group(process.pid, signal.SIGKILL)
                        break
                    time.sleep(min(0.05, grace_remaining))
                process.wait()
                return TIMEOUT_EXIT_STATUS
            time.sleep(min(0.05, remaining))
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
