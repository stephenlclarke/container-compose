"""Production adapter failure boundaries with fake commands and fixture receipts."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import finalize_qualified_compose as finalizer
import publish_qualified_compose as publication
import stable_compose_controller as controller


class ProductionBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/Volumes/SSD/q')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ops = publication.ProductionOperations.__new__(publication.ProductionOperations)
        self.ops.plan = {'sourceCommit': 'a' * 40, 'releaseTag': '0.16.0',
                         'runtimeQualifiedSource': 'f86fea2236fab118c0e0c6f8be5eb7672df894e2',
                         'runtimeFormulaVersion': '0.16.0', 'runtimeProductVersion': '0.0.0',
                         'formulaPairSHA256': {'container': 'b' * 64, 'container-compose': 'c' * 64},
                         **{key: 'd' * 64 for key in ('runtimeArchiveSHA256', 'composeArchiveSHA256',
                            'runtimeBinarySHA256', 'composeBinarySHA256', 'installationContextSHA256',
                            'installationCoreSHA256', 'installationAdapterSHA256')},
                         'assets': {'fixture.bin': {'sha256': finalizer.digest(b'qualified'), 'bytes': 9}}}
        self.ops.manifest = {'allowedSigners': str(self.root / 'signers'), 'notes': 'owned notes', 'title': 'owned title'}
        self.ops.source_repo = self.root
        self.ops.journals = self.root
        self.ops.downloads = self.root
        self.commands = []

    def response(self, stdout='', stderr='', code=0):
        return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=code)

    def test_missing_buildx_rejects_classic_fallback(self):
        def fake(args, **_kwargs):
            self.commands.append(args)
            return self.response('5.5.1' if 'compose' in args else 'classic docker builder')
        self.ops.run = fake
        with self.assertRaisesRegex(controller.ControllerError, 'plugin closure'):
            self.ops.require_plugins()
        self.assertEqual(len(self.commands), 2)

    def test_foreign_origin_and_wrong_source_tag_never_push(self):
        self.ops.git = lambda *_args, **_kwargs: 'git@github.com:apple/container-compose.git'
        with self.assertRaisesRegex(controller.ControllerError, 'owning repository'):
            self.ops._origin(self.root, publication.REPOSITORY)
        self.ops._origin = lambda *_args: None
        self.ops._remote = lambda *_args: 'b' * 40
        def fake_git(_repo, *args, **_kwargs):
            self.commands.append(args)
            if args[:2] == ('cat-file', '-t'):
                return 'tag'
            if args[-1].endswith('^{commit}'):
                return 'c' * 40
            return 'b' * 40
        self.ops.git = fake_git
        with self.assertRaisesRegex(controller.ControllerError, 'exact-source'):
            self.ops._tag('e' * 64, create=True)
        self.assertFalse(any('push' in args for args in self.commands))

    def configure_release(self):
        release = {'id': 123, 'draft': False, 'immutable': True, 'tag_name': '0.16.0',
                   'body': 'owned notes\n\n<!-- marker -->', 'prerelease': True,
                   'assets': [{'name': 'fixture.bin', 'id': 456, 'size': 9,
                               'digest': 'sha256:' + finalizer.digest(b'qualified')}]}
        self.release_fixture = release
        self.ops.gh = lambda *_args, **_kwargs: release
        journal = self.root / 'publication.json'
        finalizer.durable(journal, {'releaseId': 123, 'notesWithMarker': release['body'],
            'intent': {'targetCommit': 'a' * 40, 'notes': 'owned notes', 'title': 'owned title'},
            'assetIds': {'fixture.bin': 456}})
        self.ops._libraries = {'assets': SimpleNamespace(tag_commit=lambda *_args: 'a' * 40,
            publication_journal_path=lambda *_args: journal)}

    def test_mutable_or_changed_remote_asset_is_rejected(self):
        self.configure_release()
        self.release_fixture['immutable'] = False
        with self.assertRaisesRegex(controller.ControllerError, 'immutable'):
            self.ops.release()
        self.release_fixture['immutable'] = True
        self.release_fixture['assets'][0]['digest'] = 'sha256:' + '0' * 64
        with self.assertRaisesRegex(controller.ControllerError, 'digest/size'):
            self.ops.release()

    def test_changed_download_bytes_rejected_before_signature_or_brew(self):
        self.configure_release()
        name = 'fixture.bin'
        lock = {'schema': 1, 'repository': publication.REPOSITORY, 'tag': '0.16.0',
                'targetCommit': 'a' * 40, 'asset': name, 'sha256': finalizer.digest(b'qualified')}
        lock_path = self.root / (name + '.lock.json')
        finalizer.durable(lock_path, lock)
        destination = self.root / name
        destination.mkdir()
        (destination / name).write_bytes(b'corrupted')
        finalizer.durable(destination / 'fetch-receipt.json', {
            'releaseId': 123, 'assetId': 456, 'asset': str(destination / name),
            'sha256': lock['sha256'], 'lockSHA256': finalizer.digest(finalizer.read(lock_path)),
            'targetCommit': 'a' * 40, 'repository': publication.REPOSITORY, 'tag': '0.16.0'})
        self.ops._admission = lambda _sha: self.fail('corrupted download must not reach admission/signature/Brew')
        with self.assertRaisesRegex(controller.ControllerError, 'downloaded release'):
            self.ops._download('e' * 64)

    def test_status_alone_and_changed_inventory_cannot_admit_installation(self):
        path = self.root / 'installation.json'
        self.ops.manifest['installationReceipt'] = str(path)
        finalizer.durable(path, {'status': 'passed-restored'})
        with self.assertRaisesRegex(controller.ControllerError, 'installation/restoration'):
            self.ops._installation('e' * 64)
        receipt = {'scope': 'compose-homebrew-formula-pair-installation-test', 'status': 'passed-restored',
                   'sourceCommit': self.ops.plan['sourceCommit'], 'productVersion': '0.16.0',
                   'runtimeSourceCommit': self.ops.plan['runtimeQualifiedSource'],
                   'runtimeVersion': '0.16.0', 'runtimeProductVersion': '0.0.0',
                   'installedRuntimeProduct': {'productVersion': '0.0.0', 'sourceCommit': self.ops.plan['runtimeQualifiedSource']},
                   'baselineRestored': True, 'guardAbsent': True, 'ownedPluginRegistrationOnly': True,
                   'ownedPluginRegistrationExecuted': True, 'broadPostInstallStopExecuted': False,
                   'releaseAuthority': False, 'beforeInventorySHA256': '1' * 64, 'afterInventorySHA256': '2' * 64,
                   **{key: self.ops.plan[key] for key in ('runtimeArchiveSHA256', 'composeArchiveSHA256',
                                                         'runtimeBinarySHA256', 'composeBinarySHA256', 'formulaPairSHA256')}}
        finalizer.durable(path, receipt)
        with self.assertRaisesRegex(controller.ControllerError, 'installation/restoration'):
            self.ops._installation('e' * 64)

    def test_promotion_only_changes_same_release_metadata(self):
        release = {'id': 123, 'prerelease': True}
        self.ops.release = lambda **_kwargs: release
        calls = []
        def fake_gh(endpoint, **kwargs):
            calls.append((endpoint, kwargs))
            if 'body' in kwargs:
                release['prerelease'] = False
                return dict(release)
            return {'id': 999 if release['prerelease'] else 123}
        self.ops.gh = fake_gh
        proof = self.ops._promotion('e' * 64, execute=True)
        patches = [(endpoint, kwargs['body']) for endpoint, kwargs in calls if 'body' in kwargs]
        self.assertEqual(patches, [('repos/' + publication.REPOSITORY + '/releases/123',
                                   {'prerelease': False, 'make_latest': 'true'})])
        self.assertEqual(proof['releaseId'], 123)
        self.assertEqual(proof['assets'], self.ops.plan['assets'])

    def test_tap_remote_race_rejects_before_any_formula_write(self):
        self.ops.tap = self.root
        self.ops.manifest['tapBaselineCommit'] = 'a' * 40
        self.ops._origin = lambda *_args: None
        self.ops._remote = lambda *_args: 'b' * 40
        self.ops.git = lambda _repo, *args, **_kwargs: 'main' if args[0] == 'symbolic-ref' else 'a' * 40
        with self.assertRaisesRegex(controller.ControllerError, 'baseline'):
            self.ops._tap('e' * 64, execute=True)
        self.assertFalse((self.root / 'Formula').exists())

    def configure_tap_intent(self, committed=False, pushed=False):
        baseline, head, sha = 'a' * 40, 'f' * 40, 'e' * 64
        self.ops.tap = self.root
        self.ops.manifest['tapBaselineCommit'] = baseline
        self.ops._origin = lambda *_args: None
        self.ops._signed = lambda *_args: None
        for name, relative in publication.FORMULAE.items():
            path = self.root / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(name.encode())
            self.ops.plan['formulaPairSHA256'][name] = finalizer.digest(path.read_bytes())
        finalizer.durable(self.root / 'stable-0.16.0-tap.json', {
            'planSHA256': sha, 'baseline': baseline, 'before': self.ops.plan['formulaPairSHA256']})
        self.ops._remote = lambda *_args: head if pushed else baseline
        def git(_repo, *args, **_kwargs):
            self.commands.append(args)
            if args[0] == 'symbolic-ref':
                return 'main'
            if args[0] == 'rev-parse':
                return baseline if args[-1].endswith('^') else head if committed else baseline
            if args[0] == 'show':
                return 'chore(release): publish pair\n\nStable release plan SHA-256: ' + sha
            if args[0] == 'diff-tree':
                return '\n'.join(publication.FORMULAE.values())
            if args[0] == 'status':
                return ''
            self.fail('unexpected inspection command: ' + repr(args))
        self.ops.git = git
        return sha

    def test_tap_inspection_never_writes_commits_or_pushes_existing_intent(self):
        for committed, pushed in ((False, False), (True, False), (True, True)):
            with self.subTest(committed=committed, pushed=pushed):
                sha = self.configure_tap_intent(committed, pushed)
                with patch.object(finalizer, 'durable', side_effect=AssertionError('inspect wrote journal')):
                    result = self.ops._tap(sha)
                self.assertEqual(result is not None, pushed)
                self.assertFalse(any('push' in args or 'commit' in args or 'add' in args for args in self.commands))

    def test_owned_tap_recovery_requires_explicit_flag_and_prior_proofs(self):
        sha = self.configure_tap_intent(True, False)
        self.ops.recover_owned_tap = False
        self.assertIsNone(self.ops.recover('tap', self.ops.plan, sha, {}))
        self.ops.recover_owned_tap = True
        validated = []
        self.ops.validate = lambda phase, *_args: validated.append(phase)
        self.ops.execute = lambda phase, *_args: {'phase': phase}
        self.assertEqual(self.ops.recover('tap', self.ops.plan, sha, dict.fromkeys(
            ('admission', 'tag', 'publication', 'download', 'installation'), {})), {'phase': 'tap'})
        self.assertEqual(validated, ['admission', 'tag', 'publication', 'download', 'installation'])

    def test_promotion_rechecks_installation_and_remote_tap_before_patch(self):
        self.ops.verify_inputs = lambda: None
        checked = []
        def validate(phase, *_args):
            checked.append(phase)
            if phase == 'tap':
                raise controller.ControllerError('remote pair changed')
        self.ops.validate = validate
        self.ops._promotion = lambda *_args, **_kwargs: self.fail('must not patch after changed pair')
        with self.assertRaisesRegex(controller.ControllerError, 'remote pair changed'):
            self.ops.execute('promotion', self.ops.plan, 'e' * 64,
                dict.fromkeys(('tag', 'publication', 'download', 'installation', 'tap'), {}))
        self.assertEqual(checked, ['tag', 'publication', 'download', 'installation', 'tap'])


if __name__ == '__main__':
    unittest.main()
