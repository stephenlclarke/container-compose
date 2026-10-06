"""Pure unrelated-job parser tests; no launchctl or service operation."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
SPEC=importlib.util.spec_from_file_location('foreign_job_adapter',Path(__file__).with_name('compose_homebrew_installation.py'))
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)
class FakeLaunchd:
    domain='gui/501'
    def __init__(self,text,status=0):self.text=text;self.status=status;self.calls=[]
    def command(self,*arguments):
        self.calls.append(arguments);return SimpleNamespace(stdout=self.text.encode(),returncode=self.status)
class ForeignRegistrationTests(unittest.TestCase):
    def test_submitted_job_without_path_or_program_is_accurately_recorded(self):
        job=FakeLaunchd('\ttype = Submitted\n\tpid = 123\n')
        self.assertEqual(M.foreign_job_identity(job,'submitted.job'),{'label':'submitted.job','path':None,'program':None,'type':'Submitted'})
        self.assertEqual(job.calls,[('print','gui/501/submitted.job')])
    def test_optional_fields_remain_identity_when_present(self):
        job=FakeLaunchd('\tpath = /owned/example.plist\n\tprogram = /usr/bin/example\n')
        value=M.foreign_job_identity(job,'registered.job')
        self.assertEqual(value['path'],'/owned/example.plist');self.assertEqual(value['program'],'/usr/bin/example')
    def test_duplicate_fields_reject_instead_of_adopting(self):
        for key in ['path','program','type']:
            with self.assertRaises(ValueError):M.foreign_job_identity(FakeLaunchd(f'\t{key} = a\n\t{key} = b\n'),'job')
    def test_transport_or_disappearance_failure_rejects(self):
        for status in [1,113]:
            with self.assertRaises(RuntimeError):M.foreign_job_identity(FakeLaunchd('',status),'job')
    def test_process_reincarnation_does_not_change_registration_identity(self):
        first=M.foreign_job_identity(FakeLaunchd('\ttype = Submitted\n\tpid = 12\n'),'job')
        second=M.foreign_job_identity(FakeLaunchd('\ttype = Submitted\n\tpid = 99\n'),'job')
        self.assertEqual(first,second)
    def test_program_change_changes_registration_identity(self):
        first=M.foreign_job_identity(FakeLaunchd('\tprogram = /first\n'),'job')
        second=M.foreign_job_identity(FakeLaunchd('\tprogram = /second\n'),'job')
        self.assertNotEqual(first,second)
if __name__=='__main__':unittest.main()
