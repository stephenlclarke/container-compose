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

"""Seal one configured SwiftPM package group as a compiled dependency layer.

This producer consumes one admitted source-mode Bazel build and its configured
output list. It refuses missing or conflicting binary variants. A development
proof from a dirty checkout is marked as such and cannot be published.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile

if __package__:
    from .argument_parser import command, digest, file_digest
else:
    from argument_parser import command, digest, file_digest

UPPER_PACKAGES = {"container", "containerization", "container-engine-api"}
BUILD_ONLY_PACKAGES = {"swift-docc-plugin", "swift-docc-symbolkit"}
PUBLISHED_LOWER = "swift-argument-parser"
GROUPS = ("foundation", "containerization", "engine-api", "container-sdk")
GROUP_PACKAGES = {"containerization": {"containerization"},
                  "engine-api": {"container-engine-api"}, "container-sdk": {"container"}}
GROUP_REPOSITORIES = {"foundation": "stephenlclarke/container-compose",
                      "containerization": "stephenlclarke/containerization",
                      "engine-api": "stephenlclarke/container-engine-api",
                      "container-sdk": "stephenlclarke/container"}
LOWERS = {"foundation": ("argument-parser",),
          "containerization": ("argument-parser", "foundation"),
          "engine-api": ("argument-parser", "foundation"),
          "container-sdk": ("argument-parser", "foundation", "containerization", "engine-api")}
IMPLEMENTATION_EXTENSIONS = {".swift", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".s", ".S", ".asm"}
OUTPUT_SUFFIXES = (".swiftmodule", ".swiftdoc", ".a", ".lo")
REPOSITORY_PREFIX = "+dependencies+swiftpkg_"
SHA = re.compile(r"[0-9a-f]{64}\Z")


def source_records(root: Path, profile: str = "enhanced") -> dict[str, dict]:
    if profile not in {"enhanced", "stock"}:
        raise ValueError("foundation profile must be enhanced or stock")
    selected = "Package.resolved" if profile == "enhanced" else "Package.stock.resolved"
    rows = json.loads((root / selected).read_text())["pins"]
    records = {row["identity"]: {"revision": row["state"]["revision"],
                                  "location": row["location"]} for row in rows}
    if (len(records) != len(rows) or
            any(not re.fullmatch(r"[0-9a-f]{40}", item["revision"]) or
                not isinstance(item["location"], str) or not item["location"]
                for item in records.values())):
        raise ValueError("resolved dependency source pins are incomplete")
    return records


def source_pins(root: Path, profile: str = "enhanced") -> dict[str, str]:
    return {name: item["revision"] for name, item in source_records(root, profile).items()}


def foundation_pins(pins: dict[str, str]) -> dict[str, str]:
    return {name: revision for name, revision in pins.items()
            if name not in UPPER_PACKAGES | BUILD_ONLY_PACKAGES | {PUBLISHED_LOWER}}


def group_pins(pins: dict[str, str], group: str) -> dict[str, str]:
    if group == "foundation":
        return foundation_pins(pins)
    if group not in GROUP_PACKAGES:
        raise ValueError("unsupported Swift package layer group")
    return {name: pins[name] for name in GROUP_PACKAGES[group]}


def recipe_identity(root: Path, profile: str = "enhanced", group: str = "foundation") -> dict[str, str]:
    semantic_build_lines = []
    operational = ("build --jobs=", "build --local_resources=", "build --experimental_disk_cache_gc_",
                   "build --symlink_prefix=", "build --action_env=TMPDIR")
    for raw in (root / ".bazelrc").read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(("test ", "coverage ")):
            continue
        if line.startswith(operational) or line.startswith(("build:asan ", "build:tsan ", "common:prebuilt-")):
            continue
        if line.startswith(("common ", "build ", f"common:{profile} ", f"build:{profile} ", "build:release ")):
            semantic_build_lines.append(line)
    if not semantic_build_lines or not any("--macos_minimum_os=" in line for line in semantic_build_lines):
        raise ValueError("Bazel release configuration identity is incomplete")
    module_lock = json.loads((root / "MODULE.bazel.lock").read_text())
    # Bazel's local facts and extension evaluation metadata can change when a
    # later data-only release lock is added. Registry hashes and resolved
    # external module extensions still bind the compiler/build-rule graph.
    module_rules = {key: module_lock[key] for key in
                    ("lockFileVersion", "registryFileHashes", "selectedYankedVersions")}
    module_rules["moduleExtensions"] = {key: value for key, value in module_lock["moduleExtensions"].items()
                                        if "%local_git_ext" not in key}
    result = {"producer": file_digest(root / "Tools/bazel/artifacts/foundation.py"),
              "importer": file_digest(root / "Tools/bazel/artifacts/foundation_import.bzl"),
              "configuredOutputs": file_digest(root / "Tools/bazel/artifacts/compiled_outputs.bzl"),
              "launcher": file_digest(root / "Tools/bazel/run.py"),
              "sourceIdentity": file_digest(root / "Tools/bazel/input_identity.py"),
              "rootBuild": file_digest(root / "BUILD.bazel"),
              "swiftPackageManifest": file_digest(root / "Package.swift"),
              "bazelConfiguration": digest(("\n".join(semantic_build_lines) + "\n").encode()),
              "moduleGraph": file_digest(root / "MODULE.bazel"),
              "moduleRules": digest(json.dumps(module_rules, sort_keys=True, separators=(",", ":")).encode()),
              "dependencyExtension": file_digest(root / "Tools/bazel/dependencies.bzl")}
    if profile == "enhanced" and group == "foundation":
        result["zstdPatch"] = file_digest(root / "Tools/bazel/zstd-public-module.patch")
    if profile == "enhanced" and group == "containerization":
        result["containerizationPatch"] = file_digest(root / "Tools/bazel/containerization-ext4-unaligned.patch")
    return result


def repo_name(identity: str) -> str:
    return "swiftpkg_" + identity.replace("-", "_").replace(".", "_")


def layer_lock_path(root: Path, group: str, profile: str) -> Path:
    if group not in GROUPS or profile not in {"enhanced", "stock"}:
        raise ValueError("unknown package layer lock")
    return root / "Tools/bazel/artifacts/layer-locks" / f"{group}-{profile}.json"


def lower_records(root: Path, profile: str, group: str,
                  argument_parser_lock: Path | None = None) -> dict[str, dict]:
    selected = source_pins(root, profile)
    records = {}
    for lower in LOWERS[group]:
        if lower == "argument-parser":
            path = argument_parser_lock or root / "Tools/bazel/artifacts/argument-parser.lock.json"
        else:
            path = layer_lock_path(root, lower, profile)
        lock = json.loads(path.read_text())
        archive = lock.get("archiveSHA256", "")
        if not SHA.fullmatch(archive):
            raise ValueError(f"lower {lower} archive has no exact digest")
        if lower == "argument-parser":
            if lock.get("manifest", {}).get("sourceCommit") != selected[PUBLISHED_LOWER]:
                raise ValueError("published ArgumentParser pin differs from profile lock")
        elif lock.get("group") != lower or lock.get("profile") != profile:
            raise ValueError(f"lower {lower} has wrong group or profile")
        if (lock.get("developmentProof") is True or not isinstance(lock.get("tag"), str)
                or not SHA.fullmatch(lock.get("evidenceSHA256", ""))):
            raise ValueError(f"lower {lower} must be a published, qualified binary layer")
        records[lower] = {"archiveSHA256": archive,
                          "tag": lock.get("tag"),
                          "evidenceSHA256": lock.get("evidenceSHA256")}
    return records


def transformed_build(original: str) -> str:
    swift = 'load("@build_bazel_rules_swift//swift:swift.bzl"'
    cc = 'load("@rules_cc//cc:defs.bzl"'
    lines = []
    for line in original.splitlines():
        if line.startswith(swift):
            line = line.replace('"swift_library", ', '').replace(', "swift_library"', '')
            line = line.replace(', "swift_library")', ')')
        if line.startswith(cc):
            line = line.replace('"cc_library", ', '').replace(', "cc_library"', '')
            line = line.replace(', "cc_library")', ')')
        if line.startswith((swift, cc)) and ('"swift_library"' in line or '"cc_library"' in line):
            raise ValueError("could not replace a source compiler rule")
        if line.startswith((swift, cc)) and line.endswith('.bzl")'):
            continue
        lines.append(line)
    transformed = ('load(":prebuilt.bzl", swift_library = "foundation_swift_library", '
                   'cc_library = "foundation_cc_library")\n' + "\n".join(lines) + "\n")
    if re.search(r'^load\([^\n]*"(?:swift_library|cc_library)"', transformed[transformed.index("\n") + 1:], re.M):
        raise ValueError("a generated package still loads a source compiler rule")
    return transformed


def rule_modules(build: str) -> dict[str, str]:
    modules = {}
    for block in re.findall(r"^swift_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        module = re.search(r'^    module_name = "([^"]+)"', block, re.M)
        if name and module:
            modules[name.group(1)] = module.group(1)
    return modules


def header_only_c_targets(build: str) -> set[str]:
    targets = set()
    for block in re.findall(r"^cc_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        if not name:
            continue
        srcs = re.search(r'^    srcs = (.*?)(?=^    [a-z_]+ = |^\)\n)', block, re.M | re.S)
        if not srcs:
            targets.add(name.group(1))
            continue
        value = srcs.group(1).strip().removesuffix(",").strip()
        if not re.fullmatch(r'\[\s*(?:"[^"]+"\s*,?\s*)*\]', value, re.S):
            continue
        paths = re.findall(r'"([^"]+)"', value)
        if all(Path(path).suffix in {".h", ".hpp", ".modulemap", ".inc", ".def"}
               for path in paths):
            targets.add(name.group(1))
    return targets


def compiled_c_header_sources(build: str, compiled: set[str]) -> dict[str, list[str]]:
    """Retain public headers originally declared in C srcs, never C implementations."""
    result = {}
    found = set()
    for block in re.findall(r"^cc_library\(\n.*?^\)\n", build, re.M | re.S):
        name = re.search(r'^    name = "([^"]+)"', block, re.M)
        if not name or name.group(1) not in compiled:
            continue
        target = name.group(1)
        found.add(target)
        srcs = re.search(r'^    srcs = (.*?)(?=^    [a-z_]+ = |^\)\n)', block, re.M | re.S)
        if srcs is None:
            result[target] = []
            continue
        value = srcs.group(1).strip().removesuffix(",").strip()
        if not re.fullmatch(r'\[\s*(?:"[^"]+"\s*,?\s*)*\]', value, re.S):
            raise ValueError(f"compiled C target has unsupported source expression: {target}")
        result[target] = [path for path in re.findall(r'"([^"]+)"', value)
                          if Path(path).suffix in {".h", ".hpp", ".inc", ".modulemap", ".def"}]
    if found != compiled:
        raise ValueError("compiled C target is absent from generated BUILD: " + ", ".join(sorted(compiled - found)))
    return result


def artifact_map(paths: list[str], execution_root: Path, output_base: Path,
                 allowed: dict[str, str]) -> tuple[dict[str, dict[str, bytes]], dict[str, dict]]:
    files: dict[str, dict[str, bytes]] = {name: {} for name in allowed}
    identities: dict[str, dict] = {name: {"swift": {}, "cc": {}} for name in allowed}
    output_base = output_base.resolve(strict=True)
    for line in paths:
        relative = Path(line.strip())
        if not relative.parts or relative.parts[0] != "bazel-out" or ".." in relative.parts:
            continue
        marker = next((part for part in relative.parts if part.startswith(REPOSITORY_PREFIX)), None)
        if marker is None:
            continue
        repository = marker.removeprefix("+dependencies+")
        if repository not in allowed:
            continue
        name = relative.name
        if not name.endswith(OUTPUT_SUFFIXES):
            continue
        if not (execution_root / relative).exists() and name.endswith(".swiftdoc"):
            continue
        candidate = (execution_root / relative).resolve(strict=True)
        if not candidate.is_file() or not candidate.is_relative_to(output_base):
            raise ValueError(f"configured output escaped Bazel output base: {line}")
        content = candidate.read_bytes()
        # Bazel's `.lo` output is an ar archive, but cc_import accepts only
        # `.a`/`.lib` labels. Keep its bytes and expose a conventional suffix.
        key = "binary/" + (name.removesuffix(".lo") + ".a" if name.endswith(".lo") else name)
        existing = files[repository].get(key)
        if existing is not None and existing != content:
            raise ValueError(f"one package has conflicting configured binary variants: {repository}/{name}")
        files[repository][key] = content
    for repository, members in files.items():
        archives = {name.removeprefix("binary/lib").removesuffix(".a"): name for name in members
                    if name.startswith("binary/lib") and name.endswith(".a")}
        identities[repository]["cc"] = {target: archive for target, archive in archives.items()
                                         if not target.endswith(".rspm.__impl")}
        identities[repository]["swift"] = {
            target: {"archive": archive,
                     "swiftmodule": "binary/" + module + ".swiftmodule",
                     "swiftdoc": "binary/" + module + ".swiftdoc"}
            for target, archive in archives.items() if target.endswith(".rspm.__impl")
            for module in [target.removesuffix(".rspm.__impl")]
        }
    return files, identities


def source_files_used_as_headers(build: str) -> set[str]:
    paths = set()
    for value in re.findall(r"\b(?:textual_hdrs|hdrs)\s*=\s*\[(.*?)\]", build, re.S):
        paths.update(re.findall(r'"([^"]+)"', value))
    return paths


def package_files(external: Path, build: str) -> dict[str, bytes]:
    members = {}
    textual_headers = source_files_used_as_headers(build)
    for path in sorted(external.rglob("*")):
        if path.is_dir():
            continue
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if not resolved.is_file() or not resolved.is_relative_to(external.resolve(strict=True)):
                raise ValueError(f"package metadata symlink leaves source tree: {path}")
        if not path.is_file():
            raise ValueError(f"unexpected package input type: {path}")
        relative = path.relative_to(external)
        if any(part.startswith(".git") for part in relative.parts):
            continue
        if relative.parts[0] in {"Tests", "Benchmarks", "Examples"}:
            continue
        if path.suffix in IMPLEMENTATION_EXTENSIONS and str(relative) not in textual_headers:
            continue
        if relative.name == "BUILD.bazel":
            continue
        members[str(relative)] = path.read_bytes()
    return members


def package_overlay(repository: str, source: Path, outputs: dict[str, bytes],
                    identity: dict) -> dict[str, bytes]:
    original = (source / "BUILD.bazel").read_text()
    modules = rule_modules(original)
    for target in list(identity["swift"]):
        if target not in modules:
            identity["cc"][target] = identity["swift"].pop(target)["archive"]
    for target, artifact in identity["swift"].items():
        module = modules.get(target)
        if not module:
            raise ValueError(f"compiled Swift target absent from generated BUILD: {repository}/{target}")
        artifact["swiftmodule"] = "binary/" + module + ".swiftmodule"
        artifact["swiftdoc"] = "binary/" + module + ".swiftdoc"
        if artifact["swiftdoc"] not in outputs:
            del artifact["swiftdoc"]
        if any(member not in outputs for member in artifact.values()):
            raise ValueError(f"compiled Swift target lacks an interface/archive: {repository}/{target}")
    if not identity["swift"] and not identity["cc"]:
        raise ValueError(f"package has no compiled binary output: {repository}")
    source_files = package_files(source, original)
    c_src_headers = compiled_c_header_sources(original, set(identity["cc"]))
    # Binary members supersede any source-tree file with the same name.
    if set(source_files) & set(outputs):
        raise ValueError(f"binary output collides with package metadata: {repository}")
    prebuilt = ('load("@//Tools/bazel/artifacts:foundation_import.bzl", '
                '"import_swift_library", "import_cc_library")\n'
                'SWIFT = ' + json.dumps(identity["swift"], sort_keys=True) + '\n'
                'C = ' + json.dumps(identity["cc"], sort_keys=True) + '\n'
                'C_HEADER_ONLY = ' + json.dumps(sorted(header_only_c_targets(original))) + '\n'
                'C_SRC_HEADERS = ' + json.dumps(c_src_headers, sort_keys=True) + '\n'
                'def foundation_swift_library(**kwargs):\n'
                '    import_swift_library(SWIFT, **kwargs)\n'
                'def foundation_cc_library(**kwargs):\n'
                '    import_cc_library(C, C_HEADER_ONLY, C_SRC_HEADERS, **kwargs)\n')
    return {**source_files, **outputs,
            "BUILD.bazel": transformed_build(original).encode(),
            "prebuilt.bzl": prebuilt.encode()}


def archive_bytes(members: dict[str, bytes], manifest: dict) -> bytes:
    group = manifest["group"]
    contents = {**members, group + "/layer.json":
                (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()}
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, content in sorted(contents.items()):
                info = tarfile.TarInfo(name)
                info.size, info.mtime, info.uid, info.gid = len(content), 0, 0, 0
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(content))
    return out.getvalue()


def inspect(path: Path, expected_sha: str | None = None) -> dict:
    raw = path.read_bytes()
    archive_sha = digest(raw)
    if expected_sha and archive_sha != expected_sha:
        raise ValueError("foundational archive checksum differs from lock")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        names = tar.getnames()
        if len(names) != len(set(names)) or any(not m.isfile() or m.issym() or m.islnk() for m in tar):
            raise ValueError("foundational archive has duplicate or non-file members")
        roots = {name.split("/", 1)[0] for name in names}
        if len(roots) != 1 or not roots.issubset(GROUPS) or any(".." in Path(n).parts for n in names):
            raise ValueError("foundational archive member escapes its package")
        contents = {name: tar.extractfile(name).read() for name in names}
    group = roots.pop()
    manifest = json.loads(contents.pop(group + "/layer.json"))
    if (manifest.get("schema") != 1 or manifest.get("group") != group
            or manifest.get("profile") not in {"enhanced", "stock"}):
        raise ValueError("foundational archive has the wrong profile")
    if set(contents) != set(manifest.get("files", {})):
        raise ValueError("foundational archive manifest is incomplete")
    for name, sha in manifest["files"].items():
        if not SHA.fullmatch(sha) or digest(contents[name]) != sha:
            raise ValueError(f"foundational archive member changed: {name}")
    return {"archiveSHA256": archive_sha, "manifest": manifest}


def proof_lock(receipt_path: Path, root: Path, output: Path) -> dict:
    receipt = json.loads(receipt_path.read_text())
    observed = inspect(Path(receipt["archive"]), receipt["archiveSHA256"])
    if observed["manifest"] != receipt["manifest"] or not observed["manifest"]["developmentProof"]:
        raise ValueError("development lock requires an actual proof archive")
    if output.exists():
        raise ValueError("proof lock already exists")
    profile = observed["manifest"]["profile"]
    manifest = observed["manifest"]
    group = manifest["group"]
    lock = {"schema": 1, "developmentProof": True, "group": group,
            "profile": profile, "archiveSHA256": observed["archiveSHA256"],
            "sourcePins": group_pins(source_pins(root, profile), group),
            "reachedSources": {name: {key: row[key] for key in ("sourceCommit", "sourceLocation", "repository")}
                               for name, row in manifest["packages"].items()},
            "lower": manifest["lower"], "toolchain": manifest["toolchain"],
            "recipeSHA256": manifest["recipeSHA256"]}
    output.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return lock


def _legacy_recipe_compatible(lock: dict, root: Path, profile: str, group: str,
                              current: dict[str, str]) -> bool:
    """Admit unchanged published groups across exact upper pin changes.

    The old producer bytes remain authenticated by the published lock. The
    canonical AST check proves this file changed only in this consumer check;
    production, import, archive sealing, and configuration logic are unchanged.
    """
    import ast

    old_container = b"15361ce5f55a6b8ab3242e89650a188766b47581"
    old_containerization = b"5ed9bc7490aa30c76337bd5b3d8ff251b63c678f"
    changed_container = b"4d82da2c571d0924bd97569249a5d200ca764a13"
    changed_containerization = b"6db16197bbad8196a78132f86529daa89125aafb"
    old_producer = "fc84c316dc42f7c978cadf8a89208bcf5f1984aeb270eab5276442cb494bb678"
    old_manifest = "459a721a03f96978259620ec8ab278c809e0fec182ed08a13f76cbe432e81ac1"
    old_resolved = "6bf3d07b02f5e6a03df82efa7a08c5103fc0f044096dd4a9a48ca3436945e6ad"
    old_producer_source = "9414f170ff95287d40ed0517af4a4e0307c065ce7a38332b253db1e49de0aeca"
    if not ((profile == "enhanced" and group in {"foundation", "containerization", "engine-api"})
            or (profile == "stock" and group in GROUPS)):
        return False
    historical = lock.get("recipeSHA256")
    if (lock.get("developmentProof") is not False or not isinstance(historical, dict)
            or set(historical) != set(current)
            or historical.get("producer") != old_producer
            or historical.get("swiftPackageManifest") != old_manifest
            or any(historical[key] != value for key, value in current.items()
                   if key not in {"producer", "swiftPackageManifest"})):
        return False

    source = (root / "Tools/bazel/artifacts/foundation.py").read_text()
    module = ast.parse(source)
    excluded = {"verify_consumer", "_legacy_recipe_compatible"}
    functions = [node for node in module.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
    definitions = {node.name: node for node in functions if node.name in excluded}
    verifier_defaults = definitions.get("verify_consumer").args.defaults if "verify_consumer" in definitions else []
    if (len(definitions) != len(excluded) or len(functions) != len({node.name for node in functions})
            or any(node.decorator_list for node in module.body
                   if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)))
            or definitions["_legacy_recipe_compatible"].args.defaults
            or any(value is not None for value in definitions["_legacy_recipe_compatible"].args.kw_defaults)
            or len(verifier_defaults) != 2
            or not all(isinstance(value, ast.Constant) for value in verifier_defaults)
            or [value.value for value in verifier_defaults] != ["enhanced", "foundation"]
            or any(value is not None for value in definitions["verify_consumer"].args.kw_defaults)):
        return False
    # ast.dump changes when a Python release adds AST fields. Bind exact
    # source bytes for each retained top-level production node instead.
    production = [(type(node).__name__, ast.get_source_segment(source, node))
                  for node in module.body
                  if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                  or node.name not in excluded]
    if (any(segment is None for _, segment in production)
            or digest(json.dumps(production, ensure_ascii=False,
                                 separators=(",", ":")).encode()) != old_producer_source):
        return False

    selected_pins = source_pins(root, "enhanced")
    selected = selected_pins.get("container", "").encode()
    selected_containerization = selected_pins.get("containerization", "").encode()
    manifest = (root / "Package.swift").read_bytes()
    resolved = (root / "Package.resolved").read_bytes()
    if (not re.fullmatch(rb"[0-9a-f]{40}", selected) or selected == old_container
            or manifest.count(selected) != 1 or resolved.count(selected) != 1
            or old_container in manifest or old_container in resolved):
        return False
    if selected_containerization == old_containerization:
        if manifest.count(old_containerization) != 1 or resolved.count(old_containerization) != 1:
            return False
    elif (selected == changed_container and selected_containerization == changed_containerization
          and ((profile == "enhanced" and group in {"foundation", "engine-api"})
               or (profile == "stock" and group in GROUPS))
          and manifest.count(selected_containerization) == 1
          and resolved.count(selected_containerization) == 1
          and old_containerization not in manifest and old_containerization not in resolved):
        manifest = manifest.replace(selected_containerization, old_containerization)
        resolved = resolved.replace(selected_containerization, old_containerization)
    else:
        return False
    return (digest(manifest.replace(selected, old_container)) == old_manifest
            and digest(resolved.replace(selected, old_container)) == old_resolved)


def verify_consumer(lock_path: Path, root: Path, mirror: Path | None,
                    environment: dict[str, str], profile: str = "enhanced",
                    group: str = "foundation") -> dict:
    lock = json.loads(lock_path.read_text())
    if (lock.get("schema") != 1 or not SHA.fullmatch(lock.get("archiveSHA256", ""))
            or lock.get("group") != group or lock.get("profile") != profile
            or lock.get("sourcePins") != group_pins(source_pins(root, profile), group)
            or lock.get("lower") != lower_records(root, profile, group)):
        raise ValueError("foundational bundle differs from enhanced source pins or lower layer")
    current_recipe = recipe_identity(root, profile, group)
    if (lock.get("recipeSHA256") != current_recipe
            and not _legacy_recipe_compatible(lock, root, profile, group, current_recipe)):
        raise ValueError("foundational bundle exporter, importer or source patch changed")
    packages = lock.get("reachedSources", {})
    records = source_records(root, profile)
    if (not isinstance(packages, dict) or not packages or
            any(name not in lock["sourcePins"] or row.get("sourceCommit") != lock["sourcePins"][name]
                or row.get("sourceLocation") != records[name]["location"]
                or row.get("repository") != repo_name(name) for name, row in packages.items())):
        raise ValueError("foundational bundle package inventory differs from locked sources")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("foundational bundle requires Apple silicon macOS")
    swiftc = Path(command("/usr/bin/xcrun", "-f", "swiftc", environment=environment))
    sdk = Path(command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path", environment=environment))
    tools = lock.get("toolchain", {})
    if (tools.get("swiftcSHA256") != file_digest(swiftc)
            or tools.get("sdkSettingsSHA256") != file_digest(sdk / "SDKSettings.json")
            or tools.get("sdkVersion") != command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version",
                                                    environment=environment)
            or tools.get("xcodeVersion") != command("/usr/bin/xcodebuild", "-version", environment=environment)
            or tools.get("bazelVersion") != (root / ".bazelversion").read_text().strip()):
        raise ValueError("foundational bundle compiler, SDK, Xcode or Bazel differs from producer")
    if lock.get("developmentProof") and mirror is None:
        raise ValueError("development bundle requires an explicit local mirror")
    if not lock.get("developmentProof"):
        expected_tag = f"layer-{group}-{profile}-{lock['archiveSHA256'][:20]}"
        if (lock.get("repository") != GROUP_REPOSITORIES[group] or
                lock.get("tag") != expected_tag or
                not re.fullmatch(r"[0-9a-f]{40}", lock.get("targetCommit", "")) or
                not re.fullmatch(r"[0-9a-f]{40}", lock.get("producerCommit", "")) or
                (group != "foundation" and
                 lock["targetCommit"] != lock["sourcePins"][next(iter(GROUP_PACKAGES[group]))]) or
                not isinstance(lock.get("asset"), str) or not lock["asset"].endswith(".tar.gz") or
                not isinstance(lock.get("evidenceAsset"), str) or
                not SHA.fullmatch(lock.get("evidenceSHA256", ""))):
            raise ValueError("published package layer lacks exact release and sidecar identity")
    if mirror is not None:
        if not mirror.is_absolute() or mirror.is_symlink() or not mirror.is_file():
            raise ValueError("foundational bundle mirror must be an absolute regular file")
        observed = inspect(mirror, lock["archiveSHA256"])
        manifest = observed["manifest"]
        reached = {name: {key: row[key] for key in ("sourceCommit", "sourceLocation", "repository")}
                   for name, row in manifest["packages"].items()}
        if (manifest.get("group") != group or manifest.get("profile") != profile
                or manifest.get("platform") != "darwin-arm64"
                or manifest.get("configuration") != "opt" or manifest.get("developmentProof") != lock.get("developmentProof")
                or manifest.get("lower") != lock["lower"] or manifest.get("toolchain") != tools
                or manifest.get("recipeSHA256") != lock["recipeSHA256"] or reached != packages):
            raise ValueError("foundational bundle mirror manifest differs from compact lock")
    return lock


def produce(root: Path, output: Path, lower_lock: Path, development_proof: bool,
            profile: str = "enhanced", group: str = "foundation") -> dict:
    if group not in GROUPS:
        raise ValueError("unsupported Swift package layer group")
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError("foundation output must be a fresh absolute directory")
    source = command("git", "-C", str(root), "rev-parse", "HEAD")
    dirty = bool(command("git", "-C", str(root), "status", "--porcelain"))
    if dirty and not development_proof:
        raise ValueError("publishable foundation requires a clean producer checkout")
    lower = json.loads(lower_lock.read_text())
    if lower != json.loads((root / "Tools/bazel/artifacts/argument-parser.lock.json").read_text()):
        raise ValueError("producer ArgumentParser lower lock differs from configured repository lock")
    if lower.get("manifest", {}).get("package") != PUBLISHED_LOWER or not SHA.fullmatch(lower.get("archiveSHA256", "")):
        raise ValueError("package layer requires the published ArgumentParser lock")
    records = source_records(root, profile)
    pins = {name: item["revision"] for name, item in records.items()}
    if lower["manifest"].get("sourceCommit") != pins[PUBLISHED_LOWER]:
        raise ValueError("published ArgumentParser source does not match the selected lock")
    lowers = lower_records(root, profile, group, lower_lock)
    sys.path.insert(0, str(root / "Tools/bazel"))
    from run import BAZEL, RETAINED, SSD, clean_env, source_snapshot, workspace_lease
    allowed = {repo_name(name): name for name in group_pins(pins, group)}
    output.mkdir(parents=True, mode=0o700)
    runner = str(root / "Tools/bazel/run.sh")
    lower_config = {"foundation": "prebuilt-argument-parser",
                    "containerization": "prebuilt-foundation",
                    "engine-api": "prebuilt-foundation",
                    "container-sdk": "prebuilt-engine-api"}[group]
    build_flags = ["--config=release", f"--config={profile}", f"--config={lower_config}"]
    if group == "container-sdk":
        build_flags.append("--config=prebuilt-containerization")
    # The executable's link graph need not request every transitive library's
    # DefaultInfo interface. Request selected outputs through an aspect on the
    # configured root so minimum-OS transitions are preserved.
    aspect_name = group.replace("-", "_") + "_outputs"
    materialize_flags = [
        f"--aspects=//Tools/bazel/artifacts:compiled_outputs.bzl%{aspect_name}",
        "--output_groups=+layer_compiled",
    ]
    producer_flags = build_flags + materialize_flags
    built = subprocess.run([runner, "build", *producer_flags, "//:compose"],
                           cwd=root, capture_output=True, text=True, timeout=3600)
    if built.returncode:
        raise RuntimeError(f"foundation source producer failed: {built.stderr[-2000:]}")
    evidence = re.findall(r"^Compose Bazel evidence: (/.+)$", built.stdout + built.stderr, re.M)
    if len(evidence) != 1:
        raise ValueError("foundation producer lacks one retained launcher invocation")
    invocation = Path(evidence[0])
    outcome = json.loads((invocation / "outcome.json").read_text())
    if outcome.get("bazel_exit_code") != 0 or outcome.get("validation_exit_code") != 0:
        raise ValueError("foundation source build was not admitted")
    events = [json.loads(line) for line in (invocation / "events.json").read_text().splitlines()]
    commands = [item["unstructuredCommandLine"]["args"] for item in events
                if "unstructuredCommandLine" in item]
    finished = [item["finished"] for item in events if "finished" in item]
    options = [item["optionsParsed"]["cmdLine"] for item in events if "optionsParsed" in item]
    if (len(commands) != 1 or commands[0][0] != "build" or "//:compose" not in commands[0]
            or not set(producer_flags).issubset(commands[0]) or
            len(options) != 1 or "--compilation_mode=opt" not in options[0] or
            len(finished) != 1 or finished[0].get("overallSuccess") is not True or
            finished[0].get("exitCode", {}).get("name") != "SUCCESS"):
        raise ValueError("optimized producer BEP did not confirm the selected layer build")
    inputs_before = json.loads((invocation / "inputs-before.json").read_text())
    inputs_after = json.loads((invocation / "inputs-after.json").read_text())
    if inputs_before != inputs_after or inputs_before.get("commit") != source or inputs_before.get("dirty") != dirty:
        raise ValueError("foundation source changed during its admitted build")
    execution_root = Path(command(runner, "info", "execution_root", cwd=root).splitlines()[-1])
    output_base = Path(command(runner, "info", "output_base", cwd=root).splitlines()[-1])
    environment = clean_env()
    from artifacts.argument_parser import cached_release as cached_argument, verify_consumer as verify_argument
    argument = root / "Tools/bazel/artifacts/argument-parser.lock.json"
    argument_archive = cached_argument(argument, RETAINED / "binary-layers/argument-parser")
    verify_argument(argument, root, argument_archive, environment)
    environment["COMPOSE_ARGUMENT_PARSER_LAYER_MIRROR"] = str(argument_archive)
    for lower_group in LOWERS[group]:
        if lower_group == "argument-parser":
            continue
        from artifacts.layer_release import cached_release as cached_layer
        lower_path = layer_lock_path(root, lower_group, profile)
        lower_archive = cached_layer(lower_path, RETAINED / "binary-layers" / lower_group / profile)
        verify_consumer(lower_path, root, lower_archive, environment, profile, lower_group)
        environment[{"foundation": "COMPOSE_FOUNDATION_LAYER_MIRROR",
                     "containerization": "COMPOSE_CONTAINERIZATION_LAYER_MIRROR",
                     "engine-api": "COMPOSE_ENGINE_API_LAYER_MIRROR"}[lower_group]] = str(lower_archive)
    query = [str(BAZEL), "--nosystem_rc", "--nohome_rc", "--noworkspace_rc",
             f"--bazelrc={root / '.bazelrc'}", f"--output_user_root={SSD / 'output'}",
             f"--host_jvm_args=-Djava.io.tmpdir={SSD / 'tmp'}", "cquery", f"--config={profile}",
             *build_flags, "deps(//:compose)", "--output=files",
             f"--repository_cache={SSD / 'repository'}"]
    members = {}
    packages = {}
    with workspace_lease("cquery") as recovery:
        recovery.write_text(json.dumps({"schema": 1, "reason": "in-flight compiled layer output export",
                                        "group": group, "producerCommit": source}) + "\n")
        listed = subprocess.check_output(query, cwd=root, env=environment, text=True, timeout=600)
        binaries, identities = artifact_map(listed.splitlines(), execution_root, output_base, allowed)
        for repository, identity in identities.items():
            binary_member = binaries[repository]
            if not binary_member:
                continue  # Lockfile packages unused by the production closure.
            package = allowed[repository]
            external = output_base / "external" / ("+dependencies+" + repository)
            overlay = package_overlay(repository, external, binary_member, identity)
            prefix = group + "/" + repository + "/"
            members.update({prefix + name: value for name, value in overlay.items()})
            packages[package] = {"sourceCommit": pins[package],
                                 "sourceLocation": records[package]["location"],
                                 "repository": repository,
                                 "swiftTargets": sorted(identity["swift"]),
                                 "cTargets": sorted(identity["cc"]),
                                 "metadata": sorted(name for name in overlay if name not in binary_member)}
        if source_snapshot() != inputs_before:
            raise ValueError("foundation source changed during configured output export")
        recovery.unlink()
    required = {"foundation": {"swift-log"} | ({"zstd"} if profile == "enhanced" else set()),
                "containerization": {"containerization"},
                "engine-api": {"container-engine-api"},
                "container-sdk": {"container"}}[group]
    if not required.issubset(packages):
        raise ValueError("configured closure omitted a required pinned package: " + ", ".join(sorted(required - packages.keys())))
    tool = Path(command("/usr/bin/xcrun", "-f", "swiftc", environment=environment))
    sdk = Path(command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path", environment=environment))
    manifest = {"schema": 1, "group": group, "profile": profile, "platform": "darwin-arm64",
                "configuration": "opt", "developmentProof": dirty,
                "recipeSHA256": recipe_identity(root, profile, group),
                "toolchain": {"swiftcSHA256": file_digest(tool),
                              "swiftVersion": command(str(tool), "--version", environment=environment),
                              "sdkSettingsSHA256": file_digest(sdk / "SDKSettings.json"),
                              "sdkVersion": command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version",
                                                    environment=environment),
                              "xcodeVersion": command("/usr/bin/xcodebuild", "-version", environment=environment),
                              "bazelVersion": (root / ".bazelversion").read_text().strip()},
                "lower": lowers,
                "packages": packages, "files": {name: digest(value) for name, value in members.items()}}
    archive = output / f"{group}-{profile}-darwin-arm64-opt.tar.gz"
    if source_snapshot() != inputs_before:
        raise ValueError("foundation source changed before archive sealing")
    archive.write_bytes(archive_bytes(members, manifest))
    observed = inspect(archive)
    receipt = {"schema": 1, **observed, "archive": str(archive), "producerCommit": source,
               "launcherInvocation": str(invocation),
               "outcomeSHA256": file_digest(invocation / "outcome.json"),
               "producerEventsSHA256": file_digest(invocation / "events.json"),
               "sourceInputsSHA256": file_digest(invocation / "inputs-before.json")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["produce", "proof-lock"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", choices=["enhanced", "stock"], default="enhanced")
    parser.add_argument("--group", choices=GROUPS, default="foundation")
    parser.add_argument("--lower-lock", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--development-proof", action="store_true")
    args = parser.parse_args()
    if args.action == "produce":
        if args.lower_lock is None:
            parser.error("produce requires --lower-lock")
        result = produce(args.root, args.output, args.lower_lock, args.development_proof, args.profile, args.group)
    else:
        if args.receipt is None:
            parser.error("proof-lock requires --receipt")
        result = proof_lock(args.receipt, args.root, args.output)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
