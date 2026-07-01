# container-compose

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=bugs)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=coverage)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Duplicated Lines (%)](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=duplicated_lines_density)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose2&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2)
[![CodeQL](https://github.com/stephenlclarke/container-compose/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/stephenlclarke/container-compose/actions/workflows/codeql.yml?query=branch%3Amain)
![Repo Visitors](https://visitor-badge.laobi.icu/badge?page_id=stephenlclarke.container-compose)

`container-compose` is a standalone plugin that provides Docker Compose style
workflows for Apple's [`container`](https://github.com/apple/container) CLI
where the supported Compose surface maps to available runtime primitives.

The first implementation target is local-development Compose v2 compatibility
where [`container`](https://github.com/apple/container) has matching runtime
primitives. Compose file normalization uses `compose-go`, with Swift handling
runtime orchestration.

The CLI accepts the Docker Compose 5.2.0 command and option surface, including
help output. Help color-codes command, subcommand, and option support status:
green for supported, orange for partially supported, and red for not supported;
use `--ansi never` for plain output. Commands or option modes that do not yet
have backing `apple/container` functionality fail with an explicit
`unsupported compose feature` message.

The top-level help output is the quickest support overview. Run
`container compose COMMAND --help` for command-specific option support.

Current detailed gap examples:

- Supported `build` coverage includes Compose build args, additional contexts,
  file/env build secrets with Docker-compatible ignored ownership metadata,
  SSH forwarding, cache hints, labels, target stages, platforms, pull/no-cache,
  builder selection, checks, provenance/SBOM attestations, extra hosts, build
  network mode, Buildx-compatible isolation acceptance, privileged builds,
  shared memory size, ulimits, `--print`, and service-context build ordering.
- Supported `up` coverage includes attach selection, dependency attachment,
  exit-control flags, raw output flags, timestamps, watch mode, and the
  attached terminal `--menu` shortcut surface. The menu path supports detach,
  watch toggle, command-level `--watch` start, graceful stop, force stop
  shortcuts, and exit-control flags; Docker Desktop-only shortcuts are
  intentionally absent.
- Supported service mount coverage includes named volumes, bind mounts,
  anonymous volumes, tmpfs mounts, long-form tmpfs options, `volumes_from`,
  Docker-compatible bind `create_host_path` handling, and long-form
  `volume.labels` preservation. Anonymous `volume.labels` are applied to the
  created runtime volume; named service mount labels remain config metadata,
  matching Docker Compose.
- Supported namespace-mode coverage includes `network_mode: none` and
  `pid: host`. `network_mode: host` maps to the Stephen fork-backed
  `container --network host` runtime path while avoiding Compose project network
  attachment. Service/container namespace-sharing forms remain explicit runtime
  gaps.
- Supported network-resource coverage includes top-level network `driver_opts`,
  which are preserved in config output and passed to Apple network creation as
  plugin-specific `--option key=value` values. Service network attachment
  `driver_opts` support is currently limited to Docker-compatible MTU values
  because Apple attachment options expose MTU but not arbitrary endpoint driver
  options.
- Supported device coverage includes service `device_cgroup_rules`, which maps
  to the fork-backed `container run/create --device-cgroup-rule` runtime path,
  and service `devices`, which maps Docker Compose device entries to
  fork-backed `container run/create --device` arguments for supported Linux VM
  device paths such as `/dev/null` and `/dev/zero`. Device source paths and
  explicit target paths must be absolute. GPU requests and arbitrary macOS
  hardware passthrough remain explicit runtime gaps.
- Supported local Deploy metadata includes replicas, local job modes,
  stop-first update delays, restart policy fields, CPU/memory reservation
  hints, and Swarm `endpoint_mode` acceptance as Docker-compatible local
  metadata.
- Partially supported commands: `attach` and `up`.
- Unsupported commands: `commit` and `publish`.

Long-running project loading, image pull/build, and non-interactive runtime
handoff steps emit Compose-owned progress on stderr so scriptable stdout output
stays clean. Use `--progress quiet` to suppress these rows, `--progress plain`
for log-friendly rows, or `--progress tty` for the animated terminal spinner.
`--progress json` emits newline-delimited JSON events for Compose-owned phases.
`--progress auto` uses the animated spinner when stderr is a terminal and plain
rows otherwise.

Use `container system version` to see the running `container` runtime source, branch lane, commit, compiled `containerization` ref, and pinned `container-builder-shim` image. Use `container compose version` to see the installed plugin lane, embedded `compose-go` version, and the `container` / `containerization` pins that package was built against.

## Project Repositories

The supported preview install is a matched Stephen fork-backed stack:

- [`container-compose`](https://github.com/stephenlclarke/container-compose): this plugin and its Swift/Go packaging workflow.
- [`container`](https://github.com/stephenlclarke/container): the fork-backed runtime and CLI installed beside the plugin.
- [`containerization`](https://github.com/stephenlclarke/containerization): the Swift runtime package pinned by the stack.
- [`container-builder-shim`](https://github.com/stephenlclarke/container-builder-shim): the BuildKit bridge image pinned by `container`.

Install and upgrade commands live in [INSTALL.md](INSTALL.md). Branch, tag, release, and Homebrew lane policy lives in [BRANCHES.md](BRANCHES.md).

## Plugin Recognition

When installed correctly, `container help` lists `compose` under `PLUGINS`.

![container help output showing the compose plugin recognised](docs/images/container-help-compose-plugin.png)

## Documentation

- [INSTALL.md](INSTALL.md): install, upgrade, verify, uninstall, recover bad installs, and diagnose runtime issues.
- [BRANCHES.md](BRANCHES.md): understand `main`, short-lived development branches, semantic tags, release assets, and Homebrew lane policy.
- [BUILD.md](BUILD.md): build, test, package, and run contributor validation from source.
- [DESIGN.md](DESIGN.md): understand the Swift/Go boundary and runtime adapter ownership.
- [PLAN.md](PLAN.md): review the current roadmap and Apple-facing slice order.
- [STATUS.md](STATUS.md): get the current dependency pins, blockers, and validation handoff.
- [CONTRIBUTING.md](CONTRIBUTING.md): prepare reviewable changes.
- [docs/parity/compose-cli-surface.md](docs/parity/compose-cli-surface.md): review local Docker Compose CLI surface parity and documented differences.
- [SUPPORT.md](SUPPORT.md): ask for help or report non-security issues.
- [SECURITY.md](SECURITY.md): report security issues.

## License

This project uses the Apache License, Version 2.0, matching the license used by
[`apple/container`](https://github.com/apple/container).
