from __future__ import annotations

from typing import Protocol

from .models import CommandResult, TransportReply


class CommandTransport(Protocol):
    def transact(self, command: str, timeout_s: float | None = None) -> TransportReply: ...


class Sn32CliClient:
    """Adapter for the line-oriented CLI currently implemented on SN32F407F.

    The parser deliberately accepts extra ``key=value`` lines before a final
    ``OK``/``ERR`` so the MCU can add machine-readable status fields without
    breaking this host application.
    """

    SAFE_COMMANDS = frozenset({"help", "wiring", "ping", "caps", "status"})
    STATE_CHANGING_COMMANDS = frozenset({"zeroize", "reset"})
    ALL_COMMANDS = SAFE_COMMANDS | STATE_CHANGING_COMMANDS

    def __init__(self, transport: CommandTransport):
        self.transport = transport

    @staticmethod
    def _normalize_lines(text: str) -> tuple[str, ...]:
        return tuple(
            line.strip()
            for line in text.replace("\r", "").split("\n")
            if line.strip()
        )

    @staticmethod
    def _parse_fields(lines: tuple[str, ...]) -> dict[str, str]:
        fields: dict[str, str] = {}
        for line in lines:
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key:
                fields[key] = value.strip()
        return fields

    def command(self, name: str, timeout_s: float | None = None) -> CommandResult:
        name = name.strip().lower()
        if name not in self.ALL_COMMANDS:
            raise ValueError(f"unsupported SN32 CLI command: {name}")

        reply = self.transport.transact(name, timeout_s)
        lines = self._normalize_lines(reply.text)
        fields = self._parse_fields(lines)

        status = lines[-1] if lines else "EMPTY"
        if status == "OK":
            ok = True
        elif status in {"ERR", "UNKNOWN"}:
            ok = False
        elif name == "wiring" and "wiring" in fields:
            ok = True
            status = fields["wiring"]
        elif name == "help" and lines:
            ok = True
            status = "OK"
        else:
            # Forward-compatible MCU responses may expose fields without an
            # explicit final OK. Treat those as syntactically valid replies.
            ok = bool(fields)

        return CommandResult(
            command=name,
            ok=ok,
            status=status,
            fields=fields,
            lines=lines,
            elapsed_ms=reply.elapsed_ms,
        )

    def wiring(self) -> CommandResult:
        return self.command("wiring")

    def ping(self) -> CommandResult:
        return self.command("ping")

    def caps(self) -> CommandResult:
        return self.command("caps")

    def status(self) -> CommandResult:
        return self.command("status")

    def zeroize(self) -> CommandResult:
        return self.command("zeroize")

    def reset(self) -> CommandResult:
        return self.command("reset")
