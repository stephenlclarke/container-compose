# NET-IPAM-STATIC-ENDPOINT-01

| Field | Record |
| --- | --- |
| State | `Blocked` — Docker's bounded static-endpoint behavior is frozen, but the unchanged normal Compose graph cannot compile before a candidate can be built. |
| Behaviour | A named network with subnet `192.168.240.0/24`, range `192.168.240.128/25`, and gateway `192.168.240.1` accepts the static service address `192.168.240.20` outside the dynamic range, preserves it through restart, and removes the project network on down. |
| Pinned Docker oracle | Same-MBP Docker Compose `5.4.0` and Docker Engine `29.2.1`; the marker-protected root records successful create, inspect, restart, and cleanup. |
| Affected repositories and inputs | Compose `a9fa92be524c0e7bcb968b177e2bef9aa0d9ff1d`, clean; lock SHA-256 `a61f450629fb45e6e39c66ef725bc390cb413ee61fad60ce518d04952c786ef5`; locked Container `2a79b4553a342e33411666a88ad20ccd2ce46551`; locked Containerization `77f06d4c44341e04241941072fb69e2b85a6f5c1`. |
| Focused proof | Docker accepts `192.168.240.20`, reports it as the endpoint IP, preserves it through `compose restart`, and removes `netipamstaticoracle_appnet` on down. The candidate's exact normal lock resolves locally after hydrating the signed locked Container object into the disposable SwiftPM mirror without changing `Package.resolved`. |
| Blocker evidence | The focused candidate build reaches `ContainerDiscoveryAdapter.swift:255` then fails: `Attachment.ipv4Address` is non-optional `CIDRv4` in locked Container `2a79b455`, while current Compose's IPv6-only-safe adapter requires an optional address and calls `.map`. The previously verified compatible local commits, Container `d7e5f5ddd831e0fe0cf025d606f1d2622eb6a4d2` and Containerization `cfb00bbf3523079fe2ab9fb6b8e9b3504eff77e5`, are not fetchable from the user fork. |
| Required change to close | Publish one coherent signed lower stack, update the Compose package/release pins to it, then rerun the unchanged focused source test and one fresh exact-fingerprint candidate. Do not remove IPv6-only support to accommodate the obsolete mandatory-IPv4 API. |
| Safe handoff | Preserve `/private/tmp/net-ipam-static-endpoint-oracle.jnKnbv` (`.container-net-ipam-static-endpoint-oracle-root`), its Docker fixture and focused build log, and Slack START thread `1786222932.328589`. |

## Evidence

The candidate build is a functional source-graph failure, not a performance result. It made steady compiler progress, failed deterministically before the test phase, and did not hang or mutate the tracked Compose source or lockfile. The empty remote-object probes are retained at `/private/tmp/container-stack-remote-probe.BYnpnj`.
