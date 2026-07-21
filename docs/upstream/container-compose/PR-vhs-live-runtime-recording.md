# Pull Request

## Summary

- Generate the Current GIF by visibly typing the complete lifecycle into VHS against the matched packaged runtime on the physical Apple-silicon release runner.
- Prove that `down --remove-orphans` retains the portable `monitoring-stack_nginx_cache`: write `container-compose-volume-reuse-ok` into the volume, show the retained asset's Compose labels and identity as JSON, then show a second successful `up`, stats, `ps`, both readiness checks, and a read of that same marker before final volume removal.
- Bind every Compose invocation to the isolated runtime with `CONTAINER_COMPOSE_CONTAINER`, removing a false compatibility failure caused by a different host installation.
- Make the direct VHS session the fail-closed verification: each typed command must produce its expected live output before recording can continue.
- Restore the Source Checks gate by recognizing Container's immutable named SwiftPM
  revision without permitting runtime-computed dependency requirements.
- Make the direct tape reliable for a cold release runner without hiding work:
  each unchanged `up --wait && ps` command has a bounded fifteen-minute wait and
  advances only after its real Alertmanager `running` row appears.
- Give the unchanged typed `container system start && container system status`
  command the same bounded fifteen-minute screen wait for a first-run Apple kernel
  download, and continue only after its real `status running` output appears.
- Route Current packaging to this MBP's dedicated
  `container-compose-current` capability label, excluding an online runner that
  cannot download pinned actions over TLS without weakening action pinning.

## Type of Change

- [x] Release workflow and documentation correction
- [x] Runtime monitoring demonstration validation
- [x] Docker Compose v2 integration confirmation
- [ ] Apple Container API change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

No forked Apple source changes are required. The change uses existing runtime behaviour through a minimal Compose-owned verifier and an environment override that the Compose plugin already exposes for isolated-runtime testing. It neither changes an Apple API nor introduces a Container-specific presentation path outside `container-compose`.

## Commit Tracking

- `fix(release): harden current demo recording`
- `fix(release): prove monitoring demo volume reuse`
- `fix(release): show retained-volume reuse in VHS replay`
- `fix(release): make volume reuse visible in demo` (`ac95e92b71270b37b2a3298bba86f50f16780a70`)
- [`62908819`](https://github.com/stephenlclarke/container-compose/commit/62908819034156bfc8d24cac7becce9a203d720b) `fix(release): record live VHS commands`
- [`518ae228`](https://github.com/stephenlclarke/container-compose/commit/518ae228f650a8fa40118c36d68fdad650eb69ef) `fix(release): record direct terminal demo`
- [`af6da141`](https://github.com/stephenlclarke/container-compose/commit/af6da14150d62f09fdadf6cf12d6aab6cde6b144) `fix(ci): validate named dependency revisions`
- [`0ed7efab`](https://github.com/stephenlclarke/container-compose/commit/0ed7efab0f85ced3c3e926ecd82c2cbccbc5ed57) `fix(release): wait for cold monitoring stack`
- [`2d8748c3`](https://github.com/stephenlclarke/container-compose/commit/2d8748c3) `fix(release): wait for cold kernel bootstrap`
- [`0c2c330f`](https://github.com/stephenlclarke/container-compose/commit/0c2c330f) `fix(release): dedicate current build runner`

## Code Map

- `.github/workflows/prebuilt-binaries.yml`: selects the self-hosted Apple-silicon runner, exports the isolated package environment, validates the VHS source, and requires a non-empty GIF. It does not pre-start the runtime or create a transcript.
- `.github/actionlint.yaml`: declares `container-compose-current` as an approved
  self-hosted label, keeping the MBP-only Current route under workflow linting.
- `docs/container-compose-demo.tape`: types the real `container system start`, every `container compose` and `curl` command, the final `container system stop`, and their live output. The tape has no replay function, marker function, or transcript input.
- `docs/container-compose-demo.tape`: waits up to fifteen minutes for the real
  `status running` output from its first typed system-start command, accommodating
  a cold, isolated Apple kernel download without pre-starting or hiding it.
- `Tools/ci/check-stack-consistency.py`: resolves a named dependency revision only from a
  manifest string literal, then checks it against the stack manifest and SwiftPM lockfile;
  focused unit coverage includes accepted literal and rejected dynamic forms.
- `docs/container-compose-demo.tape`: uses the real `ps` row for
  `monitoring-stack` Alertmanager in `running` state as the completion evidence
  for each unchanged live `up --wait && ps` command. It has no sentinel or
  synthetic result command.
- `examples/monitoring-stack/docker-compose.yaml`: declares the portable `nginx_cache` named volume used to prove resource retention.
- `README.md` and `BUILD.md`: document the direct live-command recording contract and runner requirement.

## Validation

```console
python3 -m unittest Tools.release.test_container_stack_release
python3 -m unittest Tools.ci.test_check_stack_consistency
CONTAINER_STACK_REPO=/path/to/container make stack-consistency
CONTAINER_COMPOSE_DEMO_ROOT="$PWD" vhs validate docs/container-compose-demo.tape
python3 - <<'PY'
from pathlib import Path
tape = Path("docs/container-compose-demo.tape").read_text(encoding="utf-8")
assert tape.count("--wait-timeout 900") == 2
assert tape.count("Wait+Screen@900s /monitoring-stack-.*alertmanager.*running/") == 2
assert tape.count("Wait+Screen@900s /status +running/") == 1
PY
docker compose -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 300
docker compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx sh -c 'printf "%s\\n" container-compose-volume-reuse-ok > /var/cache/nginx/.container-compose-volume-reuse'
docker compose -f examples/monitoring-stack/docker-compose.yaml down --remove-orphans
docker volume inspect monitoring-stack_nginx_cache
docker compose -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 300
docker compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream
docker compose -f examples/monitoring-stack/docker-compose.yaml ps
curl -4fsS http://127.0.0.1:8080/healthz
curl -4fsS http://127.0.0.1:9093/alertmanager/-/ready
docker compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx cat /var/cache/nginx/.container-compose-volume-reuse
docker compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans
python3 -m unittest discover Tools/release
```

## Compatibility and Risks

- The runtime path and named-volume lifecycle are macOS-supported and use only portable services. Linux-host-only monitoring profiles remain excluded.
- The GIF starts Linux guests inside VHS and visibly types each command. A command failure or missing expected output blocks publication, so the recording cannot become a transcript substitute.
- A physical, labelled release runner must remain online. If it is unavailable, the package job queues instead of publishing a deceptive Current recording.
- Manifest parsing accepts only checked-in string literals. A dynamic source of truth such as
  an environment variable fails the gate rather than allowing a runtime-specific stack pin.
- A cold physical runner may need to fetch every service image. The taped commands remain
  live and bounded; the recording advances only when `ps` shows its actual running service
  row, not when a generic progress line or synthetic marker appears.
- A fresh isolated runtime may also need to fetch the Apple kernel before its first
  status result. That direct command remains visible and bounded at fifteen minutes;
  progress output cannot satisfy the `status running` gate.
- The mutable Current recording requires the dedicated runner label in addition to
  the general release label. The label is assigned only after a runner has proved
  it can fetch the pinned GitHub action archive over TLS; this avoids changing the
  action pin or silently falling back to a transcript.
- Local validation passed VHS source validation and all 65 release tests; the runner executes the real guest lifecycle when creating the published GIF.

## container-compose Checks

- [x] Docker-specific recording policy stays in Compose release automation.
- [x] No Apple runtime fork change is required for this slice.
- [x] The first start is clean, while the second start follows a demonstrably retained-volume shutdown, exposes the retained volume identity in JSON, and reads the first cycle's marker.
- [x] A failing typed command or missing expected output prevents GIF publication.
- [x] Current workflow, tape, example, tests, README, BUILD guide, and handoff records describe the same contract.
