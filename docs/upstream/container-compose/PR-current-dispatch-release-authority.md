# Pull request: accept full-dispatch Current authority

## Summary

Keep Current publication's two authority checks consistent. The package job
now accepts an exact-commit successful `main` CI run whether it was started by
the normal push path or by the explicit full-validation dispatch required
after a docs-only merge.

## Constructible commit

- `c8524d365b34386621bbfd3d5cd4839ccc8a08d3`
  `fix(release): accept dispatched main authority`

## Implementation

- Remove the `gh run list --event push` pre-filter from the package authority
  check.
- Request each candidate run's event and accept only completed successful
  `main` runs whose event is `push` or `workflow_dispatch`.
- Retain the exact commit selector and the independent package-time
  revalidation.
- Leave stable candidate-bound authority unchanged.

## Verification

```sh
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_stable_and_current_release_authority_select_main_ci \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_package_authority_requires_a_successful_candidate_bound_gate
python3 -m unittest discover Tools/release
ruby -ryaml -e 'YAML.unsafe_load_file(".github/workflows/prebuilt-binaries.yml")'
npx --yes markdownlint-cli2 \
  docs/upstream/container-compose/ISSUE-current-dispatch-release-authority.md \
  docs/upstream/container-compose/PR-current-dispatch-release-authority.md
git diff --check
```

## Hosted confirmation

1. Require exact-head CI, CodeQL, and connector review.
2. Merge the signed correction and handoff to `main`.
3. Require full exact-main CI and SonarCloud.
4. Publish Current from that exact merge and verify both archives, checksums,
   attestations, Homebrew formulae, and the typed/live VHS asset.

## Compatibility and risk

The accepted event set is identical to the stricter publish-context controller
that already verified the failed run. Pull-request and other event types remain
excluded, and the exact commit plus `main` branch filters remain fail-closed.
The change is isolated to the Compose release layer.

Tracked by
[`stephenlclarke/container-compose#163`](https://github.com/stephenlclarke/container-compose/issues/163).
