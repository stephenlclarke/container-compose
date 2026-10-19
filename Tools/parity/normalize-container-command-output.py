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

"""Canonicalize only selected Container executable tokens in assertion copies."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import uuid


LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
WHITESPACE = b" \t\r\n"


def first_token_end(line: bytes) -> int:
    """Find the first shell token's byte boundary without touching its suffix."""
    position = 2
    quote = 0
    while position < len(line):
        character = line[position]
        if quote == 0:
            if character in WHITESPACE:
                break
            if character in (ord("'"), ord('"')):
                quote = character
            elif character == ord("\\"):
                position += 1
                if position == len(line):
                    raise ValueError("Incomplete first shell token")
        elif quote == ord("'"):
            if character == quote:
                quote = 0
        elif character == quote:
            quote = 0
        elif character == ord("\\"):
            position += 1
            if position == len(line):
                raise ValueError("Incomplete first shell token")
        position += 1
    if quote or position == 2:
        raise ValueError("Malformed first shell token")
    return position


def canonicalize(raw: bytes, selected: str) -> tuple[bytes, int]:
    if not selected or "\x00" in selected:
        raise ValueError("Selected Container executable is empty or invalid")
    result = bytearray()
    replacements = 0
    for line in raw.splitlines(keepends=True):
        if not line.startswith(b"+ "):
            result.extend(line)
            continue
        end = first_token_end(line)
        try:
            tokens = shlex.split(line[2:end].decode("utf-8"), posix=True)
        except (UnicodeDecodeError, ValueError) as error:
            raise ValueError("Malformed first shell token") from error
        if len(tokens) != 1 or not tokens[0]:
            raise ValueError("Malformed first shell token")
        executable = tokens[0]
        if executable == selected:
            result.extend(b"+ container" + line[end:])
            replacements += 1
        elif Path(executable).name == "container":
            raise ValueError("Captured a different Container executable")
        else:
            result.extend(line)
    return bytes(result), replacements


def selected_executable() -> str:
    if "CONTAINER_BIN" in os.environ:
        return os.environ["CONTAINER_BIN"]
    if "CONTAINER_COMPOSE_CONTAINER" in os.environ:
        return os.environ["CONTAINER_COMPOSE_CONTAINER"]
    return "container"


def owned_file(path: Path) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError("Input is not an owned regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            return stream.read()
    finally:
        os.close(descriptor)


def private_write(path: Path, content: bytes) -> None:
    if path.is_symlink():
        raise ValueError("Refusing a symbolic-link assertion output")
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError("Assertion output is not an owned regular file")
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        os.close(descriptor)
        temporary.unlink(missing_ok=True)


def retain(label: str, raw: bytes, selected: str, *, canonical: bytes | None = None,
           replacements: int = 0, failure: str | None = None) -> None:
    configured = os.environ.get("PARITY_EVIDENCE_DIR")
    if not configured:
        return
    root = Path(configured)
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ValueError("Parity evidence directory is not owned")
    directory = root / "command-assertions"
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Command assertion evidence directory is not private")
    identity = hashlib.sha256(label.encode() + b"\0" + selected.encode() + b"\0" + raw).hexdigest()[:20]
    stem = label + "-" + identity
    private_write(directory / (stem + ".raw"), raw)
    receipt = {'schema': 1, 'label': label, 'selectedExecutable': selected,
               'rawSHA256': hashlib.sha256(raw).hexdigest(),
               'canonicalSHA256': (hashlib.sha256(canonical).hexdigest()
                                   if canonical is not None else None),
               'rewrittenLines': replacements, 'failure': failure}
    private_write(directory / (stem + ".json"),
                  (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="Existing owned raw capture")
    source.add_argument("--label", help="Safe label for standard-input capture")
    arguments = parser.parse_args()
    if arguments.file is not None:
        path = arguments.file
        if not path.is_absolute():
            parser.error("--file requires an absolute path")
        label = hashlib.sha256(os.fsencode(path)).hexdigest()[:16]
        raw = owned_file(path)
    else:
        label = arguments.label
        if not LABEL.fullmatch(label):
            parser.error("--label must be one safe file-name component")
        raw = sys.stdin.buffer.read()
    selected = selected_executable()
    try:
        canonical, replacements = canonicalize(raw, selected)
    except ValueError as error:
        retain(label, raw, selected, failure=str(error))
        raise
    retain(label, raw, selected, canonical=canonical, replacements=replacements)
    if arguments.file is not None:
        output = Path(str(path) + ".assertions")
        private_write(output, canonical)
        print(output)
    else:
        sys.stdout.buffer.write(canonical)


if __name__ == "__main__":
    main()
