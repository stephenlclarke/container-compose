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

"""Retain verified release bytes locally and publish an atomic version manifest."""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


ARTIFACT_TOOL = Path(__file__).resolve().parents[1] / "build/stack-artifact.py"
SPEC = importlib.util.spec_from_file_location("stack_artifact", ARTIFACT_TOOL)
assert SPEC is not None and SPEC.loader is not None
STACK_ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STACK_ARTIFACT)
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


class RetentionError(RuntimeError):
    """A retained release manifest or candidate asset is unsafe."""


def sha256(path: Path) -> str:
    return STACK_ARTIFACT.digest_file(path)


def manifest_path(root: Path, version: str) -> Path:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise RetentionError(f"unsafe retained release root: {root}")
    if not VERSION.fullmatch(version):
        raise RetentionError(f"invalid semantic release version: {version}")
    return root / "release" / "releases" / version / "assets.json"


def read_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"assets": {}, "schema": 1}
    if path.is_symlink() or not path.is_file():
        raise RetentionError(f"unsafe retained release manifest: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(
        value.get("assets"), dict
    ):
        raise RetentionError(f"invalid retained release manifest: {path}")
    return value


def write_manifest(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".assets-", suffix=".tmp")
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


def retain(root: Path, version: str, candidates: list[Path]) -> None:
    path = manifest_path(root, version)
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    if lock_path.is_symlink():
        raise RetentionError(f"unsafe retained release lock: {lock_path}")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        manifest = read_manifest(path)
        assets: dict[str, Any] = manifest["assets"]
        for candidate in candidates:
            name = candidate.name
            if (
                not candidate.is_absolute()
                or candidate.is_symlink()
                or not candidate.is_file()
            ):
                raise RetentionError(
                    f"release asset must be an absolute regular file: {candidate}"
                )
            STACK_ARTIFACT.validate_name(name)
            digest = sha256(candidate)
            existing = assets.get(name)
            if existing is not None:
                if not isinstance(existing, dict) or existing.get("sha256") != digest:
                    raise RetentionError(
                        f"retained stable asset conflicts for {version}: {name}"
                    )
                retained_path(root, version, name)
                continue
            retained = STACK_ARTIFACT.promote(
                candidate, root / "release/artifacts", name
            )
            record = {
                "mode": stat.S_IMODE(retained.stat(follow_symlinks=False).st_mode),
                "path": str(retained),
                "sha256": digest,
                "size": retained.stat().st_size,
            }
            assets[name] = record
        write_manifest(path, manifest)


def retained_path(root: Path, version: str, name: str) -> Path:
    STACK_ARTIFACT.validate_name(name)
    manifest = read_manifest(manifest_path(root, version))
    record = manifest["assets"].get(name)
    if not isinstance(record, dict) or not isinstance(record.get("path"), str):
        raise RetentionError(f"retained stable asset is unavailable: {version}/{name}")
    path = Path(record["path"])
    artifact_root = (root / "release/artifacts").resolve(strict=True)
    if (
        not path.is_absolute()
        or artifact_root not in path.resolve(strict=False).parents
        or path.is_symlink()
        or not path.is_file()
        or sha256(path) != record.get("sha256")
        or path.stat().st_size != record.get("size")
        or stat.S_IMODE(path.stat(follow_symlinks=False).st_mode) != record.get("mode")
    ):
        raise RetentionError(f"retained stable asset is invalid: {version}/{name}")
    return path


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("retain", "path"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--asset", type=Path, action="append", default=[])
    parser.add_argument("--name")
    options = parser.parse_args(arguments)
    try:
        if options.action == "retain":
            if not options.asset:
                raise RetentionError("retain requires at least one --asset")
            retain(options.root, options.version, options.asset)
        else:
            if not options.name:
                raise RetentionError("path requires --name")
            print(retained_path(options.root, options.version, options.name))
    except (RetentionError, STACK_ARTIFACT.ArtifactError, OSError, json.JSONDecodeError) as error:
        print(f"retain-release-assets: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
