# Pull Request: resolve the gRPC-Go security alert

<!-- markdownlint-disable MD013 -->

## Summary

- Upgrade the normalizer's indirect `google.golang.org/grpc` dependency from `v1.81.1` to `v1.82.1`.
- Resolve the repository's Dependabot alert for `GHSA-hrxh-6v49-42gf` without broad dependency churn.
- Record unit, full-suite, and Docker Compose v2 macOS parity evidence for the signed change.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The Compose normalizer inherited a vulnerable gRPC-Go version through its dependency graph. Dependabot's proposed update is a two-line source manifest change plus the corresponding reproducibility hashes. This direct signed commit carries that exact minimal upgrade while retaining ownership of the fork's release-facing main branch.

## Commit Tracking

- Dependabot alert: [#24](https://github.com/stephenlclarke/container-compose/security/dependabot/24).
- Upstream automation proposal: [#135](https://github.com/stephenlclarke/container-compose/pull/135).
- Code and test subject:
  `62ebc4049ef031bf3e33a7cc92c792c4a352054e`
  (`chore(go): update grpc security patch`).

## Implementation Details

- `Tools/compose-normalizer/go.mod` now selects `google.golang.org/grpc v1.82.1`.
- `Tools/compose-normalizer/go.sum` contains only the two hashes corresponding to that version change.
- No Compose-model code, Apple runtime adapter, Containerization source, or platform-specific behavior changed.

## Docker Compose Compatibility Notes

The full local comparison ran on the MBP against Docker Compose v2 `5.3.1` and the matched Apple Container runtime. It passed with `COMPOSE_PARITY_EXIT=0`, covering model, build, mount, namespace, network, event, state, and lifecycle scenarios. The dependency update is therefore transparent to Docker Compose v2 parity.

## Testing

- [x] Tested locally on the MBP
- [x] Added/updated dependency lock data
- [x] Added/updated handoff documentation

```sh
cd Tools/compose-normalizer
go mod verify
go test ./... -cover

cd ../..
make test
make docker-compose-parity
make lint
git diff --check
```

Results before documentation validation: all modules verified; Go package coverage reached 89.9% in the normalizer root package; `make test` passed 1,113 Swift tests in 26 suites; and full Docker Compose v2 `5.3.1` parity passed. `make lint` and GitHub Actions/SonarQube verification are recorded after this handoff document is committed and pushed.

## container-compose Checks

- [x] Updated `docs/upstream/` with issue and pull-request handoff documents.
- [x] Focused on one security remediation.
- [x] Attached local runtime, test, and parity evidence.
- [x] Used a signed Conventional Commit.
- [x] `Release-Note: none` — this is an internal security patch with no user-visible Compose behavior change.
- [x] Included Dependabot alert #24 and proposal #135.
- [x] Signed the code commit with the configured GitHub-supported signing key.
- [x] No credentials, tokens, private keys, personal data, or registry details were introduced.

## Review Checklist

- [x] The gRPC version matches Dependabot's minimal remediation.
- [x] The module lock hashes match the selected version.
- [x] The change does not expand the Apple runtime fork surface.
- [x] Current release verification remains required before beginning Phase 3 work.
