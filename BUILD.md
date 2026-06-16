# Building container-compose

This guide describes how to build, test, and package `container-compose` from
source.

## Requirements

- macOS with Xcode installed. The package targets macOS 15 and uses the Swift
  toolchain supplied by Xcode. Install Xcode from the Mac App Store or
  <https://developer.apple.com/download/>.
- Go 1.23 or newer for the Compose normalizer helper. Install Go from
  <https://go.dev/dl/> or with Homebrew:

  ```sh
  brew install go
  ```

- The `apple/container` source checkout. The Swift package references it as a
  sibling path dependency at `../container`. Obtain it from
  <https://github.com/apple/container>.
- Python 3 for coverage conversion and coverage threshold checks. macOS
  developer machines usually already have `python3`; it can also be installed
  from <https://www.python.org/downloads/> or with Homebrew.
- Optional: `markdownlint` or `markdownlint-cli2` for Markdown linting. The
  Makefile skips Markdown linting when neither command is installed.
- Optional: `sonar-scanner` and `SONAR_TOKEN` for local SonarQube scans.

If `swift` resolves to the Command Line Tools toolchain instead of Xcode, set:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Checkout Layout

Clone `apple/container` and `container-compose` as sibling directories:

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

Run the same validation used by GitHub Actions:

```sh
make ci
```

`make ci` resolves Swift packages, lints available local sources, builds the
Swift package, runs Swift and Go coverage, checks the coverage threshold, and
builds the Go helper.

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
```

## Package

Build the installable plugin archive:

```sh
make package
```

The package target creates:

```text
container-compose-plugin.tar.gz
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/compose-normalizer
```

For installation, upgrade, and removal steps, see [INSTALL.md](INSTALL.md).

## SonarQube

GitHub Actions publishes coverage to SonarCloud for `main` and eligible pull
request runs. To run the same scanner locally, install `sonar-scanner`, export a
token, and run:

```sh
export SONAR_TOKEN=...
make sonar
```

`make sonar` regenerates coverage before invoking `sonar-scanner`.

## Cleanup

Remove build products, coverage reports, the package archive, and generated Go
helper binaries:

```sh
make clean
```
