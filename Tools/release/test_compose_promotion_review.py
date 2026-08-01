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

"""Tests for exact-head Compose promotion review evidence."""

from datetime import datetime, timezone
import unittest

from Tools.release.compose_promotion_review import (
    EvidenceError,
    clean_review_comment,
    flatten_rest_pages,
    has_clean_reaction,
    query_failures,
)


HEAD = "a" * 40
REQUEST_TIME = datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc)


def comment(login: str, created_at: str, body: str = "query") -> dict[str, object]:
    return {
        "author": {"login": login},
        "createdAt": created_at,
        "body": body,
        "url": f"https://example.invalid/{created_at}",
    }


def thread_payload(
    comments: list[dict[str, object]],
    *,
    resolved: bool,
    thread_has_next_page: bool = False,
) -> list[dict[str, object]]:
    return [
        {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [
                                {
                                    "isResolved": resolved,
                                    "comments": {
                                        "nodes": comments,
                                        "pageInfo": {
                                            "hasNextPage": thread_has_next_page
                                        },
                                    },
                                }
                            ],
                            "pageInfo": {
                                "hasNextPage": False,
                                "endCursor": None,
                            },
                        }
                    }
                }
            }
        }
    ]


class ComposePromotionReviewTests(unittest.TestCase):
    def test_resolved_query_requires_a_later_owner_answer(self) -> None:
        query = comment(
            "chatgpt-codex-connector",
            "2026-08-01T11:00:00Z",
        )
        owner_answer = comment(
            "stephenlclarke",
            "2026-08-01T11:01:00Z",
            "answered",
        )

        unanswered, after_request = query_failures(
            thread_payload([query, owner_answer], resolved=True),
            "stephenlclarke",
            None,
        )

        self.assertEqual(unanswered, [])
        self.assertEqual(after_request, [])

    def test_unresolved_or_unanswered_query_is_blocking(self) -> None:
        query = comment(
            "chatgpt-codex-connector",
            "2026-08-01T11:00:00Z",
        )

        unresolved, _ = query_failures(
            thread_payload([query], resolved=False),
            "stephenlclarke",
            None,
        )

        self.assertEqual(unresolved, [query])

    def test_any_query_after_request_requires_a_fresh_review(self) -> None:
        query = comment(
            "chatgpt-codex-connector",
            "2026-08-01T12:00:01Z",
        )
        answer = comment(
            "stephenlclarke",
            "2026-08-01T12:00:02Z",
            "answered",
        )

        unanswered, after_request = query_failures(
            thread_payload([query, answer], resolved=True),
            "stephenlclarke",
            REQUEST_TIME,
        )

        self.assertEqual(unanswered, [])
        self.assertEqual(after_request, [query])

    def test_truncated_nested_comment_connection_fails_closed(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "more than 100 comments"):
            query_failures(
                thread_payload([], resolved=True, thread_has_next_page=True),
                "stephenlclarke",
                None,
            )

    def test_clean_comment_names_the_expected_head_prefix(self) -> None:
        comments = [
            {
                "user": {"login": "chatgpt-codex-connector[bot]"},
                "created_at": "2026-08-01T12:00:03Z",
                "body": (
                    "Codex Review: Didn't find any major issues.\n\n"
                    "**Reviewed commit:** `aaaaaaaaaa`"
                ),
                "html_url": "https://example.invalid/clean",
            }
        ]

        self.assertEqual(
            clean_review_comment(comments, HEAD, REQUEST_TIME),
            comments[0],
        )

    def test_clean_comment_rejects_a_stale_reviewed_commit(self) -> None:
        comments = [
            {
                "user": {"login": "chatgpt-codex-connector[bot]"},
                "created_at": "2026-08-01T12:00:03Z",
                "body": (
                    "Codex Review: Didn't find any major issues.\n\n"
                    "**Reviewed commit:** `bbbbbbbbbb`"
                ),
                "html_url": "https://example.invalid/stale",
            }
        ]

        self.assertIsNone(clean_review_comment(comments, HEAD, REQUEST_TIME))

    def test_paginated_rest_payload_is_flattened_without_mixing_shapes(self) -> None:
        self.assertEqual(
            flatten_rest_pages([[{"id": 1}], [{"id": 2}]], "fixture"),
            [{"id": 1}, {"id": 2}],
        )
        with self.assertRaisesRegex(EvidenceError, "mixes"):
            flatten_rest_pages([[{"id": 1}], {"id": 2}], "fixture")

    def test_only_connector_thumbs_up_is_a_clean_reaction(self) -> None:
        self.assertTrue(
            has_clean_reaction(
                [
                    [
                        {
                            "content": "+1",
                            "user": {
                                "login": "chatgpt-codex-connector[bot]"
                            },
                        }
                    ]
                ]
            )
        )
        self.assertFalse(
            has_clean_reaction(
                [[{"content": "+1", "user": {"login": "someone-else"}}]]
            )
        )


if __name__ == "__main__":
    unittest.main()
