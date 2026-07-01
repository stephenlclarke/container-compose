# Installing container-compose

This guide explains how to install, upgrade, verify, and uninstall the `container-compose` plugin with the compatible fork-backed `container` runtime. Source build and package steps are covered in [BUILD.md](BUILD.md); branch, tag, and release policy is covered in [BRANCHES.md](BRANCHES.md).

## Install Lane

The aggregate Homebrew tap publishes one current stack lane:

| Formula | Build type | Use when |
| --- | --- | --- |
| `container-compose` | main release build | Install this. It depends on the matched fork-backed `container` runtime. |
| `container` | main release build | Installed automatically as the runtime dependency for `container-compose`. |

The formulae install prebuilt GitHub release assets from the moving `homebrew-main` package lane. They do not build Swift or Go source on the user's machine and do not require Go or Xcode for normal installation. Maintainer-only release and branch rules live in [BRANCHES.md](BRANCHES.md).

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Homebrew.
- If Apple's signed `container` package is already installed, replace it with the Homebrew stack below. The Compose plugin requires the matched fork-backed `container` runtime for runtime-backed commands.

## Install The Matched Stack

Most users will already have Apple's signed `container` package installed. First, stop that runtime and remove Apple's package while keeping user data:

```sh
if command -v container >/dev/null 2>&1; then
  container system stop || true
fi

if [ -x /usr/local/bin/uninstall-container.sh ]; then
  sudo /usr/local/bin/uninstall-container.sh -k
fi
```

If this is a first-time install and Apple's `container` package is not already installed, both commands above safely do nothing.

Then install `container-compose`. Homebrew installs the matched `container` runtime dependency, then the `postinstall` command refreshes the plugin registration before the service starts:

```sh
brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew update
brew install --formula stephenlclarke/tap/container-compose
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
```

Then verify the installed stack:

```sh
container compose version
container system version
container system status
```

The `container` formula owns the plugin registration link inside its Homebrew install root. The `brew postinstall` command refreshes that link after installing or upgrading `container-compose`.

Installing only `container-compose` against a stock Apple `container` install is not the supported preview path when the plugin depends on fork-backed runtime surfaces. If you deliberately test against Apple `container`, install the plugin archive into Apple's plugin directory and expect compatibility gaps.

If the machine has old source taps, retired `container-release` formulae, or a mixed Homebrew/Apple install, use the [reset flow](#troubleshooting) instead of the normal install path.

## Install A Local Plugin Archive

Build a local plugin archive with `make package` as described in [BUILD.md](BUILD.md), then install or replace the plugin under the active `container` install root:

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

## Verify

Confirm that `container` discovers the plugin:

```sh
container compose version
```

Show the runtime and plugin provenance:

```sh
container system version
container compose version
container compose version --format json
```

`container system version` is the authoritative check for the running `container` CLI and API service. Fork-backed builds include the source owner, branch lane, branch name, commit, exact `containerization` source/ref, and pinned `container-builder-shim` image compiled into the runtime. Apple package builds do not carry the Stephen fork provenance fields.

`container compose version` shows the installed plugin build, embedded `compose-go` version, and the `container` and `containerization` pins that the plugin package was built against. Homebrew packages report their package lane and source revision.

Runtime-backed Compose commands check the installed stack before they start. If the shell is still finding Apple's stock `container`, if the Homebrew install is mixed, or if the installed `container` / `containerization` refs do not match the plugin package pins, `container compose` stops with upgrade guidance instead of failing later with a stale unsupported-feature or low-level runtime error. The message points back to this file and shows the matching `stephenlclarke/tap` formulae.

Run a read-only Compose command from a directory containing a Compose file:

```sh
container compose config
```

## Upgrade An Existing Installation

Yes. After the matched stack is installed, ordinary Homebrew upgrades keep `container` and `container-compose` up to date:

```sh
brew update
brew upgrade
```

If you only want to update this stack, upgrade the two formulae directly:

```sh
brew update
brew upgrade stephenlclarke/tap/container stephenlclarke/tap/container-compose
```

After either upgrade path, refresh the plugin registration, restart the service, and verify the installed versions:

```sh
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
container system version
container compose version
```

If Homebrew says a formula is already current but the install still looks mixed, use the [reset flow](#troubleshooting).

## Uninstall

Remove the plugin and fork-backed `container` package:

```sh
brew services stop container || true
brew uninstall container-compose container || true
brew untap stephenlclarke/tap || true
```

If you installed the plugin manually under `/usr/local`, remove it with:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
```

## Troubleshooting

If `container compose` is missing, hangs, or reports the wrong runtime, reset the Homebrew stack:

```sh
brew services stop stephenlclarke/tap/container || brew services stop container || true
container system stop || true

if [ -x /usr/local/bin/uninstall-container.sh ]; then
  sudo /usr/local/bin/uninstall-container.sh -k
fi

brew uninstall --ignore-dependencies stephenlclarke/container/container || true
brew uninstall --ignore-dependencies \
  container-compose container-compose-release container container-release || true
brew untap stephenlclarke/container || true
brew untap stephenlclarke/container-compose || true

brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew install --formula stephenlclarke/tap/container-compose
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
hash -r 2>/dev/null || true
```

Then verify the shell, service, plugin link, and normalizer:

```sh
command -v container
realpath "$(command -v container)"
brew list --versions container container-compose
brew services list | grep container
ls -l "$(brew --prefix container)/libexec/container-plugins/compose"
ls -l "$(brew --prefix container-compose)/libexec/container-plugins/compose/resources/compose-normalizer"
container system version
container compose version
```

The active `container` binary should come from Homebrew, not `/usr/local/bin/container`. `container system version` should show `stephenlclarke/container` and `stephenlclarke/containerization` provenance. `container compose version` should print the plugin lane, `compose-go` version, and runtime pins.
