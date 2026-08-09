# [Bug]: Keep public main independent of unpublished Container revisions

## Steps to reproduce

1. Push a Compose revision whose `Package.swift`, `Package.resolved`, or release stack metadata names an Apple-shaped Container commit that exists only on the programme MacBook Pro.
2. Start the hosted `CI` workflow.
3. Observe SwiftPM dependency resolution fail because GitHub cannot fetch the unpublished commit from `stephenlclarke/container`.

The regression was recorded by [issue #191](https://github.com/stephenlclarke/container-compose/issues/191) and [CI run 30824674891](https://github.com/stephenlclarke/container-compose/actions/runs/30824674891).

## Problem description

Signed Compose checkpoint `d6361aab21f61c5771eaefef0c5d436ddf3b925b` consumed signed Container logging implementation `2a79b4553a342e33411666a88ad20ccd2ce46551`. Container-family policy deliberately keeps that Apple-shaped dependency local until the full parity programme is ready for upstream publication. Publishing the Compose consumer first made public `main` impossible to build on GitHub-hosted runners.

Public `main` must instead use the latest published, remotely fetchable Container baseline while retaining the complete development implementation and evidence in signed history. It must not advertise a runtime capability the public dependency cannot satisfy.

## Environment

- **OS**: macOS 26.5.2 on the programme arm64 MacBook Pro
- **Container public baseline**: `6c3f7d3701cf9400855849fa0e29dd75d7b9c45d`
- **Container local logging checkpoint**: `2a79b4553a342e33411666a88ad20ccd2ce46551`
- **container-compose affected checkpoint**: `d6361aab21f61c5771eaefef0c5d436ddf3b925b`
- **Hosted runner**: GitHub Actions `macos-26`

## Acceptance criteria

- [x] Public package and stack references use published Container `6c3f7d3701cf9400855849fa0e29dd75d7b9c45d`.
- [x] The public required capability manifest omits `io.github.stephenlclarke.container.logging-drivers.v1`.
- [x] Current status and design documents distinguish the active public baseline from preserved signed development checkpoints.
- [x] The Docker logging oracle and implementation evidence remain in the repository.
- [x] The focused 14-test logging oracle suite passes against the repaired public tree.
- [x] Local source, lint, stack-consistency, documentation, handoff, progress, and licence gates pass.
- [x] Replacement GitHub CI, Quality, Documentation, and prebuilt-binary workflows complete successfully.
- [x] Issue #191 received the replacement evidence and closed on 3 August 2026.

## Closure evidence

- Signed public repair head `38e0a7ee3c88b9eb6137d4398d2322c93a77b05d` passed [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30827864185), [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30827866187), [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30827866062), and [prebuilt-binary](https://github.com/stephenlclarke/container-compose/actions/runs/30828989373) workflows.
- Current published baseline `1f0f944b3d918a39ad97d1f12bb7b7c5ef6146a0` also passed [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30840679404) and [prebuilt-binary](https://github.com/stephenlclarke/container-compose/actions/runs/30840739050) workflows.
- Complete logging execution was reactivated only on this MBP at signed local `main` commit `784aacaa26f2ad698460044a573adae30665628a`; it remains unpublished until the matched Container revision is remotely fetchable.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked existing issue records before preparing this request.
- [x] No secrets or private data are included.
