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

"""Recover exact historical guest inputs omitted from stable release assets."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import stat
import tarfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Iterable

import published_release_benchmark as published


CONTAINERIZATION_REPOSITORY = "stephenlclarke/containerization"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ReconstructionInputError(ValueError):
    """Raised when historical reconstruction authority is incomplete."""


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_containerization_run(
    runs: Iterable[dict[str, object]], revision: str
) -> dict[str, object]:
    if COMMIT.fullmatch(revision) is None:
        raise ReconstructionInputError(
            f"Containerization revision must be an exact commit: {revision}"
        )
    candidates: list[tuple[str, int, str]] = []
    for run in runs:
        if (
            run.get("workflowName") != "Build containerization"
            or run.get("headSha") != revision
            or run.get("status") != "completed"
            or run.get("conclusion") != "success"
            or run.get("event") not in {"push", "workflow_dispatch"}
        ):
            continue
        run_id = run.get("databaseId")
        created_at = run.get("createdAt")
        url = run.get("url")
        if (
            not isinstance(run_id, int)
            or run_id <= 0
            or not isinstance(created_at, str)
            or not created_at
            or url
            != f"https://github.com/{CONTAINERIZATION_REPOSITORY}/actions/runs/{run_id}"
        ):
            continue
        candidates.append((created_at, run_id, url))
    if not candidates:
        raise ReconstructionInputError(
            f"no successful Containerization build run exists at {revision}"
        )
    created_at, run_id, url = max(candidates)
    return {
        "containerizationRef": revision,
        "createdAt": created_at,
        "runId": run_id,
        "runUrl": url,
    }


def validate_initfs_artifact(
    payload: dict[str, object], run: dict[str, object]
) -> dict[str, object]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise ReconstructionInputError("artifact metadata is not an array")
    matches = [
        artifact
        for artifact in artifacts
        if isinstance(artifact, dict) and artifact.get("name") == "initfs"
    ]
    if len(matches) != 1:
        raise ReconstructionInputError(
            "Containerization run must retain exactly one initfs artifact"
        )
    artifact = matches[0]
    artifact_id = artifact.get("id")
    digest = artifact.get("digest")
    archive_url = artifact.get("archive_download_url")
    workflow_run = artifact.get("workflow_run")
    if (
        not isinstance(artifact_id, int)
        or artifact_id <= 0
        or artifact.get("expired") is not False
        or not isinstance(digest, str)
        or not digest.startswith("sha256:")
        or SHA256.fullmatch(digest.removeprefix("sha256:")) is None
        or archive_url
        != (
            "https://api.github.com/repos/"
            f"{CONTAINERIZATION_REPOSITORY}/actions/artifacts/{artifact_id}/zip"
        )
        or not isinstance(workflow_run, dict)
        or workflow_run.get("id") != run.get("runId")
        or workflow_run.get("head_sha") != run.get("containerizationRef")
    ):
        raise ReconstructionInputError(
            "initfs artifact is expired or does not match the exact build run"
        )
    return {
        **run,
        "artifactId": artifact_id,
        "artifactDigest": digest,
        "archiveDownloadUrl": archive_url,
    }


def extract_initfs(archive: Path, expected_digest: str, output: Path) -> None:
    digest = expected_digest.removeprefix("sha256:")
    if SHA256.fullmatch(digest) is None or file_sha256(archive) != digest:
        raise ReconstructionInputError("downloaded initfs artifact digest mismatch")
    required = {"initfs.ext4", "init.rootfs.tar.gz"}
    members: dict[str, zipfile.ZipInfo] = {}
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            member_path = PurePosixPath(member.filename)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise ReconstructionInputError(
                    f"unsafe initfs artifact path: {member.filename}"
                )
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ReconstructionInputError(
                    f"initfs artifact contains a symbolic link: {member.filename}"
                )
            if member.is_dir():
                continue
            basename = member_path.name
            if basename not in required or basename in members:
                raise ReconstructionInputError(
                    f"unexpected initfs artifact member: {member.filename}"
                )
            members[basename] = member
        if set(members) != required:
            missing = ", ".join(sorted(required - set(members)))
            raise ReconstructionInputError(
                f"initfs artifact is missing required members: {missing}"
            )
        output.mkdir(parents=True, exist_ok=False)
        for basename, member in members.items():
            destination = output / basename
            with bundle.open(member) as source, destination.open("wb") as target:
                shutil.copyfileobj(source, target)
            destination.chmod(0o444)


def read_tsv(path: Path) -> list[list[str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.reader(handle, delimiter="\t"))


def extract_cctl(
    archive: Path,
    manifest: Path,
    receipt: Path,
    summary: Path,
    output: Path,
) -> dict[str, object]:
    rows = read_tsv(manifest)
    records = {row[0]: row[1:] for row in rows if len(row) >= 2}
    artifact_rows = [row for row in rows if row[:2] == ["artifact", "bin/cctl"]]
    receipt_rows = read_tsv(receipt)
    receipt_records = {
        row[0]: row[1:] for row in receipt_rows if len(row) >= 2
    }
    summary_rows = read_tsv(summary)
    archive_digest = file_sha256(archive)
    manifest_digest = file_sha256(manifest)
    receipt_digest = file_sha256(receipt)
    expected_summary_rows = {
        ("stage-receipt", receipt.name, receipt_digest),
        ("stage-artifact", archive.name, archive_digest),
        ("stage-artifact", manifest.name, manifest_digest),
    }
    observed_summary_rows = {
        tuple(row) for row in summary_rows if row and row[0].startswith("stage-")
    }
    if (
        records.get("schema") != ["1"]
        or records.get("stage") != ["containerization-benchmark-cctl"]
        or records.get("repository") != ["containerization"]
        or records.get("artifact-count") != ["1"]
        or len(artifact_rows) != 1
        or len(artifact_rows[0]) != 4
        or SHA256.fullmatch(artifact_rows[0][2]) is None
        or records.get("archive-sha256") != [archive_digest]
        or receipt_records.get("schema") != ["3"]
        or receipt_records.get("stage") != ["containerization-benchmark-cctl"]
        or receipt_records.get("repository") != ["containerization"]
        or receipt_records.get("artifact-archive-sha256") != [archive_digest]
        or receipt_records.get("artifact-manifest-sha256") != [manifest_digest]
        or receipt_records.get("artifact-count") != ["1"]
        or receipt_records.get("exit") != ["0"]
        or not expected_summary_rows.issubset(observed_summary_rows)
    ):
        raise ReconstructionInputError(
            "recoverable cctl artifact evidence is invalid"
        )
    evidence_keys = (
        "source-payload-sha256",
        "source-metadata-sha256",
        "command-sha256",
        "stage-tools-sha256",
    )
    if any(
        len(receipt_records.get(key, [])) != 1
        or SHA256.fullmatch(receipt_records[key][0]) is None
        for key in evidence_keys
    ):
        raise ReconstructionInputError(
            "recoverable cctl build identity is incomplete"
        )
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        if len(members) != 1 or members[0].name != "bin/cctl":
            raise ReconstructionInputError("recoverable artifact is not exactly bin/cctl")
        member = members[0]
        if not member.isfile() or member.issym() or member.islnk():
            raise ReconstructionInputError("recoverable cctl artifact is not regular")
        source = bundle.extractfile(member)
        if source is None:
            raise ReconstructionInputError("recoverable cctl artifact cannot be read")
        output.parent.mkdir(parents=True, exist_ok=True)
        with source, output.open("wb") as target:
            shutil.copyfileobj(source, target)
    if file_sha256(output) != artifact_rows[0][2]:
        raise ReconstructionInputError("extracted cctl digest mismatch")
    output.chmod(0o500)
    return {
        "cctlArtifactSha256": archive_digest,
        "cctlBuildCommandSha256": receipt_records["command-sha256"][0],
        "cctlBuildSourceMetadataSha256": receipt_records[
            "source-metadata-sha256"
        ][0],
        "cctlBuildSourceSha256": receipt_records["source-payload-sha256"][0],
        "cctlBuildToolsSha256": receipt_records["stage-tools-sha256"][0],
        "cctlReceiptSha256": receipt_digest,
        "cctlSha256": artifact_rows[0][2],
    }


def prepare_reconstruction(
    version: str,
    distribution: Path,
    init_distribution: Path,
    tap_repository: Path,
    source_repository: Path,
    artifact_source: str,
    guest_provenance_path: Path,
    output: Path,
) -> dict[str, object]:
    provenance = json.loads(guest_provenance_path.read_text(encoding="utf-8"))
    required = {
        "artifactDigest",
        "artifactId",
        "cctlArtifactSha256",
        "cctlBuildCommandSha256",
        "cctlBuildSourceMetadataSha256",
        "cctlBuildSourceSha256",
        "cctlBuildToolsSha256",
        "cctlReceiptSha256",
        "cctlSha256",
        "containerizationRef",
        "runUrl",
    }
    if not isinstance(provenance, dict) or not required.issubset(provenance):
        raise ReconstructionInputError("guest reconstruction provenance is incomplete")
    if (
        COMMIT.fullmatch(str(provenance["containerizationRef"])) is None
        or SHA256.fullmatch(str(provenance["cctlArtifactSha256"])) is None
        or any(
            SHA256.fullmatch(str(provenance[key])) is None
            for key in required
            if key.endswith("Sha256")
        )
        or re.fullmatch(r"sha256:[0-9a-f]{64}", str(provenance["artifactDigest"]))
        is None
        or not isinstance(provenance["artifactId"], int)
        or provenance["artifactId"] <= 0
        or provenance["runUrl"]
        != f"https://github.com/{CONTAINERIZATION_REPOSITORY}/actions/runs/{provenance.get('runId')}"
    ):
        raise ReconstructionInputError("guest reconstruction provenance is invalid")
    manifest = published.prepare_distribution(
        version,
        distribution,
        init_distribution,
        tap_repository,
        source_repository,
        artifact_source,
        output,
    )
    stack_ref = manifest["stack"]["containerization"]["ref"]  # type: ignore[index]
    if provenance["containerizationRef"] != stack_ref:
        raise ReconstructionInputError(
            "guest reconstruction does not match the release stack"
        )
    manifest["comparisonMode"] = "historical-source-reconstruction"
    guest = manifest["assets"]["guest"]  # type: ignore[index]
    guest["source"] = provenance["runUrl"]  # type: ignore[index]
    guest["reconstruction"] = provenance  # type: ignore[index]
    (output / "published-distribution.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve-run")
    resolve.add_argument("--runs", type=Path, required=True)
    resolve.add_argument("--revision", required=True)

    validate = subparsers.add_parser("validate-initfs")
    validate.add_argument("--run", type=Path, required=True)
    validate.add_argument("--artifacts", type=Path, required=True)

    initfs = subparsers.add_parser("extract-initfs")
    initfs.add_argument("--archive", type=Path, required=True)
    initfs.add_argument("--digest", required=True)
    initfs.add_argument("--output", type=Path, required=True)

    cctl = subparsers.add_parser("extract-cctl")
    cctl.add_argument("--archive", type=Path, required=True)
    cctl.add_argument("--manifest", type=Path, required=True)
    cctl.add_argument("--receipt", type=Path, required=True)
    cctl.add_argument("--summary", type=Path, required=True)
    cctl.add_argument("--output", type=Path, required=True)

    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--distribution", type=Path, required=True)
    prepare.add_argument("--init-distribution", type=Path, required=True)
    prepare.add_argument("--tap-repository", type=Path, required=True)
    prepare.add_argument("--source-repository", type=Path, required=True)
    prepare.add_argument("--artifact-source", required=True)
    prepare.add_argument("--guest-provenance", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "resolve-run":
            runs = load_json(arguments.runs)
            if not isinstance(runs, list):
                raise ReconstructionInputError("run metadata has an invalid shape")
            print(
                json.dumps(
                    resolve_containerization_run(runs, arguments.revision),
                    sort_keys=True,
                )
            )
        elif arguments.command == "validate-initfs":
            run = load_json(arguments.run)
            artifacts = load_json(arguments.artifacts)
            if not isinstance(run, dict) or not isinstance(artifacts, dict):
                raise ReconstructionInputError("artifact metadata has an invalid shape")
            print(json.dumps(validate_initfs_artifact(artifacts, run), sort_keys=True))
        elif arguments.command == "extract-initfs":
            extract_initfs(arguments.archive, arguments.digest, arguments.output)
        elif arguments.command == "extract-cctl":
            print(
                json.dumps(
                    extract_cctl(
                        arguments.archive,
                        arguments.manifest,
                        arguments.receipt,
                        arguments.summary,
                        arguments.output,
                    ),
                    sort_keys=True,
                )
            )
        else:
            print(
                json.dumps(
                    prepare_reconstruction(
                        arguments.version,
                        arguments.distribution,
                        arguments.init_distribution,
                        arguments.tap_repository,
                        arguments.source_repository,
                        arguments.artifact_source,
                        arguments.guest_provenance,
                        arguments.output,
                    ),
                    sort_keys=True,
                )
            )
    except (ReconstructionInputError, published.BenchmarkInputError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
