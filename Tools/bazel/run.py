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

"""Compose-owned Bazel launcher: enrolled SSD, locked cache, source-bound evidence."""
from __future__ import annotations

import fcntl
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from input_identity import source_identity, verify
from retain_evidence import retain, restore_candidate

ROOT = Path(__file__).resolve().parents[2]
SSD = Path('/Volumes/SSD/cf/bazel')
VOLUME = Path('/Volumes/SSD')
RETAINED = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-compose'
ENROLLMENT = Path.home() / 'Library/Application Support/ContainerFamily/retained/workflow/ssd-volume.uuid'
BAZEL = SSD / 'bootstrap/bazel-8.8.0-darwin-arm64'
BAZEL_SHA = 'f0ac192aba2ccaa373cdfd527d4c407cc492c1296a2f11a4b67563e4d5aa9acb'
COMMANDS = {'build', 'test', 'coverage', 'query', 'cquery', 'aquery', 'info', 'shutdown'}
DENIED = ('--flagfile', '--target_pattern_file', '--override_module', '--override_repository',
          '--inject_repository', '--lockfile_mode', '--registry', '--module_mirrors',
          '--experimental_downloader_config', '--enable_bzlmod', '--noenable_bzlmod', '--enable_workspace', '--noenable_workspace',
          '--client_env', '--output_user_root', '--output_base', '--install_base',
          '--bazelrc', '--host_jvm_args', '--disk_cache', '--repository_cache',
          '--repo_contents_cache', '--test_tmpdir', '--sandbox_base', '--sandbox_writable_path',
          '--build_event_', '--profile', '--execution_log_', '--experimental_execution_log',
          '--remote_cache', '--remote_executor', '--symlink_prefix', '--action_env',
          '--test_env', '--host_action_env', '--repo_env', '--run_under',
          '--define=runtime_profile', '--define=DEVCONTAINER_')


def fail(message: str) -> None:
    raise ValueError(message)


def usage() -> str:
    return ('Usage: Tools/bazel/run.sh build|test|coverage|query|cquery|aquery|info|shutdown [Bazel args]\n'
            '       Tools/bazel/run.sh coverage-report ID [--minimum-percent N] [--inventory=unit|unit-cli] [--config=stock|enhanced]\n'
            '       Tools/bazel/run.sh restore-candidate ID\n'
            'All build scratch/cache stays on the enrolled SSD; invocation reports and candidate bytes are retained internally.\n')


def ensure_dir(path: Path) -> None:
    if not path.is_absolute() or '..' in path.parts:
        fail('Storage path must be absolute without traversal')
    current = Path('/')
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            fail(f'Refusing symlinked storage: {current}')
        if current.exists() and not current.is_dir():
            fail(f'Not a directory: {current}')
        current.mkdir(exist_ok=True)


def preflight() -> None:
    if os.uname().sysname != 'Darwin' or os.uname().machine != 'arm64':
        fail('Apple silicon macOS is required')
    if ROOT.joinpath('.bazelversion').read_text().strip() != '8.8.0':
        fail('Unsupported Bazel version')
    if ENROLLMENT.is_symlink() or not ENROLLMENT.is_file():
        fail('Missing enrolled SSD UUID')
    plist = subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(VOLUME)])
    def field(name: str) -> str:
        return subprocess.check_output(['/usr/bin/plutil', '-extract', name, 'raw', '-'], input=plist, text=False).decode().strip()
    expected = ENROLLMENT.read_text().strip()
    if not re.fullmatch(r'[A-Fa-f0-9-]{36}', expected) or (field('VolumeUUID'), field('MountPoint'), field('Internal')) != (expected, str(VOLUME), 'false'):
        fail('Enrolled external SSD identity or mount does not match')
    if RETAINED.is_symlink():
        fail('Refusing symlinked retained evidence')
    for path in (SSD, SSD / 'tmp', SSD / 't', SSD / 'output', SSD / 'cache', SSD / 'repository',
                 SSD / 'invocations', SSD / 'locks', RETAINED):
        ensure_dir(path)
    if RETAINED.stat().st_dev != Path.home().stat().st_dev:
        fail('Retained evidence must be on internal home storage')
    if BAZEL.is_symlink() or not BAZEL.is_file() or hashlib.sha256(BAZEL.read_bytes()).hexdigest() != BAZEL_SHA:
        fail('Pinned Bazel binary missing or checksum mismatch')


def clean_env() -> dict[str, str]:
    # Bazel records its client environment in BEP; inherit no caller secrets.
    user = subprocess.check_output(['/usr/bin/id', '-un'], text=True).strip()
    developer = os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    if not Path(developer, 'Platforms/MacOSX.platform').is_dir():
        fail('DEVELOPER_DIR must select full Xcode')
    return {'HOME': str(Path.home()), 'USER': user, 'LOGNAME': user,
            'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8',
            'TMPDIR': str(SSD / 'tmp'), 'TMP': str(SSD / 'tmp'), 'TEMP': str(SSD / 'tmp'),
            'DEVELOPER_DIR': developer, 'PYTHONDONTWRITEBYTECODE': '1',
            'GIT_TERMINAL_PROMPT': '0', 'GIT_ASKPASS': '/usr/bin/false',
            'GCM_INTERACTIVE': 'never', 'SSH_ASKPASS': '/usr/bin/false',
            'SSH_ASKPASS_REQUIRE': 'never', 'GIT_SSH_COMMAND': '/usr/bin/ssh -oBatchMode=yes'}


def validated_args(arguments: list[str]) -> tuple[str, list[str]]:
    profile = None
    result = []
    for argument in arguments:
        if argument in {'--define', '--repo_env', '--action_env', '--test_env', '--host_action_env'}:
            fail(f'Split form of {argument} is not supported')
        if argument.startswith('--config=') and argument not in {'--config=stock', '--config=enhanced', '--config=release', '--config=asan', '--config=tsan', '--config=prebuilt-argument-parser', '--config=prebuilt-foundation', '--config=prebuilt-containerization', '--config=prebuilt-engine-api', '--config=prebuilt-container-sdk'}:
            fail('Unknown Bazel config')
        if argument in ('--config=stock', '--config=enhanced'):
            selected = argument.split('=', 1)[1]
            if profile is not None and profile != selected:
                fail('Select one runtime profile')
            profile = selected
        elif argument == '--config' or argument.startswith(DENIED):
            fail(f'Unsupported Bazel argument: {argument.split("=", 1)[0]}')
        else:
            result.append(argument)
    return profile or 'enhanced', result


def source_snapshot() -> dict:
    observed = source_identity(ROOT)
    observed['tooling'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted((ROOT / 'Tools/bazel').iterdir())
                           if p.suffix in {'.py', '.sh'}}
    return observed


@contextmanager
def workspace_lease(command: str):
    lock_path = SSD / 'locks' / (hashlib.sha256(str(ROOT).encode()).hexdigest() + '.lock')
    with lock_path.open('a+b') as lock:
        deadline = time.monotonic() + 300
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    fail('Timed out waiting for Compose workspace Bazel lease')
                time.sleep(1)
        recovery = lock_path.with_suffix('.recovery-required.json')
        if recovery.exists() and command != 'shutdown':
            fail(f'Prior cancellation left Bazel server state uncertain; run local shutdown and inspect {recovery}')
        yield recovery


def locked_run(command: str, arguments: list[str], profile: str, environment: dict[str, str]) -> int:
    with workspace_lease(command) as recovery:
        result = execute(command, arguments, profile, environment, recovery)
        if command == 'shutdown' and result == 0:
            recovery.unlink(missing_ok=True)
        return result



def run_owned(argv: list[str], log_path: Path, environment: dict[str, str],
              recovery: Path | None = None, cancel_grace: float = 30) -> int:
    """Forward cancellation to only our client and keep the lease until it ends."""
    requested: list[int] = []
    process: subprocess.Popen[bytes] | None = None
    original = {kind: signal.getsignal(kind) for kind in (signal.SIGINT, signal.SIGTERM)}

    def quarantine(reason: str) -> None:
        if recovery is not None:
            recovery.write_text(json.dumps({'schema': 1, 'reason': reason,
                'pid': process.pid if process else None,
                'timeUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}) + '\n')

    def forward(kind: int, _frame: object) -> None:
        if not requested:
            requested.append(kind)
            if process is not None and process.poll() is None:
                process.send_signal(kind)

    # Install before Popen so wrapper-only TERM cannot strand a newly started
    # Bazel client in the assignment gap. Python runs deferred handlers as soon
    # as Popen returns; a pending cancellation is forwarded below.
    for kind in original:
        signal.signal(kind, forward)
    try:
        with log_path.open('wb') as log:
            process = subprocess.Popen(argv, cwd=ROOT, env=environment, stdout=log,
                                       stderr=subprocess.STDOUT)
            if requested and process.poll() is None:
                process.send_signal(requested[0])
            position = 0
            cancellation_deadline: float | None = None
            while True:
                with log_path.open('rb') as reader:
                    reader.seek(position)
                    chunk = reader.read()
                    position += len(chunk)
                if chunk:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                status = process.poll()
                if status is not None:
                    break
                if requested:
                    cancellation_deadline = cancellation_deadline or time.monotonic() + cancel_grace
                    if time.monotonic() >= cancellation_deadline:
                        try:
                            quarantine('owned Bazel client ignored cancellation')
                        finally:
                            process.kill()
                        cancellation_deadline = time.monotonic() + cancel_grace
                time.sleep(0.1)
            with log_path.open('rb') as reader:
                reader.seek(position)
                chunk = reader.read()
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            return 128 + requested[0] if requested else status
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=cancel_grace)
            except subprocess.TimeoutExpired:
                try:
                    quarantine('owned Bazel client required forced termination after supervisor error')
                finally:
                    process.kill()
                    process.wait()
        for kind, handler in original.items():
            signal.signal(kind, handler)


def execute(command: str, arguments: list[str], profile: str, environment: dict[str, str],
            recovery: Path) -> int:
    base = [str(BAZEL), '--nosystem_rc', '--nohome_rc', '--noworkspace_rc',
            f'--bazelrc={ROOT / ".bazelrc"}', f'--output_user_root={SSD / "output"}',
            f'--host_jvm_args=-Djava.io.tmpdir={SSD / "tmp"}', command]
    if command == 'shutdown':
        if arguments:
            fail('shutdown takes no arguments')
        return subprocess.call(base, cwd=ROOT, env=environment)
    if command == 'info':
        return subprocess.call(base + [f'--config={profile}', *arguments,
                                       f'--repository_cache={SSD / "repository"}'], cwd=ROOT, env=environment)
    invocation = SSD / 'invocations' / f'compose-{time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())}-{os.getpid()}'
    invocation.mkdir(mode=0o700)
    before = source_snapshot()
    (invocation / 'inputs-before.json').write_text(json.dumps(before, sort_keys=True) + '\n')
    selected = base + [f'--config={profile}', *arguments]
    if '--config=release' in arguments and command in {'build', 'test', 'coverage'}:
        selected += [f'--define=DEVCONTAINER_COMMIT={before["commit"]}',
                     '--define=DEVCONTAINER_BUILD_LANE=candidate',
                     f'--define=DEVCONTAINER_SOURCE_DIRTY={str(before["dirty"]).lower()}']
    if command in {'build', 'test', 'coverage'}:
        selected.append(f'--disk_cache={SSD / "cache"}')
    if command in {'test', 'coverage'}:
        key = hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
        selected.append(f'--test_tmpdir={SSD / "t" / key}')
    selected += [f'--repository_cache={SSD / "repository"}',
                 f'--build_event_json_file={invocation / "events.json"}']
    (invocation / 'owner.json').write_text(json.dumps({'schema': 1, 'workspace': str(ROOT),
        'profile': profile, 'command': command, 'invocation': invocation.name}, sort_keys=True) + '\n')
    print(f'Compose Bazel evidence: {invocation}', file=sys.stderr, flush=True)
    recovery.write_text(json.dumps({'schema': 1, 'reason': 'in-flight Bazel client',
        'invocation': invocation.name}) + '\n')
    start = time.monotonic()
    status = run_owned(selected, invocation / 'console.log', environment, recovery)
    (invocation / 'timing.json').write_text(json.dumps({'seconds': time.monotonic() - start,
        'profile': profile, 'command': command}, sort_keys=True) + '\n')
    validation = 0
    try:
        after = source_snapshot()
        verify(before, after)
        (invocation / 'inputs-after.json').write_text(json.dumps(after, sort_keys=True) + '\n')
        suite = 'source' if command in {'test', 'coverage'} and any(
            arg in {'//:unit_stock', '//:unit_enhanced', '//:coverage_stock', '//:coverage_enhanced'}
            for arg in arguments) else ''
        (invocation / 'outcome.json').write_text(json.dumps({'bazel_exit_code': status,
            'validation_exit_code': 0, 'suite': suite}, sort_keys=True) + '\n')
        if status == 0 and suite:
            check = [sys.executable, str(ROOT / 'Tools/bazel/check_evidence.py'),
                     str(invocation / 'events.json'), '--suite', 'source', '--profile', profile,
                     '--policy', str(ROOT / 'Tools/bazel/evidence-policy.json')]
            if command == 'test':
                check.append('--tests-only')
            else:
                inventory = 'unit-cli' if any(arg in {'//:coverage_stock', '//:coverage_enhanced'}
                                              for arg in arguments) else 'unit'
                check += ['--inventory', inventory]
            with (invocation / 'source-tests.json').open('w') as report:
                subprocess.run(check, cwd=ROOT, env=environment, stdout=report, check=True)
    except (ValueError, subprocess.CalledProcessError) as error:
        validation = 2
        print(f'Evidence validation failed: {error}', file=sys.stderr)
    (invocation / 'outcome.json').write_text(json.dumps({'bazel_exit_code': status,
        'validation_exit_code': validation, 'suite': suite if 'suite' in locals() else ''}, sort_keys=True) + '\n')
    try:
        if (invocation / 'events.json').is_file():
            identifier = retain(invocation / 'events.json', RETAINED / 'bazel-evidence.sqlite', SSD)
            print(f'Retained Compose Bazel invocation: {identifier}', file=sys.stderr)
            if json.loads(recovery.read_text()).get('reason') == 'in-flight Bazel client':
                recovery.unlink()
        else:
            fail('Missing Bazel event stream; invocation was not retained')
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f'Evidence retention failed; preserve {invocation}: {error}', file=sys.stderr)
        return status or 2
    return status or validation


def main(arguments: list[str]) -> int:
    if not arguments or arguments[0] in {'-h', '--help'}:
        print(usage(), end='')
        return 0 if arguments else 2
    command, *rest = arguments
    if command not in COMMANDS | {'coverage-report', 'restore-candidate'}:
        fail('Unsupported command; use --help')
    os.umask(0o077)
    preflight()
    environment = clean_env()
    if command == 'restore-candidate':
        if len(rest) != 1 or not re.fullmatch(r'[0-9a-f-]{36}', rest[0]):
            fail('restore-candidate requires one invocation UUID')
        print(restore_candidate(RETAINED / 'bazel-evidence.sqlite', rest[0], SSD))
        return 0
    if command == 'coverage-report':
        if not rest or not re.fullmatch(r'[0-9a-f-]{36}', rest[0]):
            fail('coverage-report requires one invocation UUID')
        identifier, *options = rest
        profile = 'enhanced'
        inventory = 'unit'
        report_args = [identifier]
        threshold = False
        while options:
            option = options.pop(0)
            if option.startswith('--config=') and option.split('=', 1)[1] in {'stock', 'enhanced'}:
                profile = option.split('=', 1)[1]
            elif option.startswith('--inventory=') and option.split('=', 1)[1] in {'unit', 'unit-cli'}:
                inventory = option.split('=', 1)[1]
            elif option == '--minimum-percent' and options:
                report_args += [option, options.pop(0)]
                threshold = True
            else:
                fail('Invalid coverage-report argument')
        if threshold:
            if source_identity(ROOT)['dirty']:
                fail('Coverage threshold requires a clean source checkout')
            report_args += ['--expected-commit', source_identity(ROOT)['commit'],
                            '--expected-profile', profile, '--expected-inventory', inventory,
                            '--expected-policy', str(ROOT / 'Tools/bazel/evidence-policy.json')]
        elif inventory != 'unit':
            fail('Inventory selection requires a coverage threshold')
        return subprocess.call([sys.executable, str(ROOT / 'Tools/bazel/coverage_report.py'),
                                *report_args], cwd=ROOT, env=environment)
    profile, supplied = validated_args(rest)
    package_configs = {'--config=prebuilt-argument-parser', '--config=prebuilt-foundation',
                       '--config=prebuilt-containerization', '--config=prebuilt-engine-api',
                       '--config=prebuilt-container-sdk'}
    if any(config in supplied for config in package_configs):
        if '--config=release' not in supplied:
            fail('Prebuilt Swift package requires the exact release compilation mode')
        conflicting = ('-c', '--compilation_mode', '--features', '--copt', '--conlyopt',
                       '--cxxopt', '--swiftcopt', '--macos_minimum_os', '--xcode_version',
                       '--macos_sdk_version', '--platforms', '--host_platform', '--cpu',
                       '--host_cpu', '--apple_platform_type', '--apple_split_cpu',
                       '--extra_toolchains', '--define',
                       '--@build_bazel_rules_swift//swift:copt')
        if any(arg in {'--config=asan', '--config=tsan'} or
               any(arg == flag or arg.startswith(flag + '=') for flag in conflicting)
               for arg in supplied):
            fail('Prebuilt Swift package cannot be combined with a different compilation configuration')
    selected_groups = set()
    if '--config=prebuilt-container-sdk' in supplied:
        selected_groups.update(('foundation', 'containerization', 'engine-api', 'container-sdk'))
    if '--config=prebuilt-containerization' in supplied:
        selected_groups.update(('foundation', 'containerization'))
    if '--config=prebuilt-engine-api' in supplied:
        selected_groups.update(('foundation', 'engine-api'))
    if '--config=prebuilt-foundation' in supplied:
        selected_groups.add('foundation')
    if selected_groups:
        from artifacts.foundation import layer_lock_path, verify_consumer as verify_layer
        from artifacts.layer_release import cached_release as cached_package_layer
        mirrors = {'foundation': 'COMPOSE_FOUNDATION_LAYER_MIRROR',
                   'containerization': 'COMPOSE_CONTAINERIZATION_LAYER_MIRROR',
                   'engine-api': 'COMPOSE_ENGINE_API_LAYER_MIRROR',
                   'container-sdk': 'COMPOSE_CONTAINER_SDK_LAYER_MIRROR'}
        for group in ('foundation', 'containerization', 'engine-api', 'container-sdk'):
            if group not in selected_groups:
                continue
            lock_path = layer_lock_path(ROOT, group, profile)
            mirror = os.environ.get(mirrors[group], '')
            verify_layer(lock_path, ROOT, Path(mirror) if mirror else None, environment, profile, group)
            archive = Path(mirror) if mirror else cached_package_layer(
                lock_path, RETAINED / 'binary-layers' / group / profile)
            verify_layer(lock_path, ROOT, archive, environment, profile, group)
            environment[mirrors[group]] = str(archive)
    if '--config=prebuilt-argument-parser' in supplied or selected_groups:
        from artifacts.argument_parser import cached_release, verify_consumer
        mirror = os.environ.get('COMPOSE_ARGUMENT_PARSER_LAYER_MIRROR', '')
        lock = ROOT / 'Tools/bazel/artifacts/argument-parser.lock.json'
        verify_consumer(lock, ROOT, None, environment)
        archive = Path(mirror) if mirror else cached_release(lock, RETAINED / 'binary-layers/argument-parser')
        verify_consumer(lock, ROOT, archive, environment)
        environment['COMPOSE_ARGUMENT_PARSER_LAYER_MIRROR'] = str(archive)
    return locked_run(command, supplied, profile, environment)


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f'Compose Bazel: {exc}', file=sys.stderr)
        sys.exit(2)
