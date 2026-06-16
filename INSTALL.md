# Installing container-compose

This guide explains how to install `container-compose` as a local
`apple/container` CLI plugin.

For build dependencies and developer workflow details, see
[BUILD.md](BUILD.md).

## Requirements

- macOS with Xcode installed and selected as the active developer directory.
- Go 1.23 or newer for the Compose normalizer helper.
- Python 3 for the repository coverage tooling used by `make ci`.
- A sibling checkout of `apple/container` at `../container` when building from
  source.
- The `container` CLI installed and working on the target machine.

If `swift` resolves to the Command Line Tools toolchain instead of Xcode, set:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Build The Plugin Archive

From the repository root, run:

```sh
make package
```

The package target builds:

```text
container-compose-plugin.tar.gz
dist/compose/bin/compose
dist/compose/config.toml
dist/compose/resources/compose-normalizer
```

## Install Locally

Install or replace the local plugin with:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo mkdir -p /usr/local/libexec/container-plugins
sudo tar -xzf container-compose-plugin.tar.gz -C /usr/local/libexec/container-plugins
```

The resulting plugin layout is:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/compose-normalizer
```

## Verify The Installation

Confirm that `container` discovers the plugin:

```sh
container compose version
```

Run a read-only Compose command from a directory containing a Compose file:

```sh
container compose config
```

## Upgrade

Build a fresh archive and replace the installed plugin:

```sh
make package
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo tar -xzf container-compose-plugin.tar.gz -C /usr/local/libexec/container-plugins
```

## Uninstall

Remove the installed plugin directory:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
```

## Troubleshooting

If `container compose` is not found, verify that
`/usr/local/libexec/container-plugins/compose/config.toml` exists and that the
`container` CLI supports plugin discovery from `/usr/local/libexec/container-plugins`.

If Compose normalization fails while running from source, build the helper with:

```sh
make go-build
```

To force a specific helper binary, set:

```sh
export CONTAINER_COMPOSE_NORMALIZER=/absolute/path/to/compose-normalizer
```
