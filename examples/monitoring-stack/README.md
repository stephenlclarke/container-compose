# Container Compose monitoring demo

This is a self-contained monitoring example for the Apple container runtime. It starts Nginx, Grafana, Prometheus, Alertmanager, Pushgateway, Loki, Tempo, and cAdvisor. Grafana is provisioned with one small dashboard; no credentials, production targets, or external dashboard bundle are included.

## Run

Start the matching `container` and `container-compose` lane, then run:

```sh
cd examples/monitoring-stack
container compose up -d --wait
container compose ps
```

The demo keeps data inside its containers so a clean `down` and subsequent `up` starts afresh. Services reach each other through Docker-compatible `host-gateway` entries; no manual host-file or DNS setup is required.

Set non-default Grafana credentials before the first start if required:

```sh
export GRAFANA_ADMIN_USER=admin
export GRAFANA_ADMIN_PASSWORD='choose-a-local-password'
container compose up -d --wait
```

## Access

Nginx exposes the friendly entry points at <http://localhost:8080>:

| Service | URL |
| --- | --- |
| Grafana | <http://localhost:8080/grafana/> |
| Prometheus | <http://localhost:8080/prometheus/> |
| Alertmanager | <http://localhost:8080/alertmanager/> |
| Pushgateway | <http://localhost:8080/pushgateway/> |
| cAdvisor | <http://localhost:8080/cadvisor/> |

The direct endpoints are also useful for scripts: Grafana <http://localhost:3000/grafana/> (redirects to Nginx), Prometheus <http://localhost:9090/prometheus/>, Alertmanager <http://localhost:9093/alertmanager/>, Pushgateway <http://localhost:9091>, cAdvisor <http://localhost:9105>, Loki <http://localhost:3100>, Tempo <http://localhost:3200>, and OTLP `4317` (gRPC) / `4318` (HTTP).

The default Grafana login is `admin` / `admin` unless the environment variables above are set. The supplied dashboard shows scrape target availability and scrape duration.

## cAdvisor and the Linux-host profile

The default cAdvisor service reports the Linux guest in which it runs. It cannot inspect macOS or enumerate Apple-container workloads through Docker's socket, because no Docker daemon or Linux host cgroup tree is exposed across that VM boundary.

The original Linux-host collectors remain available only on a Linux Docker host:

```sh
container compose --profile linux-host up -d
```

That profile deliberately mounts Linux host paths such as `/sys` and `/var/run/docker.sock`; do not enable it on macOS.

## Stop and reset

```sh
container compose down
# Also remove positions retained by the optional Linux-host profile:
container compose down --volumes --remove-orphans
```
