# Issue: Compose runtime certificate needs retained IPv4 allocation-range leases

## Problem description

Container Compose already preserves an IPv4 `ip_range`, gateway, and auxiliary-address model, but the live candidate could release a service's dynamic VMNet allocation when the old runtime session disconnected during restart. Docker retains that endpoint allocation through `docker compose restart`.

The user-visible Compose contract is one IPv4 pool with a range, gateway, and auxiliary reservations: dynamic addresses must remain inside the range, skip reserved addresses, survive service restart, and disappear only when project teardown removes the network.

## Resolution

The lower-runtime retention correction is in signed Container commits `d7e5f5ddd831e0fe0cf025d606f1d2622eb6a4d2` and `ec286fca9bca2c4d9d732f6f898564d9f23e1eb6`. Signed Compose commit `30d3017112a9b7694aaec2ec80a0cfa411e6004d` ensures release builds honor local stack overlays, allowing the exact local graph to be built and certified. The repository-owned Bash fixture `Tools/parity/check-compose-network-ipam-allocation-range.sh --strict` passes against Docker Compose `5.4.0` / Docker Engine `29.2.1` and the exact release candidate.

## Evidence

- Docker and candidate fixtures retain raw configuration, inspections, timing, fingerprints, and cleanup at `/private/tmp/container-ipam-allocation-range-release.ZgE2Ll/evidence`.
- Candidate dynamic addresses are within `192.168.200.128/25`; the in-range auxiliary reservation `192.168.200.130` is skipped.
- Candidate `alpha` retains `192.168.200.129/24` across restart and the network is absent after `down`.
- The single release timing sample remains diagnostic only; `up` is 9.24x Docker, below the 10x functional guard but not comparable-or-better performance proof.

## Tracking

- Runtime defect: [stephenlclarke/container#83](https://github.com/stephenlclarke/container/issues/83), commented and closed as completed after the release certificate.
- Build-overlay tracker: [stephenlclarke/container-compose#206](https://github.com/stephenlclarke/container-compose/issues/206).
- Contract record: [NET-IPAM-ALLOCATION-RANGE-01](../../parity/handoffs/NET-IPAM-ALLOCATION-RANGE-01.md).
- This supersedes the historical archived handoff with the same slug. No upstream or Apple publication is authorised.
