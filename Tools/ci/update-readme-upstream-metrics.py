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

"""Update README fork-divergence metrics from local stack repositories."""

from __future__ import annotations

import argparse
import importlib.util
import subprocess
import sys
import textwrap
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_README = ROOT / "README.md"
BEGIN_MARKER = "<!-- upstream-metrics:start -->"
END_MARKER = "<!-- upstream-metrics:end -->"
DISPLAY_ORDER = ("containerization", "container", "container-builder-shim")
REPOSITORY_URLS = {
    "containerization": "https://github.com/stephenlclarke/containerization",
    "container": "https://github.com/stephenlclarke/container",
    "container-builder-shim": "https://github.com/stephenlclarke/container-builder-shim",
}


def repo_root_from_git_common_dir(root: Path, common_dir_text: str) -> Path:
    common_dir = Path(common_dir_text.strip())
    if not common_dir.is_absolute():
        common_dir = root / common_dir
    common_dir = common_dir.resolve()
    if common_dir.name == ".git":
        return common_dir.parent.parent
    return root.parent


def default_repo_root(root: Path = ROOT) -> Path:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--git-common-dir",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return root.parent
    return repo_root_from_git_common_dir(root, result.stdout)


DEFAULT_REPO_ROOT = default_repo_root()


@dataclass(frozen=True)
class ReadmeMetric:
    name: str
    behind: int
    ahead: int
    commit_hash: str
    short: str


def load_divergence_reporter() -> Any:
    module_path = Path(__file__).with_name("upstream-divergence-report.py")
    spec = importlib.util.spec_from_file_location("upstream_divergence_report", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    reporter = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = reporter
    spec.loader.exec_module(reporter)
    return reporter


def snapshot_date(now: datetime | None = None) -> str:
    current = now or datetime.now()
    return f"{current.day} {current.strftime('%B')} {current.year}"


def collect_metrics(repo_root: Path, fetch: bool) -> list[ReadmeMetric]:
    reporter = load_divergence_reporter()
    report = reporter.build_report(repo_root, fetch, 0, reporter.DEFAULT_REPOS)
    by_name = {repo.name: repo for repo in report.repositories}
    metrics: list[ReadmeMetric] = []
    for name in DISPLAY_ORDER:
        repo = by_name[name]
        if repo.errors:
            raise RuntimeError(f"{name}: {'; '.join(repo.errors)}")
        if repo.fork is None:
            raise RuntimeError(f"{name}: missing fork head")
        metrics.append(
            ReadmeMetric(
                name=name,
                behind=repo.fork_to_upstream.behind,
                ahead=repo.fork_to_upstream.ahead,
                commit_hash=repo.fork.hash,
                short=repo.fork.hash[:12],
            )
        )
    return metrics


def render_metrics_section(metrics: Sequence[ReadmeMetric], date_text: str) -> str:
    total_ahead = sum(metric.ahead for metric in metrics)
    lines = [
        f"> {BEGIN_MARKER}",
        "> What started as a 'fun' implementation due to a real need for Compose functionality on `apple/container` has turned into a beast. `container-compose` cannot be maintained in isolation: it depends on runtime and build capabilities not yet available in Apple releases, plus local fixes for upstream defects. Keeping it working means carrying and continuously refreshing a matched four-repository stack. "
        f"At the {date_text} snapshot, the three support forks are **{total_ahead} commits ahead of Apple upstream**:",
        ">",
    ]
    for metric in metrics:
        repo_url = REPOSITORY_URLS[metric.name]
        lines.append(
            f"> - [`{metric.name}`]({repo_url}): **{metric.behind} behind, {metric.ahead} ahead** "
            f"at [`{metric.short}`]({repo_url}/commit/{metric.commit_hash})."
        )
    lines.extend(
        [
            "> - [`container-compose`](https://github.com/stephenlclarke/container-compose): the integration repository's current `main` branch, with no Apple repository to compare against.",
            ">",
            "> What looks like a local Compose change can therefore require coordinated conflict resolution, pin updates, builds, tests, packaging, and release validation across the entire stack. The pinned revisions must move together.",
            f"> {END_MARKER}",
            ">",
        ]
    )
    return "\n".join(lines) + "\n"


def replace_metrics_section(readme: str, replacement: str) -> str:
    start = readme.find(f"> {BEGIN_MARKER}")
    end = readme.find(f"> {END_MARKER}")
    if start != -1 and end != -1 and end > start:
        end_line = readme.find("\n", end)
        if end_line == -1:
            end_line = len(readme)
        else:
            end_line += 1
        if readme.startswith(">\n", end_line):
            end_line += 2
        return readme[:start] + replacement + readme[end_line:]

    legacy_start = readme.find("> What started as a 'fun' implementation")
    legacy_end = readme.find("> Apple's [#1769 proposal]", legacy_start)
    if legacy_start == -1 or legacy_end == -1:
        raise ValueError("could not find README upstream metrics section")
    return readme[:legacy_start] + replacement + readme[legacy_end:]


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--readme", type=Path, default=DEFAULT_README)
    parser.add_argument("--date", default=snapshot_date())
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    metrics = collect_metrics(args.repo_root.expanduser(), args.fetch)
    replacement = render_metrics_section(metrics, args.date)
    readme_path = args.readme.expanduser()
    current = readme_path.read_text(encoding="utf-8")
    updated = replace_metrics_section(current, replacement)
    if args.check:
        if updated != current:
            print(
                textwrap.dedent(
                    f"""\
                    {readme_path} upstream metrics are stale.
                    Run: python3 Tools/ci/update-readme-upstream-metrics.py --fetch
                    """
                ).strip(),
                file=sys.stderr,
            )
            return 1
        return 0
    readme_path.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
