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
import stat
import subprocess
import tempfile
import uuid

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


def _validate_scratch(scratch: Path) -> Path:
    if not scratch.is_absolute() or scratch.is_symlink() or not scratch.is_dir():
        raise ValueError("resumable publication requires an existing real absolute scratch directory")
    resolved = scratch.resolve(strict=True)
    if resolved != Path(os.path.abspath(scratch)):
        raise ValueError("resumable publication scratch path must contain no symlink components")
    info = scratch.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("resumable publication scratch directory has unsafe ownership or mode")
    return resolved


def _validate_journal_root(journal_root: Path) -> Path:
    if (not journal_root.is_absolute() or journal_root.is_symlink()
            or not journal_root.is_dir()):
        raise ValueError("resumable publication requires an existing real absolute journal root")
    resolved = journal_root.resolve(strict=True)
    if resolved != Path(os.path.abspath(journal_root)):
        raise ValueError("resumable publication journal root must contain no symlink components")
    info = journal_root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("resumable publication journal root has unsafe ownership or mode")
    return resolved


def publication_journal_path(journal_root: Path, repository: str, tag: str,
                             owner: str) -> Path:
    """Return the stable journal path for one explicit resumable publication owner."""
    root = _validate_journal_root(journal_root)
    if (not REPOSITORY.fullmatch(repository) or not NAME.fullmatch(tag)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", owner)):
        raise ValueError("invalid resumable publication identity")
    key = hashlib.sha256(f"{repository}\n{tag}\n{owner}".encode()).hexdigest()
    return root / f"release-publication-{key}.json"


def _atomic_journal(path: Path, value: dict) -> None:
    if path.is_symlink():
        raise ValueError("resumable publication journal is a symbolic link")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".release-publication-", delete=False) as stream:
        temporary = Path(stream.name)
        os.fchmod(stream.fileno(), 0o600)
        stream.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _publication_lock(path: Path) -> int:
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    info = os.fstat(descriptor)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or info.st_mode & 0o022):
        os.close(descriptor)
        raise ValueError("resumable publication lock is unsafe")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(descriptor)
        raise ValueError("resumable publication is already active")
    return descriptor


def _assets_inventory(assets: tuple[Path, ...]) -> tuple[list[dict], dict[str, Path]]:
    if (not assets or len({path.name for path in assets}) != len(assets)
            or any(path.is_symlink() or not path.is_file() or not NAME.fullmatch(path.name)
                   for path in assets)):
        raise ValueError("release publication requires unique regular asset files")
    rows = []
    paths = {}
    for path in assets:
        content = path.read_bytes()
        if not content:
            raise ValueError("release publication assets must not be empty")
        rows.append({"name": path.name, "size": len(content),
                     "sha256": hashlib.sha256(content).hexdigest()})
        paths[path.name] = path
    return sorted(rows, key=lambda row: row["name"]), paths


def _read_journal(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError("resumable publication journal is missing or unsafe")
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError("resumable publication journal ownership or mode changed")
    value = json.loads(path.read_text())
    if (value.get("schema") != 1 or not isinstance(value.get("intent"), dict)
            or not isinstance(value.get("ownershipMarker"), str)
            or not re.fullmatch(r"<!-- container-family-publish-owner:[0-9a-f]{32} -->",
                                value["ownershipMarker"])
            or not isinstance(value.get("assetIds"), dict)
            or value.get("state") not in {"intent", "draft", "exposure-intent", "exposed", "published"}
            or not isinstance(value.get("notesWithMarker"), str)
            or value["notesWithMarker"] != value["intent"].get("notes", "")
            + "\n\n" + value["ownershipMarker"]
            or (value.get("releaseId") is not None and type(value["releaseId"]) is not int)
            or any(not isinstance(name, str) or type(asset_id) is not int
                   for name, asset_id in value["assetIds"].items())):
        raise ValueError("resumable publication journal is malformed")
    inventory = value["intent"].get("assets")
    if (not isinstance(inventory, list)
            or set(value["assetIds"]) - {row.get("name") for row in inventory
                                         if isinstance(row, dict)}):
        raise ValueError("resumable publication journal asset identity is malformed")
    return value


def _release_view(repository: str, tag: str) -> dict:
    view = json.loads(gh("release", "view", tag, "--repo", repository,
                         "--json", "databaseId"))
    release_id = view.get("databaseId")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("GitHub release view did not provide a valid database ID")
    release = json.loads(gh("api", "--hostname", "github.com",
                            f"repos/{repository}/releases/{release_id}"))
    body = release.get("body")
    if (type(release.get("id")) is not int or release["id"] != release_id
            or not isinstance(release.get("tag_name"), str) or release["tag_name"] != tag
            or not isinstance(release.get("target_commitish"), str)
            or type(release.get("draft")) is not bool
            or type(release.get("prerelease")) is not bool
            or not isinstance(release.get("name"), str)
            or (body is not None and not isinstance(body, str))
            or not isinstance(release.get("assets"), list)):
        raise ValueError("GitHub REST release identity is incomplete")
    assets = []
    for item in release["assets"]:
        if (not isinstance(item, dict) or type(item.get("id")) is not int
                or not isinstance(item.get("name"), str) or type(item.get("size")) is not int
                or not isinstance(item.get("state"), str)):
            raise ValueError("GitHub REST release asset identity is incomplete")
        assets.append({"id": item["id"], "name": item["name"], "size": item["size"],
                       "state": item["state"]})
    if (len({item["id"] for item in assets}) != len(assets)
            or len({item["name"] for item in assets}) != len(assets)):
        raise ValueError("GitHub REST release contains duplicate asset identities")
    return {"databaseId": release["id"], "tagName": release["tag_name"],
            "targetCommitish": release["target_commitish"], "isDraft": release["draft"],
            "isPrerelease": release["prerelease"], "title": release["name"],
            "body": body or "", "assets": assets}


def _check_owned_release(release: dict, intent: dict, journal: dict) -> None:
    if (release.get("tagName") != intent["tag"]
            or release.get("targetCommitish") != intent["targetCommit"]
            or release.get("title") != intent["title"]
            or release.get("body") != journal["notesWithMarker"]
            or release.get("isPrerelease") is not True
            or type(release.get("isDraft")) is not bool
            or type(release.get("databaseId")) is not int):
        raise ValueError("existing release is not this exact owned prerelease")
    release_id = journal.get("releaseId")
    if release_id is not None and release["databaseId"] != release_id:
        raise ValueError("owned release identity changed")


def _validate_draft_assets(release: dict, journal: dict, scratch: Path, *,
                           require_all: bool) -> dict[str, int]:
    expected = {row["name"]: row for row in journal["intent"]["assets"]}
    observed: dict[str, int] = {}
    for item in release.get("assets", []):
        name = item.get("name")
        if (name not in expected or name in observed or type(item.get("id")) is not int
                or item.get("size") != expected[name]["size"] or item.get("state") != "uploaded"):
            raise ValueError("draft release contains unexpected or changed asset metadata")
        previous_id = journal["assetIds"].get(name)
        if previous_id is not None and previous_id != item["id"]:
            raise ValueError("owned release asset identity changed")
        observed[name] = item["id"]
    if require_all and set(observed) != set(expected):
        raise ValueError("owned published release is missing an asset")
    for name in sorted(observed):
        with tempfile.TemporaryDirectory(prefix="release-asset-check-", dir=scratch) as temporary:
            subprocess.run(["gh", "release", "download", journal["intent"]["tag"],
                            "--repo", journal["intent"]["repository"], "--pattern", name,
                            "--dir", temporary], check=True, timeout=300,
                           env={**os.environ, "GH_HOST": "github.com"})
            downloaded = Path(temporary) / name
            row = expected[name]
            if (downloaded.is_symlink() or not downloaded.is_file()
                    or downloaded.stat().st_size != row["size"]
                    or hashlib.sha256(downloaded.read_bytes()).hexdigest() != row["sha256"]):
                raise ValueError("downloaded draft asset differs from the prepared producer bytes")
    return observed


def _repair_starter_assets(repository: str, release: dict, journal: dict, journal_path: Path,
                           environment: dict[str, str]) -> dict:
    """Remove only unacknowledged, empty starter assets from an exact owned draft."""
    expected = {row["name"] for row in journal["intent"]["assets"]}
    journal.setdefault("repairs", [])
    pending = journal.get("repairIntent")
    for item in release["assets"]:
        if item["name"] not in expected:
            raise ValueError("draft release contains an unexpected asset")
    starters = [item for item in release["assets"] if item["state"] == "starter"]
    if release["isDraft"] is not True:
        if pending is not None or starters:
            raise ValueError("incomplete release assets cannot be repaired after exposure")
        return release
    if pending is not None:
        if (pending.get("releaseId") != release["databaseId"]
                or pending.get("assetName") not in expected
                or type(pending.get("assetId")) is not int):
            raise ValueError("incomplete asset repair intent differs from the owned release")
        match = [item for item in release["assets"] if item["id"] == pending["assetId"]]
        if match:
            item = match[0]
            if (item["name"] != pending["assetName"] or item["state"] != "starter"
                    or item["size"] != 0 or item["id"] in journal["assetIds"].values()):
                raise ValueError("incomplete asset repair target changed or was acknowledged")
            subprocess.run(["gh", "api", "--hostname", "github.com", "-X", "DELETE",
                            f"repos/{repository}/releases/assets/{pending['assetId']}"],
                           check=True, timeout=30, env=environment)
        after = _release_view(repository, journal["intent"]["tag"])
        if (any(item["id"] == pending["assetId"] for item in after["assets"])
                or any(item["name"] == pending["assetName"] for item in after["assets"])):
            raise ValueError("incomplete owned starter asset did not disappear")
        journal["repairs"].append({**pending, "state": "removed"})
        journal.pop("repairIntent")
        _atomic_journal(journal_path, journal)
        release = after
        starters = [item for item in release["assets"] if item["state"] == "starter"]
    for item in starters:
        if (item["name"] not in expected or item["size"] != 0 or item["id"] <= 0
                or item["id"] in journal["assetIds"].values()):
            raise ValueError("draft contains a starter asset that is not safe to repair")
        journal["repairIntent"] = {"releaseId": release["databaseId"],
                                   "assetId": item["id"], "assetName": item["name"],
                                   "observedState": item["state"], "observedSize": item["size"]}
        _atomic_journal(journal_path, journal)
        subprocess.run(["gh", "api", "--hostname", "github.com", "-X", "DELETE",
                        f"repos/{repository}/releases/assets/{item['id']}"],
                       check=True, timeout=30, env=environment)
        after = _release_view(repository, journal["intent"]["tag"])
        if (any(candidate["id"] == item["id"] for candidate in after["assets"])
                or any(candidate["name"] == item["name"] for candidate in after["assets"])):
            raise ValueError("incomplete owned starter asset did not disappear")
        journal["repairs"].append({**journal.pop("repairIntent"), "state": "removed"})
        _atomic_journal(journal_path, journal)
        release = after
    return release


def _publish_assets_resumable(repository: str, tag: str, target_commit: str, title: str,
                              notes: str, assets: tuple[Path, ...], *, scratch: Path,
                              journal_root: Path, owner: str) -> dict:
    scratch = _validate_scratch(scratch)
    journal_root = _validate_journal_root(journal_root)
    if (not REPOSITORY.fullmatch(repository) or not NAME.fullmatch(tag)
            or not COMMIT.fullmatch(target_commit)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", owner)
            or not isinstance(title, str) or not isinstance(notes, str)):
        raise ValueError("resumable publication requires exact repository, tag, commit and owner")
    inventory, named = _assets_inventory(assets)
    path = publication_journal_path(journal_root, repository, tag, owner)
    lock_path = path.with_suffix(".lock")
    descriptor = _publication_lock(lock_path)
    try:
        intent = {"schema": 1, "owner": owner, "repository": repository, "tag": tag,
                  "targetCommit": target_commit, "title": title, "notes": notes,
                  "assets": inventory}
        if path.exists() or path.is_symlink():
            journal = _read_journal(path)
            if journal["intent"] != intent:
                raise ValueError("resumable publication inputs differ from the durable intent")
        else:
            marker_token = uuid.uuid4().hex
            marker = f"<!-- container-family-publish-owner:{marker_token} -->"
            journal = {"schema": 1, "intent": intent, "ownershipMarker": marker,
                       "notesWithMarker": notes + "\n\n" + marker,
                       "state": "intent", "releaseId": None, "assetIds": {}}
            _atomic_journal(path, journal)

        environment = {**os.environ, "GH_HOST": "github.com"}
        target = json.loads(gh("api", "--hostname", "github.com",
                               f"repos/{repository}/git/commits/{target_commit}"))
        if target.get("sha") != target_commit:
            raise ValueError("release target commit is not present in the owning repository")
        reference = subprocess.run(["gh", "api", "--hostname", "github.com",
                                    f"repos/{repository}/git/ref/tags/{tag}"],
                                   capture_output=True, text=True, timeout=30, env=environment)
        if reference.returncode == 0:
            if tag_commit(repository, tag) != target_commit:
                raise ValueError("pre-pushed release tag points to a different commit")
        elif "http 404" not in reference.stderr.lower():
            raise ValueError("release tag absence could not be proved")

        existing = subprocess.run(["gh", "release", "view", tag, "--repo", repository,
                                   "--json", "databaseId"], capture_output=True, text=True,
                                  timeout=30, env=environment)
        if existing.returncode == 0:
            release = _release_view(repository, tag)
            _check_owned_release(release, intent, journal)
        elif existing.stderr.strip() == "release not found":
            if journal.get("releaseId") is not None:
                raise ValueError("previously owned release is missing; refusing replacement creation")
            subprocess.run(["gh", "release", "create", tag, "--repo", repository,
                            "--target", target_commit, "--prerelease", "--latest=false", "--draft",
                            "--title", title, "--notes", journal["notesWithMarker"]],
                           check=True, timeout=300, env=environment)
            release = _release_view(repository, tag)
            _check_owned_release(release, intent, journal)
        else:
            raise ValueError("release existence could not be proved")

        journal["releaseId"] = release["databaseId"]
        release = _repair_starter_assets(repository, release, journal, path, environment)
        observed = _validate_draft_assets(release, journal, scratch,
                                          require_all=release["isDraft"] is False)
        journal["assetIds"].update(observed)
        journal["state"] = "draft" if release["isDraft"] else "exposed"
        _atomic_journal(path, journal)

        if release["isDraft"]:
            expected = {row["name"] for row in inventory}
            for name in sorted(expected - set(observed)):
                source = named[name]
                content = source.read_bytes()
                row = next(item for item in inventory if item["name"] == name)
                if (len(content) != row["size"] or
                        hashlib.sha256(content).hexdigest() != row["sha256"]):
                    raise ValueError("prepared producer asset changed before upload")
                subprocess.run(["gh", "release", "upload", tag, str(source), "--repo", repository],
                               check=True, timeout=300, env=environment)
                release = _release_view(repository, tag)
                _check_owned_release(release, intent, journal)
                release = _repair_starter_assets(repository, release, journal, path, environment)
                observed = _validate_draft_assets(release, journal, scratch, require_all=False)
                journal["assetIds"].update(observed)
                journal["releaseId"] = release["databaseId"]
                journal["state"] = "draft"
                _atomic_journal(path, journal)

            release = _release_view(repository, tag)
            _check_owned_release(release, intent, journal)
            release = _repair_starter_assets(repository, release, journal, path, environment)
            observed = _validate_draft_assets(release, journal, scratch, require_all=True)
            journal["assetIds"].update(observed)
            journal["state"] = "exposure-intent"
            _atomic_journal(path, journal)
            subprocess.run(["gh", "release", "edit", tag, "--repo", repository,
                            "--draft=false"], check=True, timeout=60, env=environment)

        release_api = json.loads(gh("api", "--hostname", "github.com",
                                    f"repos/{repository}/releases/tags/{tag}"))
        published = {item.get("name"): item for item in release_api.get("assets", [])}
        if (release_api.get("id") != journal["releaseId"]
                or release_api.get("draft") is not False
                or release_api.get("prerelease") is not True
                or release_api.get("tag_name") != tag
                or release_api.get("target_commitish") != target_commit
                or set(published) != {row["name"] for row in inventory}
                or any(type(published[row["name"]].get("id")) is not int
                       or published[row["name"]].get("size") != row["size"]
                       or published[row["name"]]["id"] != journal["assetIds"].get(row["name"])
                       for row in inventory)
                or tag_commit(repository, tag) != target_commit):
            raise ValueError("exposed release differs from the exact owned publication")
        for item in inventory:
            if published[item["name"]]["id"] != journal["assetIds"].get(item["name"]):
                raise ValueError("published asset identity changed")
        final_view = _release_view(repository, tag)
        _check_owned_release(final_view, intent, journal)
        _validate_draft_assets(final_view, journal, scratch, require_all=True)
        journal["state"] = "published"
        _atomic_journal(path, journal)
        return {"schema": 1, "repository": repository, "tag": tag,
                "targetCommit": target_commit, "releaseId": release_api["id"],
                "assets": {row["name"]: {"sha256": row["sha256"],
                                           "assetId": published[row["name"]]["id"]}
                           for row in inventory},
                "githubImmutable": release_api.get("immutable")
                if isinstance(release_api.get("immutable"), bool) else None,
                "publicationJournal": str(path)}
    finally:
        os.close(descriptor)


def publish_assets(repository: str, tag: str, target_commit: str, title: str,
                   notes: str, assets: tuple[Path, ...], *, resume: bool = False,
                   scratch: Path | None = None, journal_root: Path | None = None,
                   owner: str | None = None) -> dict:
    """Publish exact asset bytes; opt-in resume uses durable journal and explicit scratch roots."""
    if resume:
        if scratch is None or journal_root is None or owner is None:
            raise ValueError("resumable publication requires explicit scratch, journal root and owner")
        return _publish_assets_resumable(repository, tag, target_commit, title, notes, assets,
                                         scratch=scratch, journal_root=journal_root, owner=owner)
    if scratch is not None or journal_root is not None or owner is not None:
        raise ValueError("scratch, journal root and owner are only valid with resumable publication")
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
