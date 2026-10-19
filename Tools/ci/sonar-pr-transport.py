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

"""Retry only pre-submission Sonar PR transport errors; await an owned CE task."""

from __future__ import annotations

import argparse
import base64
import codecs
import json
import math
import os
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


PROJECT_KEY = "stephenlclarke_container-compose2"
TASK_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]+\Z")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
HTTP_TRANSIENT = re.compile(
    r"Caused by: .*HttpException: Error (?:502|503|504) on "
    r"https://(?:api\.)?sonarcloud\.io/"
)
PRECONNECT_TRANSIENT = re.compile(
    r"Caused by: java\.net\.(?:ConnectException|UnknownHostException|"
    r"NoRouteToHostException|SocketTimeoutException: connect timed out)"
)
POST_TASK_CONNECTION_TRANSIENT = re.compile(
    r"Caused by: (?:java\.net\.SocketTimeoutException: (?:Read|read) timed out|"
    r"java\.net\.SocketException: (?:Connection reset|Connection timed out))"
)
NONRETRYABLE = re.compile(
    r"QUALITY GATE STATUS: FAILED|(?:HTTP|Error) (?:400|401|403|404)\b|"
    r"(?:Authentication|Authorization|Not authorized|Invalid token|Invalid project key)",
    re.IGNORECASE,
)
MAX_ATTEMPTS = 3
TOTAL_SECONDS = 39 * 60  # Below the existing 40-minute GitHub scan-step deadline.
BACKOFF_SECONDS = (20, 40)
CE_POLL_SECONDS = 5


class TransportError(RuntimeError):
    """Fail closed on an invalid task boundary or non-transient result."""


def regular_file(path: Path) -> bool:
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except FileNotFoundError:
        return False


def read_report_task(report: Path, project_key: str) -> str:
    if not regular_file(report):
        raise TransportError("Sonar report task is missing or is not a regular file")
    values: dict[str, str] = {}
    for line in report.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in values:
            raise TransportError("Sonar report task contains malformed or duplicate keys")
        values[key] = value
    if values.get("projectKey") != project_key:
        raise TransportError("Sonar report task project does not match the expected project")
    task_id = values.get("ceTaskId", "")
    if TASK_ID_PATTERN.fullmatch(task_id) is None:
        raise TransportError("Sonar report task ID is invalid")
    server = urllib.parse.urlsplit(values.get("serverUrl", ""))
    task_url = urllib.parse.urlsplit(values.get("ceTaskUrl", ""))
    if (
        server.scheme != "https"
        or server.netloc != "sonarcloud.io"
        or server.path not in ("", "/")
        or server.query
        or server.fragment
        or task_url.scheme != "https"
        or task_url.netloc != "sonarcloud.io"
        or task_url.path != "/api/ce/task"
        or task_url.fragment
        or urllib.parse.parse_qs(task_url.query, strict_parsing=True)
        != {"id": [task_id]}
    ):
        raise TransportError("Sonar report task URLs do not bind the exact server and task")
    return task_id


def transient_scanner_failure(log: str, status: int, *, has_report: bool = False) -> bool:
    if status in (0, 124, 125, 70) or status < 0 or status >= 128 or NONRETRYABLE.search(log):
        return False
    causes = [line for line in log.splitlines() if "Caused by:" in line]
    terminal = causes[-1] if causes else log.splitlines()[-1] if log else ""
    return bool(
        HTTP_TRANSIENT.search(terminal)
        or PRECONNECT_TRANSIENT.search(terminal)
        or (has_report and POST_TASK_CONNECTION_TRANSIENT.search(terminal))
    )


def save_json_exclusive(path: Path, data: dict[str, object]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(data, stream, sort_keys=True)
        stream.write("\n")


def read_session(path: Path, source_sha: str, pull_request: str) -> float:
    if not regular_file(path):
        raise TransportError("Sonar transport session is missing or invalid")
    session = json.loads(path.read_text(encoding="utf-8"))
    if (
        session.get("source_sha") != source_sha
        or session.get("pull_request") != pull_request
        or session.get("project_key") != PROJECT_KEY
    ):
        raise TransportError("Sonar transport session identity does not match")
    deadline = session.get("deadline_monotonic")
    if not isinstance(deadline, (int, float)) or not math.isfinite(deadline):
        raise TransportError("Sonar transport session deadline is invalid")
    return float(deadline)


def run_scanner_once(
    command: list[str], log_path: Path, deadline: float, token: str
) -> tuple[int, str]:
    remaining = deadline - time.monotonic()
    if remaining <= 10:
        raise TransportError("Sonar transport budget exhausted before scanner start")
    deadline_runner = Path(__file__).with_name("run-command-with-deadline.py")
    supervised = [
        sys.executable,
        str(deadline_runner),
        "--seconds",
        str(remaining - 10),
        "--grace-seconds",
        "5",
        "--",
        *command,
    ]
    process: subprocess.Popen[bytes] | None = None
    forwarded_signal: int | None = None
    cancellation_deadline: float | None = None
    previous_handlers: dict[int, signal.Handlers] = {}

    def forward_signal(number: int, _frame: object) -> None:
        nonlocal forwarded_signal, cancellation_deadline
        if forwarded_signal is not None:
            return
        forwarded_signal = number
        cancellation_deadline = time.monotonic() + 20
        if process is not None:
            try:
                process.send_signal(number)
            except ProcessLookupError:
                pass

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous_handlers[number] = signal.signal(number, forward_signal)
    try:
        with log_path.open("x", encoding="utf-8") as stream:
            os.chmod(log_path, 0o600)
            process = subprocess.Popen(
                supervised,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if forwarded_signal is not None:
                process.send_signal(forwarded_signal)
            assert process.stdout is not None
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            pending = ""

            def emit(lines: str) -> None:
                clean = lines.replace(token, "[REDACTED]")
                stream.write(clean)
                stream.flush()
                sys.stdout.write(clean)
                sys.stdout.flush()

            with process.stdout:
                while True:
                    if cancellation_deadline is not None and time.monotonic() >= cancellation_deadline:
                        raise TransportError("Sonar supervisor did not stop after cancellation")
                    ready, _, _ = select.select([process.stdout], [], [], 0.2)
                    if not ready:
                        continue
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    pending += decoder.decode(chunk)
                    while "\n" in pending:
                        line, pending = pending.split("\n", 1)
                        emit(line + "\n")
                pending += decoder.decode(b"", final=True)
                if pending:
                    emit(pending)
            status = process.wait(timeout=20 if forwarded_signal is not None else None)
    finally:
        if process is not None and process.poll() is None:
            try:
                process.send_signal(forwarded_signal or signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    if forwarded_signal is not None:
        return 128 + forwarded_signal, log_path.read_text(encoding="utf-8")
    return status, log_path.read_text(encoding="utf-8")


def run_scan(
    *,
    source_sha: str,
    pull_request: str,
    report: Path,
    log_dir: Path,
    command: list[str],
    token: str,
) -> int:
    if report.exists() or report.is_symlink():
        raise TransportError("Sonar report task existed before this scan")
    if log_dir.exists():
        raise TransportError("Sonar attempt-log directory existed before this scan")
    log_dir.mkdir(mode=0o700, parents=True)
    deadline = time.monotonic() + TOTAL_SECONDS
    save_json_exclusive(
        log_dir / "session.json",
        {
            "source_sha": source_sha,
            "pull_request": pull_request,
            "project_key": PROJECT_KEY,
            "deadline_monotonic": deadline,
        },
    )
    for attempt in range(1, MAX_ATTEMPTS + 1):
        log_path = log_dir / f"attempt-{attempt}.log"
        status, log = run_scanner_once(command, log_path, deadline, token)
        if time.monotonic() >= deadline:
            raise TransportError("Sonar transport budget expired during scanner attempt")
        has_report = report.exists() or report.is_symlink()
        if has_report:
            task_id = read_report_task(report, PROJECT_KEY)
            print(f"Sonar attempt {attempt} produced exact CE task {task_id}")
        if status == 0:
            if not has_report:
                raise TransportError("Sonar scanner succeeded without a CE task report")
            return 0
        transient = transient_scanner_failure(log, status, has_report=has_report)
        if has_report:
            if transient:
                print("Scanner transport failed after CE submission; awaiting that task")
                return 0
            return status
        if not transient or attempt == MAX_ATTEMPTS:
            return status
        pause = BACKOFF_SECONDS[attempt - 1]
        if time.monotonic() + pause + 10 >= deadline:
            raise TransportError("Sonar transport budget exhausted before retry")
        print(
            "Sonar transport failure before CE submission; "
            f"retrying {attempt + 1}/{MAX_ATTEMPTS}"
        )
        time.sleep(pause)
    raise AssertionError("unreachable scanner attempt state")


def fetch_task(task_id: str, token: str, timeout: float) -> dict[str, object]:
    query = urllib.parse.urlencode({"id": task_id})
    request = urllib.request.Request(f"https://sonarcloud.io/api/ce/task?{query}")
    credentials = base64.b64encode(f"{token}:".encode("utf-8")).decode("ascii")
    request.add_header("Authorization", f"Basic {credentials}")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def transient_request_error(error: Exception) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code in (502, 503, 504)
    if isinstance(error, urllib.error.URLError):
        return isinstance(
            error.reason,
            (ConnectionError, TimeoutError, socket.gaierror),
        )
    return isinstance(error, (ConnectionError, TimeoutError))


def wait_task(
    *, report: Path, session: Path, source_sha: str, pull_request: str, token: str
) -> dict[str, object]:
    deadline = read_session(session, source_sha, pull_request)
    task_id = read_report_task(report, PROJECT_KEY)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportError("Exact Sonar CE task did not complete within the shared budget")
        try:
            payload = fetch_task(task_id, token, min(10, remaining))
        except (urllib.error.URLError, ConnectionError, TimeoutError) as error:
            if not transient_request_error(error):
                raise TransportError("Exact Sonar CE task request failed permanently") from error
            print("Transient CE task request failure; polling the same task", file=sys.stderr)
        else:
            if time.monotonic() >= deadline:
                raise TransportError("Exact Sonar CE task completed after the shared budget")
            task = payload.get("task") if isinstance(payload, dict) else None
            if not isinstance(task, dict):
                raise TransportError("Sonar CE response is missing the exact task")
            if task.get("id") != task_id or task.get("componentKey") != PROJECT_KEY:
                raise TransportError("Sonar CE task identity does not match")
            status = task.get("status")
            if status == "SUCCESS":
                analysis_id = task.get("analysisId")
                if not isinstance(analysis_id, str) or not analysis_id:
                    raise TransportError("Successful Sonar CE task has no analysis ID")
                return {
                    "task": {
                        "id": task_id,
                        "componentKey": PROJECT_KEY,
                        "status": status,
                        "analysisId": analysis_id,
                    }
                }
            if status not in ("PENDING", "IN_PROGRESS"):
                raise TransportError(f"Exact Sonar CE task ended with {status!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportError("Exact Sonar CE task did not complete within the shared budget")
        time.sleep(min(CE_POLL_SECONDS, remaining))


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    for name in ("scan", "wait-task"):
        mode = modes.add_parser(name)
        mode.add_argument("--source-sha", required=True)
        mode.add_argument("--pull-request", required=True)
        mode.add_argument("--report", type=Path, required=True)
        mode.add_argument("--log-dir", type=Path, required=True)
        if name == "scan":
            mode.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(arguments)
    if SHA_PATTERN.fullmatch(options.source_sha) is None:
        parser.error("--source-sha must be a lowercase 40-character SHA")
    if not options.pull_request.isdigit() or int(options.pull_request) < 1:
        parser.error("--pull-request must be a positive integer")
    token = os.environ.get("SONAR_TOKEN", "")
    if not token:
        parser.error("SONAR_TOKEN is required")
    try:
        if options.mode == "scan":
            command = options.command
            if command[:1] == ["--"]:
                command = command[1:]
            if not command:
                parser.error("scan requires a scanner command after --")
            return run_scan(
                source_sha=options.source_sha,
                pull_request=options.pull_request,
                report=options.report,
                log_dir=options.log_dir,
                command=command,
                token=token,
            )
        result = wait_task(
            report=options.report,
            session=options.log_dir / "session.json",
            source_sha=options.source_sha,
            pull_request=options.pull_request,
            token=token,
        )
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, TransportError) as error:
        print(f"sonar-pr-transport: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
