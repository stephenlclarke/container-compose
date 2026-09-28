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

"""Exact original parity inventory and fail-closed per-case resource journal."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
NAME = re.compile(r'[a-z0-9][a-z0-9_.-]*\Z')
PROJECT = re.compile(r'^\s*(?:readonly\s+)?(?:[A-Z_]*PROJECT(?:_NAME|_PREFIX)?)=["\']([a-z0-9][a-z0-9-]*)', re.M)
PROJECT_DECLARATION = re.compile(
    r'^\s*(?:readonly\s+)?(?:[A-Z_]*PROJECT(?:_NAME|_PREFIX)?)=["\']([^"\']+)["\']', re.M)
EXTRA_PREFIXES = {
    'docker-compose-health-wait-parity': ('health-docker-', 'health-container-'),
    'docker-compose-lifecycle-hooks-parity': ('cc-lc-ds-', 'cc-lc-df-', 'cc-lc-dr-',
                                               'cc-lc-as-', 'cc-lc-af-', 'cc-lc-ar-'),
    'docker-compose-signal-log-reliability-parity': ('cc-sl-d-', 'cc-sl-a-'),
    'docker-compose-links-parity': ('cc-links-d-', 'cc-links-a-'),
    'docker-compose-network-service-discovery-parity': ('cc-dns-d-', 'cc-dns-a-'),
    'docker-compose-api-socket-client-parity': ('cc-api-socket-',),
    'docker-compose-build-secret-metadata-parity': ('compose-build-secret-metadata.',),
}
EXTRA_IMAGE_PREFIXES = {
    'runtime-suite': ('container-compose-named-builder:', 'registry.local/compose-ssh:',
                      'registry.local/compose-ssh-named:',
                      'registry.local/compose-ssh-multiple:'),
    'docker-compose-commit-parity': ('example/commit-parity-docker-base-',
                                     'example/commit-parity-docker-',
                                     'example/commit-parity-runtime-base-',
                                     'example/commit-parity-runtime-'),
    'docker-compose-build-external-dockerfile-parity': (
        'container-compose-external-dockerfile:latest',),
    'docker-compose-build-no-cache-filter-parity': (
        'container-compose-no-cache-filter:latest',),
    'docker-compose-build-external-secret-parity': (
        'container-compose-external-build-secret-cfq',),
}
FIXED_OUTPUT_IMAGES = {
    'docker-compose-build-external-dockerfile-parity':
        ('container-compose-external-dockerfile:latest',),
    'docker-compose-build-no-cache-filter-parity':
        ('container-compose-no-cache-filter:latest',),
}
BUILD_CASES = {
    'runtime-suite', 'docker-compose-image-volumes-parity',
    'docker-compose-commit-parity', 'docker-compose-create-options-parity',
    'docker-compose-build-builder-parity', 'docker-compose-build-check-parity',
    'docker-compose-build-external-dockerfile-parity',
    'docker-compose-build-external-secret-parity',
    'docker-compose-build-isolation-parity',
    'docker-compose-build-no-cache-filter-parity',
    'docker-compose-build-secret-metadata-parity',
}
NAMED_RUNTIME_BUILDER = re.compile(
    r'buildkit-compose-runtime-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\Z')


def authorized_builder(name: str, case: str) -> bool:
    return (case in BUILD_CASES and
            (name == 'buildkit' or (case == 'runtime-suite' and
                                     NAMED_RUNTIME_BUILDER.fullmatch(name) is not None)))


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, data: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def record_image_volume_mounts(project: str, destination: Path,
                               *, allow_partial: bool = False) -> None:
    """Persist Docker's exact project volume mounts before the leaf can down."""
    if (not re.fullmatch(r'container-compose-image-volumes-[0-9]+-[0-9]+', project)
            or not destination.is_absolute() or not destination.parent.is_dir()
            or destination.exists() or destination.is_symlink()):
        raise RuntimeError('Image-volume mount journal path/project is not fresh and exact')
    ids = subprocess.check_output(
        ['docker', '--context', 'colima', 'ps', '-aq', '--filter',
         'label=com.docker.compose.project=' + project], text=True, timeout=30).splitlines()
    if ((not allow_partial and len(ids) != 10) or len(ids) > 10
            or len(set(ids)) != len(ids)):
        raise RuntimeError('Image-volume mount journal found an invalid owned container count')
    rows = (json.loads(subprocess.check_output(
        ['docker', '--context', 'colima', 'container', 'inspect', *ids],
        text=True, timeout=30)) if ids else [])
    if len(rows) != len(ids):
        raise RuntimeError('Image-volume Docker container inventory changed')
    volumes = []
    for row in rows:
        name = row.get('Name', '').lstrip('/')
        if (not name.startswith(project + '-') or
                row.get('Config', {}).get('Labels', {}).get('com.docker.compose.project') != project):
            raise RuntimeError('Image-volume mount inventory includes a different owner')
        volumes.extend(mount['Name'] for mount in row.get('Mounts', [])
                       if mount.get('Type') == 'volume' and mount.get('Name'))
    write(destination, {'schema': 1, 'project': project,
                        'container_ids': sorted(ids), 'volumes': sorted(set(volumes))})


def inventory(root: Path = ROOT) -> list[dict]:
    text = (root / 'Makefile').read_text()
    match = re.search(r'^DOCKER_COMPOSE_PARITY_TARGETS := \\\n((?:[^\n]*\n)+?)\n', text, re.M)
    if match is None:
        raise RuntimeError('Original Docker Compose parity inventory is missing')
    targets = [row.strip().removesuffix('\\').strip() for row in match[1].splitlines()]
    if len(targets) != 66 or len(set(targets)) != 66:
        raise RuntimeError('Original Docker Compose parity inventory changed without review')
    result = []
    for target in targets:
        if not re.fullmatch(r'docker-compose-[a-z0-9-]+-parity', target):
            raise RuntimeError('Unexpected original parity target: ' + target)
        suffix = target.removeprefix('docker-compose-').removesuffix('-parity')
        script = root / 'Tools/parity' / ('check-compose-' + suffix + '.sh')
        if not script.is_file():
            raise RuntimeError('Original parity script is missing: ' + str(script))
        script_text = script.read_text()
        prefixes = sorted(set(PROJECT.findall(script_text))
                          | set(EXTRA_PREFIXES.get(target, ())))
        fixed_names = sorted(set(value for value in PROJECT_DECLARATION.findall(script_text)
                                 if '$' not in value))
        result.append({'target': target, 'script': str(script),
                       'script_sha256': sha(script), 'owned_prefixes': prefixes,
                       'fixed_names': fixed_names,
                       'owned_image_prefixes': list(EXTRA_IMAGE_PREFIXES.get(target, ()))})
    return result


def native_containers(text: str) -> dict[str, str]:
    rows = json.loads(text)
    if not isinstance(rows, list):
        raise RuntimeError('Native inventory is not a list')
    result = {}
    for row in rows:
        identity = row.get('id')
        name = row.get('name') or row.get('configuration', {}).get('id')
        if not identity or not name or identity in result:
            raise RuntimeError('Native container inventory omitted a unique ID/name')
        result[identity] = name
    return result


def docker_containers(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or parts[0] in result:
            raise RuntimeError('Docker inventory omitted a unique ID/name')
        result[parts[0]] = parts[1]
    return result


def names(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        name = line.strip()
        if not NAME.fullmatch(name) or name in result:
            raise RuntimeError('Resource inventory contained an invalid or repeated name')
        result[name] = name
    return result


def docker_images(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not re.fullmatch(r'sha256:[0-9a-f]{64}', parts[1]):
            raise RuntimeError('Docker image inventory omitted a unique repository/tag and ID')
        reference, identity = parts
        # The Engine may repeat one RepoTag within one image summary. Preserve
        # each distinct platform ID, while collapsing only an identical row.
        result[reference + '|' + identity] = reference
    return result


def identities(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        identity = line.strip()
        if not identity or any(ch.isspace() for ch in identity) or identity in result:
            raise RuntimeError('Image inventory contained an invalid or repeated identity')
        result[identity] = identity
    return result


def native_images(text: str) -> dict[str, str]:
    """Bind each native image reference to the immutable OCI index digest."""
    rows = json.loads(text)
    if not isinstance(rows, list):
        raise RuntimeError('Native image inventory is not a list')
    result = {}
    for row in rows:
        configuration = row.get('configuration', {})
        reference = configuration.get('name')
        digest = configuration.get('descriptor', {}).get('digest')
        if (not isinstance(reference, str) or not reference or reference in result
                or not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest)):
            raise RuntimeError('Native image inventory omitted a unique reference/digest')
        result[reference] = digest
    return result


def docker_volume_labels(text: str, names: dict[str, str]) -> dict[str, dict]:
    rows = json.loads(text)
    if not isinstance(rows, list) or {row.get('Name') for row in rows} != set(names):
        raise RuntimeError('Docker volume details changed during inventory')
    result = {}
    for row in rows:
        labels = row.get('Labels') or {}
        if not isinstance(labels, dict):
            raise RuntimeError('Docker volume labels are malformed')
        result[row['Name']] = labels
    return result


def docker_container_mounts(text: str, containers: dict[str, str]) -> dict[str, list[str]]:
    rows = json.loads(text)
    if not isinstance(rows, list) or len(rows) != len(containers):
        raise RuntimeError('Docker container mounts changed during inventory')
    result = {}
    for row in rows:
        matches = [identity for identity in containers
                   if isinstance(row.get('Id'), str) and row['Id'].startswith(identity)]
        if len(matches) != 1 or matches[0] in result:
            raise RuntimeError('Docker container identity changed during inventory')
        mounts = row.get('Mounts') or []
        if not isinstance(mounts, list):
            raise RuntimeError('Docker container mounts are malformed')
        result[matches[0]] = [mount['Name'] for mount in mounts
                             if mount.get('Type') == 'volume' and mount.get('Name')]
    return result


def image_reference(identity: str) -> str:
    reference = identity.split('|', 1)[0]
    if reference.startswith('docker.io/'):
        reference = reference.removeprefix('docker.io/')
    if reference.startswith('library/'):
        reference = reference.removeprefix('library/')
    return reference


def assert_namespace_free(baseline: dict, case: str,
                          fixed_names: list[str] | None = None,
                          fixed_images: list[str] | None = None) -> None:
    """Never run a legacy leaf whose cleanup could replace user-owned names."""
    for lane in ('candidate', 'docker'):
        for kind in ('containers', 'networks', 'volumes', 'images'):
            for identity, name in baseline[lane][kind].items():
                value = (image_reference(identity)
                         if kind == 'images' else name)
                owned = (any(value == image for image in (fixed_images or []))
                         if kind == 'images' else any(
                             value == fixed or value.startswith(fixed + '-')
                             for fixed in (fixed_names or []))) or (
                         (lane == 'candidate' and kind == 'containers'
                          and authorized_builder(name, case)))
                if owned:
                    raise RuntimeError('Original ' + lane + ' ' + kind +
                                       ' collides with parity-owned namespace: ' + value)


def snapshot(invoke: Callable[[str, str, list[str]], str]) -> dict:
    """Invocation must run under Q's existing shared command lease."""
    rows = {}
    for lane in ('candidate', 'docker'):
        base = (['container'] if lane == 'candidate' else ['docker', '--context', 'colima'])
        commands = {
            'containers': (['list', '--all', '--format', 'json'] if lane == 'candidate'
                           else ['ps', '-a', '--format', '{{.ID}} {{.Names}}']),
            'networks': (['network', 'list', '--quiet'] if lane == 'candidate'
                         else ['network', 'ls', '--format', '{{.Name}}']),
            'volumes': (['volume', 'list', '--quiet'] if lane == 'candidate'
                        else ['volume', 'ls', '--format', '{{.Name}}']),
            'images': (['image', 'list', '--format', 'json'] if lane == 'candidate'
                       else ['image', 'ls', '--no-trunc', '--format',
                             '{{.Repository}}:{{.Tag}} {{.ID}}']),
        }
        rows[lane] = {}
        for kind, args in commands.items():
            output = invoke(lane, kind, base + args)
            rows[lane][kind] = ((native_containers(output) if lane == 'candidate'
                                 else docker_containers(output)) if kind == 'containers'
                                else docker_images(output) if kind == 'images' and lane == 'docker'
                                else native_images(output) if kind == 'images'
                                else names(output))
    docker = rows['docker']
    docker['volume_labels'] = (docker_volume_labels(
        invoke('docker', 'volume-details',
               ['docker', '--context', 'colima', 'volume', 'inspect',
                *docker['volumes']]), docker['volumes']) if docker['volumes'] else {})
    docker['container_mounts'] = (docker_container_mounts(
        invoke('docker', 'container-details',
               ['docker', '--context', 'colima', 'container', 'inspect',
                *docker['containers']]), docker['containers']) if docker['containers'] else {})
    return rows


def difference(before: dict, after: dict, prefixes: list[str],
               enrolled_volumes: list[str] | None = None,
               case: str = '', image_prefixes: list[str] | None = None) -> list[dict]:
    """Require original resources untouched; authorize only named new resources."""
    additions = []
    for lane in ('candidate', 'docker'):
        for kind in ('containers', 'networks', 'volumes', 'images'):
            original = before[lane][kind]
            current = after[lane][kind]
            baseline_refs = ({image_reference(key) for key in original}
                             if lane == 'docker' and kind == 'images' else set())
            if any(current.get(identity) != name for identity, name in original.items()):
                raise RuntimeError('Original ' + lane + ' ' + kind + ' changed during parity')
            for identity, name in current.items():
                if identity in original:
                    continue
                if lane == 'docker' and kind == 'images':
                    reference = image_reference(identity)
                    if reference in baseline_refs or reference.endswith(':<none>'):
                        raise RuntimeError('Docker image tag cannot be safely removed: ' + reference)
                volume_owned = (lane == 'docker' and kind == 'volumes' and
                                (name in (enrolled_volumes or []) or any(
                                    after['docker'].get('volume_labels', {}).get(name, {}).get(
                                        'com.docker.compose.project', '').startswith(prefix)
                                    for prefix in prefixes)))
                image_name = image_reference(identity)
                image_owned = kind == 'images' and any(
                    image_name.startswith(prefix) for prefix in
                    [*prefixes, *(image_prefixes or [])])
                if not (
                        image_owned or
                        volume_owned or
                        (lane == 'candidate' and kind == 'containers'
                         and authorized_builder(name, case))
                        or any(name.startswith(prefix) for prefix in prefixes)):
                    raise RuntimeError('Unrecognized new ' + lane + ' ' + kind + ': ' + name)
                additions.append({'lane': lane, 'kind': kind, 'id': identity, 'name': name})
    return additions


def removal(resource: dict) -> list[str]:
    lane, kind, identity = resource['lane'], resource['kind'], resource['id']
    base = ['container'] if lane == 'candidate' else ['docker', '--context', 'colima']
    if kind == 'containers':
        return base + (['delete', '--force', identity] if lane == 'candidate'
                       else ['rm', '--force', identity])
    if kind == 'images':
        # A new tag may share its image ID with a baseline tag. Remove only
        # the enrolled tag, never --force an ID belonging to the baseline.
        value = identity if lane == 'candidate' else resource['name']
        return base + (['image', 'delete', '--force', value] if lane == 'candidate'
                       else ['image', 'rm', '--force', value])
    return base + ([kind.removesuffix('s'), 'delete', identity] if lane == 'candidate'
                   else [kind.removesuffix('s'), 'rm', identity])


class Ledger:
    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / 'resource-ledger.json'
        self.data = json.loads(self.path.read_text()) if self.path.exists() else {
            'schema': 1, 'cases': []}

    def begin(self, name: str, source_sha256: str, prefixes: list[str], baseline: dict,
              image_prefixes: list[str] | None = None) -> None:
        if self.pending() or any(row['name'] == name for row in self.data['cases']):
            raise RuntimeError('Parity case was already enrolled: ' + name)
        self.data['cases'].append({'name': name, 'source_sha256': source_sha256,
                                   'owned_prefixes': prefixes, 'baseline': baseline,
                                   'owned_image_prefixes': image_prefixes or [],
                                   'enrolled_volumes': [], 'restored': False})
        self.directory.mkdir(parents=True, exist_ok=True)
        write(self.path, self.data)

    def pending(self) -> list[dict]:
        return [row for row in self.data['cases'] if not row['restored']]

    def finish(self, name: str, current: dict) -> None:
        row = next(item for item in self.pending() if item['name'] == name)
        if difference(row['baseline'], current, row['owned_prefixes'],
                      row['enrolled_volumes'], row['name'],
                      row['owned_image_prefixes']):
            raise RuntimeError('Parity case left owned resources: ' + name)
        row['restored'] = True
        write(self.path, self.data)

    def verify_quiet(self, invoke: Callable[[str, str, list[str]], str]) -> dict:
        if self.pending() or not self.data['cases']:
            raise RuntimeError('Original full-suite inventory is incomplete')
        baseline = self.data['cases'][0]['baseline']
        prefixes = sorted({prefix for row in self.data['cases']
                           for prefix in row['owned_prefixes']})
        enrolled = sorted({name for row in self.data['cases']
                           for name in row.get('enrolled_volumes', [])})
        images = sorted({prefix for row in self.data['cases']
                         for prefix in row.get('owned_image_prefixes', [])})
        observed = snapshot(invoke)
        if difference(baseline, observed, prefixes, enrolled,
                      image_prefixes=images):
            raise RuntimeError('Original full-suite resources reappeared after cleanup')
        return observed

    def recover(self, invoke: Callable[[str, str, list[str]], str],
                sources: dict[str, str]) -> list[dict]:
        """Clean only validated additions and recheck the entire baseline."""
        removed = []
        for row in self.pending():
            if sources.get(row['name']) != row['source_sha256']:
                raise RuntimeError('Parity case source changed before recovery: ' + row['name'])
            observed = snapshot(invoke)
            if row['name'] == 'docker-compose-image-volumes-parity':
                journal = self.directory / 'cases' / row['name'] / 'mounts.json'
                if journal.is_symlink():
                    raise RuntimeError('Image-volume mount journal is a symbolic link')
                if journal.exists():
                    mounted = json.loads(journal.read_text())
                    if (mounted.get('schema') != 1 or
                            not mounted.get('project', '').startswith(
                                'container-compose-image-volumes-') or
                            not isinstance(mounted.get('volumes'), list) or
                            any(not NAME.fullmatch(value) for value in mounted['volumes'])):
                        raise RuntimeError('Image-volume mount journal is malformed')
                    for volume in mounted['volumes']:
                        if (volume not in row['baseline']['docker']['volumes'] and
                                volume not in row['enrolled_volumes']):
                            row['enrolled_volumes'].append(volume)
            new_containers = observed['docker']['containers'].items()
            for identity, name in new_containers:
                if identity in row['baseline']['docker']['containers']:
                    continue
                if not any(name.startswith(prefix) for prefix in row['owned_prefixes']):
                    raise RuntimeError('Unrecognized new Docker container before mount enrollment: ' + name)
                for volume in observed['docker'].get('container_mounts', {}).get(identity, []):
                    if volume not in row['baseline']['docker']['volumes'] and volume not in row['enrolled_volumes']:
                        row['enrolled_volumes'].append(volume)
            write(self.path, self.data)  # durable before deleting the mounting container
            additions = difference(row['baseline'], observed, row['owned_prefixes'],
                                   row['enrolled_volumes'], row['name'],
                                   row['owned_image_prefixes'])
            for kind in ('containers', 'volumes', 'networks', 'images'):
                for resource in additions:
                    if resource['kind'] == kind:
                        invoke(resource['lane'], 'remove-' + kind, removal(resource))
                        removed.append(resource)
            self.finish(row['name'], snapshot(invoke))
        if self.data['cases']:
            baseline = self.data['cases'][0]['baseline']
            prefixes = sorted({prefix for row in self.data['cases']
                               for prefix in row['owned_prefixes']})
            enrolled = sorted({name for row in self.data['cases']
                               for name in row.get('enrolled_volumes', [])})
            images = sorted({prefix for row in self.data['cases']
                             for prefix in row.get('owned_image_prefixes', [])})
            additions = difference(baseline, snapshot(invoke), prefixes, enrolled,
                                   image_prefixes=images)
            for kind in ('containers', 'volumes', 'networks', 'images'):
                for resource in additions:
                    if resource['kind'] == kind:
                        invoke(resource['lane'], 'remove-' + kind, removal(resource))
                        removed.append(resource)
            if additions and difference(baseline, snapshot(invoke), prefixes, enrolled,
                                        image_prefixes=images):
                raise RuntimeError('Full-suite resource baseline did not restore')
        return removed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['record-mounts'])
    parser.add_argument('--project', required=True)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--allow-partial', action='store_true')
    arguments = parser.parse_args()
    record_image_volume_mounts(arguments.project, arguments.destination,
                               allow_partial=arguments.allow_partial)
