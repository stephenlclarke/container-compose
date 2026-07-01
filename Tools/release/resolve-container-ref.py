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

"""Resolve the exact stephenlclarke/container commit for package metadata."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="../container")
    parser.add_argument("--remote", default="https://github.com/stephenlclarke/container.git")
    parser.add_argument("--branch", default="main")
    return parser.parse_args()


def git_output(arguments: list[str]) -> str | None:
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def local_repo_ref(repo: Path) -> str | None:
    if not (repo / ".git").exists():
        return None
    return git_output(["git", "-C", str(repo), "rev-parse", "HEAD"])


def remote_branch_ref(remote: str, branch: str) -> str | None:
    output = git_output(["git", "ls-remote", remote, f"refs/heads/{branch}"])
    if output is None:
        return None
    fields = output.split()
    return fields[0] if fields else None


def main() -> int:
    args = parse_args()
    ref = local_repo_ref(Path(args.repo)) or remote_branch_ref(args.remote, args.branch)
    if ref is None:
        print(
            f"could not resolve container ref from {args.repo} or {args.remote} {args.branch}",
            file=sys.stderr,
        )
        return 1
    print(ref)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
