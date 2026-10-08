#!/usr/bin/env python3
"""Fail-closed host admission for the bounded 50-service matrix profile."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone


SERVICES_MAX = 50
SERVICE_MEMORY_MIB = 200
SERVICE_OVERHEAD_MIB = 32
RUNTIME_BASE_BYTES = 6 * 1024**3
HOST_HEADROOM_BYTES = 4 * 1024**3
COLIMA_MAX_BYTES = 8 * 1024**3
HOST_MIN_BYTES = 24 * 1024**3


def capture() -> dict:
    host_bytes = int(subprocess.check_output(
        ['/usr/sbin/sysctl', '-n', 'hw.memsize'], text=True, timeout=10))
    profiles = [json.loads(line) for line in subprocess.check_output(
        ['colima', 'list', '--json'], text=True, timeout=20).splitlines()]
    defaults = [row for row in profiles if row.get('name') == 'default']
    if (len(defaults) != 1 or defaults[0].get('arch') != 'aarch64'
            or defaults[0].get('runtime') != 'docker'):
        raise RuntimeError('Expected one default arm64 Docker Colima profile')
    vm = subprocess.check_output(['/usr/bin/vm_stat'], text=True, timeout=10)
    page = re.search(r'page size of ([0-9]+) bytes', vm)
    if page is None:
        raise RuntimeError('Cannot read Darwin VM page size')
    counts = {}
    for name in ('Pages free', 'Pages inactive', 'Pages speculative'):
        match = re.search(rf'^{re.escape(name)}:\s*([0-9,]+)', vm, re.M)
        if match is None:
            raise RuntimeError('Cannot read Darwin VM availability metric: ' + name)
        counts[name] = int(match.group(1).replace(',', ''))
    page_bytes = int(page.group(1))
    available = sum(counts.values()) * page_bytes
    return {'captured_at': datetime.now(timezone.utc).isoformat(),
            'host_bytes': host_bytes, 'colima_bytes': defaults[0].get('memory'),
            'colima_status': defaults[0].get('status'),
            'page_size_bytes': page_bytes, 'page_counts': counts,
            'available_memory_bytes': available}


def admit(snapshot: dict, service_memory_mib: int = SERVICE_MEMORY_MIB) -> dict:
    if service_memory_mib != SERVICE_MEMORY_MIB:
        raise RuntimeError('Broad matrix profile requires the admitted 200 MiB service cap')
    colima_bytes = snapshot.get('colima_bytes')
    host_bytes = snapshot.get('host_bytes')
    available = snapshot.get('available_memory_bytes')
    if (type(colima_bytes) is not int or type(host_bytes) is not int
            or type(available) is not int or colima_bytes <= 0):
        raise RuntimeError('Host capacity snapshot is incomplete')
    if (host_bytes < HOST_MIN_BYTES or colima_bytes > COLIMA_MAX_BYTES):
        raise RuntimeError('Physical host or Colima allocation is outside the matrix profile')
    guest_bytes = SERVICES_MAX * (SERVICE_MEMORY_MIB + SERVICE_OVERHEAD_MIB) * 1024**2
    physical_headroom = host_bytes - colima_bytes - guest_bytes
    if physical_headroom < HOST_HEADROOM_BYTES:
        raise RuntimeError('Host/Colima budget cannot admit the capped 50-service matrix')
    incremental_guest = max(0, guest_bytes - RUNTIME_BASE_BYTES)
    pressure_headroom = available - incremental_guest
    if pressure_headroom < HOST_HEADROOM_BYTES:
        raise RuntimeError('Current memory pressure cannot admit the capped 50-service matrix')
    return {'schema': 1, **snapshot,
            'service_count_max': SERVICES_MAX,
            'service_memory_mib': SERVICE_MEMORY_MIB,
            'estimated_service_overhead_mib': SERVICE_OVERHEAD_MIB,
            'runtime_current_budget_bytes': RUNTIME_BASE_BYTES,
            'candidate_guest_envelope_bytes': guest_bytes,
            'candidate_incremental_bytes': incremental_guest,
            'physical_headroom_bytes': physical_headroom,
            'pressure_headroom_bytes': pressure_headroom,
            'minimum_host_headroom_bytes': HOST_HEADROOM_BYTES,
            'passed': True}


def main() -> None:
    evidence = Path(sys.argv[1])
    service_memory_mib = int(sys.argv[2])
    snapshot = capture()
    try:
        receipt = admit(snapshot, service_memory_mib)
    except RuntimeError as error:
        receipt = {'schema': 1, **snapshot,
                   'service_memory_mib': service_memory_mib,
                   'passed': False, 'failure': str(error)}
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
        raise
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2) from error
