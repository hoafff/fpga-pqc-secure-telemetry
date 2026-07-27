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
class KemSessionResult:
    """Secret-safe summary of the interactive dual-Primer ML-KEM session flow.

    The public ML-KEM ciphertext is returned separately by the protocol client so
    normal JSON/result logging never serializes a large binary field by accident.
    """

    command: str
    ok: bool
    status: str
    session_id: int
    ciphertext_len: int = 0
    ciphertext_crc32: int = 0
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
