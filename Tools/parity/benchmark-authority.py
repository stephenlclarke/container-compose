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

"""Verify benchmark controls and release authority through report publication."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from collections.abc import Sequence

REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?"
)
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def run_command(arguments: Sequence[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"authority command failed ({completed.returncode}): "
            f"{' '.join(arguments)}\n{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def resolve_remote_ref(repository: str, ref: str, ref_type: str) -> str:
    output = run_command(
        (
            "git",
            "ls-remote",
            f"--{ref_type}",
            f"https://github.com/{repository}.git",
            f"refs/{ref_type}/{ref}",
            *(
                (f"refs/{ref_type}/{ref}^{{}}",)
                if ref_type == "tags"
                else ()
            ),
        )
    )
    direct = ""
    peeled = ""
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        if fields[1] == f"refs/{ref_type}/{ref}^{{}}":
            peeled = fields[0]
        elif fields[1] == f"refs/{ref_type}/{ref}":
            direct = fields[0]
    resolved = peeled or direct
    if SHA_PATTERN.fullmatch(resolved) is None:
        raise ValueError(f"remote ref is missing or invalid: {repository}@{ref}")
    return resolved


def parse_release(declaration: str) -> tuple[str, str, int, str]:
    fields = declaration.split("|")
    if len(fields) != 4:
        raise ValueError(f"invalid benchmark release declaration: {declaration}")
    repository, tag, release_id_text, sha = fields
    if (
        REPOSITORY_PATTERN.fullmatch(repository) is None
        or TAG_PATTERN.fullmatch(tag) is None
        or not release_id_text.isdigit()
        or SHA_PATTERN.fullmatch(sha) is None
    ):
        raise ValueError(f"invalid benchmark release declaration: {declaration}")
    return repository, tag, int(release_id_text), sha


def verify_release(declaration: str) -> dict[str, object]:
    repository, tag, expected_id, expected_sha = parse_release(declaration)
    release = json.loads(
        run_command(("gh", "api", f"repos/{repository}/releases/tags/{tag}"))
    )
    if (
        release.get("id") != expected_id
        or release.get("tag_name") != tag
        or release.get("draft") is not False
        or release.get("prerelease") is not False
    ):
        raise ValueError(f"benchmark release authority changed: {repository}@{tag}")
    actual_sha = resolve_remote_ref(repository, tag, "tags")
    if actual_sha != expected_sha:
        raise ValueError(
            f"benchmark release tag moved: {repository}@{tag} "
            f"(expected {expected_sha}, got {actual_sha})"
        )
    return {
        "id": expected_id,
        "repository": repository,
        "sha": actual_sha,
        "tag": tag,
    }


def parse_checkout(declaration: str) -> tuple[Path, str]:
    fields = declaration.split("|")
    if len(fields) != 2:
        raise ValueError(f"invalid benchmark checkout declaration: {declaration}")
    path_text, sha = fields
    path = Path(path_text)
    if (
        not path_text
        or path.is_absolute()
        or ".." in path.parts
        or SHA_PATTERN.fullmatch(sha) is None
    ):
        raise ValueError(f"invalid benchmark checkout declaration: {declaration}")
    return path, sha


def verify_checkout(source: Path, declaration: str) -> dict[str, str]:
    relative_path, expected_sha = parse_checkout(declaration)
    repository = source / relative_path
    actual_sha = run_command(("git", "rev-parse", "HEAD"), cwd=repository)
    if actual_sha != expected_sha:
        raise ValueError(
            f"benchmark checkout authority changed: {relative_path} "
            f"(expected {expected_sha}, got {actual_sha})"
        )
    tracked_status = run_command(
        ("git", "status", "--porcelain", "--untracked-files=no"), cwd=repository
    )
    if tracked_status:
        raise ValueError(f"benchmark checkout has tracked changes: {relative_path}")
    return {"path": str(relative_path), "sha": actual_sha}


def changed_paths(repository: Path, controls_ref: str) -> set[str]:
    committed = run_command(
        ("git", "diff", "--name-only", f"{controls_ref}..HEAD"), cwd=repository
    )
    working = run_command(
        ("git", "diff", "--name-only", "HEAD"), cwd=repository
    )
    paths = set(filter(None, committed.splitlines()))
    paths.update(filter(None, working.splitlines()))
    return paths


def verify_controls(
    repository: Path, controls_ref: str, allowed_outputs: Sequence[str]
) -> dict[str, object]:
    run_command(("git", "cat-file", "-e", f"{controls_ref}^{{commit}}"), cwd=repository)
    allowed = set(allowed_outputs)
    unexpected = sorted(changed_paths(repository, controls_ref) - allowed)
    if unexpected:
        raise ValueError(
            "benchmark controls changed during execution: " + ", ".join(unexpected)
        )
    return {"allowedOutputs": sorted(allowed), "sha": controls_ref}


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--controls-ref", required=True)
    parser.add_argument("--allow-output", action="append", default=[])
    parser.add_argument("--release", action="append", default=[])
    parser.add_argument("--checkout", action="append", default=[])
    options = parser.parse_args(arguments)
    if SHA_PATTERN.fullmatch(options.controls_ref) is None:
        parser.error(f"controls ref is not an immutable SHA: {options.controls_ref}")
    if not options.release:
        parser.error("at least one release authority is required")
    for output in options.allow_output:
        if not output or Path(output).is_absolute() or ".." in Path(output).parts:
            parser.error(f"allowed output is not repository-relative: {output}")
    return options


def authority_digest(options: argparse.Namespace) -> str:
    source = options.source.resolve()
    authority = {
        "checkouts": sorted(
            (verify_checkout(source, declaration) for declaration in options.checkout),
            key=lambda item: item["path"],
        ),
        "controls": verify_controls(
            source, options.controls_ref, options.allow_output
        ),
        "releases": sorted(
            (verify_release(declaration) for declaration in options.release),
            key=lambda item: (item["repository"], item["tag"]),
        ),
        "schema": 1,
    }
    encoded = json.dumps(
        authority, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def main(arguments: Sequence[str]) -> int:
    try:
        print(authority_digest(parse_arguments(arguments)))
    except (json.JSONDecodeError, OSError, RuntimeError, ValueError) as error:
        print(
            f"benchmark authority verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
