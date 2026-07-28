# Pull request: drain package preflight output while the child runs

## Summary

- Make runtime package and service preflight commands asynchronous.
- Reuse `ComposeCore.ProcessRunner` so stdout and stderr drain concurrently.
- Inherit the shared process runner's cancellation and process-group ownership.
- Preserve stderr-first failed-command diagnostics while limiting displayed
  output to a 64 KiB raw-stream boundary with exact omitted-byte accounting.
- Cover output larger than 256 KiB on both streams, bounded errors, and
  cancellation with child-reaping evidence, including malformed UTF-8.

## Intended review delta

Apply signed commit
[`81d32eb24493f294ccdc86e7ff0c52881995c94a`](https://github.com/stephenlclarke/container-compose/commit/81d32eb24493f294ccdc86e7ff0c52881995c94a),
`fix(plugin): drain compatibility preflight output`, followed by signed review
corrections `96ac7830`, `fix(plugin): preserve diagnostic character boundaries`,
and `045d020c`, `fix(plugin): propagate preflight cancellation`. The latter
preserves structured cancellation from both the version and service-status
awaits instead of converting it into user guidance. Signed connector-review
correction `9db8f060`, `fix(plugin): preserve raw diagnostic byte counts`,
retains the process runner's raw output inside the package so malformed UTF-8
cannot distort the diagnostic boundary or omitted-byte count.

The production change is limited to the package preflight implementation, its
single asynchronous call site, and package-private raw output retained by the
shared process runner. The public `CommandResult` string API remains unchanged.
The slice changes no Apple runtime fork, package matching rule, or
Docker-shaped runtime primitive. See the companion [issue
handoff](ISSUE-package-compatibility-preflight-drain.md).

Signed follow-up commits `5d9898c3` and `56bb08d5` also make the generated
README divergence snapshot resolve the linked stack root from Git's common
directory without requiring its newer absolute-path option, so the same
automation works from both primary checkouts and isolated worktrees.

## Code map

- `ContainerPackageCompatibility.compatibilityFailure(arguments:lane:...)`
  awaits version and service commands.
- `ContainerPackageCompatibility.captureCommand` delegates process ownership,
  empty stdin, exit handling, and stream drainage to `ProcessRunner`.
- `CommandResult` retains package-private raw stdout and stderr while preserving
  its public string accessors.
- `ContainerPackageCompatibility.boundedDiagnostic` cuts at a 64 KiB raw-stream
  boundary without splitting a valid UTF-8 scalar and appends the exact omitted
  source-byte count.
- `ComposePluginMain.main` awaits the throwing compatibility preflight.
- The serialized package-preflight process suite uses real shell children to
  reproduce full-pipe, failure, and cancellation behaviour.
- `update-readme-upstream-metrics.py` derives the sibling repository root from
  `git rev-parse --git-common-dir`, with deterministic primary-checkout,
  linked-worktree, and fallback tests.

## Local validation

```console
swift test --disable-automatic-resolution --filter ContainerPackage
python3 Tools/ci/test_update_readme_upstream_metrics.py
python3 -m py_compile \
  Tools/ci/update-readme-upstream-metrics.py \
  Tools/ci/test_update_readme_upstream_metrics.py
make readme-upstream-metrics-update
make readme-upstream-metrics-check
```

Results on the designated Apple silicon MacBook Pro:

- 19 package-compatibility tests in three suites pass;
- the 307,200-byte stdout and stderr child exits normally;
- malformed UTF-8 retains its original byte count through bounded diagnostics;
- cancellation from both compatibility awaits remains `CancellationError`,
  and the TERM-ignoring cancellation child is reaped within two seconds;
- the previously hanging packaged-CLI reproduction times out at five seconds
  before the fix and exits with the expected compatibility failure after it;
- six metrics-generator regression tests and Python compilation pass;
- the generated 28 July 2026 snapshot reports all three support forks zero
  behind Apple and 493 commits ahead in total; and
- `HAWKEYE_AUTO_INSTALL=1 make ci` passes 1,257 Swift tests in 42 suites,
  92.80% Swift coverage, 89.88% Go coverage, and the complete CLI, lint,
  dependency, licence, and smoke gates.

## Publication evidence

Exact-head pull-request checks, connector review, exact-main validation, and the
slice `current` prerelease remain pending until this branch is published.

## Compatibility and risk

- Successful version output is returned unchanged to the JSON decoder.
- Failed commands still prefer stderr, then stdout, then the command name.
- Diagnostic bounding happens only after both streams have been completely
  drained.
- The existing process runner sends termination only to its exact owned process
  group and waits for child reaping.
- The implementation introduces no new global process registry, signal
  handler, runtime dependency, or Apple fork divergence.
- Metrics root discovery falls back to the prior checkout-parent behaviour when
  Git cannot report a normal common `.git` directory.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Compose-plugin-only production change
- [x] Large stdout and stderr regression coverage
- [x] Bounded failure diagnostic coverage
- [x] Multibyte diagnostic boundary coverage
- [x] Malformed UTF-8 raw-byte accounting coverage
- [x] Cancellation and child-reaping coverage
- [x] Worktree-safe generated metrics regression coverage
- [x] Complete local repository gate
- [x] Signed Conventional documentation commit
- [ ] Pull-request checks and connector review
- [ ] Exact-main CI, CodeQL, and SonarCloud gate
- [ ] Slice prerelease, checksums, attestations, and Homebrew update
