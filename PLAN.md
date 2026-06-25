# container-compose Plan

This is the living roadmap for `container-compose`. It should stay small enough to review in one pass. Historical validation evidence, parked-session notes, and old slice ledgers belong in git history, CI logs, or the upstream handoff drafts under `docs/upstream/`, not in this file.

For current branch state, blockers, and validation status, use [STATUS.md](STATUS.md).

## Direction

`container-compose` owns Docker Compose compatibility policy. Keep Compose-specific parsing, service selection, project filtering, output formatting, and Docker-compatible option behavior in this repository.

The Apple runtime forks should expose smaller Apple-native primitives that can be reviewed independently: lifecycle metadata, health state, restart policy, event streams, log retrieval/follow streams, copy options, process listing, networking identity, and resource controls.

## Branch Lanes

- `main`: active development and integration lane. Keep full CI, CodeQL, and SonarQube here so the public badges describe the code under active review.
- `release/*`: frozen release lanes. Build optimized prebuilt assets, remove branch-inappropriate SonarQube badges, and update the release Homebrew formula from published assets.
- `snapshot/*`: frozen debug snapshot lanes. Build debug Swift prebuilt assets, keep the Go normalizer release-built, remove branch-inappropriate SonarQube badges, and update the snapshot Homebrew formula from published assets.

The `container-compose` branch must stay pinned to the required `stephenlclarke/container` and `stephenlclarke/containerization` surfaces. Do not silently drift back to incompatible `apple/container` or `apple/containerization` surfaces while fork-backed behavior is still required.

## Current Focus

Keep the prebuilt install path healthy for both lanes:

- GitHub Actions publishes branch release assets for frozen `release/*` and `snapshot/*` branches.
- Homebrew installs those prebuilt Swift and Go binaries without requiring Go, Xcode, or a Swift toolchain on the target machine.
- Package targets always include a release-built Go normalizer, even when the Swift plugin is a debug snapshot build.
- CI accepts classified SwiftPM signal-pass output only when the helper proves tests passed and no failure markers were emitted.
- Homebrew advisory jobs trust only the specific taps required by the formulas.

## Upstreamable Runtime Slices

Prefer PR-sized runtime slices in this rough order when continuing Apple-facing work:

1. Logs and logging: retrieval filters, structured records, static rotated replay, local logging policy, raw follow, and structured follow.
2. Lifecycle and dependency state: exit metadata, health state, healthcheck configuration, image healthcheck inheritance, restart policy, and restart timing.
3. Events and process data: generic container lifecycle events, event time filters, process identifiers, and richer `top` metadata.
4. Networking identity: host entries, host gateway, hostname, domain name, network aliases, links, external links, fixed IPs, and multi-network DNS behavior.
5. Runtime controls and data movement: pause/unpause, copy follow-link/archive, build inputs, mounts, secrets/configs, blkio, sysctls, and device controls.

Each Apple-facing slice should avoid Compose output policy. Each `container-compose` slice should consume the smallest runtime primitive available and keep Docker Compose behavior local to this plugin.

## Review Gates

Before pushing a functional slice:

- Verify the fork dependency pins still point at the required `stephenlclarke` branches or revisions.
- Check open Apple and peer PRs for API drift or overlapping work.
- Run the focused tests for touched code and `make ci` for `container-compose` unless the toolchain or runtime is externally blocked.
- Update [STATUS.md](STATUS.md) only with current branch state, blockers, and validation. Do not paste long evidence logs.
- Keep commits small, Conventional Commits compliant, and free of prohibited wording.

## Documentation Rules

- [README.md](README.md) maps readers to the right document.
- [INSTALL.md](INSTALL.md) owns install and uninstall flows.
- [BRANCHES.md](BRANCHES.md) owns lane selection.
- [BUILD.md](BUILD.md) owns build, test, package, and validation commands.
- [DESIGN.md](DESIGN.md) owns architecture and runtime boundary decisions.
- [STATUS.md](STATUS.md) owns current state only.

When detailed evidence is needed, link to the commit, CI run, issue, PR, or handoff draft rather than copying a permanent transcript into top-level docs.
