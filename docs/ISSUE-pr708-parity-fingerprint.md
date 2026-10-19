# PR 708 parity fingerprint check failure

The reported release tool check fails for `PARITY_RETAIN_FIXTURE_DIR` and `PARITY_SERVICE_MEMORY_MIB`: both defaulted script inputs are absent from the release checkpoint fingerprint. Changing them can reuse a checkpoint made under different inputs.
