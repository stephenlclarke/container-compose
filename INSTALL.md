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
- No running `container` service from a different install source while switching to the fork-backed Homebrew stack.

## Install From The Aggregate Tap

For a normal install, tap the repository, install the matched runtime and plugin, then start the service:

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

## If Apple container Is Already Installed

If `container` was installed from Apple's signed package, stop it before installing this fork-backed lane:

```sh
container system stop || true
```

To avoid path and service ambiguity, remove the Apple package install before installing the Homebrew lane. Keep user data with `-k` or remove user data with `-d`:

```sh
sudo /usr/local/bin/uninstall-container.sh -k
```

Then install `container` and `container-compose` from the aggregate tap with the commands above.

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

Refresh the tap, upgrade the two formulae, then restart the service:

```sh
brew update
brew upgrade stephenlclarke/tap/container stephenlclarke/tap/container-compose
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
