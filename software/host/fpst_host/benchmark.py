from __future__ import annotations

import math
import statistics
from collections.abc import Callable

from .models import BenchmarkResult, CommandResult


def _percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    frac = pos - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def benchmark_command(
    command_name: str,
    invoke: Callable[[], CommandResult],
    count: int,
) -> BenchmarkResult:
    if count <= 0:
        raise ValueError("benchmark count must be positive")

    results = [invoke() for _ in range(count)]
    latencies = [result.elapsed_ms for result in results]
    success_count = sum(1 for result in results if result.ok)

    return BenchmarkResult(
        command=command_name,
        count=count,
        success_count=success_count,
        failure_count=count - success_count,
        min_ms=min(latencies),
        mean_ms=statistics.fmean(latencies),
        p50_ms=_percentile(latencies, 0.50),
        p95_ms=_percentile(latencies, 0.95),
        max_ms=max(latencies),
    )
