# Building container-compose

This guide is for contributors who need to build, test, and package
`container-compose` from source. It stops at producing the plugin archive used
by installers; target-machine installation steps live in [INSTALL.md](INSTALL.md).

## Requirements

- macOS with an Apple Swift 6.2 or newer toolchain. Xcode from the Mac App Store,
  Xcode from <https://developer.apple.com/download/>, or the Apple Command Line
  Tools can provide the required Swift compiler.
- Keep the local Swift toolchain aligned with the version used by the Apple
  `container` and `containerization` repositories for the lane being tested.
  Those projects can adopt Swift APIs and standard-library/runtime behavior with
  the toolchain; building this fork stack with a different Swift version can
  fail because functions are missing, renamed, or called with different
  signatures.
- Go 1.23 or newer for the Compose normalizer helper. Install Go from
  <https://go.dev/dl/> or with Homebrew:

  ```sh
  brew install go
  ```

- The matching [`stephenlclarke/container`](https://github.com/stephenlclarke/container) source checkout for the lane being tested. The Swift package references it as a sibling path dependency at `../container`. Use Apple's upstream `container` checkout only when deliberately testing upstream compatibility gaps.
- Python 3 for coverage conversion and coverage threshold checks. macOS
  developer machines usually already have `python3`; it can also be installed
  from <https://www.python.org/downloads/> or with Homebrew.
- Node.js with npm for the required Markdown lint step. Install Node.js from <https://nodejs.org/> or with Homebrew, then install the pinned linter used by CI:

  ```sh
  npm install --global markdownlint-cli@0.48.0
  ```

- Optional: `sonar-scanner` and either `SONAR_TOKEN` or `SONAR_TOKEN_PERSONAL`
  for local SonarQube scans.
- Optional: Docker Engine plus either `docker compose` or `docker-compose` for
  local Docker Compose parity fixture refreshes. Colima works well on macOS
  when Docker Desktop is not used.

If you need to force a specific Apple developer directory, set:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The Makefile uses the active `swift` executable to locate Swift Testing
frameworks and runtime libraries, so Command Line Tools and full Xcode
toolchains are both supported as long as their Swift version satisfies the
package requirement.

## Checkout Layout

Clone [`stephenlclarke/container`](https://github.com/stephenlclarke/container) and `container-compose` as sibling directories:

```sh
mkdir -p ~/github
git clone https://github.com/stephenlclarke/container.git ~/github/container
git clone https://github.com/stephenlclarke/container-compose.git ~/github/container-compose
cd ~/github/container-compose
```

The resulting layout should be:

```text
~/github/container
~/github/container-compose
```

## Build

Build the Swift plugin executable:

```sh
make build
```

Build a release executable:

```sh
make build-release
```

Release builds default to `SWIFT_RELEASE_FLAGS="-Xswiftc -Osize"`. This keeps the package path on release optimization while avoiding a Swift 6.3.2 optimizer crash in the existing async watch loop on this project. To test a newer toolchain without the workaround, run `SWIFT_RELEASE_FLAGS= make build-release`.

Build the Go normalizer helper:

```sh
make go-build
```

All Go outputs in this project are release-quality artifacts. `make go-build` produces the Homebrew-packaged normalizer using `CGO_ENABLED=0`, `-trimpath`, and `-ldflags "-s -w"`, and package targets do not introduce a debug Go helper.

Run the plugin from source:

```sh
swift run compose version
```

When run from a source checkout, `ComposeNormalizer` falls back to
`go run .` in `Tools/compose-normalizer` if no installed normalizer is found.
To force a specific helper binary, set:

```sh
export CONTAINER_COMPOSE_NORMALIZER=/absolute/path/to/compose-normalizer
```

## Test And Coverage

Run Swift and Go tests:

```sh
make test
```

The default Swift test path is static: it covers normalizer output,
orchestration planning, command projection, and adapter behavior without
requiring a live Apple container runtime. Runtime smoke tests live in the
separate `ComposeRuntimeTests` target and are opt-in:

```sh
make swift-runtime-test
```

That target builds `.build/debug/compose`, sets
`CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1`, and runs only the runtime smoke test
filter. Use it when proving real Apple container behavior locally; it is not
part of `make ci`.

Use the Makefile targets for local Swift tests instead of invoking
`swift test` directly. The Makefile derives the Swift Testing framework and
runtime library paths from the active `swift` executable and fails if SwiftPM
builds the test bundle without actually running tests. It follows the
[`apple/container`](https://github.com/apple/container) pattern of building
test products once with coverage instrumentation, then running tests with
`--skip-build` to avoid an extra SwiftPM build pass. Swift coverage export uses
the `llvm-cov` binary from that same toolchain when available; set
`SWIFT_LLVM_COV=/absolute/path/to/llvm-cov` to override it.

Run the same validation used by GitHub Actions:

```sh
make ci
```

`make ci` runs required Markdown linting, Python coverage-tool tests, Go formatting checks, Hawkeye license-header checks, Swift and Go coverage, the coverage threshold gate, the Go helper build, and the CLI smoke test. Swift build and test targets use the checked-in `Package.resolved` by default so CI fails quickly if dependency versions need an intentional lockfile refresh. The CI smoke test reuses the debug `compose` executable emitted by the Swift coverage test build, while standalone `make cli-smoke` still builds the debug executable before exercising representative commands.

GitHub Actions keeps the expensive and security-oriented checks in separate workflows so PR feedback stays narrow and Apple-facing upstream slices can adopt the same checks one at a time:

| Workflow | Trigger | Coverage |
| --- | --- | --- |
| `CI / Validate` | Pushes to `main` and `develop/*`, PRs to `main`, semantic release tags, and manual runs | Runs `make ci` on `main` and PRs, including Swift Testing/XCTest through SwiftPM, Go tests, Markdown linting, Hawkeye license-header validation, coverage gates, and the CLI smoke test. Stable tag validation also builds a release plugin artifact so the package layout stays covered. |
| `Quality / Swift ASan` | Pushes to `main`, every PR, and manual runs | Resolves the current `stephenlclarke/container:main` commit, checks out that exact dependency revision, then runs `swift test --disable-automatic-resolution --sanitize=address`. |
| `Quality / Swift TSan Nightly` | Nightly schedule and manual runs | Resolves the current `stephenlclarke/container:main` commit, checks out that exact dependency revision, then runs `swift test --disable-automatic-resolution --sanitize=thread`. |
| `Quality / SwiftLint/SwiftFormat Advisory` | Pushes to `main`, every PR, and manual runs | Runs `swiftlint lint --strict --quiet Package.swift Sources Tests` and `swiftformat Package.swift Sources Tests --lint --swift-version 6.2`. These checks are advisory until a repo-owned SwiftLint and SwiftFormat baseline/configuration lands, because the current default tools report existing repository-wide style drift. |
| `Homebrew / Formula Syntax` | Pushes to `main`, `develop/*`, semantic release tags, PRs to `main`, and manual runs | Validates the Homebrew formula Ruby syntax and inspects `container-compose` through `brew info`; install flow details live in [INSTALL.md](INSTALL.md). |
| `CodeQL / Analyze Go` | Pushes to `main`, PRs to `main`, weekly schedule, and manual runs | Runs CodeQL over the Go normalizer using the same release build path as packaged Homebrew artifacts. Swift remains covered by `make ci`, ASan, SonarCloud, and focused tests; Swift CodeQL is not part of the push gate because CodeQL's Swift compiler trace rebuilds the fork-backed Apple dependency graph and times out on GitHub-hosted macOS runners before reaching `container-compose` sources. |

SwiftPM on the current Apple Swift 6.3.2 toolchain exposes `address`, `thread`, `undefined`, `scudo`, and `fuzzer` sanitizer modes. It does not expose a separate `leak` mode, so there is no standalone Leak Sanitizer job yet; keep ASan as the PR sanitizer gate and add a dedicated LSan job only when the supported SwiftPM sanitizer list includes it.

Run the faster non-coverage source checks with:

```sh
make check
```

`make check` runs the same lint and license-header checks used at the start of `make ci`.

Apply supported source formatting and license-header updates with:

```sh
make fmt
```

This installs the pinned Hawkeye binary into `.local/bin` when needed, updates license headers, and runs Go formatting. In non-interactive CI, set `HAWKEYE_AUTO_INSTALL=1` so the local installer can run without a prompt.

The default minimum coverage is 85 percent for both Swift and Go:

```sh
make coverage-check
```

Use a different local threshold with:

```sh
COVERAGE_MIN=90 make coverage-check
```

`swift-coverage` retries SwiftPM helper signal failures with `SWIFT_COVERAGE_TEST_ATTEMPTS` but does not accept the signal-13 fallback as a successful coverage run; incomplete profile data would make the report unusable.

Generated coverage reports are:

```text
coverage.lcov
coverage.xml
Tools/compose-normalizer/coverage.out
*.profraw
```

## Docker Compose Parity Fixtures

The normal `make ci` path does not require Docker. For local parity checks against Docker Compose behavior, start a local Docker daemon and run:

```sh
make docker-log-fixtures
```

This runs `examples/logging/compose.yml` through Docker Compose and compares the captured rotated log tail behavior with `Tests/ComposeCoreTests/Fixtures/logging/docker-compose-rotated-tail.expected`. The fixture currently records `logs --tail 5`, `logs --tail 0`, `logs --tail -1`, and `logs --tail all` for rotated `json-file` and `local` logging drivers.

For the local-only command/help surface parity check, run:

```sh
make docker-compose-cli-surface-parity
```

This builds the local `compose` binary, compares root command listings, `bridge` management command listings, and every documented long option against Docker Compose V2, then writes `.build/parity/compose-cli-surface.md`. Known intentional differences are documented in `docs/parity/compose-cli-surface.md` and encoded in `Tools/parity/compose-cli-surface.allowlist`. The target is not used by `make ci` because Apple-facing CI must not require Docker Compose.

For the local-only `build --builder` parity check, run:

```sh
make docker-compose-build-builder-parity
```

This compares Docker Compose V2 `build --builder default --print` and `build --builder NAME --print` with the same `container compose` commands using a daemon-free local fixture. The target proves builder selection stays out of Buildx bake JSON in print mode, while live named-builder execution is covered by the local runtime smoke path. The target is not used by `make ci` because Apple-facing CI must not require Docker Compose.

For the local-only `build.isolation` parity check, run:

```sh
make docker-compose-build-isolation-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with `build.isolation: hyperv`: both preserve the value in `config --format json`, omit it from `build --print` Buildx bake JSON on this platform, and accept the build path without treating the field as an unsupported feature. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only build-secret metadata parity check, run:

```sh
make docker-compose-build-secret-metadata-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with build-secret `uid`, `gid`, and `mode` metadata. Docker Compose preserves those fields in `config --format json` but omits them from BuildKit bake secret entries and accepts the build; `container-compose` mirrors the build behavior by accepting the metadata and projecting only the effective BuildKit secret ID plus file/env source. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only bind `create_host_path` parity check, run:

```sh
make docker-compose-bind-create-host-path-parity
```

This compares Docker Compose V2 and `container-compose` for default bind mounts and explicit `bind.create_host_path: false`. Docker Compose preserves the explicit false policy in `config --format json`, accepts the default bind policy, and rejects a missing source when host-path creation is disabled; `container-compose` mirrors that CLI behavior and creates missing bind source directories itself before Apple runtime handoff when the policy is true or defaulted. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only service volume-label parity check, run:

```sh
make docker-compose-volume-labels-parity
```

This compares Docker Compose V2 and `container-compose` for service long-form `volume.labels`. Docker Compose preserves named and anonymous mount labels in `config --format json`, applies labels only to anonymous runtime volumes, and keeps named service mount labels off the named volume resource; `container-compose` mirrors that behavior by preserving the config metadata, creating labeled anonymous Apple volumes before runtime handoff, and leaving named service mount labels as metadata. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only Deploy endpoint-mode parity check, run:

```sh
make docker-compose-deploy-endpoint-mode-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with `deploy.endpoint_mode: dnsrr`. Docker Compose preserves the Swarm metadata in `config --format json` and accepts local dry-run `up --no-start`; `container-compose` mirrors the local behavior by accepting the metadata without reporting it as an unsupported deploy field. The target is not used by `make ci` because Apple-facing CI must not require Docker Compose.

For the local-only Deploy CPU/memory reservation parity check, run:

```sh
make docker-compose-deploy-resource-reservations-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory`. Docker Compose preserves those scheduler hints in `config --format json` and accepts local dry-run `up --no-start`; `container-compose` mirrors the local behavior by accepting the metadata without reporting those reservations as unsupported deploy fields. The target is not used by `make ci` because Apple-facing CI must not require Docker Compose.

For the local-only device cgroup rule parity check, run:

```sh
make docker-compose-device-cgroup-rules-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with service `device_cgroup_rules`. Docker Compose preserves the rules in `config --format json` and projects them to Docker Engine `HostConfig.DeviceCgroupRules`; `container-compose` preserves the normalized config and maps `up`, `create`, and one-off `run` to repeatable fork-backed `container --device-cgroup-rule` arguments. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only service device parity check, run:

```sh
make docker-compose-devices-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with service `devices`. Docker Compose preserves the mappings in `config --format json` and projects them to Docker Engine `HostConfig.Devices`; `container-compose` preserves the normalized config and maps `up`, `create`, and one-off `run` to repeatable fork-backed `container --device` arguments for the runtime-supported Linux VM device table. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only top-level network `driver_opts` parity check, run:

```sh
make docker-compose-network-driver-opts-parity
```

This compares Docker Compose V2 and `container-compose` for a Compose file with `networks.<name>.driver_opts`. Docker Compose preserves the network options in `config --format json` and projects them to Docker Engine network options; `container-compose` preserves the normalized config and maps those options to Apple network creation through repeatable `container network create --option key=value` arguments in dry-run and `NetworkConfiguration.options` through the direct API path. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only `build --check` parity check, run:

```sh
make docker-compose-build-check-parity
```

This refreshes Docker Compose's upstream e2e fixture checkout, copies `pkg/e2e/fixtures/build-test/minimal` into a temporary directory, tweaks only the copied Dockerfile's `FROM` casing to trigger BuildKit's `FromAsCasing` lint rule, and verifies `container compose build --print --check` renders a Buildx-compatible `call: "lint"` target without image outputs. Set `CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1` to also run live `container compose build --check`; that live mode requires a matching fork-backed `container` build backend and builder image. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only `events` parity check added with the fork-backed event-stream slice, run:

```sh
make docker-compose-events-parity
```

This runs Docker Compose V2 against a temporary project and validates the event behavior mirrored by `container-compose`: JSON output, container-event scope, selected-service filtering, internal Compose label stripping, and one-off container suppression. Standalone `docker-compose` 5.1.4 may print `EOF` after emitting replay output for `events --since/--until`; the script validates the captured output and reports that as a warning. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only restart-policy parity check added with the fork-backed lifecycle slice, run:

```sh
make docker-compose-restart-policy-parity
```

This runs Docker Compose V2 against a temporary project and validates the container `HostConfig.RestartPolicy` shape mirrored by `container-compose`: service-level `restart`, deploy-over-service precedence, deploy `condition: any`, deploy `condition: none`, and `on-failure:0` as an unlimited retry policy. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only `rm` lifecycle parity check, run:

```sh
make docker-compose-rm-parity
```

This runs Docker Compose V2 against a temporary project and validates the `rm` behavior mirrored by `container-compose`: missing service containers report `No stopped containers`, running containers are not removed without `--stop`, and `rm --stop --force` removes a running service container. The target also runs the focused local Swift tests for the same `container-compose` behavior. It is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

For the local-only host namespace parity check, run:

```sh
make docker-compose-host-namespaces-parity
```

This runs Docker Compose V2 against a temporary project and validates the host namespace behavior mirrored by `container-compose`: `network_mode: host` emits the Stephen fork-backed `container --network host` path without attaching the Compose project network, `pid: host` sets Docker-compatible host PID mode while keeping normal service networking, and service/container namespace-sharing forms stay documented unsupported modes in `container-compose`. The target is not used by `make ci` because Apple-facing CI must not require Docker Compose.

For the local-only create-options parity check, run:

```sh
make docker-compose-create-options-parity
```

This target refreshes a sparse checkout of Docker Compose's upstream e2e fixtures under `.build/parity/docker-compose-e2e` only when the checkout is missing or Docker Compose `main` has moved. The temporary parity project copies the current upstream `pkg/e2e/fixtures/build-test/minimal/Dockerfile`, then runs the same fixture through Docker Compose V2 and `container-compose`. The check covers build wiring plus create-time behavior for explicit healthchecks, local and disabled logging, restart policy, deploy restart timing, host-IP published ports, configs, secrets, DNS options, host identity, extra hosts, sysctls, blkio weight, and network aliases. The target is not used by `make ci`.

To refresh only the Docker Compose e2e fixture checkout, run:

```sh
make docker-compose-e2e-fixtures
```

Refresh the checked fixture after intentionally changing the example or adopting a newer Docker behavior with:

```sh
make docker-log-fixtures-update
```

The fixture script skips cleanly when Docker, Docker Compose, or the daemon is unavailable. Use `./scripts/capture-docker-compose-log-fixtures.sh --strict` when an unavailable Docker dependency should fail the local run.

## Package Archive

Build the plugin archive consumed by the install guide:

```sh
make package
```

`make package` is an alias for the release package. Build a local archive with:

```sh
make package-release
make package-debug
```

`make package` uses the same `SWIFT_RELEASE_FLAGS` as `make build-release`. `make package-debug` is a local Swift debugging aid only; it still includes the release-built Go normalizer from `make go-build` and is not a Homebrew lane.

The default local package target writes the archive, checksum, and staging directory:

```text
container-compose-plugin-release-arm64.tar.gz
container-compose-plugin-release-arm64.tar.gz.sha256
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/build-info.json
dist/compose/resources/compose-normalizer
```

GitHub Actions uses the same package layout for published assets. Branch, tag, pre-release, and Homebrew formula policy lives in [BRANCHES.md](BRANCHES.md); target-machine installation lives in [INSTALL.md](INSTALL.md).

Plugin archives include `compose/resources/build-info.json`. The `compose version` command reads that file and reports the package lane, branch, commit, build type, the resolved `container` dependency commit, `containerization` pin from `Package.resolved`, and embedded `compose-go` module version from the Go normalizer. Local development builds fall back to the current git checkout and sibling `../container` checkout when the packaged metadata file is absent.

Use [INSTALL.md](INSTALL.md) to install, upgrade, verify, or remove the packaged plugin on a target machine.

## Runtime Boundary

The build produces two executables: `compose` in Swift and `compose-normalizer` in Go. The architecture and runtime adapter boundary are documented in [DESIGN.md](DESIGN.md).

The installed plugin layout is:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/compose-normalizer
```

## SonarQube

GitHub Actions publishes coverage to SonarCloud for `main` and eligible pull
request runs. To run the same scanner locally, install `sonar-scanner`, export a
SonarCloud token, and run:

```sh
export SONAR_TOKEN=...
make sonar
```

`make sonar` also accepts `SONAR_TOKEN_PERSONAL` when `SONAR_TOKEN` is not set.

`make sonar` regenerates coverage before invoking `sonar-scanner`.
By default it publishes analysis for the current Git branch. Override the
branch when needed:

```sh
SONAR_BRANCH=main make sonar
```

This project uses the free SonarQube/SonarCloud tier, which only tracks one
branch for the project. Treat `main` as the canonical analyzed branch; README
badges are pinned to `main` so they reflect the branch SonarQube is allowed to
retain.

When coverage has already been generated by `make ci`, run only the scanner
step with:

```sh
SONAR_BRANCH=main make sonar-scan
```

Local scans default `SONAR_QUALITYGATE_WAIT` to `false` so branch analysis can
be published even when the local token cannot read Quality Gate status. Set it
to `true` when testing a token with project administration or Quality Gate read
access:

```sh
SONAR_QUALITYGATE_WAIT=true make sonar
```

## License Header Tooling

The project follows the [`apple/container`](https://github.com/apple/container) workflow for license headers by using [Hawkeye](https://github.com/korandoru/hawkeye). The pinned installer lives in `scripts/install-hawkeye.sh`, and `scripts/ensure-hawkeye-exists.sh` protects local runs from silently executing a downloaded installer unless the user opts in or `HAWKEYE_AUTO_INSTALL=1` is set.

Useful targets:

```sh
make check-licenses
make update-licenses
make pre-commit
```

`make pre-commit` installs a local hook that runs `make check` before commits. Set `PRECOMMIT_NOFMT=1` for the rare case where the hook must be skipped locally.

## Cleanup

Remove build products, coverage reports, the package archive, and generated Go
helper binaries:

```sh
make clean
```
