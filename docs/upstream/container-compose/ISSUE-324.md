# Issue 324: unify unattended stable release authority

Issue [#324](https://github.com/stephenlclarke/container-compose/issues/324) tracks the remaining duplication and interactivity in the stable release transaction.

## Failure

The release controller is already resumable and verifies exact source, test, parity, signing, package, attestation, and Homebrew authorities. Its scheduled entry point, however, only exports milestone intent and does not provision the Developer ID identity required by the local release gate. A maintenance or security release therefore still starts from an interactive terminal, and a scheduled run can reach the Mac without its required signing authority. The controller also reads the local GitHub CLI credential through the login Keychain. Either credential boundary can display or wait behind a macOS Keychain prompt after expensive validation has begun.

## Contract

- Use one unattended dispatch path for milestone, maintenance, security, automatic, patch, minor, major, and exact-version release requests.
- Validate and sanitize the request on a hosted runner before allocating the Apple-silicon release runner.
- Authenticate release mutations with a purpose-specific Actions secret, not the runner's login Keychain.
- Import the Developer ID certificate into an operation-scoped temporary keychain, verify its configured fingerprint and expiry, and complete a timestamped hardened-runtime signing probe before the release gate.
- Close standard input and apply finite process-group deadlines to every prompt-capable keychain/signing command.
- Restore the exact prior keychain search list and delete temporary credentials on success or failure.
- Retry transient GitHub release-draft creation failures with a finite bound,
  and reconcile an exact matching draft before retrying an ambiguous response.
- Before a stable publication retry, validate and stage the complete retained
  asset set before replacing working files so nondeterministic Developer ID
  signatures can never replace or conflict with the already authenticated
  release bytes.
- Preserve the existing exact-head Codex review, PR checks, checked-admin solo-maintainer handling, checkpoints, signed tags, hosted authority, immutable packages, attestations, and atomic Homebrew update.

## Evidence

Focused request-policy, temporary-keychain, release-draft retry,
runner-prerequisite, and workflow-contract tests cover all release intents,
exact versions, control-character rejection, missing secrets, identity mismatch,
cleanup, noninteractive signing, transient GitHub 500 responses, ambiguous
create responses, bounded retry exhaustion, complete retained-set restoration,
missing retained assets, and unsafe restoration destinations. The 0.15.1
transaction exposed both the release-create 500 after successful signing and
attestation and the resulting nondeterministic archive conflict on retry. Those
live failures provide the evidence for bounded reconciliation and exact-byte
restoration.
