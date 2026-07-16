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

"""Classify local topic branches without modifying worktrees or refs."""

from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BranchAudit:
    name: str
    category: str
    worktree: Path | None
    dirty: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--main", default="main", help="integration branch to compare against")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail when an integrated cleanup candidate remains",
    )
    return parser.parse_args()


def run_git(repository: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=repository,
        capture_output=True,
        check=False,
        text=True,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return result


def checked_out_worktrees(repository: Path) -> dict[str, Path]:
    worktrees: dict[str, Path] = {}
    path: Path | None = None
    for line in run_git(repository, "worktree", "list", "--porcelain").stdout.splitlines():
        if not line:
            path = None
            continue
        if line.startswith("worktree "):
            path = Path(line.removeprefix("worktree "))
        elif line.startswith("branch refs/heads/") and path is not None:
            worktrees[line.removeprefix("branch refs/heads/")] = path
    return worktrees


def local_branches(repository: Path) -> list[str]:
    output = run_git(repository, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout
    return [line for line in output.splitlines() if line]


def has_remote_branch(repository: Path, branch: str) -> bool:
    result = run_git(
        repository,
        "show-ref",
        "--verify",
        "--quiet",
        f"refs/remotes/origin/{branch}",
        check=False,
    )
    return result.returncode == 0


def has_unique_patch(repository: Path, main_branch: str, branch: str) -> bool:
    merge_commits = run_git(
        repository,
        "rev-list",
        "--merges",
        "--max-count=1",
        f"{main_branch}..{branch}",
    ).stdout.strip()
    if merge_commits:
        return True
    result = run_git(repository, "cherry", main_branch, branch, check=False)
    if result.returncode != 0:
        return True
    return any(line.startswith("+") for line in result.stdout.splitlines())


def is_dirty(repository: Path, worktree: Path | None) -> bool:
    if worktree is None or not worktree.is_dir():
        return False
    return bool(run_git(repository, "-C", str(worktree), "status", "--porcelain").stdout.strip())


def audit_branches(repository: Path, main_branch: str) -> list[BranchAudit]:
    worktrees = checked_out_worktrees(repository)
    audits: list[BranchAudit] = []
    for branch in local_branches(repository):
        if branch == main_branch:
            continue
        worktree = worktrees.get(branch)
        dirty = is_dirty(repository, worktree)
        if has_remote_branch(repository, branch):
            category = "active"
        elif has_unique_patch(repository, main_branch, branch):
            category = "retain"
        else:
            category = "integrated"
        audits.append(BranchAudit(branch, category, worktree, dirty))
    return audits


def format_audit(audit: BranchAudit) -> str:
    details = []
    if audit.worktree is not None:
        details.append(str(audit.worktree))
    if audit.dirty:
        details.append("dirty")
    return f"  - {audit.name}" + (f" ({'; '.join(details)})" if details else "")


def main() -> int:
    args = parse_args()
    repository = args.repository.resolve()
    audits = audit_branches(repository, args.main)
    grouped = {
        "active": "Active topic branches (origin branch exists)",
        "integrated": "Cleanup candidates (no remote branch and no unique patches)",
        "retain": "Retain or close deliberately (no remote branch and unique patches)",
    }

    print(f"Worktree audit for {repository} against {args.main}")
    print("Fetch with --prune before acting; this command never changes worktrees or refs.")
    for category, title in grouped.items():
        entries = [audit for audit in audits if audit.category == category]
        print(f"\n{title}:")
        if entries:
            for audit in entries:
                print(format_audit(audit))
        else:
            print("  - none")

    if args.strict and any(audit.category == "integrated" and not audit.dirty for audit in audits):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
