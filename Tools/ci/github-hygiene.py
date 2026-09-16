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

"""Report GitHub repository hygiene and remove only proven merged PR branches."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


RETAINED_PREFIXES = ("upstream/", "release/", "release-", "archive/")


class HygieneError(RuntimeError):
    """GitHub hygiene could not be proved or completed safely."""


@dataclass(frozen=True)
class Branch:
    name: str
    sha: str
    protected: bool


@dataclass(frozen=True)
class PullRequest:
    number: int
    head_ref: str
    head_sha: str
    head_repository: str
    base_ref: str
    merged_at: datetime | None


@dataclass(frozen=True)
class Decision:
    branch: str
    sha: str
    disposition: str
    reason: str
    pull_request: int | None = None


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="owner/name")
    parser.add_argument("--default-branch")
    parser.add_argument("--grace-days", type=int, default=7)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    return parser.parse_args(arguments)


def parse_timestamp(value: str | None) -> datetime | None:
    if value is None:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def parse_pull_request(payload: dict[str, Any]) -> PullRequest:
    head_repository = payload.get("head", {}).get("repo") or {}
    return PullRequest(
        number=int(payload["number"]),
        head_ref=str(payload["head"]["ref"]),
        head_sha=str(payload["head"]["sha"]),
        head_repository=str(head_repository.get("full_name") or ""),
        base_ref=str(payload["base"]["ref"]),
        merged_at=parse_timestamp(payload.get("merged_at")),
    )


class GitHubClient:
    def __init__(self, token: str, api_url: str = "https://api.github.com") -> None:
        if not token:
            raise HygieneError("GITHUB_TOKEN is required")
        parsed = urllib.parse.urlparse(api_url.rstrip("/"))
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.netloc
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise HygieneError(f"invalid GitHub API URL: {api_url}")
        self.token = token
        self.api_origin = f"{parsed.scheme}://{parsed.netloc}"
        self.api_base_path = parsed.path.rstrip("/")
        self.api_url = f"{self.api_origin}{self.api_base_path}"

    def request(
        self,
        method: str,
        endpoint: str,
        *,
        expected: tuple[int, ...] = (200,),
    ) -> tuple[Any, urllib.response.addinfourl]:
        request = urllib.request.Request(
            f"{self.api_url}{endpoint}",
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "container-compose-repository-hygiene",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise HygieneError(
                f"GitHub {method} {endpoint} failed with {error.code}: {detail}"
            ) from error
        if response.status not in expected:
            raise HygieneError(
                f"GitHub {method} {endpoint} returned unexpected status {response.status}"
            )
        payload = None if response.status == 204 else json.load(response)
        return payload, response

    def paginated(self, endpoint: str) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        current: str | None = endpoint
        while current is not None:
            payload, response = self.request("GET", current)
            if not isinstance(payload, list):
                raise HygieneError(f"GitHub pagination returned a non-list for {current}")
            results.extend(payload)
            current = None
            for item in response.headers.get("Link", "").split(","):
                if 'rel="next"' not in item:
                    continue
                target = item.split(";", 1)[0].strip().strip("<>")
                parsed = urllib.parse.urlparse(target)
                if f"{parsed.scheme}://{parsed.netloc}" != self.api_origin:
                    raise HygieneError("GitHub pagination escaped the configured API origin")
                if self.api_base_path:
                    prefix = f"{self.api_base_path}/"
                    if not parsed.path.startswith(prefix):
                        raise HygieneError(
                            "GitHub pagination escaped the configured API base path"
                        )
                    endpoint = parsed.path[len(self.api_base_path) :]
                else:
                    endpoint = parsed.path
                current = endpoint + (f"?{parsed.query}" if parsed.query else "")
                break
        return results

    def repository(self, repository: str) -> dict[str, Any]:
        payload, _ = self.request("GET", f"/repos/{repository}")
        if not isinstance(payload, dict):
            raise HygieneError("GitHub repository response is invalid")
        return payload

    def branches(self, repository: str) -> list[Branch]:
        payload = self.paginated(f"/repos/{repository}/branches?per_page=100")
        return [
            Branch(
                name=str(item["name"]),
                sha=str(item["commit"]["sha"]),
                protected=bool(item["protected"]),
            )
            for item in payload
        ]

    def pull_requests(
        self, repository: str, branch: str, *, state: str
    ) -> list[PullRequest]:
        owner = repository.split("/", 1)[0]
        query = urllib.parse.urlencode(
            {
                "state": state,
                "head": f"{owner}:{branch}",
                "sort": "updated",
                "direction": "desc",
                "per_page": "100",
            }
        )
        payload = self.paginated(f"/repos/{repository}/pulls?{query}")
        return [parse_pull_request(item) for item in payload]

    def branch(self, repository: str, branch: str) -> Branch:
        encoded = urllib.parse.quote(branch, safe="")
        payload, _ = self.request("GET", f"/repos/{repository}/branches/{encoded}")
        return Branch(
            name=str(payload["name"]),
            sha=str(payload["commit"]["sha"]),
            protected=bool(payload["protected"]),
        )

    def pull_request(self, repository: str, number: int) -> PullRequest:
        payload, _ = self.request("GET", f"/repos/{repository}/pulls/{number}")
        return parse_pull_request(payload)

    def delete_branch(self, repository: str, branch: str) -> None:
        encoded = urllib.parse.quote(branch, safe="")
        self.request(
            "DELETE",
            f"/repos/{repository}/git/refs/heads/{encoded}",
            expected=(204,),
        )


def exact_merged_pull_request(
    branch: Branch,
    pull_requests: list[PullRequest],
    repository: str,
    default_branch: str,
) -> PullRequest | None:
    matches = [
        pull_request
        for pull_request in pull_requests
        if pull_request.merged_at is not None
        and pull_request.head_ref == branch.name
        and pull_request.head_sha == branch.sha
        and pull_request.head_repository == repository
        and pull_request.base_ref == default_branch
    ]
    return max(
        matches,
        key=lambda item: item.merged_at or datetime.min.replace(tzinfo=UTC),
        default=None,
    )


def classify_branch(
    branch: Branch,
    *,
    repository: str,
    default_branch: str,
    open_pull_requests: list[PullRequest],
    closed_pull_requests: list[PullRequest],
    now: datetime,
    grace: timedelta,
) -> Decision:
    if branch.name == default_branch:
        return Decision(branch.name, branch.sha, "retained", "default branch")
    if branch.protected:
        return Decision(branch.name, branch.sha, "retained", "protected branch")
    if branch.name.startswith(RETAINED_PREFIXES):
        return Decision(branch.name, branch.sha, "retained", "retained branch class")
    if open_pull_requests:
        return Decision(branch.name, branch.sha, "active", "open pull request")
    merged = exact_merged_pull_request(
        branch, closed_pull_requests, repository, default_branch
    )
    if merged is None:
        return Decision(
            branch.name,
            branch.sha,
            "review",
            "no exact merged pull-request proof",
        )
    assert merged.merged_at is not None
    if now - merged.merged_at < grace:
        return Decision(
            branch.name,
            branch.sha,
            "grace",
            f"merged pull request #{merged.number} is inside the grace period",
            merged.number,
        )
    return Decision(
        branch.name,
        branch.sha,
        "candidate",
        f"exact head of merged pull request #{merged.number}",
        merged.number,
    )


def revalidate_and_delete(
    client: GitHubClient,
    repository: str,
    default_branch: str,
    decision: Decision,
) -> Decision:
    if decision.disposition != "candidate" or decision.pull_request is None:
        return decision
    branch = client.branch(repository, decision.branch)
    if branch.sha != decision.sha or branch.protected:
        return replace(
            decision,
            disposition="preserved",
            reason="branch changed during hygiene run",
        )
    if client.pull_requests(repository, decision.branch, state="open"):
        return replace(
            decision,
            disposition="preserved",
            reason="pull request opened during hygiene run",
        )
    pull_request = client.pull_request(repository, decision.pull_request)
    if exact_merged_pull_request(
        branch, [pull_request], repository, default_branch
    ) is None:
        return replace(
            decision,
            disposition="preserved",
            reason="merged pull-request proof changed",
        )
    client.delete_branch(repository, decision.branch)
    return replace(decision, disposition="deleted")


def render_markdown(
    repository: str,
    default_branch: str,
    apply: bool,
    delete_branch_on_merge: bool,
    decisions: list[Decision],
) -> str:
    lines = [
        "# GitHub repository hygiene report",
        "",
        f"- Repository: `{repository}`",
        f"- Default branch: `{default_branch}`",
        f"- Mode: `{'apply' if apply else 'dry-run'}`",
        "- GitHub delete-on-merge setting: "
        f"`{'enabled' if delete_branch_on_merge else 'disabled'}`",
        f"- Generated: `{datetime.now(UTC).isoformat()}`",
        "",
        "| Disposition | Branch | Pull request | SHA | Reason |",
        "| --- | --- | --- | --- | --- |",
    ]
    for decision in decisions:
        pull_request = f"#{decision.pull_request}" if decision.pull_request else "—"
        fields = [
            decision.disposition,
            decision.branch,
            pull_request,
            decision.sha,
            decision.reason,
        ]
        lines.append(
            "| " + " | ".join(value.replace("|", "\\|") for value in fields) + " |"
        )
    return "\n".join(lines) + "\n"


def write_atomic(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(contents, encoding="utf-8")
    temporary.replace(path)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(arguments)
    if options.grace_days < 1:
        print("github-hygiene: grace period must be at least one day", file=sys.stderr)
        return 2
    try:
        client = GitHubClient(
            os.environ.get("GITHUB_TOKEN", ""),
            os.environ.get("GITHUB_API_URL", "https://api.github.com"),
        )
        repository_data = client.repository(options.repository)
        default_branch = options.default_branch or str(repository_data["default_branch"])
        now = datetime.now(UTC)
        decisions: list[Decision] = []
        for branch in client.branches(options.repository):
            open_pull_requests = client.pull_requests(
                options.repository, branch.name, state="open"
            )
            closed_pull_requests = client.pull_requests(
                options.repository, branch.name, state="closed"
            )
            decision = classify_branch(
                branch,
                repository=options.repository,
                default_branch=default_branch,
                open_pull_requests=open_pull_requests,
                closed_pull_requests=closed_pull_requests,
                now=now,
                grace=timedelta(days=options.grace_days),
            )
            if options.apply:
                decision = revalidate_and_delete(
                    client, options.repository, default_branch, decision
                )
            decisions.append(decision)
        markdown = render_markdown(
            options.repository,
            default_branch,
            options.apply,
            bool(repository_data.get("delete_branch_on_merge")),
            decisions,
        )
        payload = {
            "schema": 1,
            "repository": options.repository,
            "defaultBranch": default_branch,
            "mode": "apply" if options.apply else "dry-run",
            "generatedAt": datetime.now(UTC).isoformat(),
            "deleteBranchOnMerge": bool(repository_data.get("delete_branch_on_merge")),
            "branches": [asdict(decision) for decision in decisions],
        }
        write_atomic(options.report, markdown)
        write_atomic(
            options.json_output,
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
        )
        print(markdown, end="")
        return 0
    except (HygieneError, KeyError, OSError, UnicodeError, ValueError) as error:
        print(f"github-hygiene: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
