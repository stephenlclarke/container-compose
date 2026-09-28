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
    def empty(self):
        return {lane: {kind: {} for kind in ('containers', 'networks', 'volumes', 'images')}
                for lane in ('candidate', 'docker')}

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
