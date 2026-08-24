# Issue 312: prevent repeated macOS privacy prompts during runtime validation

## Problem description

Unattended matched-stack validation could start rebuilt, ad-hoc-signed runtime
executables from removable or privacy-controlled paths and could consult the
login Keychain for public GHCR fixtures. macOS then displayed Local Network,
removable-volume, or credential approval dialogs that blocked the build until a
person noticed them.

The validation harness must prevent the interactive boundary instead of
automating, bypassing, or resetting macOS privacy controls.

## Resolution

The runtime build requires a Developer ID Application identity and the wrapper
rejects unsigned, ad-hoc, or non-Mach-O launchable packaged executables before
launch. Every complete source package is pinned under a persistent
internal-volume path, while marker-protected state originating on
privacy-controlled storage is relocated there. Public GHCR fixtures use the
existing anonymous-registry contract, so they do not consult saved credentials.

The staging root is a private, owner-validated, non-symbolic directory. An
indirect, unowned, or group/other-writable candidate is rejected before any
cleanup or launch operation.

## Focused evidence

- Four focused signing, staging, localization, and symlink-rejection tests pass
  at signed head `2763f1ccee9c2bd5d4a329543a2eb5a0764abf01`.
- The protected symlink target remains unchanged in the negative fixture.
- Bash syntax and `git diff --check` pass.
- The complete runtime-wrapper test file is the final pre-merge component gate.
- Thirteen focused exact-head tests prove inherited candidate aliases are replaced,
  the entire staged package is one generation, and exact or symlinked protected
  paths are localized. Signature inspection consumes the shared deadline, and
  interrupted replacement retains a marker that the next run can recover.
  Required packaged binaries reject non-Mach-O artifacts unless the explicit
  portable unit-fixture switch is active.
- Six focused latest-review tests prove automatic local-package pinning,
  launchable plugin rejection, managed nested-wrapper reuse without lock
  reacquisition, serialization, mixed-generation rejection, and interrupted
  replacement recovery.
- The focused privacy-path regression also proves differently cased canonical
  paths cannot bypass automatic localization on case-insensitive macOS filesystems.
- The local release gate supplies the source CLI through the environment, so
  the wrapper's staged alias wins before managed Make targets run.
- The wrapper gives the staged CLI final GNU Make command-line precedence, so
  inherited `MAKEFLAGS` cannot restore a mutable source path in recursive makes.
- Cleanup authorization precedes first staging-directory creation; an
  interrupted `mkdir` is removed after ownership and mode revalidation.
- Developer ID acceptance is anchored to an `Authority=` record, so package
  path text cannot spoof the signing identity.
- An unchanged, revalidated staged generation is reused while an orphaned
  process still runs from it; changed running generations remain protected.
- Incomplete packaged layouts fail closed before launch instead of falling
  back to standalone-CLI handling.
- Runtime-root marker type checks and reads share the complete startup
  deadline, so stalled filesystems cannot leave the wrapper waiting after the
  host runtime lock is held.

## Scope

This changes the local validation harness and documented build prerequisites.
It does not change Compose service semantics, grant new privacy permissions, or
make an authenticated registry anonymous.

Refs [#312](https://github.com/stephenlclarke/container-compose/issues/312).
