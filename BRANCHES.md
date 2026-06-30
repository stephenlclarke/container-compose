# Branch Guide

This guide is the branch policy for these Stephen Clarke repositories:

- `stephenlclarke/container-compose`
- `stephenlclarke/container`
- `stephenlclarke/containerization`
- `stephenlclarke/container-builder-shim`

Keep this file in `container-compose` only. Do not copy it into the Apple
repositories, and do not maintain separate `BRANCHES.md` files in the companion
forks.

The four repositories have different roles:

- `container` is the fork-backed runtime and CLI that Homebrew installs.
- `container-compose` is the plugin package that is installed beside the matching `container` lane.
- `containerization` is the Swift package consumed by both `container` and `container-compose`; its branch must match the runtime lane.
- `container-builder-shim` is Go source for the BuildKit bridge image used by `container build`; `container` pins an immutable builder image version, currently `0.13.6`, instead of installing the shim from Homebrew.

## Active Branches

| Branch | Purpose | Build and quality rule |
| --- | --- | --- |
| `main` | Current development for all four repositories. | Full CI, CodeQL, SonarQube where configured, and Homebrew main prebuilt packages for installable packages. |
| `release` | Latest stable snapshot promoted from validated `main`. | Release package validation only; no debug binaries. |
| `release-VERSION-TAG` | Permanent copy of a release tag, for example `release-v0.4.1`. | Release package validation only; no debug binaries. |

`main` is the only active development branch because the free SonarQube tier
only provides one useful branch signal. README badges, quality gates, and normal
integration work should therefore stay on `main`.

`release` is the moving stable snapshot branch. Each promoted release should
also be tagged in every repository and copied to a matching
`release-VERSION-TAG` branch so the exact source state remains installable.

Do not use `develop`, `snapshot/*`, or compatibility side branches as active
lanes for these four repositories.

## Release Flow

1. Validate `main` in `container-compose`, `container`, `containerization`, and the builder shim image version pinned by `container`.
2. Tag the release in each repository that participates in the promoted source snapshot. The builder shim tag must already match the image version pinned by `container`.
3. Fast-forward or reset the `release` branch to the tagged commit in each
   lane-tracked repository.
4. Create a branch copy named `release-VERSION-TAG` from the same tag in each
   lane-tracked repository.
5. Publish Homebrew prebuilt assets for `main`, `release`, and each
   `release-VERSION-TAG` branch.

All release branch artifacts must be release builds. The Swift packages must be
built with release configuration. All Go outputs across this project are release-quality code paths: `container-compose` packages the normalizer with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags, and `container-builder-shim` builds the Linux image binary with the same release-oriented shape. Debug package lanes are not part of this branch model.

## Dependency Lanes

`container` and `container-compose` consume `containerization` by branch:

| Consumer lane | `containerization` branch |
| --- | --- |
| `main` | `main` |
| `release` | `release` |
| `release-VERSION-TAG` | matching `release-VERSION-TAG` when that branch exists, otherwise the immutable release tag used for the copied lane |

`container-compose` also pins the exact `container` commit used by CI and package metadata through `APPLE_CONTAINER_REF`. Keep that pin in the same lane as the plugin package.

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. The current Stephen fork default is `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.6`. Update the shim source on `main`, publish an immutable image tag, verify the GHCR manifest is available, then update `container` to that tag; do not point release packages at untagged, unpublished, or debug builder images.

## Homebrew Lanes

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Repository | Main formula | Release formula pattern |
| --- | --- | --- |
| `container` | `container` | `container-release`, plus branch-derived formula names when matching runtime release branches exist |
| `container-compose` | `container-compose` | `container-compose-release`, `container-compose-release-v0-4-1`, and other branch-derived formula names |

`homebrew-main` tracks the latest `main` package, and `homebrew-release` tracks
the latest stable `release` package. Treat `homebrew-release` like Docker's
`:latest` tag for the stable lane: it is intentionally moved whenever a newer
release is promoted. Versioned release branch copies, such as
`release-v0.4.1`, keep their own branch-derived Homebrew tags and formula names
for immutable installs.

The tap's `sources/*` submodules are maintenance inputs and track the four project repositories on `main`: `sources/container`, `sources/container-compose`, `sources/containerization`, and `sources/container-builder-shim`. Release formulae do not install from those submodules; they consume the prebuilt assets published from the matching release package tags.

Release formula names are derived from the branch name by lowercasing it and
replacing non-alphanumeric separators with `-`. For example,
`release-v0.4.1` becomes `container-compose-release-v0-4-1`.

Install matching formula lanes together: `container` with `container-compose`
for `main`, or `container-release` with `container-compose-release` for the
moving stable release. After installing a compose formula, link the plugin into
the matching Homebrew-installed `container` prefix:

```sh
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" \
  "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart container
container compose version
```

For the moving stable release lane, use the same commands with
`container-release` and `container-compose-release`.

## Local Checkouts

For current development, use `main` in all four repositories:

```sh
git -C ~/github/container-builder-shim checkout main
git -C ~/github/containerization checkout main
git -C ~/github/container checkout main
git -C ~/github/container-compose checkout main
```

For stable validation, use matching `release` branches for the lane-tracked Swift repositories and the immutable builder shim tag pinned by `container`:

```sh
git -C ~/github/containerization checkout release
git -C ~/github/container checkout release
git -C ~/github/container-compose checkout release
```

For a tagged release copy, use the same `release-VERSION-TAG` branch name in the lane-tracked repositories and verify that `container` still points at the intended builder shim image tag.

## Archived Names

The former `develop`, `snapshot/*`, `regression`, `apple-container-compatible`,
logs, restart-policy, and full-compose branches are historical references only.
Old handoff notes may mention them, but new work should target `main`, `release`,
or a `release-VERSION-TAG` branch.
