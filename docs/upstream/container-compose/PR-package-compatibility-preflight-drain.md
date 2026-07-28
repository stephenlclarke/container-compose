# Pull request: drain package preflight output while the child runs

## Summary

- Make runtime package and service preflight commands asynchronous.
- Reuse `ComposeCore.ProcessRunner` so stdout and stderr drain concurrently.
- Inherit the shared process runner's cancellation and process-group ownership.
- Preserve stderr-first failed-command diagnostics while limiting displayed
  output to a 64 KiB raw-stream boundary with exact omitted-byte accounting.
- Cover output larger than 256 KiB on both streams, bounded errors, and
  cancellation with child-reaping evidence, including malformed UTF-8.
- Convert preflight-time host signals into owned child cancellation before the
  CLI exits with the corresponding conventional shell status.

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
cannot distort the diagnostic boundary or omitted-byte count. Signed
connector-review correction `e0ad1dfe`, `fix(plugin): bound preflight
diagnostic memory`, replaces the intermediate per-byte unit array with a
single pass over the retained raw data. The pass keeps only the bounded
rendered prefix and byte offsets, so diagnostic formatting no longer amplifies
large child output into proportional per-byte object storage. Signed
connector-review correction `4bf2eac6`, `fix(core): preserve command result
equality`, defines equality in terms of the existing public status, stdout, and
stderr contract so package-private raw bytes do not change observable
semantics. Signed test correction `592266a7`, `test(plugin): enforce preflight
memory bound`, runs the complete CLI preflight in an isolated process and
asserts a 16 MiB failure remains below 320 MiB maximum resident memory. Signed
connector-review correction `3ed87228`, `fix(plugin): forward preflight
interrupts`, uses the existing Compose signal proxy to cancel the isolated
preflight task before returning the corresponding shell status.

The production change is limited to the package preflight implementation, its
single asynchronous call site and executable interruption boundary, and
package-private raw output retained by the shared process runner. The public
`CommandResult` string API remains unchanged. The slice changes no Apple
runtime fork, package matching rule, or Docker-shaped runtime primitive. See
the companion [issue handoff](ISSUE-package-compatibility-preflight-drain.md).

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
  its public string accessors and equality contract.
- `ContainerPackageCompatibility.boundedDiagnostic` cuts at a 64 KiB raw-stream
  boundary in one pass without splitting a valid UTF-8 scalar or retaining a
  per-byte model, then appends the exact omitted source-byte count.
- `ComposePluginMain.main` awaits the throwing compatibility preflight and
  converts a retained host signal into its conventional shell exit status.
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

- 21 package-compatibility tests in four suites pass;
- the 307,200-byte stdout and stderr child exits normally;
- `CommandResult` values with identical public status and decoded strings remain
  equal even when their package-private raw bytes differ;
- malformed UTF-8 retains its original byte count through bounded diagnostics;
- an isolated packaged CLI writes 16 MiB to stderr, exits below 320 MiB maximum
  resident memory, and renders a diagnostic below 67,000 bytes;
- the isolated 16 MiB memory regression also passes with Address Sanitizer;
- cancellation from both compatibility awaits remains `CancellationError`,
  and the TERM-ignoring cancellation child is reaped within two seconds;
- an isolated full CLI receives SIGINT, reaps its TERM-ignoring preflight child,
  and exits with status 130;
- the previously hanging packaged-CLI reproduction times out at five seconds
  before the fix and exits with the expected compatibility failure after it;
- six metrics-generator regression tests and Python compilation pass;
- the generated 28 July 2026 snapshot reports all three support forks zero
  behind Apple and 493 commits ahead in total; and
- `HAWKEYE_AUTO_INSTALL=1 make ci` passes 1,260 Swift tests in 44 suites,
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
- [x] Bounded-allocation large-diagnostic coverage
- [x] Public `CommandResult` equality compatibility coverage
- [x] Isolated full-CLI maximum resident memory coverage
- [x] Cancellation and child-reaping coverage
- [x] Host-signal forwarding and conventional exit-status coverage
- [x] Worktree-safe generated metrics regression coverage
- [x] Complete local repository gate
- [x] Signed Conventional documentation commit
- [ ] Pull-request checks and connector review
- [ ] Exact-main CI, CodeQL, and SonarCloud gate
- [ ] Slice prerelease, checksums, attestations, and Homebrew update
