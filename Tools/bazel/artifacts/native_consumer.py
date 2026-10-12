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

"""Explicit Compose admission of the unchanged Container-native binary graph."""

from __future__ import annotations

import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import types

VERIFIER_COMMIT = "fc5d94aeeaae2ce373480a65b7a7ae11c2897315"
CLIENT_TESTS = frozenset({"@swiftpkg_container//:ContainerAPIClientTests.rspm", "@swiftpkg_container//:ContainerXPCTests.rspm"})


def options(arguments: list[str]) -> tuple[dict[str, Path], list[str]]:
    selected, filtered = {}, []
    for item in arguments:
        if item.startswith(("--native-container-source", "--native-layer-locks")):
            key, separator, value = item.partition("=")
            if (key not in {"--native-container-source", "--native-layer-locks"}
                    or not separator or key in selected or not Path(value).is_absolute()
                    or ".." in Path(value).parts):
                raise ValueError("Native admission requires unique absolute source and lock paths")
            selected[key] = Path(value)
        else:
            filtered.append(item)
    if selected and set(selected) != {"--native-container-source", "--native-layer-locks"}:
        raise ValueError("Native admission requires both source and published lock paths")
    return selected, filtered


def load_verifier(root: Path):
    # Verify every tracked byte before importing executable verifier code.
    try:
        from Tools.bazel.input_identity import source_identity
    except ModuleNotFoundError:
        from input_identity import source_identity
    state = source_identity(root)
    if state["dirty"] or state["commit"] != VERIFIER_COMMIT:
        raise ValueError("native verifier requires its exact reviewed clean Container source")
    namespace = "_compose_native_" + VERIFIER_COMMIT
    for name in list(sys.modules):
        if name == namespace or name.startswith(namespace + "."):
            del sys.modules[name]
    package = types.ModuleType(namespace)
    package.__path__ = [str(root / "Tools/bazel/artifacts")]
    sys.modules[namespace] = package
    # A fresh private cache prefix prevents ignored/stale .pyc from replacing
    # authenticated source. This launcher admits one graph synchronously.
    previous_cache = sys.pycache_prefix
    with tempfile.TemporaryDirectory(prefix="compose-native-verifier-cache-") as temporary:
        sys.pycache_prefix = temporary
        try:
            layers = importlib.import_module(namespace + ".native_layers")
            producer = importlib.import_module(namespace + ".native_producer")
        finally:
            sys.pycache_prefix = previous_cache
    return layers, producer, state


def coherent_pins(root: Path, native: dict, commit: str) -> dict:
    original = json.loads((root / "Package.resolved").read_text())
    rows = {row["identity"]: row for row in original["pins"]}
    if len(rows) != len(original["pins"]) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("native consumer source vector is malformed")
    for name, row in native.items():
        if (row.get("identity") != name or row.get("kind") != "remoteSourceControl"
                or not re.fullmatch(r"[0-9a-f]{40}", row.get("state", {}).get("revision", ""))
                or not isinstance(row.get("location"), str) or not row["location"]):
            raise ValueError("native source vector lacks immutable package identity")
        rows[name] = row
    rows["container"] = {"identity": "container", "kind": "remoteSourceControl",
        "location": "https://github.com/stephenlclarke/container.git", "state": {"revision": commit}}
    return {"version": original.get("version", 3), "pins": [rows[name] for name in sorted(rows)]}


def configuration(root: Path, native_root: Path, supplied: list[str], profile: str) -> None:
    if profile != "enhanced" or "--config=release" not in supplied:
        raise ValueError("native consumption requires the existing enhanced release profile")
    forbidden = ("--config=prebuilt-", "--config=asan", "--config=tsan", "-c", "--compilation_mode",
                 "--features", "--swiftcopt", "--copt", "--conlyopt", "--cxxopt", "--define",
                 "--macos_", "--xcode_", "--platform", "--host_", "--cpu", "--apple_", "--extra_toolchains",
                 "--@build_bazel_rules_swift//swift:copt")
    if any(arg.startswith(forbidden) for arg in supplied if arg != "--config=release"):
        raise ValueError("native binary consumer configuration cannot be overridden")
    def minimum(path):
        values = re.findall(r"^build --macos_minimum_os=(\S+)$", (path / ".bazelrc").read_text(), re.M)
        if len(values) != 1:
            raise ValueError("native consumer minimum OS configuration is ambiguous")
        return values[0]
    if (minimum(root) != minimum(native_root)
            or (root / ".bazelversion").read_bytes() != (native_root / ".bazelversion").read_bytes()):
        raise ValueError("Compose native configuration differs from producer minimum OS or Bazel")


def verify_client(layers, producer, sidecar: dict, manifest: dict,
                  pair: dict, admission: dict, pins: dict) -> None:
    commit = admission["source"]
    selected = producer._group_source_pins("container-sdk", {"commit": commit, "pins": pins})
    lower = {name: layers.lower_identity(row) for name, row in admission["layers"].items()}
    recipe = admission["recipeSHA256"]
    manifest_sha = hashlib.sha256((json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
    if (manifest.get("group") != "container-sdk" or manifest.get("graph") != "container-native"
            or manifest.get("profile") != "native" or manifest.get("configuration") != "opt"
            or manifest.get("platform") != "darwin-arm64" or manifest.get("developmentProof") is not False
            or manifest.get("producerCommit") != commit or manifest.get("sourcePins") != selected
            or manifest.get("lower") != lower or manifest.get("recipeSHA256") != recipe
            or manifest.get("toolchain") != admission["toolchain"]
            or pair["archive"].get("repository") != "stephenlclarke/container"
            or pair["archive"].get("asset") != "container-sdk-native-darwin-arm64-opt.tar.gz"
            or pair["archive"].get("targetCommit") != commit
            or pair["evidence"].get("asset") != "container-sdk-native-evidence.json"
            or pair["proof"].get("asset") != "container-sdk-native-proof.tar.gz"):
        raise ValueError("native client differs from its exact own-source, recipe or four-lower graph")
    for key, value in {"schema": 1, "group": "container-sdk", "source": commit,
                       "archiveSHA256": pair["archive"]["sha256"], "sourcePins": selected,
                       "lower": lower, "recipeSHA256": recipe, "toolchain": admission["toolchain"],
                       "manifestSHA256": manifest_sha, "passed": True, "developmentProof": False}.items():
        if sidecar.get(key) != value:
            raise ValueError("native client sidecar differs from authenticated product")
    if (sidecar.get("proofBundle", {}).get("sha256") != pair["proof"]["sha256"]
            or sidecar["proofBundle"].get("asset") != pair["proof"]["asset"]):
        raise ValueError("native client portable proof identity differs")
    qualification = sidecar.get("qualification", {})
    tests = {name for row in qualification.get("invocations", []) for name in row.get("targets", [])}
    reports = {row["label"]: row for invocation in qualification.get("invocations", [])
               for row in invocation.get("reports", [])}
    if (qualification.get("passed") is not True or qualification.get("source") != commit
            or qualification.get("group") != "container-sdk" or not CLIENT_TESTS.issubset(tests)
            or not CLIENT_TESTS.issubset(qualification.get("requiredTargets", []))
            or not CLIENT_TESTS.issubset(reports)
            or any(reports[name].get("executed", 0) <= 0 or reports[name].get("skipped") != 0
                   or reports[name].get("reportSHA256", {}).get("test.xml") != sidecar.get("tests", {}).get(name)
                   or not layers.SHA.fullmatch(sidecar.get("tests", {}).get(name, ""))
                   for name in CLIENT_TESTS)):
        raise ValueError("native client source qualification lacks authenticated client/XPC reports")
    outputs = manifest.get("payloadOutputs", {})
    files = sidecar.get("producerBuild", {}).get("files", {})
    if (not outputs or set(outputs) != {name for name in manifest["files"] if "/binary/" in name}
            or any(files.get(configured, {}).get("sha256") != manifest["files"][member]
                   for member, configured in outputs.items())):
        raise ValueError("native client binaries lack authenticated configured output evidence")
    if not {"container-sdk/swiftpkg_container/binary/ContainerAPIClient.swiftmodule",
            "container-sdk/swiftpkg_container/binary/ContainerXPC.swiftmodule"}.issubset(manifest["files"]):
        raise ValueError("native client lacks compiled client/XPC modules")
    package = manifest.get("packages", {}).get("container", {})
    if (set(manifest.get("packages", {})) != {"container"}
            or package.get("sourceCommit") != commit or package.get("sourceLocation") != selected["container"]["location"]
            or package.get("repository") != "swiftpkg_container"
            or not layers.SHA.fullmatch(package.get("generatedBuildSHA256", ""))):
        raise ValueError("native client package source identity differs")


def cached_client(layers, archive: Path, manifest: dict, cache: Path, sha: str) -> Path:
    destination = cache / "container-sdk" / sha / "packages"
    layers._private_cache(destination)
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="client-", dir=destination.parent) as temporary:
            staged = Path(temporary) / "packages"
            layers._safe_extract(archive, manifest, "container-sdk", staged)
            staged.rename(destination)
    expected = {name.removeprefix("container-sdk/"): digest for name, digest in manifest["files"].items()}
    actual = {}
    for path in destination.rglob("*"):
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            raise ValueError("native client cache has unsafe ownership or links")
        if path.is_file():
            relative = str(path.relative_to(destination))
            mode = 0o755 if relative.endswith("/binary/SmithyCodegenCLI.rspm.__impl") else 0o644
            if path.stat().st_mode & 0o7777 != mode:
                raise ValueError("native client cached file permissions differ")
            actual[relative] = layers.digest(path)
        elif not path.is_dir():
            raise ValueError("native client cache has unexpected file type")
    if actual != expected:
        raise ValueError("native client cached file inventory or bytes differ")
    return destination / "swiftpkg_container"


def admit(root: Path, native_root: Path, locks: Path, cache: Path,
          supplied: list[str], profile: str) -> dict:
    if sys.version_info < (3, 10):
        raise ValueError("native Container proof admission requires Python >= 3.10")
    configuration(root, native_root, supplied, profile)
    layers, producer, state = load_verifier(native_root)
    admission = layers.import_layers(root=native_root, locks=locks, cache=cache)
    if admission["source"] != state["commit"] or layers.toolchain(root) != admission["toolchain"]:
        raise ValueError("Compose native consumer toolchain differs from producer")
    pins = layers.pin_records(native_root)
    product, evidence, proof, pair = layers._release_pair("container-sdk", locks, cache)
    observed = importlib.import_module(layers.__package__ + ".native_format").inspect(
        Path(product["asset"]), pair["archive"]["sha256"])
    manifest = observed["manifest"]
    sidecar = json.loads(Path(evidence["asset"]).read_text())
    verify_client(layers, producer, sidecar, manifest, pair,
                  admission, pins)
    producer.verify_proof_bundle(Path(proof["asset"]), sidecar)
    client = cached_client(layers, Path(product["asset"]), manifest, cache, pair["archive"]["sha256"])
    vector = coherent_pins(root, pins, state["commit"])
    packages = {row["identity"] for row in vector["pins"]}
    overrides = {name: path for name, path in admission["overrides"].items()
                 if any(name == "+dependencies+" + layers.repo_name(pin) for pin in packages)}
    overrides["+dependencies+swiftpkg_container"] = str(client.resolve(strict=True))
    expected = {"+dependencies+" + layers.repo_name(name) for name in packages
                if name not in {"swift-docc-plugin", "swift-docc-symbolkit"}}
    unimported = {"+dependencies+" + layers.repo_name(name)
                  for name in admission["expectedUnimportedPins"]}
    if not expected.issubset(set(overrides) | unimported):
        raise ValueError("native graph lacks compiled packages required by Compose: " +
                         ", ".join(sorted(expected - set(overrides) - unimported)))
    encoded = (json.dumps(vector, sort_keys=True, indent=2) + "\n").encode()
    resolved = cache / ("compose-native-" + hashlib.sha256(encoded).hexdigest() + ".json")
    if resolved.is_symlink() or resolved.exists() and resolved.read_bytes() != encoded:
        raise ValueError("native consumer resolved vector cache changed")
    resolved.write_bytes(encoded)
    # Revalidate executable verifier source after all imports/admission.
    if load_verifier(native_root)[2] != state:
        raise ValueError("native verifier source changed during admission")
    return {"schema": 1, "graph": "container-native", "consumerProfile": "enhanced",
            "verifierCommit": state["commit"], "verifierRoot": str(native_root), "locksRoot": str(locks),
            "verifierSourceSHA256": hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest(),
            "layers": admission["layers"],
            "client": pair, "resolved": str(resolved), "resolvedSHA256": hashlib.sha256(encoded).hexdigest(),
            "overrides": overrides, "expectedUnimportedPins": admission["expectedUnimportedPins"],
            "toolchain": admission["toolchain"],
            "configurationEquivalence": {"compilationMode": "opt", "minimumOS": "15.0"},
            "compiledConsumerVerified": False}


def readmit(root: Path, record: dict, cache: Path, supplied: list[str], profile: str) -> None:
    current = admit(root, Path(record["verifierRoot"]), Path(record["locksRoot"]), cache, supplied, profile)
    if current != record:
        raise ValueError("native dependency admission changed during Compose invocation")
