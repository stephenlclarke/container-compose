# Installing container-compose

This guide explains how to install the `container-compose` plugin and the compatible fork-backed `container` runtime. Source build, test, and package steps are covered in [BUILD.md](BUILD.md); branch rules are covered in [BRANCHES.md](BRANCHES.md).

## Install Lanes

`main` is the active development branch and keeps the useful SonarCloud badges. Homebrew installs use prebuilt release assets:

| Lane | Formula | Build type | Use when |
| --- | --- | --- | --- |
| Main | `container-compose` | release | You want the latest development build. |
| Release | `container-compose-release` | release | You want the latest stable release branch build. |
| Tagged Compose release | `container-compose-release-v0-4-1` style | release | You want a specific Compose `release-VERSION-TAG` branch. |

These lanes install prebuilt GitHub release assets. They do not build Swift or Go source on the user's machine and do not require Go or Xcode for normal installation. Debug formula lanes are not part of the current branch model.

## Maintainer Release Setup

The `container` and `container-compose` prebuilt workflows publish `homebrew-*` prereleases with generated release notes, upload the matching archive and checksum assets, and update `stephenlclarke/homebrew-tap` when the workflow can access a tap write token.

Set `HOMEBREW_TAP_TOKEN` in both source repositories before relying on automatic tap updates. The token must be allowed to push to `stephenlclarke/homebrew-tap`; pipe it into GitHub rather than pasting it into shell history:

```sh
gh auth token | gh secret set HOMEBREW_TAP_TOKEN --repo stephenlclarke/container
gh auth token | gh secret set HOMEBREW_TAP_TOKEN --repo stephenlclarke/container-compose
```

Verify the secret is present without printing its value:

```sh
gh secret list --repo stephenlclarke/container | grep '^HOMEBREW_TAP_TOKEN'
gh secret list --repo stephenlclarke/container-compose | grep '^HOMEBREW_TAP_TOKEN'
```

If the secret is absent, the release assets and release notes are still published, but the workflow skips the aggregate tap update. In that case, update `stephenlclarke/homebrew-tap` manually before announcing the lane.

Keep each source repository formula in `Formula/` aligned with the aggregate tap formula after a release workflow advances a `homebrew-*` tag. Formula-only commits should exercise the lightweight Homebrew workflow while the heavy Swift and Go workflows skip.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Homebrew.
- The fork-backed `container` formula from `stephenlclarke/tap`.
- No running `container` service from a different install source while switching lanes.

## Install From The Aggregate Tap

Install or refresh the latest `main` prebuilt runtime and plugin with one copy/paste block:

```sh
install_script="$(mktemp "${TMPDIR:-/tmp}/container-compose-install.XXXXXX")"
cat >"${install_script}" <<'INSTALL_CONTAINER_COMPOSE'
set -Eeuo pipefail

trap 'rc=$?; printf "\nInstall failed at line %s with exit code %s. The terminal shell is still open because this block runs in child Bash.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew update

brew services stop stephenlclarke/tap/container || true
brew services stop stephenlclarke/tap/container-release || true

for formula in container-release container-compose-release; do
  if brew list --formula "${formula}" >/dev/null 2>&1; then
    brew unlink "${formula}" >/dev/null 2>&1 || true
  fi
done

for formula in container container-compose; do
  opt_path="$(brew --prefix)/opt/${formula}"
  if [[ -d "${opt_path}" && ! -L "${opt_path}" ]]; then
    mv "${opt_path}" "${opt_path}.backup.$(date +%Y%m%d%H%M%S)"
  fi
done

if brew list --formula container >/dev/null 2>&1; then
  brew reinstall --force --formula stephenlclarke/tap/container
else
  brew install --formula stephenlclarke/tap/container
fi

if brew list --formula container-compose >/dev/null 2>&1; then
  brew reinstall --force --formula stephenlclarke/tap/container-compose
else
  brew install --formula stephenlclarke/tap/container-compose
fi

brew link --overwrite container
brew link --overwrite container-compose

container_prefix="$(brew --prefix stephenlclarke/tap/container)"
container_bin="${container_prefix}/bin/container"

brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
"${container_bin}" --version
"${container_bin}" compose version
"${container_bin}" system status
"${container_bin}" system version
INSTALL_CONTAINER_COMPOSE

install_status=0
/bin/bash "${install_script}" || install_status=$?
rm -f "${install_script}"
if [ "${install_status}" -ne 0 ]; then
  printf 'container-compose install failed with exit code %s; see the message above.\n' "${install_status}" >&2
fi
```

This block deliberately runs the installer from a temporary child Bash script so `set -e` cannot close the interactive terminal and Homebrew child processes cannot consume the remaining copy/pasted commands from stdin. If a terminal still runs a local debug build after installing, clear the shell's command cache with `rehash` in `zsh` or `hash -r` in `bash`, then confirm `command -v container` points at `/opt/homebrew/bin/container`.

Install the latest stable release branch after the `release` branch has published assets:

```sh
brew tap stephenlclarke/tap
brew install stephenlclarke/tap/container-release
brew install stephenlclarke/tap/container-compose-release
brew postinstall stephenlclarke/tap/container-release
brew services restart stephenlclarke/tap/container-release
container compose version
```

The `container` formula owns the plugin registration link inside its own
Homebrew install root. Run the matching `container` formula's `post_install`
hook after installing or upgrading `container-compose`.

Tagged Compose release branch formulae use the same pattern. For example, branch `release-v0.4.1` publishes `container-compose-release-v0-4-1`. Tagged Compose formulae currently pair with the moving `container-release` runtime formula unless a matching versioned runtime formula is published for the same stack release.

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

Restart the Homebrew-installed `container` service and verify discovery:

```sh
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
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

`container system version` is the authoritative check for the running `container` CLI and API service. Fork-backed builds include the source owner, branch lane, branch name, commit, exact `containerization` source/ref, and pinned `container-builder-shim` image compiled into the runtime. Apple package builds do not carry the Stephen fork provenance fields.

`container compose version` shows the installed plugin build, embedded `compose-go` version, and the `container` and `containerization` pins that the plugin package was built against. `release` and versioned release packages report lane `release`; active development builds from `main` report lane `main`.

Runtime-backed Compose commands check the installed stack before they start. If the shell is still finding Apple's stock `container`, or if the Homebrew lane is mixed, `container compose` stops with install guidance instead of failing later with a low-level runtime error. The message points back to this file and shows the matching `stephenlclarke/tap` formulae for the plugin lane.

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
