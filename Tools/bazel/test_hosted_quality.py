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


class HostedQualityTests(unittest.TestCase):
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
            if 'runs?' in path:
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
             patch.object(quality, 'require_artifacts', return_value={
                 'sonar-pr-gate': {'id': 1, 'name': 'sonar-pr-gate-'+SHA}}), \
             patch.object(quality, 'download', side_effect=download):
            with self.assertRaisesRegex(ValueError, 'Newer or changed'):
                quality.admit(SHA, Path(temporary) / 'quality')


if __name__ == '__main__':
    unittest.main()
