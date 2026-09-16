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
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("github-hygiene.py")
WORKFLOW_PATH = MODULE_PATH.parents[2] / ".github/workflows/repository-hygiene.yml"
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
    state: str | None = None,
) -> hygiene.PullRequest:
    return hygiene.PullRequest(
        number,
        branch,
        sha,
        repository,
        base,
        merged_at,
        state or ("closed" if merged_at is not None else "open"),
    )


class GitHubHygieneTests(unittest.TestCase):
    def test_workflow_resolves_current_default_before_checkout(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        resolve = workflow.index("- name: Resolve current default branch")
        checkout = workflow.index("- name: Checkout current default branch")

        self.assertLess(resolve, checkout)
        self.assertIn(
            "ref: ${{ steps.repository.outputs.default_branch }}", workflow
        )
        self.assertIn(
            "DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}", workflow
        )

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
                return []

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, branch: str, _expected_sha: str
            ) -> str:
                self.deleted.append(branch)
                return "deleted"

            def restore_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                raise AssertionError("restore was not expected")

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
                return (
                    [pull_request(merged_at=None)]
                    if self.opened and state == "open"
                    else []
                )

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

    def test_apply_preserves_branch_when_atomic_delete_loses_lease(self) -> None:
        class Client:
            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                return []

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "changed"

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "preserved")
        self.assertIn("atomic deletion", result.reason)

    def test_apply_reconciles_branch_deleted_before_fresh_fetch(self) -> None:
        class Client:
            def branch(self, _repository: str, _name: str) -> hygiene.Branch:
                raise hygiene.GitHubNotFoundError("gone")

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "reconciled")
        self.assertIn("already deleted", result.reason)

    def test_apply_reconciles_branch_deleted_during_atomic_delete(self) -> None:
        class Client:
            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                return []

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "absent"

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "reconciled")
        self.assertIn("concurrently", result.reason)

    def test_apply_restores_branch_when_pr_opens_during_atomic_delete(self) -> None:
        class Client:
            def __init__(self, restoration: str) -> None:
                self.all_queries = 0
                self.restoration = restoration
                self.restored: list[tuple[str, str]] = []

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                if state == "open":
                    return []
                self.all_queries += 1
                return [] if self.all_queries == 1 else [pull_request(number=99)]

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "deleted"

            def restore_branch(
                self, _repository: str, branch: str, expected_sha: str
            ) -> str:
                self.restored.append((branch, expected_sha))
                return self.restoration

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        restored_client = Client("restored")
        restored = hygiene.revalidate_and_delete(
            restored_client, REPOSITORY, DEFAULT_BRANCH, decision
        )
        changed = hygiene.revalidate_and_delete(
            Client("changed"), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(restored.disposition, "preserved")
        self.assertIn("restored", restored.reason)
        self.assertEqual(restored_client.restored, [("feature", "a" * 40)])
        self.assertEqual(changed.disposition, "preserved")
        self.assertIn("changed", changed.reason)

    def test_apply_restores_branch_when_existing_pr_reopens_during_delete(self) -> None:
        class Client:
            def __init__(self) -> None:
                self.all_queries = 0

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                if state == "open":
                    return []
                self.all_queries += 1
                pr_state = "closed" if self.all_queries == 1 else "open"
                return [pull_request(number=88, merged_at=None, state=pr_state)]

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "deleted"

            def restore_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "restored"

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "preserved")
        self.assertIn("restored", result.reason)

    def test_apply_restores_when_post_delete_reconciliation_is_unavailable(self) -> None:
        class Client:
            def __init__(self) -> None:
                self.all_queries = 0
                self.restored = False

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                if state == "open":
                    return []
                self.all_queries += 1
                if self.all_queries == 1:
                    return []
                raise hygiene.HygieneError("temporary API failure")

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "deleted"

            def restore_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                self.restored = True
                return "restored"

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )
        client = Client()

        result = hygiene.revalidate_and_delete(
            client, REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "preserved")
        self.assertIn("unavailable", result.reason)
        self.assertTrue(client.restored)

    def test_apply_preserves_pr_opened_during_all_pr_snapshot(self) -> None:
        class Client:
            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                return [] if state == "open" else [pull_request(merged_at=None)]

        decision = hygiene.Decision(
            "feature", "a" * 40, "candidate", "proved", 12
        )

        result = hygiene.revalidate_and_delete(
            Client(), REPOSITORY, DEFAULT_BRANCH, decision
        )

        self.assertEqual(result.disposition, "preserved")
        self.assertIn("revalidation", result.reason)

    def test_parse_pull_request_handles_missing_repository_and_timestamp(self) -> None:
        payload = {
            "number": "7",
            "head": {"ref": "feature", "sha": "a" * 40, "repo": None},
            "base": {"ref": "main"},
            "merged_at": "2026-09-01T10:20:30Z",
            "state": "closed",
        }

        parsed = hygiene.parse_pull_request(payload)

        self.assertEqual(parsed.number, 7)
        self.assertEqual(parsed.head_repository, "")
        self.assertEqual(parsed.state, "closed")
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
        with self.assertRaisesRegex(hygiene.HygieneError, "invalid GitHub server URL"):
            hygiene.GitHubClient("token", server_url="file:///tmp/github")

    def test_client_request_accepts_json_and_no_content(self) -> None:
        class Response(io.BytesIO):
            def __init__(self, payload: bytes, status: int) -> None:
                super().__init__(payload)
                self.status = status
                self.headers: dict[str, str] = {}

        responses = [
            Response(b'{"ok": true}', 200),
            Response(b"", 204),
            Response(b'{"created": true}', 201),
        ]
        with mock.patch.object(
            hygiene.urllib.request, "urlopen", side_effect=responses
        ) as opened:
            client = hygiene.GitHubClient("secret")
            payload, _ = client.request("GET", "/value")
            no_content, _ = client.request("DELETE", "/value", expected=(204,))
            created, _ = client.request(
                "POST", "/value", expected=(201,), json_body={"value": "safe"}
            )

        self.assertEqual(payload, {"ok": True})
        self.assertIsNone(no_content)
        self.assertEqual(created, {"created": True})
        request = opened.call_args_list[0].args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")
        post_request = opened.call_args_list[2].args[0]
        self.assertEqual(post_request.data, b'{"value":"safe"}')

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

        not_found = urllib.error.HTTPError(
            "https://api.github.com/value",
            404,
            "not found",
            {},
            io.BytesIO(b"gone"),
        )
        with mock.patch.object(
            hygiene.urllib.request, "urlopen", side_effect=not_found
        ):
            with self.assertRaisesRegex(hygiene.GitHubNotFoundError, "404: gone"):
                hygiene.GitHubClient("secret").request("GET", "/value")

        conflict = urllib.error.HTTPError(
            "https://api.github.com/value",
            422,
            "conflict",
            {},
            io.BytesIO(b"exists"),
        )
        with mock.patch.object(
            hygiene.urllib.request, "urlopen", side_effect=conflict
        ):
            with self.assertRaisesRegex(hygiene.GitHubConflictError, "422: exists"):
                hygiene.GitHubClient("secret").request("POST", "/value")

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

        self.assertIn("head=example%3Afeature%2Fone", client.paginated.call_args_list[1].args[0])
        self.assertEqual(
            client.request.call_args_list[1].args[1],
            "/repos/example/project/branches/feature%2Fone",
        )

    def test_conditional_delete_uses_atomic_force_with_lease(self) -> None:
        client = hygiene.GitHubClient("secret")
        completed = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(hygiene.subprocess, "run", return_value=completed) as run:
            self.assertEqual(
                client.delete_branch(REPOSITORY, "feature/one", "a" * 40),
                "deleted",
            )

        command = run.call_args.args[0]
        environment = run.call_args.kwargs["env"]
        self.assertIn(
            f"--force-with-lease=refs/heads/feature/one:{'a' * 40}",
            command,
        )
        self.assertEqual(command[-1], ":refs/heads/feature/one")
        self.assertNotIn("secret", " ".join(command))
        self.assertEqual(environment["REPOSITORY_HYGIENE_TOKEN"], "secret")

    def test_conditional_delete_preserves_changed_head_and_reports_other_failures(
        self,
    ) -> None:
        client = hygiene.GitHubClient("secret")
        failed = subprocess.CompletedProcess([], 1, "", "rejected")
        with mock.patch.object(hygiene.subprocess, "run", return_value=failed):
            client.branch = mock.Mock(
                return_value=hygiene.Branch("feature", "b" * 40, False)
            )
            self.assertEqual(
                client.delete_branch(REPOSITORY, "feature", "a" * 40),
                "changed",
            )

            client.branch = mock.Mock(
                side_effect=hygiene.GitHubNotFoundError("gone")
            )
            self.assertEqual(
                client.delete_branch(REPOSITORY, "feature", "a" * 40),
                "absent",
            )

            client.branch = mock.Mock(
                return_value=hygiene.Branch("feature", "a" * 40, False)
            )
            with self.assertRaisesRegex(hygiene.HygieneError, "rejected"):
                client.delete_branch(REPOSITORY, "feature", "a" * 40)

        with self.assertRaisesRegex(hygiene.HygieneError, "invalid GitHub repository"):
            client.delete_branch("invalid", "feature", "a" * 40)
        with self.assertRaisesRegex(hygiene.HygieneError, "invalid expected branch SHA"):
            client.delete_branch(REPOSITORY, "feature", "invalid")

    def test_restore_branch_creates_only_an_absent_reference(self) -> None:
        client = hygiene.GitHubClient("secret")
        client.request = mock.Mock(
            return_value=({"ref": "refs/heads/feature"}, object())
        )

        self.assertEqual(
            client.restore_branch(REPOSITORY, "feature", "a" * 40),
            "restored",
        )
        self.assertEqual(
            client.request.call_args.args[:2],
            ("POST", "/repos/example/project/git/refs"),
        )
        self.assertEqual(
            client.request.call_args.kwargs["json_body"],
            {"ref": "refs/heads/feature", "sha": "a" * 40},
        )

        client.request = mock.Mock(side_effect=hygiene.GitHubConflictError("exists"))
        client.branch = mock.Mock(
            return_value=hygiene.Branch("feature", "a" * 40, False)
        )
        self.assertEqual(
            client.restore_branch(REPOSITORY, "feature", "a" * 40),
            "present",
        )
        client.branch = mock.Mock(
            return_value=hygiene.Branch("feature", "b" * 40, False)
        )
        self.assertEqual(
            client.restore_branch(REPOSITORY, "feature", "a" * 40),
            "changed",
        )
        client.branch = mock.Mock(side_effect=hygiene.GitHubNotFoundError("gone"))
        with self.assertRaisesRegex(hygiene.GitHubConflictError, "exists"):
            client.restore_branch(REPOSITORY, "feature", "a" * 40)

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
            def __init__(self, *_arguments: str) -> None:
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

            def delete_branch(
                self, _repository: str, branch: str, _expected_sha: str
            ) -> str:
                self.deleted.append(branch)
                return "deleted"

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
            self.assertEqual(payload["status"], "success")
            self.assertEqual(payload["branches"][0]["disposition"], "deleted")
            self.assertEqual(client.deleted, ["feature"])
            self.assertIn("GitHub repository hygiene report", report.read_text())

    def test_main_retains_partial_report_when_later_branch_fails(self) -> None:
        class Client:
            def __init__(self, *_arguments: str) -> None:
                self.deleted: list[str] = []

            def repository(self, _repository: str) -> dict[str, object]:
                return {"default_branch": "main", "delete_branch_on_merge": True}

            def branches(self, _repository: str) -> list[hygiene.Branch]:
                return [
                    hygiene.Branch("first", "a" * 40, False),
                    hygiene.Branch("second", "b" * 40, False),
                ]

            def pull_requests(
                self, _repository: str, branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                if branch == "second":
                    raise hygiene.HygieneError("fixture later-branch failure")
                if state == "open":
                    return []
                return [pull_request(branch="first")]

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request(branch="first")

            def delete_branch(
                self, _repository: str, branch: str, _expected_sha: str
            ) -> str:
                self.deleted.append(branch)
                return "deleted"

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.md"
            machine = root / "report.json"
            client = Client("token")
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
                    self.assertEqual(hygiene.main(arguments), 2)

            payload = json.loads(machine.read_text(encoding="utf-8"))
            self.assertEqual(client.deleted, ["first"])
            self.assertEqual(payload["status"], "failed")
            self.assertEqual(payload["branches"][0]["disposition"], "deleted")
            self.assertEqual(payload["error"], "fixture later-branch failure")
            self.assertIn("Status: `failed`", report.read_text(encoding="utf-8"))

    def test_main_journals_deletion_before_reconciliation_failure(self) -> None:
        class Client:
            def __init__(self, *_arguments: str) -> None:
                self.all_queries = 0

            def repository(self, _repository: str) -> dict[str, object]:
                return {"default_branch": "main"}

            def branches(self, _repository: str) -> list[hygiene.Branch]:
                return [hygiene.Branch("feature", "a" * 40, False)]

            def pull_requests(
                self, _repository: str, _branch: str, *, state: str
            ) -> list[hygiene.PullRequest]:
                if state == "open":
                    return []
                if state == "closed":
                    return [pull_request()]
                self.all_queries += 1
                if self.all_queries == 1:
                    return [pull_request()]
                raise hygiene.HygieneError("post-delete unavailable")

            def branch(self, _repository: str, name: str) -> hygiene.Branch:
                return hygiene.Branch(name, "a" * 40, False)

            def pull_request(
                self, _repository: str, _number: int
            ) -> hygiene.PullRequest:
                return pull_request()

            def delete_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                return "deleted"

            def restore_branch(
                self, _repository: str, _branch: str, _expected_sha: str
            ) -> str:
                raise hygiene.HygieneError("restoration unavailable")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            machine = root / "report.json"
            arguments = [
                "--repository",
                REPOSITORY,
                "--apply",
                "--report",
                str(root / "report.md"),
                "--json-output",
                str(machine),
            ]
            with mock.patch.object(hygiene, "GitHubClient", return_value=Client()):
                with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "token"}):
                    self.assertEqual(hygiene.main(arguments), 2)

            payload = json.loads(machine.read_text(encoding="utf-8"))
            self.assertEqual(payload["status"], "failed")
            self.assertEqual(payload["branches"][0]["disposition"], "deleted")
            self.assertIn("reconciliation pending", payload["branches"][0]["reason"])
            self.assertEqual(payload["error"], "restoration unavailable")

    def test_main_rejects_stale_supplied_default_branch(self) -> None:
        class Client:
            def __init__(self, *_arguments: str) -> None:
                pass

            def repository(self, _repository: str) -> dict[str, object]:
                return {"default_branch": "trunk"}

            def branches(self, _repository: str) -> list[hygiene.Branch]:
                raise AssertionError("stale default branch must stop before listing")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            machine = root / "report.json"
            arguments = [
                "--repository",
                REPOSITORY,
                "--default-branch",
                "main",
                "--report",
                str(root / "report.md"),
                "--json-output",
                str(machine),
            ]
            with mock.patch.object(hygiene, "GitHubClient", return_value=Client()):
                with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "token"}):
                    self.assertEqual(hygiene.main(arguments), 2)

            payload = json.loads(machine.read_text(encoding="utf-8"))
            self.assertEqual(payload["status"], "failed")
            self.assertIn("stale", payload["error"])
            self.assertEqual(payload["branches"], [])

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
