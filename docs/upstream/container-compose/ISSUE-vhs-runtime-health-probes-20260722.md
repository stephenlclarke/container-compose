# Current VHS recording must probe service health inside the matched runtime

<!-- markdownlint-disable MD013 -->

## Problem

The Current package workflow run
[29887519238](https://github.com/stephenlclarke/container-compose/actions/runs/29887519238)
successfully typed the direct Container lifecycle and started the portable nginx and Alertmanager slice. Its first external host-port health command then received repeated `curl: (56) Recv failure: Connection reset by peer` responses from `127.0.0.1:8080` and timed out waiting for `ok`.

This is not a VHS transport failure: commands had already been typed, real service output was visible, and fail-closed behavior correctly rejected the recording. Retrying the complete session would conceal a live runtime assertion failure and is intentionally forbidden.

## Required behavior

- Continue to type and display real service-readiness commands in the VHS session.
- Query nginx `/healthz` and Alertmanager readiness from their running service containers, avoiding the host-port forwarding path that reset on the physical runner.
- Preserve the existing output contracts (`ok` and `OK`), the two-cycle named-volume demonstration, and fail-closed recording policy.
- Reject a future reintroduction of the host `curl` probe in release policy tests.

## Scope and ownership

This is a Compose release-demo adjustment. It uses the existing macOS Apple Container service-exec primitive and changes neither Apple Container nor Containerization source. It is macOS-specific validation work with no Windows implementation.

## Commit tracking

- Failed live recording: [29887519238](https://github.com/stephenlclarke/container-compose/actions/runs/29887519238).
- Signed Compose-layer implementation:
  `a127a397331f5a11bd97648296d6bb1891d52539`
  (`fix(release): probe demo services in runtime`).

## Validation

```sh
vhs validate docs/container-compose-demo.tape
python3 -m unittest discover Tools/release
```

The MBP also ran the matched runtime and the two portable services with the exact
commands used by the tape. Nginx printed `ok`; Alertmanager printed `OK`; and
the isolated runtime stopped cleanly with `HEALTH_PROBE_EXIT=0`.
