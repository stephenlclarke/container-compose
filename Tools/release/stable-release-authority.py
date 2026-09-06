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

"""Create or verify one candidate-bound stable release authority receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any


OBJECT_ID = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"stable release authority input is indirect or missing: {path}")
    return path


def parse_pairs(path: Path) -> list[tuple[str, ...]]:
    rows: list[tuple[str, ...]] = []
    for line in require_file(path).read_text(encoding="utf-8").splitlines():
        fields = tuple(line.split("\t"))
        if len(fields) < 2 or any(not field for field in fields):
            raise SystemExit(f"stable release authority input is malformed: {path}")
        rows.append(fields)
    return rows


def unique_value(rows: list[tuple[str, ...]], name: str, path: Path) -> str:
    values = [row[1] for row in rows if len(row) == 2 and row[0] == name]
    if len(values) != 1:
        raise SystemExit(f"stable release authority input has no unique {name}: {path}")
    return values[0]


def validated_inputs(arguments: argparse.Namespace) -> dict[str, str]:
    values = {
        "releaseTag": arguments.release_tag,
        "candidateSha": arguments.candidate_sha,
        "containerBuilderShim": arguments.builder_ref,
        "containerization": arguments.containerization_ref,
        "container": arguments.container_ref,
        "homebrewTap": arguments.homebrew_tap_ref,
        "guestInitImageSha256": arguments.init_image_sha256,
    }
    if not SEMVER.fullmatch(values["releaseTag"]):
        raise SystemExit(f"stable release tag is invalid: {values['releaseTag']}")
    for name in (
        "candidateSha",
        "containerBuilderShim",
        "containerization",
        "container",
        "homebrewTap",
    ):
        if not OBJECT_ID.fullmatch(values[name]):
            raise SystemExit(f"stable release authority {name} is not immutable")
    if not DIGEST.fullmatch(values["guestInitImageSha256"]):
        raise SystemExit("stable release authority guest image digest is invalid")
    return values


def build_receipt(arguments: argparse.Namespace) -> dict[str, Any]:
    values = validated_inputs(arguments)
    evidence_input = Path(arguments.evidence_dir)
    if evidence_input.is_symlink() or not evidence_input.is_dir():
        raise SystemExit(
            "stable release authority evidence is indirect or missing: "
            f"{evidence_input}"
        )
    evidence = evidence_input.resolve()
    preflight = evidence / "preflight"
    if preflight.is_symlink() or not preflight.is_dir():
        raise SystemExit(
            f"stable release authority preflight is indirect or missing: {preflight}"
        )
    summary = evidence / "pipeline-summary.tsv"
    attempt = evidence / "attempt.tsv"
    session = evidence / "session.uuid"
    summary_rows = parse_pairs(summary)
    attempt_rows = parse_pairs(attempt)
    session_value = require_file(session).read_text(encoding="utf-8").strip()
    if unique_value(summary_rows, "schema", summary) != "1":
        raise SystemExit("stable release authority pipeline summary schema is unsupported")
    if unique_value(summary_rows, "profile", summary) != "release-hosted":
        raise SystemExit("stable release authority pipeline profile is not release-hosted")
    if unique_value(summary_rows, "complete", summary) != "true":
        raise SystemExit("stable release authority pipeline summary is incomplete")
    if unique_value(attempt_rows, "profile", attempt) != "release-hosted":
        raise SystemExit("stable release authority attempt profile is not release-hosted")
    for status in ("orchestrator-exit", "tee-exit", "evidence-exit", "exit"):
        if unique_value(attempt_rows, status, attempt) != "0":
            raise SystemExit(f"stable release authority attempt did not pass: {status}")
    if not re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        session_value,
    ):
        raise SystemExit("stable release authority session UUID is invalid")

    evidence_entries: list[dict[str, str]] = []
    for row in summary_rows:
        if row[0] not in {
            "repository-receipt",
            "stage-artifact",
            "stage-output",
            "stage-receipt",
        }:
            continue
        if len(row) != 3 or not DIGEST.fullmatch(row[2]):
            raise SystemExit(
                f"stable release authority pipeline evidence is malformed: {row[0]}"
            )
        evidence_entries.append(
            {"kind": row[0], "name": row[1], "sha256": row[2]}
        )
    if not evidence_entries:
        raise SystemExit("stable release authority pipeline evidence is empty")
    if len({(item["kind"], item["name"]) for item in evidence_entries}) != len(
        evidence_entries
    ):
        raise SystemExit("stable release authority pipeline evidence contains duplicates")

    repository_digests = {
        item["name"]: item["sha256"]
        for item in evidence_entries
        if item["kind"] == "repository-receipt"
    }
    expected_commits = {
        "container-compose": values["candidateSha"],
        "container-builder-shim": values["containerBuilderShim"],
        "containerization": values["containerization"],
        "container": values["container"],
        "homebrew-tap": values["homebrewTap"],
    }
    for repository, commit in expected_commits.items():
        for kind in ("identity", "provenance"):
            name = f"{repository}.{kind}.tsv"
            repository_receipt = preflight / name
            if repository_digests.get(name) != sha256_file(
                require_file(repository_receipt)
            ):
                raise SystemExit(
                    f"stable release authority repository receipt changed: {name}"
                )
            repository_rows = parse_pairs(repository_receipt)
            if unique_value(repository_rows, "repository", repository_receipt) != repository:
                raise SystemExit(
                    f"stable release authority repository name changed: {name}"
                )
            if unique_value(repository_rows, "commit", repository_receipt) != commit:
                raise SystemExit(
                    f"stable release authority repository commit changed: {name}"
                )
            if unique_value(repository_rows, "clean", repository_receipt) != "true":
                raise SystemExit(
                    f"stable release authority repository was not clean: {name}"
                )

    package_inputs = {
        "candidateSha": values["candidateSha"],
        "components": {
            "container-builder-shim": values["containerBuilderShim"],
            "containerization": values["containerization"],
            "container": values["container"],
            "homebrew-tap": values["homebrewTap"],
        },
        "guestInitImageSha256": values["guestInitImageSha256"],
    }
    package_inputs_sha256 = hashlib.sha256(
        json.dumps(package_inputs, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    host_tools_sha256 = unique_value(summary_rows, "host-tools-sha256", summary)
    if not DIGEST.fullmatch(host_tools_sha256):
        raise SystemExit("stable release authority host toolchain digest is invalid")
    return {
        "schema": 1,
        "result": "success",
        "releaseTag": values["releaseTag"],
        **package_inputs,
        "packageInputsSha256": package_inputs_sha256,
        "pipeline": {
            "attemptSha256": sha256_file(attempt),
            "evidence": evidence_entries,
            "hostToolsSha256": host_tools_sha256,
            "session": session_value,
            "summarySha256": sha256_file(summary),
        },
    }


def write_receipt(receipt: dict[str, Any], output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise SystemExit(f"refusing to replace stable release authority receipt: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    if temporary.exists() or temporary.is_symlink():
        raise SystemExit(f"stable release authority temporary output exists: {temporary}")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        os.chmod(temporary, 0o444)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def verify_receipt(expected: dict[str, Any], receipt: Path) -> str:
    try:
        actual = json.loads(require_file(receipt).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"stable release authority receipt is malformed: {error.msg}"
        ) from error
    if actual != expected:
        raise SystemExit("stable release authority receipt does not match its evidence")
    return sha256_file(receipt)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("create", "verify"))
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--builder-ref", required=True)
    parser.add_argument("--containerization-ref", required=True)
    parser.add_argument("--container-ref", required=True)
    parser.add_argument("--homebrew-tap-ref", required=True)
    parser.add_argument("--init-image-sha256", required=True)
    arguments = parser.parse_args()
    expected = build_receipt(arguments)
    receipt = Path(arguments.receipt)
    if arguments.mode == "create":
        write_receipt(expected, receipt)
        print(sha256_file(receipt))
        return
    print(verify_receipt(expected, receipt))


if __name__ == "__main__":
    main()
