# Pull Request

## Summary

- Generate the Current GIF from a complete, fresh lifecycle transcript produced by the matched packaged runtime on the physical Apple-silicon release runner.
- Prove that `down --remove-orphans` retains the portable `monitoring-stack_nginx_cache`, then show a second successful `up`, stats, `ps`, and both readiness checks before final volume removal.
- Bind every Compose invocation to the isolated runtime with `CONTAINER_COMPOSE_CONTAINER`, removing a false compatibility failure caused by a different host installation.

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

## Code Map

- `Tools/release/record_monitoring_stack_transcript.py`: invokes the exact packaged `container` binary, exports it to Compose's compatibility check, resets only the monitoring project before the first start, captures thirteen marked logs, and cleans up on error.
- `Tools/release/test_record_monitoring_stack_transcript.py`: covers the complete successful sequence, failure capture/cleanup, absent `curl`, and isolated-runtime environment propagation.
- `.github/workflows/prebuilt-binaries.yml`: selects the self-hosted Apple-silicon runner, starts the disposable matched runtime, rejects missing transcript logs, validates the VHS source, and requires a non-empty GIF.
- `docs/container-compose-demo.tape`: displays the verified first start, retained volume listing, second start, health checks, and final empty project table at a deliberately readable pace.
- `examples/monitoring-stack/docker-compose.yaml`: declares the portable `nginx_cache` named volume used to prove resource retention.
- `README.md` and `BUILD.md`: document the fail-closed verified-transcript contract and runner requirement.

## Validation

```console
python3 -m unittest Tools.release.test_record_monitoring_stack_transcript Tools.release.test_container_stack_release
CONTAINER_COMPOSE_DEMO_ROOT="$PWD" \
  CONTAINER_COMPOSE_DEMO_TRANSCRIPT=/path/to/fresh/transcript \
  vhs validate docs/container-compose-demo.tape
python3 Tools/release/record_monitoring_stack_transcript.py \
  --container /path/to/matched/bin/container \
  --compose-file examples/monitoring-stack/docker-compose.yaml \
  --working-directory "$PWD" \
  --output-directory /path/to/fresh/transcript
docker compose -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 300
docker compose -f examples/monitoring-stack/docker-compose.yaml down --remove-orphans
docker volume inspect monitoring-stack_nginx_cache
docker compose -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 300
docker compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream
docker compose -f examples/monitoring-stack/docker-compose.yaml ps
curl -4fsS http://127.0.0.1:8080/healthz
curl -4fsS http://127.0.0.1:9093/alertmanager/-/ready
docker compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans
python3 -m unittest discover Tools/release
```

## Compatibility and Risks

- The runtime path and named-volume lifecycle are macOS-supported and use only portable services. Linux-host-only monitoring profiles remain excluded.
- The GIF intentionally replays freshly captured command/output logs rather than starting Linux guests inside VHS. The workflow fails before rendering if any real lifecycle command fails, so replay cannot hide a guest error.
- A physical, labelled release runner must remain online. If it is unavailable, the package job queues instead of publishing a deceptive Current recording.

## container-compose Checks

- [x] Docker-specific recording policy stays in Compose release automation.
- [x] No Apple runtime fork change is required for this slice.
- [x] The first start is clean, while the second start follows a demonstrably retained-volume shutdown.
- [x] A failing command or missing transcript prevents GIF publication.
- [x] Current workflow, tape, example, tests, README, BUILD guide, and handoff records describe the same contract.
