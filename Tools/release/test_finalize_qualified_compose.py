"""Deterministic release boundaries; no binary, signing or notary execution."""
import copy
import json
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
import zipfile

import finalize_qualified_compose as finalizer

SOURCE = 'a' * 40
TOOL = 'b' * 40


class FinalizerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/Volumes/SSD/q')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir()
        self.output = self.root / 'output'
        self.info = {'version': '0.15.1', 'lane': 'candidate', 'branch': 'detached',
                     'commit': SOURCE, 'buildType': 'release',
                     'containerSource': 'enhanced/container', 'containerRef': 'c' * 40,
                     'containerizationSource': 'enhanced/containerization',
                     'containerizationRef': 'd' * 40, 'runtimeCapabilities': ['original']}
        self.files = {finalizer.BUILD_INFO: finalizer.canonical(self.info),
                      'bin/compose': b'original signed executable',
                      'resources/compose-normalizer': b'original normalizer',
                      'resources/THIRD-PARTY-NOTICES.txt': b'original notices',
                      **{name: b'\x7fELForiginal guest executable' for name in finalizer.ELF}}
        self.archive = self.evidence / 'signed-compose.zip'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, data in self.files.items():
                entry = zipfile.ZipInfo('compose/' + name)
                entry.external_attr = (stat.S_IFREG | (0o755 if name != finalizer.BUILD_INFO else 0o644)) << 16
                archive.writestr(entry, data)
        (self.evidence / 'acceptance.json').write_bytes(b'{"passed":true}')
        self.admitted = {'source': SOURCE, 'signedAndNotarized': True,
                         'signedArchiveSHA256': finalizer.digest(self.archive.read_bytes()),
                         'signedTree': {name: finalizer.digest(data) for name, data in self.files.items()},
                         'unsignedCandidate': {'receipt': {'runtimeProfile': 'enhanced',
                                                          'dependencyLockSHA256': 'e' * 64}},
                         'noticeInventorySHA256': finalizer.digest(self.files['resources/THIRD-PARTY-NOTICES.txt']),
                         'compiledSdkChain': {'locks': {'q': 'exact-published-lock'}}}
        self.closure = self.root / 'legal.json'
        review = self.root / 'review.txt'
        review.write_bytes(b'fixture reviewed closure report')
        self.legal = {'schemaVersion': 1, 'scope': 'reviewed-compose-legal-closure',
                      'closureComplete': True, 'reviewer': 'fixture reviewer',
                      'reviewEvidence': 'review.txt',
                      'bindings': {'sourceCommit': SOURCE, 'runtimeProfile': 'enhanced',
                                   'dependencyLockSHA256': 'e' * 64,
                                   'dependencyNoticesSHA256': self.admitted['noticeInventorySHA256'],
                                   'compiledSdkChain': self.admitted['compiledSdkChain'],
                                   **{key: self.info[key] for key in ('containerSource', 'containerRef',
                                                                   'containerizationSource', 'containerizationRef')}},
                      'files': {'review.txt': {'sha256': finalizer.digest(review.read_bytes()),
                                               'bytes': review.stat().st_size}}}
        self.write_legal()
        self.calls = []

    def write_legal(self):
        self.closure.write_bytes(finalizer.canonical(self.legal))
        self.closure_sha = finalizer.digest(self.closure.read_bytes())

    def fake_command(self, args, timeout):
        self.calls.append(args)
        if args[0].endswith('/compose'):
            if args[-1] == '--short':
                return '0.15.2\n'
            return json.dumps(dict(self.info, version='0.15.2', lane='stable', branch='0.15.2'))
        if 'submit' in args:
            return json.dumps({'id': '12345678-1234-1234-1234-123456789abc'})
        if 'wait' in args:
            return json.dumps({'id': '12345678-1234-1234-1234-123456789abc', 'status': 'Accepted'})
        return ''

    def stage(self, **kwargs):
        options = dict(evidence=self.evidence, output=self.output, source=SOURCE,
                       tool_commit=TOOL, version='0.15.2', closure=self.closure,
                       closure_sha=self.closure_sha, admit=lambda _: self.admitted,
                       run=self.fake_command)
        options.update(kwargs)
        return finalizer.stage(**options)

    def test_metadata_only_and_exact_other_bytes(self):
        result = self.stage()
        tree = finalizer.archive_files(self.output / 'compose-stable.zip')
        for name, data in self.files.items():
            if name != finalizer.BUILD_INFO:
                self.assertEqual(tree[name][0], data)
        info = json.loads(tree[finalizer.BUILD_INFO][0])
        self.assertEqual(info, dict(self.info, version='0.15.2', lane='stable', branch='0.15.2'))
        with tarfile.open(self.output / finalizer.TAR_NAME, 'r:gz') as archive:
            tar_tree = {member.name.removeprefix('compose/'):
                        (archive.extractfile(member).read(), member.mode)
                        for member in archive.getmembers()}
        self.assertEqual(tar_tree, tree)
        self.assertEqual(result['sourceCommit'], SOURCE)
        self.assertEqual(result['toolCommit'], TOOL)
        self.assertEqual(sum('codesign' in args[0] for args in self.calls), 2)
        self.assertEqual(self.stage(), result)

    def test_absent_or_incomplete_legal_fails_before_commands(self):
        with self.assertRaisesRegex(finalizer.FinalizationError, 'required'):
            self.stage(closure=None)
        self.legal['closureComplete'] = False
        self.write_legal()
        with self.assertRaisesRegex(finalizer.FinalizationError, 'incomplete'):
            self.stage()
        self.assertFalse(self.calls)
        self.assertFalse(self.output.exists())

    def test_wrong_legal_bindings(self):
        for key in self.legal['bindings']:
            with self.subTest(key=key):
                original = copy.deepcopy(self.legal)
                self.legal['bindings'][key] = 'substituted'
                self.write_legal()
                with self.assertRaisesRegex(finalizer.FinalizationError, 'different inputs'):
                    self.stage()
                self.legal = original
        self.assertFalse(self.output.exists())

    def test_legal_sidecar_and_manifest_checksums(self):
        with self.assertRaisesRegex(finalizer.FinalizationError, 'checksum'):
            self.stage(closure_sha='f' * 64)
        (self.root / 'review.txt').write_bytes(b'changed review')
        with self.assertRaisesRegex(finalizer.FinalizationError, 'checksum'):
            self.stage()

    def test_changed_qualified_archive_or_tree(self):
        self.admitted['signedArchiveSHA256'] = 'f' * 64
        with self.assertRaisesRegex(finalizer.FinalizationError, 'archive changed'):
            self.stage()
        self.admitted['signedArchiveSHA256'] = finalizer.digest(self.archive.read_bytes())
        self.admitted['signedTree']['bin/compose'] = 'f' * 64
        with self.assertRaisesRegex(finalizer.FinalizationError, 'tree differs'):
            self.stage()

    def test_wrong_source_profile_version(self):
        for key, value in (('source', 'c' * 40), ('version', '01.2.3')):
            with self.subTest(key=key), self.assertRaises(finalizer.FinalizationError):
                self.stage(**{key: value})
        self.admitted['unsignedCandidate']['receipt']['runtimeProfile'] = 'stock'
        with self.assertRaisesRegex(finalizer.FinalizationError, 'profile'):
            self.stage()

    def test_signature_or_cli_failure_does_not_stage_archive(self):
        def rejected(args, _timeout):
            if 'codesign' in args[0]:
                raise finalizer.FinalizationError('signature rejected')
            return ''
        with self.assertRaisesRegex(finalizer.FinalizationError, 'signature'):
            self.stage(run=rejected)
        self.assertFalse((self.output / 'stage.json').exists())
        with self.assertRaisesRegex(finalizer.FinalizationError, 'reconciliation'):
            self.stage()

    def test_final_archive_tamper_or_changed_request_rejected(self):
        self.stage()
        with self.assertRaisesRegex(finalizer.FinalizationError, 'different inputs'):
            self.stage(version='0.15.3')
        (self.output / 'compose-stable.zip').write_bytes(b'changed')
        with self.assertRaisesRegex(finalizer.FinalizationError, 'archive changed'):
            self.stage()
        with self.assertRaisesRegex(finalizer.FinalizationError, 'input changed'):
            finalizer.notarize(self.output, 'fixture', run=self.fake_command)

    def test_accepted_notary_is_reused_without_resubmit(self):
        self.stage()
        first = finalizer.notarize(self.output, 'fixture', run=self.fake_command)
        self.assertTrue(first['archiveReady'])
        self.assertFalse(first['publicationAuthorized'])
        self.assertTrue(first['installationAndRestorationPending'])
        count = len(self.calls)
        self.assertEqual(finalizer.notarize(self.output, 'fixture', run=self.fake_command), first)
        self.assertEqual(len(self.calls), count)
        self.assertEqual(sum('submit' in args for args in self.calls), 1)

    def test_interrupted_wait_resumes_same_submission(self):
        self.stage()
        def interrupted(args, timeout):
            if 'wait' in args:
                raise TimeoutError('interrupted')
            return self.fake_command(args, timeout)
        with self.assertRaises(TimeoutError):
            finalizer.notarize(self.output, 'fixture', run=interrupted)
        finalizer.notarize(self.output, 'fixture', run=self.fake_command)
        self.assertEqual(sum('submit' in args for args in self.calls), 1)

    def test_uncertain_submit_never_resubmits(self):
        self.stage()
        def interrupted(_args, _timeout):
            raise TimeoutError('unknown submit outcome')
        with self.assertRaises(TimeoutError):
            finalizer.notarize(self.output, 'fixture', run=interrupted)
        count = len(self.calls)
        with self.assertRaisesRegex(finalizer.FinalizationError, 'reconciliation'):
            finalizer.notarize(self.output, 'fixture', run=self.fake_command)
        self.assertEqual(len(self.calls), count)

    def test_rejected_notary_cannot_emit_authority_or_retry(self):
        self.stage()
        def rejected(args, timeout):
            response = self.fake_command(args, timeout)
            if 'wait' in args:
                return json.dumps({'id': '12345678-1234-1234-1234-123456789abc',
                                   'status': 'Invalid'})
            return response
        with self.assertRaisesRegex(finalizer.FinalizationError, 'not accepted'):
            finalizer.notarize(self.output, 'fixture', run=rejected)
        self.assertFalse((self.output / 'authority.json').exists())
        with self.assertRaisesRegex(finalizer.FinalizationError, 'reconciliation'):
            finalizer.notarize(self.output, 'fixture', run=self.fake_command)
        self.assertEqual(sum('submit' in args for args in self.calls), 1)

    def test_incomplete_qualification_is_not_replaced_by_finalizer(self):
        def failed_admission(_evidence):
            raise RuntimeError('qualification has not passed')
        with self.assertRaisesRegex(RuntimeError, 'not passed'):
            self.stage(admit=failed_admission)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.calls)

    def test_appledouble_is_authenticated_by_zip_and_preserved(self):
        with zipfile.ZipFile(self.archive, 'a') as archive:
            entry = zipfile.ZipInfo('compose/resources/._build-info.json')
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, b'original AppleDouble metadata')
        self.admitted['signedArchiveSHA256'] = finalizer.digest(self.archive.read_bytes())
        self.stage()
        tree = finalizer.archive_files(self.output / 'compose-stable.zip')
        self.assertEqual(tree['resources/._build-info.json'],
                         (b'original AppleDouble metadata', 0o644))

    def add_external_source(self):
        path = self.root / 'compose-source-companion.tar.gz'
        path.write_bytes(b'fixture independently reviewed source archive')
        self.legal['externalSourceCompanion'] = {
            'asset': path.name, 'sha256': finalizer.file_digest(path), 'bytes': path.stat().st_size,
            'url': 'https://github.com/stephenlclarke/container-compose/releases/download/0.15.2/' + path.name}
        self.legal['sourceAvailabilityNotice'] = 'sources.txt'
        notice = self.root / 'sources.txt'
        notice.write_text(self.legal['externalSourceCompanion']['url'] + '\n' +
                          self.legal['externalSourceCompanion']['sha256'] + '\n')
        self.legal['files'][notice.name] = {'sha256': finalizer.file_digest(notice), 'bytes': notice.stat().st_size}
        self.write_legal()
        return path

    def test_external_source_is_bound_but_not_embedded(self):
        self.add_external_source()
        self.stage()
        tree = finalizer.archive_files(self.output / 'compose-stable.zip')
        self.assertNotIn('resources/legal/compose-source-companion.tar.gz', tree)
        self.assertIn('resources/legal/sources.txt', tree)
        request = json.loads((self.output / 'request.json').read_text())
        self.assertEqual(request['externalSourceCompanion'], self.legal['externalSourceCompanion'])

    def test_missing_changed_or_wrong_url_external_source_fails(self):
        path = self.add_external_source()
        path.unlink()
        with self.assertRaisesRegex(finalizer.FinalizationError, 'missing'):
            self.stage()
        path.write_bytes(b'changed source bytes')
        with self.assertRaisesRegex(finalizer.FinalizationError, 'checksum'):
            self.stage()
        self.add_external_source()
        self.legal['externalSourceCompanion']['url'] = self.legal['externalSourceCompanion']['url'].replace('0.15.2', '0.16.0')
        self.write_legal()
        with self.assertRaisesRegex(finalizer.FinalizationError, 'claim'):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_unsafe_archive_member_rejected(self):
        for name in ('compose/../escape', '/compose/escape', 'compose/./escape', 'foreign/file'):
            with self.subTest(name=name):
                with zipfile.ZipFile(self.archive, 'w') as archive:
                    archive.writestr(name, b'bad')
                with self.assertRaisesRegex(finalizer.FinalizationError, 'unsafe'):
                    finalizer.archive_files(self.archive)


if __name__ == '__main__':
    unittest.main()
