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

"""Publish and consume exact, qualified compiled Swift package groups."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

if __package__:
    from .argument_parser import file_digest
    from .foundation import (GROUP_REPOSITORIES, group_pins, inspect, lower_records,
                             recipe_identity, repo_name, source_pins, source_records)
    from .release_asset import cached_fetch, gh, publish_assets, tag_commit
else:
    from argument_parser import file_digest
    from foundation import (GROUP_REPOSITORIES, group_pins, inspect, lower_records,
                            recipe_identity, repo_name, source_pins, source_records)
    from release_asset import cached_fetch, gh, publish_assets, tag_commit

TEST_LABELS = {"//Tools/bazel:cli_smoke", "//Tools/bazel:cli_contracts"}
SOURCE_LOWER_CONFIGS = {"foundation": {"--config=prebuilt-argument-parser"},
                        "containerization": {"--config=prebuilt-foundation"},
                        "engine-api": {"--config=prebuilt-foundation"},
                        "container-sdk": {"--config=prebuilt-containerization", "--config=prebuilt-engine-api"}}


def clean_checkout(root: Path, commit: str) -> None:
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"], text=True)
    if head != commit or status:
        raise ValueError("package layer release requires its exact clean producer checkout")


def admitted_tests(invocation: Path, source_inputs: dict, group: str, profile: str) -> dict:
    before = json.loads((invocation / "inputs-before.json").read_text())
    after = json.loads((invocation / "inputs-after.json").read_text())
    outcome = json.loads((invocation / "outcome.json").read_text())
    if before != source_inputs or after != before or before.get("dirty") is not False:
        raise ValueError("binary consumer tests used a different or dirty source")
    if outcome.get("bazel_exit_code") != 0 or outcome.get("validation_exit_code") != 0:
        raise ValueError("binary consumer test invocation was not admitted")
    events = [json.loads(line) for line in (invocation / "events.json").read_text().splitlines()]
    commands = [event["unstructuredCommandLine"]["args"] for event in events if "unstructuredCommandLine" in event]
    options = [event["optionsParsed"]["cmdLine"] for event in events if "optionsParsed" in event]
    finished = [event["finished"] for event in events if "finished" in event]
    summaries = [event for event in events if "testSummary" in event]
    labels = {event.get("id", {}).get("testSummary", {}).get("label") for event in summaries}
    if (len(commands) != 1 or commands[0][0] != "test" or
            f"--config={profile}" not in commands[0] or
            f"--config={'stock' if profile == 'enhanced' else 'enhanced'}" in commands[0] or
            "--config=release" not in commands[0] or
            len(options) != 1 or "--compilation_mode=opt" not in options[0] or
            "--config=prebuilt-" + group in commands[0] or
            not SOURCE_LOWER_CONFIGS[group].issubset(commands[0]) or
            len(finished) != 1 or finished[0].get("overallSuccess") is not True or
            finished[0].get("exitCode", {}).get("name") != "SUCCESS" or
            labels != TEST_LABELS or len(summaries) != len(TEST_LABELS) or
            any(event["testSummary"].get("overallStatus") != "PASSED" for event in summaries)):
        raise ValueError("source-mode CLI smoke and contracts were not both passed")
    return {"invocation": str(invocation), "outcomeSHA256": file_digest(invocation / "outcome.json"),
            "eventsSHA256": file_digest(invocation / "events.json"),
            "inputsSHA256": file_digest(invocation / "inputs-before.json"),
            "passedLabels": sorted(labels)}


def write_evidence(root: Path, receipt_path: Path, test_invocation: Path, output: Path) -> dict:
    if output.exists():
        raise ValueError("qualification sidecar already exists")
    receipt = json.loads(receipt_path.read_text())
    archive = Path(receipt["archive"])
    observed = inspect(archive, receipt["archiveSHA256"])
    if observed["manifest"] != receipt["manifest"]:
        raise ValueError("producer receipt differs from archive")
    manifest = observed["manifest"]
    if manifest["developmentProof"] is not False:
        raise ValueError("dirty development archive cannot be released")
    clean_checkout(root, receipt["producerCommit"])
    producer = Path(receipt["launcherInvocation"])
    inputs = json.loads((producer / "inputs-before.json").read_text())
    if (inputs != json.loads((producer / "inputs-after.json").read_text()) or
            inputs.get("commit") != receipt["producerCommit"] or inputs.get("dirty") is not False or
            file_digest(producer / "inputs-before.json") != receipt["sourceInputsSHA256"] or
            file_digest(producer / "events.json") != receipt["producerEventsSHA256"] or
            file_digest(producer / "outcome.json") != receipt["outcomeSHA256"]):
        raise ValueError("optimized producer source or build evidence changed")
    outcome = json.loads((producer / "outcome.json").read_text())
    if outcome.get("bazel_exit_code") != 0 or outcome.get("validation_exit_code") != 0:
        raise ValueError("optimized producer build was not admitted")
    accepted = admitted_tests(test_invocation, inputs, manifest["group"], manifest["profile"])
    evidence = {"schema": 1, "archiveSHA256": observed["archiveSHA256"],
                "producerCommit": receipt["producerCommit"],
                "producerReceiptSHA256": file_digest(receipt_path),
                "producerBuild": {"invocation": str(producer),
                                  "outcomeSHA256": receipt["outcomeSHA256"],
                                  "eventsSHA256": receipt["producerEventsSHA256"],
                                  "inputsSHA256": receipt["sourceInputsSHA256"]},
                "sourceCLITests": accepted}
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    return evidence


def release_tag(manifest: dict, archive_sha: str) -> str:
    return "layer-" + manifest["group"] + "-" + manifest["profile"] + "-" + archive_sha[:20]


def release_target(manifest: dict, producer_commit: str) -> str:
    if manifest["group"] == "foundation":
        return producer_commit
    package = {"containerization": "containerization", "engine-api": "container-engine-api",
               "container-sdk": "container"}[manifest["group"]]
    revision = manifest["packages"][package]["sourceCommit"]
    if len(revision) != 40 or any(character not in "0123456789abcdef" for character in revision):
        raise ValueError("package-owned release target is not an exact source commit")
    return revision


def write_lock(root: Path, receipt_path: Path, evidence_path: Path, output: Path) -> dict:
    if output.exists():
        raise ValueError("release lock already exists")
    receipt = json.loads(receipt_path.read_text())
    observed = inspect(Path(receipt["archive"]), receipt["archiveSHA256"])
    manifest = observed["manifest"]
    evidence = json.loads(evidence_path.read_text())
    if (manifest != receipt["manifest"] or manifest["developmentProof"] is not False or
            evidence.get("archiveSHA256") != observed["archiveSHA256"] or
            evidence.get("producerCommit") != receipt["producerCommit"] or
            evidence.get("producerReceiptSHA256") != file_digest(receipt_path) or
            evidence.get("producerBuild") != {
                "invocation": receipt["launcherInvocation"],
                "outcomeSHA256": receipt["outcomeSHA256"],
                "eventsSHA256": receipt["producerEventsSHA256"],
                "inputsSHA256": receipt["sourceInputsSHA256"]} or
            evidence.get("sourceCLITests") != admitted_tests(
                Path(evidence["sourceCLITests"]["invocation"]),
                json.loads((Path(receipt["launcherInvocation"]) / "inputs-before.json").read_text()),
                manifest["group"], manifest["profile"])):
        raise ValueError("archive and qualification sidecar disagree")
    clean_checkout(root, receipt["producerCommit"])
    selected = group_pins(source_pins(root, manifest["profile"]), manifest["group"])
    records = source_records(root, manifest["profile"])
    if (not selected.keys() >= manifest["packages"].keys() or
            manifest.get("recipeSHA256") != recipe_identity(root, manifest["profile"], manifest["group"]) or
            manifest.get("lower") != lower_records(root, manifest["profile"], manifest["group"]) or
            any(row.get("sourceCommit") != selected[name] or
                row.get("sourceLocation") != records[name]["location"] or
                row.get("repository") != repo_name(name)
                for name, row in manifest["packages"].items())):
        raise ValueError("archive includes a package outside its pinned layer")
    lock = {"schema": 1, "developmentProof": False, "group": manifest["group"],
            "profile": manifest["profile"], "repository": GROUP_REPOSITORIES[manifest["group"]],
            "tag": release_tag(manifest, observed["archiveSHA256"]),
            "targetCommit": release_target(manifest, receipt["producerCommit"]),
            "producerCommit": receipt["producerCommit"], "asset": Path(receipt["archive"]).name,
            "archiveSHA256": observed["archiveSHA256"], "evidenceAsset": evidence_path.name,
            "evidenceSHA256": file_digest(evidence_path),
            "sourcePins": selected,
            "reachedSources": {name: {key: row[key] for key in ("sourceCommit", "sourceLocation", "repository")}
                               for name, row in manifest["packages"].items()},
            "lower": manifest["lower"], "toolchain": manifest["toolchain"],
            "recipeSHA256": manifest["recipeSHA256"]}
    output.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return lock


def checked_release(lock: dict) -> tuple[dict, dict[str, dict]]:
    repository, tag = lock["repository"], lock["tag"]
    release = json.loads(gh("api", "--hostname", "github.com", f"repos/{repository}/releases/tags/{tag}"))
    assets = {item.get("name"): item for item in release.get("assets", [])}
    if (release.get("draft") is not False or release.get("prerelease") is not True or
            release.get("tag_name") != tag or tag_commit(repository, tag) != lock["targetCommit"] or
            set(assets) != {lock["asset"], lock["evidenceAsset"]} or
            any(not isinstance(item.get("id"), int) or item.get("size", 0) <= 0 for item in assets.values())):
        raise ValueError("published package layer release identity differs from lock")
    return release, assets


def publish(root: Path, receipt_path: Path, evidence_path: Path, lock_path: Path) -> dict:
    """Stage, reread, byte-verify, then publish one new prerelease."""
    lock = json.loads(lock_path.read_text())
    receipt = json.loads(receipt_path.read_text())
    archive = Path(receipt["archive"])
    observed = inspect(archive, receipt["archiveSHA256"])
    manifest = observed["manifest"]
    evidence = json.loads(evidence_path.read_text())
    clean_checkout(root, receipt["producerCommit"])
    with tempfile.TemporaryDirectory(prefix="package-layer-lock-review-") as temporary:
        if lock != write_lock(root, receipt_path, evidence_path, Path(temporary) / "lock.json"):
            raise ValueError("published package lock differs from qualified producer identity")
    if (manifest != receipt["manifest"] or manifest.get("developmentProof") is not False or
            lock.get("repository") != GROUP_REPOSITORIES[manifest["group"]] or
            lock.get("targetCommit") != release_target(manifest, receipt["producerCommit"]) or
            lock.get("producerCommit") != receipt["producerCommit"] or
            lock.get("archiveSHA256") != observed["archiveSHA256"] or
            lock.get("asset") != archive.name or
            lock.get("evidenceAsset") != evidence_path.name or
            lock.get("evidenceSHA256") != file_digest(evidence_path) or
            lock.get("tag") != release_tag(manifest, observed["archiveSHA256"]) or
            evidence.get("archiveSHA256") != observed["archiveSHA256"] or
            evidence.get("producerReceiptSHA256") != file_digest(receipt_path) or
            evidence.get("sourceCLITests") != admitted_tests(
                Path(evidence["sourceCLITests"]["invocation"]),
                json.loads((Path(receipt["launcherInvocation"]) / "inputs-before.json").read_text()),
                manifest["group"], manifest["profile"])):
        raise ValueError("published package lock or qualification differs from producer")
    repository, tag = lock["repository"], lock["tag"]
    transport = publish_assets(repository, tag, lock["targetCommit"],
                               f"Compiled {manifest['group']} {manifest['profile']} dependency layer",
                               "Exact-toolchain compiled dependency layer; not a product release.",
                               (archive, evidence_path))
    release, published_assets = checked_release(lock)
    if release["id"] != transport["releaseId"] or set(published_assets) != {archive.name, evidence_path.name}:
        raise ValueError("published layer differs from the verified draft")
    return {**transport, "producerCommit": receipt["producerCommit"],
            "archiveSHA256": observed["archiveSHA256"], "evidenceSHA256": file_digest(evidence_path),
            "githubImmutable": release.get("immutable") if isinstance(release.get("immutable"), bool) else None}


def cached_release(lock_path: Path, cache_root: Path) -> Path:
    lock = json.loads(lock_path.read_text())
    if lock.get("developmentProof") is not False or lock.get("tag") != release_tag(
            {"group": lock["group"], "profile": lock["profile"]}, lock["archiveSHA256"]):
        raise ValueError("published package layer lock is incomplete")
    key = file_digest(lock_path)
    if not cache_root.is_absolute() or cache_root.is_symlink():
        raise ValueError("package layer cache root must be an absolute directory")
    root = cache_root / key
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("package layer cache directory is invalid")
    locks = []
    for name, sha in ((lock["asset"], lock["archiveSHA256"]),
                      (lock["evidenceAsset"], lock["evidenceSHA256"])):
        descriptor = {"schema": 1, "repository": lock["repository"], "tag": lock["tag"],
                      "targetCommit": lock["targetCommit"], "asset": name, "sha256": sha}
        path = root / (name + ".lock.json")
        encoded = json.dumps(descriptor, sort_keys=True).encode()
        if path.exists() and path.read_bytes() != encoded:
            raise ValueError("cached release asset descriptor changed")
        path.write_bytes(encoded)
        locks.append(path)
    fetched = [cached_fetch(path, root / ("asset-" + str(index))) for index, path in enumerate(locks)]
    if (fetched[0]["releaseId"] != fetched[1]["releaseId"] or
            fetched[0]["assetId"] == fetched[1]["assetId"]):
        raise ValueError("package layer assets came from different release identities")
    pair_path = root / "verified-pair.json"
    expected_pair = {"schema": 1, "lockSHA256": key, "releaseId": fetched[0]["releaseId"],
                     "assetIds": sorted(item["assetId"] for item in fetched),
                     "archiveSHA256": lock["archiveSHA256"], "evidenceSHA256": lock["evidenceSHA256"]}
    if pair_path.exists():
        if pair_path.is_symlink() or json.loads(pair_path.read_text()) != expected_pair:
            raise ValueError("offline package layer pair receipt differs from exact lock")
    else:
        release, assets = checked_release(lock)
        if (release["id"] != expected_pair["releaseId"] or
                sorted(item["id"] for item in assets.values()) != expected_pair["assetIds"]):
            raise ValueError("published package assets changed during pair admission")
        pair_path.write_text(json.dumps(expected_pair, indent=2, sort_keys=True) + "\n")
    archive = Path(fetched[0]["asset"])
    manifest = inspect(archive, lock["archiveSHA256"])["manifest"]
    evidence = json.loads(Path(fetched[1]["asset"]).read_text())
    if (manifest.get("group") != lock["group"] or manifest.get("profile") != lock["profile"] or
            manifest.get("developmentProof") is not False or
            manifest.get("lower") != lock["lower"] or manifest.get("toolchain") != lock["toolchain"] or
            manifest.get("recipeSHA256") != lock["recipeSHA256"] or
            evidence.get("archiveSHA256") != lock["archiveSHA256"] or
            evidence.get("producerCommit") != lock["producerCommit"]):
        raise ValueError("cached package layer archive or qualification differs from release lock")
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["write-evidence", "write-lock", "publish"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--test-invocation", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.action == "write-evidence":
        if args.test_invocation is None or args.output is None:
            parser.error("write-evidence requires --test-invocation and --output")
        result = write_evidence(args.root, args.receipt, args.test_invocation, args.output)
    elif args.action == "write-lock":
        if args.evidence is None or args.output is None:
            parser.error("write-lock requires --evidence and --output")
        result = write_lock(args.root, args.receipt, args.evidence, args.output)
    else:
        if args.evidence is None or args.lock is None:
            parser.error("publish requires --evidence and --lock")
        result = publish(args.root, args.receipt, args.evidence, args.lock)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
