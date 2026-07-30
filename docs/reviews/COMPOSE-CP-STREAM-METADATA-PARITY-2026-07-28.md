# Compose `cp` Stream Metadata Parity

Date: 2026-07-28

## Outcome

The matched supported stack passed the live Docker Compose `cp -` archive
fixture for content, ownership, mode, timestamps, symlinks, hard links, sparse
allocation, long paths, and large files.

Performance is recorded separately from behavioural parity. Container Compose
was slower in this single local run, but every operation completed well inside
the 120-second timeout and none crossed the material-slowdown boundary of both
10x the Docker duration and 5 seconds additional elapsed time.

## Revisions

| Component | Revision |
| --- | --- |
| Docker Compose | 5.3.1 |
| `stephenlclarke/containerization` | `52386838456a431d24bed6c38a9e84fb0ad28997` |
| `stephenlclarke/container` | `f5e25b12ed074e7e5fb09933d86a27652034f3e5` |
| `stephenlclarke/container-compose` | `fix/cp-stream-metadata-parity`, based on `5d2dc8e98d3c1bcaf132ddd15f5aac68a3e1959b` |
| Compose Go | `v2.13.0` |

The isolated Apple Container runtime reported the exact Container and
Containerization revisions above before the fixture ran.

## Environment

| Item | Value |
| --- | --- |
| Host | macOS 26.5.1 build 25F80, arm64 |
| Darwin | 25.5.0 |
| Docker client | 29.6.2 |
| Docker server | 29.5.2 |
| GNU tar | 1.35 |
| Fixture image | `alpine:3.20` |
| Repetitions | 1 per implementation and operation |
| Per-copy timeout | 120 seconds |
| Material slowdown boundary | ratio greater than 10x and absolute delay greater than 5 seconds |

## Workload

The automated fixture in
`Tools/parity/check-compose-cp-stdio-archive-streams.sh` performs four timed
copy operations against Docker Compose and then Container Compose:

1. stdin tar stream containing a small regular file;
2. stdout tar stream containing a small regular file;
3. archived stdin metadata fixture with UID 1234, GID 2345, mode 0640, mtime
   1700000000, a symlink, a 16 MiB sparse file, a 180-character path component,
   and a 4 MiB file;
4. archived stdin hard-link fixture requiring one shared inode.

Untimed assertions compare content hashes, symlink targets, exact metadata,
sparse size and block allocation, and hard-link inode identity. Timings use the
host monotonic clock around each bounded copy command and include command and
runtime round-trip overhead.

## Measurements

| Operation | Docker seconds | Container Compose seconds | Ratio | Delta seconds |
| --- | ---: | ---: | ---: | ---: |
| stdin content | 0.132713 | 0.742988 | 5.60x | +0.610275 |
| stdout content | 0.131541 | 0.741976 | 5.64x | +0.610435 |
| stdin metadata | 0.233447 | 0.780232 | 3.34x | +0.546785 |
| stdin hard links | 0.152129 | 0.688076 | 4.52x | +0.535947 |

The machine-readable source is
[`compose-cp-stream-metadata-parity-timings-2026-07-28.tsv`](compose-cp-stream-metadata-parity-timings-2026-07-28.tsv).
These one-run values are a release baseline, not an optimisation benchmark.
Future comparisons should retain the same workload and environment or explain
the differences, increase repetitions for statistical conclusions, and report
behavioural parity independently from performance.

## Validation

- Exact metadata: `1234:2345:640:1700000000`.
- Sparse size and allocation: `16777216:32768`.
- Hard-link source and target used the same inode.
- Content hashes, symlink target, long path, and 4 MiB file matched.
- All eight timed operations completed without timeout.
- Full Compose CI passed against the exact matched pins.

The first isolated runtime build attempt was blocked by guest DNS resolution,
and a Docker fallback encountered the local Swift SDK certificate chain. The
validated runtime was therefore built from the official Swift 6.3.0 SDK after
verifying SHA-256
`d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c`.
Those setup failures occurred before the parity fixture and are not product
failures.
