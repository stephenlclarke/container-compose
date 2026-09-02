# Issue 423: preflight the login Keychain for unattended Container validation

## Problem

The 0.13.1 stable release gate runs Container validation with an isolated non-interactive `HOME`. Seven `LoggingHandoffControlResponderTests` failed with Security framework status `-25308` because Security Framework could not resolve the operator's login Keychain from that home. An unattended gate must neither display nor wait for a GUI approval dialog.

A disposable Keychain was tested and rejected. These legacy generic-password queries do not select an explicit Keychain, and changing the `security` command's default inside a separate process does not change Security Framework's default in the test process. The exact seven-test suite instead passed when only its `HOME` pointed to the actual operator home; those stores already disable authentication UI before reading.

Tracking issue: [`#423`](https://github.com/stephenlclarke/container-compose/issues/423).

## Required outcome

- Derive the canonical operator home from the local account database rather than trusting inherited environment state.
- Preflight the exact login Keychain with a closed input stream and a five-second deadline before any release build starts.
- Fail fast when the login Keychain is absent, indirect, locked, or inaccessible.
- Expose the operator home only to the Container unit-coverage invocation; keep source reconstruction, formatting, builds, signing, and every other stage on their isolated homes.
- Authenticate `/usr/bin/security` in the host tool manifest when and only when the selected graph includes Container release validation.
- Preserve real Keychain-backed coverage rather than skipping or mocking the affected tests.
- Never mutate the user's default Keychain, search list, keys, or Keychain settings.

## Acceptance evidence

- An unlocked-versus-locked disposable probe proves `security show-keychain-info` exits `0` for the unlocked case and nonzero for the locked case without user interaction.
- The seven previously failing logging-handoff tests pass with the exact clean release environment and the operator home supplied only to the test invocation.
- Focused pipeline-policy tests prove tool authentication, preflight ordering, fail-fast behavior, isolation, and exact stage scoping.
- The retained 0.13.1 stable gate resumes and passes Container validation.

## Scope

This changes release orchestration only. Product runtime behavior and persistent credential state are unchanged. The trusted, immutable Container test bundle can read its normal login-Keychain namespace during unit coverage, but authentication UI remains disabled and the preflight prevents a locked Keychain from becoming an interactive wait.
