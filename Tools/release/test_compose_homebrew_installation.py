"""Offline admission regressions; no Homebrew, services, or runtime invocation."""
import importlib.util
from pathlib import Path
import copy
import unittest

SPEC = importlib.util.spec_from_file_location('compose_install', Path(__file__).with_name('compose_homebrew_installation.py'))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class PairAdmissionTests(unittest.TestCase):
    def fixture(self):
        ctx = {'sourceCommit':'a'*40, 'version':'1.2.3', 'runtimeVersion':'0.16.0', 'runtimeProductVersion':'0.0.0',
               'runtimeArchiveSHA256':M.RUNTIME_SHA, 'runtimeSourceCommit':M.RUNTIME_SOURCE, 'formulae':{}}
        texts = {}
        for name, asset, digest in [('container','container-release-arm64.tar.gz',M.RUNTIME_SHA),
                                    ('container-compose','container-compose-plugin-release-arm64.tar.gz','b'*64)]:
            text = f'  url "https://github.com/stephenlclarke/container-compose/releases/download/1.2.3/{asset}"\n  sha256 "{digest}"\n'
            if name=='container':text += '  version "0.16.0"\n  # container CLI version 0.0.0 (commit: f86fea2)\n  link = opt/container-compose/libexec/container-plugins/compose\n'
            else:text += '  depends_on "stephenlclarke/tap/container"\n'
            texts[name]=text;ctx['formulae'][name]={'archiveSHA256':digest,'formulaSHA256':M.sha(text.encode()),'binarySHA256':M.RUNTIME_BINARY_SHA if name=='container' else 'c'*64}
        return ctx,texts

    def test_embedded_product_source_are_verified_independently(self):
        ctx,_=self.fixture()
        self.assertEqual(M.validate_runtime_product('container CLI version 0.0.0 (commit: f86fea2)\n',ctx),
                         {'productVersion':'0.0.0','sourceCommit':M.RUNTIME_SOURCE})
        for output in ['container CLI version 0.16.0 (commit: f86fea2)',
                       'container CLI version 0.0.0 (commit: aaaaaaa)',
                       'container CLI version 0.0.0 (commit: f86fea2) unexpected']:
            with self.assertRaises(ValueError):M.validate_runtime_product(output,ctx)

    def test_runtime_build_metadata_preserves_exact_version_and_source(self):
        ctx,_=self.fixture()
        value='container CLI version 0.0.0 (build: release, builder-shim: registry@sha256:123, commit: f86fea2, distribution: custom)'
        self.assertEqual(M.validate_runtime_product(value,ctx)['sourceCommit'],M.RUNTIME_SOURCE)
        for bad in [value.replace('f86fea2','aaaaaaa'),value.replace('commit: f86fea2','commit: f86fea2, commit: f86fea2'),value+' suffix']:
            with self.assertRaises(ValueError):M.validate_runtime_product(bad,ctx)

    def test_source_build_binary_hash_cannot_substitute_for_signed_payload(self):
        ctx,texts=self.fixture();ctx['formulae']['container']['binarySHA256']='4'*64
        with self.assertRaises(ValueError):M.validate_pair(ctx,texts)

    def test_matched_runtime_version_is_independent_of_compose_version(self):
        ctx,texts=self.fixture();M.validate_pair(ctx,texts)

    def test_wrong_qualified_runtime_never_admitted(self):
        ctx,texts=self.fixture();ctx['runtimeSourceCommit']='c'*40
        with self.assertRaises(ValueError):M.validate_pair(ctx,texts)

    def test_duplicate_archive_or_modified_ruby_rejected(self):
        for extra in ['  sha256 "'+'b'*64+'"\n', '  system "unexpected"\n']:
            ctx,texts=self.fixture();texts['container-compose']+=extra
            with self.assertRaises(ValueError):M.validate_pair(ctx,texts)

    def test_same_tag_does_not_overwrite_runtime_product_version(self):
        ctx,texts=self.fixture();ctx['runtimeVersion']='1.2.3'
        with self.assertRaises(ValueError):M.validate_pair(ctx,texts)

    def test_distribution_version_can_be_derived_only_from_matching_url(self):
        ctx,texts=self.fixture()
        for name in texts:
            texts[name]=texts[name].replace('/1.2.3/','/0.16.0/')
        ctx['version']='0.16.0'
        texts['container']=texts['container'].replace('  version "0.16.0"\n','')
        for name,text in texts.items():ctx['formulae'][name]['formulaSHA256']=M.sha(text.encode())
        M.validate_pair(ctx,texts)
        ctx['version']='1.2.3'
        for name in texts:
            texts[name]=texts[name].replace('/0.16.0/','/1.2.3/')
            ctx['formulae'][name]['formulaSHA256']=M.sha(texts[name].encode())
        with self.assertRaises(ValueError):M.validate_pair(ctx,texts)

    def test_private_pair_rewrites_only_tap_namespace(self):
        ctx,texts=self.fixture();tap='stephenlclarke/container-compose-release-ci-123'
        for text in texts.values():
            updated=M.private_formula(text,tap)
            self.assertEqual(updated.replace(tap+'/container','stephenlclarke/tap/container'),text)
        self.assertIn(tap+'/container',M.private_formula(texts['container-compose'],tap))

    def test_foreign_or_existing_namespace_is_not_allowed(self):
        with self.assertRaises(ValueError):M.private_formula('x','stephenlclarke/tap')

if __name__=='__main__':unittest.main()
