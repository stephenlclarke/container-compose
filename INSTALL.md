# Installing container-compose

This guide explains how to install the `container-compose` plugin and the compatible fork-backed `container` runtime. Source build, test, and package steps are covered in [BUILD.md](BUILD.md); branch rules are covered in [BRANCHES.md](BRANCHES.md).

## Install Lanes

`main` is the active development branch and keeps the useful SonarCloud badges. Homebrew installs use prebuilt release assets:

| Lane | Formula | Build type | Use when |
| --- | --- | --- | --- |
| Main | `container-compose` | release | You want the latest development build. |
| Release | `container-compose-release` | release | You want the latest stable release branch build. |
| Tagged release | `container-compose-release-v0-1-0` style | release | You want a specific `release-VERSION-TAG` branch. |

These lanes install prebuilt GitHub release assets. They do not build Swift or Go source on the user's machine and do not require Go or Xcode for normal installation. Debug snapshot formulae are not part of the current branch model.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Homebrew.
- The fork-backed `container` formula from `stephenlclarke/tap`.
- No running `container` service from a different install source while switching lanes.

## Install From The Aggregate Tap

Install the latest `main` prebuilt:

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container
brew install stephenlclarke/tap/container-compose
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" "$(brew --prefix container)/libexec/container-plugins/compose"
brew services start container
container compose version
```

Install the latest stable release branch after the `release` branch has published assets:

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container-release
brew install stephenlclarke/tap/container-compose-release
mkdir -p "$(brew --prefix container-release)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose-release)/libexec/container-plugins/compose" "$(brew --prefix container-release)/libexec/container-plugins/compose"
brew services restart container-release
container compose version
```

Tagged release branch formulae use the same pattern. For example, branch `release-v0.1.0` publishes `container-compose-release-v0-1-0`.

## If Apple container Is Already Installed

If `container` was installed from Apple's signed package, stop it before installing this fork-backed lane:

```sh
container system stop || true
```

To avoid path and service ambiguity, remove the Apple package install before installing the Homebrew lane. Keep user data with `-k` or remove user data with `-d`:

```sh
sudo /usr/local/bin/uninstall-container.sh -k
```

Then install `container` and `container-compose` from the aggregate tap using one of the lanes above.

Installing only `container-compose` against a stock Apple `container` install is not the supported preview path when the plugin depends on fork-backed runtime surfaces. If you deliberately test against Apple `container`, install the plugin archive into Apple's plugin directory and expect compatibility gaps.

## Install From A Source Branch

Use this path only when testing a source branch directly, not for normal Homebrew installs:

```sh
branch=main
brew tap stephenlclarke/container-compose https://github.com/stephenlclarke/container-compose
git -C "$(brew --repo stephenlclarke/container-compose)" fetch origin
git -C "$(brew --repo stephenlclarke/container-compose)" checkout "$branch"
brew install stephenlclarke/container-compose/container-compose
```

Register the plugin with the Homebrew-installed `container` keg:

```sh
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart container
container compose version
```

## Install A Local Plugin Archive

Build a local plugin archive with `make package`, then install or replace the plugin under the active `container` install root:

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

`container system version` is the authoritative check for the running `container` CLI and API service. Fork-backed builds include the source owner, branch lane, branch name, commit, and the exact `containerization` source/ref compiled into the runtime. Apple package builds do not carry the Stephen fork provenance fields.

`container compose version` shows the installed plugin build plus the `container` and `containerization` pins that the plugin package was built against. `release` and `release-*` packages report lane `release`; active development builds from `main` report lane `main`.

Run a read-only Compose command from a directory containing a Compose file:

```sh
container compose config
```

## Upgrade Or Switch Lanes

Stop the active service, uninstall the old plugin lane, install the new lane, then register the plugin again:

```sh
brew services stop container || true
brew uninstall container-compose container-compose-release || true
```

Then run the main or release install commands above.

## Uninstall

Remove the plugin and fork-backed `container` package:

```sh
brew services stop container || true
brew uninstall container-compose container-compose-release container || true
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
ls -l "$(brew --prefix container-compose 2>/dev/null || brew --prefix container-compose-release)/libexec/container-plugins/compose/resources/compose-normalizer"
```
