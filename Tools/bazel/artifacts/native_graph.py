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

"""Verify the configured Compose closure against admitted native product bytes."""

import hashlib
import importlib
import json
import os
from pathlib import Path
import re

from . import native_consumer
from ..input_identity import source_identity

ALLOWED_IMPORTED_ACTIONS = frozenset(("FileWrite", "TemplateExpand", "ExecutableSymlink", "SymlinkTree",
                                    "RepoMappingManifest", "SourceSymlinkManifest", "Middleman"))
UNUSED_HTTP = frozenset(("swift-http-types", "swift-http-structured-headers"))
REQUIRED_LINK_REPOSITORIES = frozenset("+dependencies+swiftpkg_" + name for name in
                                     ("container", "containerization", "swift_argument_parser"))


def _graph(path: Path) -> dict:
    text = path.read_text()
    start = text.find("\n{")
    document = text.lstrip() if text.lstrip().startswith("{") else text[start + 1:] if start >= 0 else ""
    if not document:
        raise ValueError("Compose aquery lacks a JSON action graph")
    graph, consumed = json.JSONDecoder().raw_decode(document)
    trailing = document[consumed:]
    if (not trailing.startswith("\nINFO:") or "Build completed successfully" not in trailing
            or "Aquery did NOT complete successfully" in trailing):
        raise ValueError("Compose aquery did not complete successfully")
    for key in ("actions", "targets", "artifacts", "depSetOfFiles", "pathFragments", "configuration"):
        if not isinstance(graph.get(key), list):
            raise ValueError("Compose aquery lacks configured action inventory")
    return graph


def _indexed(rows: list[dict]) -> dict:
    result = {row["id"]: row for row in rows}
    if len(result) != len(rows):
        raise ValueError("Compose aquery contains duplicate identifiers")
    return result


class _Paths:
    def __init__(self, graph):
        self.fragments = _indexed(graph["pathFragments"])
        self.artifacts = _indexed(graph["artifacts"])
        self.sets = _indexed(graph["depSetOfFiles"])

    def artifact(self, identity):
        item = self.artifacts[identity]
        labels, seen = [], set()
        fragment = item["pathFragmentId"]
        while fragment:
            if fragment in seen or fragment not in self.fragments:
                raise ValueError("Compose action has a cyclic or missing path fragment")
            seen.add(fragment)
            row = self.fragments[fragment]
            label = row["label"]
            if not label or label in (".", "..") or "/" in label:
                raise ValueError("Compose action path escapes its execution root")
            labels.append(label)
            fragment = row.get("parentId")
        if not labels:
            raise ValueError("Compose action has an empty artifact path")
        return "/".join(reversed(labels))

    def inputs(self, action):
        files, visited, active = set(), set(), set()
        def visit(identity):
            if identity in active or identity not in self.sets:
                raise ValueError("Compose action has a cyclic or missing input set")
            if identity in visited:
                return
            active.add(identity)
            row = self.sets[identity]
            files.update(self.artifact(item) for item in row.get("directArtifactIds", []))
            for child in row.get("transitiveDepSetIds", []):
                visit(child)
            active.remove(identity)
            visited.add(identity)
        for identity in action.get("inputDepSetIds", []):
            visit(identity)
        return files


def authenticated_packages(admission: dict, cache: Path, root: Path) -> dict:
    # Replay full admission, not a caller-supplied archive/hash map.
    native_consumer.readmit(root, admission, cache, ["--config=release"], "enhanced")
    layers, _, _ = native_consumer.load_verifier(Path(admission["verifierRoot"]))
    format_module = importlib.import_module(layers.__package__ + ".native_format")
    inventory = {}
    for group in ("argument-parser", "foundation", "containerization", "engine-api", "container-sdk"):
        product, evidence, proof, pair = layers._release_pair(group, Path(admission["locksRoot"]), cache)
        if group == "container-sdk":
            if pair != admission["client"]:
                raise ValueError("native client release identity changed during graph proof")
        else:
            record = admission["layers"][group]
            current = {"archiveSHA256": pair["archive"]["sha256"],
                       "evidenceSHA256": pair["evidence"]["sha256"], "proofSHA256": pair["proof"]["sha256"],
                       "assetId": product["assetId"], "evidenceAssetId": evidence["assetId"],
                       "proofAssetId": proof["assetId"], "releaseId": product["releaseId"],
                       "lockSHA256": pair["lockSHA256"]}
            if any(record.get(key) != value for key, value in current.items()):
                raise ValueError("native lower release identity changed during graph proof")
        manifest = format_module.inspect(Path(product["asset"]), pair["archive"]["sha256"])["manifest"]
        for row in manifest["packages"].values():
            repository = "+dependencies+" + row["repository"]
            if repository in inventory or repository not in admission["overrides"]:
                raise ValueError("native graph package ownership differs from admission")
            prefix = group + "/" + row["repository"] + "/"
            files = {name.removeprefix(prefix): sha for name, sha in manifest["files"].items()
                     if name.startswith(prefix)}
            inventory[repository] = {"root": admission["overrides"][repository], "files": files,
                                     "archiveSHA256": pair["archive"]["sha256"]}
    if set(inventory) != set(admission["overrides"]):
        raise ValueError("native graph inventory omits an admitted package")
    return inventory


def _repository(label: str) -> str:
    repository = label.split("//", 1)[0].lstrip("@")
    if "swiftpkg_" in repository and not repository.startswith("+dependencies+swiftpkg_"):
        raise ValueError("Compose graph uses an unadmitted Swift package repository alias")
    return repository


def _loaded(repository: str, inventory: dict, output_base: Path) -> str:
    row = inventory[repository]
    selected = Path(row["root"])
    loaded = output_base / "external" / repository
    if loaded.resolve(strict=True) != selected.resolve(strict=True):
        raise ValueError("Bazel redirected an admitted native repository")
    build = loaded / "BUILD.bazel"
    sha = hashlib.sha256(build.read_bytes()).hexdigest()
    if (build.is_symlink() or not build.resolve(strict=True).is_relative_to(selected.resolve(strict=True))
            or sha != row["files"].get("BUILD.bazel")):
        raise ValueError("loaded native BUILD differs from the published archive")
    return sha


def _archive(entry: str, inventory: dict, output_base: Path) -> tuple[str, str]:
    parts = Path(entry).parts
    names = [part for part in parts if part.startswith("+dependencies+swiftpkg_")]
    if len(names) != 1 or names[0] not in inventory:
        raise ValueError("Compose link reaches an unverified lower archive")
    repository = names[0]
    index = parts.index(repository)
    if parts[:index] != ("external",) or index + 2 >= len(parts) or parts[index + 1] != "binary":
        raise ValueError("Compose link lower archive is not a published source artifact")
    relative = "/".join(parts[index + 1:])
    row = inventory[repository]
    file = output_base / "external" / repository / relative
    selected = Path(row["root"]) / relative
    expected = row["files"].get(relative)
    if (not expected or file.is_symlink() or not file.is_file()
            or file.resolve(strict=True) != selected.resolve(strict=True)
            or not file.resolve(strict=True).is_relative_to(Path(row["root"]).resolve(strict=True))
            or file.stat().st_uid != os.getuid()
            or hashlib.sha256(file.read_bytes()).hexdigest() != expected):
        raise ValueError("Compose linked native archive differs from its authenticated product")
    return repository, expected


def verify_action_graph(path: Path, admission: dict, output_base: Path, cache: Path, root: Path) -> dict:
    source_before = source_identity(root)
    graph_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if source_before["dirty"]:
        raise ValueError("Compose graph requires a clean immutable consumer source")
    graph = _graph(path)
    inventory = authenticated_packages(admission, cache, root)
    if (not output_base.is_absolute() or output_base.is_symlink() or not output_base.is_dir()
            or output_base.stat().st_uid != os.getuid()):
        raise ValueError("Compose graph requires an owned absolute Bazel output base")
    targets = _indexed(graph["targets"])
    configurations = _indexed(graph["configuration"])
    paths = _Paths(graph)
    unused = set(admission["expectedUnimportedPins"]) - {"swift-docc-plugin", "swift-docc-symbolkit"}
    if unused != UNUSED_HTTP:
        raise ValueError("Compose unused native package inventory requires explicit review")
    unused_repos = {"+dependencies+swiftpkg_" + name.replace("-", "_") for name in unused}
    for row in targets.values():
        if _repository(row["label"]) in unused_repos:
            raise ValueError("expected unused HTTP package is configured in Compose")
    for identity in paths.artifacts:
        if set(Path(paths.artifact(identity)).parts) & unused_repos:
            raise ValueError("expected unused HTTP package has a Compose artifact")
    loaded, archive_inputs, links = {}, {}, []
    for action in graph["actions"]:
        label = targets[action["targetId"]]["label"]
        repository = _repository(label)
        if repository.startswith("+dependencies+swiftpkg_"):
            if repository not in inventory or action["mnemonic"] not in ALLOWED_IMPORTED_ACTIONS:
                raise ValueError("native implementation action remains reachable: " + label)
            loaded[repository] = _loaded(repository, inventory, output_base)
        if action["mnemonic"] == "CppLink" and label in ("//:compose", "@@//:compose", "@//:compose"):
            sealed = sorted(entry for entry in paths.inputs(action)
                            if "swiftpkg_" in entry and entry.endswith((".a", ".lo")))
            repositories = set()
            for entry in sealed:
                names = [part for part in Path(entry).parts if part in inventory]
                if len(names) == 1:
                    loaded[names[0]] = _loaded(names[0], inventory, output_base)
                repository, sha = _archive(entry, inventory, output_base)
                archive_inputs[entry] = sha
                repositories.add(repository)
            if not REQUIRED_LINK_REPOSITORIES.issubset(repositories):
                raise ValueError("Compose link omits a required native lower archive")
            outputs = [paths.artifact(item) for item in action.get("outputIds", [])]
            if not outputs or any(not re.fullmatch(r"bazel-out/darwin_arm64-opt(?:-ST-[0-9a-f]+)?/bin/[^ ]+", item)
                                  for item in outputs):
                raise ValueError("Compose link output is not the owned optimized configuration")
            for entry in outputs:
                if not (output_base / "execroot/_main" / entry).resolve().is_relative_to(output_base.resolve()):
                    raise ValueError("Compose link output escapes its owned output base")
            configuration = configurations[action["configurationId"]]
            links.append({"label": label, "configuration": configuration, "outputs": outputs,
                          "repositories": sorted(repositories)})
    if len(links) != 1:
        raise ValueError("Compose action graph must contain exactly one product link")
    if source_identity(root) != source_before or hashlib.sha256(path.read_bytes()).hexdigest() != graph_sha:
        raise ValueError("Compose source or aquery changed during graph verification")
    return {"schema": 1, "graph": "container-native", "qualified": False,
            "source": source_before, "aquerySHA256": graph_sha,
            "nativeAdmissionSHA256": hashlib.sha256(json.dumps(admission, sort_keys=True).encode()).hexdigest(),
            "actions": len(graph["actions"]), "loadedBUILD": loaded, "archiveInputs": archive_inputs,
            "unusedPackagesAbsent": sorted(unused), "links": links,
            "outputBase": str(output_base.resolve()), "buildConfigurationVerified": False,
            "configurationScope": "actual aquery configuration; build BEP equality must be verified separately"}
