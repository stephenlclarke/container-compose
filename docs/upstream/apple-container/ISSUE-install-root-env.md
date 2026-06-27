<!-- markdownlint-disable MD013 -->

# [Bug]: `container system start` ignores `CONTAINER_INSTALL_ROOT`

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/01-bug.yml`.

## What Happened?

`container system start` defaults its `--install-root` option to `InstallRoot.defaultPath` instead of the environment-resolved `InstallRoot.path`.

That means a Homebrew wrapper can set `CONTAINER_INSTALL_ROOT=/opt/homebrew/opt/container`, but `container system start` still writes the launchd plist using the grandparent of the real executable path. For a Homebrew keg binary at `.../Cellar/container/<version>/libexec/bin/container`, the computed install root becomes `.../Cellar/container/<version>/libexec`.

The API server then receives the wrong `CONTAINER_INSTALL_ROOT` and searches for built-in plugins under `.../libexec/libexec/container/plugins`. The network plugin is installed under the real install root at `.../libexec/container/plugins`, so startup fails before Compose can run:

```text
helper failed [error=internalError: "cannot find any plugins with type network"] [name=container-apiserver]
```

## What Did You Expect To Happen?

`container system start` should honor the same install-root resolution as other runtime components. If `CONTAINER_INSTALL_ROOT` is set, the default `--install-root` should use that value unless the user passes an explicit CLI option.

That keeps package-manager wrappers, source builds, and explicit `--install-root` overrides aligned with the plugin loader and API-server startup path.

## How Can It Be Reproduced?

Install a Homebrew-wrapped `container` binary where the real executable lives below `libexec/bin` and the wrapper exports `CONTAINER_INSTALL_ROOT`:

```bash
CONTAINER_INSTALL_ROOT=/opt/homebrew/opt/container /opt/homebrew/Cellar/container/<version>/libexec/bin/container system start
```

Inspect the generated launchd plist or logs. The API server receives the executable-derived install root instead of the environment value and fails to find built-in network plugins.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
