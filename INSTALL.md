# Installing container-compose

This guide explains how to install, upgrade, verify, and uninstall the `container-compose` plugin with the compatible fork-backed `container` runtime. Source build and package steps are covered in [BUILD.md](BUILD.md); branch, tag, and release policy is covered in [BRANCHES.md](BRANCHES.md).

## Install Lane

The aggregate Homebrew tap publishes one stable install lane:

| Formula | Build type | Use when |
| --- | --- | --- |
| `container` | release | You need the fork-backed Apple `container` runtime required by this preview stack. |
| `container-compose` | release | You need the latest validated stable Compose plugin. |

The stable formulae install prebuilt GitHub release assets. They do not build Swift or Go source on the user's machine and do not require Go or Xcode for normal installation. Maintainer-only release and branch rules live in [BRANCHES.md](BRANCHES.md).

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

Then install the matched Homebrew `container` and `container-compose` formulae, refresh the plugin registration, and start the Homebrew service:

```sh
brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew update
brew install --formula stephenlclarke/tap/container
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

If the machine has old source taps, retired `container-release` formulae, or a mixed Homebrew/Apple install, use the reset steps in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#bad-homebrew-install-or-mixed-runtime) instead of the normal install path.

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

`container compose version` shows the installed plugin build, embedded `compose-go` version, and the `container` and `containerization` pins that the plugin package was built against. Stable Homebrew packages report stable release metadata from their source tag; local or development packages report their package lane and source revision.

Runtime-backed Compose commands check the installed stack before they start. If the shell is still finding Apple's stock `container`, or if the Homebrew install is mixed, `container compose` stops with install guidance instead of failing later with a low-level runtime error. The message points back to this file and shows the matching `stephenlclarke/tap` formulae.

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

If Homebrew says a formula is already current but the install still looks mixed, use the reset flow in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#bad-homebrew-install-or-mixed-runtime).

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

If `container compose` is not found, verify that the plugin symlink points into the active Homebrew `container` prefix:

```sh
ls -l "$(brew --prefix container)/libexec/container-plugins/compose"
```

If Compose normalization fails after installation, verify that the normalizer exists and is executable:

```sh
ls -l "$(brew --prefix container-compose)/libexec/container-plugins/compose/resources/compose-normalizer"
```
