# Pull request: avoid oversized release dependency caches

## Summary

- Remove the release job's exact/ref-fallback SwiftPM build-tree cache.
- Disable the `setup-go` module/build cache in the release job.
- Lock both decisions with workflow-policy regression coverage.
- Keep source checkouts, authority checks, package commands, attestations,
  Homebrew promotion, and typed/live VHS recording unchanged.

## Intended review delta

Apply signed implementation commit
`6cae9a84deee2b13eecfeb1efbf83ad2c98f88a9`
(`perf(release): avoid oversized dependency caches`) from
`chore/upstream-audit-20260727`.

The companion report is
[ISSUE-release-dependency-cache-overhead.md](ISSUE-release-dependency-cache-overhead.md).

## Code map

- `.github/workflows/prebuilt-binaries.yml`: removes the SwiftPM cache
  fingerprint/action and configures release `setup-go` with `cache: false`.
- `Tools/release/test_container_stack_release.py`: requires those cache-free
  release policies.

## Validation

```console
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_current_package_avoids_oversized_dependency_caches \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_current_package_workflow_only_follows_successful_main_ci
ruby -ryaml -e \
  'YAML.unsafe_load_file(".github/workflows/prebuilt-binaries.yml")'
actionlint .github/workflows/prebuilt-binaries.yml
python3 -m unittest discover Tools/release
make ci
git diff --check
```

The two focused workflow-policy tests, YAML load, and actionlint pass locally.
The complete release suite passes 175 tests. Full CI passes 1,249 Swift tests
in 41 suites with 92.81% Swift and 89.88% Go coverage. Pull-request-hosted
checks remain required before merge.

## Baseline evidence

Current run
[`30235634675`](https://github.com/stephenlclarke/container-compose/actions/runs/30235634675)
recorded:

| Step | Duration | Cache transfer |
| --- | ---: | ---: |
| Cache SwiftPM build artifacts | 10m 00s | 2,134,173,923 bytes |
| Build matched runtime package | 2m 25s | none |
| Set up Go | 19m 19s | 1,624,881,811-byte attempted restore |
| Build release package | 2m 17s | none after the Go restore failed |

The Go cache failed authentication after receiving about 1.29 GB; the build
then succeeded. This makes the no-cache behavior directly equivalent to the
successful portion of the observed run.

## Publication comparison

Exact-main Current run
[`30255646679`](https://github.com/stephenlclarke/container-compose/actions/runs/30255646679)
published merge `4fe88b796fe2b4b3008ccc7da8d284cedd4235c4` successfully.

| Step | Duration | Cache transfer |
| --- | ---: | ---: |
| Cache SwiftPM build artifacts | removed | none |
| Build matched runtime package | 2m 50s | none |
| Set up Go | 0s | none; `setup-go` cache disabled |
| Build release package | 2m 31s | none |
| Generate Current build VHS recording | 6m 38s | none |
| Package job total | 14m 18s | none from the removed release caches |

The baseline package job took 43m 01s. The Current job that contains this
change avoided the prior 2,134,173,923-byte SwiftPM cache transfer and the
1,624,881,811-byte Go cache restore attempt while preserving the same release
authority, package, attestation, Homebrew, and live VHS stages.

The refreshed `current` prerelease is not a draft, is marked prerelease, targets
`4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`, and was published at
2026-07-27 10:05:13 UTC. Both package archives have verified SHA-256 sidecars
and locally verified GitHub attestations:

- `container-compose-plugin-current-4fe88b796fe2-arm64.tar.gz`:
  `cc51d5dea4feabf84a66fc024a22b067b61a307f078bf23a48fa3ea1d32771ac`
- `container-current-4fe88b796fe2-arm64.tar.gz`:
  `64b47eb5377b7f60c70381008510656d2a88dee1b4c625e349da2eba6ab840b2`

Homebrew tap commit
`5d53619c83bd8a2b1b47638d8d99d0c817d1ed17` updates
`container-current.rb` and `container-compose-current.rb` to
`current.895.4fe88b796fe2` with the matching asset names and SHA-256 values.

## Compatibility and risk

- The clean job already checks out every exact source revision and SwiftPM
  resolves from tracked manifests.
- `setup-go` still installs/selects the version pinned by `go.mod`; only its
  cache restore/save behavior changes.
- Cold build duration can vary, but the exact-main Current run confirms the
  release path no longer pays the deterministic 3.76 GB transfer obligation
  observed to exceed the builds it was intended to accelerate.
- CI, CodeQL, Quality, and stable-gate caches are unchanged.
- Archive contents, checksums, attestations, formulae, and release identity are
  unchanged.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Focused workflow-policy tests
- [x] YAML parse and actionlint
- [x] Complete release test suite
- [x] Pull-request checks and connector review
- [x] Exact-main Current publication and timing comparison
