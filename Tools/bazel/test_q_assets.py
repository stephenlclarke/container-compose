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

"""No-network checks for released qualified Container asset admission."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import q_assets


class QAssetTests(unittest.TestCase):
    def test_selected_graph_and_published_locks_agree(self) -> None:
        root = Path(__file__).resolve().parents[2]
        pins = {row['identity']: row['state']['revision']
                for row in json.loads((root / 'Package.resolved').read_text())['pins']}
        self.assertEqual(pins['container'], q_assets.Q)
        self.assertEqual(pins['containerization'], q_assets.GUEST)
        locks = {name: q_assets.read_lock(q_assets.LOCKS / (name + '.lock.json'))
                 for name in q_assets.NAMES}
        for name, lock in locks.items():
            self.assertEqual((lock['repository'], lock['targetCommit']), q_assets.SOURCES[name])
            self.assertEqual(lock['asset'], q_assets.NAMES[name])
        self.assertEqual(locks['runtime']['tag'], locks['provenance']['tag'])

    def fixture(self):
        # Keep the production schema test self-contained; no local Q checkout
        # or unpublished draft is an admission input.
        h = 'a' * 64
        locks = {name: {'sha256': h} for name in q_assets.NAMES}
        bundle = {'schema': 1, 'kind': 'container-qualified-runtime-assets',
                  'qualified_container_source': q_assets.Q,
                  'qualification': {'target': 'bazel-qualify', 'passed': True},
                  'qualified_helpers_sha256': {'helper.py': h},
                  'assets': {
                      name: {'name': q_assets.NAMES[name], 'sha256': h,
                             'source': {'runtime': q_assets.Q, 'guest': q_assets.GUEST,
                                        'builder': q_assets.BUILDER}[name],
                             'reference': name + ':pinned'}
                      for name in ('runtime', 'guest', 'builder')},
                  'guest': {'source': q_assets.GUEST, 'reference': 'guest:pinned'},
                  'builder': {'source': q_assets.BUILDER, 'reference': 'builder:pinned'},
                  'runtime': {'init_archive_sha256': h, 'builder_archive_sha256': h,
                              'kernel_sha256': h, 'package_lock_sha256': h,
                              'init_image': 'guest:pinned', 'builder_image': 'builder:pinned',
                              'workload_image': 'docker.io/library/alpine@sha256:' + h,
                              'payload': {f'bin/file{index}': h for index in range(25)},
                              'notary': {'status': 'Accepted', 'id': 'receipt-id'}},
                  'source_receipt_sha256': {name: h for name in q_assets.RECEIPTS}}
        return bundle, locks

    def test_complete_same_release_provenance(self) -> None:
        bundle, locks = self.fixture()
        self.legacy(bundle)
        with patch.object(q_assets, 'Q', q_assets.LEGACY_Q), \
             patch.object(q_assets, 'GUEST', bundle['guest']['source']):
            q_assets.validate(bundle, locks, bundle['qualified_helpers_sha256'])

    def test_selected_source_requires_native_chain(self) -> None:
        bundle, locks = self.fixture()
        with self.assertRaisesRegex(RuntimeError, 'native chain is malformed'):
            q_assets.validate(bundle, locks, bundle['qualified_helpers_sha256'])

    def test_tamper_and_missing_product_fail(self) -> None:
        bundle, locks = self.fixture()
        self.legacy(bundle)
        for mutation in ('archive', 'payload', 'notary', 'guest', 'helper', 'missing'):
            changed = copy.deepcopy(bundle)
            if mutation == 'archive':
                changed['assets']['runtime']['sha256'] = 'b' * 64
            elif mutation == 'payload':
                changed['runtime']['payload']['bin/file0'] = 'invalid'
            elif mutation == 'notary':
                changed['runtime']['notary']['status'] = 'Rejected'
            elif mutation == 'guest':
                changed['guest']['source'] = 'b' * 40
            elif mutation == 'helper':
                changed['qualified_helpers_sha256']['helper.py'] = 'b' * 64
            else:
                del changed['assets']['builder']
            with self.subTest(mutation=mutation), patch.object(q_assets, 'Q', q_assets.LEGACY_Q), \
                 patch.object(q_assets, 'GUEST', bundle['guest']['source']), self.assertRaises(RuntimeError):
                q_assets.validate(changed, locks, bundle['qualified_helpers_sha256'])

    @staticmethod
    def legacy(bundle: dict) -> None:
        bundle['qualified_container_source'] = q_assets.LEGACY_Q
        bundle['assets']['runtime']['source'] = q_assets.LEGACY_Q
        guest = '5ed9bc7490aa30c76337bd5b3d8ff251b63c678f'
        bundle['assets']['guest']['source'] = guest
        bundle['guest']['source'] = guest

    def test_missing_or_mixed_release_locks_fail_before_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            locks_dir = root / 'locks'
            locks_dir.mkdir()
            with self.assertRaises(FileNotFoundError):
                q_assets.fetch_assets(root / 'evidence', {}, locks_dir=locks_dir,
                                      invoke=lambda *_: self.fail('must not fetch'))
            for name in q_assets.NAMES:
                (locks_dir / (name + '.lock.json')).write_text(json.dumps({
                    'schema': 1, 'repository': q_assets.SOURCES[name][0],
                    'tag': 'q153', 'targetCommit': q_assets.SOURCES[name][1],
                    'asset': q_assets.NAMES[name], 'sha256': 'a' * 64}))
            provenance = locks_dir / 'provenance.lock.json'
            record = json.loads(provenance.read_text())
            record['tag'] = 'different'
            provenance.write_text(json.dumps(record))
            with self.assertRaisesRegex(RuntimeError, 'source releases'):
                q_assets.fetch_assets(root / 'evidence', {}, locks_dir=locks_dir,
                                      invoke=lambda *_: self.fail('must not fetch'))


class NativeQAssetTests(unittest.TestCase):
    """Synthetic authenticated-sidecar shapes; no claim of real qualification."""

    def setUp(self):
        self.source = 'b' * 40
        for name, value in (('Q', self.source), ('GUEST', q_assets.NATIVE_PINS['containerization'])):
            guard = patch.object(q_assets, name, value)
            guard.start()
            self.addCleanup(guard.stop)
        self.bundle, self.locks = QAssetTests().fixture()
        self.bundle['runtime']['payload'] = {f'bin/additional-{index}': 'd' * 64 for index in range(17)}
        layers = {}
        for index, group in enumerate(q_assets.NATIVE_GROUPS):
            pin_name = {'argument-parser': 'swift-argument-parser', 'foundation': 'swift-log',
                        'containerization': 'containerization', 'engine-api': 'container-engine-api'}[group]
            revision = q_assets.NATIVE_PINS.get(pin_name, 'c' * 40)
            repository = 'stephenlclarke/' + q_assets.NATIVE_OWNERS[group]
            location = ('https://github.com/apple/' + pin_name + '.git' if group in ('argument-parser', 'foundation')
                        else 'https://github.com/' + repository + '.git')
            producer = str(index + 1) * 40
            assets = {kind: {'name': group + suffix, 'assetId': index * 3 + offset,
                             'sha256': 'a' * 64, 'lockSHA256': 'b' * 64}
                      for kind, suffix, offset in (('archive', '-native-darwin-arm64-opt.tar.gz', 1),
                          ('evidence', '-native-evidence.json', 2), ('proof', '-native-proof.tar.gz', 3))}
            row = {'repository': repository, 'tag': 'layer-' + group + '-native-' + producer[:12] + '-' + 'a' * 20,
                   'targetCommit': producer if group in ('argument-parser', 'foundation') else revision,
                   'releaseId': 100 + index, 'assets': assets, 'producerCommit': producer,
                   'sourcePins': {pin_name: {'identity': pin_name, 'kind': 'remoteSourceControl',
                       'location': location, 'state': {'revision': revision}}},
                   'lower': {}}
            # Independent reproduction of the published compact lower identity.
            for lower in q_assets.NATIVE_LOWER[group]:
                value = layers[lower]
                row['lower'][lower] = {'archiveSHA256': value['assets']['archive']['sha256'],
                    'evidenceSHA256': value['assets']['evidence']['sha256'],
                    'proofSHA256': value['assets']['proof']['sha256'], 'releaseId': value['releaseId'],
                    'assetId': value['assets']['archive']['assetId'], 'evidenceAssetId': value['assets']['evidence']['assetId'],
                    'proofAssetId': value['assets']['proof']['assetId'],
                    'lockSHA256': {kind: asset['lockSHA256'] for kind, asset in value['assets'].items()},
                    'producerCommit': value['producerCommit'], 'sourcePins': copy.deepcopy(value['sourcePins'])}
            layers[group] = row
        repositories = sorted('+dependencies+swiftpkg_' + name.replace('-', '_')
                              for row in layers.values() for name in row['sourcePins'])
        loaded = {name: 'a' * 64 for name in repositories}
        archive_inputs = {'external/' + name + '/binary/libLower.a': 'a' * 64 for name in repositories}
        products, files, links = {}, {}, {}
        for name in q_assets.NATIVE_PRODUCTS:
            path = 'bin/' + name if name in q_assets.NATIVE_PRODUCTS[:3] else 'libexec/container/plugins/' + name + '/bin/' + name
            products[name] = {'unsignedSHA256': 'b' * 64, 'measuredPath': path,
                              'signedMeasuredSHA256': 'c' * 64, 'signedDistributionSHA256': 'd' * 64}
            self.bundle['runtime']['payload'][path] = 'd' * 64
            files['bazel-out/opt/bin/external/+dependencies+swiftpkg_container/' + name + '.rspm.__impl'] = {
                'sha256': 'b' * 64, 'size': 100}
            links['@@+dependencies+swiftpkg_container//:' + name + '.rspm.__impl'] = {
                'importedArchives': 4, 'repositories': repositories}
        release = {'configuration': 'release', 'source': self.source, 'compiledConsumerSHA256': '1' * 64,
                   'buildEventsSHA256': '2' * 64, 'actionGraphSHA256': '3' * 64,
                   'build': {'invocation': 'fixture-invocation', 'targets': ['//:container'], 'configuration': 'opt',
                             'optionsSHA256': '4' * 64, 'files': files}, 'loadedBUILD': loaded,
                   'importedArchiveInputs': archive_inputs, 'importedActions': {'FileWrite': 4}, 'actions': 12,
                   'links': links, 'recipeSHA256': dict(q_assets.NATIVE_RECIPE_NEW, **{'BUILD.bazel': 'a' * 64}),
                   'toolchain': {'swiftcSHA256': 'a' * 64, 'sdkSettingsSHA256': 'b' * 64,
                                 'swiftVersion': 'fixture Swift', 'sdkVersion': '27.0', 'xcodeVersion': 'fixture Xcode',
                                 'bazelVersion': '8.8.0', 'hostMachine': 'arm64', 'platform': 'Darwin'},
                   'products': products, 'semanticHelperSHA256': {name: 'c' * 64 for name in q_assets.NATIVE_HELPERS}}
        self.bind_recipe(release)
        coverage = copy.deepcopy(release)
        coverage.update(configuration='runtime-coverage', compiledConsumerSHA256='5' * 64,
                        buildEventsSHA256='6' * 64, actionGraphSHA256='7' * 64)
        for product in coverage['products'].values(): product.pop('signedDistributionSHA256')
        receipts = {phase + '/' + name: value * 64 for phase in ('runtime-smoke', 'runtime-benchmark', 'release')
                    for name, value in (('compiled-consumer.json', '1'), ('fork-release.events.json', '2'),
                        ('fork-release-native-aquery.json', '3'), ('fork-fingerprint.json', 'a'), ('source-inputs.json', '8'))}
        receipts.update({'integration/coverage/' + name: value * 64 for name, value in (
            ('coverage-compiled-consumer.json', '5'), ('fork-runtime-coverage.events.json', '6'),
            ('fork-runtime-coverage-native-aquery.json', '7'), ('fork-fingerprint.json', '9'))})
        measured = {name: 'a' * 64 for name in q_assets.NATIVE_MEASURED}
        self.chain = {'schema': 1, 'source': self.source, 'layers': layers, 'release': release, 'coverage': coverage,
                      'sourceReceiptSHA256': receipts, 'measuredAssets': measured,
                      'signedArchiveSHA256': 'a' * 64, 'interpretation': 'Synthetic unit fixture only.'}
        self.bundle.update(native_compiled_chain=self.chain, measured_assets=copy.deepcopy(measured),
                           performance_parity_asset={'name': 'container-performance-parity-' + self.source[:8] + '.zip',
                                                     'sha256': 'a' * 64})
        self.bundle['runtime'].update(compiled_consumer_sha256='1' * 64,
                                     unsigned_native_inputs={name: 'b' * 64 for name in q_assets.NATIVE_PRODUCTS})
        self.seal(self.bundle)

    @staticmethod
    def seal(bundle):
        encoded = (json.dumps(bundle['native_compiled_chain'], sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
        bundle['native_compiled_chain_sha256'] = hashlib.sha256(encoded).hexdigest()

    @staticmethod
    def bind_recipe(row, mode='known-consumer-verifier-update'):
        recipe = row['recipeSHA256']
        producer = recipe if mode == 'exact' else dict(recipe, **q_assets.NATIVE_RECIPE_OLD)
        def digest(value):
            return hashlib.sha256(json.dumps(value, separators=(',', ':'), sort_keys=True).encode()).hexdigest()
        row['recipeCompatibility'] = {group: {
            'schema': 1, 'mode': mode, 'producerRecipeSHA256': digest(producer),
            'currentRecipeSHA256': digest(recipe), 'policySHA256': q_assets.NATIVE_RECIPE_POLICY,
            'changedFiles': [] if mode == 'exact' else sorted(q_assets.NATIVE_RECIPE_OLD),
        } for group in q_assets.NATIVE_GROUPS}

    def validate(self, bundle=None):
        q_assets.validate(bundle or self.bundle, self.locks, self.bundle['qualified_helpers_sha256'])

    def reject(self, change):
        bundle = copy.deepcopy(self.bundle)
        change(bundle)
        self.seal(bundle)
        with self.assertRaises(RuntimeError): self.validate(bundle)

    def test_complete_chain_uses_separate_unsigned_measured_and_distribution_hashes(self):
        self.validate()
        self.assertNotEqual(self.chain['release']['products']['container']['unsignedSHA256'],
                            self.chain['release']['products']['container']['signedMeasuredSHA256'])
        self.assertNotEqual(self.chain['release']['products']['container']['signedMeasuredSHA256'],
                            self.bundle['runtime']['payload']['bin/container'])

    def test_every_nonlegacy_selected_source_requires_chain(self):
        for source in ('b' * 40, 'f' * 40):
            with patch.object(q_assets, 'Q', source):
                bundle, locks = QAssetTests().fixture()
                with self.assertRaises(RuntimeError):
                    q_assets.validate(bundle, locks, bundle['qualified_helpers_sha256'])

    def test_legacy_source_cannot_claim_an_ignored_native_chain(self):
        with patch.object(q_assets, 'Q', q_assets.LEGACY_Q):
            bundle, locks = QAssetTests().fixture()
            bundle['native_compiled_chain'] = self.chain
            with self.assertRaises(RuntimeError):
                q_assets.validate(bundle, locks, bundle['qualified_helpers_sha256'])

    def test_digest_and_finite_schema_fail_closed(self):
        bundle = copy.deepcopy(self.bundle); bundle['native_compiled_chain_sha256'] = '0' * 64
        with self.assertRaisesRegex(RuntimeError, 'digest'): self.validate(bundle)
        for change in (lambda b: b['native_compiled_chain'].update(extra='ignored'),
                       lambda b: b['native_compiled_chain'].update(schema=True),
                       lambda b: b['native_compiled_chain'].update(source='f' * 40),
                       lambda b: b['native_compiled_chain']['release'].update(overrides={'repo': '/tmp/private'})):
            self.reject(change)
        bundle = copy.deepcopy(self.bundle); bundle['native_compiled_chain']['release']['actions'] = float('nan')
        with self.assertRaises(RuntimeError): self.validate(bundle)

    def test_layer_owner_asset_target_pin_and_nested_identity_tampering(self):
        changes = (
            lambda c: c['layers'].pop('engine-api'),
            lambda c: c['layers']['engine-api'].update(repository='other/repo'),
            lambda c: c['layers']['engine-api'].update(targetCommit='f' * 40),
            lambda c: c['layers']['engine-api']['sourcePins']['container-engine-api']['state'].update(revision='f' * 40),
            lambda c: c['layers']['argument-parser'].update(targetCommit='f' * 40),
            lambda c: c['layers']['foundation']['lower']['argument-parser'].update(proofSHA256='f' * 64),
            lambda c: c['layers']['containerization']['assets']['proof'].update(assetId=True),
            lambda c: c['layers']['engine-api']['assets']['proof'].update(assetId=10),
            lambda c: c['layers']['engine-api']['assets']['proof'].update(name='other-native-proof.tar.gz'),
            lambda c: c['layers']['engine-api']['assets']['proof'].update(lockSHA256='not-a-hash'),
            lambda c: c['layers']['foundation'].update(releaseId=100),
            lambda c: c['layers']['foundation']['sourcePins']['swift-log'].update(identity='other'),
        )
        for index, change in enumerate(changes):
            with self.subTest(index=index): self.reject(lambda b: change(b['native_compiled_chain']))

    def test_release_and_coverage_raw_fingerprint_links(self):
        changes = (
            lambda b: b['native_compiled_chain']['sourceReceiptSHA256'].pop('release/fork-release.events.json'),
            lambda b: b['native_compiled_chain']['sourceReceiptSHA256'].update({'release/fork-release.events.json': 'f' * 64}),
            lambda b: b['native_compiled_chain']['coverage'].update(buildEventsSHA256='f' * 64),
            lambda b: b['native_compiled_chain']['release'].update(compiledConsumerSHA256='f' * 64),
            lambda b: b['source_receipt_sha256'].update({'runtime-smoke/fork-fingerprint.json': 'f' * 64}),
            lambda b: b['runtime'].update(compiled_consumer_sha256='f' * 64),
            lambda b: b['runtime']['unsigned_native_inputs'].pop('container-engine'),
        )
        for index, change in enumerate(changes):
            with self.subTest(index=index): self.reject(change)

    def test_coverage_cannot_change_recipe_toolchain_or_lower_graph(self):
        for field in ('recipeSHA256', 'toolchain', 'loadedBUILD', 'importedArchiveInputs'):
            def change(bundle):
                row = bundle['native_compiled_chain']['coverage'][field]
                row[next(iter(row))] = 'e' * 64
            with self.subTest(field=field): self.reject(change)
        self.reject(lambda b: b['native_compiled_chain']['coverage'].update(configuration='release'))

    def test_exact_and_reviewed_recipe_modes_preserve_producer_identity(self):
        self.validate()
        row = self.chain['release']['recipeCompatibility']['foundation']
        self.assertNotEqual(row['producerRecipeSHA256'], row['currentRecipeSHA256'])
        for mode in ('release', 'coverage'):
            self.bind_recipe(self.chain[mode], 'exact')
        self.seal(self.bundle)
        self.validate()
        row = self.chain['release']['recipeCompatibility']['foundation']
        self.assertEqual(row['producerRecipeSHA256'], row['currentRecipeSHA256'])

    def test_recipe_compatibility_authority_inventory_and_transition_reject_tampering(self):
        changes = (
            lambda row: row.pop('recipeCompatibility'),
            lambda row: row['recipeCompatibility'].pop('engine-api'),
            lambda row: row['recipeCompatibility'].update(extra={}),
            lambda row: row['recipeCompatibility']['foundation'].update(schema=True),
            lambda row: row['recipeCompatibility']['foundation'].update(policySHA256='f' * 64),
            lambda row: row['recipeCompatibility']['foundation'].update(currentRecipeSHA256='f' * 64),
            lambda row: row['recipeCompatibility']['foundation'].update(producerRecipeSHA256='f' * 64),
            lambda row: row['recipeCompatibility']['foundation'].update(mode='unreviewed-update'),
            lambda row: row['recipeCompatibility']['foundation'].update(changedFiles=[]),
            lambda row: row['recipeCompatibility']['foundation'].update(mode='exact'),
            lambda row: row['recipeCompatibility']['foundation'].update(extra='ignored'),
        )
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                self.reject(lambda bundle: change(bundle['native_compiled_chain']['release']))
        for filename in q_assets.NATIVE_RECIPE_NEW:
            for value in (q_assets.NATIVE_RECIPE_OLD[filename], 'f' * 64):
                def change(bundle):
                    for mode in ('release', 'coverage'):
                        row = bundle['native_compiled_chain'][mode]
                        row['recipeSHA256'][filename] = value
                        self.bind_recipe(row)
                with self.subTest(filename=filename, value=value): self.reject(change)

    def test_recipe_digest_binds_unchanged_fields_and_both_configurations(self):
        def change_unrelated(bundle):
            for mode in ('release', 'coverage'):
                row = bundle['native_compiled_chain'][mode]
                row['recipeSHA256']['BUILD.bazel'] = 'f' * 64
                # Only the current digest is changed: the published producer's
                # original digest must still bind every unchanged recipe field.
                updated = hashlib.sha256(json.dumps(row['recipeSHA256'], sort_keys=True,
                    separators=(',', ':')).encode()).hexdigest()
                for marker in row['recipeCompatibility'].values():
                    marker['currentRecipeSHA256'] = updated
        self.reject(change_unrelated)
        def change_mode(bundle):
            self.bind_recipe(bundle['native_compiled_chain']['coverage'], 'exact')
        self.reject(change_mode)
        for mode in ('release', 'coverage'):
            row = self.chain[mode]
            self.bind_recipe(row, 'exact')
            row['recipeCompatibility']['foundation']['producerRecipeSHA256'] = 'f' * 64
        self.seal(self.bundle)
        with self.assertRaises(RuntimeError): self.validate()

    def test_unsigned_inventory_distribution_and_asset_links(self):
        changes = (
            lambda b: b['native_compiled_chain']['release']['products'].pop('k8s'),
            lambda b: b['native_compiled_chain']['release']['build']['files'].pop(next(iter(b['native_compiled_chain']['release']['build']['files']))),
            lambda b: b['native_compiled_chain']['release']['products']['container'].update(unsignedSHA256='e' * 64),
            lambda b: b['native_compiled_chain']['release']['products']['container'].update(signedDistributionSHA256='e' * 64),
            lambda b: b['native_compiled_chain']['release']['products']['container'].update(measuredPath='bin/../container'),
            lambda b: b['native_compiled_chain']['coverage']['products']['container'].update(signedMeasuredSHA256='invalid'),
            lambda b: b['measured_assets'].update({'container-measured-fork-arm64.tar.gz': 'e' * 64}),
            lambda b: b['native_compiled_chain'].update(signedArchiveSHA256='e' * 64),
            lambda b: b['performance_parity_asset'].update(name='other.zip'),
        )
        for index, change in enumerate(changes):
            with self.subTest(index=index): self.reject(change)

    def test_imported_compilation_and_unbound_link_inputs_are_rejected(self):
        for mode in ('release', 'coverage'):
            for action in ('SwiftCompile', 'CppCompile', 'CppArchive', 'CppLink', 'Genrule'):
                with self.subTest(mode=mode, action=action):
                    self.reject(lambda b: b['native_compiled_chain'][mode]['importedActions'].update({action: 1}))
        self.reject(lambda b: b['native_compiled_chain']['release']['links'].pop(next(iter(b['native_compiled_chain']['release']['links']))))
        self.reject(lambda b: b['native_compiled_chain']['release']['links'][next(iter(b['native_compiled_chain']['release']['links']))].update(repositories=['+dependencies+swiftpkg_unowned']))
        self.reject(lambda b: b['native_compiled_chain']['release']['importedArchiveInputs'].update({'external/+dependencies+swiftpkg_unowned/binary/lib.a': 'a' * 64}))

    def test_baseline_coverage_metadata_is_allowed_only_in_coverage_projection(self):
        self.chain['coverage']['importedActions']['BaselineCoverage'] = 526
        self.chain['coverage']['actions'] += 526
        self.seal(self.bundle)
        self.validate()
        self.reject(lambda b: b['native_compiled_chain']['release']['importedActions'].update(BaselineCoverage=1))
        self.reject(lambda b: b['native_compiled_chain']['coverage']['importedActions'].update(BaselineCoverage=True))
        self.reject(lambda b: b['native_compiled_chain']['coverage']['importedActions'].update(BaselineCoverage=-1))

    def test_unsafe_or_private_paths_cannot_hide_behind_recomputed_chain_hash(self):
        for path in ('/tmp/lib.a', 'a/../lib.a', 'a//lib.a', 'a/./lib.a', 'file://private', 'a\\lib.a'):
            with self.subTest(path=path):
                self.reject(lambda b: b['native_compiled_chain']['release']['recipeSHA256'].update({path: 'a' * 64}))
        self.reject(lambda b: b['native_compiled_chain']['release']['toolchain'].update(swiftVersion='/Users/private/swift'))


if __name__ == '__main__':
    unittest.main()
