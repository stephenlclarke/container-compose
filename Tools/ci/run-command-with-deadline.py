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
from enum import Enum
from typing import NamedTuple

TIMEOUT_EXIT_STATUS = 124
LEAKED_PROCESS_GROUP_EXIT_STATUS = 125
NATURAL_DRAIN_SECONDS = 0.5
FORCED_CLEANUP_SECONDS = 1.0
PROCESS_INSPECTION_SECONDS = 1.0


class SessionState(Enum):
    LIVE = "live"
    DRAINED = "drained"
    UNKNOWN = "unknown"


class SessionInspection(NamedTuple):
    state: SessionState
    process_ids: tuple[int, ...] = ()
    group_fallback_safe: bool = False


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    deadline = parser.add_mutually_exclusive_group(required=True)
    deadline.add_argument("--seconds", type=float)
    deadline.add_argument(
        "--no-deadline",
        action="store_true",
        help="supervise the command process group without a wall-clock deadline",
    )
    parser.add_argument("--grace-seconds", type=float, default=10.0)
    parser.add_argument(
        "--ignore-parent-signals",
        action="store_true",
        help="let bounded cleanup finish despite repeated parent termination",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    parsed = parser.parse_args(arguments)
    if parsed.command[:1] == ["--"]:
        parsed.command = parsed.command[1:]
    if parsed.seconds is not None and parsed.seconds <= 0:
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
    except PermissionError:
        # The group can transiently contain only reparented or already-exited
        # descendants on Darwin. Still signal the direct child when possible.
        try:
            os.kill(process_group_id, number)
        except (ProcessLookupError, PermissionError):
            pass


def inspect_process_group(process_group_id: int) -> SessionState:
    """Probe one process group without treating permission denial as liveness."""
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return SessionState.DRAINED
    except PermissionError:
        return SessionState.UNKNOWN
    return SessionState.LIVE


def inspect_supervised_session(session_id: int) -> SessionInspection:
    """Inspect non-zombie members without guessing when identity is uncertain."""
    try:
        completed = subprocess.run(
            ["/bin/ps", "-axo", "pid=,state="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=PROCESS_INSPECTION_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return SessionInspection(SessionState.UNKNOWN)
    if completed.returncode != 0:
        return SessionInspection(SessionState.UNKNOWN)

    live_process_ids: list[int] = []
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2 or not fields[0].isdigit():
            continue
        process_id = int(fields[0])
        if fields[1].upper().startswith("Z"):
            continue
        try:
            process_session_id = os.getsid(process_id)
        except ProcessLookupError:
            continue
        except PermissionError:
            return SessionInspection(SessionState.UNKNOWN)
        if process_session_id == session_id:
            live_process_ids.append(process_id)
    if live_process_ids:
        return SessionInspection(SessionState.LIVE, tuple(live_process_ids))
    return SessionInspection(SessionState.DRAINED)


def inspect_with_child_fallback(
    session_id: int, process: subprocess.Popen[bytes] | subprocess.Popen[str]
) -> SessionInspection:
    """Use group probing only while the known direct child remains unreaped."""
    inspection = inspect_supervised_session(session_id)
    if inspection.state is not SessionState.UNKNOWN:
        return inspection
    if process.poll() is not None:
        return inspection
    group_state = inspect_process_group(session_id)
    return SessionInspection(
        group_state,
        group_fallback_safe=group_state is SessionState.LIVE,
    )


def signal_inspected_session(
    session_id: int, inspection: SessionInspection, number: int
) -> SessionState:
    """Signal only members whose supervised-session identity is still valid."""
    if inspection.group_fallback_safe:
        signal_process_group(session_id, number)
        return SessionState.LIVE
    uncertain = False
    for process_id in inspection.process_ids:
        try:
            if os.getsid(process_id) != session_id:
                continue
            os.kill(process_id, number)
        except ProcessLookupError:
            continue
        except PermissionError:
            uncertain = True
    return SessionState.UNKNOWN if uncertain else inspection.state


def terminate_live_session(
    session_id: int,
    grace_seconds: float,
    process: subprocess.Popen[bytes] | subprocess.Popen[str] | None = None,
) -> SessionState:
    """Terminate a verified session and preserve unknown identity as unknown."""
    inspection = (
        inspect_with_child_fallback(session_id, process)
        if process is not None
        else inspect_supervised_session(session_id)
    )
    if inspection.state is not SessionState.LIVE:
        return inspection.state

    if signal_inspected_session(session_id, inspection, signal.SIGTERM) \
        is SessionState.UNKNOWN:
        return SessionState.UNKNOWN
    cleanup_deadline = time.monotonic() + grace_seconds
    while True:
        inspection = (
            inspect_with_child_fallback(session_id, process)
            if process is not None
            else inspect_supervised_session(session_id)
        )
        if inspection.state is not SessionState.LIVE:
            return inspection.state
        remaining = cleanup_deadline - time.monotonic()
        if remaining <= 0:
            forced_deadline = time.monotonic() + FORCED_CLEANUP_SECONDS
            while True:
                inspection = (
                    inspect_with_child_fallback(session_id, process)
                    if process is not None
                    else inspect_supervised_session(session_id)
                )
                if inspection.state is not SessionState.LIVE:
                    return inspection.state
                if signal_inspected_session(
                    session_id, inspection, signal.SIGKILL
                ) is SessionState.UNKNOWN:
                    return SessionState.UNKNOWN
                forced_remaining = forced_deadline - time.monotonic()
                if forced_remaining <= 0:
                    return SessionState.LIVE
                time.sleep(min(0.05, forced_remaining))
        time.sleep(min(0.05, remaining))


def wait_for_session_to_drain(
    session_id: int, wait_seconds: float
) -> SessionState:
    """Allow short-lived descendants to exit naturally after their parent."""
    drain_deadline = time.monotonic() + wait_seconds
    while True:
        inspection = inspect_supervised_session(session_id)
        if inspection.state is not SessionState.LIVE:
            return inspection.state
        remaining = drain_deadline - time.monotonic()
        if remaining <= 0:
            return SessionState.LIVE
        time.sleep(min(0.05, remaining))


def normalized_exit_status(return_code: int) -> int:
    if return_code < 0:
        return 128 - return_code
    return return_code


def start_detached_cleanup_watchdog(
    session_id: int, grace_seconds: float
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
        terminate_live_session(session_id, grace_seconds)
    finally:
        os._exit(0)


def wait_for_watchdog(watchdog_pid: int, wait_seconds: float) -> bool:
    """Reap a cleanup watchdog without making signal handling unbounded."""
    wait_deadline = time.monotonic() + wait_seconds
    while True:
        try:
            reaped_pid, _ = os.waitpid(watchdog_pid, os.WNOHANG)
            if reaped_pid == watchdog_pid:
                return True
        except InterruptedError:
            continue
        except ChildProcessError:
            return True
        remaining = wait_deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.05, remaining))


def reap_direct_child(
    process: subprocess.Popen[bytes] | subprocess.Popen[str],
) -> bool:
    """Bound waiting for the exact child, then force that known PID to exit."""
    try:
        process.wait(timeout=FORCED_CLEANUP_SECONDS)
        return True
    except subprocess.TimeoutExpired:
        # Popen still owns this exact, unreaped child identity, so killing this
        # session's process group cannot target a recycled identity. Kill the
        # group before the exact-PID fallback so detached shell children cannot
        # retain pipes or contaminate a later stage.
        signal_process_group(process.pid, signal.SIGKILL)
        process.kill()
    try:
        process.wait(timeout=FORCED_CLEANUP_SECONDS)
        return True
    except subprocess.TimeoutExpired:
        return False


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    forwarded_signal: int | None = None
    previous_handlers: dict[int, signal.Handlers] = {}
    forwarded_signals = {
        signal.SIGHUP,
        signal.SIGINT,
        signal.SIGQUIT,
        signal.SIGTERM,
    }
    previous_signal_mask = signal.pthread_sigmask(
        signal.SIG_BLOCK, forwarded_signals
    )

    def restore_child_signal_state() -> None:
        # This runner is often started as an asynchronous Bash child. Bash
        # ignores SIGINT and SIGQUIT for such children, and an exec'd shell
        # cannot later trap a signal that was ignored when it started. Reset
        # every signal we supervise before exec so the detached command can
        # install its own cleanup traps consistently.
        for number in forwarded_signals:
            signal.signal(number, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

    try:
        process = subprocess.Popen(
            options.command,
            start_new_session=True,
            preexec_fn=restore_child_signal_state,
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
        if forwarded_signal is not None:
            return
        forwarded_signal = number
        # Keep the Python signal handler minimal. The main loop and its
        # detached watchdog perform bounded session enumeration and cleanup.

    for number in (
        signal.SIGHUP,
        signal.SIGINT,
        signal.SIGQUIT,
        signal.SIGTERM,
    ):
        handler = signal.SIG_IGN if options.ignore_parent_signals else forward_signal
        previous_handlers[number] = signal.signal(number, handler)

    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        deadline = (
            None
            if options.no_deadline
            else time.monotonic() + options.seconds
        )
        while True:
            if forwarded_signal is not None:
                watchdog_pid = start_detached_cleanup_watchdog(
                    process.pid, options.grace_seconds
                )
                cleanup_state = terminate_live_session(
                    process.pid, options.grace_seconds, process
                )
                if cleanup_state is SessionState.UNKNOWN:
                    print(
                        "could not inspect the command session during signal cleanup: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                if not reap_direct_child(process):
                    print(
                        "could not reap the command after forced cleanup: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                wait_for_watchdog(
                    watchdog_pid,
                    options.grace_seconds + FORCED_CLEANUP_SECONDS,
                )
                return 128 + forwarded_signal

            return_code = process.poll()
            if return_code is not None:
                exit_status = normalized_exit_status(return_code)
                drain_state = wait_for_session_to_drain(
                    process.pid, NATURAL_DRAIN_SECONDS
                )
                if drain_state is SessionState.UNKNOWN:
                    print(
                        "could not verify that the command session drained: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                    if exit_status == 0:
                        return LEAKED_PROCESS_GROUP_EXIT_STATUS
                elif drain_state is SessionState.LIVE:
                    terminate_live_session(process.pid, options.grace_seconds)
                    print(
                        "command left live processes after exit: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                    if exit_status == 0:
                        return LEAKED_PROCESS_GROUP_EXIT_STATUS
                return exit_status

            if deadline is None:
                time.sleep(0.05)
                continue

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(
                    f"command exceeded {options.seconds:g}-second deadline: "
                    + options.command[0],
                    file=sys.stderr,
                )
                cleanup_state = terminate_live_session(
                    process.pid, options.grace_seconds, process
                )
                if cleanup_state is SessionState.UNKNOWN:
                    print(
                        "could not inspect the command session during deadline cleanup: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                if not reap_direct_child(process):
                    print(
                        "could not reap the command after forced cleanup: "
                        + options.command[0],
                        file=sys.stderr,
                    )
                return TIMEOUT_EXIT_STATUS
            time.sleep(min(0.05, remaining))
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
