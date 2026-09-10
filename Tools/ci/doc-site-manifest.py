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

"""Create or verify a complete content manifest for a generated DocC site."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


SCHEMA = 2
MANIFEST_NAME = ".docc-site-manifest.json"
MAX_ARCHIVE_FILE_SIZE = 512 * 1024 * 1024
MAX_ARCHIVE_SIZE = 4 * 1024 * 1024 * 1024


class ManifestError(RuntimeError):
    """The generated site or its retained manifest is unsafe or incomplete."""


def digest(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    value = hashlib.sha256()
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise ManifestError(f"site entry is not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(chunk)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return value.hexdigest()


def files(root: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.name == MANIFEST_NAME:
            continue
        if path.is_symlink():
            raise ManifestError(f"DocC site contains a symbolic link: {path}")
        if path.is_dir():
            continue
        relative = path.relative_to(root).as_posix()
        status = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(status.st_mode):
            raise ManifestError(f"DocC site contains a special file: {path}")
        entries.append(
            {
                "path": relative,
                "sha256": digest(path),
                "size": status.st_size,
            }
        )
    return entries


def validate_required(entries: list[dict[str, object]]) -> None:
    paths = {entry["path"] for entry in entries}
    for required in ("index.html", "theme-settings.json"):
        if required not in paths:
            raise ManifestError(f"DocC site is missing required entry: {required}")
    if not any(str(path).startswith("documentation/") for path in paths):
        raise ManifestError("DocC site has no documentation payload")


def validate_context(value: object, expected: dict[str, str] | None = None) -> None:
    if not isinstance(value, dict) or any(
        not isinstance(key, str) or not isinstance(item, str) or not item
        for key, item in value.items()
    ):
        raise ManifestError("DocC site has an invalid semantic context")
    for key, item in (expected or {}).items():
        if value.get(key) != item:
            raise ManifestError(f"DocC site context changed: {key}")


def create(root: Path, context: dict[str, str] | None = None) -> None:
    resolved = root.resolve(strict=True)
    entries = files(resolved)
    validate_required(entries)
    value = {"context": context or {}, "files": entries, "schema": SCHEMA}
    descriptor, name = tempfile.mkstemp(dir=resolved, prefix=".manifest-", suffix=".tmp")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, resolved / MANIFEST_NAME)
    finally:
        temporary.unlink(missing_ok=True)


def verify(root: Path, expected_context: dict[str, str] | None = None) -> None:
    resolved = root.resolve(strict=True)
    manifest_path = resolved / MANIFEST_NAME
    if manifest_path.is_symlink():
        raise ManifestError("DocC manifest must not be a symbolic link")
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"could not read DocC manifest: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise ManifestError("DocC manifest has an unsupported schema")
    validate_context(value.get("context"), expected_context)
    recorded = value.get("files")
    if not isinstance(recorded, list) or recorded != files(resolved):
        raise ManifestError("DocC site does not match its content manifest")
    validate_required(recorded)


def verify_archive(path: Path, expected_context: dict[str, str] | None = None) -> None:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ManifestError(f"DocC archive is indirect or missing: {path}")
    entries: list[dict[str, object]] = []
    manifest: dict[str, object] | None = None
    names: set[str] = set()
    total_size = 0
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            if member.isdir():
                continue
            if (
                not member.isfile()
                or not name
                or PurePosixPath(name).is_absolute()
                or ".." in PurePosixPath(name).parts
                or name in names
                or member.size < 0
                or member.size > MAX_ARCHIVE_FILE_SIZE
            ):
                raise ManifestError(f"DocC archive contains an unsafe entry: {member.name}")
            names.add(name)
            stream = archive.extractfile(member)
            if stream is None:
                raise ManifestError(f"DocC archive entry is unreadable: {name}")
            payload = stream.read(MAX_ARCHIVE_FILE_SIZE + 1)
            total_size += len(payload)
            if len(payload) != member.size:
                raise ManifestError(f"DocC archive entry is truncated: {name}")
            if total_size > MAX_ARCHIVE_SIZE:
                raise ManifestError("DocC archive exceeds its safe size")
            if name == MANIFEST_NAME:
                try:
                    value = json.loads(payload)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise ManifestError("DocC archive manifest is malformed") from error
                if not isinstance(value, dict):
                    raise ManifestError("DocC archive manifest is not an object")
                manifest = value
                continue
            entries.append(
                {
                    "path": name,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size": len(payload),
                }
            )
    entries.sort(key=lambda entry: str(entry["path"]))
    if manifest is None or manifest.get("schema") != SCHEMA:
        raise ManifestError("DocC archive has no supported content manifest")
    validate_context(manifest.get("context"), expected_context)
    if manifest.get("files") != entries:
        raise ManifestError("DocC archive does not match its content manifest")
    validate_required(entries)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "verify", "verify-archive"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--site")
    parser.add_argument("--source-ref")
    parser.add_argument("--toolchain-digest")
    parser.add_argument("--hosting-base-path")
    options = parser.parse_args(arguments)
    context = {
        key: value
        for key, value in {
            "hosting_base_path": options.hosting_base_path,
            "site": options.site,
            "source_ref": options.source_ref,
            "toolchain_digest": options.toolchain_digest,
        }.items()
        if value
    }
    try:
        if options.action == "create":
            create(options.root, context)
        elif options.action == "verify-archive":
            verify_archive(options.root, context)
        else:
            verify(options.root, context)
    except (ManifestError, OSError, tarfile.TarError) as error:
        print(f"doc-site-manifest: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
