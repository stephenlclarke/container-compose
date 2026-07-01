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

"""Wait for a GitHub Actions workflow result for the current commit."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


TERMINAL_FAILURES = {"action_required", "cancelled", "failure", "skipped", "timed_out"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Wait for a workflow to succeed for a commit SHA."
    )
    parser.add_argument("--repo", required=True, help="owner/repo to query")
    parser.add_argument("--workflow", required=True, help="workflow file name or id")
    parser.add_argument("--sha", required=True, help="commit SHA to check")
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--poll-seconds", type=int, default=15)
    return parser.parse_args()


def github_request(url: str, token: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API request failed: {error.code} {detail}") from error


def set_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        print(f"{name}={value}", file=output)


def workflow_runs_url(repo: str, workflow: str, sha: str) -> str:
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    workflow_ref = urllib.parse.quote(workflow, safe="")
    query = urllib.parse.urlencode({"head_sha": sha, "per_page": "50"})
    return f"{api_url}/repos/{repo}/actions/workflows/{workflow_ref}/runs?{query}"


def main() -> int:
    args = parse_args()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        print("GH_TOKEN or GITHUB_TOKEN is required", file=sys.stderr)
        return 2

    deadline = time.monotonic() + args.timeout_seconds
    url = workflow_runs_url(args.repo, args.workflow, args.sha)

    while True:
        runs = github_request(url, token).get("workflow_runs", [])
        if any(run.get("conclusion") == "success" for run in runs):
            set_output("passed", "true")
            print(f"{args.workflow} already passed for {args.sha}")
            return 0

        failed = [
            run
            for run in runs
            if run.get("status") == "completed"
            and run.get("conclusion") in TERMINAL_FAILURES
        ]
        active = [run for run in runs if run.get("status") != "completed"]
        if failed and not active:
            set_output("passed", "false")
            for run in failed[:3]:
                print(
                    f"{args.workflow} ended with {run.get('conclusion')} for {args.sha}: "
                    f"{run.get('html_url')}",
                    file=sys.stderr,
                )
            return 1

        if time.monotonic() >= deadline:
            set_output("passed", "false")
            print(
                f"Timed out waiting for {args.workflow} on {args.sha}; "
                "release validation will run locally.",
                file=sys.stderr,
            )
            return 0

        if active:
            run = active[0]
            print(
                f"Waiting for {args.workflow} {run.get('status')} on {args.sha}: "
                f"{run.get('html_url')}"
            )
        else:
            print(f"Waiting for {args.workflow} to appear for {args.sha}")
        time.sleep(args.poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
