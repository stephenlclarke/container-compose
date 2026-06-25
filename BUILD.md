# Building container-compose

This guide is for contributors who need to build, test, and package
`container-compose` from source. It stops at producing the plugin archive used
by installers; target-machine installation steps live in [INSTALL.md](INSTALL.md).

## Requirements

- macOS with an Apple Swift 6.2 or newer toolchain. Xcode from the Mac App Store,
  Xcode from <https://developer.apple.com/download/>, or the Apple Command Line
  Tools can provide the required Swift compiler.
- Go 1.23 or newer for the Compose normalizer helper. Install Go from
  <https://go.dev/dl/> or with Homebrew:

  ```sh
  brew install go
  ```

- The [`apple/container`](https://github.com/apple/container) source checkout.
  The Swift package references it as a sibling path dependency at
  `../container`.
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

Clone [`apple/container`](https://github.com/apple/container) and
`container-compose` as sibling directories:

```sh
mkdir -p ~/github
git clone https://github.com/apple/container.git ~/github/container
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

For the local-only `events` parity check added with the fork-backed event-stream slice, run:

```sh
make docker-compose-events-parity
```

This runs Docker Compose V2 against a temporary project and validates the event behavior mirrored by `container-compose`: JSON output, container-event scope, selected-service filtering, internal Compose label stripping, and one-off container suppression. The target is not used by `make ci` because Apple-facing CI must not require Docker or Docker Compose.

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

`make package` is an alias for the release package. Build a specific lane archive with:

```sh
make package-release
make package-debug
```

`make package` uses the same `SWIFT_RELEASE_FLAGS` as `make build-release`.

The default local package target writes the archive, checksum, and staging directory:

```text
container-compose-plugin-release-arm64.tar.gz
container-compose-plugin-release-arm64.tar.gz.sha256
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/compose-normalizer
```

GitHub Actions publishes branch release assets for `main` and `develop` using branch-specific archive names such as `container-compose-plugin-main-release-arm64.tar.gz` and `container-compose-plugin-develop-debug-arm64.tar.gz`. The release lane builds optimized archives from `main`; the debug integration lane builds debug archives from `develop`. The Homebrew formulas consume those prebuilt assets so target machines do not need Go, Xcode, or a Swift toolchain just to install.

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
SONAR_BRANCH=develop make sonar
```

When coverage has already been generated by `make ci`, run only the scanner
step with:

```sh
SONAR_BRANCH=develop make sonar-scan
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
