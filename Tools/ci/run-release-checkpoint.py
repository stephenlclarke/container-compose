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
from datetime import UTC, datetime
from pathlib import Path

SCHEMA_VERSION = 1
DEADLINE_RUNNER = Path(__file__).with_name("run-command-with-deadline.py")


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint-dir", default="")
    parser.add_argument("--stage", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--seconds", type=int, required=True)
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
    if not options.command:
        parser.error("a command is required after --")
    return options


def utc_timestamp() -> str:
    return datetime.now(UTC).isoformat()


def stage_digest(stage: str, fingerprint: str, command: Sequence[str]) -> str:
    encoded = json.dumps(
        {
            "command": list(command),
            "fingerprint": fingerprint,
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


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    digest = stage_digest(options.stage, options.fingerprint, options.command)
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

    started_at = utc_timestamp()
    started = time.monotonic()
    completed = subprocess.run(
        [
            sys.executable,
            str(DEADLINE_RUNNER),
            "--seconds",
            str(options.seconds),
            "--",
            *options.command,
        ],
        check=False,
    )
    result: dict[str, object] = {
        "command_sha256": hashlib.sha256(
            json.dumps(options.command, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "digest": digest,
        "duration_seconds": round(time.monotonic() - started, 6),
        "executable": options.command[0],
        "finished_at": utc_timestamp(),
        "fingerprint": options.fingerprint,
        "schema": SCHEMA_VERSION,
        "stage": options.stage,
        "started_at": started_at,
        "status": completed.returncode,
    }
    if result_path is not None:
        write_json_atomically(result_path, result)
    if completed.returncode == 0 and success_path is not None:
        write_json_atomically(success_path, result)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
