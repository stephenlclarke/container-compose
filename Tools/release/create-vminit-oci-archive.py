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

"""Create a deterministic OCI image-layout archive from a guest rootfs layer."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
from typing import BinaryIO


OCI_INDEX = "application/vnd.oci.image.index.v1+json"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
OCI_GZIP_LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"


def json_bytes(value: object) -> bytes:
    """Encode OCI JSON reproducibly without host-specific whitespace."""
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest_stream(stream: BinaryIO) -> str:
    """Return the sha256 digest of a stream without retaining it in memory."""
    digest = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def descriptor(payload: bytes, media_type: str) -> dict[str, object]:
    """Describe one in-memory OCI object."""
    return {
        "digest": f"sha256:{hashlib.sha256(payload).hexdigest()}",
        "mediaType": media_type,
        "size": len(payload),
    }


def add_bytes(archive: tarfile.TarFile, name: str, payload: bytes) -> None:
    """Add a regular file with stable metadata."""
    info = tarfile.TarInfo(name)
    info.mode = 0o644
    info.mtime = 0
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))


def add_directory(archive: tarfile.TarFile, name: str) -> None:
    """Add an extraction-friendly directory with stable metadata."""
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = 0
    archive.addfile(info)


def add_file(archive: tarfile.TarFile, name: str, path: Path) -> None:
    """Add a filesystem payload with stable metadata and streaming I/O."""
    info = tarfile.TarInfo(name)
    info.mode = 0o644
    info.mtime = 0
    info.size = path.stat().st_size
    with path.open("rb") as stream:
        archive.addfile(info, stream)


def create_archive(
    rootfs: Path, output: Path, references: list[str], source_url: str
) -> None:
    """Create a single-platform OCI archive addressable by every reference."""
    if not rootfs.is_file() or rootfs.is_symlink():
        raise ValueError(f"rootfs must be a regular, non-symlink file: {rootfs}")
    if rootfs.resolve() == output.resolve():
        raise ValueError("rootfs and output must be different files")
    if not references or any(not reference.strip() for reference in references):
        raise ValueError("at least one non-empty image reference is required")
    if len(set(references)) != len(references):
        raise ValueError("image references must be unique")

    with rootfs.open("rb") as compressed:
        if compressed.read(2) != b"\x1f\x8b":
            raise ValueError(f"rootfs is not a gzip-compressed tar layer: {rootfs}")
        compressed.seek(0)
        layer_digest = digest_stream(compressed)
    try:
        with tarfile.open(rootfs, "r:gz") as rootfs_archive:
            if not rootfs_archive.getmembers():
                raise ValueError(f"rootfs tar archive is empty: {rootfs}")
    except (OSError, EOFError, tarfile.TarError) as error:
        raise ValueError(f"rootfs is not a valid gzip-compressed tar: {rootfs}") from error

    layer_descriptor = {
        "digest": f"sha256:{layer_digest}",
        "mediaType": OCI_GZIP_LAYER,
        "size": rootfs.stat().st_size,
    }
    config = json_bytes(
        {
            "architecture": "arm64",
            "config": {"Labels": {"org.opencontainers.image.source": source_url}},
            "os": "linux",
            # Match Containerization's InitImage.create representation. Its
            # current loader records the compressed layer digest as diffID.
            "rootfs": {"diff_ids": [f"sha256:{layer_digest}"], "type": "layers"},
        }
    )
    config_descriptor = descriptor(config, OCI_CONFIG)
    manifest = json_bytes(
        {
            "config": config_descriptor,
            "layers": [layer_descriptor],
            "mediaType": OCI_MANIFEST,
            "schemaVersion": 2,
        }
    )
    manifest_descriptor = descriptor(manifest, OCI_MANIFEST)
    platform_index = json_bytes(
        {
            "manifests": [
                {
                    **manifest_descriptor,
                    "platform": {
                        "architecture": "arm64",
                        "os": "linux",
                        "variant": "v8",
                    },
                }
            ],
            "mediaType": OCI_INDEX,
            "schemaVersion": 2,
        }
    )
    platform_descriptor = descriptor(platform_index, OCI_INDEX)
    index = json_bytes(
        {
            "manifests": [
                {
                    **platform_descriptor,
                    "annotations": {
                        "com.apple.containerization.image.name": reference,
                        "io.containerd.image.name": reference,
                        "org.opencontainers.image.ref.name": reference,
                    },
                }
                for reference in references
            ],
            "mediaType": OCI_INDEX,
            "schemaVersion": 2,
        }
    )

    blobs = {
        config_descriptor["digest"].removeprefix("sha256:"): config,
        manifest_descriptor["digest"].removeprefix("sha256:"): manifest,
        platform_descriptor["digest"].removeprefix("sha256:"): platform_index,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.unlink(missing_ok=True)
    try:
        with tarfile.open(temporary, "w", format=tarfile.PAX_FORMAT) as archive:
            for directory in (".", "blobs", "blobs/sha256"):
                add_directory(archive, directory)
            add_bytes(archive, "oci-layout", json_bytes({"imageLayoutVersion": "1.0.0"}))
            for digest in sorted(blobs):
                add_bytes(archive, f"blobs/sha256/{digest}", blobs[digest])
            add_file(archive, f"blobs/sha256/{layer_digest}", rootfs)
            add_bytes(archive, "index.json", index)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", required=True, action="append", dest="references")
    parser.add_argument("--source-url", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        create_archive(
            arguments.rootfs,
            arguments.output,
            arguments.references,
            arguments.source_url,
        )
    except (OSError, ValueError, tarfile.TarError) as error:
        raise SystemExit(f"could not create VM-init OCI archive: {error}") from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
