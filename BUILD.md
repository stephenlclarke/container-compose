# Building container-compose

This guide covers source builds, validation, parity checks, package creation,
and the deterministic release procedure. Target-machine installation lives in
[INSTALL.md](INSTALL.md), and runtime ownership lives in [DESIGN.md](DESIGN.md).

## Stack Roles And Branches

`container-compose` coordinates releases for the matched `stephenlclarke` stack. `container` supplies the runtime and CLI, `containerization` supplies its Swift runtime package, `container-builder-shim` supplies the pinned builder image, and `homebrew-tap` publishes the paired formulae.

The [Container-family parity development cycle](docs/container-family-development-cycle.md) defines how cross-repository vertical slices are selected, reviewed, validated, checkpointed, handed off, and cleaned up. This guide remains authoritative for exact build, test, runner, package, and release commands.

`main` is the releasable integration branch in each repository. Use short-lived review branches for every human-authored change and land the sibling repositories through their own pull requests before promoting Compose. The sole pre-authorised automation exception is the release helper's fast-forwarded, release-generated `container` package-pin commit, required because Compose cannot resolve an unpublished immutable runtime revision. The helper signs a commit it creates, accepts exactly one commit on reviewed `container` main, requires the generated subject, permits only `Package.swift` and `Package.resolved`, runs that repository's `make check test`, verifies the remote exact head, and then subjects the assembled revisions to the complete local release gate before Compose promotion. It aborts on any other diff, ancestry, or publication result. Recovery can currently retain a pre-existing matching local candidate without verifying its signature; the operator must verify its trusted signature/provenance before execution, and the development-cycle enabler must make that check fail closed. No feature, hand-written sibling source branch, ordinary checkpoint, or incomplete handoff uses this exception. Do not create long-lived integration or packaging branches.

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
| `make package` | Release plugin archive and relocatable checksum sidecar. |

Run the plugin directly from source with:

```sh
swift run compose version
```

Source builds fall back to `go run .` in `Tools/compose-normalizer` when no
normalizer binary is installed. Override that helper with:

```sh
export CONTAINER_COMPOSE_NORMALIZER=/absolute/path/to/compose-normalizer
```

Release Swift builds use SwiftPM's default speed optimisation. Set
`SWIFT_RELEASE_FLAGS` only when validating a toolchain-specific build change.
Every packaged Go helper uses the release build path.

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
| `make check` | Lint, documentation, generated programme-progress, formatting, and license checks. |
| `make programme-progress-update` | Regenerate the readable programme status from its machine-readable register after an intentional state or evidence change. |
| `make programme-progress-check` | Fail on missing/duplicate stable IDs, stale design anchors or generated status, heads newer than the trusted pre-change checkpoint, recorded IDs that peel from non-commit Git objects, missing or undeclared item-required repository heads, repository heads not accepted by fetched `main` in authenticated checkouts, unverified or wrong-head GitHub authorities, unsafe evidence, unactionable blockers, or unreviewed dependent documentation. The check uses the fixed system GitHub CLI and needs normal `gh` authentication; hosted jobs supply their read-only GitHub token only to the source-check step. |
| `make coverage-check` | Enforce separate ComposeCore, runtime SPI, provider, plugin, aggregate first-party Swift, and Go coverage floors. |
| `. Tools/ci/codeql-entry.sh`, then `container_compose_codeql codeql-local` | Enter Make without inherited native-loader, Make, or Python startup source; run the checksum-pinned CodeQL CLI and Go query pack against the exact normalizer build, reject undispositioned results, and retain commit-keyed SARIF. |
| `. Tools/ci/codeql-entry.sh`, then `container_compose_codeql codeql-sarif-upload` | Enter the upload goal through the same controlled boundary, regenerate exact SARIF, authenticate its digests in memory, and upload only after the checkout head, origin repository, remote ref, evidence, and commit all agree. |
| `make cli-smoke-built` | Exercise representative commands using the existing build. |
| `make swift-runtime-test` | Build and run the isolated matched runtime smoke suite. |
| `make upstream-divergence-report` | Fetch Apple upstream and stephenlclarke refs for the Apple-backed sibling repos, then write `.build/reports/upstream-divergence.md` and `.build/reports/upstream-divergence.json`. |
| `make upstream-divergence-check` | Run the same report as a strict check that fails on dirty worktrees, unpushed local commits, missing refs, or Apple upstream merge conflicts. |
| `make upstream-divergence-release-check` | Stable-release check: also fails when a fork `main` is behind Apple upstream. |

Before publishing a Current prerelease, dispatch the full hosted Quality gate
against the exact `main` revision:

```sh
gh workflow run quality.yml --ref main
```

Unlike the changed-file `push` lane, `workflow_dispatch` selects every
non-legacy Swift file for strict SwiftLint and SwiftFormat validation and runs
the complete Address Sanitizer and Thread Sanitizer suites. A failure is a
release blocker even when ordinary push CI is green.

The default Swift line-coverage floors are 90% for `ComposeCore`, 95% for
`ComposeRuntimeSPI`, 75% for the `ComposeContainerRuntime` provider, 50% for
`ComposePlugin`, and 85% across all first-party Swift. Go statement coverage
must remain at least 85%. Override local floors only for deliberate stricter
validation:

```sh
SWIFT_CORE_COVERAGE_MIN=91 \
SWIFT_PROVIDER_COVERAGE_MIN=76 \
SWIFT_AGGREGATE_COVERAGE_MIN=86 \
GO_COVERAGE_MIN=88 \
make coverage-check
```

Target-specific outputs are `coverage-core.*`, `coverage-runtime-spi.*`,
`coverage-provider.*`, `coverage-plugin.*`, and `coverage-aggregate.*`.
`coverage.lcov` and `coverage.xml` are aggregate copies for SonarQube.
Go output remains `Tools/compose-normalizer/coverage.out`.

`make swift-runtime-test` uses the sibling runtime, isolates state under the
marker-protected `.build/container-runtime` directory, retains only the kernel
cache between runs, and always stops the test runtime when it exits. Normal CI
reports the 25 live smoke tests as explicitly skipped with the activation
reason. Both normal and live lanes print authoritative `executed` and `skipped`
counts from the Swift Testing log.

### Isolated macOS Runtime Ownership

Container's data root can be isolated, but its API server and plugin helpers use stable launchd/XPC service names in one namespace for the current macOS user. `make docker-compose-parity`, Current VHS publication, and other long-running Compose workflows therefore acquire the advisory host lock in `Tools/ci/container-runtime-lock.sh` before they stop, start, or replace the runtime.

The default lock is `/tmp/container-compose-runtime-${UID}.lock`; `CONTAINER_RUNTIME_LOCK_FILE` changes it and `CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS` changes the default 10,800-second wait. The helper uses `lockf` on macOS and the equivalent `flock` file-descriptor lock in Linux source-check runners. Every cooperating workflow on the host must use the same lock path. A unique per-job lock defeats serialization, and an external repository or runner that does not acquire the lock can still replace the shared service while a Compose run owns it.

The parity harness also:

- clears only a marker-protected `CONTAINER_RUNTIME_APP_ROOT`, retaining its kernel cache;
- loads `CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE` when supplied, avoiding a cold source rebuild of the exact init image, or falls back to `CONTAINER_RUNTIME_INIT_BLOCK_REPO`;
- starts the exact Container binary and requires a real `container list --all --format json` API round trip;
- stops and restarts that exact runtime at most once after an XPC `Connection interrupted`/`Connection invalid` start or failed API-readiness round trip; and
- always stops the matched runtime when the wrapped command exits.

This recovery is deliberately bounded. The Compose image adapter retries an idempotent pull exactly once for a typed recursive `ContainerizationError.interrupted`. It never blindly replays container deletion; an interrupted delete is accepted only when direct discovery confirms the container is absent. Other errors and unverifiable postconditions fail normally.

For an authoritative same-host result, first coordinate or quiesce every self-hosted runner and local workflow that can operate Container under the same user. A momentarily idle runner is not proof of isolation because it can accept work during the suite. Restore any paused runner immediately after the controlled window.

Set `PARITY_EVIDENCE_DIR` to retain raw timing TSV, JUnit, runtime fingerprints, the human matrix, and a captured aggregate log in one named directory. `PARITY_REPETITIONS` controls equivalent fixture samples and `PARITY_TIMEOUT_SECONDS` bounds each timed operation. Keep the exact Container and Containerization revisions, host model, macOS version, Docker Compose/Engine versions, images, and warm/cold state with the result.

### Temporary CodeQL Pause

As of 30 July 2026, GitHub reports `.github/workflows/codeql.yml` as `disabled_manually` at the owner's request. The workflow source and the required `CodeQL` branch-protection context remain in place. Draft, ready-for-review, push, and scheduled events produce no CodeQL run while it is disabled, so a missing check is not a successful security result.

Do not re-enable CodeQL until the owner explicitly requests it. The supported local replacement is checksum-pinned to CodeQL bundle `2.26.2` and its bundled `codeql/go-queries@1.6.7` query pack, matching the explicit immutable `2.26.2` release-asset URL in the workflow's `tools` input. The matching official Go `1.26.3` archives are pinned for Darwin ARM64, Darwin x86-64, and Linux x86-64. GitHub CLI `2.96.0` is pinned independently to the official macOS ARM64, macOS x86-64, and Linux x86-64 archives used for credential lookup and authenticated API reads; package-manager paths and custom executable overrides are unsupported. Only downloaded archive bytes persist under ignored `.local/share/codeql/`. Before each operation, the workflow opens the selected cache entry without following a leaf symlink, copies and hashes those bytes once into a randomized private directory, rejects any digest other than the reviewed platform SHA-256, extracts there, and retains that private installation until analysis or upload-receipt confirmation finishes. It then deletes the private installation, so no verified executable is reopened from the mutable shared cache. The sole supported entry is to source `Tools/ci/codeql-entry.sh` from a Bash or Zsh process containing neither the `GITHUB_TOKEN` nor `GH_TOKEN` shell variable, then invoke `container_compose_codeql <goal>`; do not run `codeql-make.py` or the underlying Make goals directly. A shell can expand an inherited tracing prompt before any function body can disable it, so the supported caller is credential-free and has tracing disabled. The entry records the incoming shell flags, disables tracing, and rejects an already-traced caller before it can start Python or acquire a credential; it separately rejects any credential variable. Before the first caller-shadowable command or new executable inside the function, it removes every enabled shell function in its subshell (using POSIX-priority builtins in Bash and Zsh's enabled-function table), disables tracing, uses explicit builtins to unexport the complete inherited environment, re-exports only reviewed goal-specific data, and directly execs isolated absolute Python. Native-loader controls and inherited command functions therefore cannot execute in an intermediate helper. For real upload, the privately extracted pinned GitHub CLI reads its authenticated keyring only after that clean boundary; the resulting token remains in memory/environment only for the one upload and receipt-confirmation process group and never appears in an argument. The Python launcher requires that clean-process boundary, rejects any surviving `LD_*`, `DYLD_*`, or `__XPC_DYLD_*` control, allowlists its Make inputs, and then execs absolute GNU Make with built-ins disabled and an explicit repository Makefile. The Make recipes invoke the inner `/usr/bin/python3 -I` directly, defer unrelated Markdown discovery to absolute system Git, capture every configurable CodeQL value as literal data, and export those values instead of interpolating them into shell source. Caller `PYTHONPATH`, `sitecustomize`, `PATH`, shell metacharacters, or Make-function/eval text therefore cannot execute before the evidence workflow establishes its controls. Git, the archive extractor, and the downloader are likewise selected only from reviewed absolute system locations, run with the allowlisted environment, and recorded by resolved path, version, and executable hash. Caller proxy and custom certificate variables may support unauthenticated archive and module retrieval, but exact `git ls-remote` ref verification and the credential path are independently narrowed before token selection: canonical remote identity, credential-bearing CodeQL, and GitHub CLI processes receive no caller proxy, `SSL_CERT_FILE`, or `SSL_CERT_DIR` and use direct system trust. Downloading the CodeQL bundle is subject to the [GitHub CodeQL Terms and Conditions](https://securitylab.github.com/tools/codeql/license/). Update the CodeQL CLI, query pack, Action tool input, Go and GitHub CLI versions, release URLs, checksums, tests, and reviewed empty-or-dispositioned baseline together.

A supported caller is also trap-free, with Bash `functrace`/`errtrace` and shell xtrace disabled. The entry clears inherited Bash `DEBUG`, `RETURN`, and `ERR` handlers under special-builtin precedence, disables their inheritance modes, and rejects the recorded unsafe flags before any new executable. Zsh trap functions are captured and atomically disabled with the complete enabled-function table, then likewise cause rejection. This prevents a trap from restoring a native-loader export immediately before Python starts; caller trap code remains outside the supported boundary and must not be treated as sanitizable input.

Caller `TMPDIR`, `TMP`, and `TEMP` are discarded rather than passed through. The analyzer validates a fixed root-owned system temporary parent, requires sticky protection whenever it is group/other writable, and places analysis work, exact clones, caches, private verified tools, private credential tools, and upload snapshots beneath that non-replaceable parent. Only the explicitly untrusted retained evidence projection is copied back to the configured artifact root, and it is immediately re-authenticated against the in-memory analysis digests.

Run the exact normalizer build and retain its database, SARIF, and verification manifest under `.build/codeql/<full-commit>/`:

```sh
# Run these commands in a trap-free, untraced shell started without GITHUB_TOKEN or GH_TOKEN.
. Tools/ci/codeql-entry.sh
container_compose_codeql codeql-local
```

The target uses the same tracked `go-build` target and `.github/codeql/codeql-config.yml` as hosted analysis. Both paths explicitly analyze the hosted authority's `linux/amd64` Go target with toolchain `go1.26.3`. The local path selects GNU Make from a fixed system location and resolves Go only from a privately extracted, hash-authenticated copy of the official archive; it records each absolute operation-private path, version, executable hash, archive URL, platform, and archive hash. It invokes GNU Make by absolute path and sets the recorded build `PATH` to that Go executable's directory plus `/usr/bin:/bin:/usr/sbin:/sbin`; CodeQL can prepend its required Go tracing shim, but the shim can delegate only to the selected compiler. `GOTOOLCHAIN=local` forbids toolchain fallback, while a new temporary `GOMODCACHE` and `GOCACHE` are created for every scan. Module loading is read-only, uses only `https://proxy.golang.org` with `sum.golang.org`, clears private/no-sum bypasses, and disables direct VCS fallback, so neither an existing user toolchain/module cache nor unverified dependency source participates. The hosted source applies the same cache, proxy, checksum, read-only, and no-fallback policy after `setup-go` installs the exact version from `go.mod`. Exact-source Git operations use the recorded absolute system Git executable with prompting disabled, global/system configuration and replacement objects disabled, executable local settings such as `core.fsmonitor`, hooks, credential helpers, and external protocols overridden, and canonical remote inspection performed outside the checkout's local configuration. Cleanliness checks never call Git status or diff conversion machinery: they compare the exact HEAD tree to the index, then compare each raw regular-file or symlink value to its blob and enumerate untracked paths using only the reviewed root ignore file. Local/global filters and `.git/info/attributes` therefore cannot launch an unrecorded process or rewrite the upload boundary. The tool takes `HOME` from the account database and constructs an allowlisted process environment before applying the recorded pins, so caller executable wrappers, inherited Make rule/flag variables, shell startup hooks, compiler selectors, Go workspaces, Go environment files, and other caller build overrides cannot change extraction. It creates a temporary independent clone outside the checkout through normal Git transport, detaches the exact commit, rejects shared alternates and corrupt objects as well as any changed, untracked, or unexpected ignored checkout input, and revalidates the object database, head, tree, index, raw worktree, and complete untracked set after database creation while allowing only the expected ignored normalizer binary. This preserves authentic Git metadata for the Makefile while preventing checkout-only or mid-analysis inputs from entering exact-commit evidence. CodeQL reports that Go does not enforce configuration path filters, so the local target separately fails if any tracked `.go` file exists outside `Tools/compose-normalizer/` or a tracked root Go workspace appears; expanding the supported surface therefore requires an explicit reviewed change. The target emits fixed SARIF 2.1.0 with run automation ID `/language:swift-go/`, which GitHub maps to the historical analysis category `/language:swift-go`. It fails every result absent from `.github/codeql/codeql-baseline.json`, and also fails stale, incomplete, or mismatched dispositions. Never add a baseline result without maintainer, date, rationale, and security disposition review.

SARIF upload is deliberately separate and fail-closed. Authenticate the GitHub CLI keyring with `gh auth login` before entering the credential-free shell, push the exact commit to the intended ref, verify without reading a token, and then upload. Environment token credentials are intentionally unsupported because caller tracing can run before a sourced function begins:

```sh
# Run these commands in a trap-free, untraced shell started without GITHUB_TOKEN or GH_TOKEN.
. Tools/ci/codeql-entry.sh
commit="$(git rev-parse HEAD)"
CODEQL_UPLOAD_REF=refs/heads/main \
CODEQL_UPLOAD_COMMIT="$commit" \
  container_compose_codeql codeql-sarif-upload-dry-run
CODEQL_UPLOAD_REF=refs/heads/main \
CODEQL_UPLOAD_COMMIT="$commit" \
  container_compose_codeql codeql-sarif-upload
```

The dry run validates retained evidence but deliberately reads no token and performs no analysis or upload. Retained `.build` SARIF and its adjacent manifest are inspectable evidence, not upload authentication. Every real upload reruns the verified analyzer against the exact commit, carries that invocation's expected manifest and SARIF digests in memory, then privately extracts a second hash-authenticated CodeQL installation and rejects any retained projection that differs. It copies SARIF through one no-follow descriptor to a private snapshot, hashes the exact copied bytes against the regenerated digest, and uploads only that snapshot. The target also refuses abbreviated commits, repository mismatches, dirty ref substitutions, stale remote refs, unexpected alerts, and GitHub processing warnings. Its canonical remote-ref lookup uses the direct-system-trust, no-proxy environment before token selection, and `upload.json` records that identity policy separately from the credential policy. Credential lookup and every authenticated API read use the operation-private official GitHub CLI `2.96.0` selected by platform and archive SHA-256; its path, version, executable hash, archive identity, platform, URL, and archive hash are recorded in upload evidence. Neither a package-manager installation, caller `PATH` wrapper, nor custom `--gh` executable is authoritative. Both private executables remain in place until receipt-bound confirmation completes. The uploader captures GitHub's unique SARIF-upload receipt, polls only that receipt's validated `api.github.com` status URL, follows only its matching `sarif_id` analysis URL, and requires exactly one exact-ref/exact-commit/category analysis with the expected CodeQL version plus rule/result counts. A concurrent upload for the same commit therefore cannot be mistaken for the authenticated snapshot. The receipt and returned analysis identities are recorded beside the SARIF. This can supply the exact CodeQL authority required by a release quality snapshot while the workflow remains disabled. The uploader neither calls the Checks API nor runs the disabled workflow; GitHub can nevertheless attach an automatic neutral `CodeQL` service record to uploaded SARIF. That neutral record is not passed, is not hosted-workflow evidence, and must never be represented as either.

Run `make upstream-divergence-report` before upstream handoff, runtime-stack promotion, or release review work. The report compares `container`, `containerization`, and `container-builder-shim` against their Apple upstream `main` refs, lists fork-only and upstream-only commit subjects, and checks whether Apple upstream can merge cleanly into the local checkout. Use `make upstream-divergence-check` when the review needs a hard failure, and `make upstream-divergence-release-check` before a stable release so an upstream-behind fork cannot be promoted.

GitHub Actions separates source checks, macOS runtime validation, sanitizers,
formatting, CodeQL, SonarCloud, package publication, and Homebrew formula syntax
into focused workflows. Both the full and documentation/formula-only paths
publish the required `CI / Validate` result. The
stable release helper runs `make release-gate` locally against the candidate
tree before source promotion. That gate runs builder-shim coverage, containerization
coverage plus integration, container coverage plus integration, Compose CI, tap
formula syntax, the isolated Swift runtime suite, and the pinned Compose comparison
suite, including live `build --check` against the matched container backend.
The Container integration segment uses a per-candidate ignored test app/log root,
so it cannot inherit or leave persistent macOS runtime state between release-gate
runs. GitHub-hosted macOS runners cannot launch
nested Virtualization.framework guests, so the post-tag Stable Release Gate runs
the `make release-gate-hosted` equivalent from its immutable release-control
checkout against immutable source, runtime, and tap checkouts instead. It
validates the non-virtualized stack and Compose CI; the local full gate remains
mandatory for runtime integration and Docker Compose parity. When release
preparation changes `container`'s exact `containerization` package pin, the
helper applies the sole deterministic automation exception above: it verifies
one release-generated commit changes only `Package.swift` and
`Package.resolved`, runs `make check test`, fast-forwards the reviewed remote
main, and verifies the exact published head so Compose SwiftPM can resolve it.
It then runs the complete assembled-stack local gate before
it promotes `container-compose` through an automated pull request by default,
verifies the promoted main tree still matches the locally gated candidate before
it tags, and refuses to promote any other sibling source main: feature changes
must already be merged through their own reviewable pull requests. A
successful hosted gate records a candidate-bound GitHub Actions release-authority
check on that tag commit; the package workflow requires that check, then repeats
`make ci` before it publishes assets or updates the tap.

The package workflow also requires the repository secrets
`DEVELOPER_ID_APPLICATION_P12_BASE64` and
`DEVELOPER_ID_APPLICATION_P12_PASSWORD`. It imports that certificate into a
temporary non-extractable keychain only after release authority is established,
signs every Mach-O executable in the matched Compose and Container archives
with the hardened runtime and a secure timestamp, verifies the complete
archives, and removes the keychain before attestation or publication. A
missing, expired, ad hoc, mixed-team, untimestamped, or non-hardened signature
fails the release.

Phase 5 promotions have no Builder-suite exception. Apple
[`container@d1d7635`](https://github.com/apple/container/commit/d1d763530df3c6a326dbae7f0c0a59a335808045)
fixed the shared Builder startup race and moved the complete coverage into
parallel `TestCLIBuilder`, `TestCLIBuilderLocalOutput`, and
`TestCLIBuilderTarExport` suites. The signed fork synchronizes that ancestry in
[`1bc3167`](https://github.com/stephenlclarke/container/commit/1bc31674629287f3386637db4c6d8652dc36602a)
and limits its follow-up
[`abed15f`](https://github.com/stephenlclarke/container/commit/abed15fdd0cafe340f8aceb65080e4a88d0ceb0a)
to a named lifecycle fixture. The local full gate runs every Container suite,
including existing Dockerfiles outside the build context and direct,
directory, repeated-directory, and invalid tar exports. The hosted gate
continues to omit all Virtualization.framework integration rather than
filtering individual suites.

`make docker-compose-build-external-dockerfile-parity` adds the adapter-level
proof: Docker Compose V2 and `container compose` must project the same config
and bake paths, then build and run the same external-Dockerfile fixture through
their live engines. The release helper no longer accepts
`CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON`.

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
candidate assets. The Current Homebrew pair uses the monotonically increasing
package-workflow run number before the source SHA in its shared formula
version. Both `container-current` and `container-compose-current` receive that
same version, so `brew upgrade container-current container-compose-current`
recognizes each newer atomic pair even when the new commit SHA sorts below the
prior SHA.

### Scheduled Stable Releases

**Scheduled Stable Release** runs every Monday at 09:17 UTC and promotes the next minor version with `-+-` when the Current build has soaked for seven days and `main` contains source newer than the latest semantic tag. It ends successfully without allocating the release runner when either condition is not met, so an unready week is not a failed release. A manual dispatch of the same workflow permits either `-+-` (minor) or `+--` (major); patch, exact-version, and documented security releases remain explicit local helper invocations.

The scheduled stable-release workflow and the Current package workflow run only from `main` on the dedicated `container-compose-release` Apple-silicon self-hosted runner. It creates clean, disposable stack checkouts, reconstructs the read-only Apple remotes and Stephen-owned push remotes, and invokes the existing helper unchanged. That preserves the required local runtime and Docker Compose parity gate, signed semantic tag, source-promotion pull request, hosted stable gate, immutable package assets, paired Homebrew update, and the live Current VHS recording. GitHub-hosted macOS workers cannot provide the nested virtualization needed to record Container guest startup, so they must never publish that recording.

Bootstrap that runner once on the release Mac after its normal build prerequisites and GitHub CLI login are in place:

```sh
./scripts/install-scheduled-release-runner.sh
```

The installer verifies hardware virtualization, the Git author identity and SSH tag- and commit-signing configuration, that the signing key can operate without an interactive passphrase, the local `gh` account, and the release toolchain before it registers a repository-only runner and starts its standard `launchd` service. Rerun the same command during normal release maintenance: it queries the latest GitHub Actions macOS ARM64 runner asset, verifies its published SHA-256 digest before stopping anything, and, when the configured runner is stale, replaces only the runner program files, confirms the installed version, and restarts the existing registration and `launchd` service. It uses the logged-in account through the macOS keychain at run time; it does not copy the GitHub token or SSH commit/tag signing key into an Actions secret. The separate Developer ID Application certificate used for release-binary signing is held in the repository secrets named above and is handled only by the temporary package-job keychain.

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
when necessary and preserves the exact runtime stack pin. Compose source can be
promoted only through a short-lived pull request. The helper verifies the PR
still names the locally gated full commit, requires every earlier Codex thread
to have a later Stephen response and be resolved, posts the literal
`@codex review`, and waits for either the connector's thumbs-up on that request
or its explicit no-major-issues comment naming the expected commit prefix. A
new query, changed head, truncated review response, malformed evidence, or
timeout fails closed. Answer and resolve a surfaced query, revalidate any diff
change, and rerun the release command; the rerun posts a fresh exact-head review
request. Only after that clean decision does the helper wait for PR checks. It
immediately revalidates the head, review threads, and clean signal before a
`--match-head-commit` merge, and repeats those gates before the optional
solo-maintainer checked-admin merge. It never enables auto-merge.

`CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=pr` is the only supported
mode. The retired `direct` value is rejected even for maintenance or security
releases; neither intent bypasses review. After the reviewed PR merges, the
helper creates a signed semantic tag, waits for the hosted Stable Release Gate,
then dispatches the stable package workflow. That workflow rebuilds and
publishes the immutable stable assets and atomically updates both stable
Homebrew formulae. Do not create a semantic tag, copy a prerelease asset, or
edit either stable formula by hand.

If a hosted gate fails before the semantic GitHub release is created, correct the release automation on `main` and rerun the same explicit version, for example `make release VERSION_SELECTOR=X.Y.Z`. The helper reuses only the latest existing GitHub-verified signed source tag, reruns the gates and package workflow, and refuses to change a tag or overwrite an existing semantic release. The package job checks out and verifies the workflow commit's immutable release-control tools before it stages notes or publishes assets, while compiling package content only from the signed source tag. A stable retry can therefore repair release automation on `main` without retagging or changing the release payload. If the semantic GitHub release is published but its stable Homebrew formula pair is absent or incomplete, the same command dispatches formula-only recovery. It validates the existing immutable Compose and runtime assets and updates only the paired stable formulae; it never rebuilds a package, changes a signed tag, or replaces release assets.

After the tag is published, the one mutable `current` prerelease continues to
follow later green `main` commits. Homebrew users without `-current` always use
the newly promoted stable formula pair; opted-in users continue to use the
current pair.

Each package note begins with a quality snapshot for its exact commit: the eleven SonarQube quality metrics shown in the README plus CodeQL analysis, result, and rule counts. The normal release path emits all fourteen metrics as individual static Shields-compatible badges and uploads the same metrics as one self-contained SVG evidence asset. Every publication uses a unique static delivery key and Shields' maximum supported five-day cache lifetime, so a successfully verified static badge is not needlessly re-fetched through GitHub's image proxy while the release remains current. The controller asks GitHub to render the exact release Markdown, fetches every resulting GitHub-proxied image, and parses every payload as SVG before publication can continue. A badge-host, GitHub image-proxy, SonarCloud, CodeQL, or GitHub Actions authority-query failure therefore blocks the release rather than producing an unverified or broken note. Both publish-context resolution and quality-snapshot capture retry transient GitHub `429` and `5xx` responses twelve times; exhaustion fails the package workflow visibly instead of reporting a successful skip and leaving Current stale. The workflow-run gate also retries the short GitHub jobs-API window in which a completed CI run can still expose a null aggregate `Validate` conclusion, and it publishes only after every relevant conclusion is populated and the normal success-or-intentional-skip policy passes. A Current package accepts only an exact-main successful CI run with a passed SonarQube scan and retained per-metric history, whether that CI was triggered by a push or by an explicit full-validation dispatch; a docs-only run simply leaves the existing Current release in place.

SonarCloud can discard an older analysis and its metric history after a later `main` scan, even while GitHub retains the immutable semantic tag, the exact SonarCloud check run, and the exact CI job. Stable publication alone therefore has a retention-aware path: when the exact metric history is absent, it requires both a successful `SonarCloud Code Analysis` check attached to the promoted commit and a successful `SonarQube scan` step in a successful exact-commit `main` CI run. It uses that evidence immediately only when SonarCloud already exposes a different analysis completed after the exact scan; otherwise it honors the configured polling window so normal analysis and measure-history indexing can produce the full snapshot before classifying the history as expired. The same wait applies when the analysis record is visible but some required metrics are not yet indexed. The resulting fallback snapshot labels the SonarQube quality gate as passed and the historical metrics as expired, links both retained authorities, keeps the exact CodeQL counts, and states that no later metrics were substituted. A missing, failed, mismatched, or unreadable authority still blocks publication. This path is not available to mutable Current builds and never converts a transient metric API error into retention evidence. The SVG stays a downloadable evidence artifact and is not embedded inline, because GitHub release pages serve release assets as attachment data rather than reliable inline SVG images. Current-build snapshots refresh whenever the mutable `current` pointer moves; stable snapshots are immutable historical evidence.

## Docker Compose Parity

Run every maintained Docker Compose v2 comparison in deterministic sequence:

```sh
make docker-compose-parity
```

The aggregate target requires Docker Compose `5.3.1`, pins Docker's e2e fixtures to commit `f32009d4a2c687dd405398cc7975d12dccaf8dff`, builds the sibling runtime when available, starts it with isolated state, builds `compose`, runs each target in `DOCKER_COMPOSE_PARITY_TARGETS`, and stops the runtime on exit. The reference scripts establish Docker behavior; the isolated runtime suite and the Compose side of each comparison establish local behavior. [STATUS.md](STATUS.md) owns the support ledger.

The latest controlled run on 30 July 2026 completed all 62 maintained targets without interruption in 1,152.03s against Docker Compose 5.3.1 and Docker Engine 29.2.1. Its embedded three-repetition warm-image bridge comparator measured Docker/container-compose `up` medians of 0.153s/1.228s (8.01×) and `down` medians of 10.178s/5.916s (0.58×). Named-network service discovery and links passed their live behavioral and timing oracles; service-discovery startup improved 13.0% from its pre-optimization candidate baseline but remained 8.81× slower than Docker. Exact revisions, host, warnings, timing tables, and evidence paths are recorded in [STATUS.md](STATUS.md#latest-controlled-full-suite-evidence). The green 10× bridge guard does not make the slower startup comparable to Docker or complete the broader performance matrix.

This functional suite is part of the project's [macOS Docker Compose parity
and performance goal](STATUS.md#project-goal-macos-docker-compose-parity-and-performance),
not a substitute for performance evidence. Changes on a measured execution
path must also retain same-host Docker Compose benchmark evidence for the
representative workloads and reporting requirements in that goal.

### Lifecycle Performance Matrix

Run the standalone local comparator when changing lifecycle performance:

```sh
make docker-compose-performance-matrix
```

It serializes ownership of the local runtime and compares warm-image detached
`up` and `down --volumes --remove-orphans` for 1, 10, and 50 independent
services. It writes raw monotonic TSV, JUnit XML, exact runtime fingerprints,
and a median/P95 Markdown matrix under `PARITY_EVIDENCE_DIR` (or its default
performance-matrix path). `PARITY_REPETITIONS` defaults to five; do not use a
debug candidate or fewer samples as release-grade performance evidence. Logs,
`develop.watch` sync, and build-context transfer still require their own
matrix lanes; see [the remaining-gap register](STATUS.md#what-prevents-100-parity).

Run a focused target directly while iterating:

| Area | Targets |
| --- | --- |
| CLI and project loading | `docker-compose-cli-surface-parity`, `docker-compose-compatibility-names-parity`, `docker-compose-config-all-resources-parity`, `docker-compose-env-file-parity`, `docker-compose-format-template-actions-parity`, `docker-compose-git-remote-parity` |
| Compose Bridge | `docker-compose-bridge-parity` |
| Build | `docker-compose-build-builder-parity`, `docker-compose-build-check-parity`, `docker-compose-build-external-dockerfile-parity`, `docker-compose-build-external-secret-parity`, `docker-compose-build-isolation-parity`, `docker-compose-build-no-cache-filter-parity`, `docker-compose-build-secret-metadata-parity` |
| Mounts and resources | `docker-compose-bind-create-host-path-parity`, `docker-compose-bind-propagation-parity`, `docker-compose-image-volumes-parity` (Docker image `VOLUME` reference, Compose-model projection, and live macOS first-use/reuse validation when `CONTAINER_COMPOSE_LIVE=1`), `docker-compose-volume-labels-parity` (also verifies anonymous-volume identity), `docker-compose-deploy-endpoint-mode-parity`, `docker-compose-deploy-resource-reservations-parity`, `docker-compose-pids-limit-parity`, `docker-compose-device-cgroup-rules-parity`, `docker-compose-devices-parity`, `docker-compose-gpus-parity` |
| Networking | `docker-compose-network-driver-opts-parity`, `docker-compose-network-attachable-parity`, `docker-compose-network-ipv6-parity`, `docker-compose-network-ipam-options-parity`, `docker-compose-network-service-discovery-parity`, `docker-compose-links-parity`, `docker-compose-host-namespaces-parity` (live `network_mode: bridge` inspection and same-host Docker lifecycle timing evidence when `CONTAINER_COMPOSE_LIVE=1`; tune samples and timeouts with `PARITY_REPETITIONS` and `PARITY_TIMEOUT_SECONDS`) |
| Lifecycle and observability | `docker-compose-up-exit-code-from-parity`, `docker-compose-up-menu-parity`, `docker-compose-health-wait-parity`, `docker-compose-create-options-parity`, `docker-compose-events-parity`, `docker-compose-state-status-parity`, `docker-compose-rm-parity`, `docker-compose-lifecycle-hooks-parity`, `docker-compose-signal-log-reliability-parity`, `docker-compose-restart-policy-parity` |

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
The checksum sidecar names only the published archive basename, so a downloaded pair verifies without retaining any build-runner path:

```sh
shasum -a 256 -c container-compose-plugin-release-arm64.tar.gz.sha256
```

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

Local scans do not wait for the quality gate by default. Set `SONAR_QUALITYGATE_WAIT=true` when the token can read quality-gate status.

The current SonarCloud organization plan accepts short-branch reports but rejects short-branch metric, issue, and quality-gate API reads. A local branch scan can therefore prove report processing and scanner warnings through its compute-engine task, but the hosted pull-request check remains the final branch gate authority. Do not describe the polling rejection as an analyzer failure or infer a passed gate from a successful upload.

Main-branch CI keeps the scanner's three-attempt fail-closed policy and gives the step enough time for all three 300-second quality-gate waits, scanner work, and retry delays. The enclosing runtime-validation job separately covers its 45-minute coverage gate, 10-minute CLI smoke, 25-minute Sonar budget, and dependency/setup overhead. A reachable SonarCloud service therefore still blocks CI when every attempt fails, without either workflow timeout killing a valid later attempt.

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
`HAWKEYE_AUTO_INSTALL=1` is set. Local checks prefer a system-wide `hawkeye`
on `PATH` (the shared developer installation); `.local/bin/hawkeye` remains a
repository-local fallback for hermetic CI bootstrap.

Remove build products, coverage data, package archives, and generated helpers
with:

```sh
make clean
```
