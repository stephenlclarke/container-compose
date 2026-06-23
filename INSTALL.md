# Installing container-compose

This guide starts with an existing `container-compose` plugin archive and
explains how to install it for the local
[`apple/container`](https://github.com/apple/container) CLI. Source build, test,
and package steps are covered in [BUILD.md](BUILD.md).

## Requirements

- macOS.
- The `container` CLI installed and working on the target machine.
- A `container-compose-plugin.tar.gz` archive from a release or from
  `make package`.

## Install With Homebrew

The `develop` and `release` branches carry a local Homebrew formula that mirrors the source-build style used by Homebrew's `container` formula. It installs the plugin under the `container-compose` keg and leaves the final plugin registration as an explicit symlink into the active `container` install root.

Install the matching `container` fork branch first:

```sh
brew tap stephenlclarke/container https://github.com/stephenlclarke/container
git -C "$(brew --repo stephenlclarke/container)" checkout develop
brew install --build-from-source --HEAD stephenlclarke/container/container
brew services start container
```

For the frozen tester lane, check out `release` instead of `develop` inside the tap.

Install `container-compose` from the same lane:

```sh
brew tap stephenlclarke/container-compose https://github.com/stephenlclarke/container-compose
git -C "$(brew --repo stephenlclarke/container-compose)" checkout develop
brew install --build-from-source --HEAD stephenlclarke/container-compose/container-compose
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart container
```

For the frozen tester lane, check out `release` instead of `develop` inside the tap.

Verify that `container` discovers the plugin:

```sh
container compose version
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
