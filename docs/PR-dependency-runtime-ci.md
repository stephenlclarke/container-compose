# Prepare the existing normalizer dependency before timed tests

Build the existing Go helper before the stock-runtime test step, warming the Go compilation cache reused by the source fallback. Keep the same unit tests, helper-selection behavior and 30-second CLI deadline. This is a CI dependency-order fix for the reported PR failures, not a runtime change or performance result. Validate workflow syntax with actionlint; the dependency PR checks provide the hosted cold-cache confirmation.
