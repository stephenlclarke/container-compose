# Recoverable Container-Family Builds

## Decision

The Container-family source build uses Make to declare repository order and
each repository's native build tool to do the work. Swift packages are built
with SwiftPM and `container-builder-shim` is built with Go. There is no separate
workflow runtime and no duplicated build graph.

This keeps the normal path visible from the command line:

```sh
make stack-preflight
make stack-build
make stack-status
```

`make` remains the quick, repository-local Compose build. `make stack-build`
builds the complete local family and records the exact source and dependency
pins that produced every executable.

## Repository Graph

Make starts the three independent roots concurrently:

```text
containerization ─┐
                  ├─> container ─> container-compose
container-engine-api ─┘

container-builder-shim ────────────────────────┐
                                               ├─> final stack pin bundle
container-compose ─────────────────────────────┘
```

`container` cannot start until the `containerization` and
`container-engine-api` pins verify. Compose cannot start until the Container
pin and its transitive pins verify. The builder is independent, so it runs in
parallel and joins only at final bundle publication.

## Recovery Contract

Generated state defaults to
`/Volumes/SSD/github/.container-compose-build`. If that development volume is
not mounted, the local fallback is `.build/stack`. A marker prevents the build
from treating an arbitrary directory as owned state, and one non-blocking
`lockf` lock prevents concurrent writers.

Each repository has a durable JSON build pin. A pin records:

- the canonical source path, exact commit, Git tree, and origin;
- the exact upstream pin receipts it consumed;
- every published artifact path and SHA-256 digest;
- the successful native build command, duration, and completion time; and
- a build-contract digest covering configuration, tool binary and version,
  relevant compiler environment, host type, Python runtime, and controller
  source.

Pins are written to a temporary regular file, flushed, and atomically renamed
only after the native build succeeds. Failed or interrupted builds therefore
cannot publish success. SwiftPM scratch directories and Go output storage are
retained, so the next invocation can continue through the native compiler
cache.

Before a pin is reused, `Tools/build/stack-pin.py` recursively verifies its
own digest, the clean source commit and tree, every dependency receipt, and
every artifact digest. A changed source checkout, dependency pin, executable,
or receipt invalidates that repository and all downstream repositories. A
configuration, toolchain, operating-system, environment, or controller change
also selects a different native scratch identity. Work that is still exact is
reused automatically.

The final `stack.json` bundle is published while the global build lock is
still held. `verify-bundle` then recursively validates every component before
the lock is released. `make stack-status` reports `valid`, `stale`, or
`missing`; it never repairs or silently carries a receipt forward.

## What Happens After Failure

Run the same command again:

```sh
make stack-build
```

The result depends on the failure boundary:

- If a native compile failed, its success pin is absent and that command runs
  again against the retained native scratch directory.
- If an upstream source or artifact changed, its pin and every transitive
  consumer are rebuilt.
- If an independent repository already has an exact valid pin, it is skipped.
- If final bundle publication was interrupted, all valid component pins are
  reused and only the bundle is republished.
- If the previous process is still running, the lock fails immediately rather
  than creating a second writer.

Manual editing, copying, or renaming of success pins is unsupported. A modified
receipt fails its digest check.

## Unattended Operation

Build recipes disable Git credential prompting, SSH askpass, inherited shell
hooks, and dynamic-loader injection. Normal Make parsing never queries the
macOS Keychain for a signing identity. Source builds do not sign applications,
start VMs, access removable-volume data, publish artifacts, run CodeQL, build
DocC, or record performance benchmarks.

Release signing receives an explicit 40-character Developer ID fingerprint at
its release-only boundary. Missing credentials or privacy grants fail there
with a diagnostic rather than being requested by an ordinary build.

## Release Validation

Release validation remains broader than a source build. Its stages use the
same Make targets plus `Tools/ci/run-release-checkpoint.py` for bounded,
content-addressed success checkpoints and durable output logs. Each checkpoint
records the exact-input fingerprint before and after the stage, status,
duration, output name, and output digest.

The hosted stable gate retains checkpoints below a directory keyed by the
immutable release candidate commit. A corrected retry starts with the first
missing or invalid stage. Its stable-release authority receipt binds the
candidate and component commits to the verified hosted-gate checkpoint and
output log; it does not rely on an orchestration session.

CodeQL, full parity, packaging, signing, notarisation, documentation, and
publication stay in release-specific jobs. Their inclusion is explicit and
does not widen `make`, `make build`, or `make stack-build`.

## Verification

Run the focused recovery tests with:

```sh
make stack-self-test
python3 -m unittest Tools.ci.test_release_stage_git_history
python3 -m unittest Tools.release.test_stable_release_authority
```

The tests cover atomic replacement, source and artifact drift, transitive pin
invalidation, bundle corruption, unsafe output links, the declared repository
graph, lock scope, release-only exclusions, noninteractive identity handling,
and candidate-keyed hosted checkpoints.
