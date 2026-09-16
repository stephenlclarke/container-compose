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

"""Plan or remove only marker-owned transient Container-family build data."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path


MARKER = ".container-family-transient-root"
MARKER_VALUE = "container-compose transient build v2\n"
REMOVABLE = (
    "attempts",
    "builds",
    "downloads",
    "process-tmp",
    "scratch",
    "tmp",
)
RECREATABLE = frozenset(("process-tmp", "scratch"))


class CleanupError(RuntimeError):
    """Transient cleanup could not prove a target is safe."""


@dataclass(frozen=True)
class CleanupRecord:
    path: str
    disposition: str


def validate_root(root: Path) -> Path:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise CleanupError(f"unsafe transient root: {root}")
    normalized = Path(os.path.abspath(root))
    resolved = root.resolve(strict=True)
    if resolved != normalized:
        raise CleanupError(f"transient root contains a symbolic link: {root}")
    marker = resolved / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise CleanupError(f"transient root has no regular ownership marker: {resolved}")
    if marker.read_text(encoding="utf-8") != MARKER_VALUE:
        raise CleanupError(f"transient root has an unexpected ownership marker: {resolved}")
    return resolved


def remove_entry(parent_descriptor: int, name: str) -> None:
    """Remove one entry relative to an opened parent without following links."""
    status = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if not stat.S_ISDIR(status.st_mode):
        os.unlink(name, dir_fd=parent_descriptor)
        return

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        entries = list(os.scandir(descriptor))
        for entry in entries:
            remove_entry(descriptor, entry.name)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent_descriptor)


def remove_tree(path: Path) -> None:
    """Remove a direct child through an opened, no-follow parent descriptor."""
    parent = path.parent
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(parent, flags)
    try:
        remove_entry(descriptor, path.name)
    finally:
        os.close(descriptor)


def targets(root: Path) -> list[Path]:
    resolved = validate_root(root)
    selected: list[Path] = []
    for name in REMOVABLE:
        candidate = resolved / name
        try:
            candidate.lstat()
        except FileNotFoundError:
            continue
        selected.append(candidate)
    return selected


def recreate_directories(
    root: Path, names: list[str], completed: list[str] | None = None
) -> list[str]:
    """Recreate only build-owned live directories below the validated root."""
    recreated = completed if completed is not None else []
    for name in names:
        if name not in RECREATABLE:
            raise CleanupError(f"unsupported recreated transient path: {name}")
        destination = root / name
        if destination.exists() or destination.is_symlink():
            raise CleanupError(f"recreated transient path still exists: {destination}")
        destination.mkdir(mode=0o700)
        recreated.append(name)
    return recreated


def render_report(
    root: Path,
    *,
    execute: bool,
    phase: str,
    records: list[CleanupRecord],
    error: str | None = None,
) -> str:
    """Render one human-readable cleanup receipt."""
    lines = [
        "# Stack transient cleanup",
        "",
        f"- Root: `{root}`",
        f"- Mode: `{'apply' if execute else 'plan'}`",
        f"- Phase: `{phase}`",
        f"- Status: `{'failed' if error else 'success'}`",
        f"- Generated: `{datetime.now(UTC).isoformat()}`",
    ]
    if error:
        escaped_error = error.replace("`", "\\`")
        lines.append(f"- Error: `{escaped_error}`")
    lines.extend(("", "| Disposition | Path |", "| --- | --- |"))
    if not records:
        lines.append("| clean | — |")
    for record in records:
        lines.append(
            f"| {record.disposition.replace('|', '\\|')} | "
            f"{record.path.replace('|', '\\|')} |"
        )
    return "\n".join(lines) + "\n"


def write_atomic(path: Path | None, contents: str) -> None:
    """Write a cleanup receipt without exposing a partial file."""
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_receipts(
    *,
    root: Path,
    execute: bool,
    phase: str,
    records: list[CleanupRecord],
    recreated: list[str],
    report_path: Path | None,
    json_path: Path | None,
    error: str | None = None,
) -> None:
    """Persist successful or partial cleanup evidence atomically."""
    report = render_report(
        root,
        execute=execute,
        phase=phase,
        records=records,
        error=error,
    )
    payload = {
        "schema": 1,
        "root": str(root),
        "mode": "apply" if execute else "plan",
        "phase": phase,
        "status": "failed" if error else "success",
        "generatedAt": datetime.now(UTC).isoformat(),
        "entries": [asdict(record) for record in records],
        "recreated": recreated,
    }
    if error:
        payload["error"] = error
    write_atomic(report_path, report)
    write_atomic(json_path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--recreate", action="append", default=[])
    parser.add_argument("--phase", default="manual")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--json-output", type=Path)
    options = parser.parse_args(arguments)
    resolved = options.root
    records: list[CleanupRecord] = []
    recreated: list[str] = []
    try:
        resolved = validate_root(options.root)
        if options.recreate and not options.execute:
            raise CleanupError("--recreate requires --execute")
        selected = targets(resolved)
        for target in selected:
            print(target)
            if options.execute:
                remove_tree(target)
                disposition = "removed"
            else:
                disposition = "candidate"
            records.append(CleanupRecord(str(target), disposition))
        recreate_directories(resolved, options.recreate, recreated)
        write_receipts(
            root=resolved,
            execute=options.execute,
            phase=options.phase,
            records=records,
            recreated=recreated,
            report_path=options.report,
            json_path=options.json_output,
        )
    except (CleanupError, OSError, UnicodeError) as error:
        try:
            write_receipts(
                root=resolved,
                execute=options.execute,
                phase=options.phase,
                records=records,
                recreated=recreated,
                report_path=options.report,
                json_path=options.json_output,
                error=str(error),
            )
        except (OSError, UnicodeError) as receipt_error:
            print(
                f"stack-transient-clean: could not persist failure receipt: {receipt_error}",
                file=sys.stderr,
            )
        print(f"stack-transient-clean: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
