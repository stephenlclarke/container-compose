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

"""No-runtime fixture-store cache tests with an incomplete foreign-platform graph."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import fixture_cache as cache


def fixture(app: Path, *, arm: bool = True) -> tuple[str, dict]:
    blobs = app / 'content' / 'blobs' / 'sha256'
    blobs.mkdir(parents=True)

    def add(value: bytes, media: str) -> dict:
        identity = cache.digest(value)
        (blobs / identity[7:]).write_bytes(value)
        return {'digest': identity, 'mediaType': media, 'size': len(value)}

    layer = add(b'arm64 layer', 'application/vnd.oci.image.layer.v1.tar')
    config = add(b'{"architecture":"arm64","os":"linux"}',
                 'application/vnd.oci.image.config.v1+json')
    manifest = add(json.dumps({'config': config, 'layers': [layer]}, sort_keys=True).encode(),
                   'application/vnd.oci.image.manifest.v1+json')
    manifests = [{'digest': 'sha256:' + 'a' * 64, 'size': 42,
                  'mediaType': 'application/vnd.oci.image.manifest.v1+json',
                  'platform': {'os': 'linux', 'architecture': 'amd64'}}]
    if arm:
        manifests.append(dict(manifest, platform={'os': 'linux', 'architecture': 'arm64'}))
    root = add(json.dumps({'manifests': manifests}, sort_keys=True).encode(),
               'application/vnd.oci.image.index.v1+json')
    reference = 'docker.io/library/alpine:3.20'
    (app / 'state.json').write_text(json.dumps({reference: root}))
    return reference, root


class FixtureCacheTests(unittest.TestCase):
    def test_capture_restore_reuses_exact_root_and_arm64_without_foreign_blobs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            reference, root = fixture(source)
            retained = base / 'retained'
            captured = cache.capture(source, retained, ('alpine:3.20',))
            self.assertEqual(captured[0]['root'], root)
            self.assertEqual(len(captured[0]['blobs']), 4)
            target = base / 'target'
            (target / 'kernels').mkdir(parents=True)
            restored = cache.restore(target, retained, ('alpine:3.20',))
            self.assertEqual(restored, captured)
            self.assertEqual(json.loads((target / 'state.json').read_text()), {reference: root})
            self.assertEqual(len(list((target / 'content/blobs/sha256').iterdir())), 4)
            self.assertEqual(cache.capture(source, retained, ('alpine:3.20',)), captured)

    def test_missing_or_corrupt_cache_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            fixture(source)
            retained = base / 'retained'
            value = cache.capture(source, retained, ('alpine:3.20',))[0]
            entry = cache.entry_path(retained, value['reference'])
            selected = entry / 'content/blobs/sha256' / value['arm64_manifest'][7:]
            selected.write_bytes(b'changed')
            target = base / 'target'
            target.mkdir()
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                cache.restore(target, retained, ('alpine:3.20',))
            self.assertFalse((target / 'state.json').exists())

    def test_capture_rejects_pinned_mismatch_and_missing_arm64(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            reference, root = fixture(source)
            state = json.loads((source / 'state.json').read_text())
            pinned = 'docker.io/library/alpine@sha256:' + 'f' * 64
            state[pinned] = root
            (source / 'state.json').write_text(json.dumps(state))
            with self.assertRaisesRegex(RuntimeError, 'Pinned fixture reference'):
                cache.capture(source, base / 'retained', (pinned,))
            source2 = base / 'without-arm'
            source2.mkdir()
            fixture(source2, arm=False)
            with self.assertRaisesRegex(RuntimeError, 'exactly one linux/arm64'):
                cache.capture(source2, base / 'other-cache', ('alpine:3.20',))

    def test_pinned_digest_accepts_verified_index_alias_and_annotations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            _, root = fixture(source)
            root['annotations'] = {'org.opencontainers.image.ref.name': 'original'}
            pinned = 'docker.io/library/alpine@' + root['digest']
            stored = 'index.docker.io/library/alpine@' + root['digest']
            (source / 'state.json').write_text(json.dumps({stored: root}))
            values = cache.capture(source, base / 'retained', (pinned,))
            self.assertEqual(values[0]['stored_reference'], stored)
            target = base / 'target'
            target.mkdir()
            cache.restore(target, base / 'retained', (pinned,))
            self.assertEqual(json.loads((target / 'state.json').read_text()), {stored: root})
            self.assertEqual(cache.normalized(stored), pinned)

    def test_tagged_pinned_request_accepts_digest_only_q_store_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            _, root = fixture(source)
            requested = 'docker.io/library/docker:29.2.1-cli@' + root['digest']
            stored = 'docker.io/library/docker@' + root['digest']
            (source / 'state.json').write_text(json.dumps({stored: root}))
            captured = cache.capture(source, base / 'retained', (requested,))
            self.assertEqual(captured[0]['stored_reference'], stored)
            row = {'configuration': {'descriptor': root},
                   'variants': [{'platform': {'os': 'linux', 'architecture': 'arm64'},
                                 'digest': captured[0]['arm64_manifest']}]}
            self.assertEqual(cache.native_record({stored: row}, requested), row)

    def test_pinned_alias_precedes_same_repository_tag_with_identical_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            _, root = fixture(source)
            requested = 'docker.io/library/alpine@' + root['digest']
            alias = 'index.docker.io/library/alpine@' + root['digest']
            tagged = 'docker.io/library/alpine:3.22'
            (source / 'state.json').write_text(json.dumps({alias: root, tagged: root}))
            captured = cache.capture(source, base / 'retained', (requested,))
            self.assertEqual(captured[0]['stored_reference'], alias)

    def test_restore_refuses_existing_state_and_source_cache_stays_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'source'
            source.mkdir()
            reference, _ = fixture(source)
            retained = base / 'retained'
            original = cache.capture(source, retained, ('alpine:3.20',))[0]
            fixture_blob = source / 'content/blobs/sha256' / original['arm64_manifest'][7:]
            fixture_blob.write_bytes(b'now different')
            self.assertEqual(cache.capture(source, retained, ('alpine:3.20',)), [original])
            target = base / 'target'
            target.mkdir()
            (target / 'state.json').write_text(json.dumps({reference: original['root']}))
            with self.assertRaisesRegex(RuntimeError, 'not a fresh reset app'):
                cache.restore(target, retained, ('alpine:3.20',))

    def test_normalized_fixture_refs_include_tagged_digest(self) -> None:
        self.assertEqual(cache.normalized('alpine:3.21'), 'docker.io/library/alpine:3.21')
        self.assertEqual(cache.normalized('docker/compose-bridge-kubernetes@sha256:' + 'a' * 64),
                         'docker.io/docker/compose-bridge-kubernetes@sha256:' + 'a' * 64)
        self.assertEqual(cache.normalized('docker.io/library/docker:29.2.1-cli@sha256:' + 'b' * 64),
                         'docker.io/library/docker:29.2.1-cli@sha256:' + 'b' * 64)
        self.assertEqual(cache.repository('docker/compose-bridge-helm:<none>'),
                         'docker.io/docker/compose-bridge-helm')
        self.assertEqual(cache.repository('alpine:3.22'), 'docker.io/library/alpine')
        with self.assertRaisesRegex(RuntimeError, 'Invalid fixture'):
            cache.normalized('../unowned:latest')

    def test_native_pinned_aliases_match_original_root_and_arm64_variant(self) -> None:
        root = 'sha256:' + 'a' * 64
        arm = 'sha256:' + 'b' * 64
        row = {'configuration': {'descriptor': {'digest': root}},
               'variants': [{'platform': {'os': 'linux', 'architecture': 'arm64'},
                             'digest': arm}]}
        requested = 'docker.io/library/alpine@' + root
        rows = {'index.docker.io/library/alpine@' + root: row,
                'docker.io/library/alpine:3.22': row}
        self.assertEqual(cache.native_record(rows, requested), row)
        changed = {'configuration': {'descriptor': {'digest': root}},
                   'variants': [{'platform': {'os': 'linux', 'architecture': 'arm64'},
                                 'digest': 'sha256:' + 'c' * 64}]}
        rows['docker.io/library/alpine:3.22'] = changed
        with self.assertRaisesRegex(RuntimeError, 'Ambiguous'):
            cache.native_record(rows, requested)

    def test_docker_pinned_presence_uses_repository_digest_and_platform_only(self) -> None:
        requested = 'docker.io/library/docker:29.2.1-cli@sha256:' + 'a' * 64
        inventory = {'<none>:<none>|sha256:' + '1' * 64,
                     'docker.io/library/docker:<none>|sha256:' + '2' * 64,
                     'docker.io/library/alpine:3.20|sha256:' + '3' * 64,
                     '127.0.0.1:5000/isolation/alpine:3.20|sha256:' + '4' * 64}
        self.assertEqual(cache.docker_pinned_candidates(inventory, requested),
                         {'sha256:' + '2' * 64})
        metadata = 'linux|arm64|v8|["docker.io/library/docker@sha256:' + 'a' * 64 + '"]'
        self.assertTrue(cache.docker_pinned_metadata_matches(metadata, requested))
        aliased = ('linux|arm64||["127.0.0.1:5000/other/docker@sha256:' + 'c' * 64
                   + '","docker.io/library/docker@sha256:' + 'a' * 64 + '"]')
        self.assertTrue(cache.docker_pinned_metadata_matches(aliased, requested))
        self.assertFalse(cache.docker_pinned_metadata_matches(
            'linux|amd64||["docker.io/library/docker@sha256:' + 'a' * 64 + '"]', requested))
        self.assertFalse(cache.docker_pinned_metadata_matches(
            'linux|arm64||["docker.io/library/docker@sha256:' + 'b' * 64 + '"]', requested))
        self.assertFalse(cache.docker_pinned_metadata_matches('linux|arm64||null', requested))
        with self.assertRaisesRegex(RuntimeError, 'metadata'):
            cache.docker_pinned_metadata_matches('not image metadata', requested)
        with self.assertRaisesRegex(RuntimeError, 'digest metadata'):
            cache.docker_pinned_metadata_matches(
                'linux|arm64||["docker.io/library/docker@sha256:short"]', requested)


if __name__ == '__main__':
    unittest.main()
