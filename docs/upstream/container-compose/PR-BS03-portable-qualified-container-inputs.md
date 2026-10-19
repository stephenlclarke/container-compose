# Pull request BS03: make qualified Container inputs portable

## Change

Require the Compose qualification CLI and Make entrypoints to receive the exact Container checkout and matching completed Q evidence explicitly. Resolve and validate both real non-symlink directories before normal, development, reference-capture or recovery dispatch. Keep the pinned source, clean-tree, helper-hash, Q acceptance, workspace-fingerprint, installed-binary, lease and receipt checks unchanged. Recovery first verifies the selected receipt hashes against the original preflight and snapshots the admitted runtime fingerprint before any lock or restoration action. It deliberately skips checking displaced installed-binary bytes during recovery.

Pass the selected Container root into fixture-cache legacy-format verification and derive the cache location from the exact Q and Containerization source pins. Existing cache receipts remain bound to their original source; a later pin advance uses a fresh cache directory and capture. The runtime fingerprint still binds the selected evidence to that checkout's exact path, so this change enables explicit path selection but does not implement checkout relocation or a versioned helper bundle. Historical Compose benchmark reference assets and raw samples remain untouched.

## Validation

- focused CLI tests for missing inputs, symlink rejection, resolved path selection, and recovery using the same explicit roots
- fixture-cache tests for immutable historical receipt provenance and explicit Container-root compatibility checks
- Python syntax, Makefile syntax, focused workflow tests, and diff hygiene
