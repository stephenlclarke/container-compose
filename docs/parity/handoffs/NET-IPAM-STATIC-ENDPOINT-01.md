# NET-IPAM-STATIC-ENDPOINT-01

| Field | Record |
| --- | --- |
| State | `Verified` — one coherent signed lower stack and the exact Compose candidate pass the bounded static-endpoint lifecycle through the real runtime. |
| Behaviour | A named network with subnet `192.168.240.0/24`, range `192.168.240.128/25`, and gateway `192.168.240.1` accepts the static service address `192.168.240.20` outside the dynamic range, preserves it through restart, and removes the project network on down. |
| Pinned Docker oracle | Same-MBP Docker Compose `5.4.0` and Docker Engine `29.2.1`; the marker-protected root records successful create, inspect, restart, and cleanup. |
| Affected repositories and inputs | Compose `cd5f0e453372bcecb1821fab564338d27fc711c1`; Container `c7924e375d98d82af37902f4a0c310ee389eab97`; Containerization `7f62f5b940630811573a34f70cdd6f3fa11d014d`; Engine API `5e6e24d017691596783515285e1ff56d29701235`; SwiftNIO SSL `a9d648535c62e640d1df258a70c9117a8ddea43e`. The candidate archive is `container-homebrew-c7924e37-arm64.tar.gz`, SHA-256 `1d5c7c73272c6addda98639283310e92b2a703a415621bf1dd7dde94b00807c3`. |
| Focused proof | `ComposeRuntimeSmokeTests.runtimeStaticIPv4EndpointLifecycle` passes in 45.492 seconds against the exact pinned candidate. It verifies the configured subnet, allocation range, and gateway; observes `192.168.240.20` before and after `compose restart`; and confirms `compose down` removes the project network. The log is `/Volumes/SSD/github/evidence/container-family-stable-01/net-ipam-static-endpoint-cd5f0e45/runtime-test-with-preflight-path.log`. |
| Closure note | The first invocation selected an older `container` from `PATH` for Compose preflight even though the runtime test itself used `CONTAINER_BIN`. Re-running with `CONTAINER_COMPOSE_CONTAINER` set to the same pinned candidate proved the advertised capability schema and all seven required capabilities. This was a test invocation mismatch, not a product or runtime defect. |
| Safe handoff | Preserve the Docker oracle and the marker-protected exact candidate evidence under `/Volumes/SSD/github/evidence/container-family-stable-01`; reconcile [issue #208](https://github.com/stephenlclarke/container-compose/issues/208) after the verified commit is published. |

## Evidence

The previous source-graph failure is superseded by the coherent signed stack above. The 45.492-second completed sample is functional evidence only; it does not establish comparable-or-better performance.
