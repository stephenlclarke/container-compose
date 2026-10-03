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

"""Record source provenance without replacing Bazel's action keys."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def file_identity(path: Path, root: Path, object_format: str | None = None) -> dict:
    """Include permissions and linked bytes; external source links fail closed."""
    link = None
    if path.is_symlink():
        link = str(path.readlink())
        path = path.resolve(strict=True)
        if not path.is_relative_to(root.resolve()):
            raise ValueError("Source symlinks must stay within the repository")
    if not path.exists():
        return {"deleted": True}
    if not path.is_file():
        raise ValueError(f"Unsupported source input: {path}")
    payload = path.read_bytes()
    result = {"sha256": hashlib.sha256(payload).hexdigest(), "mode": stat.S_IMODE(path.stat().st_mode)}
    if link is not None:
        result["link"] = link
    if object_format is not None:
        blob = link.encode() if link is not None else payload
        header = b"blob " + str(len(blob)).encode("ascii") + b"\0"
        result["gitObject"] = hashlib.new(object_format, header + blob).hexdigest()
        result["gitMode"] = "120000" if link is not None else ("100755" if result["mode"] & 0o111 else "100644")
    return result


def source_identity(root: Path) -> dict:
    """Compare Git-visible and ignored source-glob inputs with committed bytes."""
    def git(*arguments: str) -> bytes:
        return subprocess.check_output(["/usr/bin/git", "-C", str(root), *arguments])

    paths = git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
    # Bazel globs do not honor Git ignore rules. Track only actual compile/data
    # roots; broad ignored-tree scanning would capture caches outside the graph.
    ignored = git("ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--",
                  "Sources", "Tests", "Tools/compose-normalizer")
    def glob_input(raw: bytes) -> bool:
        name = raw.decode("utf-8")
        return (name.startswith("Sources/")
                or name.startswith("Tests/") and (name.endswith(".swift") or "/Fixtures/" in name)
                or name.startswith("Tools/compose-normalizer/") and name.endswith(".go"))
    paths += b"\0".join(raw for raw in ignored.split(b"\0") if raw and glob_input(raw)) + b"\0"
    commit = git("rev-parse", "HEAD").decode().strip()
    object_format = git("rev-parse", "--show-object-format").decode().strip()
    if object_format not in {"sha1", "sha256"}:
        raise ValueError("Unsupported Git object format")
    committed = {}
    for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            mode, kind, identifier = metadata.decode("ascii").split()
            if kind != "blob":
                raise ValueError("Source submodules require explicit provenance")
            committed[name.decode("utf-8")] = (mode, identifier)
    files = {}
    for raw in sorted(set(paths.split(b"\0")) - {b""}):
        name = raw.decode("utf-8")
        path = root / name
        files[name] = file_identity(path, root, object_format)
    # Compare bytes to HEAD, not the index/stat cache: assume-unchanged,
    # skip-worktree and user Git configuration cannot attest modified inputs.
    observed = {name: (value.get("gitMode"), value.get("gitObject")) for name, value in files.items()}
    unverified_links = []
    for name, value in files.items():
        if "link" in value:
            target = Path(os.path.abspath((root / name).parent / value["link"]))
            # Only a direct, tracked target can be attested. Do not adopt an
            # intermediate link's bytes, even when its final target is tracked.
            if target != (root / name).resolve() or target.relative_to(root.resolve()).as_posix() not in committed:
                unverified_links.append(name)
    return {
        "schema": 1,
        "commit": commit,
        "dirty": observed != committed or bool(unverified_links),
        "files": files,
    }


def verify(before: dict, after: dict) -> None:
    """Reject a mixed editable-source run; only Bazel's generated lock may move."""
    if before["commit"] != after["commit"]:
        raise ValueError("Source commit changed during the invocation")
    if before.get("tooling") != after.get("tooling"):
        raise ValueError("Build tooling changed during the invocation")
    old = {key: value for key, value in before["files"].items() if key != "MODULE.bazel.lock"}
    new = {key: value for key, value in after["files"].items() if key != "MODULE.bazel.lock"}
    if old != new:
        raise ValueError("Sources changed during the invocation; do not accept mixed-source evidence")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--tooling", type=Path)
    args = parser.parse_args()
    current = source_identity(args.repository)
    if args.tooling:
        current["tooling"] = tooling_identity(args.tooling, args.repository)
    if args.verify:
        verify(json.loads(args.verify.read_text()), current)
    print(json.dumps(current, sort_keys=True))


def tooling_identity(directory: Path, repository: Path) -> dict:
    """Bind shared executable helpers to the consumer's tracked digest lock."""
    files = {path.name: file_identity(path, directory) for path in sorted(directory.iterdir())
             if path.suffix in {".py", ".sh"}}
    if directory.resolve() != (repository / "Tools/bazel").resolve():
        expected = json.loads((repository / "Tools/bazel/workflow-tooling.json").read_text())
        if expected != files:
            raise ValueError("Shared build tooling differs from the consumer's reviewed lock")
    return files


if __name__ == "__main__":
    main()
