# Branch Guide

This is the branch, release, and Homebrew policy for stephenlclarke's container stack forks:

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

`main` is the current, most up-to-date, releasable branch for all four repositories. Keep it green and ready for a stable release at the end of every completed slice.

Use short-lived topic branches only when they make review or recovery clearer. Land validated work back on `main` before release, then delete the branch locally and remotely unless it is still needed for an open review.

Do not create additional long-lived integration or packaging lanes. Non-main branches are topic or review references only.

## Version And Release Rhythm

Normal work lands on `main`. After each completed and validated slice, create the next stable release with:

```sh
make release VERSION_SELECTOR=--+
```

The release helper resolves symbolic selectors from the latest local semantic `container-compose` tag, not from mutable working-tree state. Bare semantic source tags such as `0.6.5` match Apple repository conventions; do not create `v0.6.5` tags. Existing tags are never moved.

Main-lane package artifacts are validation artifacts only. They prove that the current `main` branch can produce an installable archive, but they do not update the stable Homebrew formula. Only bare semantic release tags update `stephenlclarke/tap/container-compose`.

## Release Helper

`scripts/CONTAINER_STACK_RELEASE.sh` is the maintainer helper for stack release boundaries. It is not required for ordinary edits on `main`.

Run it from the `container-compose` checkout through Makefile targets:

```sh
make release-plan
make release VERSION_SELECTOR=--+
make repackage-release VERSION=MAJOR.MINOR.PATCH
```

`make release-plan` is a dry run. `make release` validates clean worktrees and stephenlclarke-owned push targets, bumps `container-compose` version files on `main` when needed, commits that bump, pushes the stephenlclarke-owned `main` branches, ensures the `container` Prebuilt Binaries workflow runs when the exact head lacks an immutable `homebrew-main-RUN-SHA` package tag, waits for that tag, creates and pushes the stable `container-compose` source tag, dispatches the stable package workflow for that tag, waits for the release assets and Homebrew tap update, verifies the live tap URL/version/SHA, then syncs the checked-in source formula template to the verified release asset.

`make repackage-release VERSION=MAJOR.MINOR.PATCH` repairs an existing stable tag without moving it. It dispatches the stable package workflow again, verifies the release archive, checksum asset, Homebrew formula URL, version, and SHA, then syncs the checked-in source formula template to the verified release asset.

Release notes are rendered by [Tools/release/release-notes.py](Tools/release/release-notes.py). The notes include a raw commit audit list, and they promote user-facing `Release-Note:` or `Release-Highlight:` commit trailers into a `Highlights` section before that list. Use single-line trailers that describe the Docker Compose feature, CLI option, or workflow users now get; internal release, CI, and documentation chores should normally omit the trailer or use `Release-Note: none`. For upstream-driven work, also record the original `owner/repository#number` under `Upstream-Ref:`, `Bug-Ref:`, `Refs:`, or `Follow-up-To:`. The renderer preserves references already written into the highlight and appends any missing references, including highlights collected from stack component commits.

`VERSION_SELECTOR` accepts:

- `--+`: patch bump from the latest semantic tag.
- `-+-`: minor bump from the latest semantic tag and reset patch to `0`.
- `+--`: major bump from the latest semantic tag and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit stable release version.

The container package wait and Compose package wait both default to one hour with 30-second polls. Override them only for emergency maintenance with `CONTAINER_STACK_RELEASE_WAIT_SECONDS`, `CONTAINER_STACK_RELEASE_POLL_SECONDS`, `CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS`, or `CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS`.

The helper refuses Apple push targets. stephenlclarke-owned remotes are the only release push targets.

## Dependency Pins

`container-compose` must stay on the stephenlclarke fork surfaces while fork-backed runtime behavior is required. Do not silently drift back to incompatible `apple/container` or `apple/containerization` revisions.

The exact `container` commit used by CI and package metadata is resolved automatically from the sibling `../container` checkout for local development, then from the latest published `stephenlclarke/container` `homebrew-main-RUN-SHA` tag, and finally from `stephenlclarke/container:main` only when no published package tag exists. The resolver is [Tools/release/resolve-container-ref.py](Tools/release/resolve-container-ref.py); do not reintroduce a hand-maintained pin file.

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. Publish and verify an immutable GHCR builder image before updating `container` to a new shim tag.

## Homebrew Formulae

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Formula | Installs |
| --- | --- |
| `container` | Current fork-backed runtime from the latest immutable `homebrew-main-RUN-SHA` package lane. |
| `container-compose` | Current stable plugin package from the latest semantic release; depends on the matching `container` formula. |

The install formulae consume validated GitHub release assets. `container-compose` follows the latest stable semantic release and is what users install. Both formulae record the published `stephenlclarke/container` runtime commit in package metadata, so runtime/plugin mismatches fail fast and `brew upgrade` can keep the installed stack aligned. The tap does not install from `sources/*` submodules.

`Formula/container-compose.rb` in this repository is the source formula template used by the package workflow when updating `stephenlclarke/homebrew-tap`. Release helpers sync that template only after the stable package asset, checksum asset, and live tap formula have been verified, so the checked-in template reflects the last verified stable release rather than an unverified local build.

Because the source formula sync is post-release bookkeeping, `make release-plan` does not count a `container-compose` diff that only touches `Formula/container-compose.rb` as unreleased application work.

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

After a non-main branch has been landed on `main`, delete that branch locally and remotely unless it is still needed for an open review.

## Release Retention

Keep stable source tags and GitHub release objects. Release automation keeps binary assets on the latest main validation release and the latest stable release. Older release assets are pruned only after their release notes include the original prebuilt asset SHA-256 and a copy/paste Homebrew source-install block that rebuilds from the retained source tag.
