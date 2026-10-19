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

"""Build, seal, inspect, publish, or fetch one compiled ArgumentParser package.

The archive contains compiled Swift modules AND static libraries. A source
checkout or a warm Bazel cache alone is not a distributable layer.
"""

from __future__ import annotations

import argparse
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile

if __package__:
    from .release_asset import gh, tag_commit
else:
    from release_asset import gh, tag_commit

PACKAGE = "swift-argument-parser"
REPOSITORY = "stephenlclarke/container"
MODULES = ("ArgumentParserToolInfo", "ArgumentParser")
LOWER = {"ArgumentParserToolInfo": [], "ArgumentParser": ["ArgumentParserToolInfo"]}
FILES = tuple(
    name
    for module in MODULES
    for name in (
        f"{module}.swiftmodule",
        f"{module}.swiftdoc",
        f"lib{module}.rspm.__impl.a",
    )
) + ("LICENSE.txt", "pkg_info.json")
SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
PRODUCER_BUILD_SHA256 = "008810e43ddf6820daf7a13a1455368b96087256bdb93fbfebc0393f94ff30d9"


def command(*args: str, cwd: Path | None = None, timeout: int = 180,
            environment: dict[str, str] | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=timeout,
                                   env=environment).strip()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    return digest(path.read_bytes())


def pinned_revision(root: Path) -> str:
    pins = json.loads((root / "Package.resolved").read_text())["pins"]
    matches = [row for row in pins if row["identity"] == PACKAGE]
    if len(matches) != 1 or matches[0]["kind"] != "remoteSourceControl":
        raise ValueError("missing unique immutable ArgumentParser source pin")
    revision = matches[0]["state"]["revision"]
    if not COMMIT.fullmatch(revision):
        raise ValueError("ArgumentParser revision is not an exact commit")
    return revision


def clean_source(root: Path, expected: str) -> None:
    if command("git", "-C", str(root), "rev-parse", "HEAD") != expected:
        raise ValueError("producer source is not the requested Container commit")
    if command("git", "-C", str(root), "status", "--porcelain"):
        raise ValueError("producer checkout is dirty")


def selected_output(lines: str, suffix: str, execution_root: Path, output_base: Path) -> Path:
    matches = [line for line in lines.splitlines() if line == suffix or line.endswith("/" + suffix)]
    existing = []
    for name in matches:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("configured binary output is not relative to the Bazel execution root")
        candidate = execution_root / relative
        if not candidate.exists():
            continue
        path = candidate.resolve(strict=True)
        if not path.is_file() or not path.is_relative_to(output_base.resolve()):
            raise ValueError("configured binary output escaped the Bazel execution root")
        existing.append(path)
    # SwiftPM's configured wrapper applies a minimum-OS transition. Its ST
    # output is consumed by the package graph; the untransitioned archive can
    # contain different bytes and must not be conflated with it.
    transitioned = [path for path in existing if "-ST-" in str(path)]
    if not transitioned or len({file_digest(path) for path in transitioned}) != 1:
        raise ValueError(f"expected one materialized transitioned {suffix} output, got {existing}")
    return transitioned[0]


def output_files(root: Path, execution_root: Path, output_base: Path) -> dict[str, bytes]:
    runner = str(root / "Tools/bazel/run.sh")
    payload = {}
    for module in MODULES:
        label = f"@swiftpkg_swift_argument_parser//:{module}.rspm.__impl"
        listed = command(runner, "cquery", "--config=release", label,
                         "--output=files", cwd=root, timeout=300)
        for suffix in (f"{module}.swiftmodule", f"{module}.swiftdoc",
                       f"lib{module}.rspm.__impl.a"):
            payload[suffix] = selected_output(listed, suffix, execution_root, output_base).read_bytes()
    return payload


def archive_bytes(files: dict[str, bytes], manifest: dict) -> bytes:
    members = {**files, "layer.json": (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()}
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0, filename="") as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, content in sorted(members.items()):
                info = tarfile.TarInfo("argument-parser/" + name)
                info.size, info.mtime, info.uid, info.gid = len(content), 0, 0, 0
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(content))
    return output.getvalue()


def inspect(archive: Path, expected_archive_sha: str | None = None) -> dict:
    raw = archive.read_bytes()
    archive_sha = digest(raw)
    if expected_archive_sha and archive_sha != expected_archive_sha:
        raise ValueError("binary layer archive checksum differs from lock")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        names = tar.getnames()
        expected = {"argument-parser/" + name for name in FILES + ("layer.json",)}
        if len(names) != len(expected) or set(names) != expected:
            raise ValueError("binary layer archive has missing or extra members")
        if any(not member.isfile() or member.issym() or member.islnk() for member in tar):
            raise ValueError("binary layer archive contains a non-file member")
        contents = {name.removeprefix("argument-parser/"): tar.extractfile(name).read()
                    for name in names}
    manifest = json.loads(contents.pop("layer.json"))
    if (manifest.get("schema") != 1 or manifest.get("package") != PACKAGE
            or manifest.get("modules") != LOWER
            or set(manifest.get("files", {})) != set(FILES)):
        raise ValueError("binary layer identity is incomplete")
    for name, expected in manifest["files"].items():
        if not SHA.fullmatch(expected) or digest(contents[name]) != expected:
            raise ValueError(f"binary layer member changed: {name}")
    if manifest.get("platform") != "darwin-arm64" or manifest.get("configuration") != "opt":
        raise ValueError("binary layer has the wrong platform or configuration")
    return {"archiveSHA256": archive_sha, "manifest": manifest}


def accepted_qualification(directory: Path, source: str, test_events: tuple[Path, ...]) -> dict:
    qualification = directory / "qualification.json"
    acceptance = directory / "acceptance.json"
    source_inputs = directory / "runtime-smoke/source-inputs.json"
    qualified = json.loads(qualification.read_text())
    admitted = json.loads(acceptance.read_text())
    inputs = json.loads(source_inputs.read_text())
    if (qualified.get("source") != source or qualified.get("passed") is not True
            or admitted.get("passed") is not True or inputs.get("fork") != source):
        raise ValueError("Q final qualification does not admit this producer commit")
    tests = []
    required = {"ArgumentParserToolInfoTests.rspm", "ArgumentParserUnitTests.rspm"}
    for path in test_events:
        events = [json.loads(line) for line in path.read_text().splitlines()]
        summaries = [event for event in events if "testSummary" in event]
        finished = [event["finished"] for event in events if "finished" in event]
        commands = [event["unstructuredCommandLine"]["args"] for event in events
                    if "unstructuredCommandLine" in event]
        options = [event["optionsParsed"]["cmdLine"] for event in events
                   if "optionsParsed" in event]
        if (len(summaries) != 1 or summaries[0]["testSummary"].get("overallStatus") != "PASSED"
                or len(finished) != 1 or finished[0].get("overallSuccess") is not True
                or finished[0].get("exitCode", {}).get("name") != "SUCCESS"
                or len(commands) != 1 or commands[0][0] != "test"
                or len(options) != 1 or "--compilation_mode=dbg" not in options[0]):
            raise ValueError("targeted ArgumentParser test BEP lacks a passed summary")
        # Bazel emits *.events.json; Path.with_suffix only strips the final
        # suffix, so use the full retained invocation stem for sibling files.
        stem = path.name.removesuffix(".events.json")
        source_file = path.with_name(stem + ".source.txt")
        diff_file = path.with_name(stem + ".diff")
        inputs_file = path.with_name(stem + ".inputs.sha256")
        source_lines = source_file.read_text().splitlines()
        paths = [line.partition("=")[2] for line in source_lines if line.startswith("source=")]
        heads = [line.partition("=")[2] for line in source_lines if line.startswith("head=")]
        if len(paths) != 1 or len(heads) != 1 or heads[0] != source or diff_file.read_bytes():
            raise ValueError("targeted test source snapshot differs from the qualified commit")
        checkout = Path(paths[0]).resolve(strict=True)
        clean_source(checkout, source)
        for line in inputs_file.read_text().splitlines():
            checksum, separator, relative = line.partition("  ")
            candidate = checkout / relative
            if (not separator or not SHA.fullmatch(checksum) or not relative
                    or Path(relative).is_absolute() or ".." in Path(relative).parts
                    or not candidate.is_file() or file_digest(candidate) != checksum):
                raise ValueError("targeted test input snapshot differs from qualified source")
        label = summaries[0]["id"]["testSummary"]["label"]
        tests.append({"label": label, "eventsSHA256": file_digest(path),
                      "sourceSHA256": file_digest(source_file), "diffSHA256": file_digest(diff_file),
                      "inputsSHA256": file_digest(inputs_file)})
        required.discard(label.rsplit(":", 1)[-1])
    if required:
        raise ValueError(f"missing passed ArgumentParser package tests: {sorted(required)}")
    return {"qualificationSHA256": file_digest(qualification),
            "acceptanceSHA256": file_digest(acceptance),
            "sourceInputsSHA256": file_digest(source_inputs), "qualifiedSource": source,
            "targetedSourceTests": tests}


def produce(root: Path, output: Path, expected_source: str,
            qualification: Path, test_events: tuple[Path, ...]) -> dict:
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError("output must be a fresh absolute directory")
    clean_source(root, expected_source)
    revision = pinned_revision(root)
    accepted = accepted_qualification(qualification, expected_source, test_events)
    output.mkdir(mode=0o700, parents=True)
    runner = str(root / "Tools/bazel/run.sh")
    built = subprocess.run([runner, "build", "--config=release",
                            "@swiftpkg_swift_argument_parser//:ArgumentParserToolInfo.rspm",
                            "@swiftpkg_swift_argument_parser//:ArgumentParser.rspm"],
                           cwd=root, capture_output=True, text=True, timeout=1800)
    print(built.stdout, end="")
    if built.returncode:
        raise RuntimeError(f"Container producer Bazel build failed: {built.returncode}")
    evidence_lines = re.findall(r"^Evidence: (/.+\.log)$", built.stdout, re.M)
    if len(evidence_lines) != 1:
        raise ValueError("producer build lacks one retained Bazel log")
    build_log = Path(evidence_lines[0])
    build_events = build_log.with_suffix(".events.json")
    if not build_log.is_file() or not build_events.is_file():
        raise ValueError("producer build lacks its retained BEP event stream")
    clean_source(root, expected_source)
    execution_root = Path(command(runner, "info", "--config=release", "execution_root", cwd=root).splitlines()[-1])
    output_base = Path(command(runner, "info", "--config=release", "output_base", cwd=root).splitlines()[-1])
    files = output_files(root, execution_root, output_base)
    repositories = list((output_base / "external").glob("+dependencies+swiftpkg_swift_argument_parser"))
    if len(repositories) != 1:
        raise ValueError("configured ArgumentParser source repository is missing")
    source = repositories[0]
    for name in ("LICENSE.txt", "pkg_info.json"):
        files[name] = (source / name).read_bytes()
    if json.loads(files["pkg_info.json"]).get("version") not in (None, "1.8.2"):
        raise ValueError("unexpected package metadata version")
    generated_build = source / "BUILD.bazel"
    swiftc = Path(command("/usr/bin/xcrun", "-f", "swiftc"))
    sdk = Path(command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"))
    manifest = {
        "schema": 1, "package": PACKAGE, "upstream": "apple/swift-argument-parser",
        "sourceCommit": revision, "producerRepository": REPOSITORY,
        "producerCommit": expected_source, "modules": LOWER,
        "platform": "darwin-arm64", "configuration": "opt",
        "toolchain": {"swiftcSHA256": file_digest(swiftc),
                      "swiftVersion": command(str(swiftc), "--version"),
                      "sdkSettingsSHA256": file_digest(sdk / "SDKSettings.json"),
                      "sdkVersion": command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
                      "xcodeVersion": command("/usr/bin/xcodebuild", "-version"),
                      "hostMachine": platform.machine(),
                      "bazelVersion": (root / ".bazelversion").read_text().strip(),
                      "rulesSwiftVersion": "3.6.1",
                      "rulesSwiftPackageManagerVersion": "1.23.0",
                      "generatedBuildSHA256": file_digest(generated_build),
                      "bazelrcSHA256": file_digest(root / ".bazelrc")},
        "files": {name: digest(data) for name, data in files.items()},
    }
    archive = output / "swift-argument-parser-darwin-arm64-opt.tar.gz"
    archive.write_bytes(archive_bytes(files, manifest))
    verified = inspect(archive)
    clean_source(root, expected_source)
    release_evidence = {"schema": 1, "archiveSHA256": verified["archiveSHA256"],
                        "producerCommit": expected_source, "qualification": accepted,
                        "optimizedBuild": {"logSHA256": file_digest(build_log),
                                           "eventsSHA256": file_digest(build_events)}}
    evidence_file = output / "release-evidence.json"
    evidence_file.write_text(json.dumps(release_evidence, indent=2, sort_keys=True) + "\n")
    receipt = {"schema": 1, "kind": "compiled-swift-package", **verified,
               "archive": str(archive), "sourceCheckout": str(root),
               "qualificationDirectory": str(qualification),
               "targetedTestEvents": [str(path) for path in test_events],
               "producerBuildLog": str(build_log), "producerBuildEvents": str(build_events),
               "releaseEvidence": str(evidence_file),
               "releaseEvidenceSHA256": file_digest(evidence_file)}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def release_tag(manifest: dict) -> str:
    key = digest(json.dumps({k: manifest[k] for k in ("sourceCommit", "toolchain", "platform", "configuration")},
                            sort_keys=True).encode())[:16]
    return f"layer-argument-parser-{manifest['sourceCommit'][:12]}-{key}"


def verify_consumer(lock_path: Path, root: Path, mirror: Path | None = None,
                    environment: dict[str, str] | None = None) -> dict:
    lock = json.loads(lock_path.read_text())
    manifest = lock["manifest"]
    if (lock.get("schema") != 1 or lock.get("repository") != REPOSITORY or
            lock.get("tag") != release_tag(manifest) or
            lock.get("asset") != "swift-argument-parser-darwin-arm64-opt.tar.gz" or
            not SHA.fullmatch(lock.get("archiveSHA256", "")) or
            lock.get("evidenceAsset") != "release-evidence.json" or
            not SHA.fullmatch(lock.get("evidenceSHA256", "")) or
            manifest.get("sourceCommit") != pinned_revision(root) or
            manifest.get("toolchain", {}).get("generatedBuildSHA256") != PRODUCER_BUILD_SHA256 or
            manifest.get("platform") != "darwin-arm64" or
            manifest.get("configuration") != "opt"):
        raise ValueError("binary layer lock does not match the reviewed package and source")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("prebuilt ArgumentParser requires Apple silicon macOS")
    swiftc = Path(command("/usr/bin/xcrun", "-f", "swiftc", environment=environment))
    sdk = Path(command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path",
                       environment=environment))
    tools = manifest["toolchain"]
    if (tools.get("swiftcSHA256") != file_digest(swiftc) or
            tools.get("sdkSettingsSHA256") != file_digest(sdk / "SDKSettings.json") or
            tools.get("sdkVersion") != command("/usr/bin/xcrun", "--sdk", "macosx",
                                                "--show-sdk-version", environment=environment) or
            tools.get("xcodeVersion") != command("/usr/bin/xcodebuild", "-version",
                                                  environment=environment) or
            tools.get("bazelVersion") != (root / ".bazelversion").read_text().strip()):
        raise ValueError("Swift compiler, SDK, Xcode or Bazel differs from the binary producer")
    if mirror:
        if not mirror.is_absolute() or mirror.is_symlink() or not mirror.is_file():
            raise ValueError("binary layer mirror must be an absolute regular file")
        found = inspect(mirror, lock["archiveSHA256"])
        if found["manifest"] != manifest:
            raise ValueError("binary layer mirror manifest differs from reviewed lock")
    return lock


def write_lock(receipt_path: Path, root: Path, output: Path) -> dict:
    receipt = json.loads(receipt_path.read_text())
    archive = Path(receipt["archive"])
    observed = inspect(archive, receipt["archiveSHA256"])
    if observed["manifest"] != receipt["manifest"]:
        raise ValueError("producer receipt disagrees with archive")
    manifest = observed["manifest"]
    if manifest["sourceCommit"] != pinned_revision(root) or manifest["toolchain"]["generatedBuildSHA256"] != PRODUCER_BUILD_SHA256:
        raise ValueError("producer package does not match the Compose source graph")
    evidence_file = Path(receipt["releaseEvidence"])
    evidence = json.loads(evidence_file.read_text())
    if (file_digest(evidence_file) != receipt["releaseEvidenceSHA256"]
            or evidence.get("archiveSHA256") != observed["archiveSHA256"]
            or evidence.get("producerCommit") != manifest["producerCommit"]
            or evidence.get("qualification") != accepted_qualification(
                Path(receipt["qualificationDirectory"]), manifest["producerCommit"],
                tuple(Path(path) for path in receipt["targetedTestEvents"]))):
        raise ValueError("producer qualification sidecar disagrees with the archive")
    lock = {"schema": 1, "repository": REPOSITORY, "tag": release_tag(manifest),
            "asset": archive.name, "archiveSHA256": observed["archiveSHA256"],
            "evidenceAsset": evidence_file.name, "evidenceSHA256": file_digest(evidence_file),
            "manifest": manifest}
    if output.exists():
        raise ValueError("binary layer lock already exists; review replacement explicitly")
    output.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return lock


def publish(receipt_path: Path) -> None:
    receipt = json.loads(receipt_path.read_text())
    archive = Path(receipt["archive"])
    result = inspect(archive, receipt["archiveSHA256"])
    if result["manifest"] != receipt["manifest"]:
        raise ValueError("producer receipt disagrees with archive")
    clean_source(Path(receipt["sourceCheckout"]), result["manifest"]["producerCommit"])
    evidence_file = Path(receipt["releaseEvidence"])
    evidence = json.loads(evidence_file.read_text())
    if (file_digest(evidence_file) != receipt["releaseEvidenceSHA256"]
            or evidence.get("archiveSHA256") != result["archiveSHA256"]
            or evidence.get("producerCommit") != result["manifest"]["producerCommit"]
            or evidence.get("qualification") != accepted_qualification(
                Path(receipt["qualificationDirectory"]), result["manifest"]["producerCommit"],
                tuple(Path(path) for path in receipt["targetedTestEvents"]))
            or evidence.get("optimizedBuild") != {
                "logSHA256": file_digest(Path(receipt["producerBuildLog"])),
                "eventsSHA256": file_digest(Path(receipt["producerBuildEvents"]))}):
        raise ValueError("qualification sidecar disagrees with the binary layer")
    tag = release_tag(result["manifest"])
    environment = os.environ.copy()
    environment["GH_HOST"] = "github.com"
    draft_check = subprocess.run(["gh", "release", "view", tag, "--repo", REPOSITORY,
                                  "--json", "databaseId"], capture_output=True, text=True,
                                 timeout=30, env=environment)
    if draft_check.returncode == 0:
        raise ValueError("layer release already exists; never overwrite published bytes")
    if draft_check.stderr.strip() != "release not found":
        raise ValueError("could not prove layer release is unused")
    tag_check = subprocess.run(["gh", "api", "--hostname", "github.com",
                                f"repos/{REPOSITORY}/git/ref/tags/{tag}"],
                               capture_output=True, text=True, timeout=30, env=environment)
    if tag_check.returncode == 0:
        raise ValueError("layer tag already exists; never reuse it")
    if "http 404" not in tag_check.stderr.lower():
        raise ValueError("could not prove layer tag is unused")
    subprocess.run(["gh", "release", "create", tag, "--repo", REPOSITORY,
                    "--target", result["manifest"]["producerCommit"], "--prerelease", "--draft",
                    "--title", f"Compiled {PACKAGE} {result['manifest']['sourceCommit'][:12]}",
                    "--notes", "Compiled dependency layer for exact-toolchain Compose consumption; not a runtime release.",
                    str(archive), str(evidence_file)], check=True, timeout=120, env=environment)
    draft = json.loads(gh("release", "view", tag, "--repo", REPOSITORY,
                          "--json", "databaseId,tagName,targetCommitish,isDraft,isPrerelease,assets"))
    assets = draft.get("assets", [])
    expected_names = {archive.name: archive, evidence_file.name: evidence_file}
    if (draft.get("isDraft") is not True or draft.get("isPrerelease") is not True
            or draft.get("tagName") != tag or
            draft.get("targetCommitish") != result["manifest"]["producerCommit"]
            or not isinstance(draft.get("databaseId"), int)
            or len(assets) != 2 or {asset.get("name") for asset in assets} != set(expected_names)
            or any(asset.get("size") != expected_names[asset["name"]].stat().st_size for asset in assets)):
        raise ValueError("draft release did not retain exact producer and asset metadata")
    with tempfile.TemporaryDirectory(prefix="argument-parser-release-verify-") as directory:
        for name in expected_names:
            subprocess.run(["gh", "release", "download", tag, "--repo", REPOSITORY,
                            "--pattern", name, "--dir", directory], check=True, timeout=120,
                           env=environment)
        if inspect(Path(directory) / archive.name, result["archiveSHA256"])["manifest"] != result["manifest"]:
            raise ValueError("draft release asset differs from producer archive")
        if file_digest(Path(directory) / evidence_file.name) != file_digest(evidence_file):
            raise ValueError("draft qualification sidecar differs from producer evidence")
    subprocess.run(["gh", "release", "edit", tag, "--repo", REPOSITORY,
                    "--draft=false"], check=True, timeout=60, env=environment)
    published = json.loads(gh("api", "--hostname", "github.com",
                              f"repos/{REPOSITORY}/releases/tags/{tag}"))
    if (published.get("id") != draft["databaseId"] or published.get("draft") is not False
            or published.get("prerelease") is not True or
            {asset.get("name") for asset in published.get("assets", [])} != set(expected_names)
            or tag_commit(REPOSITORY, tag) != result["manifest"]["producerCommit"]):
        raise ValueError("published layer identity differs from verified draft or qualified producer")


def fetch(lock: Path, destination: Path) -> Path:
    data = json.loads(lock.read_text())
    if data.get("repository") != REPOSITORY or data.get("tag") != release_tag(data["manifest"]):
        raise ValueError("layer release identity does not match lock")
    if destination.exists() or not destination.is_absolute():
        raise ValueError("destination must be a fresh absolute directory")
    release = json.loads(gh("api", "--hostname", "github.com",
                            f"repos/{REPOSITORY}/releases/tags/{data['tag']}"))
    expected_names = {data["asset"], data["evidenceAsset"]}
    if (release.get("draft") is not False or release.get("prerelease") is not True
            or tag_commit(REPOSITORY, data["tag"]) != data["manifest"]["producerCommit"]
            or {asset.get("name") for asset in release.get("assets", [])} != expected_names):
        raise ValueError("published layer release identity differs from lock")
    destination.mkdir(mode=0o700, parents=True)
    environment = os.environ.copy()
    environment["GH_HOST"] = "github.com"
    for name in expected_names:
        subprocess.run(["gh", "release", "download", data["tag"], "--repo", REPOSITORY,
                        "--pattern", name, "--dir", str(destination)], check=True, timeout=120,
                       env=environment)
    archive = destination / data["asset"]
    observed = inspect(archive, data["archiveSHA256"])
    if observed["manifest"] != data["manifest"]:
        raise ValueError("downloaded layer manifest differs from lock")
    evidence_file = destination / data["evidenceAsset"]
    if (file_digest(evidence_file) != data["evidenceSHA256"]
            or json.loads(evidence_file.read_text()).get("archiveSHA256") != data["archiveSHA256"]):
        raise ValueError("downloaded qualification evidence differs from lock")
    after = json.loads(gh("api", "--hostname", "github.com",
                          f"repos/{REPOSITORY}/releases/tags/{data['tag']}"))
    if (after.get("id") != release.get("id") or
            {asset.get("id") for asset in after.get("assets", [])} !=
            {asset.get("id") for asset in release.get("assets", [])} or
            tag_commit(REPOSITORY, data["tag"]) != data["manifest"]["producerCommit"]):
        raise ValueError("layer release identity changed during download")
    (destination / "verified-release.json").write_text(json.dumps({
        "schema": 1, "lockSHA256": file_digest(lock), "archiveSHA256": data["archiveSHA256"],
        "evidenceSHA256": data["evidenceSHA256"], "releaseId": release["id"],
        "assetIds": sorted(asset["id"] for asset in release["assets"]),
        "tagCommit": data["manifest"]["producerCommit"],
        "githubImmutable": release.get("immutable") if isinstance(release.get("immutable"), bool) else None,
    }, indent=2, sort_keys=True) + "\n")
    return archive


def cached_release(lock: Path, cache_root: Path) -> Path:
    """Reuse exact verified release bytes offline; fetch only on a cache miss."""
    data = json.loads(lock.read_text())
    key = file_digest(lock)
    if not cache_root.is_absolute() or cache_root.is_symlink():
        raise ValueError("binary layer cache root must be a real absolute directory")
    cache_root.mkdir(parents=True, exist_ok=True)
    target = cache_root / key
    with (cache_root / ".fetch.lock").open("a+b") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        if not target.exists():
            with tempfile.TemporaryDirectory(prefix="argument-parser-", dir=cache_root) as scratch:
                staged = Path(scratch) / "download"
                fetch(lock, staged)
                staged.rename(target)
        if target.is_symlink() or not target.is_dir():
            raise ValueError("verified binary layer cache path is invalid")
        receipt = json.loads((target / "verified-release.json").read_text())
        archive = target / data["asset"]
        evidence_file = target / data["evidenceAsset"]
        if (receipt.get("lockSHA256") != key or
                receipt.get("archiveSHA256") != data["archiveSHA256"] or
                receipt.get("evidenceSHA256") != data["evidenceSHA256"] or
                receipt.get("tagCommit") != data["manifest"]["producerCommit"] or
                not isinstance(receipt.get("releaseId"), int) or
                not isinstance(receipt.get("assetIds"), list) or
                len(receipt["assetIds"]) != 2 or archive.is_symlink() or evidence_file.is_symlink() or
                inspect(archive, data["archiveSHA256"])["manifest"] != data["manifest"] or
                file_digest(evidence_file) != data["evidenceSHA256"] or
                json.loads(evidence_file.read_text()).get("archiveSHA256") != data["archiveSHA256"]):
            raise ValueError("cached released binary does not match its verified lock and receipt")
        return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    producer = actions.add_parser("produce")
    producer.add_argument("--container-root", type=Path, required=True)
    producer.add_argument("--source", required=True)
    producer.add_argument("--output", type=Path, required=True)
    producer.add_argument("--qualification-dir", type=Path, required=True)
    producer.add_argument("--test-events", type=Path, action="append", required=True)
    checker = actions.add_parser("inspect")
    checker.add_argument("--archive", type=Path, required=True)
    checker.add_argument("--sha256")
    publisher = actions.add_parser("publish")
    publisher.add_argument("--receipt", type=Path, required=True)
    locker = actions.add_parser("write-lock")
    locker.add_argument("--receipt", type=Path, required=True)
    locker.add_argument("--compose-root", type=Path, required=True)
    locker.add_argument("--output", type=Path, required=True)
    consumer = actions.add_parser("fetch")
    consumer.add_argument("--lock", type=Path, required=True)
    consumer.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "produce":
        print(json.dumps(produce(args.container_root, args.output, args.source,
                                 args.qualification_dir, tuple(args.test_events)), sort_keys=True))
    elif args.action == "inspect":
        print(json.dumps(inspect(args.archive, args.sha256), sort_keys=True))
    elif args.action == "publish":
        publish(args.receipt)
    elif args.action == "write-lock":
        print(json.dumps(write_lock(args.receipt, args.compose_root, args.output), sort_keys=True))
    else:
        print(fetch(args.lock, args.destination))


if __name__ == "__main__":
    main()
