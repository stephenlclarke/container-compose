# Issue 362: complete the deterministic recoverable release graph

## Problem

The retained 0.14.0 release evidence showed avoidable repetition and non-deterministic recovery boundaries. The hosted Stable Release Gate spent 3 minutes 47 seconds replaying Compose validation that had already passed at the exact immutable main commit, then spent 25 minutes 53 seconds validating independent sibling repositories serially. Mutable workflow inputs, live tool installation, broad bespoke checkpoint fingerprints, and unsigned retained release candidates also prevented a retry from proving that it reused only authentic exact-input evidence.

Tracking issue: [`#362`](https://github.com/stephenlclarke/container-compose/issues/362).

## Required outcome

- Reuse exact green Compose main CI rather than replaying it in the post-tag gate.
- Run release-specific sibling validation through the checked-in checksum-pinned Nextflow graph.
- Permit one Swift-heavy lane and one independent Go or Homebrew lane while preventing competing Swift package graphs.
- Persist the graph beneath one durable marked state root and resume content-addressed work after an interruption.
- Authenticate published stage logs and prove recovery after output deletion or corruption.
- Pin workflow actions, runner images, dependency resolution, and downloaded tools to immutable inputs.
- Reject unsupported Bash runtimes during preflight instead of installing mutable host packages inside a release.
- Verify signatures plus exact subject, ancestry, and changed-file allowlists before reusing any retained release-generated candidate.
- Keep CodeQL and DocC in their release-only authorities and out of development validation.

## Acceptance evidence

- The `release-hosted` plan contains four immutable sibling repositories and eight stages without a Compose CI stage.
- A focused Homebrew execution completes through preflight, source validation, functional validation, and authenticated summary evidence.
- The recovery self-test reuses successful upstream work, repairs the failed downstream task, and restores deliberately corrupted published evidence.
- Hawkeye installation uses the exact v6.5.1 archive and SHA-256 for each supported platform, rejects symlinked cache inputs, and succeeds from a verified cache without a network installer pipe.
- Retained candidate policy tests cover valid signed release preparation, dependency-pin and coverage-repair commits, unsigned candidates, and signed but unrelated candidates.
- Actionlint, Nextflow lint/plan/preflight, focused policy tests, shell validation, Markdown lint, and `git diff --check` pass.

## Remaining migration boundary

This issue removes the measured hosted-gate waste and makes that lane deterministic and recoverable. The exclusive live-runtime, Docker parity, package, demonstration, and publication processes retain their existing authorities until their outputs can be represented as immutable artifacts with equivalent recovery proof. They must not be described as migrated merely because the hosted sibling graph is green.
