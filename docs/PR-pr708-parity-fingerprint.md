# Fix the reported PR 708 tool check

Include both existing parity inputs in the checkpoint fingerprint. Extend the existing mutation regression to prove each input changes the resulting key; retain the failing assertion as red evidence. No parity fixtures, benchmark baselines, build engines, or release execution are changed.

Validation: the existing omission check failed twice before the change. Afterward both focused fingerprint tests pass, including dynamic hash changes for the two inputs (48.789 seconds).
