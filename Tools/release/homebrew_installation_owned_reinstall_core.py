#!/usr/bin/env python3
# Copyright 2026 devcontainer project authors.
# Licensed under the Apache License, Version 2.0.
"""Run one Homebrew formula test while preserving an installed baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid

TESTING = Path(globals().get("AUTHENTICATED_TESTING_ROOT", Path(__file__).parents[1] / "testing"))
sys.path.insert(0, str(TESTING))
from host_runtime import HostGuard, cancellation, runtime_lease  # noqa: E402


SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
FORMULA_SHA = re.compile(r'^  sha256 "([0-9a-f]{64})"$', re.MULTILINE)
TAP = re.compile(r"stephenlclarke/devcontainer-release-ci-[1-9][0-9]*")
FORMULAE = {"devcontainer", "devcontainer-current"}
SERVICE_LABELS = {
    "devcontainer": "homebrew.mxcl.devcontainer",
    "devcontainer-current": "homebrew.mxcl.devcontainer-current",
}
SSD_ROOT = Path("/Volumes/SSD")
INTERNAL_ROOT = Path.home() / "Library/Application Support/ContainerFamily/retained"
SSD_IDENTITY = INTERNAL_ROOT / "workflow/ssd-volume.uuid"


class InstallationError(RuntimeError):
    """A fail-closed boundary or restoration error."""


def digest(path: Path) -> str:
    """Hash a file in bounded memory."""
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def private_file(path: Path, limit: int) -> bytes:
    """Read a canonical user-owned regular file without following aliases."""
    if not path.is_absolute() or path.is_symlink() or path.resolve() != path:
        raise InstallationError("input file path is aliased")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > limit):
            raise InstallationError("input file is not a bounded owned regular file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise InstallationError("input file exceeds its size limit")
    return data


def validate_context(context_path: Path, formula_path: Path, lane: str,
                     source_sha: str, version: str, template_path: Path,
                     formula_bytes: bytes | None = None) -> dict:
    """Bind the rendered, non-executable formula to the requested release context."""
    if lane not in {"stable", "current"} or not SHA.fullmatch(source_sha):
        raise InstallationError("unsupported lane or invalid source commit")
    if not VERSION.fullmatch(version):
        raise InstallationError("invalid expected product version")
    context = json.loads(private_file(context_path, 16384))
    fields = {"asset", "commit", "formulaVersion", "lane", "productVersion", "releaseTag"}
    if not isinstance(context, dict) or set(context) != fields:
        raise InstallationError("package context has an unsupported schema")
    commit = source_sha.lower()
    if context["lane"] != lane or context["commit"] != commit or context["productVersion"] != version:
        raise InstallationError("package context differs from the selected source and lane")
    if lane == "stable":
        if (context["formulaVersion"] != version or context["releaseTag"] != version
                or context["asset"] != "devcontainer-release-arm64.tar.gz"):
            raise InstallationError("stable package context is inconsistent")
        formula_class = "Devcontainer"
        url = f"https://github.com/stephenlclarke/devcontainer/releases/download/{version}/{context['asset']}"
        declarations = ("", "\n")
    else:
        match = re.fullmatch(r"current\.([1-9][0-9]*)\.([0-9a-f]{12})", context["formulaVersion"])
        if (match is None or match.group(2) != commit[:12] or context["releaseTag"] != "current"
                or context["asset"] != f"devcontainer-current-{commit[:12]}-arm64.tar.gz"):
            raise InstallationError("Current package context is inconsistent")
        formula_class = "DevcontainerCurrent"
        url = f"https://github.com/stephenlclarke/devcontainer/releases/download/current/{context['asset']}"
        declarations = (f'  version "{context["formulaVersion"]}"\n',
                        '  conflicts_with "devcontainer", because: "both install devcontainer commands"\n\n')
    formula = (formula_bytes if formula_bytes is not None else
               private_file(formula_path, 1024 * 1024)).decode("utf-8")
    match = FORMULA_SHA.search(formula)
    if match is None:
        raise InstallationError("formula has no valid archive digest")
    expected = private_file(template_path, 1024 * 1024).decode("utf-8")
    substitutions = {
        "@FORMULA_CLASS@": formula_class,
        "@PRODUCT_VERSION@": version,
        "@URL@": url,
        "@SHA256@": match.group(1),
        "@VERSION_DECLARATION@": declarations[0],
        "@CONFLICT_DECLARATION@": declarations[1],
    }
    for name, value in substitutions.items():
        expected = expected.replace(name, value)
    if formula != expected:
        raise InstallationError("formula differs from the maintained release template")
    return context


def validate_ssd(expected_uuid: str, diskutil_plist: bytes) -> None:
    """Require the mounted SSD identity enrolled in internal retained storage."""
    value = plistlib.loads(diskutil_plist)
    if (value.get("MountPoint") != str(SSD_ROOT) or value.get("Internal") is not False
            or str(value.get("VolumeUUID", "")).upper() != expected_uuid.upper()):
        raise InstallationError("mounted SSD differs from the enrolled volume")


def storage_preflight(scratch: Path, retained_root: Path) -> None:
    """Authenticate internal retention and SSD storage before any backup copy."""
    for path in (Path.home(), INTERNAL_ROOT, SSD_ROOT, scratch.parent, retained_root):
        if not path.is_absolute() or path.is_symlink() or path.resolve() != path or not path.is_dir():
            raise InstallationError("required storage parent is absent or aliased")
    home_device = Path.home().stat().st_dev
    if (INTERNAL_ROOT.stat().st_dev != home_device or retained_root.stat().st_dev != home_device
            or retained_root.stat().st_uid != os.getuid() or retained_root.stat().st_mode & 0o077
            or SSD_ROOT.stat().st_dev == home_device or not SSD_ROOT.is_mount()
            or scratch.parent != SSD_ROOT / "cf/bazel/tmp"
            or scratch.parent.stat().st_dev != SSD_ROOT.stat().st_dev
            or scratch.parent.stat().st_uid != os.getuid() or scratch.exists()):
        raise InstallationError("storage does not match private-retention and fresh-SSD policy")
    expected = private_file(SSD_IDENTITY, 128).decode("ascii").strip().upper()
    if re.fullmatch(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", expected) is None:
        raise InstallationError("enrolled SSD identity is malformed")
    result = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(SSD_ROOT)],
                            check=True, capture_output=True, timeout=10,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    validate_ssd(expected, result.stdout)


def tree_inventory(root: Path) -> dict[str, dict[str, int | str]]:
    """Describe a keg using relative paths, modes, sizes, and regular-file hashes."""
    if root.is_symlink() or not root.is_dir() or root.resolve() != root:
        raise InstallationError("formula keg root is unsafe")
    rows: dict[str, dict[str, int | str]] = {
        ".": {"kind": "directory", "mode": stat.S_IMODE(root.stat().st_mode)}
    }
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        name = path.relative_to(root).as_posix()
        if info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode):
            raise InstallationError("formula keg contains an aliased or unowned path")
        if stat.S_ISDIR(info.st_mode):
            rows[name] = {"kind": "directory", "mode": stat.S_IMODE(info.st_mode)}
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            rows[name] = {"kind": "file", "mode": stat.S_IMODE(info.st_mode),
                          "size": info.st_size, "sha256": digest(path)}
        else:
            raise InstallationError("formula keg contains a hard link or special file")
    return rows


def inventory_sha(value: object) -> str:
    """Hash a stable JSON inventory."""
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def canonical_directory(path: Path, root: Path) -> Path:
    """Require a physical owned directory beneath its expected root."""
    if path.is_symlink() or path.resolve() != path or not path.is_dir() or not path.is_relative_to(root):
        raise InstallationError("Homebrew directory is outside its owned root")
    if path.stat().st_uid != os.getuid():
        raise InstallationError("Homebrew directory is not owned by the current user")
    return path


def safe_parent(path: Path, root: Path) -> None:
    """Check every existing parent against symlink and containment escapes."""
    if not path.is_relative_to(root):
        raise InstallationError("affected path escapes Homebrew prefix")
    current = root
    for part in path.relative_to(root).parts[:-1]:
        current = current / part
        if current.exists() and (current.is_symlink() or current.resolve() != current or not current.is_dir()):
            raise InstallationError("affected path has an unsafe parent")


def symlink_snapshot(prefix: Path, keg_paths: dict[str, list[Path]]) -> dict[str, dict[str, str | int]]:
    """Capture opt and exported bin/man links that resolve into affected kegs."""
    roots = [path.resolve() for values in keg_paths.values() for path in values]
    affected_opt = {prefix / "opt" / name for name in FORMULAE}
    candidates = set(affected_opt)
    for parent in (prefix / "bin", prefix / "share" / "man"):
        if parent.is_dir() and not parent.is_symlink():
            for base, dirs, files in os.walk(parent, followlinks=False):
                base_path = Path(base)
                symlink_dirs = [name for name in dirs if (base_path / name).is_symlink()]
                candidates.update(base_path / name for name in symlink_dirs)
                dirs[:] = [name for name in dirs if name not in symlink_dirs]
                candidates.update(base_path / name for name in files)
    result = {}
    for path in sorted(candidates):
        if not path.is_symlink():
            continue
        safe_parent(path, prefix)
        target = os.readlink(path)
        try:
            resolved = path.resolve(strict=False)
        except (OSError, RuntimeError) as error:
            raise InstallationError("Homebrew link cannot be resolved") from error
        if any(resolved == root or root in resolved.parents for root in roots) or path in affected_opt:
            info = path.lstat()
            result[str(path)] = {"target": target, "mode": stat.S_IMODE(info.st_mode)}
    return result


def copy_keg(source: Path, destination: Path, expected: dict[str, dict[str, int | str]]) -> None:
    """Copy a verified regular-file keg into a new destination."""
    if destination.exists() or destination.is_symlink():
        raise InstallationError("keg destination already exists")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copytree(source, destination, copy_function=shutil.copy2, symlinks=False)
    if tree_inventory(destination) != expected:
        raise InstallationError("copied Homebrew keg differs from its authenticated inventory")


def sync_tree(root: Path) -> None:
    """Flush every retained file and directory before authorizing mutation."""
    for path in sorted(root.rglob("*"), reverse=True):
        if path.is_file() and not path.is_symlink():
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        elif path.is_dir() and not path.is_symlink():
            descriptor = os.open(path, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    descriptor = os.open(root, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class CommandRunner:
    """Invoke Homebrew with a bounded, reduced environment."""

    def __init__(self):
        executable = shutil.which("brew")
        if not executable:
            raise InstallationError("Homebrew executable is unavailable")
        self.executable = Path(executable).resolve(strict=True)
        if self.executable not in {Path("/opt/homebrew/bin/brew"), Path("/usr/local/bin/brew")}:
            raise InstallationError("Homebrew executable is outside supported installations")

    def __call__(self, *arguments: str, timeout: int = 900) -> str:
        env = {"PATH": f"{self.executable.parent}:/usr/bin:/bin", "HOME": str(Path.home()),
               "CI": "1", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
               "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "LC_ALL": "C"}
        try:
            result = subprocess.run([str(self.executable), *arguments], check=True, capture_output=True,
                                    text=True, timeout=timeout, env=env)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
            raise InstallationError("bounded Homebrew command failed") from error
        return result.stdout.strip()


class LaunchdServices:
    """Quiesce only the two exact formula-owned user launchd labels."""

    def __init__(self, launchd=None, *, home: Path | None = None, process_runtime=None):
        self.home = home or Path.home()
        if launchd is None:
            import service_switch
            launchd = service_switch.Launchd()
            self.canonical_file = service_switch.canonical_file
        else:
            self.canonical_file = lambda path: path.read_bytes()
        if process_runtime is None:
            import runtime_services
            process_runtime = runtime_services
        self.launchd = launchd
        self.process_runtime = process_runtime
        self.prior: list[dict] = []
        self.absent: list[str] = []
        self.captured_processes: list[dict] = []

    def capture(self, prefix: Path, kegs: dict[str, list[Path]]) -> list[dict]:
        labels = self.launchd.labels()
        for formula, label in SERVICE_LABELS.items():
            if label not in labels:
                self.absent.append(label)
                continue
            job = self.launchd.inspect(label)
            if job is None:
                raise InstallationError("Homebrew launchd inventory changed during capture")
            path = Path(job["path"])
            launch_agents = self.home / "Library/LaunchAgents"
            if (not launch_agents.is_dir() or launch_agents.is_symlink()
                    or launch_agents.resolve() != launch_agents
                    or launch_agents.stat().st_uid != os.getuid()
                    or not path.is_relative_to(launch_agents) or path.name != label + ".plist"
                    or path.is_symlink() or path.resolve() != path):
                raise InstallationError("Homebrew launchd identity is not an owned launch agent")
            payload = self.canonical_file(path)
            definition = plistlib.loads(payload)
            arguments = definition.get("ProgramArguments", [])
            program = definition.get("Program") or (arguments[0] if arguments else None)
            if definition.get("Label") != label or program != job["program"]:
                raise InstallationError("Homebrew launchd plist differs from its loaded identity")
            if not isinstance(program, str) or not Path(program).is_absolute():
                raise InstallationError("Homebrew launchd program is not an absolute executable")
            target = Path(program).resolve(strict=True)
            if (target.name != "devcontainer-engine" or target.parent.name != "bin"
                    or not any(target.is_relative_to(keg) for keg in kegs.get(formula, []))):
                raise InstallationError("Homebrew launchd program is outside the captured keg")
            item = {**job, "payload": payload, "sha256": hashlib.sha256(payload).hexdigest(),
                    "formula": formula, "mode": stat.S_IMODE(path.stat().st_mode),
                    "pid": self.launchd.process_id(label)}
            self.prior.append(item)
        self.captured_processes = self.process_runtime.capture_owned_processes(self.launchd, self.prior)
        self._reject_active_guest_processes()
        return self.prior

    def stop(self) -> None:
        current_processes = self.process_runtime.capture_owned_processes(self.launchd, self.prior)
        if current_processes != self.captured_processes:
            raise InstallationError("Homebrew service process tree changed after backup capture")
        self._reject_active_guest_processes()
        for item in self.prior:
            current = self.launchd.inspect(item["label"])
            if current != {key: item[key] for key in ("label", "path", "program")}:
                raise InstallationError("Homebrew launchd registration changed before quiesce")
            if self.launchd.process_id(item["label"]) != item["pid"]:
                raise InstallationError("Homebrew launchd process identity changed before quiesce")
            self.launchd.bootout(item["label"])
        try:
            self.process_runtime.wait_stopped(
                self._require_stopped, seconds=15)
        except (ValueError, TimeoutError) as error:
            raise InstallationError("captured Homebrew service process survived bootout") from error

    def _require_stopped(self) -> None:
        """Bootout acknowledgement precedes asynchronous registration removal."""
        for item in self.prior:
            current = self.launchd.inspect(item["label"])
            if current is not None:
                if current != {key: item[key] for key in ("label", "path", "program")}:
                    raise ValueError("Homebrew launchd registration changed during quiesce")
                raise self.process_runtime.ProcessSurvivors("captured Homebrew registration remains loaded")
        self.process_runtime.require_captured_processes_stopped(
            self.launchd, self.prior, self.captured_processes)

    def _reject_active_guest_processes(self) -> None:
        captured = {item["pid"] for item in self.captured_processes}
        guests = {"container", "container-runtime-linux", "com.apple.Virtualization.VirtualMachine",
                  "docker", "docker-compose", "colima"}
        for process in self.captured_processes:
            if Path(process["program"]).name in guests:
                raise InstallationError("captured Homebrew service owns an active guest process")
        for pid, process in self.process_runtime.process_inventory().items():
            if pid not in captured and Path(process["program"]).name in guests:
                raise InstallationError("an unowned active guest prevents Homebrew replacement")

    def restore(self) -> None:
        for item in self.prior:
            path = Path(item["path"])
            launch_agents = self.home / "Library/LaunchAgents"
            if (path.parent != launch_agents or launch_agents.is_symlink()
                    or launch_agents.resolve() != launch_agents or not launch_agents.is_dir()
                    or launch_agents.stat().st_uid != os.getuid()):
                raise InstallationError("Homebrew launch agent directory changed before restoration")
            if path.exists():
                current = self.canonical_file(path)
                if current != item["payload"] or stat.S_IMODE(path.stat().st_mode) != item["mode"]:
                    raise InstallationError("captured Homebrew service definition changed")
            else:
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.write_bytes(item["payload"])
                path.chmod(item["mode"])
            if self.launchd.inspect(item["label"]) is None:
                if self.captured_processes:
                    self.process_runtime.require_captured_processes_stopped(
                        self.launchd, self.prior, self.captured_processes)
                self.launchd.bootstrap(path)
            if self.launchd.inspect(item["label"]) != {key: item[key] for key in ("label", "path", "program")}:
                raise InstallationError("Homebrew launchd registration was not restored")

    def verify(self) -> None:
        for item in self.prior:
            path = Path(item["path"])
            if (self.canonical_file(path) != item["payload"]
                    or self.launchd.inspect(item["label"]) != {
                        key: item[key] for key in ("label", "path", "program")}):
                raise InstallationError("Homebrew service restoration could not be verified")
        for label in self.absent:
            if self.launchd.inspect(label) is not None:
                raise InstallationError("an unrequested Homebrew service appeared during testing")


class InstallationTransaction:
    """Preserve, test, and exactly restore the two conflicting formulae."""

    def __init__(self, *, formula_path: Path, test_tap: str, lane: str,
                 expected_source_sha: str, finalized_context: Path, expected_version: str,
                 ssd_scratch: Path, retained_root: Path, receipt_output: Path,
                 runner=None, service=None, storage_check=None, guard=None,
                 lease_factory=None, cancellation_factory=None, version_check=None):
        self.formula_path = formula_path
        self.tap = test_tap
        self.lane = lane
        self.source = expected_source_sha.lower()
        self.context_path = finalized_context
        self.version = expected_version
        self.scratch = ssd_scratch
        self.retained_root = retained_root
        self.receipt_output = receipt_output
        self.runner = runner or CommandRunner()
        self.service = service or LaunchdServices()
        self.storage_check = storage_check or storage_preflight
        self.guard = guard or HostGuard(INTERNAL_ROOT / "workflow/runtime-admission.json")
        self.lease_factory = lease_factory or runtime_lease
        self.cancellation_factory = cancellation_factory or cancellation
        self.version_check = version_check or self._version_subprocess
        self.backup_id = str(uuid.uuid4())
        self.backup: Path | None = None
        self.prefix: Path | None = None
        self.cellar: Path | None = None
        self.repository: Path | None = None
        self.prior_kegs: dict[str, dict[str, dict[str, int | str]]] = {}
        self.formula_roots: dict[str, int] = {}
        self.keg_paths: dict[str, list[Path]] = {name: [] for name in FORMULAE}
        self.prior_links: dict[str, dict[str, str | int]] = {}
        self.context: dict | None = None
        self.formula_bytes = b""
        self.installed_before: set[str] = set()
        self.removed_originals: set[str] = set()
        self.trust_attempted = False
        self.mutation_started = False
        self.guard_active = False
        self.tap_attempted = False
        self.status = "not-started"
        self.failure_code: str | None = None
        self.original_failure_code: str | None = None

    @property
    def formula(self) -> str:
        return "devcontainer-current" if self.lane == "current" else "devcontainer"

    def preflight(self) -> None:
        if not TAP.fullmatch(self.tap):
            raise InstallationError("temporary tap name is outside the CI namespace")
        template = Path(__file__).with_name("devcontainer.rb.in")
        self.formula_bytes = private_file(self.formula_path, 1024 * 1024)
        self.context = validate_context(self.context_path, self.formula_path, self.lane,
                                        self.source, self.version, template, self.formula_bytes)
        self.storage_check(self.scratch, self.retained_root)
        self.prefix = Path(self.runner("--prefix"))
        self.cellar = Path(self.runner("--cellar"))
        if (not self.prefix.is_absolute() or self.prefix.resolve() != self.prefix
                or not self.cellar.is_absolute() or self.cellar.resolve() != self.cellar
                or not self.cellar.is_relative_to(self.prefix)):
            raise InstallationError("Homebrew prefix or cellar is not canonical")
        self.repository = Path(self.runner("--repository", timeout=30))
        canonical_directory(self.repository, self.prefix)
        if self.tap in self.runner("tap", timeout=30).splitlines():
            raise InstallationError("temporary tap already exists")
        for name in sorted(FORMULAE):
            root = self.cellar / name
            if root.exists() or root.is_symlink():
                canonical_directory(root, self.cellar)
                self.formula_roots[name] = stat.S_IMODE(root.stat().st_mode)
                for keg in sorted(root.iterdir()):
                    canonical_directory(keg, root)
                    inventory = tree_inventory(keg)
                    self.keg_paths[name].append(keg)
                    self.prior_kegs[str(keg)] = inventory
        installed_rows = self.runner("list", "--formula", "--versions", timeout=30).splitlines()
        self.installed_before = {row.split()[0] for row in installed_rows if row.split()}
        if self.lane == "stable":
            version = self.version
        else:
            version = self.context["formulaVersion"]
        expected_keg = self.cellar / self.formula / version
        if str(expected_keg) in self.prior_kegs and not getattr(self, "allow_reinstall", False):
            raise InstallationError("candidate version already exists in the Homebrew cellar")
        self.prior_links = symlink_snapshot(self.prefix, self.keg_paths)
        self.service.capture(self.prefix, self.keg_paths)
        self.retained_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.retained_root.stat().st_dev != Path.home().stat().st_dev:
            raise InstallationError("durable backup root is not on internal storage")
        if self.retained_root.stat().st_uid != os.getuid() or self.retained_root.stat().st_mode & 0o077:
            raise InstallationError("durable backup root is not private and owned")
        self.backup = self.retained_root / self.backup_id
        self.backup.mkdir(mode=0o700)
        self.scratch.mkdir(mode=0o700)
        (self.scratch / "snapshot").mkdir(mode=0o700)
        (self.backup / "kegs").mkdir(mode=0o700)
        (self.backup / "services").mkdir(mode=0o700)
        for old_path, inventory in self.prior_kegs.items():
            source = Path(old_path)
            relative = source.relative_to(self.cellar)
            ssd_copy = self.scratch / "snapshot" / relative
            copy_keg(source, ssd_copy, inventory)
            durable_copy = self.backup / "kegs" / relative
            copy_keg(ssd_copy, durable_copy, inventory)
        for item in self.service.prior:
            service_copy = self.backup / "services" / (item["label"] + ".plist")
            service_copy.write_bytes(item["payload"])
            service_copy.chmod(0o600)
        backup_manifest = {
            "schemaVersion": 1,
            "kegs": self.prior_kegs,
            "formulaRoots": self.formula_roots,
            "links": self.prior_links,
            "services": [{key: value for key, value in item.items()
                          if key in {"label", "path", "program", "sha256", "formula", "mode", "pid"}}
                         for item in self.service.prior],
            "serviceProcesses": self.service.captured_processes,
        }
        payload = json.dumps(backup_manifest, sort_keys=True, separators=(",", ":")).encode()
        (self.backup / "manifest.json").write_bytes(payload)
        (self.backup / "manifest.json").chmod(0o600)
        self.backup_sha = hashlib.sha256(payload).hexdigest()
        sync_tree(self.backup)
        sync_tree(self.scratch)

    def call(self, *arguments: str, timeout: int = 900) -> str:
        return self.runner(*arguments, timeout=timeout)

    def installed(self, name: str) -> bool:
        result = self.call("list", "--formula", "--versions", timeout=30)
        return any(row.split() and row.split()[0] == name for row in result.splitlines())

    def execute_test(self) -> None:
        assert (self.context is not None and self.prefix is not None
                and self.cellar is not None and self.repository is not None)
        self.mutation_started = True
        self.service.stop()
        for name in sorted(FORMULAE):
            if self.installed(name):
                self.call("uninstall", "--force", name, timeout=300)
                self.removed_originals.add(name)
        self.tap_attempted = True
        self.call("tap-new", "--no-git", self.tap, timeout=120)
        tap_root = Path(self.call("--repository", self.tap, timeout=30))
        taps_root = self.repository / "Library/Taps/stephenlclarke"
        canonical_directory(tap_root, taps_root)
        expected_tap_name = "homebrew-" + self.tap.split("/", 1)[1]
        if tap_root.name != expected_tap_name:
            raise InstallationError("Homebrew created the temporary tap at an unexpected path")
        formula_destination = tap_root / "Formula" / f"{self.formula}.rb"
        canonical_directory(formula_destination.parent, tap_root)
        shutil.copyfile(self.formula_path, formula_destination)
        if formula_destination.read_bytes() != self.formula_bytes:
            raise InstallationError("temporary tap formula copy differs")
        full_formula = f"{self.tap}/{self.formula}"
        self.trust_attempted = True
        self.call("trust", "--formula", full_formula, timeout=120)
        self.call("audit", "--formula", "--strict", "--online", full_formula, timeout=300)
        self.call("fetch", "--formula", "--force", full_formula, timeout=900)
        self.call("install", "--formula", full_formula, timeout=900)
        self.call("test", full_formula, timeout=900)
        installed = Path(self.call("--prefix", full_formula, timeout=30)) / "bin/devcontainer"
        if not installed.is_file() or installed.is_symlink():
            raise InstallationError("installed candidate executable is missing or aliased")
        version = json.loads(self.version_check(installed))
        # Native packages retain the qualified candidate build identity when
        # promoted; the distribution lane is separately admitted by context.
        if (version.get("commit") != self.source or version.get("lane") != "candidate"
                or version.get("version") != self.version):
            raise InstallationError("installed candidate version identity differs")

    @staticmethod
    def _version_subprocess(executable: Path) -> str:
        output = subprocess.run([str(executable), "version", "--format", "json"], check=True,
                                capture_output=True, text=True, timeout=30,
                                env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "LC_ALL": "C"})
        return output.stdout

    def remove_candidate_links(self) -> None:
        assert self.prefix is not None and self.cellar is not None
        candidate_root = self.cellar / self.formula
        opt_path = self.prefix / "opt" / self.formula
        baseline = self.prior_links
        scan_paths = set()
        for path in (self.prefix / "bin", self.prefix / "share" / "man"):
            if path.is_dir() and not path.is_symlink():
                for base, dirs, files in os.walk(path, followlinks=False):
                    base_path = Path(base)
                    dirs[:] = [item for item in dirs if not (base_path / item).is_symlink()]
                    scan_paths.update(base_path / item for item in files)
        scan_paths.add(opt_path)
        for path in sorted(scan_paths):
            if not path.is_symlink():
                continue
            previous = baseline.get(str(path))
            target = os.readlink(path)
            if previous is not None and previous["target"] == target:
                continue
            try:
                resolved = path.resolve(strict=False)
            except (OSError, RuntimeError) as error:
                raise InstallationError("changed Homebrew link cannot be resolved") from error
            candidate_owned = (resolved == candidate_root or candidate_root in resolved.parents
                               or path == opt_path and resolved.is_relative_to(candidate_root))
            if not candidate_owned:
                if previous is not None:
                    raise InstallationError("a captured Homebrew link changed to a foreign target")
                continue
            path.unlink()

    def restore_kegs(self) -> None:
        assert self.backup is not None and self.cellar is not None
        for old_path, inventory in self.prior_kegs.items():
            source = Path(old_path)
            relative = source.relative_to(self.cellar)
            durable = self.backup / "kegs" / relative
            if tree_inventory(durable) != inventory:
                raise InstallationError("durable Homebrew backup differs from its manifest")
            if source.exists():
                if tree_inventory(source) != inventory:
                    raise InstallationError("existing Homebrew keg conflicts with its backup")
                continue
            formula_root = source.parent
            if formula_root.exists():
                canonical_directory(formula_root, self.cellar)
            else:
                formula_root.mkdir(mode=self.formula_roots.get(formula_root.name, 0o755))
            if formula_root.name in self.formula_roots:
                formula_root.chmod(self.formula_roots[formula_root.name])
            ssd_copy = self.scratch / "restore" / relative
            copy_keg(durable, ssd_copy, inventory)
            copy_keg(ssd_copy, source, inventory)
        for name, mode in self.formula_roots.items():
            root = self.cellar / name
            if not root.exists():
                root.mkdir(mode=mode)
            root.chmod(mode)

    def restore_links(self) -> None:
        assert self.prefix is not None
        for raw_path, entry in self.prior_links.items():
            path = Path(raw_path)
            safe_parent(path, self.prefix)
            if path.exists() or path.is_symlink():
                if not path.is_symlink():
                    raise InstallationError("captured Homebrew link conflicts with a non-link path")
                if os.readlink(path) != entry["target"]:
                    raise InstallationError("captured Homebrew link changed before restoration")
            else:
                path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                path.symlink_to(str(entry["target"]))

    def verify_restored(self) -> None:
        assert self.prefix is not None and self.cellar is not None
        current_kegs = {}
        for name in sorted(FORMULAE):
            root = self.cellar / name
            actual = {}
            if root.exists():
                canonical_directory(root, self.cellar)
                if stat.S_IMODE(root.stat().st_mode) != self.formula_roots.get(name, stat.S_IMODE(root.stat().st_mode)):
                    raise InstallationError("Homebrew formula directory mode differs after restoration")
                for keg in sorted(root.iterdir()):
                    canonical_directory(keg, root)
                    actual[str(keg)] = tree_inventory(keg)
            expected = {path: value for path, value in self.prior_kegs.items()
                        if Path(path).parent == root}
            if actual != expected:
                raise InstallationError("installed Homebrew keg inventory was not restored")
            current_kegs[name] = actual
        if symlink_snapshot(self.prefix, self.keg_paths) != self.prior_links:
            raise InstallationError("Homebrew opt/bin/man link inventory was not restored")
        for name in sorted(FORMULAE):
            current = self.call("list", "--formula", "--versions", timeout=30)
            installed = any(row.split() and row.split()[0] == name for row in current.splitlines())
            if installed != (name in self.installed_before):
                raise InstallationError("Homebrew installed formula state differs after restoration")
        self.service.verify()

    def cleanup_and_restore(self) -> None:
        if self.backup is None or self.prefix is None or self.cellar is None:
            return
        failures = []
        for operation in (
            self._uninstall_candidate,
            self._remove_candidate_keg,
            self.remove_candidate_links,
            self._remove_tap,
            self._revoke_trust,
            self.restore_kegs,
            self.restore_links,
            self.service.restore,
            self.verify_restored,
        ):
            try:
                operation()
            except BaseException as error:  # continue only to restore independent owned state
                failures.append(error)
        if failures:
            self.status = "restoration-failed"
            raise InstallationError("Homebrew restoration failed; private backup retained") from failures[0]
        self._remove_scratch()

    def _remove_scratch(self) -> None:
        if self.scratch.exists():
            if (self.scratch.is_symlink() or self.scratch.resolve() != self.scratch
                    or self.scratch.stat().st_uid != os.getuid() or self.scratch.stat().st_mode & 0o077):
                raise InstallationError("SSD scratch changed before cleanup")
            shutil.rmtree(self.scratch)

    def _uninstall_candidate(self) -> None:
        if ((self.formula not in self.installed_before or self.formula in self.removed_originals)
                and self.installed(self.formula)):
            self.call("uninstall", "--force", self.formula, timeout=300)

    def _remove_candidate_keg(self) -> None:
        assert self.cellar is not None and self.context is not None
        version = self.version if self.lane == "stable" else self.context["formulaVersion"]
        path = self.cellar / self.formula / version
        if not path.exists() and not path.is_symlink():
            return
        canonical_directory(path, self.cellar / self.formula)
        if (str(path) in self.prior_kegs
                and not (self.formula in self.removed_originals
                         and self.formula in getattr(self, "candidate_install_attempts", set()))):
            raise InstallationError("candidate cleanup would remove a pre-existing keg")
        tree_inventory(path)
        shutil.rmtree(path)
        parent = path.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()

    def _remove_tap(self) -> None:
        if not self.tap_attempted:
            return
        taps = self.call("tap", timeout=30).splitlines()
        if self.tap in taps:
            self.call("untap", self.tap, timeout=120)

    def _revoke_trust(self) -> None:
        if self.trust_attempted:
            self.call("untrust", "--formula", f"{self.tap}/{self.formula}", timeout=120)

    def receipt(self, status: str, error_code: str | None, original_failure_code: str | None = None) -> dict:
        prior_hash = inventory_sha({"kegs": self.prior_kegs, "links": self.prior_links})
        current_hash = prior_hash
        restored = status.endswith("-restored")
        if self.prefix is not None and self.cellar is not None and restored:
            current = {}
            for name in sorted(FORMULAE):
                root = self.cellar / name
                if root.exists():
                    for path in sorted(root.iterdir()):
                        current[str(path)] = tree_inventory(path)
            current_hash = inventory_sha({"kegs": current, "links": symlink_snapshot(self.prefix, self.keg_paths)})
        return {"schemaVersion": 1, "scope": "homebrew-formula-installation-test",
                "status": status, "failureCode": error_code, "lane": self.lane,
                "originalFailureCode": original_failure_code,
                "sourceCommit": self.source, "productVersion": self.version,
                "backupId": self.backup_id, "backupManifestSHA256": getattr(self, "backup_sha", None),
                "beforeInventorySHA256": prior_hash, "afterInventorySHA256": current_hash,
                "baselineRestored": restored}

    def run(self) -> dict:
        original_error: BaseException | None = None
        owner = None
        try:
            lock = Path(f"/private/tmp/container-compose-runtime-{os.getuid()}.lock")
            with self.lease_factory(lock, self.guard):
                self.preflight()
                owner = {"operation": "homebrew-formula-installation-test", "backupId": self.backup_id,
                         "backupManifestSHA256": self.backup_sha, "formula": self.formula,
                         "lane": self.lane, "sourceCommit": self.source}
                self.guard.begin(owner)
                self.guard_active = True
                try:
                    with self.cancellation_factory():
                        self.status = "testing"
                        self.execute_test()
                        self.status = "passed"
                except BaseException as error:
                    original_error = error
                    self.status = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
                    self.failure_code = ("cancelled" if isinstance(error, KeyboardInterrupt)
                                         else "validation-or-installation-failed")
                    self.original_failure_code = self.failure_code
                finally:
                    if self.guard_active and self.mutation_started:
                        try:
                            self.cleanup_and_restore()
                        except BaseException:
                            self.failure_code = "restoration-failed"
                            raise
                        self.status = ("interrupted-restored" if self.status == "interrupted"
                                       else "failed-restored" if self.status == "failed"
                                       else "passed-restored")
                        self.guard.clear(owner)
                        self.guard_active = False
                    elif self.guard_active:
                        self.verify_restored()
                        self._remove_scratch()
                        self.guard.clear(owner)
                        self.guard_active = False
                        self.status = ("interrupted-restored" if self.status == "interrupted"
                                       else "failed-restored" if self.status == "failed"
                                       else "passed-restored")
        except BaseException as error:
            if original_error is None:
                original_error = error
            if self.status == "not-started":
                self.status = "preflight-failed"
                self.failure_code = "preflight-failed"
            elif self.mutation_started:
                self.status = "restoration-failed"
                self.failure_code = "restoration-failed"
        receipt = self.receipt(self.status, self.failure_code, self.original_failure_code)
        write_receipt(self.receipt_output, receipt)
        if isinstance(original_error, KeyboardInterrupt):
            raise original_error
        if self.status != "passed-restored":
            detail = str(original_error) if isinstance(original_error, InstallationError) else "operation failed"
            raise InstallationError("Homebrew test transaction failed: " + detail) from original_error
        return receipt


def write_receipt(path: Path, value: dict) -> None:
    """Atomically write only the public-safe transaction summary."""
    if not path.is_absolute() or path.parent.is_symlink() or path.parent.resolve() != path.parent:
        raise InstallationError("receipt destination is aliased")
    payload = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--formula-path", type=Path, required=True)
    parser.add_argument("--test-tap", required=True)
    parser.add_argument("--lane", choices=("stable", "current"), required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--finalized-context", type=Path, required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--ssd-scratch", type=Path, required=True)
    parser.add_argument("--retained-root", type=Path, required=True)
    parser.add_argument("--receipt-output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        transaction = InstallationTransaction(
            formula_path=args.formula_path, test_tap=args.test_tap, lane=args.lane,
            expected_source_sha=args.expected_source_sha, finalized_context=args.finalized_context,
            expected_version=args.expected_version, ssd_scratch=args.ssd_scratch,
            retained_root=args.retained_root, receipt_output=args.receipt_output)
        receipt = transaction.run()
    except InstallationError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
