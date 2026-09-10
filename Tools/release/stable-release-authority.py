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
import math
import os
import re
from pathlib import Path
from typing import Any


CHECKPOINT_SCHEMA = 4
OBJECT_ID = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
STAGE = "hosted-sibling-stack"


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


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not DIGEST.fullmatch(value):
        raise SystemExit(f"stable release authority {label} is invalid")
    return value


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


def load_checkpoint(evidence: Path) -> tuple[dict[str, Any], Path, Path]:
    checkpoint_path = require_file(evidence / f"{STAGE}.success.json")
    try:
        checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"stable release authority checkpoint is malformed: {error.msg}"
        ) from error
    if not isinstance(checkpoint, dict):
        raise SystemExit("stable release authority checkpoint is not an object")
    if checkpoint.get("schema") != CHECKPOINT_SCHEMA:
        raise SystemExit("stable release authority checkpoint schema is unsupported")
    if checkpoint.get("stage") != STAGE or checkpoint.get("status") != 0:
        raise SystemExit("stable release authority checkpoint did not pass")
    if checkpoint.get("fingerprint_before") != checkpoint.get("fingerprint_after"):
        raise SystemExit("stable release authority inputs changed during validation")
    require_digest(checkpoint.get("digest"), "checkpoint digest")
    output_digest = require_digest(
        checkpoint.get("output_sha256"), "checkpoint output digest"
    )
    output_file = checkpoint.get("output_file")
    if (
        not isinstance(output_file, str)
        or not output_file
        or Path(output_file).name != output_file
    ):
        raise SystemExit("stable release authority checkpoint output name is unsafe")
    output_path = require_file(evidence / output_file)
    if sha256_file(output_path) != output_digest:
        raise SystemExit("stable release authority checkpoint output changed")
    duration = checkpoint.get("duration_seconds")
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(duration)
        or duration < 0
    ):
        raise SystemExit("stable release authority checkpoint duration is invalid")
    fingerprint = checkpoint.get("fingerprint")
    if not isinstance(fingerprint, str) or not fingerprint:
        raise SystemExit("stable release authority checkpoint fingerprint is invalid")
    return checkpoint, checkpoint_path, output_path


def build_receipt(arguments: argparse.Namespace) -> dict[str, Any]:
    values = validated_inputs(arguments)
    evidence_input = Path(arguments.evidence_dir)
    if evidence_input.is_symlink() or not evidence_input.is_dir():
        raise SystemExit(
            "stable release authority evidence is indirect or missing: "
            f"{evidence_input}"
        )
    evidence = evidence_input.resolve()
    checkpoint, checkpoint_path, output_path = load_checkpoint(evidence)

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
    fingerprint = str(checkpoint["fingerprint"])
    return {
        "schema": 2,
        "result": "success",
        "releaseTag": values["releaseTag"],
        **package_inputs,
        "packageInputsSha256": package_inputs_sha256,
        "buildEvidence": {
            "checkpointSha256": sha256_file(checkpoint_path),
            "durationSeconds": checkpoint["duration_seconds"],
            "fingerprintSha256": hashlib.sha256(fingerprint.encode()).hexdigest(),
            "outputFile": output_path.name,
            "outputSha256": sha256_file(output_path),
            "stage": STAGE,
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
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o444)
        os.replace(temporary, output)
        directory_descriptor = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
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
