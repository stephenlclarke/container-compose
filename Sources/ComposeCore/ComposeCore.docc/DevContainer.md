# devcontainer

A VS Code-compatible Dev Container implementation for Apple's container runtime, built on the shared Engine API and container project family.

The unreleased native integration preserves logical Compose network labels independently of runtime names. Digest-qualified image launches also retain the original reference spelling as reserved metadata; devcontainer accepts it only after verifying the actual native image descriptor and repository. Tag-only launches remain unchanged. Stock live C01 passes all original observations and cleanup at Compose `1fe36f56` with devcontainer `aa56f00`, invocation `178bf269-d0d4-48e1-ac73-8ca375c2707d`. Enhanced qualification remains blocked on its pinned guest image; stable release and quiet paired benchmark gates remain open.

- [Repository](https://github.com/stephenlclarke/devcontainer)
- [Hosted API reference](https://stephenlclarke.github.io/api/devcontainer/)
- [Dev Container specification and tools](https://containers.dev/)
