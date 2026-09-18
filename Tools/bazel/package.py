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

"""Validate declared native products and write unsigned candidate provenance."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct


PRODUCTS = {
    "compose": "darwin-arm64",
    "compose-normalizer": "darwin-arm64",
    "compose-volume-initializer-linux-arm64": "linux-arm64",
    "compose-volume-initializer-linux-amd64": "linux-amd64",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_binary(path: Path, platform: str) -> None:
    """Reject wrong architectures and dynamically linked guest initializers."""
    with path.open("rb") as stream:
        header = stream.read(64)
        if platform == "darwin-arm64":
            if header[:8] != struct.pack("<II", 0xFEEDFACF, 0x0100000C):
                raise ValueError("Expected a thin arm64 Mach-O product")
            return
        machine = {"linux-arm64": 183, "linux-amd64": 62}[platform]
        if (len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01"
                or struct.unpack_from("<HH", header, 16) != (2, machine)):
            raise ValueError("Expected a static ELF executable for the declared architecture")
        offset = struct.unpack_from("<Q", header, 32)[0]
        size, count = struct.unpack_from("<HH", header, 54)
        if size != 56 or count < 1 or count > 1024 or offset < 64:
            raise ValueError("Invalid ELF program header inventory")
        stream.seek(offset)
        for _ in range(count):
            record = stream.read(size)
            if len(record) != size or struct.unpack_from("<I", record)[0] in {2, 3}:
                raise ValueError("Guest initializer is truncated or dynamically linked")


def dependency(pins: list[dict], name: str, profile: str) -> tuple[str, str]:
    """Use only the selected immutable lock; never discover installed runtimes."""
    matches = [pin for pin in pins if pin["identity"] == name]
    if len(matches) != 1:
        raise ValueError("Missing or duplicate runtime dependency")
    pin = matches[0]
    source = re.fullmatch(r"https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git", pin["location"])
    revision = pin["state"]["revision"]
    if not source or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Runtime dependency must have a GitHub source and immutable revision")
    if profile == "stock" and source[1] != "apple/" + name:
        raise ValueError("Stock candidate must use unmodified Apple dependency pins")
    return source[1], revision


def metadata(manifest: dict, writer: Path) -> tuple[dict, dict]:
    """Reuse existing build-info semantics without invoking builds or signing."""
    if set(manifest["binaries"]) != set(PRODUCTS):
        raise ValueError("Candidate needs exactly four declared products")
    if manifest["profile"] not in {"stock", "enhanced"} or not re.fullmatch(r"[0-9a-f]{40}", manifest["commit"]):
        raise ValueError("Candidate requires a selected profile and full source commit")
    version = re.findall(r"^COMPOSE_VERSION\s*\?=\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$", Path(manifest["makefile"]).read_text(), re.M)
    go_version = re.findall(r"^\s*github.com/compose-spec/compose-go/v2\s+(v[0-9]+\.[0-9]+\.[0-9]+)\s*$", Path(manifest["go_mod"]).read_text(), re.M)
    if len(version) != 1 or len(go_version) != 1:
        raise ValueError("Missing unique project or compose-go version")
    pins = json.loads(Path(manifest["resolved"]).read_bytes())["pins"]
    container_source, container_ref = dependency(pins, "container", manifest["profile"])
    virtualization_source, virtualization_ref = dependency(pins, "containerization", manifest["profile"])
    capabilities, schema = [], 1
    if manifest["profile"] == "enhanced":
        spec = importlib.util.spec_from_file_location("compose_build_info", writer)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        schema, capabilities = module.load_runtime_capability_manifest(Path(manifest["capabilities"]))
    info = {
        "version": version[0], "source": "stephenlclarke/container-compose",
        "branch": "detached", "lane": "candidate", "commit": manifest["commit"],
        "buildType": "release", "containerSource": container_source, "containerRef": container_ref,
        "containerizationSource": virtualization_source, "containerizationRef": virtualization_ref,
        "composeGoVersion": go_version[0], "runtimeCapabilitySchemaVersion": schema,
        "runtimeCapabilities": capabilities,
    }
    products = {}
    for name, platform in PRODUCTS.items():
        path = Path(manifest["binaries"][name])
        validate_binary(path, platform)
        products[name] = sha256(path)
    identity = {
        "schemaVersion": 1, "kind": "unsigned-native-candidate", "productFamily": "container-compose",
        "version": version[0], "commit": manifest["commit"], "runtimeProfile": manifest["profile"],
        "architecture": "arm64", "compilationMode": "opt", "distributionReady": False,
        "licenseClosureComplete": False, "products": products,
        "dependencyLockSHA256": sha256(Path(manifest["resolved"])),
        "goModSHA256": sha256(Path(manifest["go_mod"])), "goSumSHA256": sha256(Path(manifest["go_sum"])),
    }
    return info, identity


def receipt(archive: Path, identity: dict) -> dict:
    """Seal exact archive bytes; a receipt is not Developer ID or release proof."""
    return {**identity, "archiveSHA256": sha256(archive), "archiveSize": archive.stat().st_size}


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("metadata")
    for name in ("manifest", "info", "identity", "writer"):
        build.add_argument(name, type=Path)
    seal = commands.add_parser("receipt")
    for name in ("archive", "identity", "output"):
        seal.add_argument(name, type=Path)
    args = parser.parse_args()
    if args.command == "metadata":
        info, identity = metadata(json.loads(args.manifest.read_bytes()), args.writer)
        write_json(args.info, info)
        write_json(args.identity, identity)
    else:
        write_json(args.output, receipt(args.archive, json.loads(args.identity.read_bytes())))


if __name__ == "__main__":
    main()

