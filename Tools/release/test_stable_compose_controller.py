"""Ordering and interruption safety of the controller; all adapters are fake."""
import copy
from pathlib import Path
import tempfile
import unittest

import stable_compose_controller as controller


class FakeOperations:
    def __init__(self, plan):
        self.plan = plan
        self.executed = []
        self.remote = {}
        self.fail = None

    def inspect(self, phase, _plan, _sha):
        return self.remote.get(phase)

    def execute(self, phase, plan, sha, _prior):
        self.executed.append(phase)
        if self.fail == phase:
            raise TimeoutError('uncertain external operation')
        proof = {'phase': phase, 'passed': True, 'planSHA256': sha}
        if phase == 'tag':
            proof.update(signed=True, targetCommit=plan['sourceCommit'], tagObject='b' * 40)
        if phase == 'publication':
            proof.update(releaseId=123, immutable=True, assets=plan['assets'])
        if phase == 'download':
            proof.update(assets=plan['assets'], signaturesVerified=True)
        if phase == 'installation':
            proof.update(installationAdapterSHA256=plan['installationAdapterSHA256'],
                         installationContextSHA256=plan['installationContextSHA256'],
                         installationCoreSHA256=plan['installationCoreSHA256'],
                         receipt={'scope': 'compose-homebrew-formula-pair-installation-test',
                                  'status': 'passed-restored', 'sourceCommit': plan['sourceCommit'],
                                  'productVersion': plan['releaseTag'],
                                  'runtimeSourceCommit': plan['runtimeQualifiedSource'],
                                  'runtimeVersion': plan['runtimeFormulaVersion'],
                                  'runtimeProductVersion': plan['runtimeProductVersion'],
                                  'installedRuntimeProduct': {'productVersion': plan['runtimeProductVersion'],
                                                              'sourceCommit': plan['runtimeQualifiedSource']},
                                  'baselineRestored': True, 'guardAbsent': True,
                                  'ownedPluginRegistrationOnly': True, 'ownedPluginRegistrationExecuted': True,
                                  'broadPostInstallStopExecuted': False, 'releaseAuthority': False,
                                  'runtimeArchiveSHA256': plan['runtimeArchiveSHA256'],
                                  'composeArchiveSHA256': plan['composeArchiveSHA256'],
                                  'formulaPairSHA256': plan['formulaPairSHA256'],
                                  'runtimeBinarySHA256': plan['runtimeBinarySHA256'],
                                  'composeBinarySHA256': plan['composeBinarySHA256'],
                                  'beforeInventorySHA256': 'c' * 64,
                                  'afterInventorySHA256': 'c' * 64})
        if phase == 'tap':
            proof.update(formulaPairSHA256=plan['formulaPairSHA256'], atomicPairCommit=True, tapCommit='d' * 40)
        if phase == 'promotion':
            proof.update(releaseId=123, prerelease=False, latest=True, assets=plan['assets'])
        self.remote[phase] = proof
        return proof

    def validate(self, phase, proof, _plan, _sha):
        if self.remote.get(phase) != proof:
            raise controller.ControllerError('remote proof changed')


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/Volumes/SSD/q')
        self.addCleanup(self.temp.cleanup)
        self.journal = Path(self.temp.name) / 'controller.json'
        names = ('container-compose-plugin-release-arm64.tar.gz', 'container-release-arm64.tar.gz',
                 'compose-stable-archive-authority.json', 'compose-stable-provenance.json',
                 'compose-final-notarization.json', 'compose-qualified-evidence-v1.zip',
                 'compose-reviewed-legal-closure.json', 'compose-runtime-pair-provenance.json',
                 'container-compose-plugin-release-arm64.tar.gz.sha256', 'container-release-arm64.tar.gz.sha256')
        self.plan = {'schemaVersion': 1, 'scope': 'bazel-compose-stable-release-plan',
                     'repository': 'stephenlclarke/container-compose', 'releaseTag': '0.16.0',
                     'sourceCommit': 'a' * 40, 'toolCommit': 'b' * 40, 'runtimeProfile': 'enhanced',
                     'runtimeQualifiedSource': 'f86fea2236fab118c0e0c6f8be5eb7672df894e2',
                     'legacyStableGateClaim': False, 'legalClosureComplete': True,
                     'runtimeFormulaVersion': '0.16.0', 'runtimeProductVersion': '0.0.0',
                     'assets': {name: {'sha256': 'e' * 64, 'bytes': 100} for name in names},
                     'formulaPairSHA256': {'container': 'f' * 64, 'container-compose': 'd' * 64},
                     **{key: 'e' * 64 for key in ('qualificationSHA256', 'legalClosureSHA256',
                                                'archiveAuthoritySHA256', 'runtimeArchiveSHA256',
                                                'composeArchiveSHA256', 'installationContextSHA256',
                                                'installationCoreSHA256', 'installationAdapterSHA256',
                                                'runtimeBinarySHA256', 'composeBinarySHA256')}}
        self.operations = FakeOperations(self.plan)

    def test_order_and_completed_resume_never_repeats_operations(self):
        first = controller.execute(self.plan, self.journal, self.operations)
        self.assertTrue(first['complete'])
        self.assertEqual(self.operations.executed, list(controller.PHASES))
        controller.execute(self.plan, self.journal, self.operations)
        self.assertEqual(self.operations.executed, list(controller.PHASES))

    def test_uncertain_installation_never_retries_or_promotes(self):
        self.operations.fail = 'installation'
        with self.assertRaises(TimeoutError):
            controller.execute(self.plan, self.journal, self.operations)
        self.operations.fail = None
        with self.assertRaisesRegex(controller.ControllerError, 'reconciliation'):
            controller.execute(self.plan, self.journal, self.operations)
        self.assertEqual(self.operations.executed.count('installation'), 1)
        self.assertNotIn('tap', self.operations.executed)
        self.assertNotIn('promotion', self.operations.executed)

    def test_uncertain_promotion_reconciles_without_republication(self):
        self.operations.fail = 'promotion'
        with self.assertRaises(TimeoutError):
            controller.execute(self.plan, self.journal, self.operations)
        self.operations.fail = None
        controller.execute(self.plan, self.journal, self.operations)
        self.assertEqual(self.operations.executed.count('tag'), 1)
        self.assertEqual(self.operations.executed.count('publication'), 1)
        self.assertEqual(self.operations.executed.count('installation'), 1)

    def test_wrong_formula_or_inventory_receipt_rejects_tap(self):
        original_execute = self.operations.execute
        def substituted(phase, plan, sha, prior):
            proof = original_execute(phase, plan, sha, prior)
            if phase == 'installation':
                proof['receipt']['afterInventorySHA256'] = '0' * 64
            return proof
        self.operations.execute = substituted
        with self.assertRaisesRegex(controller.ControllerError, 'installation/restoration'):
            controller.execute(self.plan, self.journal, self.operations)
        self.assertNotIn('tap', self.operations.executed)

    def test_source_tag_and_frozen_plan_are_enforced(self):
        original_execute = self.operations.execute
        def substituted(phase, plan, sha, prior):
            proof = original_execute(phase, plan, sha, prior)
            if phase == 'tag':
                proof['targetCommit'] = '0' * 40
            return proof
        self.operations.execute = substituted
        with self.assertRaisesRegex(controller.ControllerError, 'exact-source'):
            controller.execute(self.plan, self.journal, self.operations)
        changed = copy.deepcopy(self.plan)
        changed['releaseTag'] = '0.16.1'
        changed['runtimeFormulaVersion'] = '0.16.1'
        with self.assertRaisesRegex(controller.ControllerError, 'durable journal'):
            controller.execute(changed, self.journal, self.operations)
        self.assertNotIn('publication', self.operations.executed)


if __name__ == '__main__':
    unittest.main()
