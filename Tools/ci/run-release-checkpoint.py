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

"""Run one release DAG stage with a content-addressed success checkpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 2
DEADLINE_RUNNER = Path(__file__).with_name("run-command-with-deadline.py")


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint-dir", default="")
    parser.add_argument("--stage", required=True)
    fingerprint = parser.add_mutually_exclusive_group(required=True)
    fingerprint.add_argument("--fingerprint")
    fingerprint.add_argument("--fingerprint-command")
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument(
        "--supervised-worker", action="store_true", help=argparse.SUPPRESS
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(arguments)
    if options.command[:1] == ["--"]:
        options.command = options.command[1:]
    if not options.stage or any(
        character not in "abcdefghijklmnopqrstuvwxyz0123456789-_."
        for character in options.stage
    ):
        parser.error("--stage must use lowercase letters, digits, dash, dot, or underscore")
    if options.seconds <= 0:
        parser.error("--seconds must be greater than zero")
    if options.fingerprint == "":
        parser.error("--fingerprint must not be empty")
    if not options.command:
        parser.error("a command is required after --")
    return options


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def stage_digest(
    stage: str, fingerprint: str, seconds: int, command: Sequence[str]
) -> str:
    encoded = json.dumps(
        {
            "command": list(command),
            "fingerprint": fingerprint,
            "seconds": seconds,
            "schema": SCHEMA_VERSION,
            "stage": stage,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def read_checkpoint(path: Path) -> dict[str, object] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(value, dict):
        return None
    return value


def write_json_atomically(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def run_fingerprint_command(command: str) -> tuple[int, str | None]:
    try:
        completed = subprocess.run(
            [command],
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        print(f"fingerprint command was not found: {command}", file=sys.stderr)
        return 127, None
    except PermissionError:
        print(f"fingerprint command is not executable: {command}", file=sys.stderr)
        return 126, None
    if completed.returncode != 0:
        return normalized_exit_status(completed.returncode), None
    lines = [line for line in completed.stdout.splitlines() if line]
    if len(lines) != 1:
        print(
            "fingerprint command must emit exactly one non-empty line",
            file=sys.stderr,
        )
        return 2, None
    return 0, lines[0]


def run_stage_command(command: Sequence[str]) -> int:
    try:
        return normalized_exit_status(
            subprocess.run(command, check=False).returncode
        )
    except FileNotFoundError:
        print(f"command was not found: {command[0]}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"command is not executable: {command[0]}", file=sys.stderr)
        return 126


def normalized_exit_status(return_code: int) -> int:
    return 128 - return_code if return_code < 0 else return_code


def run_supervised(options: argparse.Namespace) -> int:
    started_at = utc_timestamp()
    started = time.monotonic()
    fingerprint = options.fingerprint
    if options.fingerprint_command is not None:
        fingerprint_status, fingerprint = run_fingerprint_command(
            options.fingerprint_command
        )
        if fingerprint_status != 0:
            return fingerprint_status
    assert fingerprint is not None

    digest = stage_digest(
        options.stage, fingerprint, options.seconds, options.command
    )
    checkpoint_directory = (
        Path(options.checkpoint_dir).expanduser().resolve()
        if options.checkpoint_dir
        else None
    )
    if checkpoint_directory == Path("/"):
        print("checkpoint directory must not resolve to /", file=sys.stderr)
        return 2
    success_path = (
        checkpoint_directory / f"{options.stage}.success.json"
        if checkpoint_directory is not None
        else None
    )
    result_path = (
        checkpoint_directory / f"{options.stage}.last.json"
        if checkpoint_directory is not None
        else None
    )
    if success_path is not None:
        checkpoint = read_checkpoint(success_path)
        if checkpoint is not None and checkpoint.get("digest") == digest:
            print(f"reusing exact-input release checkpoint: {options.stage}")
            return 0

    status = run_stage_command(options.command)
    result: dict[str, object] = {
        "command_sha256": hashlib.sha256(
            json.dumps(options.command, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "digest": digest,
        "duration_seconds": round(time.monotonic() - started, 6),
        "executable": options.command[0],
        "finished_at": utc_timestamp(),
        "fingerprint": fingerprint,
        "schema": SCHEMA_VERSION,
        "seconds": options.seconds,
        "stage": options.stage,
        "started_at": started_at,
        "status": status,
    }
    if result_path is not None:
        write_json_atomically(result_path, result)
    if status == 0 and success_path is not None:
        write_json_atomically(success_path, result)
    return status


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    if options.supervised_worker:
        return run_supervised(options)

    worker_arguments = [
        sys.executable,
        os.path.abspath(__file__),
        "--supervised-worker",
        *arguments,
    ]
    deadline_arguments = [
        sys.executable,
        os.path.abspath(DEADLINE_RUNNER),
        "--seconds",
        str(options.seconds),
        "--",
        *worker_arguments,
    ]
    try:
        os.execv(sys.executable, deadline_arguments)
    except FileNotFoundError:
        print(f"control Python was not found: {sys.executable}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"control Python is not executable: {sys.executable}", file=sys.stderr)
        return 126


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
