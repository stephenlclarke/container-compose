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
![Repo Visitors](https://visitor-badge.laobi.icu/badge?page_id=stephenlclarke.container-compose)

`container-compose` is a standalone plugin that provides Docker Compose style
workflows for Apple's [`container`](https://github.com/apple/container) CLI
where the supported Compose surface maps to available runtime primitives.

The first implementation target is local-development Compose v2 compatibility
where [`container`](https://github.com/apple/container) has matching runtime
primitives. Compose file normalization uses `compose-go`, with Swift handling
runtime orchestration.

## Documentation

- [INSTALL.md](INSTALL.md) explains local plugin installation and removal.
- [COMPATIBILITY.md](COMPATIBILITY.md) lists supported runtime primitives,
  Apple `container` runtime gaps, and `container-compose` implementation gaps.
- [BUILD.md](BUILD.md) explains dependencies, developer validation, packaging,
  and SonarQube scanning.
- [DESIGN.md](DESIGN.md) explains the architecture and why Go is used for
  Compose normalization.
- [CONTRIBUTING.md](CONTRIBUTING.md) explains pull request, commit, and branch
  protection expectations.

## License

This project uses the Apache License, Version 2.0, matching the license used by
[`apple/container`](https://github.com/apple/container).
