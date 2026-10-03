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

"""No-network exact-attempt hosted admission regressions."""
from __future__ import annotations

import unittest
from pathlib import Path
import json
import hashlib
import tempfile
from unittest.mock import patch

import hosted_quality as quality

SHA = 'a' * 40
CONTEXT = {'number': 708, 'head': SHA, 'branch': 'build/bazel-workflow',
           'base': 'main', 'base_sha': 'b' * 40}


def run(identifier: int, attempt: int, conclusion: str) -> dict:
    return {'id': identifier, 'run_attempt': attempt, 'run_started_at': '2026-09-28T10:00:00+00:00',
            'head_sha': SHA, 'head_branch': CONTEXT['branch'], 'event': 'pull_request',
            'status': 'completed', 'conclusion': conclusion, 'html_url': 'https://github.com/example/run',
            'repository': {'full_name': quality.REPOSITORY},
            'head_repository': {'full_name': quality.REPOSITORY},
            'pull_requests': [{'number': 708, 'head': {'sha': SHA},
                               'base': {'sha': CONTEXT['base_sha'], 'ref': 'main'}}]}


def style_job(conclusion: str = 'success') -> dict:
    return {'id': 91, 'name': 'SwiftLint/SwiftFormat', 'head_sha': SHA,
            'status': 'completed', 'conclusion': conclusion, 'html_url': 'https://github.com/example/style',
            'steps': [{'name': name, 'conclusion': 'success'} for name in
                      ('Verify exact Swift style source', 'Run deterministic Swift style checks')]}


class HostedQualityTests(unittest.TestCase):
    def test_hosted_codeql_rechecks_exact_reviewed_raw_findings(self) -> None:
        compatibility = quality.codeql_compatibility
        policy_path = quality.ROOT / 'Tools/ci' / compatibility.POLICY_NAME
        policy = compatibility.load_policy(policy_path)
        rows = [{'ruleId': item['rule_id'],
                 'partialFingerprints': item['partial_fingerprints'],
                 'locations': [{'physicalLocation': {
                     'artifactLocation': {'uri': item['uri'], 'uriBaseId': '%SRCROOT%'},
                     'region': item['region']}}]} for item in policy['findings']]
        ci, style = run(30, 1, 'success'), run(40, 1, 'success')
        prefix = 'swift-codeql-extraction-stock'
        def api(path: str) -> dict:
            if 'ci.yml/runs?' in path:
                return {'workflow_runs': [ci]}
            if 'quality.yml/runs?' in path:
                return {'workflow_runs': [style]}
            if '/jobs?' in path:
                return {'jobs': [style_job()]}
            return {'artifacts': []}
        for unexpected in (False, True):
            def download(_run, _name, directory):
                sarif = {'runs': [{'results': rows + ([{'ruleId': 'swift/new'}] if unexpected else [])}]}
                raw = directory / 'swift-stock.sarif'
                raw.write_text(json.dumps(sarif))
                inventory = directory / 'swift-source-inventory.txt'
                inventory.write_text('Sources/ComposeCore/A.swift\n')
                report = {'language': 'swift', 'complete': True, 'clean': True,
                          'inventory_count': 1, 'inventory_extracted_count': 1,
                          'extraction_error_diagnostic_count': 0,
                          **compatibility.assessment({'runs': [{'results': rows}]}, policy),
                          'compatibility_disposition_sha256': compatibility.digest(policy_path),
                          'compatibility_source': compatibility.source_receipt(
                              quality.ROOT, policy, verify_checkout=False),
                          'sarif_sha256': compatibility.digest(raw),
                          'inventory_sha256': compatibility.digest(inventory)}
                (directory / quality.ARTIFACTS[prefix]).write_text(json.dumps(report))
            with self.subTest(unexpected=unexpected), tempfile.TemporaryDirectory() as temporary, \
                 patch.object(quality, 'api', side_effect=api), \
                 patch.object(quality, 'current_context', return_value=CONTEXT), \
                 patch.object(quality, 'require_jobs', return_value={}), \
                 patch.object(quality, 'require_artifacts', return_value={prefix: {'name': prefix}}), \
                 patch.object(quality, 'download', side_effect=download):
                if unexpected:
                    with self.assertRaisesRegex(ValueError, 'raw findings'):
                        quality.admit(SHA, Path(temporary) / 'evidence')
                else:
                    self.assertTrue(quality.admit(SHA, Path(temporary) / 'evidence')['passed'])

    def test_style_requires_real_exact_head_job_and_both_steps(self) -> None:
        self.assertEqual(quality.require_style_job([style_job()], SHA)['id'], 91)
        for changed in ({'conclusion': 'skipped'}, {'status': 'in_progress'},
                        {'head_sha': 'b' * 40}):
            with self.assertRaisesRegex(ValueError, 'SwiftLint/SwiftFormat'):
                quality.require_style_job([{**style_job(), **changed}], SHA)
        missing = style_job()
        missing['steps'] = missing['steps'][1:]
        with self.assertRaisesRegex(ValueError, 'Verify exact'):
            quality.require_style_job([missing], SHA)

    def test_style_run_is_exact_pr_head_base_and_latest_attempt(self) -> None:
        old, red = run(40, 1, 'success'), run(40, 2, 'failure')
        self.assertEqual(quality.newest_run([old, red], CONTEXT, 'Quality'), red)
        wrong = run(41, 1, 'success')
        wrong['pull_requests'][0]['base']['sha'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'Quality'):
            quality.newest_run([wrong], CONTEXT, 'Quality')
        wrong_head = run(42, 1, 'success')
        wrong_head['head_sha'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'Quality'):
            quality.newest_run([wrong_head], CONTEXT, 'Quality')

    def test_successful_style_attempt_is_retained_with_job_identity(self) -> None:
        ci, style = run(30, 1, 'success'), run(40, 2, 'success')
        def api(path: str) -> dict:
            if 'ci.yml/runs?' in path:
                return {'workflow_runs': [ci]}
            if 'quality.yml/runs?' in path:
                return {'workflow_runs': [style]}
            if '/jobs?' in path:
                return {'jobs': [style_job()]}
            return {'artifacts': []}
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(quality, 'api', side_effect=api), \
             patch.object(quality, 'current_context', return_value=CONTEXT), \
             patch.object(quality, 'require_jobs', return_value={}), \
             patch.object(quality, 'require_artifacts', return_value={}):
            result = quality.admit(SHA, Path(temporary) / 'quality')
        self.assertTrue(result['passed'])
        self.assertEqual(result['style_run']['run_attempt'], 2)
        self.assertEqual(result['style_job']['id'], 91)

    def test_missing_failed_or_pending_style_blocks_release_admission(self) -> None:
        ci = run(30, 1, 'success')
        for style in (None, run(40, 1, 'failure'),
                      {**run(40, 1, 'success'), 'status': 'in_progress', 'conclusion': None}):
            def api(path: str) -> dict:
                if 'ci.yml/runs?' in path:
                    return {'workflow_runs': [ci]}
                if 'quality.yml/runs?' in path:
                    return {'workflow_runs': [] if style is None else [style]}
                if '/artifacts?' in path:
                    return {'artifacts': []}
                return {'jobs': []}
            with self.subTest(style=style), tempfile.TemporaryDirectory() as temporary, \
                 patch.object(quality, 'api', side_effect=api), \
                 patch.object(quality, 'current_context', return_value=CONTEXT), \
                 patch.object(quality, 'require_jobs', return_value={}):
                with self.assertRaisesRegex(ValueError, 'Quality|Swift style'):
                    quality.admit(SHA, Path(temporary) / 'quality')

    def test_latest_attempt_outweighs_older_success(self) -> None:
        older = run(30, 1, 'success')
        rerun = run(30, 2, 'failure')
        self.assertEqual(quality.newest_run([older, rerun], CONTEXT), rerun)

    def test_pr_base_mismatch_excludes_run(self) -> None:
        wrong = run(30, 1, 'success')
        wrong['pull_requests'][0]['base']['sha'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'No matching'):
            quality.newest_run([wrong], CONTEXT)

    def test_skipped_required_job_fails(self) -> None:
        jobs = [{'id': index, 'name': name, 'head_sha': SHA, 'status': 'completed',
                 'conclusion': 'success', 'html_url': 'https://github.com/example'}
                for index, name in enumerate(quality.JOBS)]
        jobs[-1]['conclusion'] = 'skipped'
        with self.assertRaisesRegex(ValueError, 'Validate'):
            quality.require_jobs(jobs, SHA)

    def test_full_validate_accepts_only_success_plus_skipped_lightweight(self) -> None:
        jobs = [{'id': index, 'name': name, 'head_sha': SHA, 'status': 'completed',
                 'conclusion': 'success', 'html_url': 'https://github.com/example'}
                for index, name in enumerate(quality.JOBS)]
        jobs[-1]['steps'] = [{'name': 'Check parallel validation jobs', 'conclusion': 'success'}]
        lightweight = dict(jobs[-1], id=99, conclusion='skipped', steps=[])
        jobs.append(lightweight)
        self.assertEqual(quality.require_jobs(jobs, SHA)['Validate']['id'], jobs[-2]['id'])
        jobs[-1]['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'Validate'):
            quality.require_jobs(jobs, SHA)

    def test_missing_platform_artifact_fails(self) -> None:
        artifacts = [{'id': index, 'name': prefix + '-' + SHA, 'expired': False}
                     for index, prefix in enumerate(quality.ARTIFACTS)
                     if prefix != 'go-codeql-extraction-darwin']
        with self.assertRaisesRegex(ValueError, 'darwin'):
            quality.require_artifacts(artifacts, SHA)

    def test_new_attempt_during_artifact_download_is_rejected(self) -> None:
        first, newer = run(30, 1, 'success'), run(30, 2, 'failure')
        state = {'downloaded': False}
        def api(path: str):
            if 'quality.yml/runs?' in path:
                return {'workflow_runs': [run(40, 1, 'success')]}
            if 'ci.yml/runs?' in path:
                return {'workflow_runs': [first, newer] if state['downloaded'] else [first]}
            if '/jobs?' in path:
                return {'jobs': []}
            return {'artifacts': []}
        def download(_run: int, _name: str, directory: Path):
            (directory / 'sonar-pr-gate.json').write_text(json.dumps({
                'source_sha': SHA, 'pull_request': 708, 'quality_gate': 'OK',
                'analysis_id': 'analysis', 'ce_task_id': 'task', 'unresolved_pr_issues': 0,
                'unreviewed_project_hotspots': 0, 'unreviewed_pr_hotspots': 0}))
            state['downloaded'] = True
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(quality, 'api', side_effect=api), \
             patch.object(quality, 'current_context', return_value=CONTEXT), \
             patch.object(quality, 'require_jobs', return_value={}), \
             patch.object(quality, 'require_style_job', return_value=style_job()), \
             patch.object(quality, 'require_artifacts', return_value={
                 'sonar-pr-gate': {'id': 1, 'name': 'sonar-pr-gate-'+SHA}}), \
             patch.object(quality, 'download', side_effect=download):
            with self.assertRaisesRegex(ValueError, 'Newer or changed'):
                quality.admit(SHA, Path(temporary) / 'quality')

    def test_new_style_attempt_during_artifact_download_is_rejected(self) -> None:
        ci, first_style, red_style = run(30, 1, 'success'), run(40, 1, 'success'), run(40, 2, 'failure')
        state = {'downloaded': False}
        def api(path: str) -> dict:
            if 'quality.yml/runs?' in path:
                return {'workflow_runs': [first_style, red_style] if state['downloaded'] else [first_style]}
            if 'ci.yml/runs?' in path:
                return {'workflow_runs': [ci]}
            if '/artifacts?' in path:
                return {'artifacts': []}
            return {'jobs': []}
        def download(_run: int, _name: str, directory: Path) -> None:
            (directory / 'sonar-pr-gate.json').write_text(json.dumps({
                'source_sha': SHA, 'pull_request': 708, 'quality_gate': 'OK',
                'analysis_id': 'analysis', 'ce_task_id': 'task', 'unresolved_pr_issues': 0,
                'unreviewed_project_hotspots': 0, 'unreviewed_pr_hotspots': 0}))
            state['downloaded'] = True
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(quality, 'api', side_effect=api), \
             patch.object(quality, 'current_context', return_value=CONTEXT), \
             patch.object(quality, 'require_jobs', return_value={}), \
             patch.object(quality, 'require_style_job', return_value=style_job()), \
             patch.object(quality, 'require_artifacts', return_value={
                 'sonar-pr-gate': {'id': 1, 'name': 'sonar-pr-gate-'+SHA}}), \
             patch.object(quality, 'download', side_effect=download):
            with self.assertRaisesRegex(ValueError, 'Newer or changed Swift style'):
                quality.admit(SHA, Path(temporary) / 'quality')


class CoverageAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = {}
        for profile in ('enhanced', 'stock'):
            directory = self.root / 'profiles' / profile
            directory.mkdir(parents=True)
            (directory / 'coverage.xml').write_text('<coverage version="1"/>')
            receipt = {'schema': 1, 'source_sha': SHA, 'profile': profile,
                       'source_files': {'Sources/File.swift': 'c' * 64},
                       'coverage_sha256': self.digest(directory / 'coverage.xml')}
            (directory / 'receipt.json').write_text(json.dumps(receipt))
            self.inputs[profile] = {'receipt_sha256': self.digest(directory / 'receipt.json'),
                                    'coverage_sha256': receipt['coverage_sha256']}
        (self.root / 'coverage.xml').write_text('<coverage version="1"/>')
        (self.root / 'coverage.out').write_text('mode: atomic\n')
        self.union = {'schema': 1, 'kind': 'stock-and-enhanced-line-union',
                      'source_sha': SHA, 'profiles': ['enhanced', 'stock'],
                      'profile_inputs': self.inputs,
                      'coverage_sha256': self.digest(self.root / 'coverage.xml')}
        self.seal()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def seal(self) -> None:
        (self.root / 'profile-union.json').write_text(json.dumps(self.union))
        value = {'source_sha': SHA, 'profiles': ['enhanced', 'stock'], 'gate': 'PASS',
                 'authority': 'make coverage-profiles-check',
                 'sha256': {name: self.digest(self.root / name) for name in
                            ('coverage.xml', 'coverage.out', 'profile-union.json')}}
        (self.root / 'receipt.json').write_text(json.dumps(value))

    def test_two_profile_receipt_is_admitted(self) -> None:
        quality.require_unit_coverage(self.root, SHA)

    def test_old_enhanced_only_authority_is_rejected(self) -> None:
        (self.root / 'receipt.json').write_text(json.dumps({
            'source_sha': SHA, 'profile': 'enhanced', 'gate': 'PASS',
            'authority': 'make coverage-check'}))
        with self.assertRaisesRegex(ValueError, 'both profiles'):
            quality.require_unit_coverage(self.root, SHA)

    def test_tampered_raw_profile_is_rejected(self) -> None:
        (self.root / 'profiles/stock/coverage.xml').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'stock coverage.xml hash'):
            quality.require_unit_coverage(self.root, SHA)

    def test_other_sha_or_different_sources_are_rejected_even_after_rehash(self) -> None:
        path = self.root / 'profiles/stock/receipt.json'
        original = json.loads(path.read_text())
        for key, value in (('source_sha', 'b' * 40), ('source_files', {'Sources/File.swift': 'd' * 64})):
            with self.subTest(key=key):
                path.write_text(json.dumps({**original, key: value}))
                self.inputs['stock']['receipt_sha256'] = self.digest(path)
                self.seal()
                with self.assertRaisesRegex(ValueError, 'identity differs|different source'):
                    quality.require_unit_coverage(self.root, SHA)

    def test_missing_profile_or_wrong_merged_hash_is_rejected(self) -> None:
        self.union['profile_inputs'] = {'enhanced': self.inputs['enhanced']}
        self.seal()
        with self.assertRaisesRegex(ValueError, 'union provenance'):
            quality.require_unit_coverage(self.root, SHA)
        self.union['profile_inputs'] = self.inputs
        self.union['coverage_sha256'] = '0' * 64
        self.seal()
        with self.assertRaisesRegex(ValueError, 'union provenance'):
            quality.require_unit_coverage(self.root, SHA)


if __name__ == '__main__':
    unittest.main()
