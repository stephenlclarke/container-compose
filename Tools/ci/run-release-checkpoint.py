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
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO

SCHEMA_VERSION = 3
FAILURE_TAIL_BYTES = 32 * 1024
FAILURE_TAIL_LINES = 80
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
    parser.add_argument("--active-output", default="", help=argparse.SUPPRESS)
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
    if options.active_output and not options.supervised_worker:
        parser.error("--active-output is reserved for the supervised worker")
    return options


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError(f"release checkpoint output is not regular: {path}")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


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


def checkpoint_output_is_valid(
    checkpoint: dict[str, object], output_path: Path
) -> bool:
    recorded_digest = checkpoint.get("output_sha256")
    if checkpoint.get("schema") != SCHEMA_VERSION:
        return False
    if checkpoint.get("output_file") != output_path.name:
        return False
    if not isinstance(recorded_digest, str) or len(recorded_digest) != 64:
        return False
    if any(character not in "0123456789abcdef" for character in recorded_digest):
        return False
    try:
        return sha256_file(output_path) == recorded_digest
    except OSError:
        return False


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


def open_stage_output(output_path: Path) -> BinaryIO:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(output_path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError(
                f"release checkpoint output is not regular: {output_path}"
            )
        return os.fdopen(descriptor, "wb")
    except BaseException:
        os.close(descriptor)
        raise


def run_stage_command(command: Sequence[str], output_path: Path | None) -> int:
    output: BinaryIO | None = None
    if output_path is not None:
        try:
            output = open_stage_output(output_path)
        except OSError as error:
            print(
                f"could not create release checkpoint output: {error}",
                file=sys.stderr,
            )
            return 74
    try:
        if output is None:
            return normalized_exit_status(
                subprocess.run(command, check=False).returncode
            )
        with output:
            return normalized_exit_status(
                subprocess.run(
                    command,
                    check=False,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                ).returncode
            )
    except FileNotFoundError:
        print(f"command was not found: {command[0]}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"command is not executable: {command[0]}", file=sys.stderr)
        return 126
    except OSError as error:
        print(f"could not run release checkpoint stage: {error}", file=sys.stderr)
        return 74


def normalized_exit_status(return_code: int) -> int:
    return 128 - return_code if return_code < 0 else return_code


def print_failure_tail(
    path: Path,
    line_count: int = FAILURE_TAIL_LINES,
    byte_count: int = FAILURE_TAIL_BYTES,
) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return
        offset = max(0, metadata.st_size - byte_count)
        os.lseek(descriptor, offset, os.SEEK_SET)
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            output = stream.read(byte_count)
    except OSError:
        return
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    lines = output.decode("utf-8", errors="replace").splitlines()
    retained_lines = lines[-line_count:]
    print(
        f"last {len(retained_lines)} output lines from {path.name} "
        f"(limited to {byte_count} bytes):",
        file=sys.stderr,
    )
    if offset > 0:
        print("[earlier output omitted]", file=sys.stderr)
    for line in retained_lines:
        print(line, file=sys.stderr)


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
    output_path = (
        checkpoint_directory / f"{options.stage}.{digest}.log"
        if checkpoint_directory is not None
        else None
    )
    active_output_path = None
    if options.active_output:
        assert checkpoint_directory is not None
        active_output_path = Path(options.active_output).expanduser().resolve()
        expected_prefix = f".{options.stage}.active-"
        if (
            active_output_path.parent != checkpoint_directory
            or not active_output_path.name.startswith(expected_prefix)
            or not active_output_path.name.endswith(".log")
        ):
            print(
                "supervised output path is outside its checkpoint stage",
                file=sys.stderr,
            )
            return 2
    if success_path is not None:
        checkpoint = read_checkpoint(success_path)
        if checkpoint is not None and checkpoint.get("digest") == digest:
            assert output_path is not None
            if checkpoint_output_is_valid(checkpoint, output_path):
                print(f"reusing exact-input release checkpoint: {options.stage}")
                return 0
            print(
                "invalidating release checkpoint with missing or changed "
                f"output: {options.stage}"
            )
            try:
                success_path.unlink(missing_ok=True)
            except OSError as error:
                print(
                    f"could not invalidate release checkpoint: {error}",
                    file=sys.stderr,
                )
                return 74

    stage_output_path = active_output_path or output_path
    if stage_output_path is not None:
        print(
            f"running release checkpoint {options.stage}; durable output: "
            f"{stage_output_path}"
        )
    status = run_stage_command(options.command, stage_output_path)
    retained_output_path = stage_output_path
    if (
        active_output_path is not None
        and output_path is not None
        and active_output_path.is_file()
    ):
        try:
            os.replace(active_output_path, output_path)
            retained_output_path = output_path
        except OSError as error:
            print(
                f"could not retain release checkpoint output: {error}",
                file=sys.stderr,
            )
            if status == 0:
                status = 74
    output_digest = None
    output_file = None
    if retained_output_path is not None:
        try:
            output_digest = sha256_file(retained_output_path)
            output_file = retained_output_path.name
        except OSError as error:
            print(
                f"could not verify release checkpoint output: {error}",
                file=sys.stderr,
            )
            if status == 0:
                status = 74
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
    if output_digest is not None and output_file is not None:
        result["output_sha256"] = output_digest
        result["output_file"] = output_file
    if result_path is not None:
        write_json_atomically(result_path, result)
    if status == 0 and success_path is not None:
        write_json_atomically(success_path, result)
    elif status != 0 and retained_output_path is not None:
        print_failure_tail(retained_output_path)
    return status


def run(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    if options.supervised_worker:
        return run_supervised(options)

    active_output_path = None
    worker_arguments = [
        sys.executable,
        os.path.abspath(__file__),
        "--supervised-worker",
    ]
    if options.checkpoint_dir:
        checkpoint_directory = Path(options.checkpoint_dir).expanduser().resolve()
        active_output_path = checkpoint_directory / (
            f".{options.stage}.active-{os.getpid()}-{secrets.token_hex(8)}.log"
        )
        worker_arguments.extend(["--active-output", str(active_output_path)])
    worker_arguments.extend(arguments)
    deadline_arguments = [
        sys.executable,
        os.path.abspath(DEADLINE_RUNNER),
        "--seconds",
        str(options.seconds),
        "--",
        *worker_arguments,
    ]
    forwarded_signal: int | None = None
    deadline_process: subprocess.Popen[bytes] | None = None
    previous_handlers: dict[int, signal.Handlers] = {}
    forwarded_signals = (
        signal.SIGHUP,
        signal.SIGINT,
        signal.SIGQUIT,
        signal.SIGTERM,
    )

    def forward_signal(number: int, _frame: object) -> None:
        nonlocal forwarded_signal
        if forwarded_signal is not None:
            return
        forwarded_signal = number
        if deadline_process is None:
            return
        try:
            deadline_process.send_signal(number)
        except ProcessLookupError:
            pass

    for number in forwarded_signals:
        previous_handlers[number] = signal.signal(number, forward_signal)
    try:
        deadline_process = subprocess.Popen(deadline_arguments)
        if forwarded_signal is not None:
            try:
                deadline_process.send_signal(forwarded_signal)
            except ProcessLookupError:
                pass
        return_code = deadline_process.wait()
    except FileNotFoundError:
        print(f"control Python was not found: {sys.executable}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"control Python is not executable: {sys.executable}", file=sys.stderr)
        return 126
    except OSError as error:
        print(f"could not start the deadline controller: {error}", file=sys.stderr)
        return 74
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    status = normalized_exit_status(return_code)
    if forwarded_signal is not None and status == 0:
        status = 128 + forwarded_signal
    if status == 124 and active_output_path is not None:
        print_failure_tail(active_output_path)
    return status


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
