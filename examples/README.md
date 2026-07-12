# Examples

This directory contains small Compose files that can be run through the `container compose` plugin while developing against a local `container` checkout.

Run commands from the repository root so the relative build context in `examples/compose.yml` resolves correctly.

## Alpine Shell

The default example builds a tiny Alpine image from [Dockerfile](Dockerfile) and runs a one-off shell service from [compose.yml](compose.yml).

Use a non-interactive command for a quick smoke test:

```sh
../container/bin/container compose -f examples/compose.yml run --rm --no-tty shell uname -a
```

Use an interactive shell when testing terminal behavior:

```sh
../container/bin/container compose -f examples/compose.yml run --rm shell
```

The first run may pull and build the Alpine image. A local debug build of `container` or `container-compose` also prints the debug-build warning; release Homebrew builds should not.

Example first-run output:

```text
> ../container/bin/container compose -f examples/compose.yml run --rm --no-tty shell uname -a
Warning! Running debug build. Performance may be degraded.
container-compose-alpine-shell:local
Warning! Running debug build. Performance may be degraded.
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile:
#2 transferring dockerfile: 0.0s
#2 transferring dockerfile: 2B 0.0s done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context:
#3 transferring context: 0.1s
#3 transferring context: 2B 0.1s done
#3 DONE 0.1s

#4 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc done
#4 CACHED

#5 exporting to oci image format
#5 exporting layers done
#5 exporting manifest sha256:1154ab9553905eca1e3dc12234c6fa0b3549ad871e557fc19a858dd320517f66 done
#5 exporting config sha256:6743291a0e8d20b5f68d492f3a794543b5f84deb4f43508d8664f251628da692 done
#5 exporting manifest list sha256:19565c73a231432689818da671c99e681e434db9dbbdb63d2820e66109ea8ff1 done
#5 sending tarball 0.0s done
#5 DONE 0.0s
Warning! Running debug build. Performance may be degraded.
Linux examples-shell-run-0254e20997e9 6.18.15 #1 SMP Tue Mar 17 01:36:53 UTC 2026 aarch64 Linux
```

Remove any project resources left behind during manual experiments with:

```sh
../container/bin/container compose -f examples/compose.yml down
```

## Monitoring Stack

[monitoring-stack/docker-compose.yaml](monitoring-stack/docker-compose.yaml) captures a larger Grafana/Prometheus/Loki/Tempo monitoring stack used as a compatibility example for real-world service options. It uses relative nginx example paths, `MONITORING_HOST` / `MONITORING_HOSTNAME` defaults for site-specific URLs, and Grafana `admin` / `admin` defaults for local demos. It still intentionally includes host-observability bind mounts such as Docker, journal, rootfs, `/proc`, and `/sys`; copy or adapt those paths before running it directly.
