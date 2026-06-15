# container-compose

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose&metric=coverage)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-compose&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose)

`container-compose` is a standalone SwiftPM plugin that will provide Docker Compose style workflows for Apple's `container` CLI.

The plugin is intended to install as:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
```

The first implementation target is local-development Compose v2 compatibility where `container` has matching runtime primitives. Compose file normalization is planned to use `compose-go`, with Swift handling runtime orchestration.

## License

This project uses the Apache License, Version 2.0, matching the license used by `apple/container`.
