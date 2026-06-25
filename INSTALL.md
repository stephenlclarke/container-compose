# Installing container-compose

This guide explains how to install the `container-compose` plugin for the local [`container`](https://github.com/apple/container) CLI. Source build, test, and package steps are covered in [BUILD.md](BUILD.md); branch lane rules are covered in [BRANCHES.md](BRANCHES.md).

## Requirements

- macOS.
- The `container` CLI installed and working on the target machine.
- Either Homebrew access to this repository's branch release assets or a plugin archive from `make package`.

## Install With Homebrew

The `develop` and `main` branches carry a local Homebrew formula that installs prebuilt release assets from GitHub releases instead of building Swift or Go source on the user's machine. Use the same lane for `container` and `container-compose`: `main` is the release lane and `develop` is the debug integration lane. See [BRANCHES.md](BRANCHES.md) for the full lane model.

Install the matching `container` fork branch first. Set `lane=main` for the frozen release lane or `lane=develop` for active debug builds:

```sh
lane=develop
brew tap stephenlclarke/container https://github.com/stephenlclarke/container
git -C "$(brew --repo stephenlclarke/container)" checkout "$lane"
brew install stephenlclarke/container/container
brew services start container
```

Install `container-compose` from the same lane. The formula installs the plugin under the `container-compose` keg; the final plugin registration remains an explicit symlink into the active `container` install root:

```sh
brew tap stephenlclarke/container-compose https://github.com/stephenlclarke/container-compose
git -C "$(brew --repo stephenlclarke/container-compose)" checkout "$lane"
brew install stephenlclarke/container-compose/container-compose
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart container
```

Verify that `container` discovers the plugin:

```sh
container compose version
```

## Install Locally

Build a local plugin archive with `make package`, then install or replace the plugin with:

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

Obtain or build a fresh archive, then replace the installed plugin:

```sh
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

If Compose normalization fails after installation, verify that
`/usr/local/libexec/container-plugins/compose/resources/compose-normalizer`
exists and is executable.
