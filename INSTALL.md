# Installing container-compose

This guide explains how to install `container-compose` as a local
`apple/container` CLI plugin.

## Requirements

- macOS.
- The `container` CLI installed and working on the target machine.
- A `container-compose-plugin.tar.gz` archive.

If you need to create the archive from source, follow [BUILD.md](BUILD.md).
The archive must contain:

```text
compose/bin/compose
compose/config.toml
compose/resources/compose-normalizer
```

## Install Locally

Install or replace the local plugin with:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo mkdir -p /usr/local/libexec/container-plugins
sudo tar -xzf container-compose-plugin.tar.gz -C /usr/local/libexec/container-plugins
```

The resulting plugin layout is:

```text
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
/usr/local/libexec/container-plugins/compose/resources/compose-normalizer
```

## Verify The Installation

Confirm that `container` discovers the plugin:

```sh
container compose version
```

Run a read-only Compose command from a directory containing a Compose file:

```sh
container compose config
```

## Upgrade

Obtain or build a fresh archive, then replace the installed plugin:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo tar -xzf container-compose-plugin.tar.gz -C /usr/local/libexec/container-plugins
```

## Uninstall

Remove the installed plugin directory:

```sh
sudo rm -rf /usr/local/libexec/container-plugins/compose
```

## Troubleshooting

If `container compose` is not found, verify that
`/usr/local/libexec/container-plugins/compose/config.toml` exists and that the
`container` CLI supports plugin discovery from `/usr/local/libexec/container-plugins`.

If Compose normalization fails after installation, verify that
`/usr/local/libexec/container-plugins/compose/resources/compose-normalizer`
exists and is executable.
