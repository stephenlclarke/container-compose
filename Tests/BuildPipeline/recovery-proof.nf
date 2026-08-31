nextflow.enable.dsl = 2

params.upstream_fingerprint = 'upstream-v1'
params.downstream_fingerprint = 'planned-failure-v1'
params.evidence_dir = ''

process VERIFY_STDIN_CLOSED {
    publishDir params.evidence_dir, mode: 'copy', overwrite: true
    output:
    path 'stdin-closed.txt'

    script:
    """
    python3 -c 'import os, select, sys; ready, _, _ = select.select([0], [], [], 0); value = os.read(0, 1) if ready else None; sys.exit(0 if value == b"" else 1)'
    printf '%s\\n' 'stdin closed' > stdin-closed.txt
    """
}

process BUILD_UPSTREAM {
    publishDir params.evidence_dir, mode: 'copy', overwrite: true
    input:
    path stdin_marker
    val upstream_fingerprint

    output:
    path 'upstream.txt'

    script:
    """
    grep -qx 'stdin closed' '${stdin_marker}'
    printf '%s\\n' 'upstream complete' > upstream.txt
    """
}

process RUN_DOWNSTREAM {
    publishDir params.evidence_dir, mode: 'copy', overwrite: true
    input:
    path upstream_marker
    val downstream_fingerprint

    output:
    path 'downstream.txt'

    script:
    if (downstream_fingerprint == 'corrected-v1') {
        """
        grep -qx 'upstream complete' '${upstream_marker}'
        printf '%s\\n' 'downstream complete' > downstream.txt
        """
    } else {
        """
        grep -qx 'upstream complete' '${upstream_marker}'
        printf '%s\\n' 'planned downstream failure' >&2
        exit 42
        """
    }
}

workflow {
    VERIFY_STDIN_CLOSED()
    BUILD_UPSTREAM(VERIFY_STDIN_CLOSED.out, params.upstream_fingerprint)
    RUN_DOWNSTREAM(BUILD_UPSTREAM.out, params.downstream_fingerprint)
    RUN_DOWNSTREAM.out.view { marker -> "RECOVERY_PROOF_RESULT=${marker.text.trim()}" }
}
