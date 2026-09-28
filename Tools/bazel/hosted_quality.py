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

"""Admit one exact-source, successful hosted Compose quality attempt and artifacts."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REPOSITORY = 'stephenlclarke/container-compose'
JOBS = ('Validate Runtime', 'CodeQL Swift (enhanced)', 'CodeQL Swift (stock)',
        'CodeQL Swift Source Inventory', 'CodeQL Go (linux)', 'CodeQL Go (darwin)',
        'CodeQL Go Source Inventory', 'Validate')
ARTIFACTS = {
    'sonar-pr-gate': 'sonar-pr-gate.json',
    'swift-codeql-extraction-enhanced': 'swift-extraction-enhanced.json',
    'swift-codeql-extraction-stock': 'swift-extraction-stock.json',
    'go-codeql-extraction-linux': 'go-extraction-linux.json',
    'go-codeql-extraction-darwin': 'go-extraction-darwin.json',
    'unit-coverage': 'receipt.json',
}


def gh_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items()
            if key not in {'GH_TOKEN', 'GITHUB_TOKEN'}}


def api(path: str) -> dict:
    data = subprocess.check_output(['gh', 'api', '--hostname', 'github.com',
                                    f'repos/{REPOSITORY}/{path}'], env=gh_environment(), timeout=30)
    return json.loads(data)


def current_context(sha: str) -> dict:
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Expected exact 40-character source SHA')
    branches = api(f'pulls?state=open&per_page=100')
    matches = [pr for pr in branches if pr.get('head', {}).get('sha') == sha
               and pr.get('head', {}).get('repo', {}).get('full_name') == REPOSITORY
               and pr.get('base', {}).get('ref') == 'main']
    if len(matches) != 1:
        raise ValueError('Exact SHA must be the current same-repository PR head targeting main')
    pr = matches[0]
    return {'number': pr['number'], 'head': sha, 'branch': pr['head']['ref'],
            'base': pr['base']['ref'], 'base_sha': pr['base']['sha']}


def newest_run(runs: list[dict], context: dict) -> dict:
    matches = [run for run in runs if run.get('head_sha') == context['head']
               and run.get('head_branch') == context['branch']
               and run.get('event') == 'pull_request'
               and run.get('repository', {}).get('full_name') == REPOSITORY
               and run.get('head_repository', {}).get('full_name') == REPOSITORY
               and any(pr.get('number') == context['number']
                       and pr.get('head', {}).get('sha') == context['head']
                       and pr.get('base', {}).get('sha') == context['base_sha']
                       and pr.get('base', {}).get('ref') == context['base']
                       for pr in run.get('pull_requests', []))]
    if not matches:
        raise ValueError('No matching hosted CI run for exact PR head and base')
    return max(matches, key=lambda run: (datetime.fromisoformat(run['run_started_at']),
                                         run['id'], run['run_attempt']))


def require_jobs(jobs: list[dict], sha: str) -> dict:
    admitted = {}
    for name in JOBS:
        matches = [job for job in jobs if job.get('name') == name]
        if name == 'Validate':
            successes = [job for job in matches if job.get('conclusion') == 'success']
            skipped = [job for job in matches if job.get('conclusion') == 'skipped']
            if (len(matches) != 2 or len(successes) != 1 or len(skipped) != 1
                    or any(job.get('head_sha') != sha or job.get('status') != 'completed' for job in matches)):
                raise ValueError('Hosted Validate requires one successful full aggregate and one skipped lightweight aggregate')
            selected = successes[0]
            if not any(step.get('name') == 'Check parallel validation jobs'
                       and step.get('conclusion') == 'success' for step in selected.get('steps', [])):
                raise ValueError('Successful Validate is not the full quality aggregate')
        elif len(matches) == 1 and matches[0].get('head_sha') == sha and matches[0].get('status') == 'completed' and matches[0].get('conclusion') == 'success':
            selected = matches[0]
        else:
            raise ValueError(f'Hosted {name} must complete successfully without skipping')
        admitted[name] = {key: selected[key] for key in ('id', 'name', 'head_sha', 'conclusion', 'html_url')}
    return admitted


def require_artifacts(artifacts: list[dict], sha: str) -> dict:
    selected = {}
    for prefix in ARTIFACTS:
        name = prefix + '-' + sha
        matches = [artifact for artifact in artifacts if artifact.get('name') == name and not artifact.get('expired')]
        if len(matches) != 1:
            raise ValueError(f'Missing or duplicated hosted artifact: {name}')
        selected[prefix] = {'id': matches[0]['id'], 'name': name,
                            'digest': matches[0].get('digest'), 'size': matches[0].get('size_in_bytes')}
    return selected


def download(run_id: int, name: str, directory: Path) -> None:
    subprocess.run(['gh', 'run', 'download', str(run_id), '--repo', REPOSITORY,
                    '--name', name, '--dir', str(directory)], env=gh_environment(),
                   stdin=subprocess.DEVNULL, timeout=120, check=True)


def admit(sha: str, evidence: Path) -> dict:
    evidence.mkdir(parents=True, exist_ok=False)
    result: dict = {'schema': 1, 'source': sha, 'passed': False}
    try:
        context = current_context(sha)
        result['context'] = context
        runs = api(f'actions/workflows/ci.yml/runs?head_sha={sha}&per_page=100')['workflow_runs']
        selected = newest_run(runs, context)
        result['run'] = {key: selected[key] for key in
                         ('id', 'run_attempt', 'run_started_at', 'head_sha', 'status', 'conclusion', 'html_url')}
        if selected['status'] != 'completed' or selected['conclusion'] != 'success':
            raise ValueError('Newest exact-source hosted attempt is not successful')
        jobs = api(f'actions/runs/{selected["id"]}/attempts/{selected["run_attempt"]}/jobs?per_page=100')['jobs']
        result['jobs'] = require_jobs(jobs, sha)
        artifacts = api(f'actions/runs/{selected["id"]}/artifacts?per_page=100')['artifacts']
        result['artifacts'] = require_artifacts(artifacts, sha)
        result['downloaded_sha256'] = {}
        for prefix, metadata in result['artifacts'].items():
            directory = evidence / prefix
            directory.mkdir()
            download(selected['id'], metadata['name'], directory)
            report = directory / ARTIFACTS[prefix]
            if not report.is_file():
                raise ValueError(f'Hosted artifact lacks {ARTIFACTS[prefix]}')
            if prefix == 'sonar-pr-gate':
                value = json.loads(report.read_text())
                if (value.get('source_sha') != sha or value.get('pull_request') != context['number']
                        or value.get('quality_gate') != 'OK' or not value.get('analysis_id')
                        or not value.get('ce_task_id') or value.get('unresolved_pr_issues') != 0
                        or value.get('unreviewed_project_hotspots') != 0
                        or value.get('unreviewed_pr_hotspots') != 0):
                    raise ValueError('Sonar gate does not attest this exact PR and SHA')
            elif prefix.startswith('swift-codeql-extraction-') or prefix.startswith('go-codeql-extraction-'):
                value = json.loads(report.read_text())
                if (value.get('complete') is not True or value.get('clean') is not True
                        or value.get('inventory_count', 0) <= 0
                        or value.get('inventory_extracted_count') != value.get('inventory_count')
                        or value.get('alert_count') != 0
                        or value.get('extraction_error_diagnostic_count') != 0):
                    raise ValueError(f'Incomplete {prefix} extraction evidence')
                language, profile = ('swift', prefix.removeprefix('swift-codeql-extraction-')) if prefix.startswith('swift') else ('go', prefix.removeprefix('go-codeql-extraction-'))
                for name, expected in ((f'{language}-{profile}.sarif', value.get('sarif_sha256')),
                                       (f'{language}-source-inventory' + (f'-{profile}' if language == 'go' else '') + '.txt', value.get('inventory_sha256'))):
                    file = directory / name
                    if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                        raise ValueError(f'Hosted {prefix} raw {name} hash mismatch')
                if language == 'go':
                    scope = json.loads((directory / f'go-scope-{profile}.json').read_text())
                    if scope.get('selected_tracked_count') != value['inventory_count']:
                        raise ValueError(f'Hosted {prefix} Go scope differs from extraction inventory')
            elif prefix == 'unit-coverage':
                value = json.loads((directory / 'receipt.json').read_text())
                if (value.get('source_sha') != sha or value.get('profile') != 'enhanced'
                        or value.get('gate') != 'PASS' or value.get('authority') != 'make coverage-check'):
                    raise ValueError('Unit coverage receipt does not bind the exact candidate')
                for name in ('coverage.xml', 'coverage.out'):
                    path = directory / name
                    if (not path.is_file() or not path.stat().st_size
                            or hashlib.sha256(path.read_bytes()).hexdigest() != value.get('sha256', {}).get(name)):
                        raise ValueError(f'Unit coverage {name} hash mismatch')
            result['downloaded_sha256'][prefix] = {
                str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(directory.rglob('*')) if path.is_file()
            }
        if current_context(sha) != context:
            raise ValueError('PR head/base changed during quality admission')
        latest = newest_run(api(f'actions/workflows/ci.yml/runs?head_sha={sha}&per_page=100')['workflow_runs'], context)
        if any(latest.get(key) != selected.get(key) for key in ('id', 'run_attempt', 'status', 'conclusion', 'head_sha')):
            raise ValueError('Newer or changed hosted CI attempt appeared during artifact admission')
        result['passed'] = True
        return result
    finally:
        (evidence / 'quality.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    admit(args.source, args.evidence)


if __name__ == '__main__':
    main()
