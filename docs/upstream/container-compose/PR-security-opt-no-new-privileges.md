# Pull request: map Compose no-new-privileges security option

## Summary

- Accept Compose `security_opt` values `no-new-privileges:true` and
  `no-new-privileges:false`, plus their equals-sign spellings.
- Validate unsupported security options before Compose creates resources.
- Reuse generic `container --security-opt` rendering for both managed service
  containers and one-off `compose run` containers.
- Add normalizer, orchestrator, and Docker Compose V2 config/dry-run parity
  coverage.
- Update `STATUS.md` to distinguish the supported narrow option from remaining
  security isolation gaps.

## Apple-shaped implementation boundary

The fork delta is a narrow, generic CLI-to-process-config bridge; it makes no
reference to Compose and has no macOS-host security side effects. The setting
is consumed by the Linux guest process configuration.

| Repository | Commit and responsibility |
| --- | --- |
| `stephenlclarke/containerization` | No source change. The existing Linux process configuration provides `noNewPrivileges`. |
| `stephenlclarke/container` | `22a65657d411a7103b438bd552f091805246d909`: parse the generic `--security-opt` option, persist it, and project it to the Linux runtime process configuration. |
| `stephenlclarke/container-compose` | `99225d76440fa1852facbf7895cb0900498069d0`: validate Compose values and render the generic runtime option in `up` and `run`. |

The `container` commit must be rebased or replayed onto current upstream before
submission because its local branch is behind `fork/main`. Keep the resulting
PR restricted to the generic option, model persistence, parser coverage, and
runtime configuration projection; do not add a Compose-aware API to either
fork.

## Implementation details

- `ComposeOrchestratorRuntimeSupport.swift` accepts only the generic option
  forms the runtime can enforce.
- `ComposeOrchestratorValidation.swift` invokes that validation before side
  effects.
- `ComposeOrchestratorRunCopyStart.swift` emits repeatable
  `--security-opt VALUE` arguments through the existing command path.
- The Compose normalizer test confirms compose-go retains the entry in the
  typed normalized service model.
- `Tools/parity/check-compose-security-opt.sh` compares Docker Compose V2
  configuration output, then asserts the local Compose dry-run command vector.

## Docker Compose V2 parity contract

For this fixture:

```yaml
services:
  api:
    image: alpine:3.20
    security_opt:
      - no-new-privileges:true
```

- Docker Compose V2 `config --format json` preserves
  `security_opt: ["no-new-privileges:true"]`.
- `container-compose config --format json` preserves the normalized
  `securityOpt` list.
- `container-compose --dry-run up --no-start api` renders the generic
  `--security-opt no-new-privileges:true` argument.
- When Docker Engine is available, the script also verifies that Docker Compose
  accepts the fixture in `--dry-run up`. The config and local command-vector
  checks remain deterministic on Macs without Docker Desktop or Colima.

## Validation

Completed locally for this slice:

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter \
  'normalizesComposeFileThroughComposeGo|upMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|runMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|RejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources'
bash -n Tools/parity/check-compose-security-opt.sh
DOCKER_COMPOSE=.build/docker-reference-test/docker-compose \
  CONTAINER_COMPOSE=.build/debug/compose \
  Tools/parity/check-compose-security-opt.sh --strict
make lint
make coverage-check
git diff --check
```

The coverage gate passed 1,036 Swift tests with 91.35% Swift coverage and
85.50% Go coverage. Docker Engine dry-run confirmation was not available on
the local host, but Docker Compose V2 config parity and the local Compose
dry-run assertion both passed.

## Review checklist

- [ ] The `container` change remains generic and Compose-agnostic.
- [ ] The fork commit is rebased onto the current upstream base before opening
  the Apple handoff PR.
- [ ] The Compose integration uses only the documented generic option.
- [ ] Unsupported SELinux, AppArmor, seccomp, and profile options remain
  explicit failures rather than accepted no-ops.
- [ ] The Docker Compose V2 fixture and unit coverage pass on the final stack.

## Non-goals

- Linux host namespace, seccomp, SELinux, and AppArmor emulation on macOS.
- Windows isolation and credential-spec support.
- Docker-complete privileged mode, device exposure, or security-profile
  behavior beyond the guest Linux no-new-privileges primitive.
