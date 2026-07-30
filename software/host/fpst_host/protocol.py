from __future__ import annotations

import re
import zlib
from typing import Protocol

from .models import CommandResult, KemSessionResult, TransportReply


class CommandTransport(Protocol):
    def transact(self, command: str, timeout_s: float | None = None) -> TransportReply: ...

    def transact_kem_session(
        self,
        command: str,
        public_key: bytes,
        timeout_s: float | None = None,
    ) -> TransportReply: ...


_KEM_BEGIN_RE = re.compile(
    r"^KEM_CT_BEGIN session=0x([0-9A-Fa-f]{8}) len=0x([0-9A-Fa-f]{4}) "
    r"crc32=0x([0-9A-Fa-f]{8})$"
)
_KEM_ACTIVE_RE = re.compile(
    r"^kem-pair-session=ACTIVE session=0x([0-9A-Fa-f]{8})\b"
)


class Sn32CliClient:
    """Adapter for the final line-oriented dual-Primer SN32F407F CLI.

    The command registry below intentionally mirrors ``handle_command()`` in
    ``fpst_sn32f407_dual_main.c``. ``kem-session`` is not a normal prompt-only
    command: it requires a second 800-byte public-key transfer and dedicated
    result validation.
    """

    READ_ONLY_COMMANDS = frozenset(
        {
            "help",
            "wiring",
            "ping",
            "ping2",
            "discover",
            "selftest",
            "id",
            "id2",
            "status",
            "status2",
            "key-status",
            "key-status2",
            "pqc-status",
            "rx-counters",
            "adc",
            "rng-status",
            "fault",
        }
    )
    SIMPLE_STATE_CHANGING_COMMANDS = frozenset(
        {"rng-reseed", "zeroize", "telemetry"}
    )
    INTERACTIVE_COMMANDS = frozenset({"kem-session"})
    STATE_CHANGING_COMMANDS = SIMPLE_STATE_CHANGING_COMMANDS | INTERACTIVE_COMMANDS
    SAFE_COMMANDS = READ_ONLY_COMMANDS
    ALL_COMMANDS = READ_ONLY_COMMANDS | STATE_CHANGING_COMMANDS

    MLKEM512_PUBLIC_KEY_BYTES = 800
    MLKEM512_CIPHERTEXT_BYTES = 768

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
        if name in self.INTERACTIVE_COMMANDS:
            raise ValueError(
                "kem-session is interactive; use establish_kem_session() with an 800-byte public key"
            )

        reply = self.transport.transact(name, timeout_s)
        lines = self._normalize_lines(reply.text)
        fields = self._parse_fields(lines)

        status = lines[-1] if lines else "EMPTY"
        if status == "OK":
            ok = True
        elif (
            status in {"ERR", "UNKNOWN"}
            or status.startswith(("ERR code=", "REMOTE_ERR", "BLOCKED:", "code=0x"))
        ):
            ok = False
        elif any(
            line.startswith(("ERR code=", "REMOTE_ERR", "BLOCKED:", "code=0x"))
            for line in lines
        ):
            ok = False
            status = next(
                line
                for line in lines
                if line.startswith(("ERR code=", "REMOTE_ERR", "BLOCKED:", "code=0x"))
            )
        elif name == "wiring" and "wiring" in fields:
            ok = True
            status = fields["wiring"]
        elif name == "help" and lines:
            ok = True
            status = "OK"
        else:
            # Most final dual-MCU diagnostics return machine-readable fields and
            # then the prompt, without a redundant terminal "OK" line.
            ok = bool(fields)

        return CommandResult(
            command=name,
            ok=ok,
            status=status,
            fields=fields,
            lines=lines,
            elapsed_ms=reply.elapsed_ms,
        )

    def establish_kem_session(
        self,
        public_key: bytes,
        session_id: int,
        timeout_s: float | None = 120.0,
    ) -> tuple[KemSessionResult, bytes]:
        """Provision P1 TX + P2 RX using the MCU's interactive ML-KEM flow."""
        if len(public_key) != self.MLKEM512_PUBLIC_KEY_BYTES:
            raise ValueError(
                f"public key must be exactly {self.MLKEM512_PUBLIC_KEY_BYTES} bytes, "
                f"got {len(public_key)}"
            )
        if not 1 <= session_id <= 0xFFFFFFFF:
            raise ValueError("session_id must be in 1..0xFFFFFFFF")

        public_key_crc = zlib.crc32(public_key) & 0xFFFFFFFF
        command = f"kem-session {session_id:08X} {public_key_crc:08X}"
        reply = self.transport.transact_kem_session(command, public_key, timeout_s)
        lines = self._normalize_lines(reply.text)

        failure = next(
            (
                line
                for line in lines
                if line.startswith(
                    (
                        "KEM_PK_CRC_FAIL",
                        "KEM_PK_ABORT",
                        "kem-pair-session=FAILED",
                        "REMOTE_ERR",
                        "ERR code=",
                        "BLOCKED:",
                    )
                )
            ),
            None,
        )
        if failure is not None:
            return (
                KemSessionResult(
                    command="kem-session",
                    ok=False,
                    status=failure,
                    session_id=session_id,
                    lines=lines,
                    elapsed_ms=reply.elapsed_ms,
                ),
                b"",
            )

        begin_session: int | None = None
        expected_len: int | None = None
        expected_crc: int | None = None
        ct_hex: str | None = None
        saw_end = False
        active_session: int | None = None

        for line in lines:
            match = _KEM_BEGIN_RE.match(line)
            if match:
                begin_session = int(match.group(1), 16)
                expected_len = int(match.group(2), 16)
                expected_crc = int(match.group(3), 16)
                continue
            if line.startswith("KEM_CT_HEX="):
                ct_hex = line[len("KEM_CT_HEX=") :]
                continue
            if line == "KEM_CT_END":
                saw_end = True
                continue
            match = _KEM_ACTIVE_RE.match(line)
            if match:
                active_session = int(match.group(1), 16)

        if begin_session != session_id or active_session != session_id:
            raise ValueError(
                "SN32 KEM session identity mismatch or missing ACTIVE acknowledgement"
            )
        if expected_len != self.MLKEM512_CIPHERTEXT_BYTES:
            raise ValueError(
                f"SN32 ciphertext length field must be {self.MLKEM512_CIPHERTEXT_BYTES}"
            )
        if expected_crc is None or ct_hex is None or not saw_end:
            raise ValueError("incomplete KEM ciphertext framing from SN32")
        if len(ct_hex) != 2 * self.MLKEM512_CIPHERTEXT_BYTES:
            raise ValueError("SN32 returned an invalid ciphertext hex length")

        try:
            ciphertext = bytes.fromhex(ct_hex)
        except ValueError as exc:
            raise ValueError("SN32 returned non-hex ciphertext data") from exc

        actual_crc = zlib.crc32(ciphertext) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(
                f"SN32 ciphertext CRC mismatch: expected 0x{expected_crc:08X}, "
                f"got 0x{actual_crc:08X}"
            )

        return (
            KemSessionResult(
                command="kem-session",
                ok=True,
                status="ACTIVE",
                session_id=session_id,
                ciphertext_len=len(ciphertext),
                ciphertext_crc32=actual_crc,
                lines=lines,
                elapsed_ms=reply.elapsed_ms,
            ),
            ciphertext,
        )

    def wiring(self) -> CommandResult:
        return self.command("wiring")

    def ping(self) -> CommandResult:
        return self.command("ping")

    def status(self) -> CommandResult:
        return self.command("status")

    def status2(self) -> CommandResult:
        return self.command("status2")

    def zeroize(self) -> CommandResult:
        return self.command("zeroize")
