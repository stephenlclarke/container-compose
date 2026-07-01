# Troubleshooting container-compose

This guide tracks common install and runtime issues for the Homebrew-installed
`container` and `container-compose` stack.

## Bad Homebrew Install Or Mixed Runtime

Use this when `container compose` is missing, `container compose version` hangs,
Homebrew installed `container` from an old source tap, or the plugin symlink
points at the wrong formula.

The reset below removes retired plugin lanes, removes the old source-style
`stephenlclarke/container` and `stephenlclarke/container-compose` taps if they
exist, reinstalls the current stable lane from the aggregate tap, relinks the
plugin into the active `container` prefix, and restarts the service.

```sh
brew services stop stephenlclarke/tap/container || brew services stop container || true

brew uninstall --ignore-dependencies stephenlclarke/container/container || true
brew uninstall container-compose container-compose-release container || true
brew untap stephenlclarke/container || true
brew untap stephenlclarke/container-compose || true

brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap

brew install stephenlclarke/tap/container-compose

brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container

container compose help
container compose version
```

Expected result:

- `container compose help` prints the Compose command help instead of reporting
  an unknown plugin.
- `container compose version` prints the plugin build metadata, including the
  installed lane, embedded `compose-go` version, and the `container` /
  `containerization` pins.

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
between install sources, confirm that the `compose` plugin link is
inside the currently selected `container` prefix:

```sh
ls -l "$(brew --prefix container)/libexec/container-plugins/compose"
```

The link target should point under:

```text
$(brew --prefix container-compose)/libexec/container-plugins/compose
```

Refresh it with the `container` formula's `post_install` hook:

```sh
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
```

If the link still points at the wrong lane, recreate it manually:

```sh
container_prefix="$(brew --prefix container)"
compose_prefix="$(brew --prefix container-compose)"
mkdir -p "$container_prefix/libexec/container-plugins"
ln -sfn \
  "$compose_prefix/libexec/container-plugins/compose" \
  "$container_prefix/libexec/container-plugins/compose"
brew services restart stephenlclarke/tap/container
```

## Apple Container Is Installed But The Fork-Backed Container Is Required

Use this when the machine has Apple's signed `container` package, but this
Compose preview needs the fork-backed `container` runtime from
`stephenlclarke/tap`. A common signal on Apple silicon is that the shell finds
`/usr/local/bin/container` instead of the Homebrew formula's `bin/container`.

Check what the shell is actually running:

```sh
command -v container
realpath "$(command -v container)"
pkgutil --pkgs | grep -i 'container'
container system version
```

Apple package builds do not show the Stephen fork provenance fields in
`container system version`. Fork-backed builds include source owner, lane,
branch, commit, compiled `containerization` ref, and pinned
`container-builder-shim` image.

Stop the currently running runtime, remove the Apple package while keeping user
data, then install the fork-backed stable lane. If `container system stop` hangs,
skip it and continue with the uninstall script.

```sh
container system stop || true
brew services stop stephenlclarke/tap/container || brew services stop container || true

if [ -x /usr/local/bin/uninstall-container.sh ]; then
  sudo /usr/local/bin/uninstall-container.sh -k
fi

brew tap stephenlclarke/tap
brew trust --tap stephenlclarke/tap
brew untap stephenlclarke/container || true
brew untap stephenlclarke/container-compose || true
brew uninstall --ignore-dependencies \
  container-compose container-compose-release container container-release || true
brew install stephenlclarke/tap/container-compose

brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
hash -r 2>/dev/null || true
```

Verify that the shell and service now use the fork-backed Homebrew install:

```sh
expected="$(realpath "$(brew --prefix container)/bin/container")"
actual="$(realpath "$(command -v container)")"
printf 'expected: %s\nactual:   %s\n' "$expected" "$actual"
test "$actual" = "$expected"

container compose help
container system version
container compose version
```

The verification should show Stephen fork provenance for the runtime, the runtime's pinned `container-builder-shim` image, and matching `container` / `containerization` / `compose-go` pins for the Compose package.

If `command -v container` still resolves to `/usr/local/bin/container` after
the uninstall, start a new shell or check `PATH` ordering. On Apple silicon,
Homebrew's `/opt/homebrew/bin` should usually appear before `/usr/local/bin`.

## Service Is Running From A Different Container Build

If `container compose` still behaves unexpectedly after reinstalling, verify the
CLI and service provenance:

```sh
command -v container
realpath "$(command -v container)"
brew list --versions container container-compose
brew services list | grep container
container system version
container compose version
```

The Homebrew stable lane should use the `container` formula from
`stephenlclarke/tap` and the `container-compose` formula from the same tap.
