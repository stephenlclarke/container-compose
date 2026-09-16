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

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("github-hygiene.py")
SPEC = importlib.util.spec_from_file_location("github_hygiene", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
hygiene = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = hygiene
SPEC.loader.exec_module(hygiene)


REPOSITORY = "example/project"
DEFAULT_BRANCH = "main"
NOW = datetime(2026, 9, 16, tzinfo=UTC)


def pull_request(
    *,
    number: int = 12,
    branch: str = "feature",
    sha: str = "a" * 40,
    repository: str = REPOSITORY,
    base: str = DEFAULT_BRANCH,
    merged_at: datetime | None = NOW - timedelta(days=8),
) -> hygiene.PullRequest:
    return hygiene.PullRequest(number, branch, sha, repository, base, merged_at)


class GitHubHygieneTests(unittest.TestCase):
    def classify(
        self,
        branch: hygiene.Branch,
        *,
        opened: list[hygiene.PullRequest] | None = None,
        closed: list[hygiene.PullRequest] | None = None,
    ) -> hygiene.Decision:
        return hygiene.classify_branch(
            branch,
            repository=REPOSITORY,
            default_branch=DEFAULT_BRANCH,
            open_pull_requests=opened or [],
            closed_pull_requests=closed or [],
            now=NOW,
            grace=timedelta(days=7),
        )

    def test_only_exact_aged_merged_pull_request_head_is_candidate(self) -> None:
        branch = hygiene.Branch("feature", "a" * 40, False)

        decision = self.classify(branch, closed=[pull_request()])

        self.assertEqual(decision.disposition, "candidate")
        self.assertEqual(decision.pull_request, 12)

    def test_default_protected_and_retained_classes_are_never_candidates(self) -> None:
        cases = (
            hygiene.Branch(DEFAULT_BRANCH, "a" * 40, False),
            hygiene.Branch("protected", "a" * 40, True),
            hygiene.Branch("upstream/apple-fix", "a" * 40, False),
            hygiene.Branch("release/1.2.3", "a" * 40, False),
            hygiene.Branch("release-0.14", "a" * 40, False),
            hygiene.Branch("archive/history", "a" * 40, False),
        )
        for branch in cases:
            with self.subTest(branch=branch.name):
                self.assertEqual(
                    self.classify(branch, closed=[pull_request(branch=branch.name)]).disposition,
                    "retained",
                )

    def test_open_pull_request_wins_over_old_merged_pull_request(self) -> None:
        branch = hygiene.Branch("feature", "a" * 40, False)

        decision = self.classify(
            branch,
            opened=[pull_request(merged_at=None)],
            closed=[pull_request()],
        )

        self.assertEqual(decision.disposition, "active")

    def test_changed_or_cross_repository_merged_head_requires_review(self) -> None:
        branch = hygiene.Branch("feature", "b" * 40, False)
        for merged in (
            pull_request(sha="a" * 40),
            pull_request(sha="b" * 40, repository="fork/project"),
            pull_request(sha="b" * 40, base="develop"),
        ):
            with self.subTest(merged=merged):
                self.assertEqual(
                    self.classify(branch, closed=[merged]).disposition,
                    "review",
                )

    def test_recent_merge_observes_grace_period(self) -> None:
        branch = hygiene.Branch("feature", "a" * 40, False)

        decision = self.classify(
            branch,
            closed=[pull_request(merged_at=NOW - timedelta(days=1))],
        )

        self.assertEqual(decision.disposition, "grace")

    def test_apply_revalidates_sha_open_pr_and_merged_proof(self) -> None:
        class Client:
            def __init__(self) -> None:
                self.deleted: list[str] = []

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                self.assert_state = state
                return []

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(self, _repository: str, branch: str) -> None:
                self.deleted.append(branch)

        client = Client()
        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            client, REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "deleted")
        self.assertEqual(client.deleted, ["feature"])

    def test_apply_preserves_branch_when_sha_changes(self) -> None:
        class Client:
            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "b" * 40, False)

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "preserved")

    def test_apply_preserves_branch_when_open_pr_or_merge_proof_changes(self) -> None:
        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        class Client:
            def __init__(self, *, opened: bool) -> None:
                self.opened = opened

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                self.state = state
                return [pull_request(merged_at=None)] if self.opened else []

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request(sha="b" * 40)

        opened = hygiene.revalidate_and_delete(
            Client(opened=True), REPOSITORY, DEFAULT_BRANCH, decision
        )
        changed = hygiene.revalidate_and_delete(
            Client(opened=False), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(opened.disposition, "preserved")
        self.assertIn("opened", opened.reason)
        self.assertEqual(changed.disposition, "preserved")
        self.assertIn("proof changed", changed.reason)

    def test_apply_ignores_non_candidate(self) -> None:
        decision = hygiene.Decision("feature", "a" * 40, "active", "open")
        self.assertIs(
            hygiene.revalidate_and_delete(
                object(), REPOSITORY, DEFAULT_BRANCH, decision
            ),
            decision,
        )

    def test_parse_pull_request_handles_missing_repository_and_timestamp(self) -> None:
        payload = {
            "number": "7",
            "head": {"ref": "feature", "sha": "a" * 40, "repo": None},
            "base": {"ref": "main"},
            "merged_at": "2026-09-01T10:20:30Z",
        }

        parsed = hygiene.parse_pull_request(payload)

        self.assertEqual(parsed.number, 7)
        self.assertEqual(parsed.head_repository, "")
        self.assertEqual(parsed.merged_at, datetime(2026, 9, 1, 10, 20, 30, tzinfo=UTC))
        self.assertIsNone(hygiene.parse_timestamp(None))

    def test_client_requires_token_and_normalizes_api_url(self) -> None:
        with self.assertRaisesRegex(hygiene.HygieneError, "GITHUB_TOKEN"):
            hygiene.GitHubClient("")
        self.assertEqual(
            hygiene.GitHubClient("token", "https://example.invalid/").api_url,
            "https://example.invalid",
        )
        with self.assertRaisesRegex(hygiene.HygieneError, "invalid GitHub API URL"):
            hygiene.GitHubClient("token", "file:///tmp/github")

    def test_client_request_accepts_json_and_no_content(self) -> None:
        class Response(io.BytesIO):
            def __init__(self, payload: bytes, status: int) -> None:
                super().__init__(payload)
                self.status = status
                self.headers: dict[str, str] = {}

        responses = [Response(b'{"ok": true}', 200), Response(b"", 204)]
        with mock.patch.object(
            hygiene.urllib.request, "urlopen", side_effect=responses
        ) as opened:
            client = hygiene.GitHubClient("secret")
            payload, _ = client.request("GET", "/value")
            no_content, _ = client.request("DELETE", "/value", expected=(204,))

        self.assertEqual(payload, {"ok": True})
        self.assertIsNone(no_content)
        request = opened.call_args_list[0].args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")

    def test_client_request_reports_http_and_unexpected_status(self) -> None:
        http_error = urllib.error.HTTPError(
            "https://api.github.com/value",
            403,
            "forbidden",
            {},
            io.BytesIO(b"denied"),
        )
        with mock.patch.object(
            hygiene.urllib.request, "urlopen", side_effect=http_error
        ):
            with self.assertRaisesRegex(hygiene.HygieneError, "403: denied"):
                hygiene.GitHubClient("secret").request("GET", "/value")

        response = io.BytesIO(b"unexpected")
        response.status = 201
        response.headers = {}
        with mock.patch.object(hygiene.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(hygiene.HygieneError, "unexpected status 201"):
                hygiene.GitHubClient("secret").request("GET", "/value")

    def test_client_pagination_follows_only_same_origin(self) -> None:
        class Response:
            def __init__(self, link: str = "") -> None:
                self.headers = {"Link": link}

        client = hygiene.GitHubClient("secret")
        client.request = mock.Mock(
            side_effect=[
                (
                    [{"page": 1}],
                    Response(
                        '<https://api.github.com/items?page=2>; rel="next", '
                        '<https://api.github.com/items?page=2>; rel="last"'
                    ),
                ),
                ([{"page": 2}], Response()),
            ]
        )
        self.assertEqual(client.paginated("/items?page=1"), [{"page": 1}, {"page": 2}])

        client.request = mock.Mock(
            return_value=([], Response('<https://evil.invalid/items>; rel="next"'))
        )
        with self.assertRaisesRegex(hygiene.HygieneError, "escaped"):
            client.paginated("/items")

        client.request = mock.Mock(return_value=({}, Response()))
        with self.assertRaisesRegex(hygiene.HygieneError, "non-list"):
            client.paginated("/items")

    def test_client_pagination_preserves_enterprise_api_base_path(self) -> None:
        class Response:
            def __init__(self, link: str = "") -> None:
                self.headers = {"Link": link}

        client = hygiene.GitHubClient("secret", "https://github.example/api/v3")
        client.request = mock.Mock(
            side_effect=[
                (
                    [{"page": 1}],
                    Response(
                        '<https://github.example/api/v3/items?page=2>; rel="next"'
                    ),
                ),
                ([{"page": 2}], Response()),
            ]
        )

        self.assertEqual(client.paginated("/items?page=1"), [{"page": 1}, {"page": 2}])
        self.assertEqual(client.request.call_args_list[1].args[1], "/items?page=2")

        client.request = mock.Mock(
            return_value=(
                [],
                Response('<https://github.example/not-api/items>; rel="next"'),
            )
        )
        with self.assertRaisesRegex(hygiene.HygieneError, "base path"):
            client.paginated("/items")

    def test_client_resource_methods_parse_and_encode(self) -> None:
        pull_payload = {
            "number": 12,
            "head": {
                "ref": "feature/one",
                "sha": "a" * 40,
                "repo": {"full_name": REPOSITORY},
            },
            "base": {"ref": DEFAULT_BRANCH},
            "merged_at": "2026-09-01T00:00:00Z",
        }
        client = hygiene.GitHubClient("secret")
        client.request = mock.Mock(
            side_effect=[
                ({"default_branch": "main"}, object()),
                (
                    {
                        "name": "feature/one",
                        "commit": {"sha": "a" * 40},
                        "protected": False,
                    },
                    object(),
                ),
                (pull_payload, object()),
                (None, object()),
            ]
        )
        client.paginated = mock.Mock(
            side_effect=[
                [
                    {
                        "name": "feature/one",
                        "commit": {"sha": "a" * 40},
                        "protected": False,
                    }
                ],
                [pull_payload],
            ]
        )

        self.assertEqual(client.repository(REPOSITORY)["default_branch"], "main")
        self.assertEqual(client.branches(REPOSITORY)[0].name, "feature/one")
        self.assertEqual(
            client.pull_requests(REPOSITORY, "feature/one", state="closed")[0].number,
            12,
        )
        self.assertEqual(client.branch(REPOSITORY, "feature/one").name, "feature/one")
        self.assertEqual(client.pull_request(REPOSITORY, 12).number, 12)
        client.delete_branch(REPOSITORY, "feature/one")

        self.assertIn("head=example%3Afeature%2Fone", client.paginated.call_args_list[1].args[0])
        self.assertEqual(
            client.request.call_args_list[1].args[1],
            "/repos/example/project/branches/feature%2Fone",
        )
        self.assertEqual(
            client.request.call_args_list[3].args[1],
            "/repos/example/project/git/refs/heads/feature%2Fone",
        )

    def test_client_rejects_invalid_repository_payload(self) -> None:
        client = hygiene.GitHubClient("secret")
        client.request = mock.Mock(return_value=([], object()))
        with self.assertRaisesRegex(hygiene.HygieneError, "response is invalid"):
            client.repository(REPOSITORY)

    def test_report_rendering_and_atomic_write(self) -> None:
        decision = hygiene.Decision("feature|one", "a" * 40, "review", "why|now")
        markdown = hygiene.render_markdown(
            REPOSITORY, DEFAULT_BRANCH, False, True, [decision]
        )
        self.assertIn("Mode: `dry-run`", markdown)
        self.assertIn("feature\\|one", markdown)
        self.assertIn("why\\|now", markdown)

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "nested" / "report.md"
            hygiene.write_atomic(destination, markdown)
            self.assertEqual(destination.read_text(encoding="utf-8"), markdown)

    def test_main_writes_dry_run_reports_and_apply_deletes(self) -> None:
        class Client:
            def __init__(self, _token: str, _api_url: str) -> None:
                self.deleted: list[str] = []

            def repository(self, _repository: str) -> dict[str, object]:
                return {"default_branch": "main", "delete_branch_on_merge": True}

            def branches(self, _repository: str) -> list[hygiene.Branch]:
                return [hygiene.Branch("feature", "a" * 40, False)]

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                return [] if state == "open" else [pull_request()]

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(self, _repository: str, branch: str) -> None:
                self.deleted.append(branch)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.md"
            machine = root / "report.json"
            client = Client("token", "api")
            arguments = [
                "--repository",
                REPOSITORY,
                "--apply",
                "--report",
                str(report),
                "--json-output",
                str(machine),
            ]
            with mock.patch.object(hygiene, "GitHubClient", return_value=client):
                with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "token"}):
                    self.assertEqual(hygiene.main(arguments), 0)

            payload = json.loads(machine.read_text(encoding="utf-8"))
            self.assertEqual(payload["mode"], "apply")
            self.assertEqual(payload["branches"][0]["disposition"], "deleted")
            self.assertEqual(client.deleted, ["feature"])
            self.assertIn("GitHub repository hygiene report", report.read_text())

    def test_main_rejects_bad_grace_and_reports_client_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = [
                "--repository",
                REPOSITORY,
                "--grace-days",
                "0",
                "--report",
                str(root / "report.md"),
                "--json-output",
                str(root / "report.json"),
            ]
            self.assertEqual(hygiene.main(arguments), 2)
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(hygiene.main(arguments[:2] + arguments[4:]), 2)


if __name__ == "__main__":
    unittest.main()
