# Pull request: accept unconfined AppArmor at the Compose boundary

## Summary

Adds Docker Compose V2-compatible handling for
`security_opt: apparmor=unconfined` and `security_opt: apparmor:unconfined`. It is an intentional Compose-layer no-op:
the matched macOS Linux guest has no usable workload AppArmor confinement
interface, so forwarding the Docker-shaped value would not change enforcement.

## Constructible commit

- `ee216c3beebeeb6b0ecc7df959a3fa8b2d5d4600`
  `feat(security): accept unconfined apparmor option`
- `62a6d20e153ea2a4f4bee6e864771a15245d3ed7`
  `feat(security): accept portable no-op option forms`

## Apple-shaped boundary

No Apple fork change is required. The Compose layer owns the Docker Compose
spelling and its precise compatibility decision. `container` and
`containerization` retain their generic APIs and make no Compose-aware or
Docker-profile-specific change.

## Implementation

- The security-option adapter recognizes both AppArmor and seccomp unconfined
  spellings alongside the existing compatibility path.
- Both values remain in normalized config but are omitted from the generic
  runtime command; no-new-privileges remains a real forwarded primitive.
- Unit tests cover `up`, `run`, combined options, normalization, and
  pre-side-effect rejection.
- The Docker Compose V2 parity fixture retains all three supported security
  options and checks that only no-new-privileges reaches the dry-run command.
- `STATUS.md` distinguishes unconfined baseline values from profile support.

## Verification

```sh
go -C Tools/compose-normalizer test ./...
swift test --filter 'ComposeNormalizerTests/normalizesComposeFileThroughComposeGo'
swift test --filter 'ComposeOrchestratorTests/(upConsumesUnconfinedSecurityProfileOptions|runConsumesUnconfinedSecurityProfileOptions|upMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|runMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources|runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources)'
make docker-compose-security-opt-parity DOCKER_COMPOSE_REFERENCE=docker-compose
make coverage-check
make check
git diff --check
```

The unit, normalizer, Docker Compose V2 5.3.1 config-parity, and check-suite
steps passed locally. Docker Engine was unavailable, so the optional
Engine-backed dry-run assertion was skipped. A matched-stack guest probe
returned `EINVAL` for `/proc/self/attr/current`, confirming that the workload
has no AppArmor profile interface to relax.

## Compatibility and non-goals

Both Compose-documented `apparmor=unconfined` and `apparmor:unconfined`
spellings are accepted. Named/default AppArmor policies, seccomp profiles,
SELinux labels, and arbitrary
security-option values remain explicit errors before resources are created.
This does not claim macOS host confinement, Docker's default profile, or
Windows security-option support.
