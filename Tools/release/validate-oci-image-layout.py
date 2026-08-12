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

"""Validate a retained OCI image-layout archive and its descriptor closure."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
from typing import Any


INDEX_MEDIA_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
MANIFEST_MEDIA_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
ARTIFACT_MEDIA_TYPE = "application/vnd.oci.artifact.manifest.v1+json"
DIGEST_PATTERN = re.compile(r"^[a-z0-9]+(?:[+._-][a-z0-9]+)*:[0-9a-f]+$")


class ValidationError(ValueError):
    """An OCI layout invariant was not satisfied."""


def normalized_member_name(name: str) -> str:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValidationError(f"archive contains unsafe member path: {name}")
    parts = list(path.parts)
    while parts and parts[0] == ".":
        parts.pop(0)
    return str(PurePosixPath(*parts))


def load_json(payload: bytes, context: str) -> dict[str, Any]:
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{context} is not valid JSON ({error})") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{context} must contain a JSON object")
    return value


def validate_archive(archive_path: Path, required_references: set[str]) -> None:
    try:
        archive = tarfile.open(archive_path, "r:*")
    except (OSError, tarfile.TarError) as error:
        raise ValidationError(f"archive is unreadable ({error})") from error

    with archive:
        members: dict[str, tarfile.TarInfo] = {}
        for member in archive.getmembers():
            name = normalized_member_name(member.name)
            if name in {".", ""} or member.isdir():
                continue
            if name in members:
                raise ValidationError(f"archive contains duplicate member: {name}")
            if not member.isfile():
                raise ValidationError(f"archive member is not a regular file: {name}")
            members[name] = member

        def read_member(name: str) -> bytes:
            member = members.get(name)
            if member is None:
                raise ValidationError(f"archive is missing required member: {name}")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValidationError(f"archive member is unreadable: {name}")
            return stream.read()

        layout = load_json(read_member("oci-layout"), "oci-layout")
        if layout.get("imageLayoutVersion") != "1.0.0":
            raise ValidationError("oci-layout imageLayoutVersion must be 1.0.0")

        index = load_json(read_member("index.json"), "index.json")
        if index.get("schemaVersion") != 2:
            raise ValidationError("index.json schemaVersion must be 2")
        root_manifests = index.get("manifests")
        if not isinstance(root_manifests, list):
            raise ValidationError("index.json manifests must be an array")

        validated: dict[tuple[str, str], bool] = {}

        def descriptor_payload(descriptor: Any, context: str) -> tuple[bytes, str, str]:
            if not isinstance(descriptor, dict):
                raise ValidationError(f"{context} descriptor must be an object")
            digest = descriptor.get("digest")
            size = descriptor.get("size")
            media_type = descriptor.get("mediaType")
            if not isinstance(digest, str) or DIGEST_PATTERN.fullmatch(digest) is None:
                raise ValidationError(f"{context} has an invalid digest: {digest!r}")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                raise ValidationError(f"{context} has an invalid size: {size!r}")
            if not isinstance(media_type, str) or not media_type:
                raise ValidationError(f"{context} has no mediaType")
            algorithm, encoded = digest.split(":", 1)
            try:
                hasher = hashlib.new(algorithm)
            except ValueError as error:
                raise ValidationError(
                    f"{context} uses unsupported digest algorithm: {algorithm}"
                ) from error
            member_name = f"blobs/{algorithm}/{encoded}"
            member = members.get(member_name)
            if member is None:
                raise ValidationError(
                    f"archive is missing required member: {member_name}"
                )
            stream = archive.extractfile(member)
            if stream is None:
                raise ValidationError(f"archive member is unreadable: {member_name}")
            retain_payload = media_type in (
                INDEX_MEDIA_TYPES | MANIFEST_MEDIA_TYPES | {ARTIFACT_MEDIA_TYPE}
            )
            chunks: list[bytes] = []
            actual_size = 0
            while chunk := stream.read(1024 * 1024):
                actual_size += len(chunk)
                hasher.update(chunk)
                if retain_payload:
                    chunks.append(chunk)
            if actual_size != size:
                raise ValidationError(
                    f"{context} size mismatch for {digest}: expected {size}, got {actual_size}"
                )
            if hasher.hexdigest() != encoded:
                raise ValidationError(f"{context} digest mismatch for {digest}")
            return b"".join(chunks), media_type, digest

        def validate_descriptor(descriptor: Any, context: str) -> bool:
            payload, media_type, digest = descriptor_payload(descriptor, context)
            cache_key = (digest, media_type)
            if cache_key in validated:
                return validated[cache_key]

            if media_type in INDEX_MEDIA_TYPES:
                nested = load_json(payload, f"{context} {digest}")
                if nested.get("schemaVersion") != 2:
                    raise ValidationError(f"{context} {digest} schemaVersion must be 2")
                manifests = nested.get("manifests")
                if not isinstance(manifests, list):
                    raise ValidationError(f"{context} {digest} manifests must be an array")
                contains_image = False
                for position, child in enumerate(manifests):
                    contains_image = (
                        validate_descriptor(child, f"{context}.manifests[{position}]")
                        or contains_image
                    )
                subject = nested.get("subject")
                if subject is not None:
                    subject_media_type = (
                        subject.get("mediaType") if isinstance(subject, dict) else None
                    )
                    if subject_media_type in (
                        INDEX_MEDIA_TYPES | MANIFEST_MEDIA_TYPES | {ARTIFACT_MEDIA_TYPE}
                    ):
                        validate_descriptor(subject, f"{context}.subject")
                    else:
                        descriptor_payload(subject, f"{context}.subject")
                validated[cache_key] = contains_image
                return contains_image

            if media_type in MANIFEST_MEDIA_TYPES:
                manifest = load_json(payload, f"{context} {digest}")
                if manifest.get("schemaVersion") != 2:
                    raise ValidationError(f"{context} {digest} schemaVersion must be 2")
                descriptor_payload(manifest.get("config"), f"{context}.config")
                layers = manifest.get("layers")
                if not isinstance(layers, list):
                    raise ValidationError(f"{context} {digest} layers must be an array")
                for position, layer in enumerate(layers):
                    descriptor_payload(layer, f"{context}.layers[{position}]")
                subject = manifest.get("subject")
                if subject is not None:
                    subject_media_type = (
                        subject.get("mediaType") if isinstance(subject, dict) else None
                    )
                    if subject_media_type in (
                        INDEX_MEDIA_TYPES | MANIFEST_MEDIA_TYPES | {ARTIFACT_MEDIA_TYPE}
                    ):
                        validate_descriptor(subject, f"{context}.subject")
                    else:
                        descriptor_payload(subject, f"{context}.subject")
                validated[cache_key] = True
                return True

            if media_type == ARTIFACT_MEDIA_TYPE:
                manifest = load_json(payload, f"{context} {digest}")
                blobs = manifest.get("blobs")
                if not isinstance(blobs, list):
                    raise ValidationError(f"{context} {digest} blobs must be an array")
                for position, blob in enumerate(blobs):
                    descriptor_payload(blob, f"{context}.blobs[{position}]")
                subject = manifest.get("subject")
                if subject is not None:
                    subject_media_type = (
                        subject.get("mediaType") if isinstance(subject, dict) else None
                    )
                    if subject_media_type in (
                        INDEX_MEDIA_TYPES | MANIFEST_MEDIA_TYPES | {ARTIFACT_MEDIA_TYPE}
                    ):
                        validate_descriptor(subject, f"{context}.subject")
                    else:
                        descriptor_payload(subject, f"{context}.subject")
                validated[cache_key] = False
                return False

            raise ValidationError(
                f"{context} uses unsupported manifest mediaType: {media_type}"
            )

        available: dict[str, str] = {}
        for position, manifest in enumerate(root_manifests):
            contains_image = validate_descriptor(
                manifest, f"index.json.manifests[{position}]"
            )
            if not isinstance(manifest, dict):
                continue
            annotations = manifest.get("annotations", {})
            if not isinstance(annotations, dict):
                raise ValidationError(
                    f"index.json.manifests[{position}] annotations must be an object"
                )
            reference = annotations.get("org.opencontainers.image.ref.name")
            digest = manifest.get("digest")
            if isinstance(reference, str) and contains_image:
                if reference in available and available[reference] != digest:
                    raise ValidationError(
                        f"required reference is ambiguous: {reference}"
                    )
                available[reference] = digest

        missing = sorted(required_references - available.keys())
        if missing:
            raise ValidationError(
                "archive is missing required reference(s): " + ", ".join(missing)
            )
        required_digests = {available[reference] for reference in required_references}
        if len(required_digests) > 1:
            raise ValidationError(
                "archive required references do not resolve to one digest: "
                + ", ".join(
                    f"{reference}={available[reference]}"
                    for reference in sorted(required_references)
                )
            )


def main(arguments: list[str]) -> int:
    if len(arguments) < 2:
        print(
            f"usage: {Path(arguments[0]).name} OCI_ARCHIVE [REQUIRED_REFERENCE ...]",
            file=sys.stderr,
        )
        return 2
    archive = Path(arguments[1])
    try:
        validate_archive(archive, set(arguments[2:]))
    except ValidationError as error:
        print(
            f"container runtime init-image archive is not a complete OCI archive: "
            f"{archive} ({error})",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
