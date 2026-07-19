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
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
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


def static_badge(label: str, message: str, color: str) -> str:
    query = urllib.parse.urlencode(
        {"label": label, "message": message, "color": color, "style": "flat"}
    )
    return f"![{label}](https://img.shields.io/static/v1?{query})"


def zero_color(value: int) -> str:
    return "brightgreen" if value == 0 else "red"


def metric_color(*, good_when: bool) -> str:
    return "brightgreen" if good_when else "orange"


def codeql_badges(*, analysis: dict[str, Any]) -> Iterable[str]:
    codeql_results = analysis.get("results_count")
    codeql_rules = analysis.get("rules_count")
    codeql_error = analysis.get("error")
    codeql_warning = analysis.get("warning")
    if not isinstance(codeql_results, int) or not isinstance(codeql_rules, int):
        raise ValueError("CodeQL analysis did not include result and rule counts")
    if codeql_error or codeql_warning:
        raise ValueError("CodeQL analysis completed with an error or warning")

    yield static_badge("CodeQL Analysis", "Completed", "brightgreen")
    yield static_badge("CodeQL Results", str(codeql_results), zero_color(codeql_results))
    yield static_badge("CodeQL Rules", str(codeql_rules), "blue")


def snapshot_badges(
    *, sonar_measures: dict[str, str], codeql_analysis: dict[str, Any]
) -> Iterable[str]:
    quality_gate = sonar_measures["alert_status"]
    bugs = int(float(sonar_measures["bugs"]))
    vulnerabilities = int(float(sonar_measures["vulnerabilities"]))
    coverage = float(sonar_measures["coverage"])
    duplication = float(sonar_measures["duplicated_lines_density"])
    ncloc = int(float(sonar_measures["ncloc"]))
    yield static_badge(
        "Quality Gate Status",
        "Passed" if quality_gate == "OK" else quality_gate,
        "brightgreen" if quality_gate == "OK" else "red",
    )
    yield static_badge("Bugs", str(bugs), zero_color(bugs))
    yield static_badge("Code Smells", sonar_measures["code_smells"], "blue")
    yield static_badge(
        "Coverage",
        f"{sonar_measures['coverage']}%",
        metric_color(good_when=coverage >= 90),
    )
    yield static_badge(
        "Duplicated Lines (%)",
        f"{sonar_measures['duplicated_lines_density']}%",
        metric_color(good_when=duplication <= 3),
    )
    yield static_badge("Lines of Code", f"{ncloc:,}", "blue")
    yield static_badge("Reliability Rating", rating(sonar_measures["reliability_rating"]), "brightgreen")
    yield static_badge("Security Rating", rating(sonar_measures["security_rating"]), "brightgreen")
    yield static_badge("Technical Debt", minutes(sonar_measures["sqale_index"]), "blue")
    yield static_badge("Maintainability Rating", rating(sonar_measures["sqale_rating"]), "brightgreen")
    yield static_badge("Vulnerabilities", str(vulnerabilities), zero_color(vulnerabilities))
    yield from codeql_badges(analysis=codeql_analysis)


def render_snapshot(
    *,
    commit: str,
    sonar_analysis: dict[str, Any] | None,
    sonar_measures: dict[str, str] | None,
    codeql_analysis: dict[str, Any],
    release_kind: str = "stable",
) -> str:
    if release_kind == "current":
        retention = "These static, non-clickable badges describe this mutable Current build and are replaced when `current` moves."
    else:
        retention = "These static, non-clickable badges are retained as historical evidence; they do not update."
    if sonar_analysis is None or sonar_measures is None:
        badges = " ".join(codeql_badges(analysis=codeql_analysis))
        analysis_summary = (
            f"- CodeQL analysis covers `{commit}`. SonarQube metrics are omitted "
            "because the validated CI run did not produce a SonarQube scan."
        )
    else:
        badges = " ".join(
            snapshot_badges(sonar_measures=sonar_measures, codeql_analysis=codeql_analysis)
        )
        analysis_summary = (
            f"- SonarQube `main` analysis `{sonar_analysis['date']}` and CodeQL "
            f"analysis both cover `{commit}`."
        )
    return "\n".join(
        [
            "## Quality Snapshot",
            "",
            retention,
            analysis_summary,
            "",
            badges,
            "",
        ]
    )


def main() -> None:
    args = parse_args()
    try:
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
        print(
            render_snapshot(
                commit=args.commit,
                sonar_analysis=sonar_analysis,
                sonar_measures=sonar_measures,
                codeql_analysis=codeql_analysis,
                release_kind=args.release_kind,
            ),
            end="",
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
