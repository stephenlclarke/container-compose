# Branch Guide

This is the branch, release, and Homebrew lane policy for Stephen Clarke's container stack forks:

- `stephenlclarke/container-compose`
- `stephenlclarke/container`
- `stephenlclarke/containerization`
- `stephenlclarke/container-builder-shim`

Keep this guide in `container-compose` only. Do not copy it into Apple upstream repositories or maintain separate branch policy files in the companion forks.

## Repository Roles

| Repository | Role |
| --- | --- |
| `container-compose` | Compose plugin, package metadata, and stack release coordination. |
| `container` | Fork-backed runtime and CLI installed by Homebrew. |
| `containerization` | Swift runtime package consumed by `container` and `container-compose`. |
| `container-builder-shim` | BuildKit bridge source; `container` pins a published GHCR image tag instead of installing this from Homebrew. |

## Branch Policy

| Branch | Use |
| --- | --- |
| `main` | Current, most up-to-date, releasable branch for all four repositories. Keep it green and ready for stable tags. |
| `develop/VERSION` | Short-lived development slice for the next version. Squash validated work back to `main`, then delete the branch. |
| `hotfix/VERSION` | Short-lived patch branch from an older source tag only when current `main` cannot be released. Squash or cherry-pick back, then delete the branch. |

Do not create new long-lived `release`, `release-*`, `snapshot/*`, compatibility, or feature-integration lanes. Historical branches with those names are references only.

## Version And Release Rhythm

`main` is the current integration and package lane. Normal work lands on `main`; the main-lane prebuilt workflow then publishes the moving `homebrew-main` package used by the install guide.

When a formal version boundary is needed, `main` contains the version that will become the next stable source tag. A development slice increments the version on `develop/VERSION`, publishes pre-release assets only, then lands back on `main` before the stable tag is created.

Use bare semantic source tags such as `0.5.1`, matching Apple repository conventions. Do not create new `v0.5.1` tags. Development pre-release assets use `VERSION-pre`, for example `0.5.2-pre`, so the later stable `0.5.2` tag remains available and immutable.

## Release Helper

`CONTAINER_STACK_RELEASE.sh` is a maintainer helper for release boundaries and versioned development slices. It is not required for ordinary edits on `main`, and it does not replace the automated `homebrew-main` package lane.

Run it from the `container-compose` checkout:

```sh
./CONTAINER_STACK_RELEASE.sh plan
./CONTAINER_STACK_RELEASE.sh tag-current
./CONTAINER_STACK_RELEASE.sh start-dev --+
```

The helper is dry-run by default. Add `--execute` only after the plan is correct.

Common flows:

```sh
# Tag current main as the stable release.
./CONTAINER_STACK_RELEASE.sh tag-current --execute

# Start the next patch development slice.
./CONTAINER_STACK_RELEASE.sh start-dev --+ --execute
```

`start-dev` accepts:

- `--+`: patch bump.
- `-+-`: minor bump and reset patch to `0`.
- `+--`: major bump and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit next development version.

Before it changes anything, the helper checks that worktrees are clean, push remotes are Stephen-owned, and Apple remotes are not writable release targets.

Use it in this order:

1. Finish and validate work on `main`.
2. Let the main-lane prebuilt workflows update the moving Homebrew packages.
3. Run `tag-current --execute` only when the current `main` state should become an immutable stable source tag.
4. Run `start-dev VERSION_SELECTOR --execute` only when opening the next short-lived `develop/VERSION` slice.

## Dependency Pins

`container-compose` must stay on the Stephen fork surfaces while fork-backed runtime behavior is required. Do not silently drift back to incompatible `apple/container` or `apple/containerization` revisions.

The exact `container` commit used by CI and package metadata is resolved automatically from the sibling `../container` checkout for local development, then from the published `stephenlclarke/container` `homebrew-main` tag, and finally from `stephenlclarke/container:main` only when no published package tag exists. The resolver is [Tools/release/resolve-container-ref.py](Tools/release/resolve-container-ref.py); do not reintroduce a hand-maintained pin file.

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. Publish and verify an immutable GHCR builder image before updating `container` to a new shim tag.

## Homebrew Lanes

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Formula | Installs |
| --- | --- |
| `container` | Current fork-backed runtime from the moving `homebrew-main` package lane. |
| `container-compose` | Current plugin package from the moving `homebrew-main` package lane; depends on the matching `container` formula. |

The install formulae consume validated GitHub release assets from the moving `homebrew-main` releases. `container-compose` rebuilds its main-lane package from `main` and records the published `stephenlclarke/container` `homebrew-main` commit in package metadata, so `brew upgrade` can keep the plugin and runtime pins aligned. The `container` main-lane package workflow triggers the matching `container-compose` package workflow after it updates the runtime formula. `container-compose` formula versions use `COMPOSE_VERSION-main.GITHUB_RUN_NUMBER.SHORT_SHA` so Homebrew sees each main-lane package as an upgrade from older stable or main-lane installs. Development pre-release assets from `develop/VERSION` are not installed by the aggregate tap, and the tap does not install from `sources/*` submodules.

The tap `sources/container`, `sources/container-compose`, `sources/containerization`, and `sources/container-builder-shim` submodules are maintenance inputs that track project `main` branches.

Install, upgrade, verification, and uninstall commands live in [INSTALL.md](INSTALL.md). Source build and package commands live in [BUILD.md](BUILD.md).

## Local Checkout Rules

For normal integration work, keep all four repositories on `main`:

```sh
git -C ~/github/container-builder-shim switch main
git -C ~/github/containerization switch main
git -C ~/github/container switch main
git -C ~/github/container-compose switch main
```

Use `develop/VERSION` only in repositories that need source changes for the current slice. Repositories that do not change should remain on `main`.

After a non-main branch has been squashed or merged into `main`, delete that branch locally and remotely unless it is still needed for an open review.

## Release Retention

Keep stable source tags and GitHub release objects. Binary assets for older releases may be pruned only after the release notes explain how to rebuild from the retained source tag, usually with `brew extract --version` into a personal tap followed by `brew install --build-from-source`.
