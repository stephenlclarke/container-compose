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

"""Capture SonarQube and CodeQL metrics for a release-note quality snapshot."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from collections.abc import Iterable
from typing import Any


SONARQUBE_URL = "https://sonarcloud.io"
SONARQUBE_PROJECT = "stephenlclarke_container-compose2"
SONARQUBE_BRANCH = "main"
CODEQL_REF = "refs/heads/main"
POLL_INTERVAL_SECONDS = 10
# A main CodeQL analysis is allowed to use its full workflow timeout. Package
# publication may start before CodeQL completes, so a 30-minute window prevents
# a valid slower analysis from producing a release without its quality snapshot.
POLL_TIMEOUT_SECONDS = 1800
SHIELDS_STATIC_BADGE_URL = "https://img.shields.io/static/v1"
BADGE_CACHE_SECONDS = "300"
BADGE_DELIVERY_ATTEMPTS = 3

BADGE_COLORS = {
    "blue": "#007ec6",
    "brightgreen": "#4c1",
    "orange": "#fe7d37",
    "red": "#e05d44",
}
BADGE_HEIGHT = 20
BADGE_GAP = 8
BADGE_MARGIN = 8
BADGE_MAX_ROW_WIDTH = 1200

SONARQUBE_METRICS = (
    "alert_status",
    "bugs",
    "code_smells",
    "coverage",
    "duplicated_lines_density",
    "ncloc",
    "reliability_rating",
    "security_rating",
    "sqale_index",
    "sqale_rating",
    "vulnerabilities",
)


@dataclass(frozen=True)
class SnapshotBadge:
    """One quality metric rendered into the release-owned SVG."""

    label: str
    message: str
    color: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture a static SonarQube and CodeQL release-note snapshot."
    )
    parser.add_argument("--repo", required=True, help="GitHub owner/repository")
    parser.add_argument("--commit", required=True, help="Promoted commit SHA")
    parser.add_argument(
        "--release-kind",
        choices=("current", "stable"),
        default="stable",
        help="Whether this snapshot belongs to the mutable current build or an immutable stable release",
    )
    parser.add_argument("--sonarqube-url", default=SONARQUBE_URL)
    parser.add_argument("--sonarqube-project", default=SONARQUBE_PROJECT)
    parser.add_argument("--sonarqube-branch", default=SONARQUBE_BRANCH)
    parser.add_argument("--codeql-ref", default=CODEQL_REF)
    parser.add_argument(
        "--svg-output",
        type=Path,
        help="Write the release-owned SVG snapshot to this path",
    )
    parser.add_argument(
        "--asset-url",
        help="GitHub release-asset URL used by the rendered Markdown snapshot",
    )
    parser.add_argument(
        "--badge-snapshot-id",
        help=(
            "Unique static-badge delivery key; defaults to --commit and keeps "
            "GitHub's image proxy cache isolated to this publication"
        ),
    )
    parser.add_argument(
        "--verify-static-badges",
        action="store_true",
        help=(
            "Render every static badge through GitHub Markdown and require "
            "each exact proxied image to be valid SVG before printing notes"
        ),
    )
    parser.add_argument(
        "--allow-missing-sonarqube",
        action="store_true",
        help=(
            "Allow a current-build snapshot with exact CodeQL evidence but no "
            "SonarQube metrics when the validated CI run did not produce a "
            "SonarQube scan"
        ),
    )
    parser.add_argument("--poll-interval", type=int, default=POLL_INTERVAL_SECONDS)
    parser.add_argument("--poll-timeout", type=int, default=POLL_TIMEOUT_SECONDS)
    parser.add_argument("--gh", default="gh", help="GitHub CLI executable")
    return parser.parse_args()


def request_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
    except urllib.error.URLError as error:
        raise ValueError(f"request failed for {url}: {error}") from error
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ValueError(f"response from {url} was not JSON") from error
    if not isinstance(value, dict):
        raise ValueError(f"response from {url} was not an object")
    return value


def sonar_url(host: str, path: str, parameters: dict[str, str]) -> str:
    return f"{host.rstrip('/')}{path}?{urllib.parse.urlencode(parameters)}"


def gh_json(gh: str, *arguments: str) -> Any:
    result = subprocess.run(
        [gh, "api", *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise ValueError(f"GitHub API request failed: {message}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub API returned invalid JSON") from error


def gh_text(gh: str, *arguments: str) -> str:
    """Return text from a GitHub CLI API call with an actionable failure."""

    result = subprocess.run(
        [gh, "api", *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise ValueError(f"GitHub API request failed: {message}")
    return result.stdout


def find_sonarqube_analysis(
    *, host: str, project: str, branch: str, commit: str
) -> dict[str, Any] | None:
    response = request_json(
        sonar_url(
            host,
            "/api/project_analyses/search",
            {"project": project, "branch": branch, "ps": "500"},
        )
    )
    analyses = response.get("analyses")
    if not isinstance(analyses, list):
        raise ValueError("SonarQube did not return an analyses list")
    for analysis in analyses:
        if isinstance(analysis, dict) and analysis.get("revision") == commit:
            return analysis
    return None


def find_codeql_analysis(
    *, gh: str, repository: str, ref: str, commit: str
) -> dict[str, Any] | None:
    response = gh_json(
        gh,
        "--paginate",
        "--slurp",
        f"repos/{repository}/code-scanning/analyses?ref={urllib.parse.quote(ref, safe='')}&tool_name=CodeQL&per_page=100",
    )
    if not isinstance(response, list):
        raise ValueError("GitHub did not return CodeQL analysis pages")
    for page in response:
        if not isinstance(page, list):
            raise ValueError("GitHub returned an invalid CodeQL analysis page")
        for analysis in page:
            if isinstance(analysis, dict) and analysis.get("commit_sha") == commit:
                return analysis
    return None


def wait_for_analyses(
    *,
    host: str,
    project: str,
    branch: str,
    gh: str,
    repository: str,
    codeql_ref: str,
    commit: str,
    poll_interval: int,
    poll_timeout: int,
    require_sonarqube: bool = True,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    if poll_interval <= 0 or poll_timeout <= 0:
        raise ValueError("poll interval and timeout must be positive")

    deadline = time.monotonic() + poll_timeout
    while True:
        sonar_analysis = None
        if require_sonarqube:
            sonar_analysis = find_sonarqube_analysis(
                host=host, project=project, branch=branch, commit=commit
            )
        codeql_analysis = find_codeql_analysis(
            gh=gh,
            repository=repository,
            ref=codeql_ref,
            commit=commit,
        )
        if codeql_analysis is not None and (
            not require_sonarqube or sonar_analysis is not None
        ):
            return sonar_analysis, codeql_analysis
        if time.monotonic() >= deadline:
            waiting_for = []
            if require_sonarqube and sonar_analysis is None:
                waiting_for.append("SonarQube")
            if codeql_analysis is None:
                waiting_for.append("CodeQL")
            raise ValueError(
                f"timed out waiting for {' and '.join(waiting_for)} analysis of {commit}"
            )
        time.sleep(poll_interval)


def sonar_measures_for_analysis(
    *, host: str, project: str, branch: str, analysis: dict[str, Any]
) -> dict[str, str]:
    analysis_date = analysis.get("date")
    if not isinstance(analysis_date, str) or not analysis_date:
        raise ValueError("SonarQube analysis did not include a timestamp")
    response = request_json(
        sonar_url(
            host,
            "/api/measures/search_history",
            {
                "component": project,
                "branch": branch,
                "metrics": ",".join(SONARQUBE_METRICS),
                "from": analysis_date,
                "to": analysis_date,
            },
        )
    )
    measure_history = response.get("measures")
    if not isinstance(measure_history, list):
        raise ValueError("SonarQube did not return measure history")

    result: dict[str, str] = {}
    for measure in measure_history:
        if not isinstance(measure, dict):
            continue
        metric = measure.get("metric")
        history = measure.get("history")
        if not isinstance(metric, str) or not isinstance(history, list):
            continue
        for entry in history:
            if not isinstance(entry, dict) or entry.get("date") != analysis_date:
                continue
            value = entry.get("value")
            if isinstance(value, str):
                result[metric] = value

    missing = [metric for metric in SONARQUBE_METRICS if metric not in result]
    if missing:
        raise ValueError(
            "SonarQube analysis is missing required metrics: " + ", ".join(missing)
        )
    return result


def rating(value: str) -> str:
    try:
        numeric = int(float(value))
    except ValueError as error:
        raise ValueError(f"invalid SonarQube rating: {value}") from error
    letters = {1: "A", 2: "B", 3: "C", 4: "D", 5: "E"}
    if numeric not in letters:
        raise ValueError(f"unsupported SonarQube rating: {value}")
    return letters[numeric]


def minutes(value: str) -> str:
    try:
        total = int(float(value))
    except ValueError as error:
        raise ValueError(f"invalid SonarQube technical-debt value: {value}") from error
    hours, remainder = divmod(total, 60)
    if hours:
        return f"{hours}h {remainder}m"
    return f"{remainder}m"


def snapshot_badge(label: str, message: str, color: str) -> SnapshotBadge:
    if color not in BADGE_COLORS:
        raise ValueError(f"unsupported quality badge color: {color}")
    return SnapshotBadge(label=label, message=message, color=color)


def zero_color(value: int) -> str:
    return "brightgreen" if value == 0 else "red"


def metric_color(*, good_when: bool) -> str:
    return "brightgreen" if good_when else "orange"


def codeql_badges(*, analysis: dict[str, Any]) -> Iterable[SnapshotBadge]:
    codeql_results = analysis.get("results_count")
    codeql_rules = analysis.get("rules_count")
    codeql_error = analysis.get("error")
    codeql_warning = analysis.get("warning")
    if not isinstance(codeql_results, int) or not isinstance(codeql_rules, int):
        raise ValueError("CodeQL analysis did not include result and rule counts")
    if codeql_error or codeql_warning:
        raise ValueError("CodeQL analysis completed with an error or warning")

    yield snapshot_badge("CodeQL Analysis", "Completed", "brightgreen")
    yield snapshot_badge("CodeQL Results", str(codeql_results), zero_color(codeql_results))
    yield snapshot_badge("CodeQL Rules", str(codeql_rules), "blue")


def snapshot_badges(
    *, sonar_measures: dict[str, str], codeql_analysis: dict[str, Any]
) -> Iterable[SnapshotBadge]:
    quality_gate = sonar_measures["alert_status"]
    bugs = int(float(sonar_measures["bugs"]))
    vulnerabilities = int(float(sonar_measures["vulnerabilities"]))
    coverage = float(sonar_measures["coverage"])
    duplication = float(sonar_measures["duplicated_lines_density"])
    ncloc = int(float(sonar_measures["ncloc"]))
    yield snapshot_badge(
        "Quality Gate Status",
        "Passed" if quality_gate == "OK" else quality_gate,
        "brightgreen" if quality_gate == "OK" else "red",
    )
    yield snapshot_badge("Bugs", str(bugs), zero_color(bugs))
    yield snapshot_badge("Code Smells", sonar_measures["code_smells"], "blue")
    yield snapshot_badge(
        "Coverage",
        f"{sonar_measures['coverage']}%",
        metric_color(good_when=coverage >= 90),
    )
    yield snapshot_badge(
        "Duplicated Lines (%)",
        f"{sonar_measures['duplicated_lines_density']}%",
        metric_color(good_when=duplication <= 3),
    )
    yield snapshot_badge("Lines of Code", f"{ncloc:,}", "blue")
    yield snapshot_badge(
        "Reliability Rating", rating(sonar_measures["reliability_rating"]), "brightgreen"
    )
    yield snapshot_badge(
        "Security Rating", rating(sonar_measures["security_rating"]), "brightgreen"
    )
    yield snapshot_badge("Technical Debt", minutes(sonar_measures["sqale_index"]), "blue")
    yield snapshot_badge(
        "Maintainability Rating", rating(sonar_measures["sqale_rating"]), "brightgreen"
    )
    yield snapshot_badge("Vulnerabilities", str(vulnerabilities), zero_color(vulnerabilities))
    yield from codeql_badges(analysis=codeql_analysis)


def badge_text_width(value: str) -> int:
    """Estimate Verdana's compact 11px metric width without a browser dependency."""

    return 10 + sum(4 if character == " " else 7 for character in value)


def badge_width(badge: SnapshotBadge) -> int:
    return badge_text_width(badge.label) + badge_text_width(badge.message)


def render_badges_svg(badges: Iterable[SnapshotBadge]) -> str:
    """Render one deterministic, self-contained SVG for the quality evidence."""

    positions: list[tuple[SnapshotBadge, int, int, int]] = []
    x = BADGE_MARGIN
    y = BADGE_MARGIN
    widest = 0
    for badge in badges:
        width = badge_width(badge)
        if x > BADGE_MARGIN and x + width > BADGE_MAX_ROW_WIDTH:
            widest = max(widest, x - BADGE_GAP + BADGE_MARGIN)
            x = BADGE_MARGIN
            y += BADGE_HEIGHT + BADGE_GAP
        positions.append((badge, x, y, width))
        x += width + BADGE_GAP
    widest = max(widest, x - BADGE_GAP + BADGE_MARGIN)
    height = y + BADGE_HEIGHT + BADGE_MARGIN
    description = "; ".join(f"{badge.label}: {badge.message}" for badge, *_ in positions)

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{widest}" height="{height}" viewBox="0 0 {widest} {height}" role="img" aria-labelledby="title description">',
        "  <title id=\"title\">Quality snapshot</title>",
        f"  <desc id=\"description\">{html.escape(description)}</desc>",
    ]
    for badge, x, y, width in positions:
        label_width = badge_text_width(badge.label)
        label = html.escape(badge.label)
        message = html.escape(badge.message)
        color = BADGE_COLORS[badge.color]
        lines.extend(
            [
                f'  <g transform="translate({x} {y})">',
                f'    <rect width="{width}" height="{BADGE_HEIGHT}" rx="3" fill="#555"/>',
                f'    <rect x="{label_width}" width="{width - label_width}" height="{BADGE_HEIGHT}" rx="3" fill="{color}"/>',
                f'    <rect x="{label_width}" width="3" height="{BADGE_HEIGHT}" fill="{color}"/>',
                f'    <text x="5" y="14" fill="#fff" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">{label}</text>',
                f'    <text x="{label_width + 5}" y="14" fill="#fff" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">{message}</text>',
                "  </g>",
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def static_badge_url(*, badge: SnapshotBadge, snapshot_id: str) -> str:
    """Build a release-specific static Shields-compatible badge URL."""

    if not snapshot_id:
        raise ValueError("static quality badge snapshot ID must not be empty")
    parameters = urllib.parse.urlencode(
        {
            "label": badge.label,
            "message": badge.message,
            "color": badge.color,
            "style": "flat",
            "cacheSeconds": BADGE_CACHE_SECONDS,
            "snapshot": snapshot_id,
        }
    )
    return f"{SHIELDS_STATIC_BADGE_URL}?{parameters}"


def render_static_badges(
    badges: Iterable[SnapshotBadge], *, snapshot_id: str
) -> str:
    """Render individual static quality badges in the release-note body."""

    return " ".join(
        f"![{badge.label}]({static_badge_url(badge=badge, snapshot_id=snapshot_id)})"
        for badge in badges
    )


class RenderedBadgeParser(HTMLParser):
    """Collect GitHub-rendered static badge source pairs from release Markdown."""

    def __init__(self) -> None:
        super().__init__()
        self.badges: list[tuple[str, str]] = []

    def handle_starttag(
        self, tag: str, attributes: list[tuple[str, str | None]]
    ) -> None:
        if tag != "img":
            return
        values = dict(attributes)
        canonical_source = values.get("data-canonical-src")
        proxied_source = values.get("src")
        if canonical_source and canonical_source.startswith(SHIELDS_STATIC_BADGE_URL):
            if proxied_source is None:
                raise ValueError("GitHub rendered a static quality badge without a source")
            self.badges.append((canonical_source, proxied_source))


def rendered_static_badges(markdown: str) -> list[tuple[str, str]]:
    """Return the canonical and GitHub-proxied URLs emitted for static badges."""

    parser = RenderedBadgeParser()
    parser.feed(markdown)
    parser.close()
    return parser.badges


def fetch_badge_svg(url: str) -> str:
    """Fetch one GitHub-proxied badge and return its SVG payload."""

    request = urllib.request.Request(url, headers={"Accept": "image/svg+xml"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_type = response.headers.get_content_type()
            payload = response.read().decode("utf-8")
    except urllib.error.URLError as error:
        raise ValueError(f"GitHub could not deliver static quality badge {url}: {error}") from error
    if content_type != "image/svg+xml":
        raise ValueError(
            f"GitHub delivered static quality badge {url} as {content_type}, not image/svg+xml"
        )
    return payload


def validate_badge_svg(*, url: str, payload: str) -> None:
    """Require the exact image response to be a parseable SVG document."""

    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError as error:
        raise ValueError(f"GitHub delivered invalid static quality badge SVG {url}") from error
    if root.tag != "{http://www.w3.org/2000/svg}svg":
        raise ValueError(f"GitHub delivered non-SVG static quality badge payload {url}")


def validate_static_badge_delivery(
    *, gh: str, repository: str, badges: list[SnapshotBadge], snapshot_id: str
) -> None:
    """Fail publication unless GitHub can render every exact static badge image."""

    canonical_sources = [
        static_badge_url(badge=badge, snapshot_id=snapshot_id) for badge in badges
    ]
    markdown = render_static_badges(badges, snapshot_id=snapshot_id)
    rendered = gh_text(
        gh,
        "markdown",
        "--method",
        "POST",
        "-f",
        f"text={markdown}",
        "-f",
        "mode=gfm",
        "-f",
        f"context={repository}",
    )
    delivered_badges = rendered_static_badges(rendered)
    if [canonical for canonical, _ in delivered_badges] != canonical_sources:
        raise ValueError(
            "GitHub did not render every expected static quality badge through its image proxy"
        )

    for _, proxied_source in delivered_badges:
        last_error: ValueError | None = None
        for attempt in range(BADGE_DELIVERY_ATTEMPTS):
            try:
                validate_badge_svg(
                    url=proxied_source, payload=fetch_badge_svg(proxied_source)
                )
                break
            except ValueError as error:
                last_error = error
                if attempt + 1 < BADGE_DELIVERY_ATTEMPTS:
                    time.sleep(attempt + 1)
        else:
            assert last_error is not None
            raise last_error


def resolved_badges(
    *,
    sonar_measures: dict[str, str] | None,
    codeql_analysis: dict[str, Any],
) -> list[SnapshotBadge]:
    if sonar_measures is None:
        return list(codeql_badges(analysis=codeql_analysis))
    return list(snapshot_badges(sonar_measures=sonar_measures, codeql_analysis=codeql_analysis))


def render_snapshot(
    *,
    commit: str,
    sonar_analysis: dict[str, Any] | None,
    sonar_measures: dict[str, str] | None,
    codeql_analysis: dict[str, Any],
    release_kind: str = "stable",
    asset_url: str = "quality-snapshot.svg",
    badge_snapshot_id: str | None = None,
) -> str:
    if not asset_url:
        raise ValueError("quality snapshot asset URL must not be empty")
    if release_kind == "current":
        retention = "These static badges describe this mutable Current build and are replaced when `current` moves."
    else:
        retention = "These static badges are retained as historical evidence; they do not update."
    if sonar_analysis is None or sonar_measures is None:
        analysis_summary = (
            f"- CodeQL analysis covers `{commit}`. SonarQube metrics are omitted "
            "because the validated CI run did not produce a SonarQube scan."
        )
    else:
        analysis_summary = (
            f"- SonarQube `main` analysis `{sonar_analysis['date']}` and CodeQL "
            f"analysis both cover `{commit}`."
        )
    badges = resolved_badges(
        sonar_measures=sonar_measures,
        codeql_analysis=codeql_analysis,
    )
    return "\n".join(
        [
            "## Quality Snapshot",
            "",
            retention,
            analysis_summary,
            "",
            render_static_badges(
                badges,
                snapshot_id=badge_snapshot_id or commit,
            ),
            "",
            f"[Download the self-contained SVG evidence]({asset_url}).",
            "",
        ]
    )


def main() -> None:
    args = parse_args()
    try:
        if (args.svg_output is None) != (args.asset_url is None):
            raise ValueError("--svg-output and --asset-url must be supplied together")
        if args.allow_missing_sonarqube and args.release_kind != "current":
            raise ValueError("only current snapshots may omit SonarQube metrics")
        sonar_analysis, codeql_analysis = wait_for_analyses(
            host=args.sonarqube_url,
            project=args.sonarqube_project,
            branch=args.sonarqube_branch,
            gh=args.gh,
            repository=args.repo,
            codeql_ref=args.codeql_ref,
            commit=args.commit,
            poll_interval=args.poll_interval,
            poll_timeout=args.poll_timeout,
            require_sonarqube=not args.allow_missing_sonarqube,
        )
        sonar_measures = None
        if sonar_analysis is not None:
            sonar_measures = sonar_measures_for_analysis(
                host=args.sonarqube_url,
                project=args.sonarqube_project,
                branch=args.sonarqube_branch,
                analysis=sonar_analysis,
            )
        badges = resolved_badges(
            sonar_measures=sonar_measures,
            codeql_analysis=codeql_analysis,
        )
        badge_snapshot_id = args.badge_snapshot_id or args.commit
        if args.verify_static_badges:
            validate_static_badge_delivery(
                gh=args.gh,
                repository=args.repo,
                badges=badges,
                snapshot_id=badge_snapshot_id,
            )
        if args.svg_output is not None:
            args.svg_output.parent.mkdir(parents=True, exist_ok=True)
            args.svg_output.write_text(render_badges_svg(badges), encoding="utf-8")
        print(
            render_snapshot(
                commit=args.commit,
                sonar_analysis=sonar_analysis,
                sonar_measures=sonar_measures,
                codeql_analysis=codeql_analysis,
                release_kind=args.release_kind,
                asset_url=args.asset_url or "quality-snapshot.svg",
                badge_snapshot_id=badge_snapshot_id,
            ),
            end="",
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
