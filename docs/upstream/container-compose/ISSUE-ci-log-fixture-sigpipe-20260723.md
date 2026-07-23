# Followed-log fixture can terminate coverage with SIGPIPE

## Context

The exact Phase 3 hosted coverage gate repeatedly terminated
`swiftpm-testing-helper` with signal 13 while running followed-log tests. Local
coverage passed on the same commit.

The rotating log test client uses `Pipe` to model the runtime follow stream.
Its detached writer can outlive a test that closes the read handle. On Darwin,
a later write to that descriptor delivers `SIGPIPE` to the whole test process
before Swift can report the write error.

## Reproduction

1. Create a rotating log fixture with a delayed chunk.
2. Request its followed-log reader.
3. Close the reader before the delayed writer runs.
4. Wait for the write.

Without descriptor protection, the test process exits with signal 13. The
hosted coverage run reproduced this on all three configured attempts.

## Expected behavior

Closing a test reader should make the fixture writer receive an ordinary
broken-pipe error. It must not terminate unrelated tests or invalidate
coverage data.

## Resolution

Set Darwin `F_SETNOSIGPIPE` on each fixture write descriptor before launching
its detached writer. Apply the same protection to raw and structured followed
log fixtures. Keep the production log adapter unchanged.

Add a regression that closes a reader before a delayed write and confirms the
test process remains alive.

## Acceptance criteria

- [x] Raw followed-log fixture writers suppress descriptor-local `SIGPIPE`.
- [x] Structured fixture writers use the same protection.
- [x] The closed-reader regression passes.
- [x] Local full coverage remains above both required thresholds.
- [ ] Hosted coverage, SonarQube, and Current packaging pass.
