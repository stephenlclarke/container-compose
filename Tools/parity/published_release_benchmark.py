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

"""Resolve, verify, and report published release benchmark inputs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import inspect
import json
import math
import os
import posixpath
import re
import statistics
import subprocess
import tarfile
from collections import defaultdict
from pathlib import Path
from typing import Iterable


SEMANTIC_VERSION = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+$")
REPOSITORY = "stephenlclarke/container-compose"
ASSETS = {
    "compose": (
        "container-compose-plugin-release-arm64.tar.gz",
        "Formula/container-compose.rb",
    ),
    "runtime": (
        "container-release-arm64.tar.gz",
        "Formula/container.rb",
    ),
}


class BenchmarkInputError(ValueError):
    """Raised when published benchmark input cannot be trusted."""


def version_tuple(version: str) -> tuple[int, int, int]:
    if SEMANTIC_VERSION.fullmatch(version) is None:
        raise BenchmarkInputError(
            f"version must be a bare semantic version: {version}"
        )
    return tuple(int(component) for component in version.split("."))  # type: ignore[return-value]


def stable_versions(releases: Iterable[dict[str, object]]) -> set[str]:
    versions: set[str] = set()
    for release in releases:
        tag = release.get("tagName")
        if not isinstance(tag, str) or SEMANTIC_VERSION.fullmatch(tag) is None:
            continue
        if release.get("isDraft") is True or release.get("isPrerelease") is True:
            continue
        versions.add(tag)
    return versions


def resolve_versions(
    releases: Iterable[dict[str, object]],
    target: str,
    baseline: str | None,
) -> dict[str, str]:
    target_key = version_tuple(target)
    available = stable_versions(releases)
    if target not in available:
        raise BenchmarkInputError(
            f"target is not a published stable release: {target}"
        )
    if baseline:
        version_tuple(baseline)
        if baseline not in available:
            raise BenchmarkInputError(
                f"comparison version is not a published stable release: {baseline}"
            )
    else:
        earlier = [version for version in available if version_tuple(version) < target_key]
        if not earlier:
            raise BenchmarkInputError(
                f"no published stable release precedes {target}"
            )
        baseline = max(earlier, key=version_tuple)
    if baseline == target:
        raise BenchmarkInputError("target and comparison versions must differ")
    return {"target": target, "baseline": baseline}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sidecar_digest(path: Path, asset_name: str) -> str:
    fields = path.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2 or fields[1].removeprefix("*") != asset_name:
        raise BenchmarkInputError(
            f"checksum sidecar does not name {asset_name}: {path}"
        )
    digest = fields[0]
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise BenchmarkInputError(f"invalid SHA-256 in {path}")
    return digest


def git_output(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def formula_authority(
    tap_repository: Path,
    formula_path: str,
    version: str,
    asset_name: str,
    digest: str,
) -> str:
    expected_url = (
        f"https://github.com/{REPOSITORY}/releases/download/"
        f"{version}/{asset_name}"
    )
    authority_ref = ""
    for candidate in ("refs/remotes/origin/main", "refs/heads/main"):
        result = subprocess.run(
            [
                "git",
                "-C",
                str(tap_repository),
                "rev-parse",
                "--verify",
                f"{candidate}^{{commit}}",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            authority_ref = candidate
            break
    if not authority_ref:
        raise BenchmarkInputError("Homebrew tap has no verifiable main history")
    commits = git_output(
        tap_repository,
        "log",
        "--format=%H",
        authority_ref,
        "--",
        formula_path,
    ).splitlines()
    for commit in commits:
        show = subprocess.run(
            ["git", "-C", str(tap_repository), "show", f"{commit}:{formula_path}"],
            check=False,
            capture_output=True,
            text=True,
        )
        if show.returncode != 0:
            continue
        if f'url "{expected_url}"' in show.stdout and f'sha256 "{digest}"' in show.stdout:
            return commit
    raise BenchmarkInputError(
        f"Homebrew main history never distributed {asset_name} for {version} at {digest}"
    )


def validate_archive_members(archive: tarfile.TarFile) -> None:
    for member in archive.getmembers():
        normalized = posixpath.normpath(member.name)
        if member.name.startswith("/") or normalized == ".." or normalized.startswith("../"):
            raise BenchmarkInputError(f"unsafe archive path: {member.name}")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise BenchmarkInputError(f"unsupported archive entry: {member.name}")
        if member.issym() or member.islnk():
            base = posixpath.dirname(normalized) if member.issym() else ""
            link = posixpath.normpath(posixpath.join(base, member.linkname))
            if member.linkname.startswith("/") or link == ".." or link.startswith("../"):
                raise BenchmarkInputError(
                    f"unsafe archive link: {member.name} -> {member.linkname}"
                )


def prepare_distribution(
    version: str,
    distribution: Path,
    tap_repository: Path,
    output: Path,
) -> dict[str, object]:
    version_tuple(version)
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    asset_manifest: dict[str, object] = {}
    for component, (asset_name, formula_path) in ASSETS.items():
        asset = distribution / asset_name
        sidecar = distribution / f"{asset_name}.sha256"
        if not asset.is_file() or not sidecar.is_file():
            raise BenchmarkInputError(
                f"published release {version} is missing {asset_name} or its checksum"
            )
        expected_digest = sidecar_digest(sidecar, asset_name)
        actual_digest = sha256(asset)
        if actual_digest != expected_digest:
            raise BenchmarkInputError(
                f"published release checksum mismatch for {asset_name}"
            )
        tap_commit = formula_authority(
            tap_repository,
            formula_path,
            version,
            asset_name,
            actual_digest,
        )
        component_output = output / component
        component_output.mkdir(mode=0o700)
        with tarfile.open(asset, "r:gz") as archive:
            validate_archive_members(archive)
            extraction_options: dict[str, str] = {}
            if "filter" in inspect.signature(archive.extractall).parameters:
                extraction_options["filter"] = "fully_trusted"
            archive.extractall(component_output, **extraction_options)
        asset_manifest[component] = {
            "asset": asset_name,
            "sha256": actual_digest,
            "homebrewFormula": formula_path,
            "homebrewCommit": tap_commit,
        }
    manifest: dict[str, object] = {
        "version": version,
        "release": f"https://github.com/{REPOSITORY}/releases/tag/{version}",
        "assets": asset_manifest,
    }
    (output / "published-distribution.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def nearest_rank_p95(values: list[float]) -> float:
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def load_samples(evidence: Path) -> dict[str, dict[str, list[float]]]:
    path = evidence / "timings.tsv"
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        raise BenchmarkInputError(f"benchmark has no samples: {path}")
    grouped: dict[str, dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in rows:
        if row.get("outcome") != "success" or row.get("direction") != "lower-is-better":
            raise BenchmarkInputError(
                f"benchmark contains an unsuccessful or unsupported sample: {path}"
            )
        lane = row.get("lane")
        fixture = row.get("fixture")
        if lane not in {"docker", "container-compose"} or not fixture:
            raise BenchmarkInputError(f"benchmark contains an invalid lane: {path}")
        grouped[fixture][lane].append(float(row["duration_seconds"]))
    result = {fixture: dict(lanes) for fixture, lanes in grouped.items()}
    for fixture, lanes in result.items():
        if set(lanes) != {"docker", "container-compose"}:
            raise BenchmarkInputError(f"benchmark fixture has incomplete lanes: {fixture}")
        if len(lanes["docker"]) != len(lanes["container-compose"]):
            raise BenchmarkInputError(f"benchmark fixture has unbalanced lanes: {fixture}")
    return result


def percentage(ratio: float) -> str:
    return f"{(ratio - 1) * 100:+.1f}%"


def render_report(
    target_evidence: Path,
    baseline_evidence: Path,
    target_distribution: Path,
    baseline_distribution: Path,
    output: Path,
    workflow_url: str,
) -> None:
    target_manifest = json.loads(target_distribution.read_text(encoding="utf-8"))
    baseline_manifest = json.loads(baseline_distribution.read_text(encoding="utf-8"))
    target_version = target_manifest["version"]
    baseline_version = baseline_manifest["version"]
    target_samples = load_samples(target_evidence)
    baseline_samples = load_samples(baseline_evidence)
    if set(target_samples) != set(baseline_samples):
        raise BenchmarkInputError("target and comparison fixture inventories differ")

    target_fingerprints = json.loads(
        (target_evidence / "fingerprints.json").read_text(encoding="utf-8")
    )
    baseline_fingerprints = json.loads(
        (baseline_evidence / "fingerprints.json").read_text(encoding="utf-8")
    )
    for key in ("host", "docker"):
        if target_fingerprints[key] != baseline_fingerprints[key]:
            raise BenchmarkInputError(
                f"target and comparison {key} fingerprints differ"
            )

    target_conditions = target_fingerprints["conditions"]
    baseline_conditions = baseline_fingerprints["conditions"]
    if target_conditions != baseline_conditions:
        raise BenchmarkInputError("target and comparison benchmark conditions differ")
    repetitions = int(target_conditions["repetitions"])
    for label, samples_by_fixture in (
        ("target", target_samples),
        ("comparison", baseline_samples),
    ):
        for fixture, lanes in samples_by_fixture.items():
            for lane, samples in lanes.items():
                if len(samples) != repetitions:
                    raise BenchmarkInputError(
                        f"{label} fixture {fixture} lane {lane} has "
                        f"{len(samples)} samples; expected {repetitions}"
                    )

    noise = float(target_conditions["comparableNoisePercent"])
    lower = 1 - noise / 100
    upper = 1 + noise / 100
    rows: list[tuple[object, ...]] = []
    median_ratios: list[float] = []
    p95_ratios: list[float] = []
    improved = unchanged = regressed = 0
    for fixture in sorted(target_samples):
        target = target_samples[fixture]
        baseline = baseline_samples[fixture]
        target_median = statistics.median(target["container-compose"])
        baseline_median = statistics.median(baseline["container-compose"])
        target_p95 = nearest_rank_p95(target["container-compose"])
        baseline_p95 = nearest_rank_p95(baseline["container-compose"])
        target_docker_median = statistics.median(target["docker"])
        baseline_docker_median = statistics.median(baseline["docker"])
        median_ratio = target_median / baseline_median
        p95_ratio = target_p95 / baseline_p95
        normalized_ratio = (
            target_median / target_docker_median
        ) / (baseline_median / baseline_docker_median)
        median_ratios.append(median_ratio)
        p95_ratios.append(p95_ratio)
        if median_ratio < lower:
            verdict = "Improved"
            improved += 1
        elif median_ratio > upper:
            verdict = "Regressed"
            regressed += 1
        else:
            verdict = "Within noise"
            unchanged += 1
        rows.append(
            (
                fixture,
                baseline_median,
                target_median,
                median_ratio,
                baseline_p95,
                target_p95,
                p95_ratio,
                normalized_ratio,
                verdict,
            )
        )

    geometric_median = math.exp(sum(math.log(value) for value in median_ratios) / len(median_ratios))
    geometric_p95 = math.exp(sum(math.log(value) for value in p95_ratios) / len(p95_ratios))
    host = target_fingerprints["host"]
    docker = target_fingerprints["docker"]
    lines = [
        f"# Published release benchmark: {target_version} versus {baseline_version}",
        "",
        "This report compares immutable, Developer ID-signed release archives. No source product was built by the benchmark workflow. Both releases ran on the same host against the same Docker installation; Docker-normalized change is included to expose host drift.",
        "",
        "## Result",
        "",
        f"Across {len(rows)} fixed-work fixtures, the geometric-mean median changed {percentage(geometric_median)} and the geometric-mean P95 changed {percentage(geometric_p95)}. With a ±{noise:g}% noise band, {improved} fixtures improved, {unchanged} stayed within noise, and {regressed} regressed.",
        "",
        "Lower durations and negative changes are better.",
        "",
        "## Published inputs",
        "",
    ]
    for label, manifest in (("Target", target_manifest), ("Comparison", baseline_manifest)):
        lines.extend(
            [
                f"### {label} {manifest['version']}",
                "",
                f"Release: [{manifest['release']}]({manifest['release']})",
                "",
            ]
        )
        for component in ("runtime", "compose"):
            asset = manifest["assets"][component]
            lines.append(
                f"- `{asset['asset']}`: SHA-256 `{asset['sha256']}`; Homebrew formula history `{asset['homebrewCommit']}`."
            )
        lines.append("")
    lines.extend(
        [
            "## Host and method",
            "",
            f"- Host: `{host['hardwareModel']}`, `{host['architecture']}`, {host['hardwareMemoryBytes']} bytes memory, macOS `{host['macOSVersion']}`.",
            f"- Docker Compose: `{docker['composeVersion']}`.",
            f"- Repetitions: {repetitions} per lane, counterbalanced Docker-first/candidate-first order.",
            f"- Cross-VM remote-sink logging lanes: {'included' if target_conditions.get('remoteLogging') else 'excluded to keep the unattended run free of macOS Local Network approval'}.",
            f"- Workflow evidence: [{workflow_url}]({workflow_url}).",
            "- Raw TSV, JUnit, timing matrices, distribution manifests, and exact fingerprints are retained as the workflow artifact.",
            "",
            "## Fixture evidence",
            "",
            "| Fixture | Comparison median (s) | Target median (s) | Median change | Comparison P95 (s) | Target P95 (s) | P95 change | Docker-normalized median change | Verdict |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    for row in rows:
        fixture, baseline_median, target_median, median_ratio, baseline_p95, target_p95, p95_ratio, normalized_ratio, verdict = row
        lines.append(
            f"| {fixture} | {baseline_median:.3f} | {target_median:.3f} | {percentage(median_ratio)} | {baseline_p95:.3f} | {target_p95:.3f} | {percentage(p95_ratio)} | {percentage(normalized_ratio)} | {verdict} |"
        )
    lines.extend(
        [
            "",
            "## Interpretation boundary",
            "",
            "The report supports claims only for the listed warm-image lifecycle and logging fixtures. It does not replace functional, Docker parity, security, quality, packaging, or release gates, and it is not authority for workloads absent from the matrix.",
            "",
        ]
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--releases", type=Path, required=True)
    resolve.add_argument("--target", required=True)
    resolve.add_argument("--baseline")

    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--distribution", type=Path, required=True)
    prepare.add_argument("--tap-repository", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)

    render = subparsers.add_parser("render")
    render.add_argument("--target-evidence", type=Path, required=True)
    render.add_argument("--baseline-evidence", type=Path, required=True)
    render.add_argument("--target-distribution", type=Path, required=True)
    render.add_argument("--baseline-distribution", type=Path, required=True)
    render.add_argument("--output", type=Path, required=True)
    render.add_argument("--workflow-url", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "resolve":
            releases = load_json(arguments.releases)
            if not isinstance(releases, list):
                raise BenchmarkInputError("release metadata must be a JSON array")
            result = resolve_versions(releases, arguments.target, arguments.baseline)
            print(json.dumps(result, sort_keys=True))
        elif arguments.command == "prepare":
            result = prepare_distribution(
                arguments.version,
                arguments.distribution,
                arguments.tap_repository,
                arguments.output,
            )
            print(json.dumps(result, sort_keys=True))
        else:
            render_report(
                arguments.target_evidence,
                arguments.baseline_evidence,
                arguments.target_distribution,
                arguments.baseline_distribution,
                arguments.output,
                arguments.workflow_url,
            )
    except BenchmarkInputError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
