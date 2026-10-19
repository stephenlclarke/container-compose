#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Durable stable publication ordering around product-specific release adapters.

This coordinator has no default external operations. The root executor supplies
real adapters implementing the contracts in CONTROLLER.md. Production adapters
must reconcile remote state, never repeat an uncertain installation or tap push.
"""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import re
from typing import Protocol

from finalize_qualified_compose import canonical, digest, durable, read

PHASES = ('admission', 'tag', 'publication', 'download', 'installation', 'tap', 'promotion')


class ControllerError(ValueError):
    """Release state or independently verifiable proof differs."""


class Operations(Protocol):
    """Root-owned adapters authenticate all proof bytes and remote identities."""

    def inspect(self, phase: str, plan: dict, intent_sha: str) -> dict | None:
        """Return independently authenticated existing proof, or None if absent."""

    def execute(self, phase: str, plan: dict, intent_sha: str, prior: dict) -> dict:
        """Perform/reconcile one operation; installation never repeats implicitly."""

    def validate(self, phase: str, proof: dict, plan: dict, intent_sha: str) -> None:
        """Re-admit proof and actual bytes/state; raise on any discrepancy."""


def validate_plan(plan: dict) -> None:
    if (plan.get('schemaVersion') != 1 or plan.get('scope') != 'bazel-compose-stable-release-plan'
            or plan.get('repository') != 'stephenlclarke/container-compose'
            or re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', plan.get('releaseTag', '')) is None
            or any(re.fullmatch(r'[0-9a-f]{40}', plan.get(key, '')) is None
                   for key in ('sourceCommit', 'toolCommit'))
            or plan.get('runtimeProfile') != 'enhanced'
            or plan.get('runtimeQualifiedSource') != 'f86fea2236fab118c0e0c6f8be5eb7672df894e2'
            or plan.get('legacyStableGateClaim') is not False
            or plan.get('legalClosureComplete') is not True
            or plan.get('runtimeFormulaVersion') != plan.get('releaseTag')
            or plan.get('runtimeProductVersion') != '0.0.0'
            or not isinstance(plan.get('assets'), dict) or not plan['assets']):
        raise ControllerError('stable release plan is incomplete')
    required = {'container-compose-plugin-release-arm64.tar.gz', 'container-release-arm64.tar.gz',
                'compose-stable-archive-authority.json', 'compose-stable-provenance.json',
                'compose-final-notarization.json', 'compose-qualified-evidence-v1.zip',
                'compose-reviewed-legal-closure.json', 'compose-runtime-pair-provenance.json',
                'container-compose-plugin-release-arm64.tar.gz.sha256',
                'container-release-arm64.tar.gz.sha256'}
    external = plan.get('externalSourceCompanion')
    if external is not None:
        expected_url = ('https://github.com/stephenlclarke/container-compose/releases/download/'
                        + plan['releaseTag'] + '/compose-source-companion.tar.gz')
        if (not isinstance(external, dict) or external.get('asset') != 'compose-source-companion.tar.gz'
                or external.get('url') != expected_url
                or plan['assets'].get(external['asset']) !=
                {'sha256': external.get('sha256'), 'bytes': external.get('bytes')}):
            raise ControllerError('external source companion is not in exact release inventory')
    if not required.issubset(plan['assets']):
        raise ControllerError('stable publication asset closure is incomplete')
    for name, claim in plan['assets'].items():
        if (re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) is None
                or set(claim) != {'sha256', 'bytes'}
                or re.fullmatch(r'[0-9a-f]{64}', claim['sha256']) is None
                or type(claim['bytes']) is not int or claim['bytes'] <= 0):
            raise ControllerError('asset inventory is malformed')
    if (not isinstance(plan.get('formulaPairSHA256'), dict)
            or set(plan['formulaPairSHA256']) != {'container', 'container-compose'}
            or any(not isinstance(key, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None
                   for key, value in plan['formulaPairSHA256'].items())):
        raise ControllerError('formula pair must name exactly two frozen formula hashes')
    for key in ('qualificationSHA256', 'legalClosureSHA256', 'archiveAuthoritySHA256',
                'runtimeArchiveSHA256', 'composeArchiveSHA256',
                'installationContextSHA256', 'installationCoreSHA256',
                'installationAdapterSHA256', 'runtimeBinarySHA256', 'composeBinarySHA256'):
        if re.fullmatch(r'[0-9a-f]{64}', plan.get(key, '')) is None:
            raise ControllerError('plan lacks exact release bindings')
    if (plan['runtimeArchiveSHA256'] != plan['assets']['container-release-arm64.tar.gz']['sha256']
            or plan['composeArchiveSHA256'] != plan['assets']['container-compose-plugin-release-arm64.tar.gz']['sha256']):
        raise ControllerError('pair archive hashes differ from release inventory')


def proof_boundary(phase: str, proof: dict, plan: dict, intent_sha: str) -> None:
    if (proof.get('planSHA256') != intent_sha or proof.get('phase') != phase
            or proof.get('passed') is not True):
        raise ControllerError('phase proof is not bound to this admitted plan')
    if phase == 'tag' and (proof.get('signed') is not True
                            or proof.get('targetCommit') != plan['sourceCommit']
                            or not re.fullmatch(r'[0-9a-f]{40}', proof.get('tagObject', ''))):
        raise ControllerError('signed exact-source tag authority is absent')
    if phase == 'publication' and (type(proof.get('releaseId')) is not int
                                    or proof.get('immutable') is not True
                                    or proof.get('assets') != plan['assets']):
        raise ControllerError('immutable staged release proof is incomplete')
    if phase == 'download' and (proof.get('assets') != plan['assets']
                                 or proof.get('signaturesVerified') is not True):
        raise ControllerError('downloaded hash/signature verification is incomplete')
    if phase == 'installation':
        receipt = proof.get('receipt', {})
        if (receipt.get('scope') != 'compose-homebrew-formula-pair-installation-test'
                or receipt.get('status') != 'passed-restored'
                or receipt.get('sourceCommit') != plan['sourceCommit']
                or receipt.get('productVersion') != plan['releaseTag']
                or receipt.get('runtimeSourceCommit') != plan['runtimeQualifiedSource']
                or receipt.get('runtimeVersion') != plan.get('runtimeFormulaVersion')
                or receipt.get('runtimeProductVersion') != plan.get('runtimeProductVersion')
                or receipt.get('installedRuntimeProduct') !=
                {'productVersion': plan.get('runtimeProductVersion'), 'sourceCommit': plan['runtimeQualifiedSource']}
                or receipt.get('baselineRestored') is not True
                or receipt.get('guardAbsent') is not True
                or receipt.get('ownedPluginRegistrationOnly') is not True
                or receipt.get('ownedPluginRegistrationExecuted') is not True
                or receipt.get('broadPostInstallStopExecuted') is not False
                or receipt.get('releaseAuthority') is not False
                or receipt.get('runtimeArchiveSHA256') != plan['runtimeArchiveSHA256']
                or receipt.get('composeArchiveSHA256') != plan['composeArchiveSHA256']
                or receipt.get('formulaPairSHA256') != plan['formulaPairSHA256']
                or receipt.get('runtimeBinarySHA256') != plan['runtimeBinarySHA256']
                or receipt.get('composeBinarySHA256') != plan['composeBinarySHA256']
                or re.fullmatch(r'[0-9a-f]{64}', receipt.get('beforeInventorySHA256', '')) is None
                or receipt.get('beforeInventorySHA256') != receipt.get('afterInventorySHA256')
                or proof.get('installationContextSHA256') != plan['installationContextSHA256']
                or proof.get('installationCoreSHA256') != plan['installationCoreSHA256']
                or proof.get('installationAdapterSHA256') != plan['installationAdapterSHA256']):
            raise ControllerError('matched pair installation/restoration proof is incomplete')
    if phase == 'tap' and (proof.get('formulaPairSHA256') != plan['formulaPairSHA256']
                            or proof.get('atomicPairCommit') is not True
                            or not re.fullmatch(r'[0-9a-f]{40}', proof.get('tapCommit', ''))):
        raise ControllerError('tested atomic tap pair proof is incomplete')
    if phase == 'promotion' and (proof.get('prerelease') is not False
                                  or proof.get('latest') is not True
                                  or proof.get('assets') != plan['assets']):
        raise ControllerError('stable latest metadata proof is incomplete')


def execute(plan: dict, journal: Path, operations: Operations) -> dict:
    """Advance authenticated phases, safely reconciling interrupted operations.

    A phase with durable intent but no proof is inspected first. Publication and
    tag adapters can safely reconcile using remote identities and their journals;
    uncertain installation or tap mutation is never automatically executed again.
    """
    validate_plan(plan)
    if not journal.is_absolute() or journal.resolve() != journal or journal.parent.is_symlink():
        raise ControllerError('journal must be a canonical absolute private path')
    parent = journal.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise ControllerError('journal parent must be private and owned')
    descriptor = os.open(journal.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        lock_info = os.fstat(descriptor)
        if lock_info.st_uid != os.getuid() or lock_info.st_nlink != 1 or lock_info.st_mode & 0o077:
            raise ControllerError('release controller lock is not private and owned')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        intent_sha = digest(canonical(plan))
        state = json.loads(read(journal)) if journal.exists() else {
            'schemaVersion': 1, 'plan': plan, 'planSHA256': intent_sha, 'phases': {}}
        if state.get('plan') != plan or state.get('planSHA256') != intent_sha:
            raise ControllerError('release intent differs from durable journal')
        durable(journal, state)
        for phase in PHASES:
            retained = state['phases'].get(phase)
            if retained and retained.get('proof') is not None:
                proof = retained['proof']
                proof_boundary(phase, proof, plan, intent_sha)
                operations.validate(phase, proof, plan, intent_sha)
                continue
            prior = {name: row['proof'] for name, row in state['phases'].items() if 'proof' in row}
            proof = operations.inspect(phase, plan, intent_sha)
            if proof is None:
                if retained is not None and phase in {'installation', 'tap'}:
                    recover = getattr(operations, 'recover', None)
                    proof = recover(phase, plan, intent_sha, prior) if recover is not None else None
                    if proof is None:
                        raise ControllerError('uncertain ' + phase + ' requires adapter reconciliation')
                else:
                    state['phases'][phase] = {'intent': True}
                    durable(journal, state)
                    proof = operations.execute(phase, plan, intent_sha, prior)
            proof_boundary(phase, proof, plan, intent_sha)
            operations.validate(phase, proof, plan, intent_sha)
            if phase == 'promotion' and proof.get('releaseId') != prior['publication']['releaseId']:
                raise ControllerError('promotion changed release identity')
            state['phases'][phase] = {'proof': proof}
            durable(journal, state)
        state['complete'] = True
        durable(journal, state)
        return state
    finally:
        os.close(descriptor)
