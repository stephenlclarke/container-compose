#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Offline admission and graph-composition tests for stock Engine test support."""
from __future__ import annotations

import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import test_support as support


def package():
    return {'swift': {'Existing.rspm.__impl': {'archive': 'binary/existing.a'}},
            'cc': {'ExistingC': 'binary/existing-c.a'}, 'headers': ['HeaderOnly'],
            'headerSources': {'ExistingC': []},
            'files': {'binary/existing.a': b'existing'}}


def graph_row(target, kind='swift_library', checksum='a' * 64, srcs=None):
    return {'repository': 'swiftpkg_example', 'target': target, 'kind': kind,
            'configuration': {'checksum': checksum},
            'attributes': {'srcs': {'stringListValue': srcs or []}}}


class TestSupportAdmissionTests(unittest.TestCase):
    def test_archive_rejects_traversal_duplicate_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'input.tar.gz'
            for names, link in [(('../escape',), False), (('same', 'same'), False), (('link',), True)]:
                with self.subTest(names=names, link=link):
                    with tarfile.open(path, 'w:gz') as archive:
                        for name in names:
                            info = tarfile.TarInfo(name)
                            if link:
                                info.type, info.linkname = tarfile.SYMTYPE, '/etc/passwd'
                                archive.addfile(info)
                            else:
                                info.size = 1
                                archive.addfile(info, io.BytesIO(b'x'))
                    with self.assertRaises(ValueError):
                        support.read_members(path)

    def test_derives_transitive_missing_targets_including_c(self):
        graph = {str(i): row for i, row in enumerate([
            graph_row('Existing.rspm.__impl'), graph_row('Server.rspm.__impl'),
            graph_row('WebSocket.rspm.__impl'), graph_row('SHA1.rspm_c', 'cc_library', srcs=['sha1.c']),
            graph_row('HeaderOnly', 'cc_library'), graph_row('HeaderNew', 'cc_library', srcs=['new.h'])])}
        missing = support.missing_targets(graph, {'swiftpkg_example': package()})
        self.assertEqual(missing, {'swiftpkg_example': {
            'swift': {'Server.rspm.__impl', 'WebSocket.rspm.__impl'}, 'cc': {'SHA1.rspm_c'}}})
        graph['unknown'] = dict(graph_row('Other'), repository='swiftpkg_unadmitted')
        with self.assertRaisesRegex(ValueError, 'authenticated'):
            support.missing_targets(graph, {'swiftpkg_example': package()})

    def test_refuses_binary_target_and_header_overwrites(self):
        for swift, cc, files in [({'Existing.rspm.__impl': {}}, {}, {}),
                                 ({}, {'ExistingC': 'x'}, {}), ({}, {'HeaderOnly': 'x'}, {}),
                                 ({}, {}, {'binary/existing.a': b'new'})]:
            with self.subTest(swift=swift, cc=cc, files=files):
                with self.assertRaisesRegex(ValueError, 'overwrite'):
                    support.merge_delta(package(), swift, cc, files)
        merged = support.merge_delta(package(), {'New': {}}, {}, {'binary/new.a': b'new'})
        self.assertEqual(merged['files']['binary/existing.a'], b'existing')

    def test_preserves_wrappers_and_consumer_never_loads_source_rules(self):
        original = ('load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")\n'
                    'load(":minimum_os.bzl", "minimum_os")\n'
                    'swift_library(name = "New", alwayslink = True)\n'
                    'minimum_os(name = "New.rspm", minimum_os = "15.0", deps = [":New"])\n')
        missing = {'swift': {'New'}, 'cc': set()}
        producer, imports = support.overlay_build(original, package(), missing, True)
        self.assertIn('support_swift_library', imports)
        self.assertIn('minimum_os = "15.0"', producer)
        consumer, imports = support.overlay_build(original, package(), missing, False)
        self.assertEqual(producer, consumer)
        self.assertIn('import_swift_library', imports)
        self.assertNotIn('support_swift_library', imports)
        self.assertNotIn('@build_bazel_rules_swift', consumer)

    def test_compiler_actions_reject_source_fallback_even_if_cached(self):
        actions = {'targets': [{'id': 1, 'label': '@@+dependencies+swiftpkg_example//:New'}],
                   'actions': [{'targetId': 1, 'mnemonic': 'SwiftCompile'}]}
        support.assert_compile_actions(actions, {'swiftpkg_example': {'swift': {'New'}, 'cc': set()}})
        with self.assertRaisesRegex(ValueError, 'Unexpected lower'):
            support.assert_compile_actions(actions, {'swiftpkg_example': {'swift': set(), 'cc': set()}})

    def test_rejects_configuration_and_minimum_os_drift(self):
        expected = {'key': graph_row('New')}
        observed = {'key': dict(graph_row('New'), configuration={'checksum': 'b' * 64})}
        missing = {'swiftpkg_example': {'swift': {'New'}, 'cc': set()}}
        with self.assertRaisesRegex(ValueError, 'variant changed'):
            support.assert_variants(expected, observed, missing)
        with self.assertRaisesRegex(ValueError, 'variant changed'):
            support.assert_variants(expected, {}, missing)

    def test_configured_graph_requires_full_configuration(self):
        config = {'checksum': 'a' * 64, 'fragmentOptions': [{'options': [
            {'name': 'compilation_mode', 'value': 'opt'},
            {'name': '--define:runtime_profile', 'value': 'stock'},
            {'name': 'macos_minimum_os', 'value': '15.0'}]}]}
        row = {'target': {'rule': {'name': '@swiftpkg_example//:New', 'ruleClass': 'swift_library',
                                  'attribute': []}}, 'configuration': {'checksum': 'a' * 64}}
        graph = {'configurations': [config], 'results': [row]}
        self.assertEqual(len(support.configured_graph(graph)), 1)
        for index, value in [(0, 'dbg'), (1, 'enhanced'), (2, '')]:
            modified = json.loads(json.dumps(graph))
            modified['configurations'][0]['fragmentOptions'][0]['options'][index]['value'] = value
            with self.assertRaisesRegex(ValueError, 'configuration'):
                support.configured_graph(modified)

    def test_tree_identity_binds_modes_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / 'runner.sh'
            script.write_text('#!/bin/sh\n')
            script.chmod(0o755)
            before = support.tree_identity(root)
            script.chmod(0o644)
            self.assertNotEqual(before, support.tree_identity(root))
            (root / 'link').symlink_to(script)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                support.tree_identity(root)

    def test_fresh_xml_refuses_cached_missing_empty_and_failed_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            xml = root / 'test.xml'
            xml.write_text('<testsuite><testcase name="proof"/></testsuite>')
            log = root / 'test.log'
            log.write_text('passed')
            result = {'status': 'PASSED', 'testActionOutput': [
                {'name': 'test.xml', 'uri': xml.as_uri()}, {'name': 'test.log', 'uri': log.as_uri()}]}
            event = lambda value: {'id': {'testResult': {'label': support.TARGET}}, 'testResult': value}
            support.retain_test_xml([event(result)], root / 'retained.xml', root)
            for changes in [{'cachedLocally': True}, {'executionInfo': {'cachedRemotely': True}},
                            {'testActionOutput': []}, {'status': 'FAILED'}]:
                with self.subTest(changes=changes):
                    with self.assertRaises(ValueError):
                        support.retain_test_xml([event(dict(result, **changes))], root / 'rejected.xml', root)
            for payload in ['<testsuite/>', '<testsuite><testcase><skipped/></testcase></testsuite>',
                            '<testsuite><testcase><failure/></testcase></testsuite>']:
                xml.write_text(payload)
                with self.assertRaises(ValueError):
                    support.retain_test_xml([event(result)], root / 'rejected.xml', root)
            with self.assertRaises(ValueError):
                support.retain_test_xml([{'id': {'testResult': {'label': '//:Wrong'}}, 'testResult': result}],
                                        root / 'rejected.xml', root)


    def test_generated_cwd_binding_restores_source_even_on_failure(self):
        original = support.launcher.ROOT
        generated = Path('/Volumes/SSD/q/generated-test-workspace')
        with self.assertRaisesRegex(RuntimeError, 'child'):
            with support.selected_workspace(generated):
                self.assertEqual(support.launcher.ROOT, generated)
                raise RuntimeError('child')
        self.assertEqual(support.launcher.ROOT, original)
        with tempfile.TemporaryDirectory() as temporary:
            with support.selected_workspace(generated):
                with patch.object(support.launcher.subprocess, 'Popen', side_effect=RuntimeError('child')) as child:
                    with self.assertRaises(RuntimeError):
                        support.launcher.run_owned(['bazel'], Path(temporary) / 'child.log', {})
                    self.assertEqual(child.call_args.kwargs['cwd'], generated)
        self.assertEqual(support.launcher.ROOT, original)

    def test_json_document_rejects_missing_or_multiple_documents(self):
        self.assertEqual(support.json_document('INFO: query\n{"results": []}\nINFO: finished'), {'results': []})
        for text in ['INFO: no JSON', '{}\n{}']:
            with self.assertRaises(ValueError):
                support.json_document(text)

    def test_layer_admission_rejects_map_lock_drift_before_inspection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'Tools/bazel/artifacts/argument-parser.lock.json'
            lock.parent.mkdir(parents=True)
            lock.write_text(json.dumps({'archiveSHA256': 'a' * 64}))
            archive = root / 'archive.tar.gz'
            archive.write_bytes(b'archive')
            paths = {group: {'archive': str(archive), 'archiveSHA256': 'a' * 64,
                             'lock': str(lock), 'lockSHA256': 'b' * 64} for group in support.GROUPS}
            with patch.object(support.argument, 'verify_consumer') as verify:
                with self.assertRaisesRegex(ValueError, 'current source locks'):
                    support.load_layers(root, paths, {})
                verify.assert_not_called()


    def test_shutdown_clears_only_successful_recovery_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / 'recovery.json'
            runner = support.Workspace(root, root, {}, marker)
            runner.workspace.mkdir()
            for status in (1, 0):
                marker.write_text('uncertain')
                def child(argv, log, environment, recovery):
                    log.write_text('shutdown')
                    return status
                with patch.object(support.launcher, 'run_owned', side_effect=child):
                    if status:
                        with self.assertRaises(RuntimeError):
                            runner.invoke('shutdown', [])
                        self.assertTrue(marker.exists())
                    else:
                        runner.invoke('shutdown', [])
                        self.assertFalse(marker.exists())
            marker.write_text('uncertain')
            with patch.object(support.launcher, 'run_owned', side_effect=RuntimeError('unreaped')):
                with self.assertRaises(RuntimeError):
                    runner.invoke('shutdown', [])
            self.assertTrue(marker.exists())

    def test_xml_records_cases_and_checks_every_declared_suite_total(self):
        xml = ('<testsuites tests="2" failures="0" errors="0" skipped="0">'
               '<testsuite tests="1"><testcase name="one"/></testsuite>'
               '<testsuite tests="1"><testcase name="two"/></testsuite></testsuites>')
        self.assertEqual(support.xml_testcase_count(xml.encode()), 2)
        for changed in [xml.replace('tests="2"', 'tests="1"'),
                        xml.replace('tests="1"', 'tests="2"', 1),
                        xml.replace('failures="0"', 'failures="1"'),
                        xml.replace('errors="0"', 'errors="1"'),
                        xml.replace('skipped="0"', 'skipped="1"'),
                        xml.replace('tests="2"', 'tests="invalid"')]:
            with self.subTest(changed=changed):
                with self.assertRaisesRegex(ValueError, 'Contradictory XML'):
                    support.xml_testcase_count(changed.encode())

    def test_bep_run_count_counts_attempts_not_xml_cases(self):
        events = [
            {'id': {'testSummary': {'label': support.TARGET, 'configuration': {'id': 'config'}}},
             'testSummary': {'overallStatus': 'PASSED', 'totalRunCount': 1, 'runCount': 1,
                             'attemptCount': 1, 'shardCount': 1}},
            {'id': {'testResult': {'label': support.TARGET, 'configuration': {'id': 'config'},
                                  'run': 1, 'attempt': 1, 'shard': 0}},
             'testResult': {'status': 'PASSED'}}]
        support.validate_test_summary(events)
        # One executable invocation legitimately reports multiple XML cases.
        self.assertEqual(support.xml_testcase_count(
            b'<testsuite tests="2"><testcase/><testcase/></testsuite>'), 2)
        for field, value in [('totalRunCount', 2), ('runCount', 2), ('attemptCount', 2),
                             ('shardCount', 2), ('totalNumCached', 1)]:
            changed = json.loads(json.dumps(events))
            changed[0]['testSummary'][field] = value
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, 'Contradictory BEP'):
                    support.validate_test_summary(changed)
        changed = json.loads(json.dumps(events))
        changed[1]['id']['testResult']['configuration']['id'] = 'other'
        with self.assertRaises(ValueError):
            support.validate_test_summary(changed)
        with self.assertRaises(ValueError):
            support.validate_test_summary(events + [events[1]])


if __name__ == '__main__':
    unittest.main()
