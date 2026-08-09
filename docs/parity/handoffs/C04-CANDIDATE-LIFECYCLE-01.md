# C04-CANDIDATE-LIFECYCLE-01 Handoff

## State

`Verified`. The exact Container Compose candidate passes every declared C04
lifecycle observation. The functional blocker is closed; the retained duration
is not comparable-or-better performance evidence.

## User-visible contract

Against the valid Docker C04 oracle, the Container Compose provider must run
the Dev Containers Compose lifecycle fixture and observe the selected primary
service and label, forced recreation, `term` termination, restart, shutdown,
and cleanup.

## Pinned reference and candidate

The Docker reference passed on this MBP in 4.337 seconds using
`@devcontainers/cli@0.88.0` at
`f683c29f64a20109b4453e5149807e390ff65133`, Docker Engine `29.2.1` (API
`1.53`), and Docker Compose `5.3.1`.

The fresh candidate used Dev Containers `df495818fe4d58c72878022355131022ac3ad43f`,
Container Compose `ff5d74d8c0eaef7c043d5046c4bf397899397153`, Container
`c7924e375d98d82af37902f4a0c310ee389eab97`, Containerization
`7f62f5b940630811573a34f70cdd6f3fa11d014d`, and Engine API
`5e6e24d017691596783515285e1ff56d29701235`. The guest/init archive is
`vminit-7f62f5b9-c7924e37-skopeo.oci.tar`; the marker-protected runtime root is
`/Volumes/ContainerDevRuntime/cfs01-a`.

## Focused proof

The candidate completed in 18.595 seconds with no semantic or cleanup
differences. Its observations were:

```json
{
  "primary": "app",
  "primary_label": "true",
  "recreated": "true",
  "restart_signal": "term",
  "restarted": "true",
  "shutdown": "true"
}
```

The exact fingerprint, raw commands, result, and cleanup record are retained at
`/Volumes/SSD/github/evidence/container-family-stable-01/devcontainer-c04-d57c2b6-ff5d74d8-v5/`.
Dev Containers' 76 parity-runner regressions and seven focused Apple runtime
tests also pass.

The candidate run exposed two harness/runtime-routing gaps before the proof:
isolated `CONTAINER_APP_ROOT` and `CONTAINER_SERVICE_NAMESPACE` values were
filtered from child processes, and the official CLI preferred the installed
`docker compose` plug-in over its standalone Compose fallback. Signed Dev
Containers commit `df495818fe4d58c72878022355131022ac3ad43f` preserves the
isolated runtime identity and routes the official CLI's `compose` subcommand
through the selected candidate wrapper. Neither correction changes the C04
fixture or its expected observations.

## Completion and remaining work

The functional completion criteria are met and
[container-compose issue #184](https://github.com/stephenlclarke/container-compose/issues/184)
can close with this exact evidence. The 18.595-second candidate remains 4.29x
the 4.337-second Docker reference, so this certificate must not be used as a
comparable-or-better performance claim. Release performance remains a separate
programme gate.

## Safe handoff

Preserve the exact evidence directory and the immutable commits above. Any
rerun must use a fresh marker-protected evidence directory, explicitly selected
candidate binaries, and the same provenance checks; do not overwrite this
certificate.
