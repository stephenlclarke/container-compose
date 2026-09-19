# devcontainer

A VS Code-compatible Dev Container implementation for Apple's container runtime, built on the shared Engine API and container project family.

The unreleased native integration preserves logical Compose network labels independently of runtime names. Digest-qualified image launches also retain the original reference spelling as reserved metadata; devcontainer accepts it only after verifying the actual native image descriptor and repository. Tag-only launches remain unchanged. Focused component tests pass, but matched live parity and stable release qualification remain pending.

- [Repository](https://github.com/stephenlclarke/devcontainer)
- [Hosted API reference](https://stephenlclarke.github.io/api/devcontainer/)
- [Dev Container specification and tools](https://containers.dev/)
