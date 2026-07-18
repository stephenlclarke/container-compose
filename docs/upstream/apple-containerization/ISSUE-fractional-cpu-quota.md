# Compatibility gap: generic fractional CPU quota

`LinuxContainer.Configuration.cpus` is integral because it contributes to VM
vCPU allocation, but CFS quota can limit a Linux workload fractionally. The
missing generic configuration prevented `0.25` CPU limits on macOS guests.

`f7b45bf` adds the optional OCI microsecond quota only. It deliberately
excludes CLI parsing, Compose models, fractional VM vCPUs, CPU period/realtime
controls, host scheduling, and Windows behavior.
