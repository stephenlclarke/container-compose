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

"""Fetch one exact published GitHub release asset into a fresh retained directory."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")


def gh(*args: str) -> str:
    environment = os.environ.copy()
    environment["GH_HOST"] = "github.com"
    return subprocess.check_output(["gh", *args], text=True, timeout=60, env=environment)


def tag_commit(repository: str, tag: str) -> str:
    value = json.loads(gh("api", "--hostname", "github.com", f"repos/{repository}/git/ref/tags/{tag}"))["object"]
    for _ in range(3):
        if value.get("type") == "commit" and COMMIT.fullmatch(value.get("sha", "")):
            return value["sha"]
        if value.get("type") != "tag" or not COMMIT.fullmatch(value.get("sha", "")):
            break
        value = json.loads(gh("api", "--hostname", "github.com",
                              f"repos/{repository}/git/tags/{value['sha']}"))["object"]
    raise ValueError("release tag does not resolve to one exact commit")


def release_asset(lock: dict) -> tuple[dict, dict]:
    repo, tag, name = lock["repository"], lock["tag"], lock["asset"]
    release = json.loads(gh("api", "--hostname", "github.com", f"repos/{repo}/releases/tags/{tag}"))
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if (release.get("tag_name") != tag or release.get("draft") is not False
            or tag_commit(repo, tag) != lock["targetCommit"] or len(assets) != 1
            or not isinstance(assets[0].get("size"), int) or assets[0]["size"] <= 0):
        raise ValueError("published release tag or unique asset differs from lock")
    return release, assets[0]


def read_lock(path: Path) -> dict:
    data = json.loads(path.read_text())
    if (data.get("schema") != 1 or not REPOSITORY.fullmatch(data.get("repository", ""))
            or not NAME.fullmatch(data.get("tag", ""))
            or not NAME.fullmatch(data.get("asset", ""))
            or data.get("asset") == "fetch-receipt.json"
            or not COMMIT.fullmatch(data.get("targetCommit", ""))
            or not SHA.fullmatch(data.get("sha256", ""))):
        raise ValueError("release asset lock lacks an exact repository, tag, target, asset or SHA")
    return data


def fetch(lock_path: Path, destination: Path) -> dict:
    lock = read_lock(lock_path)
    if not destination.is_absolute() or destination.exists() or destination.is_symlink():
        raise ValueError("destination must be a fresh absolute directory")
    repo, tag, name = lock["repository"], lock["tag"], lock["asset"]
    release, published_asset = release_asset(lock)
    destination.mkdir(mode=0o700, parents=True)
    environment = os.environ.copy()
    environment["GH_HOST"] = "github.com"
    subprocess.run(["gh", "release", "download", tag, "--repo", repo,
                    "--pattern", name, "--dir", str(destination)], check=True, timeout=300,
                   env=environment)
    asset = destination / name
    if not asset.is_file() or asset.is_symlink() or asset.stat().st_size != published_asset["size"]:
        raise ValueError("downloaded release asset is missing or has the wrong size")
    actual = hashlib.sha256(asset.read_bytes()).hexdigest()
    if actual != lock["sha256"]:
        raise ValueError("downloaded release asset differs from pinned SHA")
    after_release, after_asset = release_asset(lock)
    if after_release["id"] != release["id"] or after_asset["id"] != published_asset["id"]:
        raise ValueError("release or asset identity changed during download")
    receipt = {"schema": 1, "repository": repo, "tag": tag, "targetCommit": lock["targetCommit"],
               "releaseId": release["id"], "assetId": published_asset["id"], "asset": str(asset),
               "sha256": actual, "lockSHA256": hashlib.sha256(lock_path.read_bytes()).hexdigest(),
               "githubImmutable": release.get("immutable") if isinstance(release.get("immutable"), bool) else None}
    (destination / "fetch-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def cached_fetch(lock_path: Path, cache_root: Path) -> dict:
    """Reuse an exact GitHub-verified asset offline against its unchanged lock."""
    lock = read_lock(lock_path)
    if not cache_root.is_absolute() or cache_root.is_symlink():
        raise ValueError("release asset cache must be a real absolute directory")
    cache_root.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(lock_path.read_bytes()).hexdigest()
    target = cache_root / key
    with (cache_root / ".fetch.lock").open("a+b") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        reused = target.exists()
        if not reused:
            with tempfile.TemporaryDirectory(prefix="release-asset-", dir=cache_root) as scratch:
                staged = Path(scratch) / "download"
                fetch(lock_path, staged)
                staged.rename(target)
        if target.is_symlink() or not target.is_dir():
            raise ValueError("verified release cache path is invalid")
        asset = target / lock["asset"]
        receipt_path = target / "fetch-receipt.json"
        if asset.is_symlink() or receipt_path.is_symlink() or not asset.is_file() or not receipt_path.is_file():
            raise ValueError("verified release cache asset or receipt is missing")
        receipt = json.loads(receipt_path.read_text())
        if (receipt.get("schema") != 1 or receipt.get("lockSHA256") != key
                or receipt.get("repository") != lock["repository"]
                or receipt.get("tag") != lock["tag"]
                or receipt.get("targetCommit") != lock["targetCommit"]
                or receipt.get("sha256") != lock["sha256"]
                or not isinstance(receipt.get("releaseId"), int)
                or not isinstance(receipt.get("assetId"), int)
                or hashlib.sha256(asset.read_bytes()).hexdigest() != lock["sha256"]):
            raise ValueError("offline release cache differs from the verified lock")
        return {**receipt, "asset": str(asset), "offlineCacheReuse": reused}


def publish_assets(repository: str, tag: str, target_commit: str, title: str,
                   notes: str, assets: tuple[Path, ...]) -> dict:
    """Publish a new prerelease only after verifying every draft asset byte."""
    if (not REPOSITORY.fullmatch(repository) or not NAME.fullmatch(tag)
            or not COMMIT.fullmatch(target_commit) or not assets
            or len({path.name for path in assets}) != len(assets)
            or any(not path.is_file() or path.is_symlink() or not NAME.fullmatch(path.name)
                   for path in assets)):
        raise ValueError("release publication requires exact repository, tag, commit and unique files")
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in assets}
    environment = os.environ.copy()
    environment["GH_HOST"] = "github.com"
    existing = subprocess.run(["gh", "release", "view", tag, "--repo", repository,
                               "--json", "databaseId"], capture_output=True, text=True,
                              timeout=30, env=environment)
    if existing.returncode == 0 or existing.stderr.strip() != "release not found":
        raise ValueError("release already exists or its absence could not be proved")
    target = json.loads(gh("api", "--hostname", "github.com",
                           f"repos/{repository}/git/commits/{target_commit}"))
    if target.get("sha") != target_commit:
        raise ValueError("release target commit is not present in the owning repository")
    reference = subprocess.run(["gh", "api", "--hostname", "github.com",
                                f"repos/{repository}/git/ref/tags/{tag}"], capture_output=True,
                               text=True, timeout=30, env=environment)
    if reference.returncode == 0:
        if tag_commit(repository, tag) != target_commit:
            raise ValueError("pre-pushed release tag points to a different commit")
    elif "http 404" not in reference.stderr.lower():
        raise ValueError("release tag absence could not be proved")
    subprocess.run(["gh", "release", "create", tag, "--repo", repository,
                    "--target", target_commit, "--prerelease", "--latest=false", "--draft",
                    "--title", title, "--notes", notes,
                    *(str(path) for path in assets)], check=True, timeout=300, env=environment)
    draft = json.loads(gh("release", "view", tag, "--repo", repository,
                          "--json", "databaseId,tagName,targetCommitish,isDraft,isPrerelease,assets"))
    named = {path.name: path for path in assets}
    draft_assets = draft.get("assets", [])
    if (draft.get("isDraft") is not True or draft.get("isPrerelease") is not True or
            draft.get("tagName") != tag or draft.get("targetCommitish") != target_commit or
            not isinstance(draft.get("databaseId"), int) or
            len(draft_assets) != len(named) or
            {item.get("name") for item in draft_assets} != set(named) or
            any(item.get("size") != named[item["name"]].stat().st_size for item in draft_assets)):
        raise ValueError("draft release lost exact target or asset metadata")
    with tempfile.TemporaryDirectory(prefix="release-assets-verify-") as temporary:
        for name in named:
            subprocess.run(["gh", "release", "download", tag, "--repo", repository,
                            "--pattern", name, "--dir", temporary], check=True,
                           timeout=300, env=environment)
            if hashlib.sha256((Path(temporary) / name).read_bytes()).hexdigest() != hashes[name]:
                raise ValueError("draft release bytes differ from the qualified producer")
    subprocess.run(["gh", "release", "edit", tag, "--repo", repository,
                    "--draft=false"], check=True, timeout=60, env=environment)
    release = json.loads(gh("api", "--hostname", "github.com",
                            f"repos/{repository}/releases/tags/{tag}"))
    published = {item.get("name"): item for item in release.get("assets", [])}
    if (release.get("id") != draft["databaseId"] or release.get("draft") is not False or
            release.get("prerelease") is not True or release.get("tag_name") != tag or
            set(published) != set(named) or tag_commit(repository, tag) != target_commit):
        raise ValueError("published release differs from verified draft")
    return {"schema": 1, "repository": repository, "tag": tag,
            "targetCommit": target_commit, "releaseId": release["id"],
            "assets": {name: {"sha256": hashes[name], "assetId": published[name]["id"]}
                       for name in sorted(named)},
            "githubImmutable": release.get("immutable") if isinstance(release.get("immutable"), bool) else None}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fetch", choices=["fetch"])
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(fetch(args.lock, args.destination), sort_keys=True))


if __name__ == "__main__":
    main()
