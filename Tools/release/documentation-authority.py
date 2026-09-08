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

"""Verify the immutable authority used by one documentation deployment."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections.abc import Sequence

SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?"
)


def run_command(arguments: Sequence[str]) -> str:
    completed = subprocess.run(
        arguments,
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


def resolve_tag(repository: str, tag: str) -> str:
    output = run_command(
        (
            "git",
            "ls-remote",
            "--tags",
            f"https://github.com/{repository}.git",
            f"refs/tags/{tag}",
            f"refs/tags/{tag}^{{}}",
        )
    )
    direct = ""
    peeled = ""
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        if fields[1] == f"refs/tags/{tag}^{{}}":
            peeled = fields[0]
        elif fields[1] == f"refs/tags/{tag}":
            direct = fields[0]
    resolved = peeled or direct
    if SHA_PATTERN.fullmatch(resolved) is None:
        raise ValueError(f"published tag is missing or invalid: {repository}@{tag}")
    return resolved


def verify_release(
    repository: str, tag: str, expected_id: int, expected_sha: str
) -> dict[str, object]:
    release = json.loads(
        run_command(("gh", "api", f"repos/{repository}/releases/tags/{tag}"))
    )
    actual_id = release.get("id")
    if (
        actual_id != expected_id
        or release.get("tag_name") != tag
        or release.get("draft") is not False
        or release.get("prerelease") is not False
    ):
        raise ValueError(f"published release authority changed: {repository}@{tag}")
    actual_sha = resolve_tag(repository, tag)
    if actual_sha != expected_sha:
        raise ValueError(
            f"published tag moved: {repository}@{tag} "
            f"(expected {expected_sha}, got {actual_sha})"
        )
    return {
        "id": actual_id,
        "repository": repository,
        "sha": actual_sha,
        "tag": tag,
    }


def verify_commit(repository: str, expected_sha: str) -> dict[str, str]:
    actual_sha = run_command(
        ("gh", "api", f"repos/{repository}/commits/{expected_sha}", "--jq", ".sha")
    )
    if actual_sha != expected_sha:
        raise ValueError(
            f"released component commit changed: {repository} "
            f"(expected {expected_sha}, got {actual_sha})"
        )
    return {"repository": repository, "sha": actual_sha}


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compose-repository", required=True)
    parser.add_argument("--compose-tag", required=True)
    parser.add_argument("--compose-release-id", required=True, type=int)
    parser.add_argument("--compose-ref", required=True)
    parser.add_argument("--component", action="append", default=[])
    parser.add_argument("--k8s-repository", required=True)
    parser.add_argument("--k8s-tag", required=True)
    parser.add_argument("--k8s-release-id", required=True, type=int)
    parser.add_argument("--k8s-ref", required=True)
    options = parser.parse_args(arguments)
    for name, value in (
        ("compose repository", options.compose_repository),
        ("k8s repository", options.k8s_repository),
    ):
        if REPOSITORY_PATTERN.fullmatch(value) is None:
            parser.error(f"{name} is invalid: {value}")
    for name, value in (
        ("compose tag", options.compose_tag),
        ("k8s tag", options.k8s_tag),
    ):
        if TAG_PATTERN.fullmatch(value) is None:
            parser.error(f"{name} is invalid: {value}")
    for name, value in (
        ("compose ref", options.compose_ref),
        ("k8s ref", options.k8s_ref),
    ):
        if SHA_PATTERN.fullmatch(value) is None:
            parser.error(f"{name} is not an immutable SHA: {value}")
    return options


def authority_digest(options: argparse.Namespace) -> str:
    components = []
    for declaration in options.component:
        repository, separator, sha = declaration.partition("=")
        if (
            not separator
            or REPOSITORY_PATTERN.fullmatch(repository) is None
            or SHA_PATTERN.fullmatch(sha) is None
        ):
            raise ValueError(f"invalid released component declaration: {declaration}")
        components.append(verify_commit(repository, sha))
    authority = {
        "compose": verify_release(
            options.compose_repository,
            options.compose_tag,
            options.compose_release_id,
            options.compose_ref,
        ),
        "components": sorted(components, key=lambda item: item["repository"]),
        "k8s": verify_release(
            options.k8s_repository,
            options.k8s_tag,
            options.k8s_release_id,
            options.k8s_ref,
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
    except (json.JSONDecodeError, RuntimeError, ValueError) as error:
        print(
            f"documentation authority verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
