# Feature request: support an explicit unlimited CPU limit

## Feature or enhancement request details

`container run` and `container create` rejected `--cpus 0`, although Docker treats zero NanoCPUs as no CPU quota. This prevented generic callers from stating the unlimited case explicitly and left the lower runtime attempting to write the invalid cgroup v2 value `-1 100000` to `cpu.max` when an unlimited OCI quota was supplied.

The required implementation is two small, reusable macOS/Linux-guest changes: Container commit `29c3cc8` accepts a nonnegative generic `--cpus` value and represents zero as the existing OCI unlimited quota sentinel (`-1`); Containerization commit `46c0921` writes that sentinel as cgroup v2 `max`. Docker Compose V2 itself normalizes `cpus: 0` to an omitted CPU limit, which container-compose already matches; Compose commit `52b0b874` provides the downstream parity coverage and handoff documentation.

This intentionally excludes Docker Compose types, Docker API compatibility types, realtime CPU scheduling, cpusets, VM CPU hotplug, host scheduling, Linux-host behavior, and Windows behavior.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
