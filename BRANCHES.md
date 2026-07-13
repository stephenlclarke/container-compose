# Branch Guide

This is the branch, release, and Homebrew policy for stephenlclarke's container stack forks:

- `stephenlclarke/container-compose`
- `stephenlclarke/container`
- `stephenlclarke/containerization`
- `stephenlclarke/container-builder-shim`
- `stephenlclarke/homebrew-tap`

Keep this guide in `container-compose` only. Do not copy it into Apple upstream repositories or maintain separate branch policy files in the companion forks.

## Repository Roles

| Repository | Role |
| --- | --- |
| `container-compose` | Compose plugin, package metadata, and stack release coordination. |
| `container` | Matched `stephenlclarke` runtime and CLI installed by Homebrew. |
| `containerization` | Swift runtime package consumed by `container` and `container-compose`. |
| `container-builder-shim` | BuildKit bridge source; `container` pins a published GHCR image tag instead of installing this from Homebrew. |
| `homebrew-tap` | Verified stable formulae and source-maintenance submodules for the stack. |

## Branch Policy

`main` is the current, most up-to-date, releasable branch for all five repositories. Keep it green and ready for a stable release at the end of every completed slice.

Use short-lived topic or review branches for runtime, release, security, upstream-import, and cross-repository stack changes. Keep each branch focused on one coherent slice, attach CI and review notes through a pull request or equivalent review record, then land the validated result on `main` before release. Delete the branch locally and remotely unless it is still needed for an open review.

The stable release helper promotes `container-compose` `main` through an automated short-lived pull request by default, so pull-request checks and review state remain visible before the semantic release tag is created. The Apple-backed sibling forks are still pushed directly to their stephenlclarke-owned remotes during stack promotion, after the helper verifies that Apple remotes are read-only.

Do not create additional long-lived integration or packaging lanes. Non-main branches are topic or review references only.

## Version And Release Rhythm

Normal work lands on `main`. After each completed and validated slice, create the next stable release with:

```sh
make release VERSION_SELECTOR=--+
```

The release helper resolves symbolic selectors from the latest local semantic `container-compose` tag, not from mutable working-tree state. Bare `MAJOR.MINOR.PATCH` source tags match Apple repository conventions; do not add a `v` prefix. Existing tags are never moved.

Main-lane package artifacts are validation artifacts only. They prove that the current `main` branch can produce an installable archive, but they do not update the stable Homebrew formula. Only bare semantic release tags update `stephenlclarke/tap/container-compose`.

## Release Helper

`scripts/CONTAINER_STACK_RELEASE.sh` is the maintainer helper for stack release boundaries. It is not required for ordinary edits on `main`.

Run it from the `container-compose` checkout through Makefile targets:

```sh
make release-plan
make release VERSION_SELECTOR=--+
```

`make release-plan` is a dry run over the four local source checkouts and the
Homebrew tap workflow boundary. `make release` validates the source worktrees
and `stephenlclarke` push targets, synchronizes exact `containerization` SwiftPM
revision pins when the local runtime stack moved, prepares the version and stack
manifest, and runs the full local release gate. That gate validates builder-shim
coverage, containerization coverage plus integration, container coverage plus
integration, Compose source checks, the Compose parity suite including live
`build --check`, and the live tap formula syntax. The helper then promotes the
source branches,
waits for the matching immutable `container` package, creates one new semantic
`container-compose` tag, and dispatches the stable package workflow. The
workflow requires the tap token before it publishes, creates the release with
the archive and checksum assets in one operation, updates the tap, and the
helper verifies the live release and tap URL, version, and SHA.

Stable tags and published stable releases are immutable. The helper rejects an
existing local or remote semantic tag before it changes release files, and the
package workflow rejects an existing stable release instead of editing notes or
overwriting assets. Correct a failed release through an explicitly reviewed
incident change; do not replay a semantic version.

Release notes are rendered by [Tools/release/release-notes.py](Tools/release/release-notes.py). The notes compare against the newest published stable GitHub release when release metadata is available, with local semantic tags as the offline fallback, so unpublished source tags cannot hide user-facing changes. They include a raw commit audit list, and they promote user-facing `Release-Note:` or `Release-Highlight:` commit trailers into a `Highlights` section before that list. Use single-line trailers that describe the Docker Compose feature, CLI option, or workflow users now get; internal release, CI, and documentation chores should normally omit the trailer or use `Release-Note: none`. For upstream-driven work, also record the original `owner/repository#number` under `Upstream-Ref:`, `Bug-Ref:`, `Refs:`, or `Follow-up-To:`. The renderer preserves references already written into the highlight and appends any missing references, including highlights collected from stack component commits.

`VERSION_SELECTOR` accepts:

- `--+`: patch bump from the latest semantic tag.
- `-+-`: minor bump from the latest semantic tag and reset patch to `0`.
- `+--`: major bump from the latest semantic tag and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit stable release version.

The container package wait, Compose package wait, and pull-request promotion wait all default to one hour with 30-second polls. Override them only for emergency maintenance with `CONTAINER_STACK_RELEASE_WAIT_SECONDS`, `CONTAINER_STACK_RELEASE_POLL_SECONDS`, `CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS`, `CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS`, `CONTAINER_STACK_RELEASE_PROMOTION_WAIT_SECONDS`, or `CONTAINER_STACK_RELEASE_PROMOTION_POLL_SECONDS`.

The helper refuses Apple push targets. stephenlclarke-owned remotes are the only release push targets.

`CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=direct` is reserved for emergency maintenance when stephenlclarke/container-compose branch protection intentionally permits a direct push. The default `pr` mode is the normal release path.

`CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE=checked-admin` is the default for the solo-maintainer release repository. It waits for pull-request checks, tries a normal merge, and uses an admin merge only when GitHub blocks the merge on the required-review rule that the PR author cannot satisfy. Set it to `strict` when another reviewer is available and the helper should fail instead of using that checked admin merge.

## Runtime Ref Policy

`container-compose` must stay on the `stephenlclarke` runtime surfaces while those APIs differ from released Apple packages. Do not silently drift back to incompatible `apple/container` or `apple/containerization` revisions.

The exact `container` commit used by CI and package metadata is resolved automatically from the sibling `../container` checkout for local development, then from the latest published `stephenlclarke/container` `homebrew-main-RUN-SHA` tag, and finally from `stephenlclarke/container:main` only when no published package tag exists. The resolver is [Tools/release/resolve-container-ref.py](Tools/release/resolve-container-ref.py); do not reintroduce duplicated hand-maintained pin prose in the docs.

`container` and `container-compose` pin `stephenlclarke/containerization` by exact SwiftPM `revision` in `Package.swift`. `Tools/release/stack-refs.json`, both `Package.swift` manifests, and both `Package.resolved` lockfiles must name the same revision; `make check` enforces this through [Tools/ci/check-stack-consistency.py](Tools/ci/check-stack-consistency.py).

`container` pins the builder shim through `BUILDER_SHIM_REPOSITORY` and `BUILDER_SHIM_VERSION`. Publish and verify an immutable GHCR builder image before updating `container` to a new shim tag.

Before upstream handoff, runtime-stack promotion, or release review work, run:

```sh
make upstream-divergence-report
```

The report fetches the stephenlclarke and Apple `main` refs for `container`, `containerization`, and `container-builder-shim`, writes Markdown and JSON under `.build/reports/`, lists fork-only and upstream-only commit subjects, and records whether Apple upstream can merge cleanly into each local checkout. Use `make upstream-divergence-check` when dirty worktrees, unpushed local commits, missing refs, or Apple upstream merge conflicts should fail the review.

## Homebrew Formulae

The aggregate tap is `stephenlclarke/homebrew-tap`.

| Formula | Installs |
| --- | --- |
| `container` | Current `stephenlclarke` runtime from the latest immutable `homebrew-main-RUN-SHA` package lane. |
| `container-compose` | Current stable plugin package from the latest semantic release; depends on the matching `container` formula. |

The install formulae consume validated GitHub release assets. `container-compose` follows the latest stable semantic release and is what users install. Both formulae record the published `stephenlclarke/container` runtime commit in package metadata, so runtime/plugin mismatches fail fast and `brew upgrade` can keep the installed stack aligned. The tap does not install from `sources/*` submodules.

`stephenlclarke/homebrew-tap/Formula/container-compose.rb` is the only live
formula. `Tools/release/container-compose.rb.in` is a non-release source
template used by the package workflow to render that tap formula. It never
claims a published release version or checksum, so a source tag cannot carry a
stale Homebrew release reference.

The tap `sources/container`, `sources/container-compose`, `sources/containerization`, and `sources/container-builder-shim` submodules are maintenance inputs that track project `main` branches.

Install, upgrade, verification, and uninstall commands live in [INSTALL.md](INSTALL.md). Source build and package commands live in [BUILD.md](BUILD.md).

## Local Checkout Rules

For normal integration work and release promotion, keep all five repositories on
`main` after each reviewed slice lands:

```sh
git -C ~/github/container-builder-shim switch main
git -C ~/github/containerization switch main
git -C ~/github/container switch main
git -C ~/github/container-compose switch main
git -C ~/github/homebrew-tap switch main
```

After a non-main branch has been landed on `main`, delete that branch locally and remotely unless it is still needed for an open review.

## Release Retention

Keep stable source tags and GitHub release objects. Release automation keeps binary assets on the latest main validation release and the latest stable release. Older release assets are pruned only after their release notes include the original prebuilt asset SHA-256 and a copy/paste Homebrew source-install block that rebuilds from the retained source tag.
