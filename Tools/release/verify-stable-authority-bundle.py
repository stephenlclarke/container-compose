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

"""Verify a published stable-authority archive without extracting it."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any


OBJECT_ID = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
MAX_FILE_SIZE = 64 * 1024 * 1024
MAX_ARCHIVE_SIZE = 128 * 1024 * 1024


class AuthorityBundleError(RuntimeError):
    """The authority archive does not prove its claimed candidate."""


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not DIGEST.fullmatch(value):
        raise AuthorityBundleError(f"invalid {label}")
    return value


def read_bundle(path: Path) -> dict[str, bytes]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise AuthorityBundleError(f"authority bundle is indirect or missing: {path}")
    files: dict[str, bytes] = {}
    total = 0
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            name = str(PurePosixPath(member.name))
            while name.startswith("./"):
                name = name[2:]
            if member.isdir() and name in {"", "."}:
                continue
            if (
                not member.isfile()
                or not name
                or PurePosixPath(name).name != name
                or member.size < 0
                or member.size > MAX_FILE_SIZE
                or name in files
            ):
                raise AuthorityBundleError(f"unsafe authority bundle member: {member.name}")
            stream = archive.extractfile(member)
            if stream is None:
                raise AuthorityBundleError(f"unreadable authority bundle member: {name}")
            payload = stream.read(MAX_FILE_SIZE + 1)
            total += len(payload)
            if len(payload) != member.size or total > MAX_ARCHIVE_SIZE:
                raise AuthorityBundleError("authority bundle exceeds its safe size")
            files[name] = payload
    return files


def read_json(files: dict[str, bytes], name: str) -> dict[str, Any]:
    try:
        value = json.loads(files[name])
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuthorityBundleError(f"invalid authority bundle JSON: {name}") from error
    if not isinstance(value, dict):
        raise AuthorityBundleError(f"authority bundle JSON is not an object: {name}")
    return value


def verify_bundle(options: argparse.Namespace) -> tuple[str, str]:
    expected_objects = {
        "candidateSha": options.candidate_sha,
        "containerBuilderShim": options.builder_ref,
        "containerization": options.containerization_ref,
        "container": options.container_ref,
    }
    if not SEMVER.fullmatch(options.release_tag):
        raise AuthorityBundleError("invalid stable release tag")
    for label, value in expected_objects.items():
        if not OBJECT_ID.fullmatch(value):
            raise AuthorityBundleError(f"invalid expected {label}")
    require_digest(options.init_image_sha256, "expected guest image digest")

    files = read_bundle(options.archive)
    receipt_name = "stable-release-authority.json"
    receipt = read_json(files, receipt_name)
    receipt_digest = digest_bytes(files[receipt_name])
    if options.receipt_sha256 and receipt_digest != options.receipt_sha256:
        raise AuthorityBundleError("authority receipt digest does not match its check")
    if receipt.get("schema") != 2 or receipt.get("result") != "success":
        raise AuthorityBundleError("authority receipt did not pass")
    if receipt.get("releaseTag") != options.release_tag:
        raise AuthorityBundleError("authority receipt release tag changed")
    if receipt.get("candidateSha") != options.candidate_sha:
        raise AuthorityBundleError("authority receipt candidateSha changed")
    if receipt.get("guestInitImageSha256") != options.init_image_sha256:
        raise AuthorityBundleError("authority receipt guest image digest changed")
    components = receipt.get("components")
    if not isinstance(components, dict) or set(components) != {
        "container-builder-shim",
        "containerization",
        "container",
        "homebrew-tap",
    }:
        raise AuthorityBundleError("authority receipt components are invalid")
    expected_components = {
        "container-builder-shim": options.builder_ref,
        "containerization": options.containerization_ref,
        "container": options.container_ref,
    }
    for name, value in expected_components.items():
        if components.get(name) != value:
            raise AuthorityBundleError(f"authority receipt component changed: {name}")
    homebrew_ref = components.get("homebrew-tap")
    if not isinstance(homebrew_ref, str) or not OBJECT_ID.fullmatch(homebrew_ref):
        raise AuthorityBundleError("authority receipt Homebrew snapshot is invalid")

    package_inputs = {
        "candidateSha": options.candidate_sha,
        "components": components,
        "guestInitImageSha256": options.init_image_sha256,
    }
    package_digest = digest_bytes(
        json.dumps(package_inputs, sort_keys=True, separators=(",", ":")).encode()
    )
    if receipt.get("packageInputsSha256") != package_digest:
        raise AuthorityBundleError("authority package-input digest changed")

    evidence = receipt.get("buildEvidence")
    if not isinstance(evidence, dict) or evidence.get("stage") != "hosted-sibling-stack":
        raise AuthorityBundleError("authority build evidence is invalid")
    checkpoint_name = "hosted-sibling-stack.success.json"
    checkpoint = read_json(files, checkpoint_name)
    if digest_bytes(files[checkpoint_name]) != evidence.get("checkpointSha256"):
        raise AuthorityBundleError("authority checkpoint digest changed")
    if (
        checkpoint.get("schema") != 4
        or checkpoint.get("stage") != "hosted-sibling-stack"
        or checkpoint.get("status") != 0
        or checkpoint.get("fingerprint_before") != checkpoint.get("fingerprint_after")
    ):
        raise AuthorityBundleError("authority checkpoint did not pass unchanged inputs")
    require_digest(checkpoint.get("digest"), "checkpoint digest")
    output_name = checkpoint.get("output_file")
    if not isinstance(output_name, str) or PurePosixPath(output_name).name != output_name:
        raise AuthorityBundleError("authority checkpoint output name is unsafe")
    output = files.get(output_name)
    if output is None or set(files) != {receipt_name, checkpoint_name, output_name}:
        raise AuthorityBundleError("authority bundle file closure changed")
    output_digest = digest_bytes(output)
    if (
        checkpoint.get("output_sha256") != output_digest
        or evidence.get("outputFile") != output_name
        or evidence.get("outputSha256") != output_digest
    ):
        raise AuthorityBundleError("authority checkpoint output changed")
    duration = checkpoint.get("duration_seconds")
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(duration)
        or duration < 0
        or evidence.get("durationSeconds") != duration
    ):
        raise AuthorityBundleError("authority checkpoint duration is invalid")
    fingerprint = checkpoint.get("fingerprint")
    if (
        not isinstance(fingerprint, str)
        or not fingerprint
        or evidence.get("fingerprintSha256")
        != digest_bytes(fingerprint.encode())
    ):
        raise AuthorityBundleError("authority checkpoint fingerprint changed")
    return receipt_digest, homebrew_ref


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--builder-ref", required=True)
    parser.add_argument("--containerization-ref", required=True)
    parser.add_argument("--container-ref", required=True)
    parser.add_argument("--init-image-sha256", required=True)
    parser.add_argument("--receipt-sha256")
    options = parser.parse_args()
    try:
        receipt_digest, homebrew_ref = verify_bundle(options)
    except (AuthorityBundleError, OSError, tarfile.TarError) as error:
        print(f"verify-stable-authority-bundle: {error}", file=sys.stderr)
        return 2
    print(f"{receipt_digest}\t{homebrew_ref}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
