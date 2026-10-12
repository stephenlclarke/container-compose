#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Qualify a stock Engine test-only binary supplement in an isolated workspace.

The five product layers and their recipes are never changed. The producer may
compile only configured package targets absent from those layers. The consumer
imports every package library; test execution is required for qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import sys
import tarfile
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse
from contextlib import contextmanager

import run as launcher
from artifacts import argument_parser as argument
from artifacts import foundation
from input_identity import source_identity

TARGET = '//:ComposeEngineRuntimeTests'
GROUPS = ('argument-parser', 'foundation', 'containerization', 'engine-api', 'container-sdk')
PACKAGE = re.compile(r'@{1,2}(?:\+dependencies\+)?(swiftpkg_[a-z0-9_]+)//:([^/]+)\Z')
SHA = re.compile(r'[a-f0-9]{64}\Z')
COMPILERS = {'swift_library', 'cc_library'}


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def safe_name(value: str) -> str:
    if (not value or value.startswith('/') or '\\' in value
            or any(part in ('', '.', '..') for part in value.split('/'))):
        raise ValueError('Noncanonical archive path: ' + value)
    return value


def read_members(path: Path, expected_sha: str | None = None) -> dict[str, bytes]:
    payload = path.read_bytes()
    if expected_sha is not None and digest(payload) != expected_sha:
        raise ValueError('Product archive changed during admission')
    result = {}
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
        for member in archive:
            name = safe_name(member.name)
            if not member.isfile() or member.issym() or member.islnk() or name in result:
                raise ValueError('Unsafe or duplicate archive member: ' + name)
            result[name] = archive.extractfile(member).read()
    return result


def write_members(directory: Path, members: dict[str, bytes]) -> None:
    directory.mkdir(parents=True)
    for name, payload in members.items():
        path = directory / safe_name(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)


def bookkeeping_collision(name: str, generated: bytes, published: bytes, build: str) -> dict:
    # SwiftPM writes its generator PID here; it is not an input to any rule.
    # Admit only this observed bookkeeping path, with no explicit or glob use.
    if (name != '.build/.lock' or '.build' in build or '.lock' in build
            or re.search(r'\bglob\s*\(', build)
            or any(not re.fullmatch(rb'[1-9][0-9]{0,9}', value)
                   or int(value) > 2147483647 for value in (generated, published))):
        raise ValueError('Product metadata differs from generated package: ' + name)
    return {'path': name, 'generatedSHA256': digest(generated),
            'publishedSHA256': digest(published), 'disposition': 'authenticated-product-bytes-retained'}


def tree_identity(root: Path) -> dict:
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Generated workspace contains a symlink')
        if path.is_file():
            files[path.relative_to(root).as_posix()] = {
                'sha256': digest(path.read_bytes()), 'mode': path.stat().st_mode & 0o7777}
        elif not path.is_dir():
            raise ValueError('Generated workspace contains a special file')
    return files


def assignments(build: str, name: str) -> object:
    rows = re.findall(r'^' + name + r' = (.+)$', build, re.M)
    if len(rows) != 1:
        raise ValueError('Missing unique binary map: ' + name)
    return json.loads(rows[0])


def load_layers(root: Path, paths: dict, environment: dict) -> tuple[dict, dict]:
    if set(paths) != set(GROUPS):
        raise ValueError('Exactly five product archives are required')
    packages, admitted = {}, {}
    for group in GROUPS:
        row = paths[group]
        if not isinstance(row, dict) or set(row) != {'archive', 'archiveSHA256', 'lock', 'lockSHA256'}:
            raise ValueError('Each layer requires archive and lock identities')
        path = Path(row['archive'])
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise ValueError('Product archive must be an absolute regular file')
        lock_path = (root / 'Tools/bazel/artifacts/argument-parser.lock.json' if group == 'argument-parser'
                     else foundation.layer_lock_path(root, group, 'stock'))
        lock = json.loads(lock_path.read_text())
        if (digest(lock_path.read_bytes()) != row['lockSHA256']
                or lock['archiveSHA256'] != row['archiveSHA256']
                or Path(row['lock']).read_bytes() != lock_path.read_bytes()):
            raise ValueError('Product input map differs from current source locks')
        if group == 'argument-parser':
            argument.verify_consumer(lock_path, root, path, environment)
            observed = argument.inspect(path, lock['archiveSHA256'])
        else:
            foundation.verify_consumer(lock_path, root, path, environment, 'stock', group)
            observed = foundation.inspect(path, lock['archiveSHA256'])
        if group != 'argument-parser' and lock.get('developmentProof') is not False:
            raise ValueError('Test support requires published product layers')
        members = read_members(path, lock['archiveSHA256'])
        admitted[group] = {'lock': lock, 'manifest': observed['manifest'],
                           'archiveSHA256': observed['archiveSHA256']}
        if group == 'argument-parser':
            repo = 'swiftpkg_swift_argument_parser'
            files = {name.removeprefix('argument-parser/'): value for name, value in members.items()}
            swift = {name + '.rspm.__impl': {
                'swiftmodule': name + '.swiftmodule', 'swiftdoc': name + '.swiftdoc',
                'archive': 'lib' + name + '.rspm.__impl.a'} for name in argument.MODULES}
            packages[repo] = {'files': files, 'swift': swift, 'cc': {}, 'headers': [], 'headerSources': {},
                              'generatedBuildSHA256': observed['manifest']['toolchain']['generatedBuildSHA256']}
        else:
            for row in observed['manifest']['packages'].values():
                repo = row['repository']
                if repo in packages:
                    raise ValueError('Product layers duplicate a package')
                prefix = group + '/' + repo + '/'
                files = {name.removeprefix(prefix): value for name, value in members.items()
                         if name.startswith(prefix)}
                generated = files['prebuilt.bzl'].decode()
                packages[repo] = {'files': files,
                                  'swift': assignments(generated, 'SWIFT'),
                                  'cc': assignments(generated, 'C'),
                                  'headers': assignments(generated, 'C_HEADER_ONLY'),
                                  'headerSources': assignments(generated, 'C_SRC_HEADERS')}
    tools = [row['manifest']['toolchain'] for row in admitted.values()]
    keys = set(tools[1])
    if any({key: value.get(key) for key in keys} != {key: tools[0].get(key) for key in keys}
           for value in tools[1:]):
        raise ValueError('Product layers have different toolchains')
    return packages, admitted


def configured_graph(document: dict) -> dict:
    configurations = {row['checksum']: row for row in document['configurations']}
    result = {}
    for item in document['results']:
        rule = item.get('target', {}).get('rule')
        if not rule:
            continue
        match = PACKAGE.fullmatch(rule['name'])
        if not match:
            continue
        checksum = item.get('configuration', {}).get('checksum')
        if not SHA.fullmatch(checksum or '') or checksum not in configurations:
            raise ValueError('Package target lacks its configured variant')
        config = configurations[checksum]
        options = {option['name']: option['value'] for fragment in config['fragmentOptions']
                   for option in fragment.get('options', [])}
        if (rule['ruleClass'] in COMPILERS | {'swift_import', 'cc_import'}
                and (options.get('compilation_mode') != 'opt'
                     or options.get('--define:runtime_profile') != 'stock'
                     or not options.get('macos_minimum_os'))):
            raise ValueError('Unsupported package compilation configuration')
        repo, target = match.groups()
        key = repo + ':' + target + ':' + checksum
        if key in result:
            raise ValueError('Duplicate configured target')
        result[key] = {'repository': repo, 'target': target, 'kind': rule['ruleClass'],
                       'configuration': {key: value for key, value in config.items() if key != 'id'},
                       'attributes': {attr['name']: attr for attr in rule['attribute']}}
    if not result:
        raise ValueError('Configured package graph is empty')
    return result


def missing_targets(graph: dict, packages: dict) -> dict:
    missing = {name: {'swift': set(), 'cc': set()} for name in packages}
    for row in graph.values():
        if row['kind'] not in COMPILERS:
            continue
        repo, target = row['repository'], row['target']
        if repo not in packages:
            raise ValueError('Configured library lacks an authenticated product package: ' + repo)
        package = packages[repo]
        if row['kind'] == 'swift_library':
            if target not in package['swift']:
                missing[repo]['swift'].add(target)
        elif target not in package['cc'] and target not in package['headers']:
            # Header-only libraries have no binary to supplement.
            srcs = row['attributes'].get('srcs', {}).get('stringListValue', [])
            if any(Path(source).suffix not in {'.h', '.hpp', '.inc', '.def', '.modulemap'} for source in srcs):
                missing[repo]['cc'].add(target)
    return missing


def merge_delta(package: dict, swift: dict, cc: dict, files: dict) -> dict:
    if (set(swift) & set(package['swift']) or set(cc) & (set(package['cc']) | set(package['headers']))
            or set(files) & set(package['files'])):
        raise ValueError('Supplement would overwrite a published binary or metadata')
    result = dict(package)
    result['swift'] = {**package['swift'], **swift}
    result['cc'] = {**package['cc'], **cc}
    result['files'] = {**package['files'], **files}
    return result


def overlay_build(original: str, package: dict, missing: dict, producer: bool) -> tuple[str, str]:
    # Reuse the maintained transformation; all generated minimum-OS wrappers,
    # dependency edges, resources and metadata remain in the original BUILD.
    build = foundation.transformed_build(original)
    maps = ('SWIFT = ' + json.dumps(package['swift'], sort_keys=True) + '\n'
            'C = ' + json.dumps(package['cc'], sort_keys=True) + '\n'
            'HEADERS = ' + json.dumps(package['headers']) + '\n'
            'HEADER_SOURCES = ' + json.dumps(package['headerSources'], sort_keys=True) + '\n')
    if producer:
        prebuilt = ('load("@//Tools/bazel:test_support_import.bzl", "support_swift_library", "support_cc_library")\n'
                    + maps + 'MISSING_SWIFT = ' + json.dumps(sorted(missing['swift'])) + '\n'
                    + 'MISSING_C = ' + json.dumps(sorted(missing['cc'])) + '\n'
                    + 'def foundation_swift_library(**kwargs):\n'
                    + '    support_swift_library(SWIFT, MISSING_SWIFT, **kwargs)\n'
                    + 'def foundation_cc_library(**kwargs):\n'
                    + '    support_cc_library(C, HEADERS, HEADER_SOURCES, MISSING_C, **kwargs)\n')
    else:
        prebuilt = ('load("@//Tools/bazel/artifacts:foundation_import.bzl", "import_swift_library", "import_cc_library")\n'
                    + maps + 'def foundation_swift_library(**kwargs):\n'
                    + '    import_swift_library(SWIFT, **kwargs)\n'
                    + 'def foundation_cc_library(**kwargs):\n'
                    + '    import_cc_library(C, HEADERS, HEADER_SOURCES, **kwargs)\n')
    return build, prebuilt


def assert_variants(expected: dict, observed: dict, missing: dict) -> None:
    # Import rules replace compiler rules but retain target names and the
    # configured minimum-OS transitions. Require every selected library variant.
    for key, row in expected.items():
        if row['kind'] not in COMPILERS:
            continue
        candidate = observed.get(key)
        if candidate is None or candidate['configuration'] != row['configuration']:
            raise ValueError('Configured library variant changed: ' + key)
        expected_kind = row['kind'] if row['target'] in missing[row['repository']][
            'swift' if row['kind'] == 'swift_library' else 'cc'] else None
        if expected_kind and candidate['kind'] != expected_kind:
            raise ValueError('Producer lost an admitted source target: ' + key)


def assert_compile_actions(document: dict, missing: dict) -> None:
    targets = {str(row['id']): row['label'] for row in document.get('targets', [])}
    for action in document.get('actions', []):
        label = targets.get(str(action.get('targetId')), '')
        match = PACKAGE.fullmatch(label)
        if match and (action.get('mnemonic', '').startswith('SwiftCompile')
                      or action.get('mnemonic') in {'CppCompile', 'ObjcCompile', 'CppModuleCompile'}):
            repo, target = match.groups()
            allowed = missing.get(repo, {'swift': set(), 'cc': set()})
            if target not in allowed['swift'] | allowed['cc']:
                raise ValueError('Unexpected lower source compilation: ' + label)


def xml_testcase_count(payload: bytes) -> int:
    root = ET.fromstring(payload)
    if root.tag not in {'testsuite', 'testsuites'}:
        raise ValueError('Unexpected test XML root')
    cases = list(root.iter('testcase'))
    if not cases or any(list(root.iter(name)) for name in ('failure', 'error', 'skipped')):
        raise ValueError('Test XML has no cases or reports failures/skips')
    for suite in root.iter():
        if suite.tag not in {'testsuite', 'testsuites'}:
            continue
        expected = {'tests': len(list(suite.iter('testcase'))), 'failures': 0, 'errors': 0, 'skipped': 0}
        for name, count in expected.items():
            declared = suite.get(name)
            if declared is not None and (not declared.isdecimal() or int(declared) != count):
                raise ValueError('Contradictory XML suite total: ' + name)
    return len(cases)


def validate_test_summary(events: list[dict]) -> None:
    # Bazel 8.8 TestSummary.total_run_count counts shard attempts, not XML
    # testcases. This runner deliberately admits one fresh, unsharded attempt.
    summaries = [row for row in events if 'testSummary' in row]
    results = [row for row in events if 'testResult' in row]
    if (len(summaries) != 1 or len(results) != 1
            or summaries[0].get('id', {}).get('testSummary', {}).get('label') != TARGET
            or results[0].get('id', {}).get('testResult', {}).get('label') != TARGET
            or summaries[0]['testSummary'].get('overallStatus') != 'PASSED'):
        raise ValueError('Consumer did not execute one passing test suite')
    summary = summaries[0]['testSummary']
    result_id = results[0]['id']['testResult']
    summary_id = summaries[0]['id']['testSummary']
    if (summary.get('totalRunCount') != len(results) or summary.get('totalNumCached', 0) != 0
            or any(summary.get(name, 1) != 1 for name in ('runCount', 'attemptCount'))
            or summary.get('shardCount', 0) not in (0, 1)
            or result_id.get('run', 1) != 1 or result_id.get('attempt', 1) != 1
            or result_id.get('shard', 0) != 0
            or result_id.get('configuration') != summary_id.get('configuration')):
        raise ValueError('Contradictory BEP run/attempt/configuration evidence')


def retain_test_xml(events: list[dict], output: Path, output_base: Path) -> int:
    results = [row for row in events if 'testResult' in row]
    if (len(results) != 1 or results[0]['testResult'].get('status') != 'PASSED'
            or results[0].get('id', {}).get('testResult', {}).get('label') != TARGET):
        raise ValueError('Missing one actual passing test result')
    result = results[0]['testResult']
    if result.get('cachedLocally') or result.get('executionInfo', {}).get('cachedRemotely'):
        raise ValueError('Test-support qualification requires fresh test execution')
    files = {row['name']: row for row in result.get('testActionOutput', [])}
    if not {'test.xml', 'test.log'}.issubset(files):
        raise ValueError('Missing fresh test XML/log')
    payload = b''
    for name in ('test.xml', 'test.log'):
        uri = urlparse(files[name]['uri'])
        if uri.scheme != 'file' or uri.netloc:
            raise ValueError('Test output must be a local declared output')
        path = Path(unquote(uri.path)).resolve(strict=True)
        if not path.is_relative_to(output_base.resolve(strict=True)):
            raise ValueError('Test output escapes the owned output base')
        content = path.read_bytes()
        if name == 'test.xml':
            payload = content
        else:
            output.with_suffix('.test.log').write_bytes(content)
    count = xml_testcase_count(payload)
    output.write_bytes(payload)
    return count


def json_document(log: str) -> dict:
    # The owned launcher coalesces Bazel progress stderr with stdout. There must
    # be exactly one unindented JSON document, never an arbitrary brace search.
    starts = list(re.finditer(r'^\{', log, re.M))
    if len(starts) != 1:
        raise ValueError('Expected one Bazel JSON document')
    document, _ = json.JSONDecoder().raw_decode(log[starts[0].start():])
    return document


def info_path(log: str) -> Path:
    paths = [Path(line) for line in log.splitlines() if line.startswith('/')]
    if len(paths) != 1 or not paths[0].is_dir():
        raise ValueError('Bazel info did not identify one existing directory')
    return paths[0]


@contextmanager
def selected_workspace(workspace: Path):
    # This CLI is single-threaded. Reuse the maintained cancellation/reaping
    # implementation while explicitly selecting its Popen cwd; always restore
    # the source root before any subsequent provenance/admission operation.
    previous = launcher.ROOT
    launcher.ROOT = workspace
    try:
        yield
    finally:
        launcher.ROOT = previous


class Workspace:
    def __init__(self, root: Path, output: Path, environment: dict, recovery: Path):
        self.root, self.output, self.environment, self.recovery = root, output, environment, recovery
        self.workspace = output / 'workspace'
        self.number = 0
        self.overrides = []
        self.overlay_directory = None
        self.testcase_count = None
        self.metadata_dispositions = []
        self.base = [str(launcher.BAZEL), '--nosystem_rc', '--nohome_rc', '--noworkspace_rc',
                     '--bazelrc=' + str(self.workspace / '.bazelrc'),
                     '--output_user_root=' + str(launcher.SSD / 'output'),
                     '--host_jvm_args=-Djava.io.tmpdir=' + str(launcher.SSD / 'tmp')]

    def invoke(self, command: str, arguments: list[str]) -> str:
        self.number += 1
        stem = self.output / f'{self.number:02d}-{command}'
        flags = ([] if command == 'shutdown' else ['--config=stock', '--config=release',
                 '--features=swift.enable_testing', '--nocache_test_results',
                 '--run_under=//Tools/bazel:ssd_test_runner', '--test_env=TMPDIR', '--test_env=HOME',
                 '--test_output=errors', '--flaky_test_attempts=1', '--local_test_jobs=2',
                 '--test_tmpdir=' + str(launcher.SSD / 't' / self.output.name),
                 '--repository_cache=' + str(launcher.SSD / 'repository'),
                 *self.overrides])
        if command in {'build', 'test'}:
            flags += ['--disk_cache=' + str(launcher.SSD / 'cache'),
                      '--build_event_json_file=' + str(stem) + '.bep.json']
        argv = self.base + [command, *flags, *arguments]
        write_json(stem.with_suffix('.argv.json'), argv)
        before = self.identity()
        write_json(Path(str(stem) + '.inputs-before.json'), before)
        with selected_workspace(self.workspace):
            status = launcher.run_owned(argv, stem.with_suffix('.log'), self.environment, self.recovery)
        after = self.identity()
        write_json(Path(str(stem) + '.inputs-after.json'), after)
        if command in {'build', 'test'} and before != after:
            raise ValueError('Generated test-support inputs changed during execution')
        if status:
            raise RuntimeError(f'Test-support {command} failed ({status}); see {stem}.log')
        if command == 'shutdown':
            self.recovery.unlink(missing_ok=True)
        if command in {'build', 'test'}:
            events = [json.loads(line) for line in Path(str(stem) + '.bep.json').read_text().splitlines()]
            commands = [row['unstructuredCommandLine']['args'] for row in events if 'unstructuredCommandLine' in row]
            expected = [command, *flags, *arguments]
            if (len(commands) != 1 or commands[0][0] != command
                    or commands[0][-len(expected[1:]):] != expected[1:]
                    or '--client_cwd=' + str(self.workspace) not in commands[0]):
                raise ValueError('BEP command differs from owned test-support invocation')
            options = [row['optionsParsed']['cmdLine'] for row in events if 'optionsParsed' in row]
            required = {'--compilation_mode=opt', '--macos_minimum_os=15.0',
                        '--define=runtime_profile=stock', '--features=swift.enable_testing'}
            if (len(options) != 1 or not required.issubset(options[0])
                    or [item for item in options[0] if item.startswith('--compilation_mode=')][-1:] != ['--compilation_mode=opt']
                    or [item for item in options[0] if item.startswith('--macos_minimum_os=')][-1:] != ['--macos_minimum_os=15.0']):
                raise ValueError('BEP compilation configuration differs from test-support recipe')
            finished = [row['finished'] for row in events if 'finished' in row]
            if (len(finished) != 1 or finished[0].get('overallSuccess') is not True
                    or finished[0].get('exitCode', {}).get('name') != 'SUCCESS'):
                raise ValueError('Missing successful producer/consumer BEP')
            if command == 'test':
                validate_test_summary(events)
                self.testcase_count = retain_test_xml(events, stem.with_suffix('.xml'), self.output_base)
        return stem.with_suffix('.log').read_text()

    def identity(self) -> dict:
        roots = {'workspace': self.workspace}
        if self.overlay_directory is not None:
            roots['packages'] = self.overlay_directory
        return {name: tree_identity(path) for name, path in roots.items()}

    def graph(self) -> dict:
        return configured_graph(json_document(self.invoke('cquery', ['deps(' + TARGET + ')', '--output=jsonproto'])))

    def install(self, packages: dict, sources: dict, missing: dict, producer: bool) -> None:
        self.overrides = []
        directory = self.output / ('producer' if producer else 'consumer')
        self.overlay_directory = directory
        for repo, package in packages.items():
            destination = directory / repo
            source = sources[repo]
            original = (source / 'BUILD.bazel').read_text()
            if producer:
                shutil.copytree(source, destination, symlinks=False)
                # Repository generator metadata must not contain external links.
                for path in source.rglob('*'):
                    if path.is_symlink() and not path.resolve().is_relative_to(source.resolve()):
                        raise ValueError('Package source link escapes pinned repository')
            else:
                write_members(destination, foundation.package_files(source, (source / 'BUILD.bazel').read_text()))
            for name, payload in package['files'].items():
                if name in {'BUILD.bazel', 'prebuilt.bzl'}:
                    continue
                path = destination / safe_name(name)
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.exists() and path.read_bytes() != payload:
                    disposition = bookkeeping_collision(name, path.read_bytes(), payload, original)
                    self.metadata_dispositions.append(dict(disposition, repository=repo,
                                                           stage='producer' if producer else 'consumer'))
                path.write_bytes(payload)
            if 'generatedBuildSHA256' in package:
                if digest(original.encode()) != package['generatedBuildSHA256']:
                    raise ValueError('ArgumentParser generated build differs from published compilation')
            elif package['files']['BUILD.bazel'].decode() != foundation.transformed_build(original):
                raise ValueError('Generated package recipe differs from published compilation: ' + repo)
            build, prebuilt = overlay_build(original, package, missing[repo], producer)
            (destination / 'BUILD.bazel').write_text(build)
            (destination / 'prebuilt.bzl').write_text(prebuilt)
            self.overrides.append('--override_repository=+dependencies+' + repo + '=' + str(destination))
        write_json(self.output / 'metadata-dispositions.json', self.metadata_dispositions)


def run(root: Path, output: Path, layer_paths: dict) -> dict:
    root = root.resolve(strict=True)
    if root != launcher.ROOT.resolve():
        raise ValueError('Run the helper belonging to the selected source root')
    if not output.is_absolute() or output.exists() or output.is_symlink() or '..' in output.parts:
        raise ValueError('Output must be a fresh absolute directory')
    launcher.preflight()
    environment = launcher.clean_env()
    snapshot = source_identity(root)
    if snapshot['dirty']:
        raise ValueError('Test-support qualification requires a clean source checkout')
    packages, layers = load_layers(root, layer_paths, environment)
    output.mkdir(mode=0o700, parents=True)
    write_json(output / 'source-before.json', snapshot)
    with launcher.workspace_lease('test-support') as recovery:
        runner = Workspace(root, output, environment, recovery)
        write_members(runner.workspace, {name: (root / name).read_bytes() for name, row in snapshot['files'].items()
                                        if not row.get('deleted')})
        for name, row in snapshot['files'].items():
            if not row.get('deleted'):
                (runner.workspace / name).chmod(row['mode'])
        try:
            source_graph = runner.graph()
            write_json(output / 'source-graph.json', source_graph)
            reached = {row['repository'] for row in source_graph.values()}
            packages = {repo: package for repo, package in packages.items() if repo in reached}
            output_base = info_path(runner.invoke('info', ['output_base']))
            runner.output_base = output_base
            execution_root = info_path(runner.invoke('info', ['execution_root']))
            sources = {repo: output_base / 'external' / ('+dependencies+' + repo) for repo in packages}
            missing = missing_targets(source_graph, packages)
            if not any(row['swift'] or row['cc'] for row in missing.values()):
                raise ValueError('Selected test graph requires no supplement')
            # Preserve the generator output before repository overrides replace it.
            saved = output / 'source-packages'
            for repo, source in list(sources.items()):
                shutil.copytree(source, saved / repo, symlinks=False)
                sources[repo] = saved / repo
            write_json(output / 'source-packages.json', tree_identity(saved))
            runner.install(packages, sources, missing, True)
            assert_variants(source_graph, runner.graph(), missing)
            runner.invoke('aquery', ['deps(' + TARGET + ')', '--output=jsonproto'])
            actions = json_document((output / f'{runner.number:02d}-aquery.log').read_text())
            assert_compile_actions(actions, missing)
            aspects = [group.replace('-', '_') + '_outputs' for group in foundation.GROUPS]
            runner.invoke('build', [TARGET, '--aspects=' + ','.join(
                '//Tools/bazel/artifacts:compiled_outputs.bzl%' + name for name in aspects),
                '--output_groups=+layer_compiled'])
            listed = runner.invoke('cquery', ['deps(' + TARGET + ')', '--output=files'])
            allowed = {repo: repo for repo in packages}
            binary_files, identities = foundation.artifact_map(listed.splitlines(), execution_root, output_base, allowed)
            delta = {}
            consumers = {}
            for repo, package in packages.items():
                identity = identities[repo]
                modules = foundation.rule_modules((sources[repo] / 'BUILD.bazel').read_text())
                for key in list(identity['swift']):
                    if key not in modules:
                        identity['cc'][key] = identity['swift'].pop(key)['archive']
                selected = missing[repo]
                swift = {key: value for key, value in identity['swift'].items() if key in selected['swift']}
                cc = {key: value for key, value in identity['cc'].items() if key in selected['cc']}
                # Generated module_name can differ from target basename.
                for key, value in swift.items():
                    value['swiftmodule'] = 'binary/' + modules[key] + '.swiftmodule'
                    doc = 'binary/' + modules[key] + '.swiftdoc'
                    if doc in binary_files[repo]:
                        value['swiftdoc'] = doc
                    else:
                        value.pop('swiftdoc', None)
                if set(swift) != selected['swift'] or set(cc) != selected['cc']:
                    raise ValueError('Producer omitted an admitted missing binary: ' + repo)
                names = {name for value in swift.values() for name in value.values()} | set(cc.values())
                files = {name: binary_files[repo][name] for name in names}
                consumers[repo] = merge_delta(package, swift, cc, files)
                consumers[repo]['headerSources'] = {**package['headerSources'], **foundation.compiled_c_header_sources(
                    (sources[repo] / 'BUILD.bazel').read_text(), set(cc))}
                delta.update({repo + '/' + name: payload for name, payload in files.items()})
            runner.install(consumers, sources, missing, False)
            empty = {repo: {'swift': set(), 'cc': set()} for repo in packages}
            assert_variants(source_graph, runner.graph(), empty)
            actions = json_document(runner.invoke('aquery', ['deps(' + TARGET + ')', '--output=jsonproto']))
            assert_compile_actions(actions, empty)
            runner.invoke('test', [TARGET])
        finally:
            runner.invoke('shutdown', [])
        if source_identity(root) != snapshot:
            raise ValueError('Original source changed during test-support qualification')
        for group, row in layer_paths.items():
            if digest(Path(row['archive']).read_bytes()) != layers[group]['archiveSHA256']:
                raise ValueError('Product archive changed during test-support qualification')
        write_json(output / 'source-after.json', snapshot)
        # Seal only new binary members. Existing lower modules are references,
        # never duplicated into the supplement or promoted to new product layers.
        archive_path = output / 'test-support-stock.tar.gz'
        import gzip
        with gzip.GzipFile(filename=str(archive_path), mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, payload in sorted(delta.items()):
                    info = tarfile.TarInfo(name)
                    info.size, info.mode = len(payload), 0o644
                    archive.addfile(info, io.BytesIO(payload))
        receipt = {'schema': 1, 'invocation': str(uuid.uuid4()), 'profile': 'stock',
                   'releaseAuthority': False, 'productInputs': layers, 'source': snapshot,
                   'missingTargets': {repo: {kind: sorted(values) for kind, values in row.items()}
                                      for repo, row in missing.items()},
                   'archiveSHA256': digest(archive_path.read_bytes()),
                   'binaryMembers': {name: digest(payload) for name, payload in delta.items()},
                   'evidence': {path.name: digest(path.read_bytes()) for path in output.iterdir() if path.is_file()},
                   'xmlTestcaseCount': runner.testcase_count, 'testSupportQualified': True}
        write_json(output / 'receipt.json', receipt)
        return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--layers', type=Path, required=True,
                        help='JSON object mapping all five group names to authenticated archive paths')
    args = parser.parse_args()
    print(json.dumps(run(args.root, args.output, json.loads(args.layers.read_text())), sort_keys=True))


if __name__ == '__main__':
    main()
