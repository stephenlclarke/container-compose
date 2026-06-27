# Branch Guide

This guide is the branch policy for these Stephen Clarke repositories:

- `stephenlclarke/container-compose`
- `stephenlclarke/container`
- `stephenlclarke/containerization`

Keep this file in `container-compose` only. Do not copy it into the Apple
repositories, and do not maintain separate `BRANCHES.md` files in the companion
forks.

## Active Branches

| Branch | Purpose | Build and quality rule |
| --- | --- | --- |
| `main` | Current development for all three repositories. | Full CI, CodeQL, SonarQube, and Homebrew main prebuilt packages. |
| `release` | Latest stable snapshot promoted from validated `main`. | Release package validation only; no debug binaries. |
| `release-VERSION-TAG` | Permanent copy of a release tag, for example `release-v0.1.0`. | Release package validation only; no debug binaries. |

`main` is the only active development branch because the free SonarQube tier
only provides one useful branch signal. README badges, quality gates, and normal
integration work should therefore stay on `main`.

`release` is the moving stable snapshot branch. Each promoted release should
also be tagged in every repository and copied to a matching
`release-VERSION-TAG` branch so the exact source state remains installable.

Do not use `develop`, `snapshot/*`, or compatibility side branches as active
lanes for these three repositories.

## Release Flow

1. Validate `main` in `container-compose`, `container`, and `containerization`.
2. Tag the release in each repository.
3. Fast-forward or reset the `release` branch to the tagged commit in each
   repository.
4. Create a branch copy named `release-VERSION-TAG` from the same tag in each
   repository.
5. Publish Homebrew prebuilt assets for `main`, `release`, and each
   `release-VERSION-TAG` branch.

All release branch artifacts must be release builds. The Swift packages must be
built with release configuration, and the Go normalizer must keep using release
flags (`CGO_ENABLED=0`, `-trimpath`, and stripped linker flags). Debug package
lanes are not part of this branch model.

## Homebrew Lanes

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Repository | Main formula | Release formula pattern |
| --- | --- | --- |
| `container` | `container` | `container-release`, `container-release-v0-1-0`, and other branch-derived formula names |
| `container-compose` | `container-compose` | `container-compose-release`, `container-compose-release-v0-1-0`, and other branch-derived formula names |

Release formula names are derived from the branch name by lowercasing it and
replacing non-alphanumeric separators with `-`. For example,
`release-v0.1.0` becomes `container-compose-release-v0-1-0`.

The `container-compose` formula installs the plugin payload. After installing a
compose formula, link the plugin into the Homebrew-installed `container` prefix:

```sh
mkdir -p "$(brew --prefix container)/libexec/container-plugins"
ln -sfn "$(brew --prefix container-compose)/libexec/container-plugins/compose" \
  "$(brew --prefix container)/libexec/container-plugins/compose"
brew services restart container
container compose version
```

## Local Checkouts

For current development, use `main` in all three repositories:

```sh
git -C ~/github/containerization checkout main
git -C ~/github/container checkout main
git -C ~/github/container-compose checkout main
```

For stable validation, use matching `release` branches:

```sh
git -C ~/github/containerization checkout release
git -C ~/github/container checkout release
git -C ~/github/container-compose checkout release
```

For a tagged release copy, use the same `release-VERSION-TAG` branch name in all
three repositories.

`container-compose` still pins the exact `container` commit used in CI through
`APPLE_CONTAINER_REF`. It also resolves `containerization` from
`stephenlclarke/containerization` `main`; promote runtime work to that branch
before deleting a temporary integration branch.

## Archived Names

The former `develop`, `snapshot/*`, `regression`, `apple-container-compatible`,
logs, restart-policy, and full-compose branches are historical references only.
Old handoff notes may mention them, but new work should target `main`, `release`,
or a `release-VERSION-TAG` branch.
