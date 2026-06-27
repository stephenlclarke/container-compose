# Troubleshooting container-compose

This guide tracks common install and runtime issues for the Homebrew-installed
`container` and `container-compose` stack.

## Bad Homebrew Install Or Mixed Runtime

Use this when `container compose` is missing, `container compose version` hangs,
Homebrew installed `container` from an old source tap, or the plugin symlink
points at the wrong formula lane.

The reset below removes old plugin lanes, removes the old source-style
`stephenlclarke/container` tap if it exists, reinstalls the current main lane
from the aggregate tap, relinks the plugin into the active `container` prefix,
and restarts the service.

```sh
brew services stop stephenlclarke/tap/container || brew services stop container || true

brew uninstall --ignore-dependencies stephenlclarke/container/container || true
brew uninstall container-compose container-compose-release container || true
brew untap stephenlclarke/container || true

brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap

brew install stephenlclarke/tap/container
brew install stephenlclarke/tap/container-compose

mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn \
  "$(brew --prefix container-compose)/libexec/container-plugins/compose" \
  "$(brew --prefix container)/libexec/container-plugins/compose"

brew services restart stephenlclarke/tap/container

container compose help
container compose version
```

Expected result:

- `container compose help` prints the Compose command help instead of reporting
  an unknown plugin.
- `container compose version` prints the plugin build metadata, including the
  installed lane and the `container` / `containerization` pins.

If Homebrew is configured with `HOMEBREW_REQUIRE_TAP_TRUST`, any non-official
tap used by installed formulae must be trusted before Homebrew will load those
formulae. Check the current warning list with:

```sh
brew doctor
```

Trust only the taps you intentionally use:

```sh
brew trust --tap stephenlclarke/tap
```

## Plugin Symlink Does Not Point At The Active Container Prefix

`container` discovers plugins from its active install root. After switching
between main and release formulae, confirm that the `compose` plugin link is
inside the currently selected `container` prefix:

```sh
ls -l "$(brew --prefix container)/libexec/container-plugins/compose"
```

For the main lane, the link target should point under:

```text
$(brew --prefix container-compose)/libexec/container-plugins/compose
```

Recreate it with:

```sh
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn \
  "$(brew --prefix container-compose)/libexec/container-plugins/compose" \
  "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart stephenlclarke/tap/container
```

## Service Is Running From A Different Container Build

If `container compose` still behaves unexpectedly after reinstalling, verify the
CLI and service provenance:

```sh
command -v container
realpath "$(command -v container)"
brew list --versions container container-compose container-compose-release
brew services list | grep container
container system version
container compose version
```

The Homebrew main lane should use the `container` formula from
`stephenlclarke/tap` and the `container-compose` formula from the same tap.
