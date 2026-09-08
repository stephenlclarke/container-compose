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

"""Persist host restoration authority across release-controller processes."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


SCHEMA = 1
ROOT_MARKER = ".container-compose-release-host-state"
ROOT_MARKER_VALUE = "container-compose release host state v1\n"
JOURNAL = "quiesced-launch-agents.json"
LABEL = re.compile(r"^[A-Za-z0-9._-]+$")


class HostStateError(RuntimeError):
    """Raised when durable host state cannot be trusted or updated."""


@dataclass(frozen=True)
class LaunchAgent:
    """One launch agent that must be restored after release validation."""

    label: str
    plist: str


def validate_launch_agent(label: str, plist: str) -> LaunchAgent:
    """Return a normalized launch-agent entry or reject unsafe input."""

    if not LABEL.fullmatch(label):
        raise HostStateError(f"invalid launch-agent label: {label!r}")
    if not plist.startswith("/") or "\n" in plist or "\t" in plist:
        raise HostStateError(f"invalid launch-agent plist path: {plist!r}")
    if Path(plist).name != f"{label}.plist":
        raise HostStateError(
            f"launch-agent plist does not match label {label}: {plist}"
        )
    return LaunchAgent(label=label, plist=plist)


def require_regular_private_file(path: Path, description: str) -> os.stat_result:
    """Require one user-owned regular file with no group or other access."""

    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise HostStateError(f"missing {description}: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise HostStateError(f"untrusted {description}: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise HostStateError(f"insecure permissions on {description}: {path}")
    return metadata


def path_exists_without_following_links(path: Path) -> bool:
    """Return whether a directory entry exists, including a dangling link."""

    try:
        path.lstat()
    except FileNotFoundError:
        return False
    return True


def write_new_private_file(path: Path, content: bytes) -> None:
    """Create one private file without following an existing link."""

    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def fsync_directory(path: Path) -> None:
    """Make a journal rename or removal durable in its containing directory."""

    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def require_state_root(root: Path) -> Path:
    """Create or validate the private marker-protected host-state root."""

    if not root.is_absolute() or root == Path("/"):
        raise HostStateError(f"host-state root must be an absolute child path: {root}")
    try:
        root.mkdir(mode=0o700)
        fsync_directory(root.parent)
    except FileExistsError:
        pass
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise HostStateError(f"untrusted host-state root: {root}")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise HostStateError(f"insecure permissions on host-state root: {root}")

    marker = root / ROOT_MARKER
    if not path_exists_without_following_links(marker):
        write_new_private_file(marker, ROOT_MARKER_VALUE.encode("utf-8"))
        fsync_directory(root)
    require_regular_private_file(marker, "host-state marker")
    if marker.read_text(encoding="utf-8") != ROOT_MARKER_VALUE:
        raise HostStateError(f"invalid host-state marker: {marker}")
    return root


def load_launch_agents(root: Path) -> list[LaunchAgent]:
    """Read and validate the complete retained restoration journal."""

    root = require_state_root(root)
    journal = root / JOURNAL
    if not path_exists_without_following_links(journal):
        return []
    require_regular_private_file(journal, "host-state journal")
    try:
        payload = json.loads(journal.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise HostStateError(f"invalid host-state journal: {journal}") from error
    if not isinstance(payload, dict) or set(payload) != {
        "entries",
        "ownerUid",
        "schema",
    }:
        raise HostStateError(f"invalid host-state journal structure: {journal}")
    if payload["schema"] != SCHEMA or payload["ownerUid"] != os.getuid():
        raise HostStateError(f"host-state journal identity does not match: {journal}")
    if not isinstance(payload["entries"], list):
        raise HostStateError(f"invalid host-state journal entries: {journal}")

    entries: list[LaunchAgent] = []
    for item in payload["entries"]:
        if not isinstance(item, dict) or set(item) != {"label", "plist"}:
            raise HostStateError(f"invalid host-state journal entry: {journal}")
        if not isinstance(item["label"], str) or not isinstance(item["plist"], str):
            raise HostStateError(f"invalid host-state journal value: {journal}")
        entries.append(validate_launch_agent(item["label"], item["plist"]))
    if len({entry.label for entry in entries}) != len(entries):
        raise HostStateError(f"duplicate launch-agent journal entry: {journal}")
    return entries


def store_launch_agents(root: Path, entries: Sequence[LaunchAgent]) -> None:
    """Atomically replace the retained restoration journal."""

    root = require_state_root(root)
    journal = root / JOURNAL
    if not entries:
        if path_exists_without_following_links(journal):
            require_regular_private_file(journal, "host-state journal")
            journal.unlink()
            fsync_directory(root)
        return

    if path_exists_without_following_links(journal):
        require_regular_private_file(journal, "host-state journal")

    payload = {
        "entries": [
            {"label": entry.label, "plist": entry.plist}
            for entry in entries
        ],
        "ownerUid": os.getuid(),
        "schema": SCHEMA,
    }
    descriptor, temporary_name = tempfile.mkstemp(prefix=".host-state.", dir=root)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=False) as stream:
            json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, journal)
        fsync_directory(root)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def record_launch_agent(root: Path, entry: LaunchAgent) -> None:
    """Durably retain restoration authority before host mutation."""

    entries = load_launch_agents(root)
    existing = next((item for item in entries if item.label == entry.label), None)
    if existing is not None and existing != entry:
        raise HostStateError(
            f"launch-agent journal already maps {entry.label} to {existing.plist}"
        )
    if existing is None:
        store_launch_agents(root, [*entries, entry])


def remove_launch_agent(root: Path, entry: LaunchAgent) -> None:
    """Discard restoration authority only after the service is healthy."""

    entries = load_launch_agents(root)
    existing = next((item for item in entries if item.label == entry.label), None)
    if existing is not None and existing != entry:
        raise HostStateError(
            f"launch-agent journal maps {entry.label} to {existing.plist}"
        )
    store_launch_agents(root, [item for item in entries if item != entry])


def parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""

    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, required=True)
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    for name in ("record", "remove"):
        command = commands.add_parser(name)
        command.add_argument("--label", required=True)
        command.add_argument("--plist", required=True)
    return result


def main(arguments: Sequence[str]) -> int:
    """Execute one host-state journal operation."""

    options = parser().parse_args(arguments)
    try:
        if options.command == "list":
            for entry in load_launch_agents(options.root):
                print(f"{entry.label}\t{entry.plist}")
        else:
            entry = validate_launch_agent(options.label, options.plist)
            if options.command == "record":
                record_launch_agent(options.root, entry)
            else:
                remove_launch_agent(options.root, entry)
    except (HostStateError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
