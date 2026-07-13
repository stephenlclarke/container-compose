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

"""Report fork divergence from Apple upstream for stack source repositories."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REPO_ROOT = ROOT.parent


@dataclass(frozen=True)
class RepoSpec:
    name: str
    relative_path: str
    fork_remotes: tuple[str, ...]
    upstream_remotes: tuple[str, ...]
    branch: str = "main"


@dataclass(frozen=True)
class CommitSummary:
    hash: str
    short: str
    subject: str


@dataclass
class MergeStatus:
    status: str
    details: str = ""
    files: list[str] = field(default_factory=list)


@dataclass
class Divergence:
    ahead: int = 0
    behind: int = 0


@dataclass
class RepositoryReport:
    name: str
    path: str
    branch: str
    dirty: bool
    dirty_paths: list[str]
    fork_remote: str | None
    upstream_remote: str | None
    local: CommitSummary | None
    fork: CommitSummary | None
    upstream: CommitSummary | None
    merge_base: CommitSummary | None
    local_to_upstream: Divergence
    fork_to_upstream: Divergence
    local_to_fork: Divergence
    local_only_commits: list[CommitSummary]
    upstream_only_commits: list[CommitSummary]
    unpushed_local_commits: list[CommitSummary]
    merge_upstream_into_local: MergeStatus
    errors: list[str] = field(default_factory=list)


@dataclass
class ReportSummary:
    repository_count: int
    clean_merge_count: int
    conflict_count: int
    dirty_count: int
    error_count: int
    unpushed_count: int


@dataclass
class StackReport:
    generated_at: str
    fetched: bool
    max_commits: int
    repositories: list[RepositoryReport]
    summary: ReportSummary


DEFAULT_REPOS: tuple[RepoSpec, ...] = (
    RepoSpec(
        name="container",
        relative_path="container",
        fork_remotes=("fork",),
        upstream_remotes=("origin", "upstream"),
    ),
    RepoSpec(
        name="containerization",
        relative_path="containerization",
        fork_remotes=("origin", "fork"),
        upstream_remotes=("upstream",),
    ),
    RepoSpec(
        name="container-builder-shim",
        relative_path="container-builder-shim",
        fork_remotes=("fork",),
        upstream_remotes=("upstream", "origin"),
    ),
)


class GitError(RuntimeError):
    def __init__(self, args: Sequence[str], cwd: Path, result: subprocess.CompletedProcess[str]):
        command = " ".join(args)
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        super().__init__(f"git {command} failed in {cwd}: {detail}")
        self.args_for_git = tuple(args)
        self.cwd = cwd
        self.result = result


def run_git(repo: Path, args: Sequence[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        check=False,
        text=True,
    )
    if check and result.returncode != 0:
        raise GitError(args, repo, result)
    return result


def git_text(repo: Path, args: Sequence[str]) -> str:
    return run_git(repo, args).stdout.strip()


def fetch_remote(repo: Path, remote: str, branch: str) -> None:
    run_git(
        repo,
        [
            "fetch",
            "--prune",
            "--no-tags",
            remote,
            f"refs/heads/{branch}:refs/remotes/{remote}/{branch}",
        ],
    )


def choose_remote(repo: Path, candidates: Sequence[str]) -> str:
    remotes = set(git_text(repo, ["remote"]).splitlines())
    for candidate in candidates:
        if candidate in remotes:
            return candidate
    raise RuntimeError(f"none of the expected remotes exist: {', '.join(candidates)}")


def remote_ref(remote: str, branch: str) -> str:
    return f"refs/remotes/{remote}/{branch}"


def commit_summary(repo: Path, ref: str) -> CommitSummary:
    revision = git_text(repo, ["rev-parse", "--verify", f"{ref}^{{commit}}"])
    short = git_text(repo, ["rev-parse", "--short=8", revision])
    subject = git_text(repo, ["log", "-1", "--format=%s", revision])
    return CommitSummary(hash=revision, short=short, subject=subject)


def maybe_commit_summary(repo: Path, ref: str) -> CommitSummary | None:
    result = run_git(repo, ["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], check=False)
    if result.returncode != 0:
        return None
    return commit_summary(repo, ref)


def ahead_behind(repo: Path, base_ref: str, compare_ref: str) -> Divergence:
    output = git_text(repo, ["rev-list", "--left-right", "--count", f"{base_ref}...{compare_ref}"])
    left, right = output.split()
    return Divergence(ahead=int(right), behind=int(left))


def commit_list(repo: Path, include_ref: str, exclude_ref: str, max_commits: int) -> list[CommitSummary]:
    output = git_text(
        repo,
        [
            "log",
            f"--max-count={max_commits}",
            "--format=%H%x00%h%x00%s",
            include_ref,
            "--not",
            exclude_ref,
        ],
    )
    commits: list[CommitSummary] = []
    for line in output.splitlines():
        if not line:
            continue
        parts = line.split("\0", 2)
        if len(parts) == 3:
            commits.append(CommitSummary(hash=parts[0], short=parts[1], subject=parts[2]))
    return commits


def dirty_paths(repo: Path) -> list[str]:
    output = git_text(repo, ["status", "--porcelain"])
    paths: list[str] = []
    for line in output.splitlines():
        if len(line) >= 4:
            paths.append(line[3:])
    return paths


def parse_conflict_files(text: str) -> list[str]:
    files: list[str] = []
    for line in text.splitlines():
        match = re.search(r"CONFLICT .* in (.+)$", line)
        if match:
            files.append(match.group(1))
    return sorted(set(files))


def merge_status(repo: Path, local_ref: str, upstream_ref: str) -> MergeStatus:
    result = run_git(
        repo,
        ["merge-tree", "--write-tree", "--messages", local_ref, upstream_ref],
        check=False,
    )
    text = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    if result.returncode == 0:
        return MergeStatus(status="clean")
    if "CONFLICT" in text:
        conflict_lines = [line for line in text.splitlines() if "CONFLICT" in line]
        return MergeStatus(
            status="conflicts",
            details="; ".join(conflict_lines[:5]),
            files=parse_conflict_files(text),
        )
    return MergeStatus(status="unknown", details=text)


def empty_repository_report(name: str, path: Path, errors: list[str]) -> RepositoryReport:
    return RepositoryReport(
        name=name,
        path=str(path),
        branch="",
        dirty=False,
        dirty_paths=[],
        fork_remote=None,
        upstream_remote=None,
        local=None,
        fork=None,
        upstream=None,
        merge_base=None,
        local_to_upstream=Divergence(),
        fork_to_upstream=Divergence(),
        local_to_fork=Divergence(),
        local_only_commits=[],
        upstream_only_commits=[],
        unpushed_local_commits=[],
        merge_upstream_into_local=MergeStatus(status="unknown"),
        errors=errors,
    )


def analyze_repository(spec: RepoSpec, repo_root: Path, fetch: bool, max_commits: int) -> RepositoryReport:
    repo = repo_root / spec.relative_path
    errors: list[str] = []
    if not repo.exists():
        errors.append("checkout is missing")
        return empty_repository_report(spec.name, repo, errors)

    try:
        inside = git_text(repo, ["rev-parse", "--is-inside-work-tree"])
        if inside != "true":
            errors.append("path is not a Git worktree")
            return empty_repository_report(spec.name, repo, errors)

        fork_remote = choose_remote(repo, spec.fork_remotes)
        upstream_remote = choose_remote(repo, spec.upstream_remotes)
        if fetch:
            fetch_remote(repo, fork_remote, spec.branch)
            fetch_remote(repo, upstream_remote, spec.branch)

        fork = remote_ref(fork_remote, spec.branch)
        upstream = remote_ref(upstream_remote, spec.branch)
        local = "HEAD"
        local_summary = commit_summary(repo, local)
        fork_summary = maybe_commit_summary(repo, fork)
        upstream_summary = maybe_commit_summary(repo, upstream)
        if fork_summary is None:
            raise RuntimeError(f"missing fork ref {fork}; run with --fetch")
        if upstream_summary is None:
            raise RuntimeError(f"missing upstream ref {upstream}; run with --fetch")

        merge_base_hash = git_text(repo, ["merge-base", local, upstream])
        paths = dirty_paths(repo)
        return RepositoryReport(
            name=spec.name,
            path=str(repo),
            branch=git_text(repo, ["branch", "--show-current"]),
            dirty=bool(paths),
            dirty_paths=paths,
            fork_remote=fork_remote,
            upstream_remote=upstream_remote,
            local=local_summary,
            fork=fork_summary,
            upstream=upstream_summary,
            merge_base=commit_summary(repo, merge_base_hash),
            local_to_upstream=ahead_behind(repo, upstream, local),
            fork_to_upstream=ahead_behind(repo, upstream, fork),
            local_to_fork=ahead_behind(repo, fork, local),
            local_only_commits=commit_list(repo, local, upstream, max_commits),
            upstream_only_commits=commit_list(repo, upstream, local, max_commits),
            unpushed_local_commits=commit_list(repo, local, fork, max_commits),
            merge_upstream_into_local=merge_status(repo, local, upstream),
            errors=[],
        )
    except (GitError, RuntimeError) as error:
        errors.append(str(error))
        return empty_repository_report(spec.name, repo, errors)


def summarize(repositories: Sequence[RepositoryReport]) -> ReportSummary:
    return ReportSummary(
        repository_count=len(repositories),
        clean_merge_count=sum(1 for repo in repositories if repo.merge_upstream_into_local.status == "clean"),
        conflict_count=sum(1 for repo in repositories if repo.merge_upstream_into_local.status == "conflicts"),
        dirty_count=sum(1 for repo in repositories if repo.dirty),
        error_count=sum(1 for repo in repositories if repo.errors),
        unpushed_count=sum(1 for repo in repositories if repo.local_to_fork.ahead > 0),
    )


def build_report(repo_root: Path, fetch: bool, max_commits: int, specs: Sequence[RepoSpec]) -> StackReport:
    repositories = [analyze_repository(spec, repo_root, fetch, max_commits) for spec in specs]
    return StackReport(
        generated_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        fetched=fetch,
        max_commits=max_commits,
        repositories=repositories,
        summary=summarize(repositories),
    )


def format_divergence(divergence: Divergence) -> str:
    return f"+{divergence.ahead}/-{divergence.behind}"


def format_commit(commit: CommitSummary | None) -> str:
    if commit is None:
        return "missing"
    return f"`{commit.short}` {commit.subject}"


def format_commit_list(commits: Sequence[CommitSummary]) -> list[str]:
    if not commits:
        return ["  - none"]
    return [f"  - `{commit.short}` {commit.subject}" for commit in commits]


def render_markdown(report: StackReport) -> str:
    lines = [
        "# Upstream Divergence Report",
        "",
        f"- Generated: `{report.generated_at}`",
        f"- Fetch remote refs first: `{'yes' if report.fetched else 'no'}`",
        f"- Repositories: `{report.summary.repository_count}`",
        f"- Clean upstream merge checks: `{report.summary.clean_merge_count}`",
        f"- Conflict merge checks: `{report.summary.conflict_count}`",
        f"- Dirty worktrees: `{report.summary.dirty_count}`",
        f"- Repositories with unpushed local commits: `{report.summary.unpushed_count}`",
        f"- Repositories with report errors: `{report.summary.error_count}`",
        "",
        "| Repository | Local vs Apple | Fork vs Apple | Local vs fork | Merge Apple into local |",
        "| --- | ---: | ---: | ---: | --- |",
    ]
    for repo in report.repositories:
        merge = repo.merge_upstream_into_local.status
        if repo.merge_upstream_into_local.files:
            merge = f"{merge}: {', '.join(repo.merge_upstream_into_local.files)}"
        lines.append(
            f"| `{repo.name}` | {format_divergence(repo.local_to_upstream)} | "
            f"{format_divergence(repo.fork_to_upstream)} | {format_divergence(repo.local_to_fork)} | {merge} |"
        )

    for repo in report.repositories:
        lines.extend(
            [
                "",
                f"## {repo.name}",
                "",
                f"- Path: `{repo.path}`",
                f"- Branch: `{repo.branch or 'unknown'}`",
                f"- Fork remote: `{repo.fork_remote or 'missing'}`",
                f"- Apple upstream remote: `{repo.upstream_remote or 'missing'}`",
                f"- Working tree: `{'dirty' if repo.dirty else 'clean'}`",
                f"- Local: {format_commit(repo.local)}",
                f"- Fork main: {format_commit(repo.fork)}",
                f"- Apple main: {format_commit(repo.upstream)}",
                f"- Merge base: {format_commit(repo.merge_base)}",
            ]
        )
        if repo.dirty_paths:
            lines.append("- Dirty paths:")
            lines.extend(f"  - `{path}`" for path in repo.dirty_paths)
        if repo.errors:
            lines.append("- Errors:")
            lines.extend(f"  - {error}" for error in repo.errors)
        if repo.merge_upstream_into_local.details:
            lines.append(f"- Merge details: {repo.merge_upstream_into_local.details}")
        lines.append(f"- Local commits not in Apple upstream (latest {report.max_commits}):")
        lines.extend(format_commit_list(repo.local_only_commits))
        lines.append(f"- Apple upstream commits not in local HEAD (latest {report.max_commits}):")
        lines.extend(format_commit_list(repo.upstream_only_commits))
        lines.append(f"- Local commits not pushed to the stephenlclarke-owned fork remote (latest {report.max_commits}):")
        lines.extend(format_commit_list(repo.unpushed_local_commits))

    return "\n".join(lines) + "\n"


def report_to_json(report: StackReport) -> str:
    return json.dumps(asdict(report), indent=2, sort_keys=True) + "\n"


def write_output(path: Path | None, content: str) -> None:
    if path is None:
        print(content, end="")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def strict_failures(report: StackReport) -> list[str]:
    failures: list[str] = []
    for repo in report.repositories:
        if repo.errors:
            failures.append(f"{repo.name}: report errors")
        if repo.dirty:
            failures.append(f"{repo.name}: dirty worktree")
        if repo.local_to_fork.ahead > 0:
            failures.append(f"{repo.name}: local commits are not pushed to the fork remote")
        if repo.local_to_fork.behind > 0:
            failures.append(f"{repo.name}: local HEAD is behind the fork remote")
        if repo.merge_upstream_into_local.status == "conflicts":
            failures.append(f"{repo.name}: Apple upstream merge conflicts")
        if repo.merge_upstream_into_local.status == "unknown":
            failures.append(f"{repo.name}: Apple upstream merge status is unknown")
    return failures


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help="directory containing sibling container stack checkouts",
    )
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="fetch fork and Apple upstream main refs before reporting",
    )
    parser.add_argument(
        "--max-commits",
        type=int,
        default=12,
        help="maximum commit subjects to include per section",
    )
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="primary output format",
    )
    parser.add_argument("--output", type=Path, help="write primary output to this path")
    parser.add_argument("--json-output", type=Path, help="also write JSON output to this path")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="return non-zero when repos are dirty, unpushed, missing refs, or conflict with Apple upstream",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    max_commits = max(args.max_commits, 0)
    report = build_report(args.repo_root.expanduser(), args.fetch, max_commits, DEFAULT_REPOS)
    primary = render_markdown(report) if args.format == "markdown" else report_to_json(report)
    write_output(args.output, primary)
    if args.json_output is not None:
        write_output(args.json_output, report_to_json(report))

    if args.strict:
        failures = strict_failures(report)
        if failures:
            for failure in failures:
                print(failure, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
