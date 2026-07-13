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

Every green `main` commit publishes an installable **current** stack. A bare
semantic tag publishes a **stable** stack. These are formula pairs, never
independently moving formulae:

| Channel | Runtime formula | Compose formula | Source of truth |
| --- | --- | --- | --- |
| Stable | `container` | `container-compose` | A semantic Compose tag at the green `main` head. |
| Current | `container-current` | `container-compose-current` | The latest green Compose `main` commit and the exact runtime ref in its stack manifest. |

`container-compose` owns both promotions. It verifies the runtime asset pinned
by `Tools/release/stack-refs.json`, then commits the two formula changes in one
tap commit. A runtime build never writes either stable formula by itself.

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
revision pins when the local runtime stack moved, and creates a reviewable
release-preparation commit. This is the helper's only version mutation. It then
promotes the source branches, waits for the matching immutable `container`
current package, creates one new semantic `container-compose` tag, dispatches
the hosted Stable Release Gate, and then dispatches the stable package workflow.
The hosted gate first requires green `main` CI—the only place SonarQube analyses
the project—then runs full stack parity against the exact tagged commit. The
package workflow verifies that hosted evidence and the runtime asset before it
creates the release and atomically updates the tap.

Source tags and every published GitHub release are immutable. The package
workflow rejects an existing stable or current release instead of editing notes
or overwriting assets. Correct a failed release through an explicitly reviewed
incident change; do not replay an identity.

Release notes are rendered by [Tools/release/release-notes.py](Tools/release/release-notes.py). The notes compare against the newest published stable GitHub release when release metadata is available, with local semantic tags as the offline fallback, so unpublished source tags cannot hide user-facing changes. They include a raw commit audit list, and they promote user-facing `Release-Note:` or `Release-Highlight:` commit trailers into a `Highlights` section before that list. Write one complete sentence that names the Docker Compose feature, CLI option, or workflow users now get; internal release, CI, and documentation chores should normally omit the trailer or use `Release-Note: none`, which suppresses an automatic highlight. When a user-facing conventional commit has no trailer, the renderer uses the first prose paragraph from its body before falling back to the subject. For upstream-driven work, also record the original `owner/repository#number` under `Upstream-Ref:`, `Bug-Ref:`, `Refs:`, or `Follow-up-To:`. The renderer preserves references already written into the highlight and appends any missing references, including highlights collected from stack component commits.

`VERSION_SELECTOR` accepts:

- `--+`: patch bump from the latest semantic tag.
- `-+-`: minor bump from the latest semantic tag and reset patch to `0`.
- `+--`: major bump from the latest semantic tag and reset minor and patch to `0`.
- `MAJOR.MINOR.PATCH`: explicit stable release version.

The container package wait, Compose package wait, and pull-request promotion wait all default to one hour with 30-second polls. Override them only for emergency maintenance with `CONTAINER_STACK_RELEASE_WAIT_SECONDS`, `CONTAINER_STACK_RELEASE_POLL_SECONDS`, `CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS`, `CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS`, `CONTAINER_STACK_RELEASE_PROMOTION_WAIT_SECONDS`, or `CONTAINER_STACK_RELEASE_PROMOTION_POLL_SECONDS`.

The helper refuses Apple push targets. stephenlclarke-owned remotes are the only release push targets.

`CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=direct` is reserved for emergency maintenance when stephenlclarke/container-compose branch protection intentionally permits a direct push. The default `pr` mode is the normal release path.

`CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE=checked-admin` is the default for the solo-maintainer release repository. It waits for pull-request checks, tries a normal merge, and uses an admin merge only when GitHub blocks the merge on the required-review rule that the PR author cannot satisfy. When GitHub already records an equivalent candidate tree with rewritten history, whether before promotion or while the promotion PR waits, the helper verifies tree identity and aligns local `main` to the promoted commit before tagging; a non-identical remote change still requires a fresh validation run. Set it to `strict` when another reviewer is available and the helper should fail instead of using that checked admin merge.

## Runtime Ref Policy

`container-compose` must stay on the `stephenlclarke` runtime surfaces while those APIs differ from released Apple packages. Do not silently drift back to incompatible `apple/container` or `apple/containerization` revisions.

 `Tools/release/stack-refs.json` is the canonical runtime pin for CI, packaging,
 and formula promotion. [Tools/release/resolve-container-ref.py](Tools/release/resolve-container-ref.py)
 rejects a checked-out runtime that differs from that manifest; it only falls
 back to the latest immutable `current-RUN-SHA` runtime tag or `main` when no
 manifest is present. Do not reintroduce duplicated hand-maintained pin prose.

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
| `container` + `container-compose` | Stable matched stack from the latest semantic Compose release. |
| `container-current` + `container-compose-current` | Installable current matched stack from green `main` commits. |

The formula pairs consume validated immutable GitHub release assets. Stable is
the default install. Current is explicitly opt-in. The pair update is atomic,
so Homebrew never combines a newly published runtime with an unrelated Compose
plugin. The tap does not install from `sources/*` submodules.

`Tools/release/container-compose.rb.in` and `container/Formula/container.rb`
are non-release source templates. The package workflow renders both members of
a lane from immutable release assets; source files never claim a published
checksum or live formula version.

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

Keep all source tags, GitHub release objects, release notes, highlight manifests,
and binary assets. GitHub immutable releases enforce this policy; package
retries create no mutations and a correction requires a new reviewed release.
