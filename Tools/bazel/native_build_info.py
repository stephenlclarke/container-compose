#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Write raw native-product build-info from pinned compile acceptance and admission.

This reads retained proof only; it does not build, run or qualify the product.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from artifacts.native_consumer import package_binding, readmit
from input_identity import source_identity, verify
from package import build_info, sha256, validate_binary, write_json

METADATA_FILES = ("Makefile", "Package.resolved", ".bazelrc", ".bazelversion",
                  "Tools/compose-normalizer/go.mod", "Tools/compose-normalizer/go.sum",
                  "Tools/release/runtime-capabilities.json", "Tools/release/write-build-info.py")


def generate(root: Path, acceptance_path: Path, acceptance_sha: str, product: Path) -> tuple[dict, dict]:
    """Replay the exact lower proof without relabeling previously compiled bytes."""
    if sha256(acceptance_path) != acceptance_sha:
        raise ValueError("Compiled acceptance receipt hash differs")
    acceptance = json.loads(acceptance_path.read_bytes())
    if (acceptance.get("passed") is not True or acceptance.get("compiledConsumerVerified") is not True
            or acceptance.get("buildConfigurationVerified") is not True
            or acceptance.get("hostRestored") is not True or acceptance.get("failures") != []
            or sha256(product) != acceptance["productSHA256"]):
        raise ValueError("Raw product lacks successful exact compiled acceptance")
    validate_binary(product, "darwin-arm64")
    current = source_identity(root)
    if current["dirty"]:
        raise ValueError("Raw metadata requires a clean source snapshot")
    records = []
    for invocation in acceptance["invocations"]:
        directory = Path(invocation["path"])
        hashes = invocation["filesSHA256"]
        for name in ("inputs-before.json", "inputs-after.json", "native-admission.json", "events.json", "outcome.json", "owner.json"):
            if sha256(directory / name) != hashes[name]:
                raise ValueError("Compiled invocation evidence changed")
        before = json.loads((directory / "inputs-before.json").read_bytes())
        verify(before, json.loads((directory / "inputs-after.json").read_bytes()))
        outcome = json.loads((directory / "outcome.json").read_bytes())
        owner = json.loads((directory / "owner.json").read_bytes())
        if (before["dirty"] or before["commit"] != acceptance["source"]
                or outcome["bazel_exit_code"] != 0 or outcome["validation_exit_code"] != 0
                or owner["profile"] != "enhanced"):
            raise ValueError("Compiled invocation source/configuration failed")
        selected = {name for files in (before["files"], current["files"])
                    for name in files if name.startswith("Sources/")} | set(METADATA_FILES)
        if any(before["files"].get(name) != current["files"].get(name) for name in selected):
            raise ValueError("Compiled product source or metadata inputs changed")
        records.append(json.loads((directory / "native-admission.json").read_bytes()))
    if not records or any(record != records[0] for record in records):
        raise ValueError("Compiled invocations lack one coherent native admission")
    record = records[0]
    readmit(root, record, Path(record["resolved"]).parent, ["--config=release"], "enhanced")
    manifest = {"profile": "enhanced", "commit": acceptance["source"],
                "resolved": record["resolved"], "native_binding": package_binding(record),
                "makefile": str(root / "Makefile"),
                "go_mod": str(root / "Tools/compose-normalizer/go.mod"),
                "capabilities": str(root / "Tools/release/runtime-capabilities.json")}
    info = build_info(manifest, root / "Tools/release/write-build-info.py")
    if source_identity(root) != current:
        raise ValueError("Source changed while generating raw metadata")
    return info, {"schema": 1, "releaseAuthority": False, "runtimeQualified": False,
                  "compiledSource": acceptance["source"], "metadataSource": current["commit"],
                  "acceptanceSHA256": acceptance_sha, "productSHA256": acceptance["productSHA256"],
                  "nativeAdmission": manifest["native_binding"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "acceptance", "product", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--acceptance-sha256", required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix(".proof.json").exists():
        raise ValueError("Refusing to overwrite raw-product metadata evidence")
    info, proof = generate(args.source, args.acceptance, args.acceptance_sha256, args.product)
    write_json(args.output, info)
    proof["buildInfoSHA256"] = sha256(args.output)
    write_json(args.output.with_suffix(".proof.json"), proof)


if __name__ == "__main__":
    main()
