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

"""Transport regressions for the exact-source Sonar pull-request gate."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("sonar-pr-transport.py")
SPEC = importlib.util.spec_from_file_location("sonar_pr_transport", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
transport = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transport)

SHA = "a" * 40
PR = "708"
PROJECT = "stephenlclarke_container-compose2"
TASK = "AaDtest123_-"
HTTP_502 = (
    "Caused by: com.sonarsource.scanner.engine.webapi.client.HttpException: "
    "Error 502 on https://api.sonarcloud.io/analysis/analyses : Bad Gateway\n"
    "EXECUTION FAILURE\n"
)


class SonarPrTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report = self.root / ".scannerwork/report-task.txt"
        self.logs = self.root / "attempts"

    def write_report(self, *, project: str = PROJECT, task: str = TASK) -> None:
        self.report.parent.mkdir(exist_ok=True)
        self.report.write_text(
            f"projectKey={project}\nceTaskId={task}\n"
            "serverUrl=https://sonarcloud.io\n"
            f"ceTaskUrl=https://sonarcloud.io/api/ce/task?id={task}\n",
            encoding="utf-8",
        )

    def scan(self) -> int:
        return transport.run_scan(
            source_sha=SHA,
            pull_request=PR,
            report=self.report,
            log_dir=self.logs,
            command=["sonar-scanner", "-Dsonar.qualitygate.wait=true"],
            token="secret",
        )

    def session(self) -> None:
        self.logs.mkdir()
        (self.logs / "session.json").write_text(
            json.dumps(
                {
                    "source_sha": SHA,
                    "pull_request": PR,
                    "project_key": PROJECT,
                    "deadline_monotonic": transport.time.monotonic() + 60,
                }
            ),
            encoding="utf-8",
        )

    def ce(self, status: str, *, task: str = TASK, project: str = PROJECT) -> dict:
        result = {"id": task, "componentKey": project, "status": status}
        if status == "SUCCESS":
            result["analysisId"] = "analysis-123"
        return {"task": result}

    def wait(self) -> dict:
        return transport.wait_task(
            report=self.report,
            session=self.logs / "session.json",
            source_sha=SHA,
            pull_request=PR,
            token="secret",
        )

    def test_pre_submission_502_retries_only_until_exact_task_exists(self) -> None:
        def scanner(*_args: object) -> tuple[int, str]:
            if runner.call_count == 1:
                return 3, HTTP_502
            self.write_report()
            return 0, "ANALYSIS SUCCESSFUL\n"

        with mock.patch.object(transport, "run_scanner_once", side_effect=scanner) as runner:
            with mock.patch.object(transport.time, "sleep") as sleep:
                self.assertEqual(self.scan(), 0)
        self.assertEqual(runner.call_count, 2)
        sleep.assert_called_once_with(20)
        self.assertEqual(transport.read_report_task(self.report, PROJECT), TASK)

    def test_post_submission_transport_waits_without_resubmitting(self) -> None:
        def scanner(*_args: object) -> tuple[int, str]:
            self.write_report()
            return 3, HTTP_502

        with mock.patch.object(transport, "run_scanner_once", side_effect=scanner) as runner:
            self.assertEqual(self.scan(), 0)
        runner.assert_called_once()

    def test_read_reset_without_task_fails_but_owned_task_is_polled(self) -> None:
        causes = (
            "Caused by: java.net.SocketTimeoutException: Read timed out\n",
            "Caused by: java.net.SocketException: Connection reset\n",
        )
        for index, cause in enumerate(causes):
            with self.subTest(cause=cause):
                report = self.root / f"read-report-{index}"
                logs = self.root / f"read-logs-{index}"
                with mock.patch.object(
                    transport, "run_scanner_once", return_value=(3, cause)
                ) as runner:
                    self.assertEqual(
                        transport.run_scan(
                            source_sha=SHA, pull_request=PR, report=report,
                            log_dir=logs, command=["sonar-scanner"], token="secret",
                        ),
                        3,
                    )
                runner.assert_called_once()
                self.assertFalse(report.exists())

                report = self.root / f"owned-report-{index}"
                logs = self.root / f"owned-logs-{index}"

                def scanner(*_args: object) -> tuple[int, str]:
                    report.write_text(
                        f"projectKey={PROJECT}\nceTaskId={TASK}\n"
                        "serverUrl=https://sonarcloud.io\n"
                        f"ceTaskUrl=https://sonarcloud.io/api/ce/task?id={TASK}\n",
                        encoding="utf-8",
                    )
                    return 3, cause

                with mock.patch.object(
                    transport, "run_scanner_once", side_effect=scanner
                ) as runner:
                    self.assertEqual(
                        transport.run_scan(
                            source_sha=SHA, pull_request=PR, report=report,
                            log_dir=logs, command=["sonar-scanner"], token="secret",
                        ),
                        0,
                    )
                runner.assert_called_once()

    def test_transient_pre_submission_exhausts_three_attempts(self) -> None:
        with mock.patch.object(
            transport, "run_scanner_once", return_value=(3, HTTP_502)
        ) as runner:
            with mock.patch.object(transport.time, "sleep") as sleep:
                self.assertEqual(self.scan(), 3)
        self.assertEqual(runner.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [20, 40])
        self.assertFalse(self.report.exists())

    def test_auth_config_quality_and_deadline_fail_without_retry(self) -> None:
        cases = (
            (3, "Caused by: HttpException: Error 401 on https://api.sonarcloud.io/\n", False),
            (3, "Invalid project key\n", False),
            (3, HTTP_502 + "QUALITY GATE STATUS: FAILED\n", True),
            (124, HTTP_502, False),
            (70, HTTP_502, False),
        )
        for index, (status, log, with_report) in enumerate(cases):
            with self.subTest(index=index):
                report = self.root / f"case-{index}/report-task.txt"
                log_dir = self.root / f"logs-{index}"

                def scanner(*_args: object) -> tuple[int, str]:
                    if with_report:
                        report.parent.mkdir()
                        report.write_text(
                            f"projectKey={PROJECT}\nceTaskId={TASK}\n"
                            "serverUrl=https://sonarcloud.io\n"
                            f"ceTaskUrl=https://sonarcloud.io/api/ce/task?id={TASK}\n",
                            encoding="utf-8",
                        )
                    return status, log

                with mock.patch.object(
                    transport, "run_scanner_once", side_effect=scanner
                ) as runner:
                    result = transport.run_scan(
                        source_sha=SHA,
                        pull_request=PR,
                        report=report,
                        log_dir=log_dir,
                        command=["sonar-scanner"],
                        token="secret",
                    )
                self.assertEqual(result, status)
                runner.assert_called_once()

    def test_stale_or_foreign_task_fails_closed(self) -> None:
        self.write_report()
        with self.assertRaisesRegex(transport.TransportError, "existed before"):
            self.scan()
        self.assertFalse(self.logs.exists())

        self.report.unlink()

        def foreign_scanner(*_args: object) -> tuple[int, str]:
            self.write_report(project="unrelated_project")
            return 3, HTTP_502

        with mock.patch.object(
            transport, "run_scanner_once", side_effect=foreign_scanner
        ) as runner:
            with self.assertRaisesRegex(transport.TransportError, "project"):
                self.scan()
        runner.assert_called_once()

    def test_malformed_task_and_duplicate_keys_are_rejected(self) -> None:
        self.write_report(task="invalid task")
        with self.assertRaisesRegex(transport.TransportError, "ID is invalid"):
            transport.read_report_task(self.report, PROJECT)
        self.report.write_text(
            f"projectKey={PROJECT}\nceTaskId={TASK}\nceTaskId=other\n"
            "serverUrl=https://sonarcloud.io\n"
            f"ceTaskUrl=https://sonarcloud.io/api/ce/task?id={TASK}\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(transport.TransportError, "duplicate"):
            transport.read_report_task(self.report, PROJECT)

    def test_foreign_or_unbound_report_urls_are_rejected(self) -> None:
        self.write_report()
        original = self.report.read_text(encoding="utf-8")
        for changed in (
            original.replace("serverUrl=https://sonarcloud.io", "serverUrl=https://other.example"),
            original.replace("ceTaskUrl=https://sonarcloud.io", "ceTaskUrl=https://other.example"),
            original.replace(f"id={TASK}", "id=other"),
            original.replace(f"id={TASK}", f"id={TASK}&id={TASK}"),
            original.replace("https://sonarcloud.io", "http://sonarcloud.io"),
        ):
            with self.subTest(changed=changed):
                self.report.write_text(changed, encoding="utf-8")
                with self.assertRaisesRegex(transport.TransportError, "URLs"):
                    transport.read_report_task(self.report, PROJECT)

    def test_exact_ce_task_retries_read_only_transient_and_pending(self) -> None:
        self.write_report()
        self.session()
        transient = urllib.error.HTTPError("url", 503, "unavailable", {}, None)
        with mock.patch.object(
            transport, "fetch_task",
            side_effect=[transient, self.ce("PENDING"), self.ce("SUCCESS")],
        ) as fetch:
            with mock.patch.object(transport.time, "sleep") as sleep:
                result = self.wait()
        self.assertEqual(result["task"]["analysisId"], "analysis-123")
        self.assertEqual(fetch.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_ce_failed_cancelled_auth_and_foreign_task_fail_closed(self) -> None:
        self.write_report()
        self.session()
        responses = (
            self.ce("FAILED"),
            self.ce("CANCELED"),
            self.ce("SUCCESS", task="other-task"),
            self.ce("SUCCESS", project="other-project"),
            {"task": {"id": TASK, "componentKey": PROJECT, "status": "SUCCESS"}},
            urllib.error.HTTPError("url", 401, "unauthorized", {}, None),
        )
        for response in responses:
            with self.subTest(response=response):
                with mock.patch.object(transport, "fetch_task", side_effect=[response]):
                    with self.assertRaises(transport.TransportError):
                        self.wait()

    def test_session_identity_and_expired_budget_fail_before_api(self) -> None:
        self.write_report()
        self.session()
        with mock.patch.object(transport, "fetch_task") as fetch:
            with self.assertRaisesRegex(transport.TransportError, "identity"):
                transport.wait_task(
                    report=self.report,
                    session=self.logs / "session.json",
                    source_sha="b" * 40,
                    pull_request=PR,
                    token="secret",
                )
        fetch.assert_not_called()

        session_path = self.logs / "session.json"
        session = json.loads(session_path.read_text(encoding="utf-8"))
        session["deadline_monotonic"] = transport.time.monotonic() - 1
        session_path.write_text(json.dumps(session), encoding="utf-8")
        with mock.patch.object(transport, "fetch_task") as fetch:
            with self.assertRaisesRegex(transport.TransportError, "budget"):
                self.wait()
        fetch.assert_not_called()

    def test_late_scanner_and_ce_success_cannot_cross_shared_deadline(self) -> None:
        def successful_scanner(*_args: object) -> tuple[int, str]:
            self.write_report()
            return 0, "ANALYSIS SUCCESSFUL\n"

        with mock.patch.object(transport, "run_scanner_once", side_effect=successful_scanner):
            with mock.patch.object(
                transport.time, "monotonic", side_effect=[1000, 1000 + transport.TOTAL_SECONDS + 1]
            ):
                with self.assertRaisesRegex(transport.TransportError, "expired"):
                    self.scan()

        session = json.loads((self.logs / "session.json").read_text(encoding="utf-8"))
        session["deadline_monotonic"] = 1000
        (self.logs / "session.json").write_text(json.dumps(session), encoding="utf-8")
        with mock.patch.object(transport, "fetch_task", return_value=self.ce("SUCCESS")):
            with mock.patch.object(transport.time, "monotonic", side_effect=[999, 1001]):
                with self.assertRaisesRegex(transport.TransportError, "after the shared budget"):
                    self.wait()

    def test_connection_timeout_is_retryable_but_quality_failure_is_not(self) -> None:
        for code in (502, 503, 504):
            with self.subTest(code=code):
                self.assertTrue(
                    transport.transient_scanner_failure(
                        HTTP_502.replace("502", str(code)), 3
                    )
                )
        for cause in (
            "Caused by: java.net.SocketTimeoutException: Read timed out\n",
            "Caused by: java.net.SocketException: Connection reset\n",
        ):
            with self.subTest(cause=cause):
                self.assertFalse(transport.transient_scanner_failure(cause, 3))
                self.assertTrue(
                    transport.transient_scanner_failure(cause, 3, has_report=True)
                )
        self.assertTrue(
            transport.transient_scanner_failure(
                "Caused by: java.net.ConnectException: Connection refused\n", 3
            )
        )
        self.assertFalse(
            transport.transient_scanner_failure(
                "Caused by: java.net.ConnectException: Connection refused\n"
                "QUALITY GATE STATUS: FAILED\n",
                3,
            )
        )
        for status in (129, 130, 131, 143):
            self.assertFalse(transport.transient_scanner_failure(HTTP_502, status))

    def test_attempt_log_redacts_token_before_retention(self) -> None:
        script = self.root / "scanner.py"
        script.write_text(
            "import os\nprint('token=' + os.environ['SONAR_TOKEN'])\n",
            encoding="utf-8",
        )
        log = self.root / "scanner.log"
        previous_handlers = {
            number: signal.getsignal(number)
            for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
        }
        with mock.patch.dict(transport.os.environ, {"SONAR_TOKEN": "secret"}):
            with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
                status, retained = transport.run_scanner_once(
                    [transport.sys.executable, str(script)],
                    log,
                    transport.time.monotonic() + 30,
                    "secret",
                )
        self.assertEqual(status, 0)
        self.assertNotIn("secret", retained)
        self.assertNotIn("secret", output.getvalue())
        self.assertIn("[REDACTED]", retained)
        self.assertEqual(
            {number: signal.getsignal(number) for number in previous_handlers},
            previous_handlers,
        )

    def test_interrupt_forwards_to_supervisor_and_reaps_fake_scanner(self) -> None:
        scanner = self.root / "long-scanner.py"
        scanner.write_text(
            "import os, time\n"
            "from pathlib import Path\n"
            "Path(os.environ['READY']).write_text(str(os.getpid()))\n"
            "while True: time.sleep(1)\n",
            encoding="utf-8",
        )
        for delivered, expected in (
            (signal.SIGHUP, 129),
            (signal.SIGINT, 130),
            (signal.SIGTERM, 143),
        ):
            with self.subTest(signal=delivered.name):
                ready = self.root / f"ready-{delivered.name}"
                logs = self.root / f"logs-{delivered.name}"
                report = self.root / f"report-{delivered.name}"
                process = subprocess.Popen(
                    [
                        sys.executable, str(SCRIPT), "scan",
                        "--source-sha", SHA, "--pull-request", PR,
                        "--report", str(report), "--log-dir", str(logs),
                        "--", sys.executable, str(scanner),
                    ],
                    cwd=self.root,
                    env={**os.environ, "SONAR_TOKEN": "secret", "READY": str(ready)},
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None:
                    if time.monotonic() >= deadline:
                        process.terminate()
                        self.fail("fake scanner did not start")
                    time.sleep(0.02)
                scanner_pid = int(ready.read_text(encoding="utf-8"))
                process.send_signal(delivered)
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, expected, stdout + stderr)
                self.assertFalse(report.exists())
                self.assertFalse((logs / "attempt-2.log").exists())
                state = subprocess.run(
                    ["/bin/ps", "-p", str(scanner_pid), "-o", "state="],
                    capture_output=True, text=True, check=False,
                ).stdout.strip()
                self.assertTrue(not state or state.upper().startswith("Z"), state)

    def test_scan_cli_runs_fake_scanner_and_retains_fresh_exact_task(self) -> None:
        script = self.root / "fake-scanner.py"
        script.write_text(
            "import os\n"
            "from pathlib import Path\n"
            "report = Path(os.environ['REPORT_PATH'])\n"
            "report.parent.mkdir(parents=True)\n"
            f"report.write_text('projectKey={PROJECT}\\nceTaskId={TASK}\\n"
            "serverUrl=https://sonarcloud.io\\n"
            f"ceTaskUrl=https://sonarcloud.io/api/ce/task?id={TASK}\\n')\n"
            "print('ANALYSIS SUCCESSFUL')\n",
            encoding="utf-8",
        )
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "scan",
                "--source-sha",
                SHA,
                "--pull-request",
                PR,
                "--report",
                str(self.report),
                "--log-dir",
                str(self.logs),
                "--",
                sys.executable,
                str(script),
            ],
            cwd=self.root,
            env={**os.environ, "SONAR_TOKEN": "secret", "REPORT_PATH": str(self.report)},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(transport.read_report_task(self.report, PROJECT), TASK)
        self.assertIn("ANALYSIS SUCCESSFUL", (self.logs / "attempt-1.log").read_text())
        self.assertFalse((self.logs / "attempt-2.log").exists())


if __name__ == "__main__":
    unittest.main()
