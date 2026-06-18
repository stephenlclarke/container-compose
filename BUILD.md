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

`make ci` runs required Markdown linting, Python coverage-tool tests, Go formatting checks, Hawkeye license-header checks, Swift and Go coverage, the coverage threshold gate, the Go helper build, and the CLI smoke test. Swift build and test targets use the checked-in `Package.resolved` by default so CI fails quickly if dependency versions need an intentional lockfile refresh. The smoke test builds the debug `compose` executable before exercising representative commands.

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

## Package Archive

Build the plugin archive consumed by the install guide:

```sh
make package
```

GitHub Actions builds and uploads this archive for `main` branch pushes and manual workflow runs. Pull requests run validation and SonarQube analysis without producing a package artifact, which keeps review feedback faster and avoids unnecessary release builds.

`make package` uses the same `SWIFT_RELEASE_FLAGS` as `make build-release`.

The package target writes the archive and staging directory:

```text
container-compose-plugin.tar.gz
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/compose-normalizer
```

Use [INSTALL.md](INSTALL.md) to install, upgrade, verify, or remove the packaged
plugin on a target machine.

## Runtime Boundary

The build produces two executables with separate responsibilities:

| Component | Language | Responsibility |
| --- | --- | --- |
| `compose` | Swift | Parse Docker Compose style CLI arguments, validate normalized projects, plan orchestration, and call Apple/container runtime APIs or compatibility commands. |
| `compose-normalizer` | Go | Load Compose files with `compose-go` and emit canonical JSON. It does not create, start, stop, or inspect containers. |

The installed plugin layout is:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/compose-normalizer
```

### Direct API Adapters

The Swift layer uses direct Apple/container APIs wherever a stable API maps
cleanly to a Compose operation.

| Compose surface | Direct Apple/container path |
| --- | --- |
| Project discovery, `ps`, `images`, recreate checks, indexed service targets, `port`, and orphan cleanup | `ContainerClient.list(filters:)` and `ContainerClient.get(id:)` |
| Project networks | `NetworkClient.create(configuration:)`, `NetworkConfiguration(mode:ipv4Subnet:ipv6Subnet:)`, and `NetworkClient.delete(id:)` |
| Project volumes | `ClientVolume.create(name:driver:driverOpts:labels:)`, `ClientVolume.list()`, and `ClientVolume.delete(name:)` |
| Image pull, inspect, push, and delete | `ClientImage.pull`, `ClientImage.get`, `ClientImage.push`, `ClientImage.delete`, and `ClientImage.cleanUpOrphanedBlobs()` |
| Service lifecycle | `ContainerClient.bootstrap(id:stdio:dynamicEnv:)`, `ClientProcess.start()`, `ClientProcess.wait()`, `ContainerClient.stop(id:opts:)`, `ContainerClient.delete(id:force:)`, and `ContainerClient.kill(id:signal:)` |
| Logs and output-only attach | `ContainerClient.logs(id:)` |
| Attached and detached exec | `ProcessIO.create(tty:interactive:detach:)`, `ContainerClient.createProcess(containerId:processId:configuration:stdio:)`, `ProcessIO.handleProcess(process:log:)`, and `ClientProcess.start()` |
| Stats | `ContainerClient.stats(id:)` with stopped-container metadata from `ContainerClient.list(filters:)` |
| Copy and export | `ContainerClient.copyIn`, `ContainerClient.copyOut`, and `ContainerClient.export(id:archive:)` |

### CLI Compatibility Adapter

Some supported surfaces still route through the installed `container` CLI
because this repository does not yet have a focused direct adapter for that
operation or because the CLI is the available public compatibility surface.

| Compose surface | CLI path |
| --- | --- |
| Build | `container build --pull --platform --cache-in --cache-out --tag --label --secret --file` |
| Container create/run options not yet exposed through a focused adapter | `container create` and `container run` flags such as `--network none`, `--network <name>,mac=...,mtu=...`, `--publish`, `--volume`, `--tmpfs`, and `--mount type=tmpfs` |
| Dry-run output | Renders equivalent `container` commands without mutating runtime state |

Unsupported Docker Compose behavior is rejected before resources are created.
For example, dynamic host-port allocation is not translated because
Apple/container currently requires explicit host ports for `--publish`.

Apple publishes public DocC documentation for
[`container`](https://apple.github.io/container/documentation/) and
[`ContainerClient`](https://apple.github.io/container/documentation/containerclient/).
Use those references when adding future direct Swift adapters or identifying
Apple/container runtime gaps.

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
