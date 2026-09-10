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

"""Atomically retain workflow dispatch intent and acknowledgement records."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


REQUEST_PATTERN = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")
VERSION_PATTERN = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")


class JournalError(RuntimeError):
    """The dispatch journal operation is invalid or unsafe."""


def write(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def record_path(root: Path, request_id: str) -> Path:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise JournalError(f"unsafe dispatch journal root: {root}")
    if not REQUEST_PATTERN.fullmatch(request_id):
        raise JournalError(f"invalid dispatch request ID: {request_id}")
    return root / "release" / "dispatches" / f"{request_id}.json"


def validate_record(value: object, request_id: str) -> dict[str, object]:
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise JournalError("dispatch journal has an unsupported schema")
    if value.get("request_id") != request_id:
        raise JournalError("dispatch journal request ID does not match its path")
    if not VERSION_PATTERN.fullmatch(str(value.get("version", ""))):
        raise JournalError("dispatch journal has an invalid release version")
    if not re.fullmatch(r"[0-9a-f]{40}", str(value.get("control_sha", ""))):
        raise JournalError("dispatch journal has an invalid control SHA")
    workflow = value.get("workflow")
    if not isinstance(workflow, str) or not workflow or len(workflow) > 200:
        raise JournalError("dispatch journal has an invalid workflow")
    if value.get("state") not in {
        "dispatch-intent",
        "dispatch-unknown",
        "dispatched",
    }:
        raise JournalError("dispatch journal has an invalid state")
    return value


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("intent", "unknown", "ack"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--workflow")
    parser.add_argument("--version")
    parser.add_argument("--control-sha")
    parser.add_argument("--run-id")
    options = parser.parse_args(arguments)
    try:
        path = record_path(options.root, options.request_id)
        if options.action == "intent":
            if path.exists():
                raise JournalError(f"dispatch request already exists: {options.request_id}")
            if (
                not options.workflow
                or len(options.workflow) > 200
                or VERSION_PATTERN.fullmatch(options.version or "") is None
                or not re.fullmatch(r"[0-9a-f]{40}", options.control_sha or "")
            ):
                raise JournalError("dispatch intent is missing workflow/version/control")
            value: dict[str, object] = {
                "control_sha": options.control_sha,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "request_id": options.request_id,
                "schema": 1,
                "state": "dispatch-intent",
                "version": options.version,
                "workflow": options.workflow,
            }
        elif options.action == "unknown":
            if not path.is_file() or path.is_symlink():
                raise JournalError(f"dispatch intent is unavailable: {options.request_id}")
            value = validate_record(
                json.loads(path.read_text(encoding="utf-8")), options.request_id
            )
            if value.get("state") != "dispatch-intent":
                raise JournalError("dispatch journal is not awaiting a response")
            value["unknown_at"] = datetime.now(timezone.utc).isoformat()
            value["state"] = "dispatch-unknown"
        else:
            if not path.is_file() or path.is_symlink():
                raise JournalError(f"dispatch intent is unavailable: {options.request_id}")
            value = validate_record(
                json.loads(path.read_text(encoding="utf-8")), options.request_id
            )
            if value.get("state") not in {
                "dispatch-intent",
                "dispatch-unknown",
            }:
                raise JournalError("dispatch journal is not awaiting acknowledgement")
            if not re.fullmatch(r"[0-9]+", options.run_id or ""):
                raise JournalError(f"invalid workflow run ID: {options.run_id}")
            value["acknowledged_at"] = datetime.now(timezone.utc).isoformat()
            value["run_id"] = options.run_id
            value["state"] = "dispatched"
        write(path, value)
    except (JournalError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"release-dispatch-journal: {error}", file=sys.stderr)
        return 2
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
