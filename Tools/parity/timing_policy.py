"""Shared timing policy for Docker Compose parity checks."""

from __future__ import annotations

import math


def slowdown_ratio(reference_seconds: float, candidate_seconds: float) -> float:
    """Return the candidate/reference duration ratio."""
    if not math.isfinite(reference_seconds) or not math.isfinite(candidate_seconds):
        raise ValueError("timing durations must be finite")
    if reference_seconds < 0 or candidate_seconds < 0:
        raise ValueError("timing durations must be non-negative")
    if reference_seconds == 0:
        return math.inf
    return candidate_seconds / reference_seconds


def exceeds_slowdown_boundary(
    reference_seconds: float,
    candidate_seconds: float,
    max_ratio: float,
) -> bool:
    """Return whether the candidate reaches the inclusive slowdown boundary."""
    if not math.isfinite(max_ratio) or max_ratio <= 0:
        raise ValueError("maximum slowdown ratio must be finite and positive")
    return slowdown_ratio(reference_seconds, candidate_seconds) >= max_ratio
