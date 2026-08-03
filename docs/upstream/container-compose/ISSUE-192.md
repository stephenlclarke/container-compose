# [Bug]: Strict Swift build rejects deprecated compatibility tests

## Steps to reproduce

1. Reactivate the typed logging runtime path on the matched local Container stack.
2. Build every test target with `swift build --disable-automatic-resolution --build-tests -Xswiftc -warnings-as-errors`.
3. Observe compatibility tests intentionally calling deprecated `ComposeLogConfiguration.default`, legacy initializers, properties, or archive request forwarding shims.
4. Observe the warnings-as-errors gate reject those test-only calls even though the deprecated surface must remain covered.

The bug was tracked in [issue #192](https://github.com/stephenlclarke/container-compose/issues/192).

## Problem description

Compatibility shims must stay deprecated and tested, but an ordinary new logging request test should not call a deprecated spelling. Tests that deliberately prove legacy forwarding need an explicit deprecated test context so the compiler can distinguish intentional compatibility coverage from accidental new usage. Weakening the production deprecations or the warnings-as-errors gate would hide regressions.

## Environment

- **OS**: macOS 26.5.2 on the programme arm64 MacBook Pro
- **Swift package**: local signed Compose `main` checkpoint `784aacaa26f2ad698460044a573adae30665628a`
- **Matched Container implementation**: `6a668b2b5d42246efcad3316374f6d0e0d2eaf14`
- **Matched Containerization head**: `864455bf1a104f0215b7c912a45800b0a0538973`

## Acceptance criteria

- [x] Ordinary logging coverage uses `ComposeLogConfiguration.standard`.
- [x] Tests deliberately exercising legacy initializers, properties, and archive forwarding run inside explicit deprecated contexts.
- [x] Production deprecation annotations remain unchanged.
- [x] The warnings-as-errors build passes.
- [x] All 1,360 Swift tests in 57 suites pass against the matched local stack.
- [x] Go normalizer and repository policy gates pass.
- [x] The fix is signed in local commit `784aacaa26f2ad698460044a573adae30665628a`.
- [x] Issue #192 received exact evidence and closed on 4 August 2026.

## Publication disposition

The defect is fixed. The commit remains local because the same logging checkpoint consumes an unpublished Container revision that hosted CI cannot fetch. Public `main` remains at reproducible `1f0f944b3d918a39ad97d1f12bb7b7c5ef6146a0`; coordinated dependency publication is separate programme work.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked existing issue records before preparing this request.
- [x] No secrets or private data are included.
