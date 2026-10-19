#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Publish one admitted Bazel-native stable Compose pair, durably and without rebuilds."""
from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

import finalize_qualified_compose as finalizer
import stable_compose_controller as controller

REPOSITORY = 'stephenlclarke/container-compose'
TAP_REPOSITORY = 'stephenlclarke/homebrew-tap'
FORMULAE = {'container': 'Formula/container.rb', 'container-compose': 'Formula/container-compose.rb'}
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def command(args: list[str], *, cwd: Path | None = None, input: str | None = None,
            timeout: int = 60, check: bool = True):
    result = subprocess.run(args, cwd=cwd, input=input, capture_output=True, text=True,
                            timeout=timeout, env={**os.environ, 'GH_HOST': 'github.com'})
    if check and result.returncode:
        raise controller.ControllerError('bounded external command failed: ' + Path(args[0]).name)
    return result


def regular(path: str | Path) -> Path:
    value = Path(path)
    if value.is_symlink() or not value.is_file() or value.resolve() != value:
        raise controller.ControllerError('input is missing or aliased')
    return value


def directory(path: str | Path, *, private: bool = False) -> Path:
    value = Path(path)
    if not value.is_absolute() or value.resolve() != value or value.is_symlink() or not value.is_dir():
        raise controller.ControllerError('directory is not canonical')
    info = value.stat()
    if info.st_uid != os.getuid() or (private and info.st_mode & 0o077):
        raise controller.ControllerError('directory ownership/privacy differs')
    return value


def tar_files(path: Path) -> dict[str, tuple[bytes, int]]:
    """Read regular files without extracting untrusted paths or following links."""
    files = {}
    total = 0
    with tarfile.open(path, 'r:gz') as archive:
        names = set()
        for member in archive.getmembers():
            raw = member.name.removeprefix('./')
            name = PurePosixPath(raw)
            if (name.is_absolute() or '..' in name.parts or '\\' in raw
                    or raw in names or not (member.isfile() or member.isdir() or member.issym())):
                raise controller.ControllerError('unsafe or duplicate TAR member')
            names.add(raw)
            if member.issym():
                target = PurePosixPath(member.linkname)
                if target.is_absolute() or '..' in target.parts:
                    raise controller.ControllerError('archive symlink escapes installation')
                continue
            if not member.isfile():
                continue
            total += member.size
            if total > 1073741824:
                raise controller.ControllerError('archive exceeds inspection bound')
            files[name.as_posix()] = (archive.extractfile(member).read(), member.mode)
    return files


class ProductionOperations:
    def __init__(self, plan: dict, manifest: dict, manifest_sha: str, *, run=command, libraries=None, manifest_path=None, recover_owned_tap=False):
        self.plan, self.manifest, self.manifest_sha, self.run = plan, manifest, manifest_sha, run
        self.manifest_path = manifest_path
        self.recover_owned_tap = recover_owned_tap
        self.repo = directory(manifest['checkout'])
        self.source_repo = directory(manifest['sourceRepository'])
        self.tap = directory(manifest['tapCheckout'])
        self.journals = directory(manifest['journalRoot'], private=True)
        self.assets = directory(manifest['assetsDirectory'])
        self.downloads = directory(manifest['downloadRoot'], private=True)
        self.scratch = directory(manifest['ssdScratch'])
        self._libraries = libraries
        self.verify_inputs()
        if libraries is None:
            sys.path.insert(0, str(self.repo / 'Tools/bazel'))
            self._libraries = {name: importlib.import_module(module) for name, module in (
                ('release', 'compose_release'), ('assets', 'artifacts.release_asset'),
                ('q_assets', 'q_assets'), ('qualification', 'qualify_local'))}
            self._libraries['qualification'].Q_ROOT = directory(manifest['qualifiedRuntimeCheckout'])
            self._libraries['qualification'].Q_EVIDENCE = directory(manifest['qualifiedRuntimeEvidence'])

    def git(self, repo: Path, *args: str, check=True) -> str:
        return self.run(['git', '-C', str(repo), *args], check=check).stdout.strip()

    def gh(self, endpoint: str, *, body: dict | None = None, missing=False) -> dict | None:
        args = ['gh', 'api', '--hostname', 'github.com', endpoint]
        if body is not None:
            args += ['--method', 'PATCH', '--input', '-']
        result = self.run(args, input=json.dumps(body) if body is not None else None, check=False)
        if result.returncode:
            if missing and 'http 404' in result.stderr.lower():
                return None
            raise controller.ControllerError('GitHub state could not be authenticated')
        return json.loads(result.stdout)

    def verify_inputs(self) -> None:
        m, p = self.manifest, self.plan
        if (p.get('executionManifestSHA256') != self.manifest_sha
                or self.manifest_path is not None
                and finalizer.digest(finalizer.read(self.manifest_path)) != self.manifest_sha):
            raise controller.ControllerError('private execution manifest hash differs')
        claims = m.get('inputFiles')
        if not isinstance(claims, dict) or p.get('executionFilesSHA256') != {
                label: row['sha256'] for label, row in claims.items()}:
            raise controller.ControllerError('execution file closure differs from public plan')
        actual_paths = set()
        for row in claims.values():
            path = regular(row['path'])
            if finalizer.digest(path.read_bytes()) != row['sha256']:
                raise controller.ControllerError('frozen execution file changed')
            actual_paths.add(path)
        context = json.loads(finalizer.read(regular(m['installationContext'])))
        self.context = context
        required = {Path(__file__).resolve(), Path(controller.__file__).resolve(), Path(finalizer.__file__).resolve(),
                    regular(m['installationContext']), regular(m['installationCore']), regular(m['installationAdapter']),
                    regular(m['allowedSigners'])}
        required.update(Path(row['path']) for row in context['templates'].values())
        required.update(Path(path) for path in m['publicFormulas'].values())
        required.update((self.repo / 'Tools/bazel').rglob('*.py'))
        required.update((directory(m['qualifiedRuntimeCheckout']) / 'Tools/bazel').rglob('*.py'))
        testing = directory(m['testingRoot'])
        helper_paths = set(testing.rglob('*.py')) | set((testing.parent / 'bazel').rglob('*.py'))
        required.update(helper_paths)
        controller_claims = context['controllerFilesSHA256']
        if not helper_paths.issubset({Path(path) for path in controller_claims}):
            raise controller.ControllerError('installation import closure is incomplete')
        for path, expected in controller_claims.items():
            required.add(regular(path))
            if finalizer.digest(finalizer.read(Path(path))) != expected:
                raise controller.ControllerError('installation controller import changed')
        if not required.issubset(actual_paths):
            raise controller.ControllerError('frozen execution input inventory omitted imported code or template')
        if (not isinstance(m.get('authorName'), str) or not m['authorName'].strip()
                or not isinstance(m.get('authorEmail'), str) or '@' not in m['authorEmail']):
            raise controller.ControllerError('reviewed Git author identity is missing')
        if (self.git(self.repo, 'rev-parse', 'HEAD') != p['toolCommit']
                or self.git(self.repo, 'status', '--porcelain')):
            raise controller.ControllerError('admission tooling checkout is not clean and pinned')
        if (context['sourceCommit'] != p['sourceCommit'] or context['version'] != p['releaseTag']
                or context['runtimeSourceCommit'] != p['runtimeQualifiedSource']
                or context['runtimeArchiveSHA256'] != p['runtimeArchiveSHA256']
                or context['runtimeVersion'] != p['runtimeFormulaVersion']
                or context['runtimeProductVersion'] != p['runtimeProductVersion']):
            raise controller.ControllerError('installation context product/runtime identity differs')
        for name in FORMULAE:
            formula = regular(m['publicFormulas'][name])
            row = context['formulae'][name]
            expected_archive = p['runtimeArchiveSHA256'] if name == 'container' else p['composeArchiveSHA256']
            expected_binary = p['runtimeBinarySHA256'] if name == 'container' else p['composeBinarySHA256']
            if (row['path'] != str(formula) or row['formulaSHA256'] != p['formulaPairSHA256'][name]
                    or row['archiveSHA256'] != expected_archive or row['binarySHA256'] != expected_binary
                    or finalizer.digest(formula.read_bytes()) != p['formulaPairSHA256'][name]):
                raise controller.ControllerError('public formula/context archive identity differs')
        if (finalizer.digest(finalizer.read(Path(m['installationContext']))) != p['installationContextSHA256']
                or finalizer.digest(finalizer.read(Path(m['installationCore']))) != p['installationCoreSHA256']
                or finalizer.digest(finalizer.read(Path(m['installationAdapter']))) != p['installationAdapterSHA256']):
            raise controller.ControllerError('installation adapter/core/context identity differs')
        if set(path.name for path in self.assets.iterdir() if path.is_file()) != set(p['assets']):
            raise controller.ControllerError('staged asset inventory differs')
        for name, claim in p['assets'].items():
            path = self.assets / name
            if claim != {'sha256': finalizer.file_digest(path), 'bytes': path.stat().st_size}:
                raise controller.ControllerError('staged release asset changed')

    def proof(self, phase: str, sha: str, **fields) -> dict:
        return {'phase': phase, 'passed': True, 'planSHA256': sha, **fields}

    def _admission(self, sha: str) -> dict:
        self.verify_inputs()
        p, m = self.plan, self.manifest
        accepted = self._libraries['release'].admit(directory(m['qualification']))
        authority = json.loads(finalizer.read(regular(m['finalizationAuthority'])))
        request = json.loads(finalizer.read(regular(m['finalizationRequest'])))
        notary = json.loads(finalizer.read(regular(m['finalizationNotary'])))
        if (accepted['source'] != p['sourceCommit']
                or finalizer.digest(finalizer.read(Path(m['qualification']) / 'acceptance.json')) != p['qualificationSHA256']
                or finalizer.digest(finalizer.read(Path(m['finalizationAuthority']))) != p['archiveAuthoritySHA256']
                or authority['sourceCommit'] != p['sourceCommit'] or authority['toolCommit'] != p['toolCommit']
                or authority['releaseTag'] != p['releaseTag'] or authority['archiveReady'] is not True
                or authority['publicationAuthorized'] is not False
                or authority['installationAndRestorationPending'] is not True
                or authority['notaryStatus'] != 'Accepted' or notary['status'] != 'Accepted'
                or authority['notarySubmissionId'] != notary['submissionId']
                or authority['requestSHA256'] != finalizer.digest(finalizer.canonical(request))
                or authority['legalClosureSHA256'] != p['legalClosureSHA256']
                or authority['tarSHA256'] != p['composeArchiveSHA256']
                or authority['archiveSHA256'] != p['assets'][m.get('notaryZipAsset', 'compose-stable.zip')]['sha256']
                or notary['archiveSHA256'] != authority['archiveSHA256']
                or notary['requestSHA256'] != authority['requestSHA256']
                or authority.get('externalSourceCompanion') != p.get('externalSourceCompanion')
                or request.get('externalSourceCompanion') != p.get('externalSourceCompanion')):
            raise controller.ControllerError('final archive authority is incomplete or substituted')
        original = finalizer.archive_files(Path(m['qualification']) / 'signed-compose.zip')
        finalizer.legal_files(regular(m['legalClosure']), p['legalClosureSHA256'], accepted,
                              json.loads(original[finalizer.BUILD_INFO][0]), p['releaseTag'])
        qassets = self._libraries['q_assets'].revalidate(Path(m['qualification']) / 'q-assets',
                                                       self._libraries['qualification'].q_modules()['hashes'])
        self.runtime_payload = qassets['provenance']['runtime']['payload']
        reviewed = json.loads(finalizer.read(regular(m['legalClosure'])))
        if (p.get('externalSourceCompanion') is None
                or reviewed.get('qualifiedRuntime') !=
                {'sourceCommit': p['runtimeQualifiedSource'], 'archiveSHA256': p['runtimeArchiveSHA256'],
                 'payloadSHA256': finalizer.digest(finalizer.canonical(self.runtime_payload))}):
            raise controller.ControllerError('reviewed runtime/plugin legal closure is not bound to actual Q bytes')
        for asset, path in (('compose-stable-archive-authority.json', m['finalizationAuthority']),
                            ('compose-final-notarization.json', m['finalizationNotary']),
                            ('compose-reviewed-legal-closure.json', m['legalClosure'])):
            if finalizer.digest(finalizer.read(regular(path))) != p['assets'][asset]['sha256']:
                raise controller.ControllerError('public authority/notary/legal asset differs from admitted evidence')
        if (qassets['assets']['runtime']['sha256'] != p['runtimeArchiveSHA256']
                or self.runtime_payload['bin/container'] != p['runtimeBinarySHA256']
                or request['finalTree']['bin/compose'] != p['composeBinarySHA256']):
            raise controller.ControllerError('qualified runtime/Compose payload identity differs')
        self.verify_archives({name: self.assets / name for name in p['assets']}, request, self.runtime_payload)
        notary_info = json.loads(self.run(['/usr/bin/xcrun', 'notarytool', 'info', authority['notarySubmissionId'],
                                         '--keychain-profile', m['notaryProfile'], '--output-format', 'json'], timeout=60).stdout)
        if notary_info.get('id') != authority['notarySubmissionId'] or notary_info.get('status') != 'Accepted':
            raise controller.ControllerError('Apple does not confirm final accepted submission')
        self.require_plugins()
        latest = self.gh('repos/' + REPOSITORY + '/releases/latest', missing=True)
        if latest and latest['tag_name'] != p['releaseTag']:
            if not finalizer.VERSION.fullmatch(latest['tag_name']) or tuple(map(int, latest['tag_name'].split('.'))) >= tuple(map(int, p['releaseTag'].split('.'))):
                raise controller.ControllerError('provisional stable version does not advance latest')
        if self.gh('user')['login'] != 'stephenlclarke':
            raise controller.ControllerError('GitHub execution identity is not the release owner')
        return self.proof('admission', sha, qualificationSHA256=p['qualificationSHA256'],
                          legalClosureSHA256=p['legalClosureSHA256'], archiveAuthoritySHA256=p['archiveAuthoritySHA256'])

    def require_plugins(self) -> None:
        compose = self.run(['docker', 'compose', 'version', '--short'], timeout=30).stdout.strip().removeprefix('v')
        buildx = self.run(['docker', 'buildx', 'version'], timeout=30).stdout.split()
        if compose != '5.5.1' or 'v0.37.1' not in buildx:
            raise controller.ControllerError('private Docker plugin closure is not pinned Compose/Buildx')

    def verify_archives(self, assets: dict[str, Path], request: dict, runtime_payload: dict) -> None:
        compose = tar_files(assets['container-compose-plugin-release-arm64.tar.gz'])
        if any(not name.startswith('compose/') for name in compose):
            raise controller.ControllerError('Compose TAR escaped its plugin layout')
        compose = {name.removeprefix('compose/'): row for name, row in compose.items()}
        zip_name = self.manifest.get('notaryZipAsset', 'compose-stable.zip')
        zipped = finalizer.archive_files(assets[zip_name])
        if compose != zipped or {name: finalizer.digest(data) for name, (data, _) in compose.items()} != request['finalTree']:
            raise controller.ControllerError('final TAR/ZIP tree differs')
        runtime = tar_files(assets['container-release-arm64.tar.gz'])
        for name, expected in runtime_payload.items():
            if name not in runtime or finalizer.digest(runtime[name][0]) != expected:
                raise controller.ControllerError('runtime Mach-O/resource payload differs')
        with tempfile.TemporaryDirectory(prefix='stable-signature-', dir=self.scratch) as temporary:
            base = Path(temporary)
            for prefix, tree in (('runtime', runtime), ('compose', compose)):
                for name, (data, mode) in tree.items():
                    if data[:4] not in MACHO:
                        continue
                    if not mode & 0o111:
                        raise controller.ControllerError('Mach-O executable mode differs')
                    target = base / prefix / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    target.chmod(mode)
                    self.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(target)], timeout=30)
                    display = self.run(['/usr/bin/codesign', '--display', '--verbose=4', str(target)], timeout=30)
                    if 'TeamIdentifier=' + self.context['teamID'] not in display.stderr.splitlines():
                        raise controller.ControllerError('signed release team differs')
            for name in finalizer.ELF:
                if name not in compose or not compose[name][0].startswith(b'\x7fELF') or not compose[name][1] & 0o111:
                    raise controller.ControllerError('Linux initializer identity/mode differs')

    def _remote(self, repo: Path, ref: str) -> str | None:
        rows = self.git(repo, 'ls-remote', '--refs', 'origin', ref).splitlines()
        if not rows:
            return None
        if len(rows) != 1 or rows[0].split()[1] != ref or re.fullmatch(r'[0-9a-f]{40}', rows[0].split()[0]) is None:
            raise controller.ControllerError('remote reference identity is ambiguous')
        return rows[0].split()[0]

    def _origin(self, repo: Path, owner: str) -> None:
        url = self.git(repo, 'remote', 'get-url', 'origin')
        if url not in {'git@github.com:' + owner + '.git', 'https://github.com/' + owner + '.git',
                       'https://github.com/' + owner}:
            raise controller.ControllerError('Git origin is not the owning repository')

    def _signed(self, repo: Path, kind: str, ref: str) -> None:
        self.git(repo, '-c', 'gpg.format=ssh', '-c', 'gpg.ssh.allowedSignersFile=' + self.manifest['allowedSigners'],
                 'verify-' + kind, ref)

    def _tag(self, sha: str, create=False) -> dict | None:
        repo, tag = self.source_repo, self.plan['releaseTag']
        self._origin(repo, REPOSITORY)
        ref = 'refs/tags/' + tag
        remote = self._remote(repo, ref)
        local = self.git(repo, 'rev-parse', '--verify', ref, check=False) or None
        if local is None and remote is not None and create:
            self.git(repo, 'fetch', '--no-tags', 'origin', ref + ':' + ref)
            local = self.git(repo, 'rev-parse', '--verify', ref)
        if local is None and create:
            if self.git(repo, 'status', '--porcelain'):
                raise controller.ControllerError('product source checkout is dirty')
            self.git(repo, '-c', 'gpg.format=ssh', '-c', 'user.name=' + self.manifest['authorName'],
                     '-c', 'user.email=' + self.manifest['authorEmail'],
                     'tag', '-s', tag, self.plan['sourceCommit'], '-m', 'container-compose ' + tag)
            local = self.git(repo, 'rev-parse', '--verify', ref)
        if local is None:
            return None
        if self.git(repo, 'cat-file', '-t', ref) != 'tag' or self.git(repo, 'rev-parse', ref + '^{commit}') != self.plan['sourceCommit']:
            raise controller.ControllerError('semantic tag is not annotated exact-source authority')
        self._signed(repo, 'tag', ref)
        if remote is not None and remote != local:
            raise controller.ControllerError('remote semantic tag differs; retagging is prohibited')
        if remote is None:
            if not create:
                return None
            self.git(repo, 'push', 'origin', ref + ':' + ref)
            if self._remote(repo, ref) != local:
                raise controller.ControllerError('signed tag push was not authenticated')
        return self.proof('tag', sha, signed=True, targetCommit=self.plan['sourceCommit'], tagObject=local)

    def release(self, *, missing=False) -> dict | None:
        release = self.gh('repos/' + REPOSITORY + '/releases/tags/' + self.plan['releaseTag'], missing=missing)
        if release is None:
            return None
        if (release['draft'] is not False or release.get('immutable') is not True
                or release['tag_name'] != self.plan['releaseTag']
                or self._libraries['assets'].tag_commit(REPOSITORY, self.plan['releaseTag']) != self.plan['sourceCommit']):
            raise controller.ControllerError('remote immutable release identity differs')
        entries = release['assets']
        if len(entries) != len(self.plan['assets']) or {row['name'] for row in entries} != set(self.plan['assets']):
            raise controller.ControllerError('remote release asset inventory differs')
        for row in entries:
            expected = self.plan['assets'][row['name']]
            if row['size'] != expected['bytes'] or row.get('digest') != 'sha256:' + expected['sha256']:
                raise controller.ControllerError('remote release asset digest/size differs')
        journal_path = self._libraries['assets'].publication_journal_path(
            self.journals, REPOSITORY, self.plan['releaseTag'], 'stable-' + self.plan['releaseTag'])
        journal = json.loads(finalizer.read(journal_path))
        if (journal['releaseId'] != release['id'] or release['body'] != journal['notesWithMarker']
                or journal['intent']['targetCommit'] != self.plan['sourceCommit']
                or journal['intent']['notes'] != self.manifest['notes']
                or journal['intent']['title'] != self.manifest['title']
                or {row['name']: row['id'] for row in entries} != journal['assetIds']):
            raise controller.ControllerError('release is not this durable owned publication')
        return release

    def _publication(self, sha: str, execute=False) -> dict | None:
        if execute:
            self._libraries['assets'].publish_assets(REPOSITORY, self.plan['releaseTag'], self.plan['sourceCommit'],
                self.manifest['title'], self.manifest['notes'], tuple(self.assets / name for name in sorted(self.plan['assets'])),
                resume=True, scratch=self.scratch, journal_root=self.journals, owner='stable-' + self.plan['releaseTag'])
        release = self.release(missing=not execute)
        if release is None:
            return None
        return self.proof('publication', sha, releaseId=release['id'], immutable=True, assets=self.plan['assets'],
                          assetIds={row['name']: row['id'] for row in release['assets']})

    def _download(self, sha: str, execute=False) -> dict | None:
        release = self.release()
        paths, receipts = {}, {}
        for row in release['assets']:
            name = row['name']
            lock = {'schema': 1, 'repository': REPOSITORY, 'tag': self.plan['releaseTag'],
                    'targetCommit': self.plan['sourceCommit'], 'asset': name,
                    'sha256': self.plan['assets'][name]['sha256']}
            lock_path = self.downloads / (name + '.lock.json')
            if lock_path.exists():
                if json.loads(finalizer.read(lock_path)) != lock:
                    raise controller.ControllerError('download lock changed')
            elif execute:
                finalizer.durable(lock_path, lock)
            else:
                return None
            destination = self.downloads / name
            if not destination.exists():
                if not execute:
                    return None
                with tempfile.TemporaryDirectory(prefix='stable-fetch-', dir=self.downloads) as temporary:
                    downloaded = Path(temporary) / 'asset'
                    receipt = self._libraries['assets'].fetch(lock_path, downloaded)
                    receipt['asset'] = str(destination / name)
                    finalizer.durable(downloaded / 'fetch-receipt.json', receipt)
                    downloaded.rename(destination)
            receipt_path = destination / 'fetch-receipt.json'
            receipt = json.loads(finalizer.read(receipt_path))
            asset_path = destination / name
            if (receipt['releaseId'] != release['id'] or receipt['assetId'] != row['id']
                    or receipt['asset'] != str(destination / name)
                    or receipt['sha256'] != lock['sha256'] or receipt['lockSHA256'] != finalizer.digest(finalizer.read(lock_path))
                    or receipt['targetCommit'] != self.plan['sourceCommit']
                    or receipt['repository'] != REPOSITORY or receipt['tag'] != self.plan['releaseTag']
                    or finalizer.file_digest(asset_path) != lock['sha256'] or asset_path.stat().st_size != self.plan['assets'][name]['bytes']):
                raise controller.ControllerError('downloaded release identity differs')
            paths[name] = destination / name
            receipts[name] = finalizer.digest(finalizer.read(receipt_path))
        self._admission(sha)
        request = json.loads(finalizer.read(Path(self.manifest['finalizationRequest'])))
        self.verify_archives(paths, request, self.runtime_payload)
        return self.proof('download', sha, releaseId=release['id'], assets=self.plan['assets'],
                          signaturesVerified=True, fetchReceiptsSHA256=receipts)

    def _installation(self, sha: str, execute=False) -> dict | None:
        output = Path(self.manifest['installationReceipt'])
        if not output.exists():
            if not execute:
                return None
            self._download(sha)
            m, p = self.manifest, self.plan
            self.run([sys.executable, m['installationAdapter'], '--context', m['installationContext'],
                      '--context-sha256', p['installationContextSHA256'], '--installation-core', m['installationCore'],
                      '--installation-core-sha256', p['installationCoreSHA256'], '--testing-root', m['testingRoot'],
                      '--test-tap', m['testTap'], '--ssd-scratch', m['installationScratch'],
                      '--retained-root', m['installationRetainedRoot'], '--receipt-output', str(output)], timeout=10800)
        data = finalizer.read(output)
        proof = self.proof('installation', sha, receipt=json.loads(data), receiptSHA256=finalizer.digest(data),
                           installationContextSHA256=self.plan['installationContextSHA256'],
                           installationCoreSHA256=self.plan['installationCoreSHA256'],
                           installationAdapterSHA256=self.plan['installationAdapterSHA256'])
        controller.proof_boundary('installation', proof, self.plan, sha)
        return proof

    def _tap(self, sha: str, execute=False) -> dict | None:
        self._origin(self.tap, TAP_REPOSITORY)
        baseline = self.manifest['tapBaselineCommit']
        intent_path = self.journals / ('stable-' + self.plan['releaseTag'] + '-tap.json')
        remote = self._remote(self.tap, 'refs/heads/main')
        head = self.git(self.tap, 'rev-parse', 'HEAD')
        if self.git(self.tap, 'symbolic-ref', '--short', 'HEAD') != 'main':
            raise controller.ControllerError('tap checkout is not main')
        intent = json.loads(finalizer.read(intent_path)) if intent_path.exists() else None
        if intent is None:
            if not execute:
                return None
            if head != baseline or remote != baseline or self.git(self.tap, 'status', '--porcelain'):
                raise controller.ControllerError('tap baseline is not clean/exact')
            intent = {'planSHA256': sha, 'baseline': baseline,
                      'before': {name: finalizer.digest(finalizer.read(self.tap / relative)) for name, relative in FORMULAE.items()}}
            finalizer.durable(intent_path, intent)
        if intent['planSHA256'] != sha or intent['baseline'] != baseline:
            raise controller.ControllerError('tap belongs to another release intent')
        if head == baseline:
            if not execute:
                return None
            if remote != baseline:
                raise controller.ControllerError('tap remote advanced during pair preparation')
            changed = self.git(self.tap, 'diff', '--name-only', 'HEAD').splitlines()
            untracked = self.git(self.tap, 'ls-files', '--others', '--exclude-standard')
            if set(changed) - set(FORMULAE.values()) or untracked:
                raise controller.ControllerError('tap contains foreign changes')
            for name, relative in FORMULAE.items():
                target = self.tap / relative
                if finalizer.digest(finalizer.read(target)) not in {intent['before'][name], self.plan['formulaPairSHA256'][name]}:
                    raise controller.ControllerError('tap partial write is not owned by this plan')
                shutil.copyfile(self.manifest['publicFormulas'][name], target)
            self.git(self.tap, 'add', '--', *FORMULAE.values())
            if self.git(self.tap, 'diff', '--cached', '--name-only').splitlines() != sorted(FORMULAE.values()):
                raise controller.ControllerError('atomic tap commit must change exactly two formulae')
            self.git(self.tap, '-c', 'gpg.format=ssh', '-c', 'user.name=' + self.manifest['authorName'],
                     '-c', 'user.email=' + self.manifest['authorEmail'], 'commit', '-S', '-m', 'chore(release): publish container-compose ' + self.plan['releaseTag'],
                     '-m', 'Stable release plan SHA-256: ' + sha)
            head = self.git(self.tap, 'rev-parse', 'HEAD')
        if (self.git(self.tap, 'rev-parse', head + '^') != baseline
                or self.git(self.tap, 'show', '-s', '--format=%B', head).splitlines()[-1] != 'Stable release plan SHA-256: ' + sha
                or self.git(self.tap, 'status', '--porcelain')
                or set(self.git(self.tap, 'diff-tree', '--no-commit-id', '--name-only', '-r', head).splitlines()) != set(FORMULAE.values())):
            raise controller.ControllerError('tap commit is not the one tested atomic pair')
        self._signed(self.tap, 'commit', head)
        for name, relative in FORMULAE.items():
            if finalizer.digest(finalizer.read(self.tap / relative)) != self.plan['formulaPairSHA256'][name]:
                raise controller.ControllerError('tested public tap formula bytes differ')
        if intent.get('tapCommit') not in (None, head):
            raise controller.ControllerError('retained tap commit differs')
        if execute:
            intent['tapCommit'] = head
            finalizer.durable(intent_path, intent)
        remote = self._remote(self.tap, 'refs/heads/main')
        if remote == baseline:
            if not execute:
                return None
            self.git(self.tap, 'push', 'origin', head + ':refs/heads/main')
            remote = self._remote(self.tap, 'refs/heads/main')
        if remote != head:
            raise controller.ControllerError('tap remote is not the tested signed pair commit')
        return self.proof('tap', sha, formulaPairSHA256=self.plan['formulaPairSHA256'], atomicPairCommit=True, tapCommit=head)

    def _promotion(self, sha: str, execute=False) -> dict | None:
        release = self.release()
        latest = self.gh('repos/' + REPOSITORY + '/releases/latest', missing=True)
        if release['prerelease'] is False and latest and latest['id'] == release['id']:
            return self.proof('promotion', sha, releaseId=release['id'], assets=self.plan['assets'], prerelease=False, latest=True)
        if not execute:
            return None
        self.gh('repos/' + REPOSITORY + '/releases/' + str(release['id']), body={'prerelease': False, 'make_latest': 'true'})
        result = self._promotion(sha)
        if result is None:
            raise controller.ControllerError('final stable/latest metadata was not authenticated')
        return result

    def inspect(self, phase: str, plan: dict, intent_sha: str) -> dict | None:
        self.verify_inputs()
        if phase == 'admission':
            return self._admission(intent_sha)
        if phase == 'tag':
            return self._tag(intent_sha)
        if phase == 'publication':
            # A draft is reconciled only through publish_assets' durable journal.
            raw = self.gh('repos/' + REPOSITORY + '/releases/tags/' + plan['releaseTag'], missing=True)
            return None if raw is None or raw['draft'] else self._publication(intent_sha)
        return getattr(self, '_' + phase)(intent_sha)

    def execute(self, phase: str, plan: dict, intent_sha: str, prior: dict) -> dict:
        self.verify_inputs()
        if phase == 'tag':
            return self._tag(intent_sha, create=True)
        if phase == 'publication' and self._tag(intent_sha) != prior['tag']:
            raise controller.ControllerError('tag authority changed before publication')
        if phase == 'tap':
            controller.proof_boundary('installation', prior['installation'], plan, intent_sha)
            self.validate('installation', prior['installation'], plan, intent_sha)
        if phase == 'promotion':
            for earlier in ('tag', 'publication', 'download', 'installation', 'tap'):
                self.validate(earlier, prior[earlier], plan, intent_sha)
        return getattr(self, '_' + phase)(intent_sha, execute=True)

    def recover(self, phase: str, plan: dict, intent_sha: str, prior: dict) -> dict | None:
        """Explicit owned tap recovery, called only under the controller lock."""
        if phase != 'tap' or not self.recover_owned_tap:
            return None
        path = self.journals / ('stable-' + plan['releaseTag'] + '-tap.json')
        if not path.exists():
            raise controller.ControllerError('owned tap recovery requires an existing adapter intent')
        intent = json.loads(finalizer.read(path))
        if intent.get('planSHA256') != intent_sha or intent.get('baseline') != self.manifest['tapBaselineCommit']:
            raise controller.ControllerError('owned tap recovery intent differs')
        for earlier in ('admission', 'tag', 'publication', 'download', 'installation'):
            self.validate(earlier, prior[earlier], plan, intent_sha)
        return self.execute('tap', plan, intent_sha, prior)

    def validate(self, phase: str, proof: dict, plan: dict, intent_sha: str) -> None:
        controller.proof_boundary(phase, proof, plan, intent_sha)
        actual = self.inspect(phase, plan, intent_sha)
        if actual != proof:
            raise controller.ControllerError('retained phase proof no longer matches actual state: ' + phase)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--plan-sha256', required=True)
    parser.add_argument('--execution-manifest', type=Path, required=True)
    parser.add_argument('--execution-manifest-sha256', required=True)
    parser.add_argument('--journal', type=Path, required=True)
    parser.add_argument('--recover-owned-tap', action='store_true',
                        help='reconcile only this preexisting signed pair intent under the controller lock')
    args = parser.parse_args()
    plan_data, manifest_data = finalizer.read(args.plan), finalizer.read(args.execution_manifest)
    if finalizer.digest(plan_data) != args.plan_sha256 or finalizer.digest(manifest_data) != args.execution_manifest_sha256:
        raise controller.ControllerError('reviewed plan/manifest bytes differ')
    plan, manifest = json.loads(plan_data), json.loads(manifest_data)
    controller.validate_plan(plan)
    operations = ProductionOperations(plan, manifest, args.execution_manifest_sha256, manifest_path=args.execution_manifest, recover_owned_tap=args.recover_owned_tap)
    result = controller.execute(plan, args.journal, operations)
    print(json.dumps({'complete': result.get('complete') is True, 'releaseTag': plan['releaseTag'],
                      'sourceCommit': plan['sourceCommit'], 'planSHA256': result['planSHA256']}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit('stable Compose release stopped: ' + str(error)) from error
