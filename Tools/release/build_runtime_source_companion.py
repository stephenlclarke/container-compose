#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Build a deterministic, cache-only source companion for the qualified Q runtime.

The inventory binds to retained qualification records and includes pinned project,
Swift package, Go module, and selected native build inputs. It records a source-
availability candidate, not a legal sufficiency determination.
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
import subprocess
import tarfile

SOURCE_COMMIT = "f86fea2236fab118c0e0c6f8be5eb7672df894e2"
RUNTIME_ARCHIVE_SHA = "d4a9bd8e9d332b0bfbf67fc5b0b3a99c977b66d6cc50f5954b36f3263a2cf696"
RUNTIME_PAYLOAD_SHA = "c41323b24aa7104017b05bd30801d238d2b66d5a3f3c8712e94822575749b28a"
SOURCE_URL = "https://github.com/stephenlclarke/container-compose/releases/download/0.16.0/container-runtime-source-companion.tar.gz"
LICENSE_PREFIXES = ("license", "copying", "notice", "patents", "copyright")


class InventoryError(ValueError):
    pass


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or path.resolve() != path:
        raise InventoryError(f"expected a canonical regular file: {path}")
    return path.read_bytes()


def go_module_cache_path(cache: Path, module: str, version: str) -> Path:
    """Map a locked Go module path to the escaped Go module-cache directory."""
    escaped = "/".join("".join("!" + ch.lower() if ch.isupper() else ch for ch in part)
                       for part in module.split("/"))
    return cache / f"{escaped}@{version}"


def source_names_from_archive(stream) -> list[str]:
    result = []
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or "\\" in member.name:
                raise InventoryError("source archive contains an unsafe path")
            result.append(member.name)
    return result


def package_source_root(repositories: Path, url: str, revision: str) -> Path:
    matches = []
    expected_url = url.removesuffix(".git")
    for path in sorted(repositories.iterdir()):
        if not path.is_dir():
            continue
        remote = subprocess.run(
            ["git", "-C", str(path), "config", "--get", "remote.origin.url"],
            capture_output=True, text=True, check=False,
        )
        if remote.returncode or remote.stdout.strip().removesuffix(".git") != expected_url:
            continue
        available = subprocess.run(
            ["git", "-C", str(path), "cat-file", "-e", revision + "^{tree}"],
            capture_output=True, check=False,
        )
        if available.returncode == 0:
            matches.append(path)
    if len(matches) != 1:
        raise InventoryError(f"expected one exact cached Swift source root for {url}@{revision}")
    return matches[0]


def safe_tree(root: Path) -> list[tuple[Path, str, int]]:
    if root.is_symlink() or not root.is_dir() or root.resolve() != root:
        raise InventoryError(f"source directory is missing or aliased: {root}")
    rows = []
    total = 0
    for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current = Path(directory)
        dirs.sort()
        for name in list(dirs):
            path = current / name
            if path.is_symlink():
                target = os.readlink(path)
                if Path(target).is_absolute() or not (path.parent / target).resolve().is_relative_to(root):
                    raise InventoryError("source tree has an escaping directory symlink")
                dirs.remove(name)
        for name in sorted(files):
            path = current / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                if Path(target).is_absolute() or not (path.parent / target).resolve().is_relative_to(root):
                    raise InventoryError("source tree has an escaping file symlink")
                continue
            if not stat.S_ISREG(mode):
                raise InventoryError("source tree contains a special file")
            size = path.stat().st_size
            total += size
            if total > 2_000_000_000 or len(rows) > 200_000:
                raise InventoryError("source tree exceeds bounded archive limits")
            rows.append((path, path.relative_to(root).as_posix(), stat.S_IMODE(mode)))
    return rows


def module_requirements(go_mod: str) -> list[tuple[str, str]]:
    rows = re.findall(r"^\s*([^\s]+)\s+(v[^\s]+)", go_mod, re.M)
    return sorted(set(rows))


def add_regular(archive: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        raise InventoryError("unsafe archive member name")
    info = tarfile.TarInfo(name)
    info.type = tarfile.REGTYPE
    info.size = len(data)
    info.mode = mode
    info.uid = info.gid = info.mtime = 0
    info.uname = info.gname = ""
    archive.addfile(info, io.BytesIO(data))


def add_git_archive(archive: tarfile.TarFile, repo: Path, revision: str, prefix: str,
                    *, git_dir: bool = False, license_rows: list[dict]) -> tuple[int, int]:
    command = ["git"]
    if git_dir:
        command.extend(["--git-dir", str(repo)])
    else:
        command.extend(["-C", str(repo)])
    command.extend(["archive", "--format=tar", revision])
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert process.stdout is not None
    try:
        source_archive = tarfile.open(fileobj=process.stdout, mode="r|")
    except tarfile.ReadError as error:
        if process.stdout:
            process.stdout.close()
        stderr = process.stderr.read() if process.stderr else b""
        result = process.wait()
        raise InventoryError(
            "pinned Git archive failed for " + str(repo) + " at " + revision
            + f" (exit {result}): " + stderr[:512].decode("utf-8", "replace")
        ) from error
    file_count = 0
    byte_count = 0
    with source_archive as source:
        for member in source:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts or "\\" in member.name:
                process.kill()
                raise InventoryError("pinned Git tree contains an unsafe path")
            output_name = prefix + "/" + member.name
            if member.isdir():
                continue
            if member.issym():
                target = PurePosixPath(member.linkname)
                depth = len(PurePosixPath(member.name).parent.parts)
                for component in target.parts:
                    if component in ("", "."):
                        continue
                    depth += -1 if component == ".." else 1
                    if depth < 0:
                        break
                if target.is_absolute() or depth < 0:
                    process.kill()
                    raise InventoryError("pinned Git tree contains an escaping symlink")
                info = tarfile.TarInfo(output_name)
                info.type = tarfile.SYMTYPE
                info.linkname = member.linkname
                info.mode = 0o777
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ""
                archive.addfile(info)
                continue
            stream = source.extractfile(member)
            if stream is None:
                raise InventoryError("pinned Git archive has an unreadable file")
            data = stream.read()
            add_regular(archive, output_name, data, member.mode & 0o777)
            file_count += 1
            byte_count += len(data)
            if PurePosixPath(member.name).name.lower().startswith(LICENSE_PREFIXES):
                license_rows.append({"path": output_name, "sha256": digest(data),
                                     "bytes": len(data), "rawTextUTF8": data.decode("utf-8", "replace")})
    stderr = process.stderr.read() if process.stderr else b""
    if process.stdout:
        process.stdout.close()
    if process.stderr:
        process.stderr.close()
    result = process.wait()
    if result:
        raise InventoryError("pinned Git archive failed: " + stderr[:512].decode("utf-8", "replace"))
    return file_count, byte_count


def gitlinks(repo: Path, revision: str) -> list[tuple[str, str]]:
    result = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", revision],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise InventoryError("cannot inspect pinned Git submodule links")
    rows = []
    for line in result.stdout.splitlines():
        metadata, path = line.split("\t", 1)
        mode, kind, object_id = metadata.split()
        if mode == "160000" and kind == "commit":
            rows.append((path, object_id))
    return rows


def add_gitlink_tree(archive: tarfile.TarFile, repo: Path, revision: str, prefix: str,
                     license_rows: list[dict], inventory: list[dict]) -> None:
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=False)
    if head.returncode or head.stdout.strip() != revision:
        raise InventoryError("gitlink source checkout does not match its pinned commit")
    count, size = add_git_archive(archive, repo, revision, prefix, license_rows=license_rows)
    inventory.append({"path": prefix, "commit": revision, "fileCount": count, "sourceBytes": size})
    for relative, commit in gitlinks(repo, revision):
        nested = repo / relative
        if nested.is_symlink() or not nested.is_dir():
            raise InventoryError("recursive gitlink source checkout is missing")
        add_gitlink_tree(archive, nested, commit, prefix + "/" + relative,
                         license_rows, inventory)


def build_runtime_companion(*, source_repo: Path, evidence_root: Path, compose_source_tar: Path,
                            go_module_cache: Path, aws_crt_submodule_root: Path,
                            output: Path) -> dict:
    source_repo = source_repo.resolve(strict=True)
    evidence_root = evidence_root.resolve(strict=True)
    repositories = source_repo / ".build/repositories"
    aws_crt_submodule_root = aws_crt_submodule_root.resolve(strict=True)
    if output.exists() or not output.parent.is_dir():
        raise InventoryError("output must be a fresh path under an existing directory")
    output.mkdir(mode=0o700)
    source_inputs_path = evidence_root / "release/source-inputs.json"
    artifact_path = evidence_root / "release/release-artifact.json"
    source_inputs = json.loads(regular(source_inputs_path))
    artifact = json.loads(regular(artifact_path))
    if (source_inputs.get("fork") != SOURCE_COMMIT
            or artifact.get("source") != SOURCE_COMMIT
            or artifact.get("archives", {}).get("container-homebrew-arm64.tar.gz") != RUNTIME_ARCHIVE_SHA):
        raise InventoryError("Q source or runtime archive differs from the retained qualification")
    pins = source_inputs.get("fork_pins")
    if not isinstance(pins, list) or len(pins) != 41:
        raise InventoryError("retained Q Swift lock does not have the expected 41 pins")
    lock_path = source_repo / "Package.resolved"
    if digest(regular(lock_path)) != source_inputs["build_inputs"]["Package.resolved"]:
        raise InventoryError("Q Package.resolved differs from retained build inputs")
    module_lock_path = source_repo / "MODULE.bazel.lock"
    if digest(regular(module_lock_path)) != source_inputs["build_inputs"]["MODULE.bazel.lock"]:
        raise InventoryError("Q Bazel lock differs from retained build inputs")

    runtime_payload = artifact["payload"]
    payload_sha = digest(canonical(runtime_payload))
    if payload_sha != RUNTIME_PAYLOAD_SHA:
        raise InventoryError("Q runtime payload canonical hash differs")

    aquery_path = evidence_root / "runtime-smoke/fork-release-native-aquery.json"
    aquery_bytes = regular(aquery_path)
    aquery, _ = json.JSONDecoder().raw_decode(aquery_bytes.decode("utf-8"))
    fragments = {row["id"]: row for row in aquery["pathFragments"]}
    def artifact_name(row: dict) -> str:
        pieces = []
        part = row["pathFragmentId"]
        while part:
            fragment = fragments[part]
            pieces.append(fragment["label"])
            part = fragment.get("parentId")
        return "/".join(reversed(pieces))
    aquery_roots = sorted({artifact_name(row).split("/")[1]
                           for row in aquery["artifacts"]
                           if artifact_name(row).startswith("external/")})
    compile_swift_roots = {name.removeprefix("+dependencies+") for name in aquery_roots
                           if name.startswith("+dependencies+swiftpkg_")}
    compile_go_roots = {name.removeprefix("gazelle++go_deps+") for name in aquery_roots
                        if name.startswith("gazelle++go_deps+")}

    q_go_modules = []
    go_modules = {}
    for module_dir in sorted((source_repo / "Tools").glob("*/go.mod")):
        if "Fixture" in module_dir.parent.name:
            continue
        go_mod = regular(module_dir).decode("utf-8")
        rows = module_requirements(go_mod)
        go_sum_path = module_dir.with_name("go.sum")
        q_go_modules.append({"service": module_dir.parent.name, "goModSHA256": digest(go_mod.encode()),
                             "goSumSHA256": digest(regular(go_sum_path)), "modules": rows})
        for module, version in rows:
            go_modules.setdefault((module, version), set()).add(module_dir.parent.name)
    go_module_reference_count = sum(len(service["modules"]) for service in q_go_modules)
    if len(go_modules) != 38 or go_module_reference_count != 47:
        raise InventoryError("shipped Go service graphs differ from the retained 47 references / 38 distinct-module inventory")
    go_rows = []
    go_roots_by_module = {}
    for (module, version), services in sorted(go_modules.items()):
        root = go_module_cache_path(go_module_cache, module, version)
        if not root.is_dir() or root.is_symlink():
            raise InventoryError(f"locked Go module source is unavailable: {module}@{version}")
        encoded = module.replace(".", "_").replace("/", "_").replace("-", "_")
        go_roots_by_module[module] = encoded
        go_rows.append({"module": module, "version": version,
                        "services": sorted(services), "cacheSourceAvailable": True,
                        "qAquerySourceRoot": encoded if encoded in compile_go_roots else None})

    # A single package source tar is generated as a nested deterministic stream.
    # Each project/dependency subtree remains namespaced by its exact source pin.
    source_tar = output / "runtime-source-companion.tar.gz"
    index_rows = []
    license_rows = []
    swift_rows = []
    swift_source_roots = {}
    gitlink_source_rows = []
    cache_root = source_repo / ".build/repositories"
    for pin in pins:
        identity = pin["identity"]
        revision = pin["state"]["revision"]
        url = pin["location"]
        if identity == "container":
            package_root = source_repo
        elif identity == "swift-protobuf":
            package_root = Path("<compose-source-companion-exact-pin>")
        else:
            package_root = package_source_root(cache_root, url, revision)
        swift_source_roots[identity] = package_root
        swift_rows.append({"identity": identity, "url": url, "revision": revision,
                           "aquerySourceInput": ("swiftpkg_" + identity.replace("-", "_")) in compile_swift_roots,
                           "sourceCache": "exact pinned source tree from retained SwiftPM cache"})
    with source_tar.open("xb") as raw:
        with gzip.GzipFile(fileobj=raw, filename="", mode="wb", mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as bundle:
                add_git_archive(bundle, source_repo, SOURCE_COMMIT, "runtime/project",
                                license_rows=license_rows)
                for row in swift_rows:
                    if row["identity"] == "container":
                        continue
                    if row["identity"] == "swift-protobuf":
                        with tarfile.open(compose_source_tar, "r:gz") as compose_archive:
                            prefix = "sources/+dependencies+swiftpkg_swift_protobuf/"
                            for member in compose_archive.getmembers():
                                if not member.name.startswith(prefix) or member.isdir():
                                    continue
                                source = compose_archive.extractfile(member)
                                if source is None:
                                    continue
                                data = source.read()
                                suffix = member.name.removeprefix(prefix)
                                add_regular(bundle, f"runtime/swift/{row['identity']}/{row['revision']}/{suffix}",
                                            data, member.mode & 0o777)
                                if PurePosixPath(suffix).name.lower().startswith(LICENSE_PREFIXES):
                                    license_rows.append({"path": f"runtime/swift/{row['identity']}/{row['revision']}/{suffix}",
                                        "sha256": digest(data), "bytes": len(data),
                                        "rawTextUTF8": data.decode("utf-8", "replace")})
                        continue
                    swift_repo = swift_source_roots[row["identity"]]
                    swift_prefix = f"runtime/swift/{row['identity']}/{row['revision']}"
                    add_git_archive(bundle, swift_repo, row["revision"],
                                    swift_prefix,
                                    git_dir=False, license_rows=license_rows)
                    links = gitlinks(swift_repo, row["revision"])
                    if links:
                        if row["identity"] != "aws-crt-swift":
                            raise InventoryError("an unreviewed pinned Swift package contains gitlinks")
                        if gitlinks(aws_crt_submodule_root, row["revision"]) != links:
                            raise InventoryError("AWS CRT submodule checkout has a different gitlink inventory")
                        for relative, commit in links:
                            nested = aws_crt_submodule_root / relative
                            if nested.is_symlink() or not nested.is_dir():
                                raise InventoryError("AWS CRT pinned submodule source is missing")
                            add_gitlink_tree(bundle, nested, commit, swift_prefix + "/" + relative,
                                             license_rows, gitlink_source_rows)
                for row in go_rows:
                    module, version = row["module"], row["version"]
                    root = go_module_cache_path(go_module_cache, module, version)
                    for path, relative, mode in safe_tree(root):
                        data = regular(path)
                        dest = f"runtime/go/{module}@{version}/{relative}"
                        add_regular(bundle, dest, data, mode)
                        if Path(relative).name.lower().startswith(LICENSE_PREFIXES):
                            license_rows.append({"path": dest, "sha256": digest(data), "bytes": len(data),
                                                 "rawTextUTF8": data.decode("utf-8", "replace")})
                # Preserve exact module/build/runtime metadata needed to identify the source graph.
                support = {
                    "provenance/source-inputs.json": regular(source_inputs_path),
                    "provenance/runtime-payload.json": canonical({
                        "sourceCommit": SOURCE_COMMIT,
                        "runtimeArchiveSHA256": RUNTIME_ARCHIVE_SHA,
                        "runtimePayloadSHA256": payload_sha,
                        "payload": runtime_payload,
                    }),
                    "provenance/Package.resolved": regular(lock_path),
                    "provenance/MODULE.bazel.lock": regular(module_lock_path),
                    "provenance/fork-release-native-aquery.json": aquery_bytes,
                }
                with tarfile.open(compose_source_tar, "r:gz") as compose_archive:
                    notice_member = compose_archive.extractfile(
                        "provenance/candidate-archive-notices.txt")
                    if notice_member is None:
                        raise InventoryError("Compose source companion lacks its complete notice inventory")
                    support["provenance/compose-dependency-notices.txt"] = notice_member.read()
                for module_dir in sorted((source_repo / "Tools").glob("*/go.mod")):
                    if "Fixture" in module_dir.parent.name:
                        continue
                    support[f"provenance/go-modules/{module_dir.parent.name}/go.mod"] = regular(module_dir)
                    support[f"provenance/go-modules/{module_dir.parent.name}/go.sum"] = regular(module_dir.with_name("go.sum"))
                support["provenance/locked-go-modules.json"] = canonical(go_rows)
                for name, data in support.items():
                    add_regular(bundle, name, data)
        raw.flush()
        os.fsync(raw.fileno())
    archive_bytes = regular(source_tar)
    archive_sha = digest(archive_bytes)

    source_manifest = {
        "schemaVersion": 1,
        "scope": "qualified-Q-runtime-source-availability-inventory",
        "reviewStatus": "technical-inventory-only",
        "legalSufficiencyDetermined": False,
        "sourceCommit": SOURCE_COMMIT,
        "runtimeArchiveSHA256": RUNTIME_ARCHIVE_SHA,
        "runtimePayloadSHA256": payload_sha,
        "sourceInputsSHA256": digest(regular(source_inputs_path)),
        "swiftPackagePinCount": len(swift_rows),
        "swiftPackagePins": swift_rows,
        "gitlinkSourceCount": len(gitlink_source_rows),
        "gitlinkSources": gitlink_source_rows,
        "swiftAqueryRootCount": len(compile_swift_roots),
        "goServiceCount": len(q_go_modules),
        "goModuleReferenceCount": go_module_reference_count,
        "goModuleVersionCount": len(go_rows),
        "goModules": go_rows,
        "goServices": q_go_modules,
        "nativeAqueryExternalRoots": aquery_roots,
        "nativeAqueryExternalRootCount": len(aquery_roots),
        "licenseTextCandidateCount": len(license_rows),
        "licenseTextCandidates": license_rows,
        "sourceCompanionSHA256": archive_sha,
        "sourceCompanionBytes": len(archive_bytes),
        "sourceAvailabilityNotice": "SOURCE-AVAILABILITY.md",
        "sourceAvailabilityURL": SOURCE_URL,
        "notes": [
            "Package.resolved pins not present in native aquery are reported as locked source inputs, not as linked product dependencies.",
            "All four Go service module graphs are included because their service images are distributed in the qualified runtime archive.",
            "Bazel toolchain roots are listed separately in nativeAqueryExternalRoots; this inventory does not assert that build tools ship in the runtime.",
            "License-like filenames and raw text are technical collection evidence only; classification and sufficiency require independent review.",
        ],
    }
    (output / "technical-review-evidence.json").write_bytes(canonical(source_manifest))
    (output / "license-candidate-review.json").write_bytes(canonical({
        "schemaVersion": 1, "status": "technical-candidates-only; applicability is not determined",
        "sourceCommit": SOURCE_COMMIT, "candidates": license_rows,
    }))
    (output / "SOURCE-AVAILABILITY.md").write_text(
        "# Q runtime source companion\n\n"
        "This companion contains the exact retained runtime source commit and package/module source inputs. "
        "Package lock entries absent from the native action graph are labeled as lock-only; their presence "
        "does not assert that they are linked into a shipped product. Source and license filename collection "
        "is technical evidence, not a legal sufficiency determination.\n\n"
        f"Download: {SOURCE_URL}\n"
        f"SHA-256: {archive_sha}\n"
        f"Bytes: {len(archive_bytes)}\n\n"
        f"Qualified runtime source: {SOURCE_COMMIT}\n"
        f"Qualified runtime archive SHA-256: {RUNTIME_ARCHIVE_SHA}\n"
        f"Qualified runtime payload SHA-256: {payload_sha}\n")
    return source_manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--compose-source-tar", type=Path, required=True)
    parser.add_argument("--aws-crt-submodule-root", type=Path, required=True)
    parser.add_argument("--go-module-cache", type=Path, default=Path.home() / "go/pkg/mod")
    parser.add_argument("--bazel-external", type=Path,
                        default=Path("/Volumes/SSD/cf/bazel/output/da06d6b57d27767e20a6674cda6c1a40/execroot/_main/external"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build_runtime_companion(source_repo=args.source_repo, evidence_root=args.evidence_root,
                                     compose_source_tar=args.compose_source_tar,
                                     go_module_cache=args.go_module_cache,
                                     aws_crt_submodule_root=args.aws_crt_submodule_root,
                                     output=args.output)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
