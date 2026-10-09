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

"""Run the original parity filters against already-built native test binaries."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess


RM_FILTER = ('rmSkipsRunningContainersUnlessStopIsRequested|'
             'rmIgnoresContainersThatDisappearDuringRemoval|'
             'rmSupportsForceAndAnonymousVolumeRemoval|'
             'rmConfirmsBeforeStoppingContainers|'
             'rmStopSkipsStopForAlreadyStoppedContainers')
LIFECYCLE_FILTER = ('ComposeOrchestratorTests/(preStart|upCreatesEveryReplicaBeforeOnePreStart|'
                    'runForeground|runReattachesInteractive|interactiveRunDetachKeys|runInterruption)')
SIGNAL_FILTER = ('(ComposeBuildInfoTests/|'
                 'ComposeOrchestratorTests/(attachInteractiveMode|attachOutputOnlyMode|logsPasses|'
                 'logsAcceptsComposeAllTailValue|logManagerNormalizesUnreadableDriverErrorsForCompose|'
                 'logManagerNormalizesPublicUnreadableDriverCategory|'
                 'logsTreatsUnreadableDriverHistoryAsEmptyStream|'
                 'logsContinuesReadableServicesAfterUnreadableDriverHistory|'
                 'logsPreservesUnreadableDriverErrorsForFollowRequests))')
ROUTES = {RM_FILTER: ('core',), LIFECYCLE_FILTER: ('core',),
          SIGNAL_FILTER: ('core', 'plugin')}
PASS = re.compile(r'(?:Test run with|Executed) (\d+) tests? .*passed', re.IGNORECASE)


def test_workspace(runfiles: Path, binary_name: str, fixture: str | None = None) -> str:
    """Resolve the workspace actually materialized beside a native Bazel test."""
    matches = [entry for entry in runfiles.iterdir()
               if entry.is_dir() and (entry / (binary_name + '.xctest')).is_dir()]
    if len(matches) != 1:
        raise ValueError('Native test runfiles do not identify one workspace: ' + binary_name)
    workspace = matches[0]
    if fixture is not None and not (workspace / fixture / 'Contents/Resources/Fixtures').is_dir():
        raise ValueError('Native test fixture bundle is missing: ' + fixture)
    return workspace.name


def run_filter(pattern: str, environment: dict[str, str]) -> dict[str, int]:
    """Never accept an unknown or zero-match filter as successful proof."""
    if pattern not in ROUTES:
        raise ValueError('Parity unit filter is not one of the original maintained selections')
    counts = {}
    for profile in ROUTES[pattern]:
        key = 'COMPOSE_PREBUILT_' + profile.upper() + '_TEST'
        binary = Path(environment[key])
        if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError('Missing executable prebuilt ' + profile + ' test')
        runfiles = binary.with_name(binary.name + '.runfiles')
        if not runfiles.is_dir():
            raise ValueError('Missing prebuilt ' + profile + ' test runfiles')
        test_env = dict(environment, TESTBRIDGE_TEST_ONLY=pattern,
                        TEST_SRCDIR=str(runfiles),
                        TEST_WORKSPACE=test_workspace(runfiles, binary.name))
        completed = subprocess.run([str(binary)], env=test_env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=300, check=False)
        print(completed.stdout, end='', flush=True)
        if completed.returncode:
            raise RuntimeError(profile + ' parity unit tests failed: ' + str(completed.returncode))
        matches = PASS.findall(completed.stdout)
        if not matches or int(matches[-1]) <= 0:
            raise RuntimeError(profile + ' parity unit filter matched no passing tests')
        counts[profile] = int(matches[-1])
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', required=True)
    args = parser.parse_args()
    print(run_filter(args.filter, dict(os.environ)), flush=True)


if __name__ == '__main__':
    main()
