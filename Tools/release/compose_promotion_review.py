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

"""Evaluate fail-closed Codex review evidence for Compose promotion PRs."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import re
import sys
from typing import Any, Iterable


CONNECTOR_LOGINS = {
    "chatgpt-codex-connector",
    "chatgpt-codex-connector[bot]",
}
MINIMUM_REVIEWED_PREFIX_LENGTH = 10
REVIEWED_COMMIT_PATTERN = re.compile(
    r"Reviewed commit:\s*\*{0,2}\s*`([0-9a-fA-F]{7,40})`",
    re.IGNORECASE,
)


class EvidenceError(ValueError):
    """Raised when GitHub evidence is incomplete or malformed."""


def parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{label} is missing a timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{label} has an invalid timestamp: {value}") from error
    if parsed.tzinfo is None:
        raise EvidenceError(f"{label} timestamp has no timezone: {value}")
    return parsed


def is_connector(login: Any) -> bool:
    return isinstance(login, str) and login in CONNECTOR_LOGINS


def flatten_rest_pages(payload: Any, label: str) -> list[dict[str, Any]]:
    """Accept one REST page or gh --paginate --slurp output."""

    if not isinstance(payload, list):
        raise EvidenceError(f"{label} must be a JSON array")
    values: list[Any]
    if payload and all(isinstance(page, list) for page in payload):
        values = [item for page in payload for item in page]
    elif any(isinstance(page, list) for page in payload):
        raise EvidenceError(f"{label} mixes paginated and unpaginated values")
    else:
        values = payload
    if not all(isinstance(item, dict) for item in values):
        raise EvidenceError(f"{label} contains a non-object value")
    return values


def graphql_pages(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        return [payload]
    if isinstance(payload, list) and payload and all(
        isinstance(page, dict) for page in payload
    ):
        return payload
    raise EvidenceError("review-thread response must contain one or more GraphQL pages")


def review_threads(payload: Any) -> list[dict[str, Any]]:
    pages = graphql_pages(payload)
    collected: list[dict[str, Any]] = []
    for index, page in enumerate(pages):
        try:
            pull_request = page["data"]["repository"]["pullRequest"]
            connection = pull_request["reviewThreads"]
            nodes = connection["nodes"]
            page_info = connection["pageInfo"]
        except (KeyError, TypeError) as error:
            raise EvidenceError("review-thread response is incomplete") from error
        if pull_request is None:
            raise EvidenceError("promotion pull request does not exist")
        if not isinstance(nodes, list) or not all(
            isinstance(node, dict) for node in nodes
        ):
            raise EvidenceError("review-thread nodes are malformed")
        if not isinstance(page_info, dict) or not isinstance(
            page_info.get("hasNextPage"), bool
        ):
            raise EvidenceError("review-thread pagination metadata is missing")
        if index < len(pages) - 1 and not page_info["hasNextPage"]:
            raise EvidenceError("review-thread pagination ended before the final page")
        if index == len(pages) - 1 and page_info["hasNextPage"]:
            raise EvidenceError("review-thread response is truncated")
        collected.extend(nodes)
    return collected


def author_login(comment: dict[str, Any]) -> str | None:
    author = comment.get("author")
    if author is None:
        return None
    if not isinstance(author, dict):
        raise EvidenceError("review comment author is malformed")
    login = author.get("login")
    if login is not None and not isinstance(login, str):
        raise EvidenceError("review comment author login is malformed")
    return login


def thread_comments(thread: dict[str, Any]) -> list[dict[str, Any]]:
    connection = thread.get("comments")
    if not isinstance(connection, dict):
        raise EvidenceError("review thread has no comment connection")
    page_info = connection.get("pageInfo")
    if not isinstance(page_info, dict) or not isinstance(
        page_info.get("hasNextPage"), bool
    ):
        raise EvidenceError("review-comment pagination metadata is missing")
    if page_info["hasNextPage"]:
        raise EvidenceError("review thread has more than 100 comments and is truncated")
    nodes = connection.get("nodes")
    if not isinstance(nodes, list) or not all(
        isinstance(comment, dict) for comment in nodes
    ):
        raise EvidenceError("review-thread comments are malformed")
    return nodes


def describe_query(comment: dict[str, Any]) -> str:
    url = comment.get("url")
    body = comment.get("body")
    if not isinstance(url, str) or not url:
        url = "(query URL unavailable)"
    if not isinstance(body, str) or not body.strip():
        body = "(query body unavailable)"
    return f"{url}\n{body.strip()}"


def query_failures(
    payload: Any,
    owner: str,
    since: datetime | None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not owner:
        raise EvidenceError("repository owner login is empty")
    unanswered: list[dict[str, Any]] = []
    after_request: list[dict[str, Any]] = []
    for thread in review_threads(payload):
        comments = thread_comments(thread)
        connector_comments = [
            comment for comment in comments if is_connector(author_login(comment))
        ]
        if not connector_comments:
            continue
        is_resolved = thread.get("isResolved")
        if not isinstance(is_resolved, bool):
            raise EvidenceError("review thread has no resolved state")
        parsed = [
            (comment, parse_timestamp(comment.get("createdAt"), "review comment"))
            for comment in comments
        ]
        for connector_comment in connector_comments:
            connector_created = parse_timestamp(
                connector_comment.get("createdAt"), "Codex review query"
            )
            if since is not None and connector_created >= since:
                after_request.append(connector_comment)
            answered = any(
                author_login(candidate) == owner and candidate_created > connector_created
                for candidate, candidate_created in parsed
            )
            if not answered or not is_resolved:
                unanswered.append(connector_comment)
    return unanswered, after_request


def command_queries(arguments: argparse.Namespace) -> int:
    payload = json.load(sys.stdin)
    since = (
        parse_timestamp(arguments.since, "review request")
        if arguments.since is not None
        else None
    )
    unanswered, after_request = query_failures(payload, arguments.owner, since)
    if after_request:
        print(
            "Codex posted a query after the current review request; answer it, "
            "resolve its thread, and rerun promotion for a fresh exact-head review.",
            file=sys.stderr,
        )
        for comment in after_request:
            print(describe_query(comment), file=sys.stderr)
        return 3
    if unanswered:
        print(
            "Codex review queries must receive a later owner response and be resolved "
            "before promotion can request or accept another review.",
            file=sys.stderr,
        )
        for comment in unanswered:
            print(describe_query(comment), file=sys.stderr)
        return 2
    return 0


def has_clean_reaction(payload: Any) -> bool:
    for reaction in flatten_rest_pages(payload, "review-request reactions"):
        user = reaction.get("user")
        login = user.get("login") if isinstance(user, dict) else None
        if reaction.get("content") == "+1" and is_connector(login):
            return True
    return False


def command_reaction_clean(_arguments: argparse.Namespace) -> int:
    payload = json.load(sys.stdin)
    return 0 if has_clean_reaction(payload) else 1


def clean_review_comment(
    comments: Iterable[dict[str, Any]],
    head: str,
    since: datetime,
) -> dict[str, Any] | None:
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise EvidenceError("expected pull-request head must be a full lowercase commit ID")
    for comment in comments:
        user = comment.get("user")
        login = user.get("login") if isinstance(user, dict) else None
        if not is_connector(login):
            continue
        created = parse_timestamp(comment.get("created_at"), "issue comment")
        if created < since:
            continue
        body = comment.get("body")
        if not isinstance(body, str):
            raise EvidenceError("connector issue comment body is malformed")
        normalized = body.replace("’", "'").lower()
        if "didn't find any major issues" not in normalized:
            continue
        match = REVIEWED_COMMIT_PATTERN.search(body)
        if match is None:
            continue
        reviewed = match.group(1).lower()
        if len(reviewed) < MINIMUM_REVIEWED_PREFIX_LENGTH:
            continue
        if reviewed == head[: len(reviewed)]:
            return comment
    return None


def command_comment_clean(arguments: argparse.Namespace) -> int:
    payload = json.load(sys.stdin)
    comments = flatten_rest_pages(payload, "pull-request issue comments")
    since = parse_timestamp(arguments.since, "review request")
    clean = clean_review_comment(comments, arguments.head, since)
    if clean is None:
        return 1
    url = clean.get("html_url")
    if isinstance(url, str) and url:
        print(url)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    queries = commands.add_parser("queries")
    queries.add_argument("--owner", required=True)
    queries.add_argument("--since")
    queries.set_defaults(handler=command_queries)

    reaction = commands.add_parser("reaction-clean")
    reaction.set_defaults(handler=command_reaction_clean)

    comment = commands.add_parser("comment-clean")
    comment.add_argument("--head", required=True)
    comment.add_argument("--since", required=True)
    comment.set_defaults(handler=command_comment_clean)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        return int(arguments.handler(arguments))
    except (EvidenceError, json.JSONDecodeError) as error:
        print(f"invalid Compose promotion review evidence: {error}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
