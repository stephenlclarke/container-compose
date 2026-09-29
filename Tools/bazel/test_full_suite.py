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

"""Static original inventory and fail-closed shared-resource regression checks."""

from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import full_suite


class FullSuiteTests(unittest.TestCase):
    @staticmethod
    def parity_function(leaf: str, name: str) -> str:
        source = (full_suite.ROOT / 'Tools/parity' /
                  ('check-compose-' + leaf + '.sh')).read_text()
        start = source.index('\n' + name + '() {') + 1
        end = source.index('\n}\n', start) + 2
        return source[start:end]

    def test_qualified_build_outputs_are_unique_case_owned_and_collision_guarded(self) -> None:
        for leaf, case in (('build-isolation', 'docker-compose-build-isolation-parity'),
                           ('build-secret-metadata',
                            'docker-compose-build-secret-metadata-parity')):
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as temporary:
                prefix = full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES[case]
                tag = prefix + 'a' * 32
                self.assertEqual(full_suite.EXTRA_IMAGE_PREFIXES[case], (prefix,))
                baseline = self.empty()
                baseline['docker']['images']['example/api:isolation|old'] = 'example/api:isolation'
                baseline['docker']['images']['example/api:secretmeta|old'] = 'example/api:secretmeta'
                full_suite.assert_namespace_free(baseline, case, fixed_images=[tag])
                existing = self.empty()
                existing['docker']['images'][tag + '|old'] = tag
                with self.assertRaisesRegex(RuntimeError, 'collides'):
                    full_suite.assert_namespace_free(existing, case, fixed_images=[tag])
                added = self.empty()
                added['docker']['images'].update(baseline['docker']['images'])
                added['docker']['images'][tag + '|new'] = tag
                self.assertEqual(len(full_suite.difference(
                    baseline, added, [], case=case,
                    image_prefixes=list(full_suite.EXTRA_IMAGE_PREFIXES[case]))), 1)
                added['docker']['images']['example/api:unrelated|new'] = 'example/api:unrelated'
                with self.assertRaisesRegex(RuntimeError, 'Unrecognized new docker images'):
                    full_suite.difference(
                        baseline, added, [], case=case,
                        image_prefixes=list(full_suite.EXTRA_IMAGE_PREFIXES[case]))
                refs = Path(temporary) / 'refs'
                refs.write_text('example/api:isolation\nexample/api:secretmeta\n')
                program = '''
set -euo pipefail
error() { printf '%s\\n' "$*" >&2; }
docker() { cat "$REFS"; }
''' + self.parity_function(leaf, 'select_output_image') + '\n' + \
                    self.parity_function(leaf, 'require_output_image_absent') + '''
select_output_image
require_output_image_absent
printf '%s %s\\n' "$OUTPUT_IMAGE" "$OUTPUT_IMAGE_ENROLLED"
'''
                env = dict(os.environ, PARITY_OUTPUT_IMAGE=tag,
                           COMPOSE_FULL_SUITE_QUALIFIED='1', REFS=str(refs),
                           OUTPUT_IMAGE='', OUTPUT_IMAGE_ENROLLED='0')
                result = subprocess.run(['/bin/bash', '-c', program], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), tag + ' 1')
                refs.write_text(tag + '\n')
                result = subprocess.run(['/bin/bash', '-c', program], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('already exists', result.stderr)

    def test_links_and_dns_reuse_preloaded_images_without_pull(self) -> None:
        image = {'configuration': {'name': 'docker.io/library/alpine:3.20',
                                   'descriptor': {'digest': 'sha256:' + 'a' * 64}}}
        for leaf in ('links', 'network-service-discovery'):
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                docker_refs, native_refs, events = (root / name for name in
                                                   ('docker-refs', 'native-refs', 'events'))
                docker_refs.write_text('alpine:3.20\n')
                native_refs.write_text(json.dumps([image]))
                program = '''
set -euo pipefail
REPO_ROOT="$REPOSITORY"
FIXTURE_IMAGE=alpine:3.20
CONTAINER_COMPOSE_LIVE=1
CONTAINER_BINARY=/mock/container
info() { :; }
error() { printf '%s\\n' "$*" >&2; }
run_bounded() {
  printf '%s\\n' "$*" >> "$EVENTS"
  if [[ "$1" == docker && "$2" == image && "$3" == ls ]]; then
    cat "$DOCKER_REFS"
  elif [[ "$1" == "$CONTAINER_BINARY" && "$2" == image && "$3" == list ]]; then
    cat "$NATIVE_REFS"
  fi
}
''' + self.parity_function(leaf, 'prepare_fixture_images') + '''
prepare_fixture_images
'''
                env = dict(os.environ, REPOSITORY=str(full_suite.ROOT),
                           DOCKER_REFS=str(docker_refs), NATIVE_REFS=str(native_refs),
                           EVENTS=str(events), COMPOSE_FULL_SUITE_QUALIFIED='1')
                result = subprocess.run(['/bin/bash', '-c', program], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('pull', events.read_text())
                events.unlink()
                docker_refs.write_text('')
                result = subprocess.run(['/bin/bash', '-c', program], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('qualified Docker fixture image is missing', result.stderr)
                self.assertNotIn('pull', events.read_text())

    def test_standalone_build_leaf_removes_only_new_tag_and_preserves_failure(self) -> None:
        for leaf in ('build-isolation', 'build-secret-metadata'):
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                refs, events = root / 'refs', root / 'events'
                refs.write_text('example/api:isolation\nexample/api:secretmeta\n')
                program = '''
set -euo pipefail
error() { printf '%s\\n' "$*" >&2; }
docker() {
  if [[ "$1" == image && "$2" == ls ]]; then cat "$REFS"; return; fi
  if [[ "$1" == image && "$2" == rm ]]; then
    printf '%s\\n' "$3" >> "$EVENTS"
    grep -Fvx -- "$3" "$REFS" > "$REFS.next" || true
    mv "$REFS.next" "$REFS"
    return
  fi
  return 1
}
''' + self.parity_function(leaf, 'select_output_image') + '\n' + \
                    self.parity_function(leaf, 'require_output_image_absent') + '\n' + \
                    self.parity_function(leaf, 'create_fixture') + '\n' + \
                    self.parity_function(leaf, 'cleanup') + '''
select_output_image
create_fixture
grep -Fx -- "    image: $OUTPUT_IMAGE" "$FIXTURE_DIR/compose.yml" >/dev/null
require_output_image_absent
printf '%s\\n' "$OUTPUT_IMAGE" >> "$REFS"
trap cleanup EXIT
exit 7
'''
                env = dict(os.environ, REFS=str(refs), EVENTS=str(events),
                           TMPDIR=str(root), OUTPUT_IMAGE='', OUTPUT_IMAGE_ENROLLED='0')
                env.pop('PARITY_OUTPUT_IMAGE', None)
                env.pop('COMPOSE_FULL_SUITE_QUALIFIED', None)
                result = subprocess.run(['/bin/bash', '-c', program], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 7, result.stderr)
                removed = events.read_text().splitlines()
                self.assertEqual(len(removed), 1)
                self.assertIn('-local-', removed[0])
                self.assertEqual(refs.read_text().splitlines(),
                                 ['example/api:isolation', 'example/api:secretmeta'])

    @staticmethod
    def commit_function(name: str) -> str:
        source = (full_suite.ROOT / 'Tools/parity/check-compose-commit.sh').read_text()
        start = source.index('\n' + name + '() {') + 1
        end = source.index('\n}\n', start) + 2
        return source[start:end]

    @staticmethod
    def volume_labels_function(name: str) -> str:
        source = (full_suite.ROOT / 'Tools/parity/check-compose-volume-labels.sh').read_text()
        start = source.index('\n' + name + '() {') + 1
        end = source.index('\n}\n', start) + 2
        return source[start:end]

    @staticmethod
    def up_menu_function(name: str) -> str:
        source = (full_suite.ROOT / 'Tools/parity/check-compose-up-menu.sh').read_text()
        start = source.index('\n' + name + '() {') + 1
        end = source.index('\n}\n', start) + 2
        return source[start:end]

    def empty(self):
        return {lane: {kind: {} for kind in ('containers', 'networks', 'volumes', 'images')}
                for lane in ('candidate', 'docker')}

    def test_bridge_ownership_is_exact_candidate_container_and_case_only(self) -> None:
        baseline = self.empty()
        name = 'compose-bridge-012345abcdef'
        for lane in ('candidate', 'docker'):
            for kind in ('containers', 'networks', 'volumes', 'images'):
                current = self.empty()
                current[lane][kind]['owned-id'] = name
                if lane == 'candidate' and kind == 'containers':
                    additions = full_suite.difference(baseline, current, [],
                                                      case='docker-compose-bridge-parity')
                    self.assertEqual(additions[0]['id'], 'owned-id')
                    with self.assertRaisesRegex(RuntimeError, 'collides'):
                        full_suite.assert_namespace_free(current, 'docker-compose-bridge-parity')
                else:
                    with self.assertRaisesRegex(RuntimeError, 'Unrecognized'):
                        full_suite.difference(baseline, current, [],
                                              case='docker-compose-bridge-parity')
        for invalid in (name + '0', name.upper(), 'compose-bridge-user', 'unrelated'):
            current = self.empty()
            current['candidate']['containers']['id'] = invalid
            with self.assertRaisesRegex(RuntimeError, 'Unrecognized'):
                full_suite.difference(baseline, current, [], case='docker-compose-bridge-parity')
        self.assertFalse(full_suite.authorized_bridge(name, 'runtime-suite'))

    def test_all_original_parity_leaves_have_one_script(self) -> None:
        rows = full_suite.inventory()
        self.assertEqual(len(rows), 66)
        self.assertEqual(len({row['script'] for row in rows}), 66)
        self.assertTrue(all(Path(row['script']).is_file() and row['script_sha256']
                            for row in rows))

    def test_shared_resource_requires_per_case_prefix_and_unchanged_baseline(self) -> None:
        baseline = self.empty()
        baseline['docker']['containers']['original-id'] = 'user-service'
        current = self.empty()
        current['docker']['containers'].update(baseline['docker']['containers'])
        current['docker']['containers']['new-id'] = 'cc-rm-123-api-1'
        self.assertEqual(full_suite.difference(baseline, current, ['cc-rm-']), [
            {'lane': 'docker', 'kind': 'containers', 'id': 'new-id', 'name': 'cc-rm-123-api-1'}])
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new'):
            full_suite.difference(baseline, current, ['unrelated-'])
        current['docker']['containers'].pop('original-id')
        with self.assertRaisesRegex(RuntimeError, 'Original docker containers changed'):
            full_suite.difference(baseline, current, ['cc-rm-'])

    def test_journal_is_written_before_case_and_recovery_remains_pending(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ledger = full_suite.Ledger(root)
            baseline = self.empty()
            ledger.begin('docker-compose-rm-parity', 'a' * 64, ['container-compose-rm-'], baseline)
            self.assertEqual(len(full_suite.Ledger(root).pending()), 1)
            changed = self.empty()
            changed['candidate']['volumes']['container-compose-rm-123_data'] = 'container-compose-rm-123_data'
            with self.assertRaisesRegex(RuntimeError, 'left owned resources'):
                ledger.finish('docker-compose-rm-parity', changed)
            self.assertEqual(len(full_suite.Ledger(root).pending()), 1)
            ledger.finish('docker-compose-rm-parity', baseline)
            self.assertFalse(full_suite.Ledger(root).pending())

    def test_inventory_parsers_reject_missing_identity(self) -> None:
        self.assertEqual(full_suite.docker_containers('abc owned-name\n'), {'abc': 'owned-name'})
        self.assertEqual(full_suite.native_containers('[{"id":"one","name":"owned-name"}]'),
                         {'one': 'owned-name'})
        with self.assertRaisesRegex(RuntimeError, 'unique ID/name'):
            full_suite.native_containers('[{"id":"one"}]')
        with self.assertRaisesRegex(RuntimeError, 'unique ID/name'):
            full_suite.docker_containers('abc\n')
        self.assertEqual(full_suite.native_images('[{"configuration":{"name":"alpine:3.20",'
                                                 '"descriptor":{"digest":"sha256:' + 'a' * 64 + '"}}}]'),
                         {'alpine:3.20': 'sha256:' + 'a' * 64})
        with self.assertRaisesRegex(RuntimeError, 'reference/digest'):
            full_suite.native_images('[{"configuration":{"name":"alpine:3.20"}}]')

    def test_docker_image_inventory_collapses_only_identical_rows(self) -> None:
        first = 'sha256:' + '5' * 64
        second = 'sha256:' + '6' * 64
        duplicate = 'isolation-fixture/alpine:3.20 ' + first
        rows = '\n'.join((duplicate, duplicate, 'alpine:3.20 ' + first,
                          '<none>:<none> ' + first, '<none>:<none> ' + second)) + '\n'
        parsed = full_suite.docker_images(rows)
        self.assertEqual(len(parsed), 4)
        self.assertEqual(parsed[duplicate.replace(' ', '|')],
                         'isolation-fixture/alpine:3.20')
        self.assertIn('<none>:<none>|' + first, parsed)
        self.assertIn('<none>:<none>|' + second, parsed)
        variants = full_suite.docker_images(duplicate + '\n' +
                                            'isolation-fixture/alpine:3.20 ' + second + '\n')
        self.assertEqual(len(variants), 2)
        with self.assertRaisesRegex(RuntimeError, 'unique repository/tag and ID'):
            full_suite.docker_images('isolation-fixture/alpine:3.20 5c2987750228\n')

    def test_new_docker_image_variant_cannot_remove_baseline_tag(self) -> None:
        first = 'sha256:' + '5' * 64
        second = 'sha256:' + '6' * 64
        baseline = self.empty()
        baseline['docker']['images']['owned-case:latest|' + first] = 'owned-case:latest'
        current = self.empty()
        current['docker']['images'].update(baseline['docker']['images'])
        current['docker']['images']['owned-case:latest|' + second] = 'owned-case:latest'
        with self.assertRaisesRegex(RuntimeError, 'cannot be safely removed'):
            full_suite.difference(baseline, current, ['owned-case:'])
        current['docker']['images'].pop('owned-case:latest|' + second)
        current['docker']['images']['<none>:<none>|' + second] = '<none>:<none>'
        with self.assertRaisesRegex(RuntimeError, 'cannot be safely removed'):
            full_suite.difference(baseline, current, ['<none>'])

    def test_docker_snapshot_requests_full_image_ids(self) -> None:
        commands = []

        def invoke(lane, kind, command):
            commands.append((lane, kind, command))
            return '[]' if lane == 'candidate' and kind in ('containers', 'images') else ''

        full_suite.snapshot(invoke)
        image_commands = [command for lane, kind, command in commands
                          if lane == 'docker' and kind == 'images']
        self.assertEqual(len(image_commands), 1)
        self.assertIn('--no-trunc', image_commands[0])

    def test_runtime_suite_enrolls_only_its_exact_new_builders(self) -> None:
        baseline = self.empty()
        current = self.empty()
        current['candidate']['containers']['builder-id'] = 'buildkit'
        self.assertEqual(full_suite.difference(baseline, current, ['ccrt-'],
                                               case='runtime-suite')[0]['id'],
                         'builder-id')
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new'):
            full_suite.difference(baseline, current, ['cc-rm-'])
        current['candidate']['containers']['builder-id'] = 'buildkit-unrelated'
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new'):
            full_suite.difference(baseline, current, ['ccrt-'], case='runtime-suite')
        current['candidate']['containers']['builder-id'] = (
            'buildkit-compose-runtime-12345678-1234-1234-1234-123456789abc')
        self.assertEqual(len(full_suite.difference(baseline, current, ['ccrt-'],
                                                   case='runtime-suite')), 1)
        current['candidate']['containers']['builder-id'] = 'buildkit'
        self.assertEqual(len(full_suite.difference(
            baseline, current, ['container-compose-image-volumes-'],
            case='docker-compose-image-volumes-parity')), 1)

    def test_native_image_digest_replacement_refuses_cleanup(self) -> None:
        baseline = self.empty()
        baseline['candidate']['images']['alpine:3.20'] = 'sha256:' + 'a' * 64
        current = self.empty()
        current['candidate']['images']['alpine:3.20'] = 'sha256:' + 'b' * 64
        with self.assertRaisesRegex(RuntimeError, 'Original candidate images changed'):
            full_suite.difference(baseline, current, ['ccrt-'])

    def test_docker_anonymous_volume_requires_exact_mount_enrollment(self) -> None:
        baseline, current = self.empty(), self.empty()
        current['docker']['containers']['owned-id'] = 'cc-rm-42-api-1'
        current['docker']['volumes']['a' * 64] = 'a' * 64
        current['docker']['container_mounts'] = {'owned-id': ['a' * 64]}
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new docker volumes'):
            full_suite.difference(baseline, current, ['cc-rm-'])
        with tempfile.TemporaryDirectory() as temporary:
            ledger = full_suite.Ledger(Path(temporary))
            ledger.begin('docker-compose-rm-parity', 'a' * 64, ['cc-rm-'], baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[current, baseline, baseline]):
                ledger.recover(lambda lane, kind, args: commands.append(args) or '',
                               {'docker-compose-rm-parity': 'a' * 64})
            self.assertIn(['docker', '--context', 'colima', 'volume', 'rm', 'a' * 64], commands)
            self.assertEqual(full_suite.Ledger(Path(temporary)).data['cases'][0][
                'enrolled_volumes'], ['a' * 64])

    def test_image_volume_hook_preserves_mount_identity_after_containers_disappear(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            name = 'docker-compose-image-volumes-parity'
            project = 'container-compose-image-volumes-123-456'
            path = root / 'cases' / name / 'mounts.json'
            path.parent.mkdir(parents=True)
            volumes = ['a' * 64]
            full_suite.write(path, {'schema': 1, 'project': project,
                                    'container_ids': ['owned-id'], 'volumes': volumes})
            baseline, orphaned = self.empty(), self.empty()
            orphaned['docker']['volumes'][volumes[0]] = volumes[0]
            ledger = full_suite.Ledger(root)
            ledger.begin(name, 'a' * 64, [project.removesuffix('123-456')], baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[orphaned, baseline, baseline]):
                ledger.recover(lambda lane, kind, args: commands.append(args) or '',
                               {name: 'a' * 64})
            self.assertIn(['docker', '--context', 'colima', 'volume', 'rm', volumes[0]], commands)

    def test_failed_partial_image_volume_up_can_enroll_before_down(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'mounts.json'
            project = 'container-compose-image-volumes-123-456'
            record = {'Id': 'owned-id', 'Name': '/' + project + '-api-1',
                      'Config': {'Labels': {'com.docker.compose.project': project}},
                      'Mounts': [{'Type': 'volume', 'Name': 'a' * 64}]}
            with patch.object(full_suite.subprocess, 'check_output',
                              side_effect=['owned-id\n', json.dumps([record])]):
                with self.assertRaisesRegex(RuntimeError, 'invalid owned container count'):
                    full_suite.record_image_volume_mounts(project, path)
            self.assertFalse(path.exists())
            with patch.object(full_suite.subprocess, 'check_output',
                              side_effect=['owned-id\n', json.dumps([record])]):
                full_suite.record_image_volume_mounts(project, path, allow_partial=True)
            self.assertEqual(json.loads(path.read_text())['volumes'], ['a' * 64])

    def test_commit_mount_hook_enrolls_exact_single_container(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'mounts.json'
            project = 'container-compose-commit-docker-123-456'
            record = {'Id': 'owned-id', 'Name': '/' + project + '-api-1',
                      'Config': {'Labels': {'com.docker.compose.project': project}},
                      'Mounts': [{'Type': 'volume', 'Name': 'a' * 64},
                                 {'Type': 'volume', 'Name': 'b' * 64}]}
            with patch.object(full_suite.subprocess, 'check_output',
                              side_effect=['owned-id\n', json.dumps([record])]):
                full_suite.record_image_volume_mounts(project, path)
            self.assertEqual(json.loads(path.read_text())['volumes'], ['a' * 64, 'b' * 64])

    def test_commit_partial_up_and_cross_case_journal_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = 'container-compose-commit-docker-123-456'
            path = root / 'cases/docker-compose-commit-parity/mounts.json'
            path.parent.mkdir(parents=True)
            with patch.object(full_suite.subprocess, 'check_output', return_value=''):
                with self.assertRaisesRegex(RuntimeError, 'invalid owned container count'):
                    full_suite.record_image_volume_mounts(project, path)
            with patch.object(full_suite.subprocess, 'check_output', return_value=''):
                full_suite.record_image_volume_mounts(project, path, allow_partial=True)
            self.assertEqual(json.loads(path.read_text())['container_ids'], [])
            baseline, orphaned = self.empty(), self.empty()
            orphaned['docker']['volumes']['a' * 64] = 'a' * 64
            full_suite.write(path, {'schema': 1, 'project': project,
                                    'container_ids': ['owned-id'], 'volumes': ['a' * 64]})
            ledger = full_suite.Ledger(root)
            name = 'docker-compose-commit-parity'
            ledger.begin(name, 'a' * 64, ['container-compose-commit-'], baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[orphaned, baseline, baseline]):
                ledger.recover(lambda lane, kind, args: commands.append(args) or '',
                               {name: 'a' * 64})
            self.assertIn(['docker', '--context', 'colima', 'volume', 'rm', 'a' * 64], commands)
            wrong = json.loads(path.read_text())
            wrong['project'] = 'container-compose-image-volumes-123-456'
            full_suite.write(path, wrong)
            other = full_suite.Ledger(root / 'other')
            (other.directory / 'cases' / name).mkdir(parents=True)
            full_suite.write(other.directory / 'cases' / name / 'mounts.json', wrong)
            other.begin(name, 'a' * 64, ['container-compose-commit-'], baseline)
            with patch.object(full_suite, 'snapshot', return_value=orphaned):
                with self.assertRaisesRegex(RuntimeError, 'mount journal is malformed'):
                    other.recover(lambda lane, kind, args: '', {name: 'a' * 64})

    def test_commit_exit_capture_precedes_both_volume_downs_and_retains_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'fixture'
            fixture.mkdir()
            (fixture / 'compose.yml').write_text('services: {}\n')
            journal = root / 'mounts.json'
            events = root / 'events'
            program = '''
set -euo pipefail
REPO_ROOT=/unused
DOCKER_PROJECT_NAME=container-compose-commit-docker-123-456
CONTAINER_PROJECT_NAME=container-compose-commit-runtime-123-456
DOCKER_BASE_IMAGE=example/docker-base:latest
CONTAINER_BASE_IMAGE=example/runtime-base:latest
DOCKER_IMAGE=example/docker:latest
CONTAINER_IMAGE=example/runtime:latest
CONTAINER_BINARY=container
CONTAINER_COMPOSE=compose
CLEANUP_TIMEOUT_SECONDS=30
DOCKER_COMPOSE_COMMAND=(docker compose)
run_bounded_for() { printf 'command %s\\n' "$*" >> "$EVENTS"; }
python3() {
  printf 'journal %s\\n' "$*" >> "$EVENTS"
  if [[ "$JOURNAL_FAILURE" == 1 ]]; then return 1; fi
  : > "$COMPOSE_FULL_SUITE_MOUNT_JOURNAL"
}
error() { :; }
''' + self.commit_function('cleanup') + '''
trap cleanup EXIT
exit "$INITIAL_STATUS"
'''
            environment = dict(os.environ, FIXTURE_DIR=str(fixture), EVENTS=str(events),
                               COMPOSE_FULL_SUITE_MOUNT_JOURNAL=str(journal),
                               JOURNAL_FAILURE='0', INITIAL_STATUS='7')
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            lines = events.read_text().splitlines()
            self.assertIn('record-mounts --allow-partial', lines[0])
            downs = [line for line in lines if ' down --volumes --remove-orphans' in line]
            self.assertEqual(len(downs), 2)
            self.assertFalse(fixture.exists())

    def test_commit_exit_capture_failure_preserves_mounting_container_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'fixture'
            fixture.mkdir()
            (fixture / 'compose.yml').write_text('services: {}\n')
            journal = root / 'mounts.json'
            events = root / 'events'
            program = '''
set -euo pipefail
REPO_ROOT=/unused
DOCKER_PROJECT_NAME=container-compose-commit-docker-123-456
CONTAINER_PROJECT_NAME=container-compose-commit-runtime-123-456
DOCKER_BASE_IMAGE=example/docker-base:latest
CONTAINER_BASE_IMAGE=example/runtime-base:latest
DOCKER_IMAGE=example/docker:latest
CONTAINER_IMAGE=example/runtime:latest
CONTAINER_BINARY=container
CONTAINER_COMPOSE=compose
CLEANUP_TIMEOUT_SECONDS=30
DOCKER_COMPOSE_COMMAND=(docker compose)
run_bounded_for() { printf 'command %s\\n' "$*" >> "$EVENTS"; }
python3() { printf 'journal %s\\n' "$*" >> "$EVENTS"; return 1; }
error() { :; }
''' + self.commit_function('cleanup') + '''
trap cleanup EXIT
exit 0
'''
            environment = dict(os.environ, FIXTURE_DIR=str(fixture), EVENTS=str(events),
                               COMPOSE_FULL_SUITE_MOUNT_JOURNAL=str(journal))
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(len(events.read_text().splitlines()), 1)
            self.assertTrue(fixture.is_dir())
            self.assertFalse(journal.exists())

    def test_commit_records_mounts_after_up_before_committing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'fixture'
            fixture.mkdir()
            journal = root / 'mounts.json'
            events = root / 'events'
            program = '''
set -euo pipefail
REPO_ROOT=/unused
DOCKER_PROJECT_NAME=container-compose-commit-docker-123-456
DOCKER_BASE_IMAGE=example/docker-base:latest
DOCKER_IMAGE=example/docker:latest
DOCKER_COMPOSE_COMMAND=(docker compose)
run_bounded() { printf 'command %s\\n' "$*" >> "$EVENTS"; }
python3() { printf 'journal %s\\n' "$*" >> "$EVENTS"; : > "$COMPOSE_FULL_SUITE_MOUNT_JOURNAL"; }
''' + self.commit_function('commit_with_docker_compose') + '''
commit_with_docker_compose
'''
            environment = dict(os.environ, FIXTURE_DIR=str(fixture), EVENTS=str(events),
                               COMPOSE_FULL_SUITE_MOUNT_JOURNAL=str(journal))
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = events.read_text().splitlines()
            self.assertIn(' up -d --quiet-pull api', lines[0])
            self.assertIn('record-mounts --project ', lines[1])
            self.assertIn(' commit --pause=false ', lines[2])

    def test_volume_labels_enrolls_four_containers_and_orphaned_mount(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'cases/docker-compose-volume-labels-parity/mounts.json'
            path.parent.mkdir(parents=True)
            project = 'cc-volume-labels-123'
            ids = [f'owned-{index}' for index in range(4)]
            rows = [{'Id': identity, 'Name': '/' + project + '-' + str(index),
                     'Config': {'Labels': {'com.docker.compose.project': project}},
                     'Mounts': [{'Type': 'volume', 'Name': 'a' * 64}]}
                    for index, identity in enumerate(ids)]
            with patch.object(full_suite.subprocess, 'check_output',
                              side_effect=['\n'.join(ids) + '\n', json.dumps(rows)]):
                full_suite.record_image_volume_mounts(project, path)
            self.assertEqual(json.loads(path.read_text())['volumes'], ['a' * 64])
            baseline, orphaned = self.empty(), self.empty()
            orphaned['docker']['volumes']['a' * 64] = 'a' * 64
            ledger = full_suite.Ledger(root)
            name = 'docker-compose-volume-labels-parity'
            ledger.begin(name, 'a' * 64, ['cc-volume-labels-'], baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[orphaned, baseline, baseline]):
                ledger.recover(lambda lane, kind, args: commands.append(args) or '',
                               {name: 'a' * 64})
            self.assertIn(['docker', '--context', 'colima', 'volume', 'rm', 'a' * 64], commands)

    def test_volume_labels_exit_mount_capture_before_exact_removal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'fixture'
            fixture.mkdir()
            journal = root / 'mounts.json'
            events = root / 'events'
            program = '''
set -euo pipefail
REPO_ROOT=/unused
PROJECT_NAME=cc-volume-labels-123
ONE_OFF_NAME=cc-volume-labels-123-oneoff
DOCKER_COMPOSE_COMMAND=(docker compose)
docker() { printf 'docker %s\\n' "$*" >> "$EVENTS"; }
python3() {
  printf 'journal %s\\n' "$*" >> "$EVENTS"
  if [[ "$JOURNAL_FAILURE" == 1 ]]; then return 1; fi
  : > "$COMPOSE_FULL_SUITE_MOUNT_JOURNAL"
}
error() { :; }
''' + self.volume_labels_function('cleanup') + '''
trap cleanup EXIT
exit "$INITIAL_STATUS"
'''
            environment = dict(os.environ, FIXTURE_DIR=str(fixture), EVENTS=str(events),
                               COMPOSE_FULL_SUITE_MOUNT_JOURNAL=str(journal),
                               JOURNAL_FAILURE='0', INITIAL_STATUS='7')
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            lines = events.read_text().splitlines()
            self.assertIn('record-mounts --allow-partial', lines[0])
            self.assertEqual(lines[1], 'docker rm --force --volumes cc-volume-labels-123-oneoff')
            self.assertIn('down -v --remove-orphans', lines[2])
            self.assertFalse(fixture.exists())
            journal.unlink()
            fixture.mkdir()
            events.unlink()
            environment['JOURNAL_FAILURE'] = '1'
            environment['INITIAL_STATUS'] = '0'
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(len(events.read_text().splitlines()), 1)
            self.assertTrue(fixture.is_dir())

    def test_up_menu_normalizes_only_successful_candidate_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected = "/tmp/private path's/bin/container"
            emitted = '+ ' + __import__('shlex').quote(selected) + ' create --name demo-api-1'
            program = '''
set -euo pipefail
REPO_ROOT="$REPOSITORY"
FIXTURE_DIR="$FIXTURE"
error() { :; }
reference() { printf '+ docker compose up\\n'; }
candidate() { printf '%s\\n' "$EMITTED"; }
''' + self.up_menu_function('expect_status') + '''
expect_status 'Docker Compose accepts dry-run' 0 reference
printf 'reference=%s\\n' "$LAST_STDOUT_FILE"
expect_status 'container-compose accepts dry-run' 0 candidate
printf 'candidate=%s\\n' "$LAST_STDOUT_FILE"
'''
            environment = dict(os.environ, REPOSITORY=str(full_suite.ROOT),
                               FIXTURE=str(root), CONTAINER_BIN=selected,
                               EMITTED=emitted)
            result = subprocess.run(['/bin/bash', '-c', program], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = dict(line.split('=', 1) for line in result.stdout.splitlines())
            reference = Path(rows['reference'])
            candidate = Path(rows['candidate'])
            self.assertEqual(reference.read_text(), '+ docker compose up\n')
            self.assertTrue(candidate.name.endswith('.assertions'))
            self.assertIn('+ container create --name demo-api-1', candidate.read_text())
            self.assertIn(emitted, candidate.with_suffix('').read_text())


    def test_interrupted_case_removes_only_enrolled_delta(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = self.empty()
            baseline['docker']['containers']['user-id'] = 'user-service'
            added = self.empty()
            added['docker']['containers'].update(baseline['docker']['containers'])
            added['docker']['containers']['new-id'] = 'container-compose-rm-42-api-1'
            ledger = full_suite.Ledger(root)
            ledger.begin('docker-compose-rm-parity', 'a' * 64,
                         ['container-compose-rm-'], baseline)
            commands = []
            def invoke(_lane, _kind, command):
                commands.append(command)
                return ''
            with patch.object(full_suite, 'snapshot', side_effect=[added, baseline, baseline]):
                removed = ledger.recover(invoke, {'docker-compose-rm-parity': 'a' * 64})
            self.assertEqual(removed[0]['id'], 'new-id')
            self.assertEqual(commands, [['docker', '--context', 'colima', 'rm', '--force', 'new-id']])
            self.assertFalse(full_suite.Ledger(root).pending())

    def test_unknown_delta_is_quarantined_without_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline, added = self.empty(), self.empty()
            added['docker']['containers']['unrelated-id'] = 'user-other-service'
            ledger = full_suite.Ledger(root)
            ledger.begin('docker-compose-rm-parity', 'a' * 64,
                         ['container-compose-rm-'], baseline)
            with patch.object(full_suite, 'snapshot', return_value=added):
                with self.assertRaisesRegex(RuntimeError, 'Unrecognized new'):
                    ledger.recover(lambda *_: self.fail('must not delete unrelated workload'),
                                   {'docker-compose-rm-parity': 'a' * 64})
            self.assertEqual(len(full_suite.Ledger(root).pending()), 1)

    def test_new_docker_tag_sharing_baseline_id_removes_only_tag(self) -> None:
        baseline = self.empty()
        baseline['docker']['images']['user:tag|same-id'] = 'user:tag'
        current = self.empty()
        current['docker']['images'].update(baseline['docker']['images'])
        current['docker']['images']['container-compose-rm-42:latest|same-id'] = 'container-compose-rm-42:latest'
        resource, = full_suite.difference(baseline, current, ['container-compose-rm-'])
        self.assertEqual(full_suite.removal(resource),
                         ['docker', '--context', 'colima', 'image', 'rm', '--force',
                          'container-compose-rm-42:latest'])

    def test_multiplatform_owned_tag_is_removed_once_and_all_ids_verified(self) -> None:
        name = 'docker-compose-rm-parity'
        source = 'a' * 64
        tag = 'container-compose-rm-42:latest'
        baseline = self.empty()
        baseline['docker']['images']['user:baseline|same-id'] = 'user:baseline'
        added = self.empty()
        added['docker']['images'].update(baseline['docker']['images'])
        added['docker']['images'][tag + '|same-id'] = tag
        added['docker']['images'][tag + '|other-id'] = tag
        remove_tag = ['docker', '--context', 'colima', 'image', 'rm', '--force', tag]

        with tempfile.TemporaryDirectory() as temporary:
            ledger = full_suite.Ledger(Path(temporary))
            ledger.begin(name, source, ['container-compose-rm-'], baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[added, baseline, baseline]):
                removed = ledger.recover(
                    lambda lane, kind, command: commands.append(command) or '',
                    {name: source})
            self.assertEqual(commands, [remove_tag])
            self.assertEqual({row['id'] for row in removed},
                             {tag + '|same-id', tag + '|other-id'})
            self.assertFalse(full_suite.Ledger(Path(temporary)).pending())

        with tempfile.TemporaryDirectory() as temporary:
            ledger = full_suite.Ledger(Path(temporary))
            ledger.begin(name, source, ['container-compose-rm-'], baseline)
            ledger.finish(name, baseline)
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[added, baseline]):
                removed = ledger.recover(
                    lambda lane, kind, command: commands.append(command) or '',
                    {name: source})
            self.assertEqual(commands, [remove_tag])
            self.assertEqual(len(removed), 2)

        with tempfile.TemporaryDirectory() as temporary:
            ledger = full_suite.Ledger(Path(temporary))
            ledger.begin(name, source, ['container-compose-rm-'], baseline)
            one_variant_left = self.empty()
            one_variant_left['docker']['images'].update(baseline['docker']['images'])
            one_variant_left['docker']['images'][tag + '|other-id'] = tag
            commands = []
            with patch.object(full_suite, 'snapshot',
                              side_effect=[added, one_variant_left]):
                with self.assertRaisesRegex(RuntimeError, 'left owned resources'):
                    ledger.recover(lambda lane, kind, command:
                                   commands.append(command) or '', {name: source})
            self.assertEqual(commands, [remove_tag])
            self.assertEqual(len(full_suite.Ledger(Path(temporary)).pending()), 1)

        with tempfile.TemporaryDirectory() as temporary:
            ledger = full_suite.Ledger(Path(temporary))
            ledger.begin(name, source, ['container-compose-rm-'], baseline)
            missing_alias = self.empty()
            commands = []
            with patch.object(full_suite, 'snapshot', side_effect=[added, missing_alias]):
                with self.assertRaisesRegex(RuntimeError, 'Original docker images changed'):
                    ledger.recover(lambda lane, kind, command:
                                   commands.append(command) or '', {name: source})
            self.assertEqual(commands, [remove_tag])

    def test_commit_source_declared_image_prefix_is_image_only(self) -> None:
        baseline, current = self.empty(), self.empty()
        image = 'example/commit-parity-docker-42:latest'
        current['docker']['images'][image + '|digest'] = image
        prefixes = ['container-compose-commit-docker-']
        images = ['example/commit-parity-docker-']
        self.assertEqual(len(full_suite.difference(baseline, current, prefixes,
                                                   image_prefixes=images)), 1)
        current['docker']['containers']['unrelated'] = image
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new docker containers'):
            full_suite.difference(baseline, current, prefixes, image_prefixes=images)

    def test_existing_fixed_image_or_project_namespace_blocks_leaf_before_mutation(self) -> None:
        baseline = self.empty()
        baseline['candidate']['images'][
            'docker.io/library/container-compose-external-dockerfile:latest'] = 'sha256:' + 'a' * 64
        with self.assertRaisesRegex(RuntimeError, 'collides'):
            full_suite.assert_namespace_free(
                baseline, 'docker-compose-build-external-dockerfile-parity',
                fixed_images=['container-compose-external-dockerfile:latest'])
        baseline['candidate']['images'].clear()
        baseline['docker']['containers']['old-id'] = 'cc-fixed-123-api-1'
        with self.assertRaisesRegex(RuntimeError, 'collides'):
            full_suite.assert_namespace_free(
                baseline, 'docker-compose-build-external-dockerfile-parity',
                fixed_names=['cc-fixed'],
                fixed_images=['container-compose-external-dockerfile:latest'])
        baseline['docker']['containers'].clear()
        baseline['docker']['images']['alpine:3.20|original'] = 'alpine:3.20'
        full_suite.assert_namespace_free(
            baseline, 'docker-compose-build-external-dockerfile-parity',
            fixed_images=['container-compose-external-dockerfile:latest'])
        baseline['docker']['images']['old-project-built:latest|old'] = 'old-project-built:latest'
        full_suite.assert_namespace_free(
            baseline, 'docker-compose-build-external-dockerfile-parity',
            fixed_images=['container-compose-external-dockerfile:latest'])

    def test_source_declared_built_images_are_admitted_in_both_lanes(self) -> None:
        baseline, current = self.empty(), self.empty()
        current['candidate']['images'][
            'docker.io/library/container-compose-create-runtime-42-built:latest'] = 'sha256:' + 'a' * 64
        current['docker']['images'][
            'container-compose-create-docker-42-built:latest|image-id'] = (
                'container-compose-create-docker-42-built:latest')
        self.assertEqual(len(full_suite.difference(
            baseline, current, ['container-compose-create-'],
            case='docker-compose-create-options-parity')), 2)

    def test_interrupted_runtime_suite_admits_only_its_four_named_image_families(self) -> None:
        baseline, current = self.empty(), self.empty()
        names = ('container-compose-named-builder:1234',
                 'registry.local/compose-ssh:1234',
                 'registry.local/compose-ssh-named:1234',
                 'registry.local/compose-ssh-multiple:1234')
        for index, name in enumerate(names):
            current['candidate']['images'][name] = 'sha256:' + str(index) * 64
        declared = list(full_suite.EXTRA_IMAGE_PREFIXES['runtime-suite'])
        self.assertEqual(len(full_suite.difference(
            baseline, current, ['ccrt-'], case='runtime-suite',
            image_prefixes=declared)), 4)
        current['candidate']['images']['unrelated:image'] = 'sha256:' + 'f' * 64
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized new candidate images'):
            full_suite.difference(baseline, current, ['ccrt-'], case='runtime-suite',
                                  image_prefixes=declared)

    def test_failed_cp_timing_retains_partial_samples_without_replacing_report(self) -> None:
        script = full_suite.ROOT / 'Tools/parity/check-compose-cp-stdio-archive-streams.sh'
        text = script.read_text()
        helper = text.split('retain_partial_timings() {', 1)[1].split('\n}', 1)[0]
        command = 'retain_partial_timings() {' + helper + '\n}\nretain_partial_timings'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw, retained = root / 'raw.tsv', root / 'evidence/timing.tsv'
            raw.write_text('docker\tcopy\t0.100\n')
            env = dict(os.environ, TIMING_FILE=str(raw), PARITY_TIMING_OUTPUT=str(retained))
            self.assertEqual(subprocess.run(['/bin/bash', '-c', command], env=env,
                                            timeout=5).returncode, 0)
            self.assertEqual(retained.read_bytes(), raw.read_bytes())
            retained.write_text('different prior data')
            self.assertNotEqual(subprocess.run(['/bin/bash', '-c', command], env=env,
                                               timeout=5).returncode, 0)
            self.assertEqual(retained.read_text(), 'different prior data')


if __name__ == '__main__':
    unittest.main()
