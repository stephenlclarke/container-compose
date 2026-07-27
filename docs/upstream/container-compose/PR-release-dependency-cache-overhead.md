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

## Compatibility and risk

- The clean job already checks out every exact source revision and SwiftPM
  resolves from tracked manifests.
- `setup-go` still installs/selects the version pinned by `go.mod`; only its
  cache restore/save behavior changes.
- Cold build duration can vary, so the next Current run is the authoritative
  end-to-end timing. The change removes a deterministic 3.76 GB transfer
  obligation observed to exceed the builds it was intended to accelerate.
- CI, CodeQL, Quality, and stable-gate caches are unchanged.
- Archive contents, checksums, attestations, formulae, and release identity are
  unchanged.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Focused workflow-policy tests
- [x] YAML parse and actionlint
- [x] Complete release test suite
- [ ] Pull-request checks and connector review
- [ ] Exact-main Current publication and timing comparison
