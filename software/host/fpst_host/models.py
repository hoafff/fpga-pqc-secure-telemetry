from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Sequence


@dataclass(frozen=True)
class TransportReply:
    text: str
    elapsed_ms: float


@dataclass(frozen=True)
class CommandResult:
    command: str
    ok: bool
    status: str
    fields: Mapping[str, str] = field(default_factory=dict)
    lines: Sequence[str] = field(default_factory=tuple)
    elapsed_ms: float = 0.0


@dataclass(frozen=True)
class BenchmarkResult:
    command: str
    count: int
    success_count: int
    failure_count: int
    min_ms: float
    mean_ms: float
    p50_ms: float
    p95_ms: float
    max_ms: float
