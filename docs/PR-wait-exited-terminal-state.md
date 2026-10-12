# fix(core): replay naturally exited service wait results

## Motivation

Native discovery correctly distinguishes a never-started `created` container from a naturally completed `exited` container. Compose wait only accepted the runtime spelling `stopped`, causing the current native logging run to fail after eight samples. Preserve that original failure and the strict lifecycle/cleanup contract.

## Implementation

Accept `stopped` and `exited` in the shared stored-exit-code path used by `wait` and `wait --down-project`. Return the stored code unchanged. Missing-code errors now name the actual reported state. Running/stopping targets retain runtime waits; unsupported states still fail before wait or teardown. No provider, transport, capability, timeout or workload changes are included.

## Validation

Existing orchestration tests now cover both terminal spellings with zero and nonzero codes, both missing-code states, running/stopping waits and down-project ordering. Additional parameterized cases reject `created`/unknown states with an apparent exit code for ordinary wait and down-project, proving no runtime wait or cleanup occurs. Scoped SwiftFormat and Markdown checks pass. Strict SwiftLint reports 29 preexisting findings across the two maintained files, versus 31 on the base; no finding is introduced and unrelated lint cleanup is excluded. Heavy test execution is deliberately pending root's serial native Bazel validation from an immutable checkpoint; source-only checks do not replace that proof.

## Compatibility and risks

The shared path supports existing stock `stopped` snapshots and the enhanced adapter's `exited` projection. Exit-code formatting and project teardown options are unchanged. The missing-code diagnostic becomes truthful for both spellings. Complete runtime/parity/release qualification remains separate, and prior performance/reference rows remain immutable.

## Linked issue

[ISSUE-wait-exited-terminal-state.md](ISSUE-wait-exited-terminal-state.md). No upstream issue or pull request number is claimed.
