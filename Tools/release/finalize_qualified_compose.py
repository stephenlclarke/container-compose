#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Stage stable metadata from admitted Compose bytes; never publish or rebuild.

A completed, independently reviewed legal closure is mandatory. This validates
its bindings, not the legal sufficiency of its contents. Unknown notary submission
outcomes fail closed and require operator reconciliation, never automatic retry.
"""
from __future__ import annotations

import argparse
import hashlib
import gzip
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import uuid
import zipfile

SHA = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')
BUILD_INFO = 'resources/build-info.json'
MACHO = ('bin/compose', 'resources/compose-normalizer')
ELF = tuple('resources/volume-initializer/compose-volume-initializer-linux-' + arch
            for arch in ('arm64', 'amd64'))
TAR_NAME = 'container-compose-plugin-release-arm64.tar.gz'


class FinalizationError(ValueError):
    """A release boundary was not authenticated."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def read(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or path.resolve() != path:
        raise FinalizationError('input is missing or aliased')
    return path.read_bytes()


def durable(path: Path, value: dict) -> None:
    temporary = path.with_name('.' + path.name + '-' + uuid.uuid4().hex)
    with temporary.open('xb') as stream:
        os.chmod(temporary, 0o600)
        stream.write(canonical(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def archive_files(path: Path) -> dict[str, tuple[bytes, int]]:
    result = {}
    with zipfile.ZipFile(path) as archive:
        names = set()
        total = 0
        for entry in archive.infolist():
            raw = entry.filename
            name = PurePosixPath(raw)
            mode = entry.external_attr >> 16
            if (raw in names or name.is_absolute() or '..' in name.parts
                    or '\\' in raw or not name.parts or name.parts[0] != 'compose'
                    or raw.rstrip('/') != name.as_posix()
                    or stat.S_ISLNK(mode)
                    or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                raise FinalizationError('unsafe or duplicate archive member')
            names.add(raw)
            total += entry.file_size
            if total > 536870912 or len(names) > 10000:
                raise FinalizationError('archive exceeds bounded staging limits')
            if entry.is_dir():
                continue
            if len(name.parts) < 2:
                raise FinalizationError('archive member outside plugin')
            relative = str(PurePosixPath(*name.parts[1:]))
            result[relative] = (archive.read(entry), stat.S_IMODE(mode))
    return result


def file_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file() or path.resolve() != path:
        raise FinalizationError('external source companion is missing or aliased')
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def legal_files(closure: Path | None, expected_sha: str, admitted: dict,
                info: dict, release_version: str | None = None) -> dict[str, bytes]:
    if closure is None or not SHA.fullmatch(expected_sha):
        raise FinalizationError('reviewed legal closure is required')
    payload = read(closure)
    if digest(payload) != expected_sha:
        raise FinalizationError('legal closure checksum differs')
    value = json.loads(payload)
    unsigned = admitted['unsignedCandidate']['receipt']
    expected = {'sourceCommit': admitted['source'], 'runtimeProfile': 'enhanced',
                'dependencyLockSHA256': unsigned['dependencyLockSHA256'],
                'dependencyNoticesSHA256': admitted['noticeInventorySHA256'],
                'compiledSdkChain': admitted['compiledSdkChain'],
                'containerSource': info['containerSource'], 'containerRef': info['containerRef'],
                'containerizationSource': info['containerizationSource'],
                'containerizationRef': info['containerizationRef']}
    if (value.get('schemaVersion') != 1 or value.get('scope') != 'reviewed-compose-legal-closure'
            or value.get('closureComplete') is not True or value.get('bindings') != expected
            or not isinstance(value.get('reviewer'), str) or not value['reviewer'].strip()
            or not isinstance(value.get('files'), dict) or not value['files']
            or value.get('reviewEvidence') not in value['files']):
        raise FinalizationError('legal closure is incomplete or bound to different inputs')
    files = {}
    for name, claim in value['files'].items():
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', name) is None:
            raise FinalizationError('legal sidecar name is unsafe')
        data = read(closure.parent / name)
        if claim != {'sha256': digest(data), 'bytes': len(data)}:
            raise FinalizationError('legal sidecar checksum or size differs')
        files['resources/legal/' + name] = data
    external = value.get('externalSourceCompanion')
    if external is not None:
        name = 'compose-source-companion.tar.gz'
        expected_url = ('https://github.com/stephenlclarke/container-compose/releases/download/'
                        + str(release_version) + '/' + name)
        if (not isinstance(external, dict) or set(external) != {'asset', 'sha256', 'bytes', 'url'}
                or external.get('asset') != name or external.get('url') != expected_url
                or not SHA.fullmatch(external.get('sha256', ''))
                or type(external.get('bytes')) is not int or external['bytes'] <= 0
                or name in value['files']
                or value.get('sourceAvailabilityNotice') not in value['files']):
            raise FinalizationError('external source companion claim or availability notice differs')
        companion = closure.parent / name
        if file_digest(companion) != external['sha256'] or companion.stat().st_size != external['bytes']:
            raise FinalizationError('external source companion checksum or size differs')
        notice = files['resources/legal/' + value['sourceAvailabilityNotice']].decode('utf-8')
        if expected_url not in notice or external['sha256'] not in notice:
            raise FinalizationError('source availability notice lacks exact companion binding')
    files['resources/legal/closure.json'] = payload
    if 'closure.json' in value['files']:
        raise FinalizationError('reserved legal sidecar name')
    return files


def invoke(arguments: list[str], timeout: int = 60) -> str:
    return subprocess.check_output(arguments, text=True, timeout=timeout)


def stage(evidence: Path, output: Path, source: str, tool_commit: str, version: str,
          closure: Path | None, closure_sha: str, *, admit, run=invoke) -> dict:
    if not COMMIT.fullmatch(source) or not COMMIT.fullmatch(tool_commit) or not VERSION.fullmatch(version):
        raise FinalizationError('source, tool commit or semantic version is invalid')
    admitted = admit(evidence)
    if (admitted['source'] != source or admitted.get('signedAndNotarized') is not True
            or admitted['unsignedCandidate']['receipt']['runtimeProfile'] != 'enhanced'):
        raise FinalizationError('qualification source/profile differs')
    original_archive = evidence / 'signed-compose.zip'
    if digest(read(original_archive)) != admitted['signedArchiveSHA256']:
        raise FinalizationError('qualified archive changed')
    original = archive_files(original_archive)
    # The qualification library excludes AppleDouble siblings from its signed
    # payload inventory. The original ZIP hash authenticates those siblings;
    # retain their bytes/modes in both final archives rather than discarding them.
    if {name: digest(data) for name, (data, _) in original.items()
            if not PurePosixPath(name).name.startswith('._')} != admitted['signedTree']:
        raise FinalizationError('qualified archive tree differs')
    for name in (*MACHO, *ELF):
        if name not in original or not original[name][1] & 0o111:
            raise FinalizationError('qualified executable mode is missing')
    if any(not original[name][0].startswith(b'\x7fELF') for name in ELF):
        raise FinalizationError('qualified Linux initializer is not ELF')
    info = json.loads(original[BUILD_INFO][0])
    if info.get('commit') != source or info.get('lane') != 'candidate' or info.get('buildType') != 'release':
        raise FinalizationError('qualified build identity differs')
    legal = legal_files(closure, closure_sha, admitted, info, version)
    if set(legal) & set(original):
        raise FinalizationError('legal sidecar replaces qualified content')
    final_info = dict(info, version=version, lane='stable', branch=version)
    final = dict(original)
    final[BUILD_INFO] = (canonical(final_info), original[BUILD_INFO][1])
    final.update({name: (data, 0o644) for name, data in legal.items()})
    request = {'schemaVersion': 1, 'scope': 'compose-stable-finalization-request',
               'sourceCommit': source, 'toolCommit': tool_commit, 'releaseTag': version,
               'finalizerSHA256': digest(read(Path(__file__).resolve())),
               'admissionLibrarySHA256': digest(read(Path(sys.modules[admit.__module__].__file__).resolve())),
               'qualificationSHA256': digest(read(evidence / 'acceptance.json')),
               'qualifiedArchiveSHA256': admitted['signedArchiveSHA256'],
               'legalClosureSHA256': closure_sha,
               'externalSourceCompanion': json.loads(read(closure)).get('externalSourceCompanion'),
               'originalTree': admitted['signedTree'],
               'finalTree': {name: digest(data) for name, (data, _) in final.items()},
               'metadataBefore': info, 'metadataAfter': final_info,
               'legalClosureComplete': True, 'runtimeProfile': 'enhanced'}
    if output.exists():
        if json.loads(read(output / 'request.json')) != request:
            raise FinalizationError('finalization directory belongs to different inputs')
        if not (output / 'stage.json').exists():
            raise FinalizationError('incomplete staging requires operator reconciliation')
        record = json.loads(read(output / 'stage.json'))
        if (record['requestSHA256'] != digest(canonical(request))
                or digest(read(output / 'compose-stable.zip')) != record['archiveSHA256']
                or archive_files(output / 'compose-stable.zip') != final
                or digest(read(output / TAR_NAME)) != record['tarSHA256']):
            raise FinalizationError('retained final archive changed')
        return record
    if not output.is_absolute() or output.resolve() != output:
        raise FinalizationError('output must be a canonical fresh absolute directory')
    output.mkdir(mode=0o700)
    durable(output / 'request.json', request)
    plugin = output / 'compose'
    for name, (data, mode) in final.items():
        target = plugin / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(mode)
    for name in MACHO:
        run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(plugin / name)], 30)
    env = dict(os.environ)
    env.pop('CONTAINER_COMPOSE_BUILD_INFO', None)
    # The production adapter passes a reduced environment; injected tests model
    # the immutable CLI responses without executing fixture bytes.
    if run is invoke:
        def cli(arguments):
            return subprocess.check_output(arguments, env=env, text=True, timeout=30)
    else:
        def cli(arguments):
            return run(arguments, 30)
    executable = str(plugin / 'bin/compose')
    if cli([executable, 'version', '--short']).strip() != version:
        raise FinalizationError('final CLI semantic version differs')
    observed = json.loads(cli([executable, 'version', '--format', 'json']))
    if any(observed.get(key) != final_info[key] for key in ('version', 'commit', 'lane', 'branch', 'buildType',
                                                                'containerSource', 'containerRef',
                                                                'containerizationSource', 'containerizationRef')):
        raise FinalizationError('final CLI identity differs')
    if {name: digest(read(plugin / name)) for name in final} != request['finalTree']:
        raise FinalizationError('final stage changed during verification')
    archive_path = output / 'compose-stable.zip'
    with zipfile.ZipFile(archive_path, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, (data, mode) in sorted(final.items()):
            entry = zipfile.ZipInfo('compose/' + name, (2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    with archive_path.open('rb') as stream:
        os.fsync(stream.fileno())
    if archive_files(archive_path) != final:
        raise FinalizationError('final ZIP content differs')
    tar_path = output / TAR_NAME
    with tar_path.open('xb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, (data, mode) in sorted(final.items()):
                    entry = tarfile.TarInfo('compose/' + name)
                    entry.mode = mode
                    entry.size = len(data)
                    entry.mtime = 0
                    archive.addfile(entry, io.BytesIO(data))
        raw.flush()
        os.fsync(raw.fileno())
    with tarfile.open(tar_path, 'r:gz') as archive:
        extracted = {str(PurePosixPath(*PurePosixPath(member.name).parts[1:])):
                     (archive.extractfile(member).read(), member.mode)
                     for member in archive.getmembers()}
    if extracted != final:
        raise FinalizationError('final installation TAR content differs')
    record = {'schemaVersion': 1, 'requestSHA256': digest(canonical(request)),
              'archiveSHA256': digest(read(archive_path)),
              'tarSHA256': digest(read(tar_path)), 'tarBytes': tar_path.stat().st_size,
              'sourceCommit': source,
              'toolCommit': tool_commit, 'releaseTag': version, 'staged': True}
    durable(output / 'stage.json', record)
    return record


def notarize(output: Path, profile: str, *, run=invoke) -> dict:
    request = json.loads(read(output / 'request.json'))
    staged = json.loads(read(output / 'stage.json'))
    archive = output / 'compose-stable.zip'
    if (staged['requestSHA256'] != digest(canonical(request))
            or digest(read(archive)) != staged['archiveSHA256']
            or digest(read(output / TAR_NAME)) != staged['tarSHA256']):
        raise FinalizationError('notary input changed')
    state = output / 'notary.json'
    record = json.loads(read(state)) if state.exists() else None
    binding = {'archiveSHA256': staged['archiveSHA256'], 'requestSHA256': staged['requestSHA256']}
    if record is not None and any(record.get(key) != value for key, value in binding.items()):
        raise FinalizationError('notary state belongs to different inputs')
    if record is not None and record.get('status') == 'Accepted':
        return authority(output, request, staged, record)
    if record is None:
        # An intent without a persisted submission ID is deliberately not retried.
        record = dict(binding, status='Submitting', submissionId=None)
        durable(state, record)
        response = json.loads(run(['/usr/bin/xcrun', 'notarytool', 'submit', str(archive),
                                   '--keychain-profile', profile, '--output-format', 'json'], 180))
        identifier = response.get('id')
        if not isinstance(identifier, str) or not re.fullmatch(r'[0-9a-fA-F-]{36}', identifier):
            raise FinalizationError('notary submission identity is unavailable')
        record.update(submissionId=identifier, status='Submitted')
        durable(state, record)
    if record.get('status') not in {'Submitted', 'In Progress'} or not record.get('submissionId'):
        raise FinalizationError('uncertain or rejected notary submission requires reconciliation')
    response = json.loads(run(['/usr/bin/xcrun', 'notarytool', 'wait', record['submissionId'],
                               '--keychain-profile', profile, '--output-format', 'json'], 3600))
    if response.get('id') != record['submissionId']:
        raise FinalizationError('notary response identity differs')
    record['status'] = response.get('status')
    durable(state, record)
    if record['status'] != 'Accepted':
        raise FinalizationError('final archive was not accepted')
    return authority(output, request, staged, record)


def authority(output: Path, request: dict, staged: dict, notary: dict) -> dict:
    if (notary.get('status') != 'Accepted'
            or not re.fullmatch(r'[0-9a-fA-F-]{36}', notary.get('submissionId', ''))):
        raise FinalizationError('accepted submission identity is incomplete')
    value = {'schemaVersion': 1, 'scope': 'bazel-compose-stable-archive-authority',
             'sourceCommit': request['sourceCommit'], 'toolCommit': request['toolCommit'],
             'releaseTag': request['releaseTag'], 'runtimeProfile': 'enhanced',
             'requestSHA256': staged['requestSHA256'], 'archiveSHA256': staged['archiveSHA256'],
             'finalizerSHA256': request['finalizerSHA256'],
             'admissionLibrarySHA256': request['admissionLibrarySHA256'],
             'installationArchive': TAR_NAME, 'tarSHA256': staged['tarSHA256'],
             'tarBytes': staged['tarBytes'],
             'qualificationSHA256': request['qualificationSHA256'],
             'legalClosureSHA256': request['legalClosureSHA256'],
             'externalSourceCompanion': request.get('externalSourceCompanion'),
             'notarySubmissionId': notary['submissionId'], 'notaryStatus': 'Accepted',
             'archiveReady': True, 'publicationAuthorized': False,
             'installationAndRestorationPending': True, 'signedTagVerified': False}
    durable(output / 'authority.json', value)
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--tool-commit', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--legal-closure', type=Path)
    parser.add_argument('--legal-closure-sha256', default='')
    parser.add_argument('--notary-profile')
    args = parser.parse_args()
    actual = invoke(['git', '-C', str(args.checkout), 'rev-parse', 'HEAD']).strip()
    if actual != args.tool_commit or invoke(['git', '-C', str(args.checkout), 'status', '--porcelain']).strip():
        raise FinalizationError('qualification tooling checkout is not clean and pinned')
    sys.path.insert(0, str(args.checkout / 'Tools/bazel'))
    import compose_release
    stage(args.evidence, args.output, args.source_commit, args.tool_commit, args.version,
          args.legal_closure, args.legal_closure_sha256, admit=compose_release.admit)
    if args.notary_profile:
        notarize(args.output, args.notary_profile)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit('stable Compose finalization failed: ' + str(error)) from error
