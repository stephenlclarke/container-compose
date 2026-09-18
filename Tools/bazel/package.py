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


def go_notice_inventory(manifest: dict) -> tuple[list[dict], dict[str, str]]:
    """Bind reviewed notice modules and versions to the production Go lock."""
    inventory = json.loads(Path(manifest["go_inventory"]).read_text())
    rows = inventory["modules"]
    if inventory.get("schemaVersion") != 1 or not rows:
        raise ValueError("Invalid Go notice inventory")
    required = {row["module"]: row["version"] for row in rows}
    declared = dict(re.findall(r"^\s*(\S+)\s+(v\S+)", Path(manifest["go_mod"]).read_text(), re.M))
    if len(required) != len(rows) or required != declared:
        raise ValueError("Go notice inventory does not match go.mod")
    return rows, required


def source_notices(manifest: dict, required: dict[str, str]) -> tuple[dict, dict, set]:
    """Collect dependency-graph texts with stable, source-relative headings."""
    entries = [entry for group in json.loads(Path(manifest["licenses"]).read_text()) for entry in group["licenses"]]
    texts = {}
    found = {}
    swift = set()
    for entry in entries:
        path = Path(entry["license_text"])
        content = path.read_text()
        if not content.strip():
            raise ValueError("Empty dependency notice")
        name, version = entry["package_name"], entry["package_version"]
        if name in required:
            if version != required[name]:
                raise ValueError("Go notice version mismatch")
            found.setdefault(name, set()).add(path.name)
            label = name + "@" + version + "/" + path.name
        else:
            # rules_swift_package_manager names roots from immutable package
            # identities; retain the nested source-relative path in headings.
            match = re.search(r"swiftpkg_([^/]+)/(.+)$", path.as_posix())
            bazel = re.fullmatch(r"external/([A-Za-z0-9_.+-]+)/([^\x00]+)", path.as_posix())
            if match:
                swift.add(match[1])
                label = "Swift/" + match[1] + "/" + match[2]
            elif bazel and not bazel[1].startswith("gazelle++go_deps+"):
                # The aspect can also encounter Bazel modules (e.g. protobuf)
                # through Go's generated-code graph. Preserve their notices.
                label = "Bazel/" + bazel[1] + "/" + bazel[2]
            else:
                raise ValueError("Unrecognized dependency notice provenance")
        if label in texts and texts[label] != content:
            raise ValueError("Conflicting dependency notice")
        texts[label] = content
    return texts, found, swift


def vendored_notices(manifest: dict) -> tuple[dict, list[dict]]:
    """Bind reviewed vendor texts to immutable containing-package revisions."""
    inventory = json.loads(Path(manifest["vendor_inventory"]).read_text())
    rows = inventory["packages"]
    if inventory.get("schemaVersion") != 1 or set(rows) != {"swift-crypto", "swift-nio-ssl"}:
        raise ValueError("Invalid vendored notice inventory")
    pins = json.loads(Path(manifest["resolved"]).read_text())["pins"]
    sources = {Path(path).name: Path(path) for path in manifest["vendor_notices"]}
    expected = {row["license"] for row in rows.values()}
    if len(sources) != len(manifest["vendor_notices"]) or set(sources) != expected:
        raise ValueError("Missing or unexpected vendored notice inputs")
    texts, evidence = {}, []
    for identity, row in sorted(rows.items()):
        revisions = row["packageRevisions"]
        if (not isinstance(revisions, list) or not revisions or
                any(not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None for value in revisions) or
                len(set(revisions)) != len(revisions)):
            raise ValueError("Invalid vendored notice package revisions")
        selected = [pin for pin in pins if pin["identity"] == identity]
        if (len(selected) != 1 or selected[0]["kind"] != "remoteSourceControl" or
                selected[0]["location"] != row["repository"] or
                selected[0]["state"]["revision"] not in revisions):
            raise ValueError("Vendored notice package revision requires review")
        revision = row["revision"]
        if (row["vendor"] != "BoringSSL" or re.fullmatch(r"[0-9a-f]{40}", revision) is None or
                row["sourceURL"] != f"https://raw.githubusercontent.com/google/boringssl/{revision}/LICENSE" or
                row["license"] != f"boringssl-{revision}.txt"):
            raise ValueError("Invalid vendored notice provenance")
        path = sources[row["license"]]
        content = path.read_text()
        if not content.strip() or sha256(path) != row["sha256"]:
            raise ValueError("Vendored notice bytes differ from reviewed upstream text")
        label = "Swift/" + identity.replace("-", "_") + "/BoringSSL@" + revision + "/LICENSE"
        texts[label] = content
        evidence.append({"package": identity, "packageRevision": selected[0]["state"]["revision"],
                         "vendorRevision": revision, "sourceURL": row["sourceURL"], "licenseSHA256": row["sha256"]})
    return texts, evidence


def dependency_notices(manifest: dict) -> tuple[str, dict]:
    """Bundle declared notices; not legal approval or a vendored-source audit."""
    rows, required = go_notice_inventory(manifest)
    texts, found, swift = source_notices(manifest, required)
    for row in rows:
        names = row["notices"]
        if not names or len(names) != len(set(names)) or found.get(row["module"], set()) != set(names):
            raise ValueError("Missing or unexpected Go dependency notices")
    if not {"container", "containerization"}.issubset(swift):
        raise ValueError("Missing selected Swift runtime notices")
    vendor_texts, vendor_evidence = vendored_notices(manifest)
    texts.update(vendor_texts)
    sdk_version = re.findall(r"^go ([0-9]+\.[0-9]+\.[0-9]+)$", Path(manifest["go_mod"]).read_text(), re.M)
    sdk_files = [Path(path) for path in manifest["sdk_notices"]]
    if len(sdk_version) != 1 or len(sdk_files) != 2 or {path.name for path in sdk_files} != {"LICENSE", "PATENTS"}:
        raise ValueError("Missing Go SDK notice inventory")
    for path in sdk_files:
        content = path.read_text()
        if not content.strip():
            raise ValueError("Empty Go SDK notice")
        texts["Go SDK " + sdk_version[0] + "/" + path.name] = content
    text = "\n\n".join(label + "\n" + "=" * len(label) + "\n\n" + texts[label] for label in sorted(texts)) + "\n"
    return text, {"dependencyNoticesSHA256": hashlib.sha256(text.encode()).hexdigest(),
                  "goNoticeModules": len(required), "swiftNoticePackages": len(swift), "noticeTexts": len(texts),
                  "vendoredNotices": vendor_evidence}


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("metadata")
    for name in ("manifest", "info", "identity", "writer", "notices"):
        build.add_argument(name, type=Path)
    seal = commands.add_parser("receipt")
    for name in ("archive", "identity", "output"):
        seal.add_argument(name, type=Path)
    args = parser.parse_args()
    if args.command == "metadata":
        manifest = json.loads(args.manifest.read_bytes())
        info, identity = metadata(manifest, args.writer)
        notices, evidence = dependency_notices(manifest)
        identity.update(evidence)
        args.notices.write_text(notices)
        write_json(args.info, info)
        write_json(args.identity, identity)
    else:
        write_json(args.output, receipt(args.archive, json.loads(args.identity.read_bytes())))


if __name__ == "__main__":
    main()
