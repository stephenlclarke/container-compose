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

"""Bind released Q runtime/guest/builder bytes to portable qualified provenance."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Callable

from artifacts.release_asset import read_lock

Q = 'a1effeeaf8c7c1d48b4773262a2d5218dcd5817d'
GUEST = '6db16197bbad8196a78132f86529daa89125aafb'
BUILDER = '016040197215684db474181b444767eb58797cfa'
NAMES = {'runtime': 'container-homebrew-arm64.tar.gz',
         'guest': 'guest.oci.tar', 'builder': 'builder.oci.tar',
         'provenance': 'qualified-container-assets.json'}
SOURCES = {'runtime': ('stephenlclarke/container', Q),
           'provenance': ('stephenlclarke/container', Q),
           'guest': ('stephenlclarke/containerization', GUEST),
           'builder': ('stephenlclarke/container-builder-shim', BUILDER)}
LOCKS = Path(__file__).with_name('artifacts') / 'q-assets'
FETCH = Path(__file__).with_name('artifacts') / 'release_asset.py'
SHA = re.compile(r'[0-9a-f]{64}\Z')
RECEIPTS = {'acceptance.json', 'release/release-artifact.json',
            'runtime-smoke/fork-fingerprint.json',
            'runtime-smoke/guest-artifact.json',
            'runtime-smoke/builder-artifact.json'}


# These are explicit reviewed source contracts, not a missing-field fallback.
LEGACY_Q = '6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc'
NATIVE_GROUPS = ('argument-parser', 'foundation', 'containerization', 'engine-api')
NATIVE_OWNERS = {'argument-parser': 'container', 'foundation': 'container',
                 'containerization': 'containerization', 'engine-api': 'container-engine-api'}
NATIVE_PINS = {'swift-argument-parser': '6a52f3251125d74daf04fcbd5e6f08a75d074382',
               'containerization': '6db16197bbad8196a78132f86529daa89125aafb',
               'container-engine-api': '48e44d74d738ca3d24351ba02c4869be1a3e6998'}
NATIVE_LOWER = {'argument-parser': (), 'foundation': ('argument-parser',),
                'containerization': ('argument-parser', 'foundation'),
                'engine-api': ('argument-parser', 'foundation')}
NATIVE_PRODUCTS = ('container', 'container-apiserver', 'container-engine', 'container-runtime-linux',
                   'container-network-vmnet', 'container-core-images', 'machine-apiserver', 'k8s')
NATIVE_ACTIONS = {'FileWrite', 'TemplateExpand', 'ExecutableSymlink', 'SymlinkTree',
                  'RepoMappingManifest', 'SourceSymlinkManifest', 'Middleman'}
NATIVE_REPOSITORY = re.compile(r'\+dependencies\+swiftpkg_[a-z0-9_]+\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
NATIVE_MEASURED = {'container-measured-fork-arm64.tar.gz', 'container-measured-fork-arm64.json'}
NATIVE_HELPERS = {'libexec/container/helpers/container-semantic-helper',
                  'libexec/container/helpers/container-semantic-helper.manifest.json'}
NATIVE_RECIPE_POLICY = '8a3f3560f358d58baa8679841d54c8f353e59c7b387546a9cff8c4df14aef86e'
NATIVE_RECIPE_OLD = {
    'Tools/bazel/artifacts/native_layers.py': 'fb7d2a828b5d11316288bfb1ec8a1b1908e5f32aafb4912fb2635ed3aa669630',
    'Tools/bazel/artifacts/native_consumer.py': '3dc681d3e736e83f74e0ddea6cd54b30e9f688d23df9ec30447c243cc0e51200',
}
NATIVE_RECIPE_NEW = {
    'Tools/bazel/artifacts/native_layers.py': 'e18b15255c4032a1d2b8592394ad2b6bf556100d3cf31f19f77d6709f961015c',
    'Tools/bazel/artifacts/native_consumer.py': '84f0358f54801b7448f4fe81435cbf0b8ed0efe18aac6954a121e32ac2381ebe',
}


def _native_require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError('Released Q native chain ' + message)


def _native_fields(value: dict, keys: set[str], label: str) -> None:
    _native_require(isinstance(value, dict) and set(value) == keys, label + ' fields differ')


def _native_relative(value: str) -> bool:
    return (isinstance(value, str) and value and not value.startswith('/')
            and not any(char in value for char in ('\\', ':', '\0'))
            and all(part not in ('', '.', '..') for part in value.split('/')))


def _native_hashes(value: dict, label: str, *, paths: bool = False) -> None:
    _native_require(isinstance(value, dict) and bool(value)
                    and all(isinstance(key, str) and isinstance(sha, str) and SHA.fullmatch(sha)
                            and (not paths or _native_relative(key)) for key, sha in value.items()),
                    label + ' hashes or paths differ')


def _native_identity(row: dict) -> dict:
    assets = row['assets']
    return {'archiveSHA256': assets['archive']['sha256'], 'evidenceSHA256': assets['evidence']['sha256'],
            'proofSHA256': assets['proof']['sha256'], 'releaseId': row['releaseId'],
            'assetId': assets['archive']['assetId'], 'evidenceAssetId': assets['evidence']['assetId'],
            'proofAssetId': assets['proof']['assetId'],
            'lockSHA256': {kind: value['lockSHA256'] for kind, value in assets.items()},
            'producerCommit': row['producerCommit'], 'sourcePins': row['sourcePins']}


def _native_recipe_compatibility(rows: dict, recipe: dict, mode: str) -> None:
    _native_fields(rows, set(NATIVE_GROUPS), mode + ' recipe compatibility inventory')
    _native_require(set(NATIVE_RECIPE_OLD) <= set(recipe), mode + ' recipe omits importer or consumer')
    # This is the producer policy's compact map digest, not the outer sidecar's
    # indented, newline-terminated chain digest.
    def recipe_digest(value: dict) -> str:
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                         allow_nan=False).encode()).hexdigest()

    current_digest = recipe_digest(recipe)
    for group, row in rows.items():
        label = mode + '/' + group + ' recipe compatibility'
        _native_fields(row, {'schema', 'mode', 'producerRecipeSHA256', 'currentRecipeSHA256',
                             'policySHA256', 'changedFiles'}, label)
        _native_require(type(row['schema']) is int and row['schema'] == 1
                        and row['policySHA256'] == NATIVE_RECIPE_POLICY
                        and row['currentRecipeSHA256'] == current_digest, label + ' authority differs')
        if row['mode'] == 'exact':
            _native_require(row['changedFiles'] == [] and row['producerRecipeSHA256'] == current_digest,
                            label + ' exact identity differs')
        else:
            _native_require(row['mode'] == 'known-consumer-verifier-update'
                            and row['changedFiles'] == sorted(NATIVE_RECIPE_OLD)
                            and all(recipe[key] == value for key, value in NATIVE_RECIPE_NEW.items()),
                            label + ' is not the reviewed transition')
            producer = dict(recipe, **NATIVE_RECIPE_OLD)
            _native_require(row['producerRecipeSHA256'] == recipe_digest(producer),
                            label + ' producer identity differs')


def _native_layers(rows: dict) -> set[str]:
    _native_fields(rows, set(NATIVE_GROUPS), 'layer inventory')
    pins = {}
    for group in NATIVE_GROUPS:
        row = rows[group]
        _native_fields(row, {'repository', 'tag', 'targetCommit', 'releaseId', 'assets',
                             'producerCommit', 'sourcePins', 'lower'}, group)
        _native_require(row['repository'] == 'stephenlclarke/' + NATIVE_OWNERS[group]
                        and COMMIT.fullmatch(row['producerCommit']) and COMMIT.fullmatch(row['targetCommit'])
                        and type(row['releaseId']) is int and row['releaseId'] > 0, group + ' release owner differs')
        _native_fields(row['assets'], {'archive', 'evidence', 'proof'}, group + ' asset inventory')
        for kind, suffix in (('archive', '-native-darwin-arm64-opt.tar.gz'),
                             ('evidence', '-native-evidence.json'), ('proof', '-native-proof.tar.gz')):
            asset = row['assets'][kind]
            _native_fields(asset, {'name', 'assetId', 'sha256', 'lockSHA256'}, group + '/' + kind)
            _native_require(asset['name'] == group + suffix and type(asset['assetId']) is int
                            and asset['assetId'] > 0 and SHA.fullmatch(asset['sha256'])
                            and SHA.fullmatch(asset['lockSHA256']), group + ' asset identity differs')
        _native_require(len({asset['assetId'] for asset in row['assets'].values()}) == 3
                        and row['tag'] == 'layer-' + group + '-native-' + row['producerCommit'][:12]
                            + '-' + row['assets']['archive']['sha256'][:20], group + ' release triple differs')
        selected = row['sourcePins']
        _native_require(isinstance(selected, dict) and bool(selected), group + ' source pins are empty')
        for name, pin in selected.items():
            _native_fields(pin, {'identity', 'kind', 'location', 'state'}, group + ' pin')
            _native_require(isinstance(pin['state'], dict) and set(pin['state']) in ({'revision'}, {'revision', 'version'})
                            and ('version' not in pin['state'] or isinstance(pin['state']['version'], str)),
                            group + ' pin state differs')
            _native_require(name not in pins and re.fullmatch(r'[a-z0-9.-]+', name)
                            and pin['identity'] == name and pin['kind'] == 'remoteSourceControl'
                            and re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', pin['location'])
                            and COMMIT.fullmatch(pin['state']['revision']), group + ' source pin differs')
            pins[name] = pin
        pin_name = {'argument-parser': 'swift-argument-parser', 'containerization': 'containerization',
                    'engine-api': 'container-engine-api'}.get(group)
        if pin_name:
            _native_require(set(selected) == {pin_name} and selected[pin_name]['state']['revision'] == NATIVE_PINS[pin_name],
                            group + ' selected pin differs')
            if group == 'argument-parser':
                _native_require(selected[pin_name]['location'] == 'https://github.com/apple/swift-argument-parser.git',
                                'ArgumentParser source owner differs')
            if group != 'argument-parser':
                _native_require(row['targetCommit'] == NATIVE_PINS[pin_name]
                                and selected[pin_name]['location'] == 'https://github.com/' + row['repository'] + '.git',
                                group + ' target differs from its fork pin')
        else:
            _native_require(not set(selected) & {'container', *NATIVE_PINS, 'swift-docc-plugin', 'swift-docc-symbolkit'},
                            'foundation includes an upper or unqualified package')
        if group in ('argument-parser', 'foundation'):
            _native_require(row['targetCommit'] == row['producerCommit'], group + ' producer target differs')
        _native_require(row['lower'] == {name: _native_identity(rows[name]) for name in NATIVE_LOWER[group]},
                        group + ' lower graph differs')
    _native_require(len({row['releaseId'] for row in rows.values()}) == 4
                    and len({asset['assetId'] for row in rows.values() for asset in row['assets'].values()}) == 12,
                    'published layer identities are not distinct')
    _native_require(GUEST == NATIVE_PINS['containerization'], 'guest is not the native Containerization source')
    return {'+dependencies+swiftpkg_' + name.replace('-', '_').replace('.', '_') for name in pins}


def _native_configuration(row: dict, mode: str, repositories: set[str], payload: dict) -> None:
    _native_fields(row, {'configuration', 'source', 'compiledConsumerSHA256', 'buildEventsSHA256',
                        'actionGraphSHA256', 'build', 'loadedBUILD', 'importedArchiveInputs', 'importedActions',
                        'links', 'actions', 'recipeSHA256', 'recipeCompatibility', 'toolchain', 'products',
                        'semanticHelperSHA256'}, mode)
    _native_require(row['source'] == Q and row['configuration'] == mode
                    and all(SHA.fullmatch(row[key]) for key in ('compiledConsumerSHA256', 'buildEventsSHA256', 'actionGraphSHA256')),
                    mode + ' source or raw hashes differ')
    build = row['build']
    _native_fields(build, {'invocation', 'targets', 'configuration', 'optionsSHA256', 'files'}, mode + ' build')
    _native_require(isinstance(build['invocation'], str) and bool(build['invocation'])
                    and build['targets'] == ['//:container'] and build['configuration'] == 'opt'
                    and SHA.fullmatch(build['optionsSHA256']) and isinstance(build['files'], dict)
                    and bool(build['files']), mode + ' build contract differs')
    unsigned = {}
    for path, file in build['files'].items():
        _native_fields(file, {'sha256', 'size'}, mode + ' configured file')
        _native_require(_native_relative(path) and path.startswith('bazel-out/') and SHA.fullmatch(file['sha256'])
                        and type(file['size']) is int and file['size'] >= 0, mode + ' configured output differs')
        if (path.endswith('.rspm.__impl') and '/Contents/Resources/DWARF/' not in path
                and '/external/+dependencies+swiftpkg_container/' in '/' + path):
            name = path.rsplit('/', 1)[-1].removesuffix('.rspm.__impl')
            _native_require(name not in unsigned, mode + ' has duplicate unsigned output')
            unsigned[name] = file['sha256']
    _native_fields(row['products'], set(NATIVE_PRODUCTS), mode + ' product inventory')
    _native_require(set(unsigned) == set(NATIVE_PRODUCTS), mode + ' unsigned inventory differs')
    for name, product in row['products'].items():
        fields = {'unsignedSHA256', 'measuredPath', 'signedMeasuredSHA256'}
        if mode == 'release': fields.add('signedDistributionSHA256')
        _native_fields(product, fields, mode + ' product')
        path = 'bin/' + name if name in NATIVE_PRODUCTS[:3] else 'libexec/container/plugins/' + name + '/bin/' + name
        _native_require(product['measuredPath'] == path and product['unsignedSHA256'] == unsigned[name]
                        and SHA.fullmatch(product['signedMeasuredSHA256'])
                        and (mode != 'release' or product['signedDistributionSHA256'] == payload.get(path)),
                        mode + ' product fingerprint differs')
    _native_fields(row['semanticHelperSHA256'], NATIVE_HELPERS, mode + ' semantic helper')
    _native_hashes(row['semanticHelperSHA256'], mode + ' semantic helper', paths=True)
    _native_hashes(row['loadedBUILD'], mode + ' imported BUILD')
    loaded = set(row['loadedBUILD'])
    required = {'+dependencies+swiftpkg_' + name for name in ('swift_argument_parser', 'containerization', 'container_engine_api')}
    _native_require(required <= loaded <= repositories and all(NATIVE_REPOSITORY.fullmatch(name) for name in loaded),
                    mode + ' imported repositories differ')
    _native_hashes(row['importedArchiveInputs'], mode + ' archive', paths=True)
    archive_repos = set()
    for path in row['importedArchiveInputs']:
        parts = path.split('/')
        names = [part for part in parts if part.startswith('+dependencies+swiftpkg_')]
        _native_require(len(names) == 1 and names[0] in loaded and '/binary/' in path and path.endswith('.a'),
                        mode + ' archive owner differs')
        archive_repos.add(names[0])
    actions = row['importedActions']
    # The qualified producer verifies BaselineCoverage's one-output, no-input
    # metadata shape in raw aquery. Only its count is in this public projection.
    allowed_actions = NATIVE_ACTIONS | ({'BaselineCoverage'} if mode == 'runtime-coverage' else set())
    _native_require(isinstance(actions, dict) and set(actions) <= allowed_actions
                    and all(type(count) is int and count > 0 for count in actions.values())
                    and type(row['actions']) is int and row['actions'] >= 8 + sum(actions.values()),
                    mode + ' includes imported compilation or invalid action counts')
    links = row['links']
    _native_fields(links, {'@@+dependencies+swiftpkg_container//:' + name + '.rspm.__impl' for name in NATIVE_PRODUCTS},
                   mode + ' links')
    reached = set()
    for link in links.values():
        _native_fields(link, {'importedArchives', 'repositories'}, mode + ' link')
        names = link['repositories']
        _native_require(isinstance(names, list) and names == sorted(set(names)) and bool(names)
                        and set(names) <= archive_repos and type(link['importedArchives']) is int
                        and len(names) <= link['importedArchives'] <= len(row['importedArchiveInputs']),
                        mode + ' link archives differ')
        reached.update(names)
    _native_require(required <= reached, mode + ' links omit a selected native layer')
    _native_hashes(row['recipeSHA256'], mode + ' recipe', paths=True)
    _native_recipe_compatibility(row['recipeCompatibility'], row['recipeSHA256'], mode)
    toolchain = row['toolchain']
    _native_fields(toolchain, {'swiftcSHA256', 'swiftVersion', 'sdkSettingsSHA256', 'sdkVersion',
                              'xcodeVersion', 'bazelVersion', 'hostMachine', 'platform'}, mode + ' toolchain')
    _native_require(toolchain['bazelVersion'] == '8.8.0' and toolchain['hostMachine'] == 'arm64'
                    and toolchain['platform'] == 'Darwin' and SHA.fullmatch(toolchain['swiftcSHA256'])
                    and SHA.fullmatch(toolchain['sdkSettingsSHA256'])
                    and all(isinstance(toolchain[key], str) and toolchain[key]
                            for key in ('swiftVersion', 'sdkVersion', 'xcodeVersion')), mode + ' toolchain differs')


def validate_native_chain(bundle: dict) -> None:
    """Validate authenticated public projections, without fetching private BEP or rebuilding."""
    if Q == LEGACY_Q:
        _native_require('native_compiled_chain' not in bundle and 'native_compiled_chain_sha256' not in bundle,
                        'is unexpected on the legacy source')
        return
    _native_require(COMMIT.fullmatch(Q), 'selected source is malformed')
    try:
        chain = bundle['native_compiled_chain']
        encoded = (json.dumps(chain, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
        _native_require(bundle['native_compiled_chain_sha256'] == hashlib.sha256(encoded).hexdigest(), 'digest differs')
        _native_fields(chain, {'schema', 'source', 'layers', 'release', 'coverage', 'sourceReceiptSHA256',
                              'measuredAssets', 'signedArchiveSHA256', 'interpretation'}, 'projection')
        _native_require(type(chain['schema']) is int and chain['schema'] == 1 and chain['source'] == Q
                        and isinstance(chain['interpretation'], str) and bool(chain['interpretation']),
                        'projection source differs')
        # Reject private path/env additions without rewriting authenticated data.
        _native_require(not re.search(r'file://|/(?:Users|Volumes|private|tmp|home|var)/|github_pat_|ghp_|Bearer ', encoded.decode()),
                        'contains private data')
        repositories = _native_layers(chain['layers'])
        runtime = bundle['runtime']
        _native_configuration(chain['release'], 'release', repositories, runtime['payload'])
        _native_configuration(chain['coverage'], 'runtime-coverage', repositories, runtime['payload'])
        for key in ('recipeSHA256', 'recipeCompatibility', 'toolchain', 'loadedBUILD', 'importedArchiveInputs'):
            _native_require(chain['release'][key] == chain['coverage'][key], 'release and coverage lower ' + key + ' differ')
        receipts = chain['sourceReceiptSHA256']
        phases = ('runtime-smoke', 'runtime-benchmark', 'release')
        names = ('compiled-consumer.json', 'fork-release.events.json', 'fork-release-native-aquery.json',
                 'fork-fingerprint.json', 'source-inputs.json')
        expected = {phase + '/' + name for phase in phases for name in names} | {
            'integration/coverage/' + name for name in ('coverage-compiled-consumer.json',
                'fork-runtime-coverage.events.json', 'fork-runtime-coverage-native-aquery.json', 'fork-fingerprint.json')}
        _native_fields(receipts, expected, 'raw receipt inventory')
        _native_hashes(receipts, 'raw receipt', paths=True)
        for name in names:
            _native_require(len({receipts[phase + '/' + name] for phase in phases}) == 1, 'copied ' + name + ' differs')
        for key, name in (('compiledConsumerSHA256', 'compiled-consumer.json'),
                          ('buildEventsSHA256', 'fork-release.events.json'),
                          ('actionGraphSHA256', 'fork-release-native-aquery.json')):
            _native_require(chain['release'][key] == receipts['runtime-smoke/' + name], 'release raw link differs')
        for key, name in (('compiledConsumerSHA256', 'coverage-compiled-consumer.json'),
                          ('buildEventsSHA256', 'fork-runtime-coverage.events.json'),
                          ('actionGraphSHA256', 'fork-runtime-coverage-native-aquery.json')):
            _native_require(chain['coverage'][key] == receipts['integration/coverage/' + name], 'coverage raw link differs')
        _native_require(receipts['runtime-smoke/fork-fingerprint.json'] == bundle['source_receipt_sha256']['runtime-smoke/fork-fingerprint.json']
                        and runtime['compiled_consumer_sha256'] == chain['release']['compiledConsumerSHA256']
                        and runtime['unsigned_native_inputs'] == {name: row['unsignedSHA256'] for name, row in chain['release']['products'].items()},
                        'runtime fingerprint links differ')
        _native_fields(chain['measuredAssets'], NATIVE_MEASURED, 'measured assets')
        _native_hashes(chain['measuredAssets'], 'measured asset', paths=True)
        _native_require(chain['measuredAssets'] == bundle['measured_assets']
                        and chain['signedArchiveSHA256'] == bundle['assets']['runtime']['sha256'], 'released asset links differ')
        parity = bundle['performance_parity_asset']
        _native_fields(parity, {'name', 'sha256'}, 'performance asset')
        _native_require(parity['name'] == 'container-performance-parity-' + Q[:8] + '.zip'
                        and SHA.fullmatch(parity['sha256']), 'performance asset identity differs')
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise RuntimeError('Released Q native chain is malformed') from error


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for piece in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(piece)
    return value.hexdigest()


def fetch_command(lock: Path, destination: Path) -> None:
    subprocess.run([sys.executable, str(FETCH), 'fetch', '--lock', str(lock),
                    '--destination', str(destination)], check=True, timeout=420)


def validate(bundle: dict, locks: dict, helpers: dict[str, str]) -> None:
    if (bundle.get('schema') != 1 or bundle.get('kind') != 'container-qualified-runtime-assets'
            or bundle.get('qualified_container_source') != Q
            or bundle.get('qualification') != {'target': 'bazel-qualify', 'passed': True}
            or bundle.get('qualified_helpers_sha256') != helpers):
        raise RuntimeError('Released Q provenance has wrong qualification or helper identity')
    assets = bundle.get('assets')
    if not isinstance(assets, dict) or set(assets) != set(NAMES) - {'provenance'}:
        raise RuntimeError('Released Q provenance omits a required product')
    for name in ('runtime', 'guest', 'builder'):
        product = assets[name]
        if (product.get('name') != NAMES[name]
                or product.get('sha256') != locks[name]['sha256']):
            raise RuntimeError('Released Q asset differs from the provenance sidecar: ' + name)
    if (assets['runtime'].get('source') != Q
            or assets['guest'].get('source') != GUEST
            or assets['builder'].get('source') != BUILDER):
        raise RuntimeError('Released Q asset source graph changed')
    guest, builder, runtime = bundle.get('guest', {}), bundle.get('builder', {}), bundle.get('runtime', {})
    if (guest.get('source') != GUEST or guest.get('reference') != assets['guest'].get('reference')
            or builder.get('source') != BUILDER or builder.get('reference') != assets['builder'].get('reference')
            or runtime.get('init_archive_sha256') != assets['guest']['sha256']
            or runtime.get('builder_archive_sha256') != assets['builder']['sha256']
            or runtime.get('notary', {}).get('status') != 'Accepted'
            or not runtime.get('notary', {}).get('id')
            or runtime.get('init_image') != assets['guest']['reference']
            or runtime.get('builder_image') != assets['builder']['reference']
            or not runtime.get('workload_image', '').startswith('docker.io/library/alpine@sha256:')):
        raise RuntimeError('Released Q runtime/OCI/notarization provenance changed')
    payload = runtime.get('payload')
    receipts = bundle.get('source_receipt_sha256')
    if (not isinstance(payload, dict) or len(payload) != 25
            or any(not SHA.fullmatch(value) or path.startswith('/') or '..' in Path(path).parts
                   for path, value in payload.items())
            or not isinstance(receipts, dict) or set(receipts) != RECEIPTS
            or any(not SHA.fullmatch(value) for value in receipts.values())
            or not SHA.fullmatch(runtime.get('kernel_sha256', ''))
            or not SHA.fullmatch(runtime.get('package_lock_sha256', ''))):
        raise RuntimeError('Released Q payload or source receipts are malformed')
    validate_native_chain(bundle)


def fetch_assets(evidence: Path, helpers: dict[str, str],
                 *, locks_dir: Path = LOCKS,
                 invoke: Callable[[Path, Path], None] = fetch_command) -> dict:
    """Use only the common published-release transport; never fall back locally."""
    if evidence.exists() or not evidence.is_absolute():
        raise RuntimeError('Q asset evidence must be a fresh absolute directory')
    locks = {name: read_lock(locks_dir / (name + '.lock.json')) for name in NAMES}
    if (any((row['repository'], row['targetCommit']) != SOURCES[name]
            or row['asset'] != NAMES[name] for name, row in locks.items())
            or locks['runtime']['tag'] != locks['provenance']['tag']):
        raise RuntimeError('Released Q asset locks do not bind their exact source releases')
    evidence.mkdir(parents=True, mode=0o700)
    files = {}
    receipts = {}
    for name in NAMES:
        directory = evidence / name
        invoke(locks_dir / (name + '.lock.json'), directory)
        receipt = json.loads((directory / 'fetch-receipt.json').read_text())
        asset = directory / NAMES[name]
        if (receipt.get('targetCommit') != locks[name]['targetCommit']
                or receipt.get('repository') != locks[name]['repository']
                or receipt.get('tag') != locks[name]['tag']
                or receipt.get('asset') != str(asset) or receipt.get('sha256') != locks[name]['sha256']
                or receipt.get('lockSHA256') != digest(locks_dir / (name + '.lock.json'))
                or not asset.is_file() or asset.is_symlink()
                or digest(asset) != locks[name]['sha256']):
            raise RuntimeError('Released Q fetch receipt or asset changed: ' + name)
        files[name] = asset
        receipts[name] = receipt
    bundle = json.loads(files['provenance'].read_text())
    validate(bundle, locks, helpers)
    result = {'schema': 1, 'qualified_container_source': Q,
              'releases': {name: {'repository': locks[name]['repository'],
                                  'tag': locks[name]['tag'],
                                  'target_commit': locks[name]['targetCommit']}
                           for name in NAMES},
              'assets': {name: {'path': str(files[name]), 'sha256': locks[name]['sha256'],
                                'fetch_receipt_sha256': digest(evidence / name / 'fetch-receipt.json')}
                         for name in NAMES},
              'provenance': bundle}
    (evidence / 'q-assets.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def revalidate(evidence: Path, helpers: dict[str, str]) -> dict:
    """Recover using exactly the already downloaded bytes, without network access."""
    result = json.loads((evidence / 'q-assets.json').read_text())
    if result.get('schema') != 1 or result.get('qualified_container_source') != Q:
        raise RuntimeError('Q asset recovery receipt has a different source')
    assets = result.get('assets', {})
    releases = result.get('releases', {})
    if set(assets) != set(NAMES) or set(releases) != set(NAMES):
        raise RuntimeError('Q asset recovery receipt omitted a product')
    locks = {name: read_lock(LOCKS / (name + '.lock.json')) for name in NAMES}
    for name in NAMES:
        path = evidence / name / NAMES[name]
        row = assets[name]
        lock = locks[name]
        receipt_path = evidence / name / 'fetch-receipt.json'
        receipt = json.loads(receipt_path.read_text())
        if (row.get('path') != str(path) or path.is_symlink() or not path.is_file()
                or row.get('sha256') != lock['sha256'] or row['sha256'] != digest(path)
                or row.get('fetch_receipt_sha256') != digest(receipt_path)
                or (releases[name]['repository'], releases[name]['target_commit'], releases[name]['tag'])
                   != (lock['repository'], lock['targetCommit'], lock['tag'])
                or (receipt.get('repository'), receipt.get('targetCommit'), receipt.get('tag'),
                    receipt.get('sha256'), receipt.get('asset'), receipt.get('lockSHA256'))
                   != (lock['repository'], lock['targetCommit'], lock['tag'], lock['sha256'],
                       str(path), digest(LOCKS / (name + '.lock.json')))):
            raise RuntimeError('Downloaded Q asset changed during recovery: ' + name)
    if releases['runtime']['tag'] != releases['provenance']['tag']:
        raise RuntimeError('Released Q sidecar belongs to a different runtime release')
    bundle = json.loads((evidence / 'provenance' / NAMES['provenance']).read_text())
    if result.get('provenance') != bundle:
        raise RuntimeError('Released Q provenance changed during recovery')
    validate(bundle, locks, helpers)
    return result
