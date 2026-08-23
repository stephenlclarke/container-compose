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

from __future__ import annotations

import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import ModuleType
from unittest import mock

SCRIPT = Path(__file__).with_name("run-command-with-deadline.py")


def load_script() -> ModuleType:
    specification = importlib.util.spec_from_file_location("deadline_runner", SCRIPT)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def process_state(pid: int) -> str:
    return subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "state="],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()


class RunCommandWithDeadlineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script()

    def test_session_inspection_crosses_groups_and_ignores_zombies(self) -> None:
        session = 4242
        processes = subprocess.CompletedProcess(
            args=["ps"],
            returncode=0,
            stdout=(
                "4242 S\n"
                "4243 S+\n"
                "4244 Z\n"
                "5252 S\n"
            ),
            stderr="",
        )
        sessions = {4242: session, 4243: session, 5252: 5252}

        with mock.patch.object(
            self.module.subprocess, "run", return_value=processes
        ) as run_processes, mock.patch.object(
            self.module.os,
            "getsid",
            side_effect=lambda process_id: sessions[process_id],
        ):
            inspection = self.module.inspect_supervised_session(session)
            self.assertEqual(
                inspection.state, self.module.SessionState.LIVE
            )
            self.assertEqual(inspection.process_ids, (4242, 4243))
            self.assertEqual(run_processes.call_args.args[0][0], "/bin/ps")

    def test_session_inspection_is_unknown_when_ps_fails(self) -> None:
        failed = subprocess.CompletedProcess(
            args=["ps"], returncode=1, stdout="", stderr="denied"
        )
        with mock.patch.object(self.module.subprocess, "run", return_value=failed):
            inspection = self.module.inspect_supervised_session(4242)

        self.assertEqual(inspection.state, self.module.SessionState.UNKNOWN)

    def test_session_inspection_is_unknown_when_getsid_is_denied(self) -> None:
        processes = subprocess.CompletedProcess(
            args=["ps"], returncode=0, stdout="4242 S\n", stderr=""
        )
        with mock.patch.object(
            self.module.subprocess, "run", return_value=processes
        ), mock.patch.object(
            self.module.os, "getsid", side_effect=PermissionError
        ):
            inspection = self.module.inspect_supervised_session(4242)

        self.assertEqual(inspection.state, self.module.SessionState.UNKNOWN)

    def test_unknown_inspection_uses_group_only_while_child_is_unreaped(
        self,
    ) -> None:
        process = mock.Mock()
        with mock.patch.object(
            self.module,
            "inspect_supervised_session",
            return_value=self.module.SessionInspection(
                self.module.SessionState.UNKNOWN
            ),
        ), mock.patch.object(
            self.module,
            "inspect_process_group",
            return_value=self.module.SessionState.LIVE,
        ) as inspect_group:
            process.poll.return_value = None
            inspection = self.module.inspect_with_child_fallback(4242, process)
            self.assertEqual(inspection.state, self.module.SessionState.LIVE)
            self.assertTrue(inspection.group_fallback_safe)
            inspect_group.assert_called_once_with(4242)

            inspect_group.reset_mock()
            process.poll.return_value = 0
            inspection = self.module.inspect_with_child_fallback(4242, process)
            self.assertEqual(inspection.state, self.module.SessionState.UNKNOWN)
            self.assertFalse(inspection.group_fallback_safe)
            inspect_group.assert_not_called()

    def test_unknown_session_after_success_fails_without_signaling(self) -> None:
        with mock.patch.object(
            self.module,
            "wait_for_session_to_drain",
            return_value=self.module.SessionState.UNKNOWN,
        ), mock.patch.object(
            self.module, "terminate_live_session"
        ) as terminate_session, mock.patch.object(
            self.module, "signal_inspected_session"
        ) as signal_session:
            status = self.module.run(
                ["--seconds", "5", "--", "/usr/bin/true"]
            )

        self.assertEqual(
            status, self.module.LEAKED_PROCESS_GROUP_EXIT_STATUS
        )
        terminate_session.assert_not_called()
        signal_session.assert_not_called()

    def test_returns_the_child_status_and_output(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--seconds",
                "5",
                "--",
                "/bin/sh",
                "-c",
                'printf "complete\\n"; exit 7',
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "complete\n")

    def test_no_deadline_returns_the_child_status_and_output(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--no-deadline",
                "--",
                "/bin/sh",
                "-c",
                'printf "complete\\n"; exit 7',
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )

        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "complete\n")

    def test_successful_child_allows_short_lived_descendant_to_drain(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--seconds",
                "5",
                "--grace-seconds",
                "0.2",
                "--",
                sys.executable,
                "-c",
                "import os, time; "
                "child = os.fork(); "
                "time.sleep(0.15) if child == 0 else None; "
                "os._exit(0)",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("command left live processes after exit", result.stderr)

    def test_successful_child_with_live_descendant_fails_and_cleans_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid = Path(directory) / "child-pid"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "5",
                    "--grace-seconds",
                    "0.2",
                    "--",
                    "/bin/sh",
                    "-c",
                    f"(trap '' TERM; exec /bin/sleep 30) & "
                    f'printf "%s\\n" "$!" >{child_pid}; exit 0',
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(
                result.returncode,
                self.module.LEAKED_PROCESS_GROUP_EXIT_STATUS,
                result.stderr,
            )
            self.assertIn("command left live processes after exit", result.stderr)
            pid = int(child_pid.read_text(encoding="utf-8").strip())
            cleanup_deadline = time.monotonic() + 2
            while process_state(pid) not in ("", "Z"):
                if time.monotonic() >= cleanup_deadline:
                    self.fail(f"leaked child {pid} survived cleanup")
                time.sleep(0.05)

    def test_successful_child_with_descendant_process_group_fails_and_cleans_session(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid = Path(directory) / "child-pid"
            child_program = f"""\
import os
import signal
import time

parent_process = os.getpid()
ready_read, ready_write = os.pipe()
child = os.fork()
if child == 0:
    os.close(ready_read)
    os.setpgid(0, 0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass
    os.write(ready_write, b"1")
    os.close(ready_write)
    time.sleep(30)
    os._exit(0)
os.close(ready_write)
if os.read(ready_read, 1) != b"1":
    raise RuntimeError("descendant setup did not complete")
os.close(ready_read)
with open({str(child_pid)!r}, "w", encoding="utf-8") as stream:
    stream.write(
        f"{{parent_process}}\t{{os.getsid(child)}}\t"
        f"{{child}}\t{{os.getpgid(child)}}\\n"
    )
os._exit(0)
"""
            try:
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--seconds",
                        "5",
                        "--grace-seconds",
                        "0.2",
                        "--",
                        sys.executable,
                        "-c",
                        child_program,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=8,
                )
            finally:
                if child_pid.exists():
                    details = [
                        int(value)
                        for value in child_pid.read_text(encoding="utf-8").split()
                    ]
                    child_process = details[2]
                    child_session = details[1]
                    try:
                        if os.getsid(child_process) == child_session:
                            os.kill(child_process, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

            self.assertEqual(
                result.returncode,
                self.module.LEAKED_PROCESS_GROUP_EXIT_STATUS,
                result.stderr,
            )
            self.assertIn("command left live processes after exit", result.stderr)
            parent_process, child_session, pid, child_process_group = [
                int(value)
                for value in child_pid.read_text(encoding="utf-8").split()
            ]
            self.assertEqual(parent_process, child_session)
            self.assertEqual(pid, child_process_group)
            cleanup_deadline = time.monotonic() + 2
            while process_state(pid) not in ("", "Z"):
                if time.monotonic() >= cleanup_deadline:
                    self.fail(f"descendant process-group child {pid} survived cleanup")
                time.sleep(0.05)

    def test_timeout_terminates_the_entire_child_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready"
            child_pid = root / "child-pid"
            started = time.monotonic()
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "0.2",
                    "--grace-seconds",
                    "0.3",
                    "--",
                    "/bin/sh",
                    "-c",
                    "trap 'exit 0' TERM; "
                    f"(trap '' TERM; exec sleep 30) & "
                    f'printf "%s\\n" "$!" >{child_pid}; '
                    f'touch {ready}; while :; do sleep 1; done',
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertLess(time.monotonic() - started, 3)
            self.assertTrue(ready.exists())
            self.assertIn("command exceeded 0.2-second deadline", result.stderr)
            self.assertNotIn("sleep 30", result.stderr)
            pid = int(child_pid.read_text(encoding="utf-8").strip())
            self.assertIn(process_state(pid), ("", "Z"))

    def test_deadline_stays_bounded_when_session_inspection_is_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child_pid = root / "child-pid"
            descendant_pid = root / "descendant-pid"
            harness = root / "unknown-deadline.py"
            descendant_command = (
                "(trap '' TERM; exec /bin/sleep 30) & "
                f"printf '%s' \"$!\" > {str(descendant_pid)!r}; "
                "trap '' TERM; while :; do sleep 1; done"
            )
            harness.write_text(
                f"""\
import importlib.util

spec = importlib.util.spec_from_file_location("deadline_runner", {str(SCRIPT)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_popen = module.subprocess.Popen

module.inspect_supervised_session = lambda _session: module.SessionInspection(
    module.SessionState.UNKNOWN
)
module.inspect_process_group = lambda _group: module.SessionState.UNKNOWN

def recording_popen(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    with open({str(child_pid)!r}, "w", encoding="utf-8") as stream:
        stream.write(str(process.pid))
    return process

module.subprocess.Popen = recording_popen
raise SystemExit(module.run([
    "--seconds", "0.1", "--grace-seconds", "0.1", "--",
    "/bin/sh", "-c", {descendant_command!r},
]))
""",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(harness)],
                capture_output=True,
                text=True,
                check=False,
                timeout=4,
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertIn(
                "could not inspect the command session during deadline cleanup",
                result.stderr,
            )
            pid = int(child_pid.read_text(encoding="utf-8"))
            self.assertIn(process_state(pid), ("", "Z"))
            descendant = int(descendant_pid.read_text(encoding="utf-8"))
            self.assertIn(process_state(descendant), ("", "Z"))

    def test_outer_timeout_cleans_a_nested_runner_child_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child_pid = root / "child-pid"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "0.2",
                    "--grace-seconds",
                    "0.2",
                    "--",
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "30",
                    "--grace-seconds",
                    "0.8",
                    "--",
                    "/bin/sh",
                    "-c",
                    "trap 'exit 0' TERM; "
                    f"(trap '' TERM; exec sleep 30) & "
                    f'printf "%s\\n" "$!" >{child_pid}; '
                    "while :; do sleep 1; done",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertTrue(child_pid.exists())
            pid = int(child_pid.read_text(encoding="utf-8").strip())
            cleanup_deadline = time.monotonic() + 2
            while process_state(pid) not in ("", "Z"):
                if time.monotonic() >= cleanup_deadline:
                    self.fail(f"nested deadline child {pid} survived cleanup")
                time.sleep(0.05)

    def test_signal_after_spawn_is_forwarded_without_a_race(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process_group_file = root / "process-group"
            harness = root / "signal-race.py"
            harness.write_text(
                f"""\
import importlib.util
import os
import signal
import subprocess

spec = importlib.util.spec_from_file_location("deadline_runner", {str(SCRIPT)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_popen = module.subprocess.Popen

def signaling_popen(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    with open({str(process_group_file)!r}, "w", encoding="utf-8") as stream:
        stream.write(str(process.pid))
    os.kill(os.getpid(), signal.SIGTERM)
    return process

module.subprocess.Popen = signaling_popen
raise SystemExit(module.run([
    "--seconds", "30", "--grace-seconds", "0.2", "--",
    "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done",
]))
""",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(harness)],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 143, result.stderr)
            process_group = int(process_group_file.read_text(encoding="utf-8"))
            group_state = subprocess.run(
                ["pgrep", "-g", str(process_group)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(group_state.returncode, 1, group_state.stdout)

    def test_forwarded_signal_stays_bounded_when_session_inspection_is_unknown(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child_pid = root / "child-pid"
            descendant_pid = root / "descendant-pid"
            harness = root / "unknown-session.py"
            descendant_command = (
                "(trap '' TERM; exec /bin/sleep 30) & "
                f"printf '%s' \"$!\" > {str(descendant_pid)!r}; "
                "trap '' TERM; while :; do sleep 1; done"
            )
            harness.write_text(
                f"""\
import importlib.util
import os
import signal

spec = importlib.util.spec_from_file_location("deadline_runner", {str(SCRIPT)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_popen = module.subprocess.Popen

module.inspect_supervised_session = lambda _session: module.SessionInspection(
    module.SessionState.UNKNOWN
)
module.inspect_process_group = lambda _group: module.SessionState.UNKNOWN

def signaling_popen(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    with open({str(child_pid)!r}, "w", encoding="utf-8") as stream:
        stream.write(str(process.pid))
    os.kill(os.getpid(), signal.SIGTERM)
    return process

module.subprocess.Popen = signaling_popen
raise SystemExit(module.run([
    "--seconds", "30", "--grace-seconds", "0.1", "--",
    "/bin/sh", "-c", {descendant_command!r},
]))
""",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(harness)],
                capture_output=True,
                text=True,
                check=False,
                timeout=4,
            )

            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertIn(
                "could not inspect the command session during signal cleanup",
                result.stderr,
            )
            pid = int(child_pid.read_text(encoding="utf-8"))
            self.assertIn(process_state(pid), ("", "Z"))
            descendant = int(descendant_pid.read_text(encoding="utf-8"))
            self.assertIn(process_state(descendant), ("", "Z"))

    def test_forwarded_signal_reaps_a_prompt_child_before_the_grace_period(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "ready"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "30",
                    "--grace-seconds",
                    "3",
                    "--",
                    "/bin/sh",
                    "-c",
                    f"trap 'exit 0' TERM; touch {ready}; while :; do sleep 1; done",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ready_deadline = time.monotonic() + 2
            while not ready.exists():
                if time.monotonic() >= ready_deadline:
                    process.kill()
                    self.fail("deadline child did not become ready")
                time.sleep(0.01)

            process.send_signal(signal.SIGTERM)
            # The timeout already proves the prompt child exits before the
            # configured three-second grace period without asserting a
            # scheduler-sensitive sub-second duration.
            stdout, stderr = process.communicate(timeout=2)

            self.assertEqual(process.returncode, 143, stdout + stderr)

    def test_control_signals_are_forwarded_and_reap_the_detached_child_group(
        self,
    ) -> None:
        for delivered_signal, shell_signal, expected_status in (
            (signal.SIGHUP, "HUP", 129),
            (signal.SIGQUIT, "QUIT", 131),
        ):
            with self.subTest(signal=delivered_signal.name):
                with tempfile.TemporaryDirectory() as directory:
                    ready = Path(directory) / "ready"
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            str(SCRIPT),
                            "--no-deadline",
                            "--grace-seconds",
                            "0.2",
                            "--",
                            "/bin/sh",
                            "-c",
                            f"trap 'exit 0' {shell_signal}; "
                            f"touch {ready}; while :; do sleep 1; done",
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    ready_deadline = time.monotonic() + 2
                    while not ready.exists():
                        if time.monotonic() >= ready_deadline:
                            process.kill()
                            self.fail("deadline child did not become ready")
                        time.sleep(0.01)

                    process.send_signal(delivered_signal)
                    stdout, stderr = process.communicate(timeout=2)

                    self.assertEqual(
                        process.returncode, expected_status, stdout + stderr
                    )

    def test_child_traps_work_when_the_runner_inherits_ignored_signals(self) -> None:
        for delivered_signal, shell_signal, expected_status in (
            (signal.SIGHUP, "HUP", 129),
            (signal.SIGINT, "INT", 130),
            (signal.SIGQUIT, "QUIT", 131),
        ):
            with self.subTest(signal=delivered_signal.name):
                with tempfile.TemporaryDirectory() as directory:
                    ready = Path(directory) / "ready"
                    cleanup = Path(directory) / "cleanup"
                    previous_handler = signal.signal(
                        delivered_signal, signal.SIG_IGN
                    )
                    try:
                        process = subprocess.Popen(
                            [
                                sys.executable,
                                str(SCRIPT),
                                "--no-deadline",
                                "--grace-seconds",
                                # Leave enough time for a loaded release host
                                # to schedule the shell's cleanup trap.
                                "2",
                                "--",
                                "/bin/sh",
                                "-c",
                                f"trap 'touch {cleanup}; exit 0' "
                                f"{shell_signal} TERM; "
                                f"touch {ready}; while :; do sleep 1; done",
                            ],
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                        )
                    finally:
                        signal.signal(delivered_signal, previous_handler)

                    ready_deadline = time.monotonic() + 2
                    while not ready.exists():
                        if time.monotonic() >= ready_deadline:
                            process.terminate()
                            process.communicate(timeout=2)
                            self.fail("deadline child did not become ready")
                        time.sleep(0.01)

                    process.send_signal(delivered_signal)
                    try:
                        stdout, stderr = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        stdout, stderr = process.communicate(timeout=2)
                        self.fail(
                            "ignored inherited signal prevented child cleanup\n"
                            + stdout
                            + stderr
                        )

                    self.assertEqual(
                        process.returncode, expected_status, stdout + stderr
                    )
                    self.assertTrue(cleanup.exists(), stdout + stderr)

    def test_bounded_cleanup_can_ignore_repeated_parent_termination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready"
            complete = root / "complete"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "2",
                    "--ignore-parent-signals",
                    "--",
                    "/bin/sh",
                    "-c",
                    f"touch {ready}; sleep 0.3; touch {complete}",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ready_deadline = time.monotonic() + 2
            while not ready.exists():
                if time.monotonic() >= ready_deadline:
                    process.kill()
                    self.fail("cleanup child did not become ready")
                time.sleep(0.01)

            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=2)

            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertTrue(complete.exists())


if __name__ == "__main__":
    unittest.main()
