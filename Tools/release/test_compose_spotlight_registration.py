"""Exact OS-instance normalization and private failure diagnostic regressions."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
SPEC=importlib.util.spec_from_file_location('spotlight_adapter',Path(__file__).with_name('compose_homebrew_installation.py'))
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)
class SpotlightTests(unittest.TestCase):
    def row(self,suffix):
        label='com.apple.mdworker.shared.'+suffix
        return label,{'label':label,'domain':f'user/{os.getuid()}', 'path':'/System/Library/LaunchAgents/com.apple.mdworker.shared.plist',
                      'program':'/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared','type':'LaunchAgent'}
    def test_verified_two_to_one_os_worker_churn_has_same_definition(self):
        before=dict([self.row('06000000-0500-0000-0000-000000000000'),self.row('0C000000-0300-0000-0000-000000000000')])
        after=dict([self.row('10000000-0300-0000-0000-000000000000')])
        self.assertEqual(M.normalized_foreign_registrations(before),M.normalized_foreign_registrations(after))
    def test_changed_or_unaccounted_spotlight_definition_rejects(self):
        for field,value in [('domain','gui/501'),('path','/foreign'),('program','/foreign'),('type','Submitted'),('extra','unaccounted')]:
            key,row=self.row('10000000-0300-0000-0000-000000000000');row[field]=value
            with self.assertRaises(ValueError):M.normalized_foreign_registrations({key:row})
    def test_other_apple_jobs_and_non_instance_names_remain_exact(self):
        for key in ['com.apple.other','com.apple.mdworker.shared.not-a-uuid']:
            row={'label':key,'program':'/original'}
            self.assertEqual(M.normalized_foreign_registrations({key:row}),{key:row})
    def test_missing_all_instances_is_not_silently_ignored(self):
        key,row=self.row('10000000-0300-0000-0000-000000000000')
        self.assertNotEqual(M.normalized_foreign_registrations({key:row}),M.normalized_foreign_registrations({}))
    def test_private_diagnostic_has_step_exit_and_redacted_bounded_stderr(self):
        cause=subprocess.CalledProcessError(1,['brew'],stderr='Error: because it is required by dependency\nTOKEN=abcdef password: abcdef Authorization: Bearer ghsecret https://user:secret@example.test/token?access=abc\n'+'x'*9000)
        error=RuntimeError('safe wrapper');error.__cause__=cause
        value=M.command_failure_diagnostic(('uninstall','--force','container'),error)
        self.assertEqual(value['arguments'],['uninstall','--force','container']);self.assertEqual(value['exitCode'],1)
        self.assertEqual(value['causeCategory'],'dependency-blocked');self.assertLessEqual(len(value['privateStderrExcerpt']),4096)
        for secret in ['abcdef','user:secret','access=abc','ghsecret']:self.assertNotIn(secret,value['privateStderrExcerpt'])
if __name__=='__main__':unittest.main()
