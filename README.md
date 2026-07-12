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
[![Release](https://img.shields.io/github/v/release/stephenlclarke/container-compose?label=release)](https://github.com/stephenlclarke/container-compose/releases/latest)
![Repo Visitors](https://visitor-badge.laobi.icu/badge?page_id=stephenlclarke.container-compose)

`container-compose` is a standalone plugin that provides Docker Compose v2
workflows for Apple's [`container`](https://github.com/apple/container) CLI.
Local files, Git resources, and `oci://` Compose project artifacts are
normalized with `compose-go`; image-backed projects can also push service
images and publish Compose YAML as OCI project artifacts. Swift owns
orchestration and maps supported Compose behavior to the matched runtime stack.

Help color-codes command, subcommand, and option support: green for supported,
orange for partially supported, and red for unsupported. Partially supported
commands include a `Limitations` line for gaps that are not tied to an option.
Use `--ansi never` for plain output. Unsupported runtime behavior fails before
side effects with an explicit `unsupported compose feature` message.

The top-level help output is the quickest support overview. Run
`container compose COMMAND --help` for command-specific option support.

The authoritative parity ledger is [STATUS.md](STATUS.md). It lists every
tracked Compose file, service, Dockerfile/build, command, and long-option
surface with ✅ yes, ⚠️ partial, or ❌ no, and explains every partial surface.

Use `container system version` to see the running `container` runtime source, branch lane, commit, compiled `containerization` ref, and builder image metadata. Use `container compose version` to see the installed plugin lane, embedded `compose-go` version, and package/runtime compatibility metadata.

## Project Repositories

The supported install is the matched five-repository stephenlclarke stack:

- [`container-compose`](https://github.com/stephenlclarke/container-compose): this plugin and its Swift/Go packaging workflow.
- [`container`](https://github.com/stephenlclarke/container): the matched `stephenlclarke` runtime and CLI installed beside the plugin.
- [`containerization`](https://github.com/stephenlclarke/containerization): the Swift runtime package consumed by the stack.
- [`container-builder-shim`](https://github.com/stephenlclarke/container-builder-shim): the BuildKit bridge image used by `container`.
- [`homebrew-tap`](https://github.com/stephenlclarke/homebrew-tap): the stable prebuilt `container` and `container-compose` formulae.

Install and upgrade commands live in [INSTALL.md](INSTALL.md). Branch, tag, release helper, and Homebrew formula policy live in [BRANCHES.md](BRANCHES.md).

## Plugin Recognition

When installed correctly, `container help` lists `compose` under `PLUGINS`.

![container help output showing the compose plugin recognised](docs/images/container-help-compose-plugin.png)

## Documentation

- [INSTALL.md](INSTALL.md): install, upgrade, verify, uninstall, recover bad installs, and diagnose runtime issues.
- [BRANCHES.md](BRANCHES.md): understand `main`, semantic tags, `scripts/CONTAINER_STACK_RELEASE.sh`, release assets, and Homebrew formula policy.
- [BUILD.md](BUILD.md): build, test, package, and run contributor validation from source.
- [DESIGN.md](DESIGN.md): understand the Swift/Go boundary and runtime adapter ownership.
- [STATUS.md](STATUS.md): get the current parity surfaces, blockers, active gaps, and validation handoff.
- [CONTRIBUTING.md](CONTRIBUTING.md): prepare reviewable changes.
- [docs/parity/compose-cli-surface.md](docs/parity/compose-cli-surface.md): review local Docker Compose CLI surface parity and documented differences.
- [SUPPORT.md](SUPPORT.md): ask for help or report non-security issues.
- [SECURITY.md](SECURITY.md): report security issues.

## License

This project uses the Apache License, Version 2.0, matching the license used by
[`apple/container`](https://github.com/apple/container).
