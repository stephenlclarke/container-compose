"""Pure authentication tests for an explicit portable controller root."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC=importlib.util.spec_from_file_location('portable_install',Path(__file__).with_name('compose_homebrew_installation.py'))
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)

class PortabilityTests(unittest.TestCase):
    def fixture(self,root):
        root=root.resolve();testing=root/'Tools/testing';bazel=root/'Tools/bazel'
        testing.mkdir(parents=True);bazel.mkdir()
        for name in ['host_runtime.py','runtime_services.py','service_switch.py','transitive.py']:
            (testing/name).write_text('# inert fixture\n')
        (bazel/'release_inputs.py').write_text('# inert fixture\n')
        return testing,{str(p):M.sha(p.read_bytes()) for p in root.rglob('*.py')}
    def test_explicit_root_works_outside_any_repository_location(self):
        with tempfile.TemporaryDirectory() as d:
            root,hashes=self.fixture(Path(d));self.assertEqual(M.authenticate_testing_root(root,hashes),root)
    def test_missing_transitive_binding_rejects_before_import(self):
        with tempfile.TemporaryDirectory() as d:
            root,hashes=self.fixture(Path(d));del hashes[str(root/'transitive.py')]
            with self.assertRaises(ValueError):M.authenticate_testing_root(root,hashes)
    def test_changed_sibling_bazel_code_rejects_before_import(self):
        with tempfile.TemporaryDirectory() as d:
            root,hashes=self.fixture(Path(d));(root.parent/'bazel/release_inputs.py').write_text('unexpected code')
            with self.assertRaises(ValueError):M.authenticate_testing_root(root,hashes)
    def test_aliased_root_rejects_before_import(self):
        with tempfile.TemporaryDirectory() as d:
            root,hashes=self.fixture(Path(d));alias=Path(d).resolve()/'alias';alias.symlink_to(root)
            with self.assertRaises(ValueError):M.authenticate_testing_root(alias,hashes)

if __name__=='__main__':unittest.main()
