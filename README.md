# container-compose

[![CI](https://github.com/stephenlclarke/container-compose/actions/workflows/ci.yml/badge.svg)](https://github.com/stephenlclarke/container-compose/actions/workflows/ci.yml)
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
![Repo Visitors](https://visitor-badge.laobi.icu/badge?page_id=stephenlclarke.container-compose)

`container-compose` is a standalone SwiftPM plugin that will provide Docker Compose style workflows for Apple's `container` CLI.

The plugin is intended to install as:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/compose-normalizer
```

The first implementation target is local-development Compose v2 compatibility where `container` has matching runtime primitives. Compose file normalization uses `compose-go`, with Swift handling runtime orchestration.

CI builds and tests the Swift package and Go normalizer helper. Main-branch and same-repository pull request runs also publish Swift generic coverage and Go coverage reports to SonarCloud.

## Local CI

Run the same validation and package path used by GitHub Actions before pushing:

```sh
make workflow
```

Useful targets:

- `make ci` runs the validation job used by GitHub Actions.
- `make build` builds the Swift package.
- `make test` runs Swift and Go tests.
- `make coverage-check` regenerates coverage reports and requires Swift and Go coverage to meet `COVERAGE_MIN`, which defaults to `85`.
- `make package` builds the installable plugin archive.
- `make sonar` runs a local Sonar scan when `SONAR_TOKEN` and `sonar-scanner` are available.

For local installation steps, see [INSTALL.md](INSTALL.md).

There is no local deploy target yet; release packaging is handled by `make package`, and publishing remains a GitHub Actions concern.

## License

This project uses the Apache License, Version 2.0, matching the license used by `apple/container`.
