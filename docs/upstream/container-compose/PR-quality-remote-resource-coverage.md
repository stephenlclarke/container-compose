# Pull Request: harden macOS remote-resource cache handling

## Summary

- Fall back to the macOS cache directory when `XDG_CACHE_HOME` is empty.
- Add a private OCI resolver factory seam for deterministic loader coverage;
  the default resolver construction is unchanged.
- Add focused Git, OCI, cache, transform, and publish unit coverage.
- Refresh README warning and note callouts against the current source and
  support-fork revisions.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Remote Compose resources must not derive a relative cache location from an
empty XDG environment variable. The small correction is macOS-safe and keeps
the existing Library/Caches fallback. The expanded tests make the loader's
security and cleanup paths regression-proof while bringing Go coverage to the
requested threshold without reducing Swift coverage.

## Apple-shaped boundary

All runtime behavior remains in Compose's Go normalizer. The cache correction
uses macOS's existing user cache convention; it does not alter
`apple/container`, `apple/containerization`, builder-shim APIs, or the public
Compose protocol. The resolver factory is private to the OCI loader and uses
the identical default production resolver.

## Code map

- `Tools/compose-normalizer/remote/cache.go` ignores an empty XDG cache value.
- `Tools/compose-normalizer/remote/oci.go` obtains its resolver through a
  private factory, preserving the production default.
- `Tools/compose-normalizer/remote/*_test.go` covers cache, Git, and OCI
  loader success, failure, cleanup, and path-security cases.
- `Tools/compose-normalizer/transform/replace_test.go` and
  `publish_test.go` cover malformed YAML and Compose publication helpers.
- `README.md` now has source-accurate warning and runtime-boundary callouts.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Completed locally on macOS:

```sh
cd Tools/compose-normalizer && go test ./...
make coverage-check SWIFT_COVERAGE_MIN=90 GO_COVERAGE_MIN=90
make sonar
make docker-compose-git-remote-parity CONTAINER_COMPOSE_LIVE=0
make check
```

The full coverage gate reported 91.46% Swift and 90.05% Go. SonarCloud task
`AZ-De_V_iwMl2aqiErRl` completed successfully and its Quality Gate passed.
The new-code coverage condition was 80.3%, with no failed reliability,
security, maintainability, duplication, or hotspot condition.

`make docker-compose-git-remote-parity CONTAINER_COMPOSE_LIVE=0` passed against
Docker Compose V2 5.3.1. `make check` passed its formatting, license,
Hawkeye, stack-consistency, and Python validation suite.

## Docker Compose V2 integration

This change does not alter Compose YAML semantics or runtime orchestration.
The existing Git remote-resource fixture remains the Docker Compose V2 parity
oracle and is rerun before this handoff is pushed. OCI loader coverage uses a
deterministic in-process registry resolver so no private registry or network
credential appears in the test suite.

## Compatibility and non-goals

The default OCI resolver, remote-resource public interface, and Compose output
are unchanged. This does not implement Docker Engine behavior, Windows paths,
or Linux-only runtime behavior.

## Commit tracking

- Compose implementation:
  [`e91dfb6b`](https://github.com/stephenlclarke/container-compose/commit/e91dfb6b),
  `fix(normalizer): harden macOS remote resource cache`.
- Compose handoff: this documentation commit.

## container-compose Checks

- [x] `docs/upstream/` and README are updated; `STATUS.md` has no parity
  surface change to record.
- [x] This pull request is focused on one remote-resource cache and quality
  change.
- [x] Local coverage and SonarCloud quality evidence are attached above.
- [x] Conventional Commit and signed-commit requirements are met.
- [x] Release-Note: none; this fixes cache selection and test coverage only.
- [x] No upstream issue is required; the narrow implementation is Compose
  owned and does not change an Apple fork interface.
- [x] Credentials, tokens, private keys, personal data, and private registry
  details are absent from the implementation, tests, logs, and handoff.
