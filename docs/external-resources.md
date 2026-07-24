# External Compose Resources

`configs.<name>.external` and `secrets.<name>.external` are Compose-owned local resource backends. Compose resolves a resource's optional `name:` first, then reads it only for a non-dry-run lifecycle or build operation. External configs and service secrets become private read-only mounts; external build secrets become invocation-private files that are deleted as soon as the build command returns. Values never appear in normalized JSON, bake output, command-line values, labels, or normal diagnostics.

## External Configs

Compose reads external config bytes from `CONTAINER_COMPOSE_CONFIG_DIRECTORY`, or from `~/.config/container-compose/configs` when that variable is unset. Each resolved resource name is a path below that directory; names that escape it are rejected.

Create the directory and provision a config as a regular file before invoking Compose:

```sh
mkdir -p ~/.config/container-compose/configs
install -m 0644 ./app.conf ~/.config/container-compose/configs/shared_app_config
```

```yaml
configs:
  app_config:
    external: true
    name: shared_app_config
```

External configs are ordinary non-secret files. Their lifecycle and backup policy remain the operator's responsibility.

## External Secrets

Compose reads external secrets from the macOS Keychain generic-password item whose service is `com.apple.container-compose` and whose account is the resolved resource name. Prompt for the value instead of placing it in shell history or the Compose project:

```sh
read -rs 'secret?Secret: '
printf '\n'
security add-generic-password -U -s com.apple.container-compose -a shared_api_secret -w "$secret"
unset secret
```

```yaml
secrets:
  api_secret:
    external: true
    name: shared_api_secret
```

The caller's Keychain access controls apply because Compose reads the item in its own process. Do not place secret contents in Compose files, labels, or shell history. Delete an item with `security delete-generic-password -s com.apple.container-compose -a shared_api_secret` when it is no longer needed.

The same resource can be granted to a build:

```yaml
services:
  app:
    build:
      context: .
      secrets:
        - source: api_secret
          target: api_token
```

For a live Apple build, Compose writes the Keychain bytes to an opaque 0400 file below its private state directory, passes that path to the generic `container build --secret` primitive, and deletes the invocation directory on success or failure. Concurrent builds use distinct directories. `--dry-run` does not read or write the secret.

Docker Compose V2 retains this external reference in `config`, but omits it from `build --print` and its local Docker engine reports a missing required BuildKit secret. `container compose build --print` deliberately matches that bake omission. The live Keychain resolution is the documented macOS extension; file-backed and environment-backed build secrets retain ordinary Docker Compose behavior.

## Compatibility

The external-resource reader is selected through `ComposeRuntimeSPI`, so another runtime provider can replace either backend without changing Compose orchestration. This local Compose backend does not require the fork-only `container config` or `container secret` command/API additions, and build-secret resolution does not add a runtime secret-store primitive.
