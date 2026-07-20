# Building container-compose

This guide covers source builds, validation, parity checks, package creation,
and the deterministic release procedure. Target-machine installation lives in
[INSTALL.md](INSTALL.md), and runtime ownership lives in [DESIGN.md](DESIGN.md).

## Stack Roles And Branches

`container-compose` coordinates releases for the matched `stephenlclarke` stack. `container` supplies the runtime and CLI, `containerization` supplies its Swift runtime package, `container-builder-shim` supplies the pinned builder image, and `homebrew-tap` publishes the paired formulae.

`main` is the releasable integration branch in each repository. Use short-lived review branches for all changes and land the sibling repositories through their own pull requests before promoting Compose. The release helper promotes `container-compose`; it can additionally publish only a fast-forwarded, release-generated `container` package-pin commit after that repository's `make check test` preflight, because Compose cannot resolve an unpublished immutable runtime revision. No feature or hand-written sibling source branch is promoted by the helper. Do not create long-lived integration or packaging branches.

## Requirements

- Apple silicon Mac and macOS 26 for full runtime and parity validation.
- The Swift toolchain declared by `Package.swift`, aligned with the matching
  `container` and `containerization` checkouts.
- The Go toolchain declared by `Tools/compose-normalizer/go.mod`.
- Python 3 for coverage and release tooling.
- Node.js plus `markdownlint-cli` for Markdown validation.
- Internet access for SwiftPM to fetch the exact checked-in `container` and
  `containerization` revisions. A sibling runtime checkout is required only for
  full stack, runtime, or release-gate validation.
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

An ordinary source checkout is self-contained: SwiftPM resolves the matched
runtime by the exact revision in `Package.swift` and `Package.resolved`.
Keep a sibling runtime checkout only when running the full stack gates:

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

To validate an in-progress matching `container` checkout instead of the pinned
release revision, opt into it explicitly:

```sh
Tools/ci/use-stack-container.sh ../container
swift package resolve
```

Return to the exact published dependency with `swift package unedit container
--force`.

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
| `make release-gate` | Full builder, containerization, container, Compose CI, isolated runtime smoke suite, and pinned Docker Compose comparison suite; required before stable package dispatch. |
| `make release-gate-hosted` | GitHub-hosted static stack validation: source checks, builds, unit coverage, Compose CI, and Homebrew formula syntax without Virtualization.framework or Docker-engine runtime tests. |
| `make ci-release` | Full release gate plus the release package build. |
| `make check` | Lint, documentation, formatting, and license checks. |
| `make coverage-check` | Enforce at least 90% Swift line and 85% Go statement coverage. |
| `make cli-smoke-built` | Exercise representative commands using the existing build. |
| `make swift-runtime-test` | Build and run the isolated matched runtime smoke suite. |
| `make upstream-divergence-report` | Fetch Apple upstream and stephenlclarke refs for the Apple-backed sibling repos, then write `.build/reports/upstream-divergence.md` and `.build/reports/upstream-divergence.json`. |
| `make upstream-divergence-check` | Run the same report as a strict check that fails on dirty worktrees, unpushed local commits, missing refs, or Apple upstream merge conflicts. |
| `make upstream-divergence-release-check` | Stable-release check: also fails when a fork `main` is behind Apple upstream. |

Override local coverage floors only for deliberate stricter validation:

```sh
SWIFT_COVERAGE_MIN=91 GO_COVERAGE_MIN=88 make coverage-check
```

Coverage outputs are `coverage.lcov`, `coverage.xml`,
`Tools/compose-normalizer/coverage.out`, and Swift `.profraw` files.

`make swift-runtime-test` uses the sibling runtime, isolates state under the
marker-protected `.build/container-runtime` directory, retains only the kernel
cache between runs, and always stops the test runtime when it exits.

Run `make upstream-divergence-report` before upstream handoff, runtime-stack promotion, or release review work. The report compares `container`, `containerization`, and `container-builder-shim` against their Apple upstream `main` refs, lists fork-only and upstream-only commit subjects, and checks whether Apple upstream can merge cleanly into the local checkout. Use `make upstream-divergence-check` when the review needs a hard failure, and `make upstream-divergence-release-check` before a stable release so an upstream-behind fork cannot be promoted.

GitHub Actions separates source checks, macOS runtime validation, sanitizers,
formatting, CodeQL, SonarCloud, package publication, and Homebrew formula syntax
into focused workflows. Both the full and documentation/formula-only paths
publish the required `CI / Validate` result. The
stable release helper runs `make release-gate` locally against the candidate
tree before source promotion. That gate runs builder-shim coverage, containerization
coverage plus integration, container coverage plus integration, Compose CI, tap
formula syntax, the isolated Swift runtime suite, and the pinned Compose comparison
suite, including live `build --check` against the matched container backend. GitHub-hosted macOS runners cannot launch
nested Virtualization.framework guests, so the post-tag Stable Release Gate runs
the `make release-gate-hosted` equivalent from its immutable release-control
checkout against immutable source, runtime, and tap checkouts instead. It
validates the non-virtualized stack and Compose CI; the local full gate remains
mandatory for runtime integration and Docker Compose parity. When release
preparation changes `container`'s exact `containerization` package pin, the
helper first runs `make check test` there and publishes that fast-forwarded,
release-generated metadata commit so Compose SwiftPM can resolve the exact
remote revision. It then runs the complete assembled-stack local gate before
it promotes `container-compose` through an automated pull request by default,
verifies the promoted main tree still matches the locally gated candidate before
it tags, and refuses to promote any other sibling source main: feature changes
must already be merged through their own reviewable pull requests. A
successful hosted gate records a candidate-bound GitHub Actions release-authority
check on that tag commit; the package workflow requires that check, then repeats
`make ci` before it publishes assets or updates the tap.

The 0.7.0 Phase 1 promotion has one explicitly bounded local-gate exception:
the current macOS Builder bridge rejects external Dockerfile paths when macOS
canonicalises `/tmp` to `/private/tmp`, and its tar-export handoff does not
reliably create a direct destination file or a repeated directory export. Both
are tracked as Phase 5 work and are not Docker Compose parity. Only this exact
semantic release may set
`CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON`; the helper
rejects the variable for every other version and the local gate then excludes
only `TestCLIBuilderSerial` and `TestCLIBuilderTarExportSerial` while retaining
all other Container integration suites. The hosted gate is unchanged. The
release notes and status must state that both Phase 5 Builder gaps remain
unavailable.

## Promote `main` To A Stable Release

There are two package lanes, with no manual asset copying:

- Every successful CI run that originates from a push to `main` refreshes the explicit `current` tag and a newly published mutable GitHub prerelease named **Current build**, plus the opt-in `container-current` / `container-compose-current` Homebrew pair. A commit superseded before promotion is skipped so the subsequent successful run publishes the newest `main` head.
- A semantic release is an immutable `x.y.z` tag and becomes Homebrew's default `container` / `container-compose` pair.

`current` is deliberately an unsigned, movable pointer; signing it would make
its verification describe a prior commit as soon as it advances. Stable semantic
tags are SSH-signed and GitHub-verified before their release gate starts.

Current is the normal delivery lane. Create a stable release after the current
build has soaked for seven days for a milestone, as a documented `--+`
maintenance promotion, or for a documented security incident. A maintenance
promotion is manual, must record its operational reason, and is limited to a
patch bump; it is suitable for an explicit baseline promotion or a release
mechanism fix. The soak starts when the commit-identified current plugin asset
(`container-compose-plugin-current-<12-character-sha>-arm64.tar.gz`) is
published, not when the long-lived Current prerelease was first created. The
release helper enforces these rules.

Current publication is recoverable across GitHub and Homebrew: it stages
immutable commit-identified archives on the existing Current prerelease, updates
the matching Homebrew formula pair, then moves the mutable `current` tag and
recreates the release object from those staged assets. Recreating the object
makes GitHub's published time represent this Current build rather than the
first build that used the `current` tag. If that final replacement is
interrupted, rerunning the same publication recreates the release from the same
candidate assets.

### Scheduled Stable Releases

**Scheduled Stable Release** runs every Monday at 09:17 UTC and promotes the next minor version with `-+-` when the Current build has soaked for seven days and `main` contains source newer than the latest semantic tag. It ends successfully without allocating the release runner when either condition is not met, so an unready week is not a failed release. A manual dispatch of the same workflow permits either `-+-` (minor) or `+--` (major); patch, exact-version, and documented security releases remain explicit local helper invocations.

The workflow runs only from `main` on the dedicated `container-compose-release` Apple-silicon self-hosted runner. It creates clean, disposable stack checkouts, reconstructs the read-only Apple remotes and Stephen-owned push remotes, and invokes the existing helper unchanged. That preserves the required local runtime and Docker Compose parity gate, signed semantic tag, source-promotion pull request, hosted stable gate, immutable package assets, and paired Homebrew update.

Bootstrap that runner once on the release Mac after its normal build prerequisites and GitHub CLI login are in place:

```sh
./scripts/install-scheduled-release-runner.sh
```

The installer verifies hardware virtualization, the Git author identity and SSH tag- and commit-signing configuration, that the signing key can operate without an interactive passphrase, the local `gh` account, and the release toolchain before it registers a repository-only runner and starts its standard `launchd` service. It uses the logged-in account through the macOS keychain at run time; it does not copy a GitHub token or signing key into an Actions secret.

From clean `~/github/container-compose`, `~/github/container-builder-shim`,
`~/github/containerization`, `~/github/container`, and
`~/github/homebrew-tap` checkouts, inspect the deterministic plan first:

```sh
make release-plan
```

### Promote The Current Build

Do not copy, rename, or edit the mutable GitHub **Current build** prerelease.
It is an installable view of green `main`, not a stable release candidate asset.
Promotion always rebuilds the exact tagged source into immutable stable assets,
which is what keeps the semantic version, runtime pin, checksums, Homebrew
formulae, and release notes deterministic. The current prerelease is recreated
by its workflow after the matching Homebrew formulae update, so its GitHub
published time always identifies the build users are viewing.

After `make release-plan` confirms the intended next version, promote the
validated `main` source with one selector. The selector is resolved from the
latest semantic tag—not from the working-tree version. The explicit intent
makes a stable release a conscious boundary rather than an automatic response to
every green slice:

```sh
CONTAINER_STACK_RELEASE_INTENT=milestone make release VERSION_SELECTOR=--+   # patch: X.Y.Z -> X.Y.(Z+1)
CONTAINER_STACK_RELEASE_INTENT=milestone make release VERSION_SELECTOR=-+-   # minor: X.Y.Z -> X.(Y+1).0
CONTAINER_STACK_RELEASE_INTENT=milestone make release VERSION_SELECTOR=+--   # major: X.Y.Z -> (X+1).0.0
CONTAINER_STACK_RELEASE_INTENT=milestone make release VERSION_SELECTOR=0.7.0 # exact next semantic version
CONTAINER_STACK_RELEASE_INTENT=milestone \\
  CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON='explicit maintainer authorization: promote Current as 0.7.0' \\
  make release VERSION_SELECTOR=0.7.0
CONTAINER_STACK_RELEASE_INTENT=security CONTAINER_STACK_SECURITY_REASON='CVE-2026-12345' make release VERSION_SELECTOR=--+
```

Before source promotion, the helper requires the mutable `current` tag to point
at the validated `main` head. Milestones also require that Current build's
seven-day soak. An exceptional milestone promotion may bypass only that timer
with a non-empty `CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON` recording the
explicit maintainer authorization and rationale; it still requires the exact
Current source and package, every local and hosted release gate, a signed tag,
and the paired Homebrew verification. It then blocks if a sibling fork is
behind Apple upstream, requires `kern.hv_support=1`, bootstraps the matched
stack tools, fetches the required `containerization` integration kernel when it
is absent, and runs the full local `make release-gate`. The hosted gate
then runs the `make release-gate-hosted` equivalent from its immutable
release-control checkout against the immutable source, runtime, and tap
checkouts before package publication. The helper waits up to three hours for
that hosted gate, which exceeds its 120-minute workflow timeout; set
`CONTAINER_STACK_STABLE_GATE_WAIT_SECONDS` only when an operator needs a
different bound.

The helper is the only supported version mutator. It updates the Compose version
when necessary, preserves the exact runtime stack pin, opens and merges the
source-promotion PR, creates a signed semantic tag, waits for the hosted Stable
Release Gate, then dispatches the stable package workflow. That workflow
rebuilds and publishes the immutable stable assets and atomically updates both
stable Homebrew formulae. Do not create a semantic tag, copy a prerelease
asset, or edit either stable formula by hand.

If a hosted gate fails before the semantic GitHub release is created, correct the release automation on `main` and rerun the same explicit version, for example `make release VERSION_SELECTOR=X.Y.Z`. The helper reuses only the latest existing GitHub-verified signed source tag, reruns the gates and package workflow, and refuses to change a tag or overwrite an existing semantic release. If the semantic GitHub release is published but its stable Homebrew formula pair is absent or incomplete, the same command dispatches formula-only recovery. It validates the existing immutable Compose and runtime assets and updates only the paired stable formulae; it never rebuilds a package, changes a signed tag, or replaces release assets.

After the tag is published, the one mutable `current` prerelease continues to
follow later green `main` commits. Homebrew users without `-current` always use
the newly promoted stable formula pair; opted-in users continue to use the
current pair.

Each package note begins with a quality snapshot for its exact commit: the eleven SonarQube quality metrics shown in the README plus CodeQL analysis, result, and rule counts. The release controller emits all fourteen metrics as individual static Shields-compatible badges and uploads the same metrics as one self-contained SVG evidence asset. Every publication uses a unique static delivery key and Shields' maximum supported five-day cache lifetime, so a successfully verified static badge is not needlessly re-fetched through GitHub's image proxy while the release remains current. The controller asks GitHub to render the exact release Markdown, fetches every resulting GitHub-proxied image, and parses every payload as SVG before publication can continue. A badge-host, GitHub image-proxy, SonarCloud, CodeQL, or GitHub Actions authority-query failure therefore blocks the release rather than producing a partial or broken note. Both publish-context resolution and quality-snapshot capture retry transient GitHub `429` and `5xx` responses twelve times; exhaustion fails the package workflow visibly instead of reporting a successful skip and leaving Current stale. A Current package accepts only an exact-main successful CI run with a passed SonarQube scan, whether that CI was triggered by a push or an explicit full-validation dispatch; a docs-only run simply leaves the existing Current release in place. The SVG stays a downloadable evidence artifact and is not embedded inline, because GitHub release pages serve release assets as attachment data rather than reliable inline SVG images. Current-build snapshots refresh whenever the mutable `current` pointer moves; stable snapshots are immutable historical evidence.

## Docker Compose Parity

Run every maintained Docker Compose v2 comparison in deterministic sequence:

```sh
make docker-compose-parity
```

The aggregate target requires Docker Compose `5.3.1`, pins Docker's e2e fixtures to commit `f32009d4a2c687dd405398cc7975d12dccaf8dff`, builds the sibling runtime when available, starts it with isolated state, builds `compose`, runs each target in `DOCKER_COMPOSE_PARITY_TARGETS`, and stops the runtime on exit. The reference scripts establish Docker behavior; the isolated runtime suite and the Compose side of each comparison establish local behavior. [STATUS.md](STATUS.md) owns the support ledger.

Run a focused target directly while iterating:

| Area | Targets |
| --- | --- |
| CLI and project loading | `docker-compose-cli-surface-parity`, `docker-compose-compatibility-names-parity`, `docker-compose-config-all-resources-parity`, `docker-compose-env-file-parity`, `docker-compose-format-template-actions-parity`, `docker-compose-git-remote-parity` |
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

To deliberately update either pinned Docker reference, change both the Makefile default and the documented expected behavior in the same reviewed pull request. Ad-hoc overrides are for investigation only; they are not release evidence.

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
dist/compose/resources/container-compose-icon.png
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
