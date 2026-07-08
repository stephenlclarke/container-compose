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

`main` is the current integration branch and the source of the next stable release. Normal work lands on `main`; installable binary packages are published from the main lane, from `develop/VERSION` pre-release tags, and from bare semantic stable tags.

When a formal version boundary is needed, `main` contains the version that will become the next stable source tag. A development slice increments the version on `develop/VERSION`, publishes pre-release assets only, then lands back on `main` before the stable tag is created.

Use bare semantic source tags such as `0.5.1`, matching Apple repository conventions. Do not create new `v0.5.1` tags. Development pre-release assets use immutable `VERSION-pre.RUN.SHA` tags, for example `0.5.2-pre.123.abcdef123456`, so the later stable `0.5.2` tag remains available and immutable.

## Release Helper

`CONTAINER_STACK_RELEASE.sh` is a maintainer helper for release boundaries and versioned development slices. It is not required for ordinary edits on `main`.

Run it from the `container-compose` checkout:

```sh
make release-plan
make promote-release
make start-dev-release VERSION_SELECTOR=--+
```

`make release-plan` is a dry run. `make promote-release` and `make start-dev-release` execute the checked operation after the helper validates clean worktrees and Stephen-owned push targets.

`make promote-release` creates the stable source tag in `container-compose` only. Companion repositories keep their own release tag histories; the compose package records their exact refs in build metadata instead of forcing every component to reuse the compose semver tag.

Common flows:

```sh
# Tag current main as the stable release.
make promote-release

# Start the next patch development slice.
make start-dev-release VERSION_SELECTOR=--+
```

`start-dev` accepts:

- `--+`: patch bump.
- `-+-`: minor bump and reset patch to `0`.
- `+--`: major bump and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit next development version.

Before it changes anything, the helper checks that worktrees are clean, push remotes are Stephen-owned, and Apple remotes are not writable release targets.

Use it in this order:

1. Finish and validate work on `main`.
2. Run `start-dev VERSION_SELECTOR --execute` only when opening the next short-lived `develop/VERSION` slice.
3. Let the `develop/VERSION` prebuilt workflow publish `VERSION-pre.RUN.SHA` and update `container-compose-pre`.
4. Squash the validated slice back to `main`.
5. Run `tag-current --execute` only when the current `main` state should become an immutable stable source tag.
6. Let the stable tag workflow publish `VERSION` and update `container-compose`.

## Dependency Pins

`container-compose` must stay on the Stephen fork surfaces while fork-backed runtime behavior is required. Do not silently drift back to incompatible `apple/container` or `apple/containerization` revisions.

The exact `container` commit used by CI and package metadata is resolved automatically from the sibling `../container` checkout for local development, then from the latest published `stephenlclarke/container` `homebrew-main-RUN-SHA` tag, and finally from `stephenlclarke/container:main` only when no published package tag exists. The resolver is [Tools/release/resolve-container-ref.py](Tools/release/resolve-container-ref.py); do not reintroduce a hand-maintained pin file.

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. Publish and verify an immutable GHCR builder image before updating `container` to a new shim tag.

## Homebrew Lanes

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Formula | Installs |
| --- | --- |
| `container` | Current fork-backed runtime from the latest immutable `homebrew-main-RUN-SHA` package lane. |
| `container-compose` | Current stable plugin package from the latest semantic release; depends on the matching `container` formula. |
| `container-compose-pre` | Current development plugin package from the latest `develop/VERSION` pre-release; depends on the matching `container` formula. |

The install formulae consume validated GitHub release assets. `container-compose-pre` follows the latest immutable `VERSION-pre.RUN.SHA` release and is opt-in for testing the next slice. `container-compose` follows the latest stable semantic release and is what normal users install. Both formulae record the published `stephenlclarke/container` runtime commit in package metadata, so runtime/plugin mismatches fail fast and `brew upgrade` can keep the installed stack aligned. The tap does not install from `sources/*` submodules.

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

Keep stable source tags and GitHub release objects. Release automation keeps binary assets on one pre-release and one stable release. Older release assets are pruned only after their release notes include the original prebuilt asset SHA-256 and a copy/paste Homebrew source-install block that rebuilds from the retained source tag.
