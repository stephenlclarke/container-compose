# Building container-compose

This guide covers source builds, validation, parity checks, and package
creation. Target-machine installation lives in [INSTALL.md](INSTALL.md), release
policy lives in [BRANCHES.md](BRANCHES.md), and runtime ownership lives in
[DESIGN.md](DESIGN.md).

## Requirements

- Apple silicon Mac and macOS 26 for full runtime and parity validation.
- The Swift toolchain declared by `Package.swift`, aligned with the matching
  `container` and `containerization` checkouts.
- The Go toolchain declared by `Tools/compose-normalizer/go.mod`.
- Python 3 for coverage and release tooling.
- Node.js plus `markdownlint-cli` for Markdown validation.
- A sibling [`stephenlclarke/container`](https://github.com/stephenlclarke/container)
  checkout for the matched runtime build.
- Docker Compose v2 and a Docker daemon for the full parity suite.
- Optional `sonar-scanner` and a SonarCloud token for local analysis.

Install the user-space prerequisites with Homebrew when needed:

```sh
brew install go node python sonar-scanner
npm install --global markdownlint-cli
```

Set a specific Apple developer directory with:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Checkout Layout

Keep the runtime and plugin as sibling directories because SwiftPM resolves the
matched runtime through `../container`:

```text
~/github/container
~/github/container-compose
```

```sh
mkdir -p ~/github
git clone https://github.com/stephenlclarke/container.git ~/github/container
git clone https://github.com/stephenlclarke/container-compose.git ~/github/container-compose
cd ~/github/container-compose
```

Use an Apple upstream checkout only when deliberately testing stock-upstream
compatibility.

## Build

| Target | Output |
| --- | --- |
| `make build` | Debug Swift `compose` executable. |
| `make build-release` | Release Swift `compose` executable. |
| `make go-build` | Static, trimmed release `compose-normalizer`. |
| `make package` | Release plugin archive and checksum. |

Run the plugin directly from source with:

```sh
swift run compose version
```

Source builds fall back to `go run .` in `Tools/compose-normalizer` when no
normalizer binary is installed. Override that helper with:

```sh
export CONTAINER_COMPOSE_NORMALIZER=/absolute/path/to/compose-normalizer
```

Release Swift builds use the optimization flags declared by the Makefile.
Override `SWIFT_RELEASE_FLAGS` only when validating a toolchain-specific build
change. Every packaged Go helper uses the release build path.

## Validate

Run the complete local CI gate:

```sh
make ci
```

It runs all tracked Markdown through markdownlint, Python tooling tests, Go
format and license checks, Swift and Go tests with coverage, coverage floors,
the packaged Go build, and the built CLI smoke test. Dependency resolution uses
the checked-in exact-revision `Package.swift` entries and lockfiles unless an
update is intentional.

Useful focused targets are:

| Target | Purpose |
| --- | --- |
| `make test` | Swift and Go unit/integration-style tests that do not require a live runtime. |
| `make ci-fast` | Source checks, tests, helper build, and CLI smoke without coverage export. |
| `make release-gate` | Full builder, containerization, container, and Compose validation, including runtime integration coverage and the complete Docker Compose parity suite, required before stable package dispatch. |
| `make ci-release` | Full release gate plus the release package build. |
| `make check` | Lint, documentation, formatting, and license checks. |
| `make coverage-check` | Enforce at least 90% Swift line and 85% Go statement coverage. |
| `make cli-smoke-built` | Exercise representative commands using the existing build. |
| `make swift-runtime-test` | Build and run the isolated matched runtime smoke suite. |
| `make upstream-divergence-report` | Fetch Apple upstream and stephenlclarke refs for the Apple-backed sibling repos, then write `.build/reports/upstream-divergence.md` and `.build/reports/upstream-divergence.json`. |
| `make upstream-divergence-check` | Run the same report as a strict check that fails on dirty worktrees, unpushed local commits, missing refs, or Apple upstream merge conflicts. |

Override local coverage floors only for deliberate stricter validation:

```sh
SWIFT_COVERAGE_MIN=91 GO_COVERAGE_MIN=88 make coverage-check
```

Coverage outputs are `coverage.lcov`, `coverage.xml`,
`Tools/compose-normalizer/coverage.out`, and Swift `.profraw` files.

`make swift-runtime-test` uses the sibling runtime, isolates state under the
marker-protected `.build/container-runtime` directory, retains only the kernel
cache between runs, and always stops the test runtime when it exits.

Run `make upstream-divergence-report` before upstream handoff, runtime-stack promotion, or release review work. The report compares `container`, `containerization`, and `container-builder-shim` against their Apple upstream `main` refs, lists fork-only and upstream-only commit subjects, and checks whether Apple upstream can merge cleanly into the local checkout. Use `make upstream-divergence-check` when the review needs a hard failure instead of an informational report.

GitHub Actions separates source checks, macOS runtime validation, sanitizers,
formatting, CodeQL, SonarCloud, package publication, and Homebrew formula syntax
into focused workflows. `CI / Validate` is the aggregate required result;
documentation/formula-only changes use the lightweight validation path. The
stable release helper runs `make release-gate` locally against the candidate
tree before source promotion. That gate runs builder-shim coverage, containerization
coverage plus integration, container coverage plus integration, Compose CI, tap
formula syntax, and the complete Compose parity suite, including live `build --check`
against the matched container backend. The helper promotes `container-compose` through an automated
pull request by default, and verifies the promoted main tree still matches the
locally gated candidate before it tags. The package workflow then repeats
`make ci` before publishing package assets or updating the tap. The package
workflow does not replace the local `make release-gate`; use
`make release VERSION_SELECTOR=--+` for stable promotion so the full Docker
Compose parity suite remains mandatory.

## Promote `main` To A Stable Release

There are two package lanes, with no manual asset copying:

- Every green `main` commit refreshes the one mutable GitHub prerelease named **Current build** (tag `current`) and the opt-in `container-current` / `container-compose-current` Homebrew pair.
- A semantic release is an immutable `x.y.z` tag and becomes Homebrew's default `container` / `container-compose` pair.

From a clean `~/github/container-compose` checkout, inspect the deterministic plan first:

```sh
make release-plan
```

### Promote The Current Build

Do not copy, rename, or edit the mutable GitHub **Current build** prerelease.
It is an installable view of green `main`, not a stable release candidate asset.
Promotion always rebuilds the exact tagged source into immutable stable assets,
which is what keeps the semantic version, runtime pin, checksums, Homebrew
formulae, and release notes deterministic.

After `make release-plan` confirms the intended next version, promote the
validated `main` source with one selector. The selector is resolved from the
latest semantic tag—not from the working-tree version:

```sh
make release VERSION_SELECTOR=--+   # patch: X.Y.Z -> X.Y.(Z+1)
make release VERSION_SELECTOR=-+-   # minor: X.Y.Z -> X.(Y+1).0
make release VERSION_SELECTOR=+--   # major: X.Y.Z -> (X+1).0.0
make release VERSION_SELECTOR=0.7.0 # exact next semantic version
```

The helper is the only supported version mutator. It updates the Compose version
when necessary, preserves the exact runtime stack pin, opens and merges the
source-promotion PR, creates a signed semantic tag, waits for the hosted Stable
Release Gate, then dispatches the stable package workflow. That workflow
rebuilds and publishes the immutable stable assets and atomically updates both
stable Homebrew formulae. Do not create a semantic tag, copy a prerelease
asset, or edit either stable formula by hand.

After the tag is published, the one mutable `current` prerelease continues to
follow later green `main` commits. Homebrew users without `-current` always use
the newly promoted stable formula pair; opted-in users continue to use the
current pair.

Each stable release note also stores an immutable quality snapshot for the promoted
commit: the eleven SonarQube quality badges shown in the README plus CodeQL
analysis, result, and rule counts. They are static, non-clickable shields.io
images—not live dashboard links—and intentionally exclude the release-version
and visitor badges. Publication waits for the exact SonarQube and CodeQL
analyses; if either result cannot be tied to the promoted commit, it fails
rather than publishing incomplete historical evidence.

## Docker Compose Parity

Run every maintained Docker Compose v2 comparison in deterministic sequence:

```sh
make docker-compose-parity
```

The aggregate target builds the sibling runtime when available, starts it with
isolated state, builds `compose`, runs each target in
`DOCKER_COMPOSE_PARITY_TARGETS`, and stops the runtime on exit. The scripts own
their fixtures and exact assertions; [STATUS.md](STATUS.md) owns the support
ledger.

Run a focused target directly while iterating:

| Area | Targets |
| --- | --- |
| CLI and project loading | `docker-compose-cli-surface-parity`, `docker-compose-compatibility-names-parity`, `docker-compose-config-all-resources-parity`, `docker-compose-env-file-parity`, `docker-compose-git-remote-parity` |
| Compose Bridge | `docker-compose-bridge-parity` |
| Build | `docker-compose-build-builder-parity`, `docker-compose-build-check-parity`, `docker-compose-build-isolation-parity`, `docker-compose-build-secret-metadata-parity` |
| Mounts and resources | `docker-compose-bind-create-host-path-parity`, `docker-compose-bind-propagation-parity`, `docker-compose-volume-labels-parity`, `docker-compose-deploy-endpoint-mode-parity`, `docker-compose-deploy-resource-reservations-parity`, `docker-compose-pids-limit-parity`, `docker-compose-device-cgroup-rules-parity`, `docker-compose-devices-parity`, `docker-compose-gpus-parity` |
| Networking | `docker-compose-network-driver-opts-parity`, `docker-compose-network-ipam-options-parity`, `docker-compose-host-namespaces-parity` |
| Lifecycle and observability | `docker-compose-up-menu-parity`, `docker-compose-health-wait-parity`, `docker-compose-create-options-parity`, `docker-compose-events-parity`, `docker-compose-rm-parity`, `docker-compose-restart-policy-parity` |

The CLI surface target writes the exact compared versions and differences to
`.build/parity/compose-cli-surface.md`; documented intentional differences live
in [docs/parity/compose-cli-surface.md](docs/parity/compose-cli-surface.md) and
`Tools/parity/compose-cli-surface.allowlist`.

`oci://` Compose project artifact loading, `compose publish --dry-run`, the
image-digest override layer and application image index emitted by
`compose publish`, Docker-compatible publish preflight prompts, and the
preflight/service-image-push/artifact-publish order are covered by Go
OCI/publish tests, Swift normalizer integration tests, and the CLI smoke target.
Live registry publish/fetch validation belongs in an explicit environment that
can provide deterministic credentials and cleanup.

Refresh the sparse Docker Compose fixture checkout with:

```sh
make docker-compose-e2e-fixtures
```

Validate or intentionally refresh the retained log fixtures with:

```sh
make docker-log-fixtures
make docker-log-fixtures-update
```

The aggregate runtime defaults to `../container/bin/container` when present and
otherwise uses `container` from `PATH`. Override the matched stack explicitly:

```sh
CONTAINER_STACK_REPO=/path/to/container make docker-compose-parity
CONTAINER_COMPOSE_CONTAINER=/path/to/container make docker-compose-parity
```

## Package Archive

Build the release archive consumed by Homebrew and the install guide:

```sh
make package
```

`make package` aliases `make package-release`. `make package-debug` is a local
Swift debugging aid and is not a Homebrew package; it still embeds the
release-built Go normalizer.

The package target writes:

```text
container-compose-plugin-release-arm64.tar.gz
container-compose-plugin-release-arm64.tar.gz.sha256
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/build-info.json
dist/compose/resources/compose-normalizer
```

`build-info.json` records the package lane, branch, commit, build type, resolved
`container` commit, exact `containerization` revision, and embedded `compose-go` version.
`container compose version` exposes that metadata after installation.

## SonarQube

Generate coverage and publish a local SonarCloud analysis with:

```sh
export SONAR_TOKEN=...
make sonar
```

`SONAR_TOKEN_PERSONAL` is accepted when `SONAR_TOKEN` is unset. Use
`SONAR_BRANCH=main` to select the canonical analyzed branch. If coverage already
exists from `make ci`, run only the scanner with:

```sh
SONAR_BRANCH=main make sonar-scan
```

Local scans do not wait for the quality gate by default. Set
`SONAR_QUALITYGATE_WAIT=true` when the token can read quality-gate status.

## Maintenance

Apply supported formatting and license updates with:

```sh
make fmt
```

Install the local pre-commit gate with:

```sh
make pre-commit
```

The hook runs `make check`. Set `PRECOMMIT_NOFMT=1` only for a deliberate local
bypass. Hawkeye installation remains opt-in locally unless
`HAWKEYE_AUTO_INSTALL=1` is set.

Remove build products, coverage data, package archives, and generated helpers
with:

```sh
make clean
```
