# Branch Guide

This guide is the branch and Homebrew policy for these Stephen Clarke repositories:

- `stephenlclarke/container-compose`
- `stephenlclarke/container`
- `stephenlclarke/containerization`
- `stephenlclarke/container-builder-shim`

Keep this file in `container-compose` only. Do not copy it into the Apple repositories, and do not maintain separate `BRANCHES.md` files in the companion forks.

## Repository Roles

- `container` is the fork-backed runtime and CLI that Homebrew installs.
- `container-compose` is the plugin package installed beside the matching `container` formula.
- `containerization` is the Swift runtime package consumed by both `container` and `container-compose`.
- `container-builder-shim` is Go source for the BuildKit bridge image used by `container build`; `container` pins an immutable builder image version instead of installing the shim from Homebrew.

## Active Branches

| Branch | Purpose | Build and quality rule |
| --- | --- | --- |
| `main` | Releasable integration branch for all four repositories. | Full CI, CodeQL, SonarQube where configured, and stable Homebrew release generation after a source tag. |
| `develop/VERSION` | Short-lived development slice for the next version. | Full or agreed pre-release CI; published GitHub release is marked pre-release and not latest. |
| `hotfix/VERSION` | Optional short-lived branch from an older source tag when current `main` cannot be released. | Focused fix validation plus the stable tag workflow for the patched version. |

`main` stays releasable. Development work happens on a short-lived `develop/VERSION` branch, then is squashed back to `main`. The next development branch is created only after the current `main` version has been tagged as the latest stable release point.

Do not use long-lived `release`, `release-*`, `snapshot/*`, or compatibility side branches as active lanes for these four repositories.

## Version Rhythm

The version currently on `main` is the release that will become latest before the next development slice starts. The incremented version belongs to the next work slice.

Example:

| Step | `main` version | Release label |
| --- | --- | --- |
| Current releasable state | `0.0.1` | `0.0.1` latest |
| Start next slice | `0.0.2` on `develop/0.0.2` | `0.0.2` pre-release |
| Squash `develop/0.0.2` to `main`, then start following slice | `0.0.2` | `0.0.2` latest |
| Following slice | `0.0.3` on `develop/0.0.3` | `0.0.3` pre-release |

Use bare semantic source tags such as `0.4.2`, matching Apple repository tag conventions. Do not create new `v0.4.2` source tags.

## Release Flow

Use the local release helper from the `container-compose` checkout:

```sh
./CONTAINER_STACK_RELEASE.sh plan
./CONTAINER_STACK_RELEASE.sh tag-current
./CONTAINER_STACK_RELEASE.sh start-dev --+
```

The script is dry-run by default. Add `--execute` only after the plan is correct.

Stable-only release:

```sh
./CONTAINER_STACK_RELEASE.sh tag-current --execute
```

Start a new development slice:

```sh
./CONTAINER_STACK_RELEASE.sh start-dev --+ --execute
```

Version selectors for `start-dev`:

- `--+`: patch bump.
- `-+-`: minor bump and reset patch to `0`.
- `+--`: major bump and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit next development version.

When a revision is incremented, all revisions to the right reset to `0`.

The script:

1. Verifies clean worktrees and Stephen-owned push remotes.
2. Refuses writable Apple remotes.
3. Tags the current `main` version as the stable/latest release point.
4. Creates `develop/NEXT_VERSION` from `main`.
5. Bumps version declarations on the development branch.
6. Commits and pushes the development branch only when `--execute` is present.

## Release Credentials

Release workflows publish source-repo assets first. They update `stephenlclarke/homebrew-tap` only when the source repository has a `HOMEBREW_TAP_TOKEN` secret with permission to push to that tap.

Set or rotate the secret without printing the token value:

```sh
gh auth token | gh secret set HOMEBREW_TAP_TOKEN --repo stephenlclarke/container
gh auth token | gh secret set HOMEBREW_TAP_TOKEN --repo stephenlclarke/container-compose
```

Verify the secret name is present without exposing the value:

```sh
gh secret list --repo stephenlclarke/container | grep '^HOMEBREW_TAP_TOKEN'
gh secret list --repo stephenlclarke/container-compose | grep '^HOMEBREW_TAP_TOKEN'
```

If the secret is absent, release assets and release notes can still be published, but the release should not be announced until the aggregate tap formulae have been updated and validated.

## Dependency Rules

`container-compose` must stay pinned to the required `stephenlclarke/container` and `stephenlclarke/containerization` surfaces while fork-backed behavior is required. Do not silently drift back to incompatible `apple/container` or `apple/containerization` surfaces.

`container-compose` resolves the exact `container` commit used by CI and package metadata automatically from the checked-out `../container` dependency, or from `stephenlclarke/container:main` when no sibling checkout is available. The resolver lives at `Tools/release/resolve-container-ref.py`; do not reintroduce a hand-maintained pin file.

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. Update the shim source on `main`, publish an immutable image tag, verify the GHCR manifest is available, then update `container` to that tag. Do not point stable packages at untagged, unpublished, or debug builder images.

## Homebrew Policy

The aggregate tap is `stephenlclarke/homebrew-tap`.

Maintain one stable formula per installable repository:

| Repository | Stable formula |
| --- | --- |
| `container` | `container` |
| `container-compose` | `container-compose` |

Stable formulae point at the newest validated stable release assets. They do not point at `develop/VERSION` pre-release assets.

Development pre-releases use tags named `VERSION-pre`, for example `0.4.3-pre`, so the later stable source tag `0.4.3` remains available and immutable.

The tap's `sources/*` submodules are maintenance inputs and track the project repositories on `main`: `sources/container`, `sources/container-compose`, `sources/containerization`, and `sources/container-builder-shim`. Stable formulae do not install from those submodules; they consume verified prebuilt GitHub release assets.

Install, upgrade, verification, and uninstall commands live in [INSTALL.md](INSTALL.md). Keep the copy/paste Homebrew flow there so the install path has one source of truth.

## Release Assets

Stable source tags and GitHub release objects are retained. Uploaded binary assets for older releases may be pruned only after the release notes include Homebrew source-build instructions.

The release notes for pruned assets must tell users how to rebuild from the retained source tag, usually with `brew extract --version` into a personal tap followed by `brew install --build-from-source`.

## Local Checkouts

For current integration work, use `main` in all four repositories:

```sh
git -C ~/github/container-builder-shim switch main
git -C ~/github/containerization switch main
git -C ~/github/container switch main
git -C ~/github/container-compose switch main
```

For active development, use the short-lived branch only in repositories that need source changes for that slice:

```sh
git -C ~/github/container-compose switch develop/0.5.1
```

Companion repositories may remain on `main` when their current tagged asset is reused by the stack manifest.

## Archived Names

The former long-lived `release`, `release-*`, `snapshot/*`, `regression`, `apple-container-compatible`, logs, restart-policy, and full-compose branches are historical references only. Old handoff notes may mention them, but new work should target `main`, short-lived `develop/VERSION`, or short-lived `hotfix/VERSION` branches.
