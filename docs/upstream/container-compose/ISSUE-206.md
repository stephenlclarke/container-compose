# Issue 206: release builds ignore configured local stack overlays

## Steps to reproduce

Configure `PARITY_ENV` with local Container, Containerization, and Engine API package paths, then invoke `make build-release`.

Before the correction, the debug build respected the local overlay but the release target rebuilt against the repository's stale remote Container revision. That made a release Compose binary unsuitable for exact local runtime validation even when the source and dependency stack had been selected intentionally.

## Resolution

Signed commit `30d3017112a9b7694aaec2ec80a0cfa411e6004d` applies the same transactional local-stack `Package.resolved` overlay to `build-release`, restores the lockfile afterward, and adds `Tools/ci/test_build_release_local_stack.py`. The focused Python test passes 2/2 and the exact local release build succeeded before the allocation-range certificate ran.

## Tracking

- GitHub issue: [stephenlclarke/container-compose#206](https://github.com/stephenlclarke/container-compose/issues/206).
- The issue is closed after the exact release candidate certificate passed.
- This was a Compose build integration defect, not an Apple upstream bug.
