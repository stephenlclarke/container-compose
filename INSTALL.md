# Installing container-compose

This guide explains how to install, upgrade, verify, and uninstall the `container-compose` plugin with the matched `stephenlclarke/container` runtime. Source build, package, branch, tag, and release policy live in [BUILD.md](BUILD.md).

## Homebrew Formulae

The aggregate Homebrew tap publishes two matched stacks. Install one lane at a
time: both runtime formulae provide the `container` executable.

| Formula | Build type | Use when |
| --- | --- | --- |
| `container-compose` | stable release build | Default install. It depends on the matched `stephenlclarke/container` runtime. |
| `container` | runtime build | Installed automatically as the runtime dependency for the plugin formula. |
| `container-compose-current` | one mutable `current` prerelease | Opt in when you want the latest green-`main` app. It depends on `container-current`. |
| `container-current` | current runtime build | Installed automatically with the current plugin formula. |

The formulae install prebuilt GitHub release assets. They do not build Swift or Go source on the user's machine and do not require Go or Xcode for normal installation. Maintainer-only release and branch rules live in [BUILD.md](BUILD.md).

Homebrew without a `-current` formula always uses the latest immutable semantic
release. The opt-in lane follows the single mutable GitHub prerelease named
**Current build** (tag `current`), which advances only after green `main` CI.
The release page retains downloadable assets only for the newest stable release
and that one current prerelease; older release notes contain source-build
instructions instead.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Homebrew.
- If Apple's signed `container` package is already installed, replace it with the Homebrew stack below. The Compose plugin requires the matched `stephenlclarke/container` runtime for runtime-backed commands.

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

For upgrades, use [Upgrade An Existing Installation](#upgrade-an-existing-installation). Then verify the installed stack:

```sh
container compose version
container system version
container system status
```

The `container` formula owns the plugin registration link inside its Homebrew install root. The `brew postinstall` command refreshes that link after installing or upgrading `container-compose`.

Installing only `container-compose` against a stock Apple `container` install is not the supported release path while the plugin depends on `stephenlclarke` runtime surfaces. If you deliberately test against Apple `container`, install the plugin archive into Apple's plugin directory and expect compatibility gaps.

If the machine has a mixed Homebrew/Apple install, use the [reset flow](#troubleshooting) instead of the normal install path.

## Install The Current Matched Stack

Use this lane when you want the latest installable `main` build rather than the
latest semantic stable release. It follows the one mutable **Current build**
prerelease (tag `current`), generated only after green `main` CI, and is always
paired with the exact runtime package in its Compose stack manifest. It
deliberately does not modify the stable formulae.

Switch from stable (or reset a mixed installation) first:

```sh
brew services stop stephenlclarke/tap/container || true
brew uninstall --ignore-dependencies stephenlclarke/tap/container-compose stephenlclarke/tap/container || true
brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew update
brew install --formula stephenlclarke/tap/container-compose-current
brew postinstall stephenlclarke/tap/container-current
brew services restart stephenlclarke/tap/container-current
container system version
container compose version
```

To return to stable, stop and uninstall the current pair, then follow
[Install The Matched Stack](#install-the-matched-stack). Do not mix
`container` with `container-compose-current`, or `container-current` with
`container-compose`: the formula pair is the compatibility boundary.

## Install A Local Plugin Archive

Build a local plugin archive with `make package` as described in [BUILD.md](BUILD.md), then install or replace the plugin under the active `container` install root:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo mkdir -p /usr/local/libexec/container-plugins
sudo tar -xzf container-compose-plugin-release-arm64.tar.gz -C /usr/local/libexec/container-plugins
```

The resulting plugin layout is:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/container-compose-icon.png
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

`container system version` is the authoritative check for the running `container` CLI and API service. Fork-backed builds include the source owner, branch lane, branch name, commit, exact `containerization` source/ref, and builder image metadata compiled into the runtime. Apple package builds do not carry the stephenlclarke fork provenance fields.

`container compose version` shows the installed plugin build, embedded `compose-go` version, and the package/runtime compatibility metadata used by the preflight. Homebrew packages report their package lane and source revision.

Runtime-backed Compose commands check the installed stack before they start. If the shell is still finding Apple's stock `container`, if the Homebrew install is mixed, or if the installed `container` / `containerization` refs do not match the plugin package metadata, `container compose` stops with upgrade guidance instead of failing later with a stale unsupported-feature or low-level runtime error. The message points back to this file and shows the matching `stephenlclarke/tap` formulae.

Runtime-backed Compose commands also check `container system status` before they load a project or create runtime side effects. If the matched stack is installed but the service is stopped or missing from launchd, start it with `container system start` or refresh the Homebrew service with `brew postinstall stephenlclarke/tap/container` followed by `brew services restart stephenlclarke/tap/container`.

Run a read-only Compose command from a directory containing a Compose file:

```sh
container compose config
```

## Upgrade An Existing Installation

Ordinary Homebrew upgrades keep `container` and `container-compose` up to date:

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

For the opted-in current lane, use its pair explicitly:

```sh
brew update
brew upgrade stephenlclarke/tap/container-current stephenlclarke/tap/container-compose-current
brew postinstall stephenlclarke/tap/container-current
brew services restart stephenlclarke/tap/container-current
```

If Homebrew says a formula is already current but the install still looks mixed, use the [reset flow](#troubleshooting).

## Uninstall

Remove the plugin and matched `stephenlclarke/container` package:

```sh
brew services stop stephenlclarke/tap/container || true
brew uninstall stephenlclarke/tap/container-compose stephenlclarke/tap/container || true
brew untap stephenlclarke/tap || true
```

If you installed the plugin manually under `/usr/local`, remove it with:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
```

## Troubleshooting

### Migrate Legacy Pre-0.6.68 Packages

This is the only legacy release-process procedure in this guide. Packages made
before 0.6.68 used the same Homebrew formula names while release and prerelease
assets changed underneath them. They can leave a `homebrew-main-*` or old
`main-*` build paired with a newer formula. Do not try to upgrade that install
in place: remove the old package pair, then install exactly one current lane.

The following removes only Homebrew formulae and the obsolete manually linked
plugin. It does not use `--zap` and does not remove container data or settings:

```sh
container system stop || true

for formula in \
  stephenlclarke/tap/container-compose \
  stephenlclarke/tap/container \
  stephenlclarke/tap/container-compose-current \
  stephenlclarke/tap/container-current; do
  brew services stop "$formula" || true
  brew uninstall --ignore-dependencies --force "$formula" || true
done

sudo rm -rf /usr/local/libexec/container-plugins/compose
hash -r 2>/dev/null || true
```

Install the normal stable lane unless you explicitly need green `main`:

```sh
brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew update
brew install --formula stephenlclarke/tap/container-compose
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
```

To opt in to the one mutable **Current build** prerelease instead, replace the
last three commands with:

```sh
brew install --formula stephenlclarke/tap/container-compose-current
brew postinstall stephenlclarke/tap/container-current
brew services restart stephenlclarke/tap/container-current
```

Finish either migration with `container system version` and `container compose
version`. The two commands must report the same selected lane.

### Switch Between Stable And Current

The two runtime formulae both provide `container`, so they cannot be installed
side by side. Stop and remove the active pair before installing the other pair.
This preserves container data; it changes only the installed executables and
plugin registration.

To switch from stable to current:

```sh
brew services stop stephenlclarke/tap/container || true
brew uninstall --ignore-dependencies stephenlclarke/tap/container-compose stephenlclarke/tap/container || true
brew update
brew install --formula stephenlclarke/tap/container-compose-current
brew postinstall stephenlclarke/tap/container-current
brew services restart stephenlclarke/tap/container-current
```

To switch from current back to stable:

```sh
brew services stop stephenlclarke/tap/container-current || true
brew uninstall --ignore-dependencies stephenlclarke/tap/container-compose-current stephenlclarke/tap/container-current || true
brew update
brew install --formula stephenlclarke/tap/container-compose
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
```

After either switch, run `hash -r 2>/dev/null || true`, `container system
version`, and `container compose version`. If the output names mixed formulae,
repeat the legacy migration above instead of combining packages manually.

If `container compose` is missing, hangs, or reports the wrong runtime, reset the Homebrew stack:

```sh
brew services stop stephenlclarke/tap/container || true
container system stop || true

if [ -x /usr/local/bin/uninstall-container.sh ]; then
  sudo /usr/local/bin/uninstall-container.sh -k
fi

brew uninstall --ignore-dependencies stephenlclarke/tap/container-compose || true
brew uninstall --ignore-dependencies stephenlclarke/tap/container || true

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
brew list --versions stephenlclarke/tap/container stephenlclarke/tap/container-compose
brew services list | grep container
ls -l "$(brew --prefix stephenlclarke/tap/container)/libexec/container-plugins/compose"
ls -l "$(brew --prefix stephenlclarke/tap/container-compose)/libexec/container-plugins/compose/resources/compose-normalizer"
container system version
container compose version
```

The active `container` binary should come from Homebrew, not `/usr/local/bin/container`. `container system version` should show `stephenlclarke/container` and `stephenlclarke/containerization` provenance. `container compose version` should print the plugin lane, `compose-go` version, and package/runtime compatibility metadata.
