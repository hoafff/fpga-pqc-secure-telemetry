from __future__ import annotations

import json
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


_SENSITIVE_TOKENS = (
    "secret",
    "private",
    "key",
    "seed",
    "password",
    "token",
)


def _redact(value: Any, key: str = "") -> Any:
    key_lower = key.lower()
    if any(token in key_lower for token in _SENSITIVE_TOKENS):
        return "<redacted>"
    if is_dataclass(value):
        value = asdict(value)
    if isinstance(value, dict):
        return {str(k): _redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_redact(item) for item in value]
    return value


class JsonlResultLog:
    """Append-only result log that refuses to persist obvious secret fields."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def append(self, kind: str, payload: Any) -> None:
        record = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "kind": kind,
            "payload": _redact(payload),
        }
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
