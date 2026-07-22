# Pull Request: probe Current demo health inside the matched runtime

<!-- markdownlint-disable MD013 -->

## Summary

- Replace the Current tape's two host-port `curl` readiness probes with typed `container compose exec` commands.
- Keep nginx `/healthz` and Alertmanager readiness visible as their services' real `wget` output.
- Add release-policy coverage that requires the two internal probes and forbids the fragile host `curl` form.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The physical release runner completed all preceding typed commands, but the host forwarding proxy reset connections to nginx. That left the service itself healthy while the external host probe could not prove it. The repair queries the two services from inside their already-running containers using the existing Compose exec path. The result is still direct, typed, and fail-closed: a failed `wget` or missing output stops VHS without retries.

## Commit Tracking

- Failing Current package run: [29887519238](https://github.com/stephenlclarke/container-compose/actions/runs/29887519238).
- Code and regression test:
  `a127a397331f5a11bd97648296d6bb1891d52539`
  (`fix(release): probe demo services in runtime`).

## Implementation Details

- Each nginx health check now types `container compose exec --no-tty nginx wget -qO- http://127.0.0.1/healthz`.
- Each Alertmanager check now types the analogous `exec --no-tty alertmanager wget` readiness command.
- `Wait+Screen` still requires the real `ok` and `OK` output in both lifecycle passes.
- The README describes the internal service probes, and policy tests assert their two occurrences while rejecting `curl -4fsS`.

## Docker Compose Compatibility Notes

No Compose-file, model, or runtime semantics change. The tape continues to exercise Compose v2-compatible service startup, process execution, health output, stats, retained-volume reuse, and final teardown on macOS. Only the presentation-layer probe endpoint changed from a host-port proxy to the direct service namespace.

## Testing

- [x] Tested locally on the MBP
- [x] Added/updated regression coverage
- [x] Added/updated documentation

```sh
vhs validate docs/container-compose-demo.tape
python3 -m unittest discover Tools/release
git diff --check
```

Results: VHS validation passed and 143 release tests passed. A live matched-runtime probe started nginx and Alertmanager, emitted `ok` and `OK` through the exact typed `container compose exec` commands, cleaned up the isolated runtime, and recorded `HEALTH_PROBE_EXIT=0`. Full hosted Current-release verification is required after merge because it is the only environment that generates the published GIF.

## container-compose Checks

- [x] Updated `docs/upstream/` with issue and pull-request handoff documents.
- [x] Focused on one release recording fault.
- [x] Attached local runtime and test evidence.
- [x] Used a signed Conventional Commit.
- [x] `Release-Note: none` — the recording reliability fix does not change user-facing Compose semantics.
- [x] Included the failed upstream workflow reference.
- [x] Signed the code commit with the configured GitHub-supported signing key.
- [x] No credentials, tokens, private keys, personal data, or registry details were introduced.

## Review Checklist

- [x] The tape still types commands and retains their live output.
- [x] The probe remains fail-closed and does not retry typed-command failures.
- [x] No transcript, replay, marker helper, or Apple runtime patch was added.
- [x] The Current release workflow must pass before Phase 3 begins.
