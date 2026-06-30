# Feature or Enhancement Request Details

`LinuxContainer.Configuration` should allow callers to request the sandbox VM PID namespace instead of always creating a private OCI PID namespace for the workload process.

Docker-compatible higher-level clients need this primitive for `pid: host` / `--pid host` style behavior. In the Apple architecture, the relevant "host" for a Linux workload is the sandbox VM namespace that owns the OCI runtime process, not the macOS host. Today `LinuxContainer.generateRuntimeSpec()` always includes `LinuxNamespace(type: .pid)`, so downstream `apple/container` cannot represent that host-PID mode without modifying the generated OCI spec outside `containerization`.

Requested shape:

- Add a small boolean on `LinuxContainer.Configuration`, defaulting to isolated PID namespace behavior.
- Preserve the existing OCI namespace list by default.
- When the boolean is enabled, omit the `.pid` namespace entry from the generated OCI runtime spec.
- Keep Docker/Compose option parsing out of `containerization`; downstream clients own those user-facing strings.

## Upstream Search

Checked before implementation:

- `apple/containerization` issues and PRs for PID host namespace terms: no matching open implementation or discussion found.
- GitHub discussions search for `apple/containerization` PID host namespace terms: no matching discussion found.
- Host-network CLI behavior is handled in `apple/container`; no `containerization` network namespace change was required for this PID primitive.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
