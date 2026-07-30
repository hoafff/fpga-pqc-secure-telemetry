from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

from .models import TransportReply


class TransportError(RuntimeError):
    """Base transport failure."""


class TransportTimeout(TransportError):
    """Raised when the SN32F407F response is not observed before the deadline."""


@dataclass
class SerialConfig:
    port: str
    baudrate: int = 115200
    read_timeout_s: float = 0.05
    response_timeout_s: float = 2.0


class SerialTransport:
    """UART transport for the final dual-Primer SN32F407F CLI.

    Normal commands are prompt-delimited. ``kem-session`` is intentionally
    different: the MCU first enters an 800-byte public-key input mode, emits
    ``KEM_PK_READY``, consumes 1600 hexadecimal digits, performs ML-KEM/session
    provisioning, and only then returns to the normal ``> `` prompt.
    """

    PROMPT = b"> "
    KEM_READY = b"KEM_PK_READY"

    def __init__(self, config: SerialConfig):
        self.config = config
        self._serial = None

    @property
    def is_open(self) -> bool:
        return bool(self._serial is not None and self._serial.is_open)

    def open(self) -> None:
        if self.is_open:
            return
        try:
            import serial  # type: ignore
        except ImportError as exc:
            raise TransportError(
                "pyserial is required for hardware access; install the host package first"
            ) from exc

        try:
            self._serial = serial.Serial(
                port=self.config.port,
                baudrate=self.config.baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=self.config.read_timeout_s,
                write_timeout=self.config.response_timeout_s,
            )
        except Exception as exc:  # pyserial uses backend-specific exceptions
            raise TransportError(f"cannot open serial port {self.config.port}: {exc}") from exc

    def close(self) -> None:
        if self._serial is not None:
            try:
                self._serial.close()
            finally:
                self._serial = None

    def __enter__(self) -> "SerialTransport":
        self.open()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def _write(self, payload: bytes) -> None:
        if not self.is_open:
            raise TransportError("serial transport is not open")
        try:
            self._serial.write(payload)
            self._serial.flush()
        except Exception as exc:
            raise TransportError(f"serial write failed: {exc}") from exc

    def _read_until_prompt(self, timeout_s: Optional[float] = None) -> str:
        if not self.is_open:
            raise TransportError("serial transport is not open")

        timeout = self.config.response_timeout_s if timeout_s is None else timeout_s
        deadline = time.monotonic() + timeout
        buf = bytearray()

        while time.monotonic() < deadline:
            chunk = self._serial.read(256)
            if chunk:
                buf.extend(chunk)
                data = bytes(buf)
                prompt_index = -1

                # Chỉ chấp nhận "> " nếu nó là prompt độc lập:
                # ở đầu buffer hoặc ở đầu một dòng mới.
                if data.startswith(self.PROMPT):
                    prompt_index = 0
                else:
                    for marker in (b"\r\n> ", b"\n> "):
                        index = data.find(marker)
                        if index >= 0:
                            prompt_index = index + len(marker) - len(self.PROMPT)
                            break

                if prompt_index >= 0:
                    return data[:prompt_index].decode("utf-8", errors="replace")
            else:
                time.sleep(0.002)

        preview = bytes(buf[-160:]).decode("utf-8", errors="replace")
        raise TransportTimeout(
            f"timeout waiting for SN32 prompt on {self.config.port}; received={preview!r}"
        )

    def _read_until_kem_ready(self, timeout_s: float) -> str:
        """Wait for the firmware to switch into public-key hex input mode."""
        if not self.is_open:
            raise TransportError("serial transport is not open")

        deadline = time.monotonic() + timeout_s
        buf = bytearray()
        while time.monotonic() < deadline:
            chunk = self._serial.read(256)
            if chunk:
                buf.extend(chunk)
                if self.KEM_READY in buf:
                    return bytes(buf).decode("utf-8", errors="replace")
                # A normal prompt before KEM_PK_READY means the command was
                # rejected and the MCU never entered the interactive mode.
                if self.PROMPT in buf:
                    preview = bytes(buf).decode("utf-8", errors="replace")
                    raise TransportError(
                        f"SN32 rejected kem-session before public-key input: {preview!r}"
                    )
            else:
                time.sleep(0.002)

        preview = bytes(buf[-160:]).decode("utf-8", errors="replace")
        raise TransportTimeout(
            f"timeout waiting for KEM_PK_READY on {self.config.port}; received={preview!r}"
        )

    def synchronize(self, timeout_s: float = 3.0) -> str:
        """Consume the boot banner/current output until the first prompt."""
        return self._read_until_prompt(timeout_s)

    def transact(self, command: str, timeout_s: Optional[float] = None) -> TransportReply:
        if not command or any(ch in command for ch in "\r\n"):
            raise ValueError("command must be one non-empty line")

        payload = (command + "\r\n").encode("ascii", errors="strict")
        start = time.perf_counter()
        self._write(payload)
        text = self._read_until_prompt(timeout_s)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        return TransportReply(text=text, elapsed_ms=elapsed_ms)

    def transact_kem_session(
        self,
        command: str,
        public_key: bytes,
        timeout_s: Optional[float] = None,
    ) -> TransportReply:
        """Execute the final MCU's two-stage ``kem-session`` UART exchange."""
        if not command.startswith("kem-session ") or any(ch in command for ch in "\r\n"):
            raise ValueError("kem-session command must be one complete command line")
        if not public_key:
            raise ValueError("public_key must not be empty")

        timeout = 120.0 if timeout_s is None else timeout_s
        if timeout <= 0:
            raise ValueError("timeout_s must be positive")

        started = time.perf_counter()
        deadline = time.monotonic() + timeout
        self._write((command + "\r\n").encode("ascii", errors="strict"))

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportTimeout("kem-session timed out before KEM_PK_READY")
        ready_text = self._read_until_kem_ready(remaining)

        # Hex is the exact console framing expected by fpst_sn32f407_dual_main.c.
        self._write(public_key.hex().upper().encode("ascii") + b"\r\n")

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportTimeout("kem-session timed out after public-key transfer")
        final_text = self._read_until_prompt(remaining)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        return TransportReply(
            text=ready_text + "\n" + final_text,
            elapsed_ms=elapsed_ms,
        )