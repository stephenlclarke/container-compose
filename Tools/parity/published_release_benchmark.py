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
import shutil
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
INIT_ASSET = "container-vminit-arm64.oci.tar"


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
    latest = max(available, key=version_tuple)
    return {"target": target, "baseline": baseline, "latest": latest}


def canonical_artifact_source(version: str, source: str) -> str:
    version_tuple(version)
    release = f"https://github.com/{REPOSITORY}/releases/tag/{version}"
    run_pattern = re.compile(
        rf"https://github[.]com/{re.escape(REPOSITORY)}/actions/runs/[1-9][0-9]*"
    )
    if source != release and run_pattern.fullmatch(source) is None:
        raise BenchmarkInputError(
            f"artifact source is not a canonical release or package run: {source}"
        )
    return source


def packaging_run_candidates(
    runs: Iterable[dict[str, object]], version: str
) -> list[dict[str, object]]:
    version_tuple(version)
    title = f"Prebuilt Binaries · {version}"
    candidates: list[tuple[str, int, str, str]] = []
    for run in runs:
        if (
            run.get("displayTitle") != title
            or run.get("event") != "workflow_dispatch"
            or run.get("status") != "completed"
            or run.get("conclusion") != "success"
        ):
            continue
        run_id = run.get("databaseId")
        created_at = run.get("createdAt")
        url = run.get("url")
        head_branch = run.get("headBranch")
        head_sha = run.get("headSha")
        if (
            not isinstance(run_id, int)
            or run_id <= 0
            or not isinstance(created_at, str)
            or not created_at
            or not isinstance(url, str)
            or url
            != f"https://github.com/{REPOSITORY}/actions/runs/{run_id}"
            or head_branch != "main"
            or not isinstance(head_sha, str)
            or re.fullmatch(r"[0-9a-f]{40}", head_sha) is None
        ):
            continue
        candidates.append((created_at, run_id, url, head_sha))
    if not candidates:
        raise BenchmarkInputError(
            f"no successful immutable package run retained for {version}"
        )
    return [
        {
            "runId": run_id,
            "url": url,
            "createdAt": created_at,
            "headSha": head_sha,
        }
        for created_at, run_id, url, head_sha in sorted(candidates, reverse=True)
    ]


def resolve_packaging_run(
    runs: Iterable[dict[str, object]], version: str
) -> dict[str, object]:
    return packaging_run_candidates(runs, version)[0]


def validate_packaging_artifacts(payload: dict[str, object]) -> dict[str, int]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise BenchmarkInputError("package run artifact metadata is not an array")
    required = {asset_name for asset_name, _ in ASSETS.values()}
    matches: dict[str, list[dict[str, object]]] = {
        name: [] for name in required
    }
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        name = artifact.get("name")
        if isinstance(name, str) and name in matches:
            matches[name].append(artifact)
    validated: dict[str, int] = {}
    for name in sorted(required):
        candidates = matches[name]
        if len(candidates) != 1:
            raise BenchmarkInputError(
                f"package run must retain exactly one {name} artifact"
            )
        artifact = candidates[0]
        artifact_id = artifact.get("id")
        if not isinstance(artifact_id, int) or artifact_id <= 0:
            raise BenchmarkInputError(f"package run artifact has no valid id: {name}")
        if artifact.get("expired") is not False:
            raise BenchmarkInputError(f"package run artifact has expired: {name}")
        validated[name] = artifact_id
    return validated


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
    allow_package_run_backfill: bool = False,
) -> str | None:
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
    if allow_package_run_backfill:
        return None
    raise BenchmarkInputError(
        f"Homebrew main history never distributed {asset_name} for {version} at {digest}"
    )


def release_tag_commit(source_repository: Path, version: str) -> str:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(source_repository),
            "rev-parse",
            "--verify",
            f"refs/tags/{version}^{{commit}}",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    commit = result.stdout.strip()
    if result.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise BenchmarkInputError(
            f"source checkout has no exact commit for release tag {version}"
        )
    return commit


def release_tag_stack(
    source_repository: Path, source_commit: str
) -> dict[str, dict[str, str]]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(source_repository),
            "show",
            f"{source_commit}:Tools/release/stack-refs.json",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        manifest = json.loads(result.stdout) if result.returncode == 0 else None
    except json.JSONDecodeError as error:
        raise BenchmarkInputError(
            "release tag stack manifest is not valid JSON"
        ) from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise BenchmarkInputError("release tag stack manifest is missing or unsupported")
    components = manifest.get("components")
    if not isinstance(components, dict):
        raise BenchmarkInputError("release tag stack manifest has no components")

    authority: dict[str, dict[str, str]] = {}
    for name in ("container", "containerization"):
        component = components.get(name)
        if not isinstance(component, dict):
            raise BenchmarkInputError(
                f"release tag stack manifest has no {name} component"
            )
        repository = component.get("repository")
        revision = component.get("ref")
        if not isinstance(repository, str) or not repository:
            raise BenchmarkInputError(
                f"release tag stack manifest has no {name} repository"
            )
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise BenchmarkInputError(
                f"release tag stack manifest has no exact {name} revision"
            )
        authority[name] = {"repository": repository, "ref": revision}
    return authority


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
    init_distribution: Path,
    tap_repository: Path,
    source_repository: Path,
    artifact_source: str,
    output: Path,
    allow_package_run_backfill: bool = False,
    latest_stable_version: str | None = None,
) -> dict[str, object]:
    version_tuple(version)
    artifact_source = canonical_artifact_source(version, artifact_source)
    source_commit = release_tag_commit(source_repository, version)
    source_stack = release_tag_stack(source_repository, source_commit)
    release = f"https://github.com/{REPOSITORY}/releases/tag/{version}"
    if allow_package_run_backfill and artifact_source == release:
        raise BenchmarkInputError(
            "maintenance backfill authority requires a retained package run"
        )
    if allow_package_run_backfill and (
        latest_stable_version is None
        or version_tuple(version) >= version_tuple(latest_stable_version)
    ):
        raise BenchmarkInputError(
            "package-run backfill authority is restricted to an older stable release"
        )
    init_asset = init_distribution / INIT_ASSET
    init_sidecar = init_distribution / f"{INIT_ASSET}.sha256"
    if not init_asset.is_file() or not init_sidecar.is_file():
        raise BenchmarkInputError(
            f"published release {version} is missing {INIT_ASSET} or its checksum"
        )
    expected_init_digest = sidecar_digest(init_sidecar, INIT_ASSET)
    actual_init_digest = sha256(init_asset)
    if actual_init_digest != expected_init_digest:
        raise BenchmarkInputError(
            f"published release checksum mismatch for {INIT_ASSET}"
        )
    containerization = source_stack["containerization"]
    init_references = [
        "vminit:container-compose",
        (
            f"ghcr.io/{containerization['repository']}/vminit:"
            f"{containerization['ref']}"
        ),
    ]
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    asset_manifest: dict[str, object] = {}
    homebrew_commits: list[str | None] = []
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
            allow_package_run_backfill,
        )
        homebrew_commits.append(tap_commit)
        component_output = output / component
        component_output.mkdir(mode=0o700)
        with tarfile.open(asset, "r:gz") as archive:
            validate_archive_members(archive)
            extraction_options: dict[str, str] = {}
            if "filter" in inspect.signature(archive.extractall).parameters:
                extraction_options["filter"] = "fully_trusted"
            archive.extractall(component_output, **extraction_options)
        component_manifest: dict[str, object] = {
            "asset": asset_name,
            "sha256": actual_digest,
            "homebrewFormula": formula_path,
        }
        if tap_commit is not None:
            component_manifest["homebrewCommit"] = tap_commit
        else:
            component_manifest["packageRun"] = artifact_source
        asset_manifest[component] = component_manifest
    if any(commit is None for commit in homebrew_commits) and not all(
        commit is None for commit in homebrew_commits
    ):
        raise BenchmarkInputError(
            "release assets have mixed Homebrew and maintenance-backfill authority"
        )
    init_output = output / "init"
    init_output.mkdir(mode=0o700)
    staged_init_asset = init_output / INIT_ASSET
    shutil.copyfile(init_asset, staged_init_asset)
    staged_init_asset.chmod(0o444)
    asset_manifest["guest"] = {
        "asset": INIT_ASSET,
        "sha256": actual_init_digest,
        "source": release,
        "references": init_references,
    }
    manifest: dict[str, object] = {
        "version": version,
        "sourceCommit": source_commit,
        "stack": source_stack,
        "release": release,
        "artifactSource": artifact_source,
        "distributionAuthority": (
            "maintenance-package-run"
            if all(commit is None for commit in homebrew_commits)
            else "homebrew-history"
        ),
        "assets": asset_manifest,
    }
    (output / "published-distribution.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def nearest_rank_p95(values: list[float]) -> float:
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def load_samples(
    evidence: Path,
) -> dict[str, dict[str, list[dict[str, float | str]]]]:
    path = evidence / "timings.tsv"
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        raise BenchmarkInputError(f"benchmark has no samples: {path}")
    grouped: dict[str, dict[str, list[dict[str, float | str]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in rows:
        if row.get("direction") != "lower-is-better":
            raise BenchmarkInputError(
                f"benchmark contains an unsupported sample: {path}"
            )
        lane = row.get("lane")
        fixture = row.get("fixture")
        if lane not in {"docker", "container-compose"} or not fixture:
            raise BenchmarkInputError(f"benchmark contains an invalid lane: {path}")
        outcome = row.get("outcome")
        if not isinstance(outcome, str) or (
            outcome
            not in {
                "success",
                "timeout",
                "skipped-dependency",
                "invalidated-dependency",
            }
            and re.fullmatch(r"exit-[1-9][0-9]*", outcome) is None
        ):
            raise BenchmarkInputError(f"benchmark contains an invalid outcome: {path}")
        grouped[fixture][lane].append(
            {"duration": float(row["duration_seconds"]), "outcome": outcome}
        )
    result = {fixture: dict(lanes) for fixture, lanes in grouped.items()}
    for fixture, lanes in result.items():
        if set(lanes) != {"docker", "container-compose"}:
            raise BenchmarkInputError(f"benchmark fixture has incomplete lanes: {fixture}")
        if len(lanes["docker"]) != len(lanes["container-compose"]):
            raise BenchmarkInputError(f"benchmark fixture has unbalanced lanes: {fixture}")
    return result


def percentage(ratio: float) -> str:
    return f"{(ratio - 1) * 100:+.1f}%"


def validate_release_identity(
    label: str,
    manifest: dict[str, object],
    fingerprints: dict[str, object],
) -> None:
    version = manifest.get("version")
    source_commit = manifest.get("sourceCommit")
    source_stack = manifest.get("stack")
    assets = manifest.get("assets")
    artifact_source = manifest.get("artifactSource")
    compose_record = fingerprints.get("containerCompose")
    runtime_record = fingerprints.get("containerRuntime")
    if (
        not isinstance(version, str)
        or not isinstance(source_commit, str)
        or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None
        or not isinstance(source_stack, dict)
        or not isinstance(assets, dict)
        or not isinstance(artifact_source, str)
        or not isinstance(compose_record, dict)
    ):
        raise BenchmarkInputError(f"{label} release identity is incomplete")
    canonical_artifact_source(version, artifact_source)
    if not isinstance(runtime_record, dict):
        raise BenchmarkInputError(f"{label} runtime identity is incomplete")

    compose = compose_record.get("version")
    runtime_components = runtime_record.get("version")
    if not isinstance(compose, dict):
        raise BenchmarkInputError(f"{label} Compose identity is not structured JSON")
    if not isinstance(runtime_components, list):
        raise BenchmarkInputError(f"{label} runtime identity is not structured JSON")

    stack_components: dict[str, dict[str, str]] = {}
    for name in ("container", "containerization"):
        component = source_stack.get(name)
        if not isinstance(component, dict):
            raise BenchmarkInputError(f"{label} release stack has no {name} authority")
        repository = component.get("repository")
        revision = component.get("ref")
        if not isinstance(repository, str) or not repository:
            raise BenchmarkInputError(
                f"{label} release stack has no {name} repository"
            )
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise BenchmarkInputError(
                f"{label} release stack has no exact {name} revision"
            )
        stack_components[name] = {"repository": repository, "ref": revision}

    container_source = stack_components["container"]["repository"]
    container_ref = stack_components["container"]["ref"]
    containerization_source = stack_components["containerization"]["repository"]
    containerization_ref = stack_components["containerization"]["ref"]
    expected_compose = {
        "version": version,
        "source": REPOSITORY,
        "lane": "stable",
        "buildType": "release",
        "containerSource": container_source,
        "containerRef": container_ref,
        "containerizationSource": containerization_source,
        "containerizationRef": containerization_ref,
    }
    for field, expected in expected_compose.items():
        if compose.get(field) != expected:
            raise BenchmarkInputError(
                f"{label} Compose {field} is {compose.get(field)!r}; expected {expected!r}"
            )

    compose_ref = compose.get("commit")
    if not isinstance(compose_ref, str) or re.fullmatch(r"[0-9a-f]{40}", compose_ref) is None:
        raise BenchmarkInputError(f"{label} Compose commit is not an exact revision")
    if compose_ref != source_commit:
        raise BenchmarkInputError(
            f"{label} Compose commit {compose_ref!r} does not match "
            f"release tag commit {source_commit!r}"
        )

    container_components = [
        component
        for component in runtime_components
        if isinstance(component, dict) and component.get("appName") == "container"
    ]
    if len(container_components) != 1:
        raise BenchmarkInputError(
            f"{label} runtime reports {len(container_components)} container identities"
        )
    container = container_components[0]
    expected_runtime = {
        "buildType": "release",
        "commit": container_ref,
        "source": container_source,
        "containerization": f"{containerization_source}@{containerization_ref}",
    }
    for field, expected in expected_runtime.items():
        if container.get(field) != expected:
            raise BenchmarkInputError(
                f"{label} runtime {field} is {container.get(field)!r}; expected {expected!r}"
            )

    for component in runtime_components:
        if not isinstance(component, dict):
            raise BenchmarkInputError(f"{label} runtime component is not structured JSON")
        app_name = component.get("appName")
        if not isinstance(app_name, str) or not app_name:
            raise BenchmarkInputError(f"{label} runtime component has no appName")
        if component.get("buildType") != "release":
            raise BenchmarkInputError(
                f"{label} runtime component {app_name!r} is not a release build"
            )
        if component.get("commit") != container_ref:
            raise BenchmarkInputError(
                f"{label} runtime component {app_name!r} does not match "
                f"Container revision {container_ref}"
            )

    guest = assets.get("guest")
    runtime_init = runtime_record.get("initImage")
    expected_init_references = [
        "vminit:container-compose",
        f"ghcr.io/{containerization_source}/vminit:{containerization_ref}",
    ]
    if not isinstance(guest, dict):
        raise BenchmarkInputError(f"{label} release has no guest init-image authority")
    init_digest = guest.get("sha256")
    if (
        guest.get("asset") != INIT_ASSET
        or not isinstance(init_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", init_digest) is None
        or guest.get("references") != expected_init_references
    ):
        raise BenchmarkInputError(f"{label} release guest init-image identity is invalid")
    if not isinstance(runtime_init, dict):
        raise BenchmarkInputError(f"{label} runtime did not record its guest init image")
    if (
        runtime_init.get("archiveSha256") != init_digest
        or runtime_init.get("references") != expected_init_references
    ):
        raise BenchmarkInputError(
            f"{label} runtime guest init image does not match the published release"
        )


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
    target_mode = target_manifest.get("comparisonMode", "published-artifacts")
    baseline_mode = baseline_manifest.get("comparisonMode", "published-artifacts")
    if target_mode != baseline_mode:
        raise BenchmarkInputError("target and comparison authority modes differ")
    if target_mode not in {
        "published-artifacts",
        "historical-source-reconstruction",
    }:
        raise BenchmarkInputError(f"unsupported benchmark authority mode: {target_mode}")
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
    validate_release_identity("target", target_manifest, target_fingerprints)
    validate_release_identity("comparison", baseline_manifest, baseline_fingerprints)
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
    normalized_median_ratios: list[float] = []
    normalized_p95_ratios: list[float] = []
    improved = unchanged = regressed = unscored = 0
    for fixture in sorted(target_samples):
        target = target_samples[fixture]
        baseline = baseline_samples[fixture]
        failed: list[str] = []
        for label, samples in (("Comparison", baseline), ("Target", target)):
            for lane in ("docker", "container-compose"):
                outcomes = [
                    str(sample["outcome"])
                    for sample in samples[lane]
                    if sample["outcome"] != "success"
                ]
                if outcomes:
                    failed.append(f"{label} {lane} failed ({', '.join(outcomes)})")
        baseline_candidate = [
            float(sample["duration"])
            for sample in baseline["container-compose"]
            if sample["outcome"] == "success"
        ]
        target_candidate = [
            float(sample["duration"])
            for sample in target["container-compose"]
            if sample["outcome"] == "success"
        ]
        if failed:
            baseline_median = (
                statistics.median(baseline_candidate)
                if len(baseline_candidate) == repetitions
                else None
            )
            baseline_p95 = (
                nearest_rank_p95(baseline_candidate)
                if len(baseline_candidate) == repetitions
                else None
            )
            target_median = (
                statistics.median(target_candidate)
                if len(target_candidate) == repetitions
                else None
            )
            target_p95 = (
                nearest_rank_p95(target_candidate)
                if len(target_candidate) == repetitions
                else None
            )
            rows.append(
                (
                    fixture,
                    baseline_median,
                    target_median,
                    None,
                    baseline_p95,
                    target_p95,
                    None,
                    None,
                    None,
                    "; ".join(failed),
                )
            )
            unscored += 1
            continue
        target_values = target_candidate
        baseline_values = baseline_candidate
        target_docker = [float(sample["duration"]) for sample in target["docker"]]
        baseline_docker = [float(sample["duration"]) for sample in baseline["docker"]]
        target_median = statistics.median(target_values)
        baseline_median = statistics.median(baseline_values)
        target_p95 = nearest_rank_p95(target_values)
        baseline_p95 = nearest_rank_p95(baseline_values)
        target_docker_median = statistics.median(target_docker)
        baseline_docker_median = statistics.median(baseline_docker)
        target_docker_p95 = nearest_rank_p95(target_docker)
        baseline_docker_p95 = nearest_rank_p95(baseline_docker)
        median_ratio = target_median / baseline_median
        p95_ratio = target_p95 / baseline_p95
        normalized_median_ratio = (
            target_median / target_docker_median
        ) / (baseline_median / baseline_docker_median)
        normalized_p95_ratio = (
            target_p95 / target_docker_p95
        ) / (baseline_p95 / baseline_docker_p95)
        normalized_median_ratios.append(normalized_median_ratio)
        normalized_p95_ratios.append(normalized_p95_ratio)
        if normalized_median_ratio < lower:
            verdict = "Improved"
            improved += 1
        elif normalized_median_ratio > upper:
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
                normalized_median_ratio,
                normalized_p95_ratio,
                verdict,
            )
        )

    geometric_median = (
        math.exp(
            sum(math.log(value) for value in normalized_median_ratios)
            / len(normalized_median_ratios)
        )
        if normalized_median_ratios
        else None
    )
    geometric_p95 = (
        math.exp(
            sum(math.log(value) for value in normalized_p95_ratios)
            / len(normalized_p95_ratios)
        )
        if normalized_p95_ratios
        else None
    )
    host = target_fingerprints["host"]
    docker = target_fingerprints["docker"]
    if target_mode == "historical-source-reconstruction":
        report_title = (
            f"# Historical reconstruction benchmark: {target_version} "
            f"versus {baseline_version}"
        )
        authority_summary = (
            "This report compares the immutable, Developer ID-signed host archives "
            "from each release. Each missing guest OCI archive was reconstructed from "
            "the exact retained Containerization CI initfs artifact with a release-mode "
            "`cctl` built from the release's exact Containerization revision. Both "
            "releases ran on the same host against the same Docker installation; "
            "Docker-normalized change is included to expose host drift."
        )
        inputs_heading = "## Reconstructed historical inputs"
    else:
        report_title = (
            f"# Published release benchmark: {target_version} versus {baseline_version}"
        )
        authority_summary = (
            "This report compares immutable, Developer ID-signed release archives. "
            "No source product was built by the benchmark workflow. Both releases ran "
            "on the same host against the same Docker installation; Docker-normalized "
            "change is included to expose host drift."
        )
        inputs_heading = "## Published inputs"
    if geometric_median is None or geometric_p95 is None:
        result_summary = (
            f"No fixture retained complete successful samples in both releases; "
            f"{unscored} fixture{' was' if unscored == 1 else 's were'} "
            "unscored because of recorded execution failures."
        )
    else:
        result_summary = (
            f"Across {len(normalized_median_ratios)} scored fixed-work fixtures, "
            f"the Docker-normalized geometric-mean median changed "
            f"{percentage(geometric_median)} and the Docker-normalized "
            f"geometric-mean P95 changed {percentage(geometric_p95)}. With a "
            f"±{noise:g}% noise band applied to the normalized median, "
            f"{improved} fixtures improved, {unchanged} stayed within noise, and "
            f"{regressed} regressed."
        )
        if unscored:
            result_summary += (
                f" {unscored} additional fixture"
                f"{' was' if unscored == 1 else 's were'} unscored because of "
                "recorded execution failures."
            )
    lines = [
        report_title,
        "",
        authority_summary,
        "",
        "## Result",
        "",
        result_summary,
        "",
        "Lower durations and negative changes are better.",
        "",
        inputs_heading,
        "",
    ]
    for label, manifest in (("Target", target_manifest), ("Comparison", baseline_manifest)):
        lines.extend(
            [
                f"### {label} {manifest['version']}",
                "",
                f"Release: [{manifest['release']}]({manifest['release']})",
                f"Artifact source: [{manifest['artifactSource']}]({manifest['artifactSource']}).",
                f"Release tag commit: `{manifest['sourceCommit']}`.",
                f"Container: `{manifest['stack']['container']['repository']}@{manifest['stack']['container']['ref']}`.",
                f"Containerization: `{manifest['stack']['containerization']['repository']}@{manifest['stack']['containerization']['ref']}`.",
                f"Guest init image: `{manifest['assets']['guest']['asset']}` at `{manifest['assets']['guest']['sha256']}`.",
                "",
            ]
        )
        reconstruction = manifest["assets"]["guest"].get("reconstruction")
        if reconstruction:
            lines.extend(
                [
                    f"- Guest initfs authority: [{reconstruction['runUrl']}]({reconstruction['runUrl']}); artifact `{reconstruction['artifactId']}` at `{reconstruction['artifactDigest']}`.",
                    f"- Guest packager: `containerization@{reconstruction['containerizationRef']}`; recoverable receipt `{reconstruction['cctlReceiptSha256']}`; stage artifact `{reconstruction['cctlArtifactSha256']}`; extracted `cctl` `{reconstruction['cctlSha256']}`.",
                    f"- Guest packager inputs: source `{reconstruction['cctlBuildSourceSha256']}`; source metadata `{reconstruction['cctlBuildSourceMetadataSha256']}`; command `{reconstruction['cctlBuildCommandSha256']}`; tools `{reconstruction['cctlBuildToolsSha256']}`.",
                ]
            )
        for component in ("runtime", "compose"):
            asset = manifest["assets"][component]
            homebrew_commit = asset.get("homebrewCommit")
            if homebrew_commit:
                authority = f"Homebrew formula history `{homebrew_commit}`"
            else:
                authority = (
                    "signed maintenance package run "
                    f"[{manifest['artifactSource']}]({manifest['artifactSource']}); "
                    "not promoted through Homebrew"
                )
            lines.append(
                f"- `{asset['asset']}`: SHA-256 `{asset['sha256']}`; {authority}."
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
            "| Fixture | Comparison median (s) | Target median (s) | Raw median change | Comparison P95 (s) | Target P95 (s) | Raw P95 change | Docker-normalized median change | Docker-normalized P95 change | Verdict |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    def duration(value: object) -> str:
        return f"{float(value):.3f}" if value is not None else "n/a"

    def change(value: object) -> str:
        return percentage(float(value)) if value is not None else "n/a"

    for row in rows:
        fixture, baseline_median, target_median, median_ratio, baseline_p95, target_p95, p95_ratio, normalized_median_ratio, normalized_p95_ratio, verdict = row
        lines.append(
            f"| {fixture} | {duration(baseline_median)} | {duration(target_median)} | {change(median_ratio)} | {duration(baseline_p95)} | {duration(target_p95)} | {change(p95_ratio)} | {change(normalized_median_ratio)} | {change(normalized_p95_ratio)} | {verdict} |"
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

    package_run = subparsers.add_parser("resolve-package-run")
    package_run.add_argument("--runs", type=Path, required=True)
    package_run.add_argument("--version", required=True)

    package_candidates = subparsers.add_parser("package-run-candidates")
    package_candidates.add_argument("--runs", type=Path, required=True)
    package_candidates.add_argument("--version", required=True)

    package_artifacts = subparsers.add_parser("validate-package-artifacts")
    package_artifacts.add_argument("--artifacts", type=Path, required=True)

    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--distribution", type=Path, required=True)
    prepare.add_argument("--init-distribution", type=Path, required=True)
    prepare.add_argument("--tap-repository", type=Path, required=True)
    prepare.add_argument("--source-repository", type=Path, required=True)
    prepare.add_argument("--artifact-source", required=True)
    prepare.add_argument("--allow-package-run-backfill", action="store_true")
    prepare.add_argument("--latest-stable-version")
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
        elif arguments.command in {
            "resolve-package-run",
            "package-run-candidates",
        }:
            runs = load_json(arguments.runs)
            if not isinstance(runs, list):
                raise BenchmarkInputError("package run metadata must be a JSON array")
            if arguments.command == "package-run-candidates":
                result = packaging_run_candidates(runs, arguments.version)
            else:
                result = resolve_packaging_run(runs, arguments.version)
            print(json.dumps(result, sort_keys=True))
        elif arguments.command == "validate-package-artifacts":
            artifacts = load_json(arguments.artifacts)
            if not isinstance(artifacts, dict):
                raise BenchmarkInputError(
                    "package run artifact metadata must be a JSON object"
                )
            result = validate_packaging_artifacts(artifacts)
            print(json.dumps(result, sort_keys=True))
        elif arguments.command == "prepare":
            result = prepare_distribution(
                arguments.version,
                arguments.distribution,
                arguments.init_distribution,
                arguments.tap_repository,
                arguments.source_repository,
                arguments.artifact_source,
                arguments.output,
                arguments.allow_package_run_backfill,
                arguments.latest_stable_version,
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
