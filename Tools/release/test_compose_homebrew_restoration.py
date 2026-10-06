"""Real restoration core with fake Brew/services; only isolated temporary files."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from contextlib import contextmanager, nullcontext
from types import SimpleNamespace, ModuleType
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
CORE=HERE/'homebrew_installation_owned_reinstall_core.py'

def load(path,name):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m);return m

M=load(HERE/'compose_homebrew_installation.py','compose_test_adapter')

class Guard:
    owner=None
    def check(self):
        if self.owner is not None:raise ValueError('guard retained')
    def begin(self,owner):self.check();self.owner=owner
    def clear(self,owner):
        if self.owner!=owner:raise ValueError('wrong guard')
        self.owner=None

@contextmanager
def lease(path,guard):
    guard.check();yield

class Services:
    prior=[];captured_processes=[];signatures={};other_registrations={}
    def capture(self,*args):pass
    def stop(self):self.stopped=True
    def restore(self):self.restored=True
    def verify(self):
        if getattr(self,'stopped',False) and not getattr(self,'restored',False):raise ValueError('not restored')

class Brew:
    def __init__(self,prefix,context,core,fail):
        self.prefix=prefix;self.context=context;self.core=core;self.taps=set();self.fail=fail;self.failed=False;self.calls=[]
    def keg(self,name,version):
        keg=self.prefix/'Cellar'/name/version;keg.mkdir(parents=True,exist_ok=True)
        (keg/'INSTALL_RECEIPT.json').write_text('{}')
        if name.startswith('container-compose'):
            binary=keg/'libexec/container-plugins/compose/bin/compose';binary.parent.mkdir(parents=True);binary.write_text('plugin')
            (keg/'bin').mkdir();(keg/'bin/container-compose').symlink_to('../libexec/container-plugins/compose/bin/compose')
        else:
            binary=keg/'libexec/bin/container';binary.parent.mkdir(parents=True);binary.write_text('runtime')
            (keg/'bin').mkdir();(keg/'bin/container').write_text('wrapper')
        opt=self.prefix/'opt'/name
        if opt.is_symlink():opt.unlink()
        opt.symlink_to(keg)
        return keg
    def __call__(self,*args,timeout=900):
        self.calls.append(args)
        if args==('--prefix',):return str(self.prefix)
        if args==('--cellar',):return str(self.prefix/'Cellar')
        if args==('--repository',):return str(self.prefix)
        if args[0]=='tap':return '\n'.join(self.taps)
        if args[0]=='--repository':return str(self.prefix/'Library/Taps/stephenlclarke'/('homebrew-'+args[1].split('/')[1]))
        if args[0]=='--prefix':return str(self.prefix/'opt'/args[1].split('/')[-1])
        if args[:3]==('list','--formula','--versions'):
            return '\n'.join(f'{name} {k.name}' for name in sorted(M.FORMULAE) for k in sorted((self.prefix/'Cellar'/name).glob('*')))
        if args[0]=='tap-new':
            self.taps.add(args[-1]);(Path(self('--repository',args[-1]))/'Formula').mkdir(parents=True);return ''
        if args[0]=='untap':
            shutil.rmtree(Path(self('--repository',args[1])));self.taps.remove(args[1]);return ''
        if args[0]=='uninstall':
            name=args[-1];root=self.prefix/'Cellar'/name
            if root.exists():shutil.rmtree(root)
            link=self.prefix/'opt'/name
            if link.is_symlink():link.unlink()
            return ''
        if args[0]=='install':
            name=args[-1].split('/')[-1];version=self.context['runtimeVersion'] if name=='container' else self.context['version']
            self.keg(name,version)
        if args[0]=='test' and getattr(self,'corrupt_backup',False):
            backup_file=next((self.transaction.backup/'kegs/container').rglob('INSTALL_RECEIPT.json'))
            backup_file.write_text('corrupted durable backup')
        key=(args[0],args[-1].split('/')[-1])
        if key==self.fail and not self.failed:
            self.failed=True;raise self.core.InstallationError('injected candidate failure')
        return ''

class RestorationTests(unittest.TestCase):
    def exercise(self,failure=None,same_version=False,corrupt_backup=False):
        with tempfile.TemporaryDirectory(dir=Path.home(),prefix='compose-install-offline-') as directory:
            root=Path(directory);prefix=root/'brew';prefix.mkdir();(prefix/'Cellar').mkdir();(prefix/'opt').mkdir()
            (prefix/'bin').mkdir();(prefix/'Library/Taps/stephenlclarke').mkdir(parents=True)
            retained=root/'retained';retained.mkdir(mode=0o700)
            context={'sourceCommit':'a'*40,'version':'1.2.3','runtimeVersion':'0.16.0','runtimeProductVersion':'0.0.0','runtimeSourceCommit':M.RUNTIME_SOURCE,'runtimeArchiveSHA256':M.RUNTIME_SHA,'teamID':'ABCDEFGHIJ','formulae':{},'templates':{}}
            for name,asset,digest in [('container','container-release-arm64.tar.gz',M.RUNTIME_SHA),('container-compose','container-compose-plugin-release-arm64.tar.gz','b'*64)]:
                text=f'  url "https://github.com/stephenlclarke/container-compose/releases/download/1.2.3/{asset}"\n  sha256 "{digest}"\n'
                text+='  version "0.16.0"\n  # container CLI version 0.0.0 (commit: f86fea2)\n  link = opt/container-compose/libexec/container-plugins/compose\n' if name=='container' else '  depends_on "stephenlclarke/tap/container"\n'
                file=root/(name+'.rb');file.write_text(text)
                context['formulae'][name]={'path':str(file),'formulaSHA256':M.sha(text.encode()),'archiveSHA256':digest,'binarySHA256':M.RUNTIME_BINARY_SHA if name=='container' else 'c'*64}
            # Stub host control at the import boundary, never the real core's
            # inventory, backup, restoration, guard-state or receipt methods.
            host = ModuleType('host_runtime')
            host.HostGuard = lambda *args: Guard()
            host.runtime_lease = lease
            host.cancellation = nullcontext
            switch = ModuleType('service_switch')
            switch.Launchd = lambda: object()
            switch.canonical_file = lambda path: path.read_bytes()
            processes = ModuleType('runtime_services')
            with patch.dict('sys.modules', {'host_runtime':host, 'service_switch':switch, 'runtime_services':processes}):
                core=load(CORE,'private_restoration_core')
            args=SimpleNamespace(context=root/'context.json',test_tap='stephenlclarke/container-compose-release-ci-123',ssd_scratch=root/'scratch',retained_root=retained,receipt_output=root/'receipt.json')
            args.context.write_text(json.dumps(context))
            with patch.dict('sys.modules', {'host_runtime':host, 'service_switch':switch, 'runtime_services':processes}):
                tx=M.transaction(core,context,args)
            brew=Brew(prefix,context,core,failure)
            brew.corrupt_backup=corrupt_backup;brew.transaction=tx
            for name in sorted(M.FORMULAE):brew.keg(name,'1.2.3' if name=='container-compose' and same_version else context['runtimeVersion'] if name=='container' and same_version else '0.15.1' if name=='container' else 'old.1')
            before={name:{str(k):core.tree_inventory(k) for k in (prefix/'Cellar'/name).iterdir()} for name in sorted(M.FORMULAE)}
            tx.runner=brew;tx.service=Services();tx.guard=Guard();tx.lease_factory=lease;tx.cancellation_factory=nullcontext;tx.storage_check=lambda *a:None
            with patch.object(M,'signed_binary',return_value=None), patch.object(M,'runtime_product',return_value={'productVersion':'0.0.0','sourceCommit':M.RUNTIME_SOURCE}):
                if corrupt_backup:
                    with self.assertRaises(core.InstallationError):tx.run()
                    receipt=json.loads(args.receipt_output.read_bytes())
                    self.assertEqual(receipt['status'],'restoration-failed')
                    self.assertFalse(receipt['baselineRestored']);self.assertFalse(receipt['guardAbsent'])
                    self.assertIsNotNone(tx.guard.owner)
                    diagnostic=json.loads(args.receipt_output.with_name('receipt.cleanup-error.json').read_text())
                    self.assertEqual(diagnostic['scope'],'private-installation-cleanup-diagnostic')
                    self.assertEqual(diagnostic['exceptionChain'][0]['type'],'InstallationError')
                    self.assertIn('restoration failed',diagnostic['exceptionChain'][0]['message'])
                    return
                if failure is None:receipt=tx.run();self.assertEqual(receipt['status'],'passed-restored')
                else:
                    with self.assertRaises(core.InstallationError):tx.run()
                    receipt=json.loads(args.receipt_output.read_bytes());self.assertEqual(receipt['status'],'failed-restored')
            after={name:{str(k):core.tree_inventory(k) for k in (prefix/'Cellar'/name).iterdir()} for name in sorted(M.FORMULAE)}
            self.assertEqual(before,after);self.assertIsNone(tx.guard.owner)
            self.assertEqual(receipt['beforeInventorySHA256'],receipt['afterInventorySHA256'])
            self.assertFalse(receipt['broadPostInstallStopExecuted'])
            self.assertTrue(all('--skip-post-install' in call for call in brew.calls if call[0]=='install'))
    def test_corrupted_durable_backup_keeps_guard_and_rejects_success(self):self.exercise(corrupt_backup=True)
    def test_same_runtime_and_compose_versions_restore_exactly(self):self.exercise(same_version=True)
    def test_partial_runtime_install_restores(self):self.exercise(('install','container'))
    def test_partial_compose_install_before_registration_restores(self):self.exercise(('install','container-compose'))
    def test_first_formula_test_failure_restores(self):self.exercise(('test','container'))
    def test_second_formula_test_failure_restores(self):self.exercise(('test','container-compose'))

if __name__=='__main__':unittest.main()
