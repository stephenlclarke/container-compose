#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Build a deterministic, cache-backed source companion for enhanced Compose.

This records technical source inventory and exact bytes. It does not determine
license sufficiency or create an approved closure manifest.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile

COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
PSL_SOURCE_SHA = "cad4acdfa1a74f77effc56558dd164381a79d5c3087bb59bdf8e8070aa4cf32a"
PSL_DATA_SHA = "76617b74fd10ee3cd654c185df63a447475c14d7cd65262232f7b33072a85045"
PSL_LICENSE_SHA = "63399014e51143c909e3b03065fe69393de2b167ef96fac84461b0266075921f"
COMPOSE_SOURCE_URL = "https://github.com/stephenlclarke/container-compose/releases/download/0.16.0/compose-source-companion.tar.gz"


class CompanionError(ValueError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def read_regular(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or path.resolve() != path:
        raise CompanionError(f"expected canonical regular file: {path}")
    return path.read_bytes()


def license_paths(value: object) -> list[str]:
    found: set[str] = set()
    def visit(item: object) -> None:
        if isinstance(item, dict):
            path = item.get("license_text")
            if isinstance(path, str):
                found.add(path)
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    return sorted(found)


def license_records(value: object) -> list[dict]:
    records = []
    def visit(item: object) -> None:
        if isinstance(item, dict):
            if isinstance(item.get("license_text"), str):
                records.append(item)
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    return records


def resolved_pins(path: Path) -> dict[str, dict]:
    value = json.loads(read_regular(path))
    pins = value.get("pins")
    if not isinstance(pins, list):
        raise CompanionError("Package.resolved pins are missing")
    result = {}
    for pin in pins:
        identity = pin.get("identity")
        state = pin.get("state")
        revision = state.get("revision") if isinstance(state, dict) else None
        if not isinstance(identity, str) or not isinstance(revision, str) or not COMMIT_RE.fullmatch(revision):
            raise CompanionError("Package.resolved contains an invalid pin")
        if identity in result:
            raise CompanionError("Package.resolved has duplicate package identities")
        result[identity] = pin
    return result


def safe_tree(root: Path) -> list[tuple[Path, str, str, int, str | None]]:
    """List a source tree without following links or accepting special files."""
    if root.is_symlink() or not root.is_dir() or root.resolve() != root:
        raise CompanionError(f"dependency root is missing or aliased: {root}")
    base = root.parent
    result = []
    total = 0
    for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current = Path(directory)
        dirs.sort()
        files.sort()
        kept_dirs = []
        for name in dirs:
            path = current / name
            rel = path.relative_to(base).as_posix()
            if path.is_symlink():
                target = os.readlink(path)
                if Path(target).is_absolute() or (path.parent / target).resolve().is_relative_to(root.resolve()) is False:
                    raise CompanionError(f"source symlink escapes its dependency root: {rel}")
                result.append((path, rel, "symlink", 0, target))
            else:
                kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            path = current / name
            rel = path.relative_to(base).as_posix()
            st = path.lstat()
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(path)
                if Path(target).is_absolute() or (path.parent / target).resolve().is_relative_to(root.resolve()) is False:
                    raise CompanionError(f"source symlink escapes its dependency root: {rel}")
                result.append((path, rel, "symlink", 0, target))
            elif stat.S_ISREG(st.st_mode):
                total += st.st_size
                if total > 2_000_000_000:
                    raise CompanionError("dependency source tree exceeds bounded archive size")
                result.append((path, rel, "file", stat.S_IMODE(st.st_mode), None))
            else:
                raise CompanionError(f"unsupported special file in source tree: {rel}")
            if len(result) > 100_000:
                raise CompanionError("dependency source tree exceeds bounded file count")
    return sorted(result, key=lambda item: item[1])


def legal_markers(data: bytes) -> list[str]:
    """Return plain-text markers for review triage, never an SPDX conclusion."""
    text = data[:262144].decode("utf-8", errors="replace")
    markers = []
    rules = (
        ("MPL-2.0-text-marker", r"Mozilla Public License(?:,| Version| version)\s*(?:version\s*)?2\.0"),
        ("GPL-2.0-text-marker", r"GNU GENERAL PUBLIC LICENSE\s+Version 2"),
        ("GPL-3.0-text-marker", r"GNU GENERAL PUBLIC LICENSE\s+Version 3"),
        ("LGPL-text-marker", r"GNU LESSER GENERAL PUBLIC LICENSE"),
        ("AGPL-text-marker", r"GNU AFFERO GENERAL PUBLIC LICENSE"),
        ("EPL-text-marker", r"Eclipse Public License"),
        ("CDDL-text-marker", r"Common Development and Distribution License"),
        ("Apache-2.0-text-marker", r"Apache License\s+Version 2\.0"),
        ("BSD-text-marker", r"BSD License|Redistribution and use in source and binary forms"),
        ("MIT-like-permission-marker", r"Permission is hereby granted, free of charge"),
    )
    for name, pattern in rules:
        if re.search(pattern, text, re.I):
            markers.append(name)
    return markers


def source_license_note(*, companion_sha: str | None = None, companion_bytes: int | None = None) -> bytes:
    note = (
        "Enhanced Container Compose dependency source companion\n"
        "=======================================================\n\n"
        "This sidecar preserves source trees selected by the enhanced candidate's Bazel license graph. "
        "It is an availability and provenance aid, not a legal sufficiency determination.\n\n"
        "MPL-covered transformed Public Suffix List in TLDExtractSwift 4.0.3\n"
        "--------------------------------------------------------------------\n"
        "The enhanced binary embeds transformed Public Suffix List rules in "
        "Sources/SPMPSL.swift and retains the corresponding frozen source data in "
        "Resources/public_suffix_list_frozen.dat. Both exact files are in the companion under "
        "sources/+dependencies+swiftpkg_tldextractswift/. They are associated with the Public "
        "Suffix List's Mozilla Public License 2.0 notice, reproduced in the generated "
        "THIRD-PARTY-NOTICES.txt and preserved with the package source. The package pin is "
        "5fb29b13f99b24401cd93c6c0c83faf7c23e9918; the MPL text is pinned to "
        "publicsuffix/list revision a179a48c465e818cfd8d626691cb317985da87fb at LICENSE. "
        "The TLDExtractSwift package's MIT license does not replace the MPL attribution for "
        "these transformed list files. The package does not record the original commit of the "
        "frozen list data, so this notice makes no guessed data-revision attribution.\n\n"
        "The companion includes complete selected Go, Swift, and Bazel external source roots, "
        "the repository's vendored patch and notice inventory, and the package lock and candidate "
        "notice evidence. Files identified in technical-review-evidence.json as unreferenced "
        "nested license candidates require review for applicability; their presence in the source "
        "bundle is not a classification or claim that each is linked into the product.\n"
    )
    if companion_sha is not None and companion_bytes is not None:
        note += (
            "\nSource availability\n"
            "-------------------\n"
            f"Download: {COMPOSE_SOURCE_URL}\n"
            f"SHA-256: {companion_sha}\n"
            f"Bytes: {companion_bytes}\n"
            "The digest and size identify the exact source companion bytes. This availability "
            "statement is not a legal sufficiency determination.\n"
        )
    return note.encode()


def build_companion(*, source_repo: Path, execroot: Path, bin_dir: Path,
                    output: Path) -> dict:
    source_repo = source_repo.resolve(strict=True)
    execroot = execroot.resolve(strict=True)
    bin_dir = bin_dir.resolve(strict=True)
    if not source_repo.is_dir() or not execroot.is_dir() or not bin_dir.is_dir():
        raise CompanionError("source, execroot or candidate output directory is unavailable")

    inputs = json.loads(read_regular(bin_dir / "candidate_archive_metadata.inputs.json"))
    identity = json.loads(read_regular(bin_dir / "candidate_archive.json"))
    if (inputs.get("profile") != "enhanced" or identity.get("runtimeProfile") != "enhanced"
            or inputs.get("commit") != identity.get("commit")
            or not COMMIT_RE.fullmatch(str(inputs.get("commit", "")))):
        raise CompanionError("candidate source identity is not the enhanced profile")
    commit = inputs["commit"]

    archive_path = bin_dir / "candidate_archive.tar.gz"
    archive_bytes = read_regular(archive_path)
    if sha(archive_bytes) != identity.get("archiveSHA256"):
        raise CompanionError("candidate archive differs from its metadata receipt")
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
        notice_member = archive.extractfile("compose/resources/THIRD-PARTY-NOTICES.txt")
        build_member = archive.extractfile("compose/resources/build-info.json")
        if notice_member is None or build_member is None:
            raise CompanionError("candidate archive is missing build or notice evidence")
        notices = notice_member.read()
        build_info = json.loads(build_member.read())
    if (sha(notices) != identity.get("dependencyNoticesSHA256")
            or build_info.get("commit") != commit or build_info.get("lane") != "candidate"):
        raise CompanionError("candidate notices or build identity differ")
    lock = execroot / "Package.resolved"
    if lock.is_symlink():
        source_lock = source_repo / "Package.resolved"
        if lock.resolve(strict=True) != source_lock.resolve(strict=True):
            raise CompanionError("Bazel Swift lock alias differs from source checkout")
        lock = source_lock
    if sha(read_regular(lock)) != identity.get("dependencyLockSHA256"):
        raise CompanionError("Swift dependency lock differs from candidate metadata")
    pins = resolved_pins(lock)

    go_mod = source_repo / inputs["go_mod"]
    go_sum = source_repo / inputs["go_sum"]
    go_inventory_path = source_repo / inputs["go_inventory"]
    go_inventory = json.loads(read_regular(go_inventory_path))
    rows = go_inventory.get("modules")
    if go_inventory.get("schemaVersion") != 1 or not isinstance(rows, list) or not rows:
        raise CompanionError("Go notice inventory is invalid")
    go_required = {row["module"]: row["version"] for row in rows}
    if len(go_required) != len(rows):
        raise CompanionError("Go notice inventory contains duplicate modules")
    declared = dict(re.findall(r"^\s*(\S+)\s+(v\S+)", read_regular(go_mod).decode(), re.M))
    if declared != go_required:
        raise CompanionError("Go notice inventory differs from go.mod")
    if (sha(read_regular(go_mod)) != identity.get("goModSHA256")
            or sha(read_regular(go_sum)) != identity.get("goSumSHA256")):
        raise CompanionError("Go lock inputs differ from candidate metadata")

    licenses_path = execroot / inputs["licenses"]
    license_inventory = json.loads(read_regular(licenses_path))
    records = license_records(license_inventory)
    paths = license_paths(license_inventory)
    if not paths:
        raise CompanionError("Bazel license metadata does not identify source roots")
    root_names = set()
    for value in paths:
        parsed = PurePosixPath(value)
        if (parsed.is_absolute() or ".." in parsed.parts or len(parsed.parts) < 3
                or parsed.parts[0] != "external"):
            raise CompanionError(f"unsafe or unrecognized license source path: {value}")
        root_name = parsed.parts[1]
        root = execroot / "external" / root_name
        source_file = root.joinpath(*parsed.parts[2:])
        try:
            resolved_root = root.resolve(strict=True)
            resolved_source = source_file.resolve(strict=True)
        except OSError as exc:
            raise CompanionError(f"license source is missing: {value}") from exc
        if (not resolved_root.is_dir() or not resolved_source.is_file()
                or not resolved_source.is_relative_to(resolved_root)):
            raise CompanionError(f"license source is missing or aliased: {value}")
        root_names.add(root_name)

    swift_roots = sorted(name for name in root_names if name.startswith("+dependencies+swiftpkg_"))
    go_roots = sorted(name for name in root_names if name.startswith("gazelle++go_deps+"))
    bazel_roots = sorted(root_names - set(swift_roots) - set(go_roots))
    expected_swift_count = identity.get("swiftNoticePackages")
    if len(swift_roots) != expected_swift_count:
        raise CompanionError("Swift source roots differ from notice package count")
    swift_identities = {name.removeprefix("+dependencies+swiftpkg_"): name for name in swift_roots}
    normalized_pins = {identity.replace("-", "_"): identity for identity in pins}
    if not set(swift_identities).issubset(normalized_pins):
        raise CompanionError("selected Swift source roots do not match Package.resolved pins")
    selected_pin_ids = {normalized_pins[name] for name in swift_identities}
    expected_go_roots = {"gazelle++go_deps+" + row["repo"] for row in rows}
    if set(go_roots) != expected_go_roots or len(go_roots) != identity.get("goNoticeModules"):
        raise CompanionError("selected Go source roots differ from notice inventory")
    observed_go = {}
    for row in records:
        path = row["license_text"]
        if path.startswith("external/gazelle++go_deps+"):
            root_name = path.split("/")[1]
            observed_go.setdefault(root_name, set()).add((row.get("package_name"), row.get("package_version")))
    for row in rows:
        root_name = "gazelle++go_deps+" + row["repo"]
        if observed_go.get(root_name) != {(row["module"], row["version"])}:
            raise CompanionError("Go source metadata differs from pinned module inventory")

    # Candidate inventory has explicit hashes for the modified MPL-covered PSL.
    psl_fragments = [row for row in identity.get("sourceNoticeFragments", [])
                     if row.get("component") == "tldextractswift-psl"]
    if len(psl_fragments) != 1:
        raise CompanionError("enhanced candidate lacks its Public Suffix List provenance row")
    psl_root = (execroot / "external" / "+dependencies+swiftpkg_tldextractswift").resolve(strict=True)
    psl_source = psl_root / "Sources/SPMPSL.swift"
    psl_data = psl_root / "Resources/public_suffix_list_frozen.dat"
    if (sha(read_regular(psl_source)) != PSL_SOURCE_SHA or sha(read_regular(psl_data)) != PSL_DATA_SHA
            or psl_fragments[0].get("sourceFileSHA256") != PSL_SOURCE_SHA
            or psl_fragments[0].get("dataSHA256") != PSL_DATA_SHA
            or psl_fragments[0].get("licenseSHA256") != PSL_LICENSE_SHA
            or psl_fragments[0].get("packageRevision") != pins["tldextractswift"]["state"]["revision"]
            or psl_fragments[0].get("sourceRevision") != pins["tldextractswift"]["state"]["revision"]):
        raise CompanionError("MPL-covered PSL source, data or notice differs from pinned candidate")

    source_roots = []
    cache_external = execroot.parent.parent / "external"
    for name in sorted(root_names):
        root = execroot / "external" / name
        if root.is_symlink():
            resolved = root.resolve(strict=True)
            expected = cache_external / name
            if not expected.exists() or resolved != expected.resolve(strict=True):
                raise CompanionError(f"Bazel external root points outside its matching cache: {name}")
        else:
            resolved = root
            if resolved.resolve(strict=True) != resolved:
                raise CompanionError(f"Bazel external root is aliased: {name}")
        source_roots.append((name, resolved))
    files = []
    for root_name, root in source_roots:
        tree = safe_tree(root)
        if not tree:
            raise CompanionError(f"selected dependency source root is empty: {root_name}")
        files.extend(tree)

    referenced = {}
    for value in paths:
        parts = PurePosixPath(value).parts
        referenced.setdefault(parts[1], set()).add("/".join(parts[2:]))
    legal_prefixes = ("license", "copying", "notice", "patents", "copyright")
    unreviewed_nested_legal_files = []
    for path, rel, kind, _, _ in files:
        relative_parts = PurePosixPath(rel).parts
        if kind != "file" or len(relative_parts) < 2:
            continue
        root_name, subpath = relative_parts[0], "/".join(relative_parts[1:])
        if (not Path(subpath).name.lower().startswith(legal_prefixes)
                or subpath in referenced.get(root_name, set())):
            continue
        data = read_regular(path)
        unreviewed_nested_legal_files.append({
            "path": rel,
            "sha256": sha(data),
            "bytes": len(data),
            "textMarkers": legal_markers(data),
            "status": "not selected by Bazel license metadata; applicability to shipped code is unreviewed",
        })

    support_files = {
        "provenance/Package.resolved": lock,
        "provenance/go.mod": go_mod,
        "provenance/go.sum": go_sum,
        "provenance/go-notice-inventory.json": go_inventory_path,
        "provenance/vendored-notice-inventory.json": source_repo / inputs["vendor_inventory"],
        "provenance/bazel-license-inventory.json": licenses_path,
        "provenance/MODULE.bazel.lock": source_repo / "MODULE.bazel.lock",
        "provenance/candidate-archive.json": bin_dir / "candidate_archive.json",
        "provenance/candidate-archive-inputs.json": bin_dir / "candidate_archive_metadata.inputs.json",
        "provenance/candidate-archive-notices.txt": None,
        "provenance/candidate-build-info.json": None,
        "provenance/SOURCE-LICENSES-AND-SOURCE-AVAILABILITY.md": None,
    }
    for vendor_notice in inputs["vendor_notices"]:
        path = Path(vendor_notice)
        if path.is_absolute() or ".." in path.parts:
            raise CompanionError("vendor notice path is unsafe")
        support_files["provenance/vendor-notices/" + path.name] = source_repo / path
    license_dir = source_repo / "Tools/bazel/licenses"
    if not license_dir.is_dir() or license_dir.is_symlink():
        raise CompanionError("repository vendored source and patch inventory is missing")
    for path in sorted(license_dir.iterdir()):
        if path.is_symlink() or not path.is_file():
            raise CompanionError("unsupported item in repository license inventory")
        support_files["provenance/repository-licenses/" + path.name] = path
    output = output.resolve()
    if output.exists() or not output.parent.is_dir():
        raise CompanionError("output must be a fresh directory under an existing parent")
    output.mkdir(mode=0o700)
    index_files = []
    companion_path = output / "source-companion.tar.gz"
    try:
        with companion_path.open("xb") as raw:
            with gzip.GzipFile(fileobj=raw, filename="", mode="wb", mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as archive:
                    for path, rel, kind, mode, target in files:
                        name = "sources/" + rel
                        entry = tarfile.TarInfo(name)
                        entry.uid = entry.gid = entry.mtime = 0
                        entry.uname = entry.gname = ""
                        if kind == "symlink":
                            entry.type = tarfile.SYMTYPE
                            entry.linkname = target or ""
                            entry.mode = 0o777
                            archive.addfile(entry)
                            encoded = (target or "").encode()
                            index_files.append({"path": name, "type": kind,
                                                "target": target, "sha256": sha(encoded), "bytes": 0})
                        else:
                            data = read_regular(path)
                            entry.type = tarfile.REGTYPE
                            entry.mode = mode
                            entry.size = len(data)
                            archive.addfile(entry, io.BytesIO(data))
                            index_files.append({"path": name, "type": kind, "sha256": sha(data),
                                                "bytes": len(data), "mode": mode})
                    for name, path in support_files.items():
                        if path is None:
                            if name.endswith("notices.txt"):
                                data = notices
                            elif name.endswith("build-info.json"):
                                data = canonical(build_info)
                            elif name.endswith(".md"):
                                data = source_license_note()
                            else:
                                raise CompanionError(f"unsupported generated provenance file: {name}")
                        else:
                            data = read_regular(path)
                        entry = tarfile.TarInfo(name)
                        entry.type = tarfile.REGTYPE
                        entry.mode = 0o644
                        entry.uid = entry.gid = entry.mtime = 0
                        entry.uname = entry.gname = ""
                        entry.size = len(data)
                        archive.addfile(entry, io.BytesIO(data))
                        index_files.append({"path": name, "type": "file", "sha256": sha(data),
                                            "bytes": len(data), "mode": 0o644})
            raw.flush()
            os.fsync(raw.fileno())
        bundle = read_regular(companion_path)
        root_pin = {}
        source_root_map = {name: root for name, root in source_roots}
        for pin_identity, package_pin in pins.items():
            root_pin["+dependencies+swiftpkg_" + pin_identity.replace("-", "_")] = {
                "kind": "swift-package", "identity": pin_identity,
                "revision": package_pin["state"]["revision"],
            }
        for row in rows:
            root_pin["gazelle++go_deps+" + row["repo"]] = {
                "kind": "go-module", "module": row["module"], "version": row["version"],
            }
        for root_name in bazel_roots:
            root_pin[root_name] = {
                "kind": "bazel-module", "moduleLockSHA256": sha(read_regular(source_repo / "MODULE.bazel.lock")),
            }
        nested_candidates = []
        for row in unreviewed_nested_legal_files:
            item = dict(row)
            root_name, _, rest = row["path"].partition("/")
            data = read_regular((source_root_map[root_name] / rest).resolve(strict=True))
            item["sourceRootBinding"] = root_pin[root_name]
            item["rawTextUTF8"] = data.decode("utf-8", errors="replace")
            nested_candidates.append(item)
        nested_review = {
            "schemaVersion": 1,
            "status": "technical-candidates-only; applicability to linked/shipped code is not determined",
            "sourceCommit": commit,
            "candidates": nested_candidates,
        }
        nested_review_bytes = canonical(nested_review)
        (output / "nested-legal-candidate-review.json").write_bytes(nested_review_bytes)
        evidence = {
            "schemaVersion": 1,
            "scope": "compose-enhanced-source-companion-inventory",
            "reviewStatus": "technical-inventory-only",
            "legalSufficiencyDetermined": False,
            "sourceCommit": commit,
            "runtimeProfile": "enhanced",
            "dependencyLockSHA256": identity["dependencyLockSHA256"],
            "dependencyNoticesSHA256": identity["dependencyNoticesSHA256"],
            "goModSHA256": identity["goModSHA256"],
            "goSumSHA256": identity["goSumSHA256"],
            "candidateArchiveSHA256": identity["archiveSHA256"],
            "sourceRoots": {
                "swift": swift_roots, "go": go_roots, "bazel": bazel_roots,
            },
            "swiftPins": [pins[name] for name in sorted(selected_pin_ids)],
            "unselectedPackageResolvedPins": [pins[name] for name in sorted(set(pins) - selected_pin_ids)],
            "goModules": rows,
            "unreviewedNestedLegalFileCandidateCount": len(unreviewed_nested_legal_files),
            "unreviewedNestedLegalFileCandidates": unreviewed_nested_legal_files,
            "nestedLegalCandidateReviewSHA256": sha(nested_review_bytes),
            "sourceFileCount": len(files),
            "companionFileCount": len(index_files),
            "companionBytes": len(bundle),
            "companionSHA256": sha(bundle),
            "publicSuffixList": {
                "packageRevision": "5fb29b13f99b24401cd93c6c0c83faf7c23e9918",
                "sourcePath": "sources/+dependencies+swiftpkg_tldextractswift/Sources/SPMPSL.swift",
                "sourceSHA256": PSL_SOURCE_SHA,
                "dataPath": "sources/+dependencies+swiftpkg_tldextractswift/Resources/public_suffix_list_frozen.dat",
                "dataSHA256": PSL_DATA_SHA,
                "licenseTextSHA256": PSL_LICENSE_SHA,
            },
        }
        index = {"schemaVersion": 1, **evidence, "files": index_files}
        (output / "source-index.json").write_bytes(canonical(index))
        (output / "technical-review-evidence.json").write_bytes(canonical(evidence))
        (output / "REVIEW-REQUIRED.md").write_text(
            "# Enhanced Compose source companion\n\n"
            "This bundle preserves complete pinned source trees for the dependency roots "
            "identified by the enhanced candidate's Bazel license graph, plus the exact "
            "Go/Swift lock and notice evidence. The inventory is technical evidence only; "
            "it is not a legal sufficiency determination or a completed release-closure review.\n\n"
            "In particular, the MPL-covered Public Suffix List transformation is represented "
            "by the exact pinned Sources/SPMPSL.swift and Resources/public_suffix_list_frozen.dat "
            "files and the already-generated MPL notice. Review must confirm the source-form "
            "distribution treatment and the full inventory before any finalizer closure manifest "
            "can be completed. Do not mark closure complete from text collection alone.\n")
        availability_notice = source_license_note(companion_sha=sha(bundle), companion_bytes=len(bundle))
        (output / "SOURCE-LICENSES-AND-SOURCE-AVAILABILITY.md").write_bytes(availability_notice)
        sidecars = {}
        for name in ("source-companion.tar.gz", "source-index.json", "technical-review-evidence.json",
                     "REVIEW-REQUIRED.md", "SOURCE-LICENSES-AND-SOURCE-AVAILABILITY.md",
                     "nested-legal-candidate-review.json"):
            data = (output / name).read_bytes()
            sidecars[name] = {"sha256": sha(data), "bytes": len(data)}
        closure_template = {
            "schemaVersion": 1,
            "scope": "reviewed-compose-legal-closure",
            "closureComplete": False,
            "reviewer": "",
            "reviewEvidence": "technical-review-evidence.json",
            "bindings": {
                "sourceCommit": commit,
                "runtimeProfile": "enhanced",
                "dependencyLockSHA256": identity["dependencyLockSHA256"],
                "dependencyNoticesSHA256": identity["dependencyNoticesSHA256"],
                "compiledSdkChain": None,
                "containerSource": build_info["containerSource"],
                "containerRef": build_info["containerRef"],
                "containerizationSource": build_info["containerizationSource"],
                "containerizationRef": build_info["containerizationRef"],
            },
            "files": sidecars,
            "requiredReview": "compiledSdkChain and reviewer must come from the admitted qualification; "
                             "closureComplete remains false until an independent sufficiency review is recorded.",
        }
        (output / "closure-review-template.json").write_bytes(canonical(closure_template))
        return evidence
    except BaseException:
        # Preserve incomplete output as evidence; callers must choose a new path.
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--execroot", type=Path, required=True, help="Bazel execroot/_main")
    parser.add_argument("--bin-dir", type=Path, required=True, help="candidate_archive output directory")
    parser.add_argument("--output", type=Path, required=True, help="new output directory")
    args = parser.parse_args()
    result = build_companion(source_repo=args.source_repo, execroot=args.execroot,
                             bin_dir=args.bin_dir, output=args.output)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
