#!/usr/bin/env python3
"""Test a downloaded stable Compose/runtime formula pair and restore the baseline.

The existing, hash-admitted Devcontainer installation core owns all backups,
lease/guard operations, and restoration. This adapter only selects the four
Compose formula names, admits the pair, and implements its installation step.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
import subprocess

FORMULAE = {'container', 'container-current', 'container-compose', 'container-compose-current'}
RUNTIME_SHA = 'd4a9bd8e9d332b0bfbf67fc5b0b3a99c977b66d6cc50f5954b36f3263a2cf696'
RUNTIME_SOURCE = 'f86fea2236fab118c0e0c6f8be5eb7672df894e2'
RUNTIME_BINARY_SHA = '6cdefe21e349b76dd3e91a064974c6889a6a79e513e84a8b63f1303ffbacdf1a'
HEX = re.compile(r'[0-9a-f]{64}')
TAP = re.compile(r'stephenlclarke/container-compose-release-ci-[1-9][0-9]*')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def private(path, expected=None):
    path = Path(path)
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise ValueError('Input is not canonical')
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
        raise ValueError('Input ownership changed')
    data = path.read_bytes()
    if len(data) > 1024 * 1024 or expected is not None and sha(data) != expected:
        raise ValueError('Frozen input bytes differ')
    return data


def private_formula(text, tap):
    """Rewrite only the declared tap namespace; never execute arbitrary Ruby."""
    if not TAP.fullmatch(tap):
        raise ValueError('Private test tap is outside the owned namespace')
    return text.replace('stephenlclarke/tap/container', tap + '/container')


def validate_pair(context, texts):
    if set(texts) != {'container', 'container-compose'} or set(context['formulae']) != {'container', 'container-compose'}:
        raise ValueError('Unexpected formula pair')
    if context['runtimeArchiveSHA256'] != RUNTIME_SHA or context['runtimeSourceCommit'] != RUNTIME_SOURCE:
        raise ValueError('Runtime differs from the qualified enhanced provider')
    if not re.fullmatch(r'[0-9a-f]{40}', context['sourceCommit']) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', context['version']):
        raise ValueError('Stable release source/version is invalid')
    if context['runtimeVersion'] != '0.16.0' or context['runtimeProductVersion'] != '0.0.0':
        raise ValueError('Runtime distribution/product mapping differs from this release')
    if not context['runtimeVersion'] or any(c in context['runtimeVersion'] for c in '\n/"'):
        raise ValueError('Runtime product version is invalid')
    for name, archive in [('container', 'container-release-arm64.tar.gz'), ('container-compose', 'container-compose-plugin-release-arm64.tar.gz')]:
        spec = context['formulae'][name]
        text = texts[name]
        expected_url = f"https://github.com/stephenlclarke/container-compose/releases/download/{context['version']}/{archive}"
        for field, expected in [('url', expected_url), ('sha256', spec['archiveSHA256'])]:
            if re.findall(r'^  ' + field + r' "([^"]*)"$', text, re.M) != [expected]:
                raise ValueError('Formula archive identity differs')
        if not HEX.fullmatch(spec['archiveSHA256']) or sha(text.encode()) != spec['formulaSHA256']:
            raise ValueError('Formula byte identity differs')
    if context['formulae']['container']['binarySHA256'] != RUNTIME_BINARY_SHA:
        raise ValueError('Runtime signed payload executable differs from qualified archive')
    if context['formulae']['container']['archiveSHA256'] != RUNTIME_SHA:
        raise ValueError('Stable runtime asset bytes differ from qualified archive')
    if re.findall(r'^  version "([^"]*)"$', texts['container'], re.M) != [context['runtimeVersion']]:
        raise ValueError('Runtime formula must preserve actual runtime product version')
    if re.findall(r'^  version ', texts['container-compose'], re.M):
        raise ValueError('Stable Compose derives version from its release URL')
    if '  depends_on "stephenlclarke/tap/container"' not in texts['container-compose']:
        raise ValueError('Compose does not require the matched runtime')
    if ('container CLI version ' + context['runtimeProductVersion'] not in texts['container']
            or RUNTIME_SOURCE[:7] not in texts['container']):
        raise ValueError('Runtime formula test does not authenticate embedded product/source')
    if 'opt/container-compose/libexec/container-plugins/compose' not in texts['container']:
        raise ValueError('Runtime plugin registration differs')


def validate_runtime_product(output, context):
    match = re.fullmatch(r'container CLI version ([0-9]+\.[0-9]+\.[0-9]+) \(commit:?\s*([0-9a-f]{7,40})\)', output.strip())
    if (match is None or match.group(1) != context['runtimeProductVersion']
            or match.group(2) != RUNTIME_SOURCE[:len(match.group(2))]):
        raise ValueError('Installed runtime embedded product/source differs')
    return {'productVersion': match.group(1), 'sourceCommit': RUNTIME_SOURCE}


def runtime_product(executable, context):
    result = subprocess.run([str(executable), '--version'], check=True, capture_output=True, text=True, timeout=30,
                            env={'PATH':'/usr/bin:/bin','HOME':str(Path.home()),'LC_ALL':'C'})
    return validate_runtime_product(result.stdout, context)


def signed_binary(path, expected, team):
    if sha(Path(path).read_bytes()) != expected:
        raise ValueError('Installed executable differs from admitted payload')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True, timeout=30)
    result = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(path)], check=True, capture_output=True, text=True, timeout=30)
    if re.findall(r'^TeamIdentifier=(.+)$', result.stderr, re.M) != [team]:
        raise ValueError('Installed signing team differs')


def transaction(core, context, arguments):
    """Customize a private module instance; the maintained module is untouched."""
    core.FORMULAE = FORMULAE
    core.TAP = TAP
    core.SERVICE_LABELS = {'container': 'homebrew.mxcl.container', 'container-current': 'homebrew.mxcl.container-current'}
    texts = {name: private(spec['path'], spec['formulaSHA256']).decode() for name, spec in context['formulae'].items()}
    validate_pair(context, texts)
    # Exact formula bytes are authority inputs. Templates are separately frozen
    # in context by the release controller; no Ruby is admitted by URL alone.
    for name, spec in context['templates'].items():
        private(spec['path'], spec['sha256'])
    core.validate_context = lambda *a, **k: {'formulaVersion': context['version'], **context}
    class PairServices(core.LaunchdServices):
        def capture(self, prefix: Path, kegs: dict[str, list[Path]]) -> list[dict]:
                labels = self.launchd.labels()
                self.other_registrations = {label:self.launchd.inspect(label) for label in labels if label not in core.SERVICE_LABELS.values()}
                for formula, label in core.SERVICE_LABELS.items():
                    if label not in labels:
                        self.absent.append(label)
                        continue
                    job = self.launchd.inspect(label)
                    if job is None:
                        raise core.InstallationError("Homebrew launchd inventory changed during capture")
                    path = Path(job["path"])
                    launch_agents = self.home / "Library/LaunchAgents"
                    if (not launch_agents.is_dir() or launch_agents.is_symlink()
                            or launch_agents.resolve() != launch_agents
                            or launch_agents.stat().st_uid != os.getuid()
                            or not path.is_relative_to(launch_agents) or path.name != label + ".plist"
                            or path.is_symlink() or path.resolve() != path):
                        raise core.InstallationError("Homebrew launchd identity is not an owned launch agent")
                    payload = self.canonical_file(path)
                    definition = plistlib.loads(payload)
                    arguments = definition.get("ProgramArguments", [])
                    program = definition.get("Program") or (arguments[0] if arguments else None)
                    if definition.get("Label") != label or program != job["program"]:
                        raise core.InstallationError("Homebrew launchd plist differs from its loaded identity")
                    if not isinstance(program, str) or not Path(program).is_absolute():
                        raise core.InstallationError("Homebrew launchd program is not an absolute executable")
                    target = Path(program).resolve(strict=True)
                    if (target.name != "container" or target.parent.name != "bin"
                            or not any(target.is_relative_to(keg) for keg in kegs.get(formula, []))):
                        raise core.InstallationError("Homebrew launchd program is outside the captured keg")
                    item = {**job, "payload": payload, "sha256": hashlib.sha256(payload).hexdigest(),
                            "formula": formula, "mode": stat.S_IMODE(path.stat().st_mode),
                            "pid": self.launchd.process_id(label)}
                    self.prior.append(item)
                self.captured_processes = self.process_runtime.capture_owned_processes(self.launchd, self.prior)
                self._reject_active_guest_processes()
                self.signatures = self.signature_inventory()
                return self.prior

        def signature_inventory(self):
            result = {}
            for process in self.captured_processes:
                path = Path(process['program']).resolve(strict=True)
                detail = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(path)], capture_output=True, timeout=30)
                result[str(path)] = {'sha256': core.digest(path), 'signatureStatus': detail.returncode,
                                     'signatureDetailSHA256': sha(detail.stderr)}
            return result

        def stop(self):
            if self.signature_inventory() != self.signatures:
                raise core.InstallationError('Captured process executable/signature changed before quiesce')
            super().stop()

        def verify(self):
            super().verify()
            current = {label:self.launchd.inspect(label) for label in self.launchd.labels() if label not in core.SERVICE_LABELS.values()}
            if current != self.other_registrations:
                raise core.InstallationError('Unrelated launchd registration inventory changed')
            if self.signature_inventory() != self.signatures:
                raise core.InstallationError('Restored service executable/signature differs')

    # Baseline container kegs include precisely this cross-keg registration.
    # Preserve its text; never follow it while backing up or deleting a keg.
    original_tree = core.tree_inventory
    def inventory(root):
        allowed = {}
        for path in root.rglob('*'):
            if path.is_symlink():
                target = os.readlink(path)
                relative = path.relative_to(root).as_posix()
                registration = (relative == 'libexec/container-plugins/compose'
                                and target in {str(Path('/opt/homebrew/opt') / name / 'libexec/container-plugins/compose')
                                               for name in ('container-compose', 'container-compose-current')})
                command_link = (relative in {'bin/container-compose', 'bin/container-compose-current'}
                                and not Path(target).is_absolute()
                                and path.resolve(strict=False) == root / 'libexec/container-plugins/compose/bin/compose')
                if not (registration or command_link) or path.lstat().st_uid != os.getuid():
                    raise core.InstallationError('Unadmitted baseline keg symlink')
                allowed[path.relative_to(root).as_posix()] = {'kind':'symlink', 'target':target,
                                                            'mode':stat.S_IMODE(path.lstat().st_mode)}
        if not allowed:
            return original_tree(root)
        # Inventory regular paths without mutating or following link entries.
        rows = {'.': {'kind':'directory', 'mode':stat.S_IMODE(root.stat().st_mode)}}
        if root.is_symlink() or root.resolve() != root or root.stat().st_uid != os.getuid():
            raise core.InstallationError('Unsafe keg root')
        for path in sorted(root.rglob('*')):
            info=path.lstat();name=path.relative_to(root).as_posix()
            if info.st_uid != os.getuid():raise core.InstallationError('Unowned keg entry')
            if name in allowed:rows[name]=allowed[name]
            elif stat.S_ISDIR(info.st_mode):rows[name]={'kind':'directory','mode':stat.S_IMODE(info.st_mode)}
            elif stat.S_ISREG(info.st_mode) and info.st_nlink==1:
                rows[name]={'kind':'file','mode':stat.S_IMODE(info.st_mode),'size':info.st_size,'sha256':core.digest(path)}
            else:raise core.InstallationError('Special or aliased keg entry')
        return rows
    core.tree_inventory = inventory
    def copy_keg(source, destination, expected):
        if destination.exists() or destination.is_symlink():raise core.InstallationError('Backup already exists')
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copytree(source, destination, copy_function=shutil.copy2, symlinks=True)
        if inventory(destination)!=expected:raise core.InstallationError('Copied keg inventory differs')
    core.copy_keg = copy_keg

    class Pair(core.InstallationTransaction):
        @property
        def formula(self):
            return getattr(self, '_selected_formula', 'container-compose')

        def preflight(self):
            self.allow_reinstall = True
            self.candidate_install_attempts = set()
            self.trust_attempts = set()
            super().preflight()
            manifest_path = self.backup / 'manifest.json'
            manifest = json.loads(manifest_path.read_bytes())
            manifest['serviceExecutableSignatures'] = self.service.signatures
            manifest['otherLaunchdRegistrations'] = self.service.other_registrations
            core.write_receipt(manifest_path, manifest)
            self.backup_sha = sha(manifest_path.read_bytes())
            core.sync_tree(self.backup)
            self.public_formula_hashes = {name: sha(value.encode()) for name, value in texts.items()}

        def execute_test(self):
            self.mutation_started = True
            self.service.stop()
            for name in ['container-compose-current', 'container-compose', 'container-current', 'container']:
                if self.installed(name):
                    self.call('uninstall', '--force', name, timeout=300)
                    self.removed_originals.add(name)
            self.tap_attempted = True
            self.call('tap-new', '--no-git', self.tap, timeout=120)
            tap_root = Path(self.call('--repository', self.tap, timeout=30))
            core.canonical_directory(tap_root, self.repository / 'Library/Taps/stephenlclarke')
            if tap_root.name != 'homebrew-' + self.tap.split('/', 1)[1]:
                raise core.InstallationError('Temporary tap path differs')
            for name in ['container', 'container-compose']:
                destination = tap_root / 'Formula' / (name + '.rb')
                core.canonical_directory(destination.parent, tap_root)
                destination.write_text(private_formula(texts[name], self.tap))
                full = self.tap + '/' + name
                self.trust_attempted = True
                self.trust_attempts.add(name)
                self.call('trust', '--formula', full, timeout=120)
                self.call('audit', '--formula', '--strict', '--online', full, timeout=300)
                self.call('fetch', '--formula', '--force', full)
                # Public formula post_install contains a broad launchd stop.
                # Skip it; install only its exact owned plugin link below.
                self.candidate_install_attempts.add(name)
                self.call('install', '--formula', '--skip-post-install', full)
            runtime_keg = Path(self.call('--prefix', self.tap + '/container', timeout=30)).resolve(strict=True)
            plugin_keg = Path(self.call('--prefix', self.tap + '/container-compose', timeout=30)).resolve(strict=True)
            for name, keg in [('container', runtime_keg), ('container-compose', plugin_keg)]:
                core.canonical_directory(keg, self.cellar / name)
                expected_version = context['runtimeVersion'] if name == 'container' else context['version']
                if keg != self.cellar / name / expected_version:
                    raise core.InstallationError('Installed candidate Cellar version differs')
            plugin = plugin_keg / 'libexec/container-plugins/compose'
            core.canonical_directory(plugin, plugin_keg)
            link = runtime_keg / 'libexec/container-plugins/compose'
            core.safe_parent(link, runtime_keg)
            if link.exists() or link.is_symlink():
                raise core.InstallationError('Candidate plugin link already exists; no adoption')
            link.parent.mkdir(parents=True, exist_ok=True)
            target = self.prefix / 'opt/container-compose/libexec/container-plugins/compose'
            if target.resolve(strict=True) != plugin:
                raise core.InstallationError('Plugin opt link differs')
            link.symlink_to(target)
            self.candidate_link = link
            for name, binary in [('container', runtime_keg / 'libexec/bin/container'), ('container-compose', plugin / 'bin/compose')]:
                signed_binary(binary, context['formulae'][name]['binarySHA256'], context['teamID'])
                if name == 'container':
                    self.installed_runtime_product = runtime_product(binary, context)
                self.call('test', self.tap + '/' + name)

        def _each(self, method):
            old_version = self.version
            try:
                for name in ['container-compose', 'container']:
                    self._selected_formula = name
                    self.version = context['runtimeVersion'] if name == 'container' else old_version
                    method()
            finally:
                self._selected_formula = 'container-compose';self.version = old_version

        def _uninstall_candidate(self):
            self._each(super()._uninstall_candidate)

        def _remove_candidate_keg(self):
            # The sole created cross-keg link is removed by exact identity before
            # the shared regular-file inventory admits candidate keg deletion.
            link = getattr(self, 'candidate_link', None)
            if link is not None and link.is_symlink():
                if os.readlink(link) != str(self.prefix / 'opt/container-compose/libexec/container-plugins/compose'):
                    raise core.InstallationError('Owned plugin link changed')
                link.unlink()
            self._each(super()._remove_candidate_keg)

        def remove_candidate_links(self):
            self._each(super().remove_candidate_links)

        def _revoke_trust(self):
            if self.trust_attempted:
                for name in sorted(self.trust_attempts):
                    self.call('untrust', '--formula', self.tap + '/' + name, timeout=120)

        def receipt(self, status, error_code, original_failure_code=None):
            result = super().receipt(status, error_code, original_failure_code)
            result.update(scope='compose-homebrew-formula-pair-installation-test', runtimeSourceCommit=RUNTIME_SOURCE,
                          runtimeArchiveSHA256=RUNTIME_SHA, runtimeVersion=context['runtimeVersion'],
                          runtimeProductVersion=context['runtimeProductVersion'],
                          installedRuntimeProduct=getattr(self, 'installed_runtime_product', None),
                          formulaPairSHA256=getattr(self, 'public_formula_hashes', {}),
                          composeArchiveSHA256=context['formulae']['container-compose']['archiveSHA256'],
                          runtimeBinarySHA256=context['formulae']['container']['binarySHA256'],
                          composeBinarySHA256=context['formulae']['container-compose']['binarySHA256'],
                          guardAbsent=not self.guard_active,
                          ownedPluginRegistrationExecuted=hasattr(self, 'candidate_link'),
                          broadPostInstallStopExecuted=False, ownedPluginRegistrationOnly=True, releaseAuthority=False)
            return result
    return Pair(formula_path=Path(context['formulae']['container-compose']['path']), test_tap=arguments.test_tap,
                lane='stable', expected_source_sha=context['sourceCommit'], finalized_context=arguments.context,
                expected_version=context['version'], ssd_scratch=arguments.ssd_scratch,
                retained_root=arguments.retained_root, receipt_output=arguments.receipt_output, service=PairServices())


def authenticate_testing_root(root, bindings):
    """Admit imported controller code before the core imports any helper."""
    root = Path(root)
    if root.is_symlink() or root.resolve() != root or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ValueError('Testing root is not canonical and owned')
    for name in ('host_runtime.py', 'service_switch.py', 'runtime_services.py'):
        if not (root / name).is_file():
            raise ValueError('Shared controller entry module is missing')
    # runtime_services imports runtime_probe -> guest_runtime, which imports
    # sibling bazel helpers. Admit these existing sources, without copying or
    # calling their package-specific guest/build functions.
    bazel = root.parent / 'bazel'
    if bazel.is_symlink() or bazel.resolve() != bazel or not bazel.is_dir():
        raise ValueError('Shared controller sibling directory is unavailable')
    required = {str(path) for directory in (root, bazel) for path in directory.rglob('*.py')}
    if not required.issubset(bindings):
        raise ValueError('Imported controller source closure is not hash-bound')
    for path in required:
        private(path, bindings[path])
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['context', 'installation-core', 'testing-root', 'ssd-scratch', 'retained-root', 'receipt-output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--context-sha256', required=True)
    parser.add_argument('--installation-core-sha256', required=True)
    parser.add_argument('--test-tap', required=True)
    args = parser.parse_args()
    context = json.loads(private(args.context, args.context_sha256))
    for path, expected in context['controllerFilesSHA256'].items():
        private(path, expected)
    private(args.installation_core, args.installation_core_sha256)
    testing_root = authenticate_testing_root(args.testing_root, context['controllerFilesSHA256'])
    spec = importlib.util.spec_from_file_location('owned_compose_installation_core', args.installation_core)
    core = importlib.util.module_from_spec(spec)
    core.AUTHENTICATED_TESTING_ROOT = testing_root
    spec.loader.exec_module(core)
    # The admitted core's testing modules own the common host lease/guard.
    result = transaction(core, context, args).run()
    print(json.dumps(result, sort_keys=True))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
