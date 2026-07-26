from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

from .models import TransportReply


class TransportError(RuntimeError):
    """Base transport failure."""


class TransportTimeout(TransportError):
    """Raised when the SN32F407F prompt is not observed before the deadline."""


@dataclass
class SerialConfig:
    port: str
    baudrate: int = 115200
    read_timeout_s: float = 0.05
    response_timeout_s: float = 2.0


class SerialTransport:
    """Prompt-delimited UART transport for the current SN32F407F CLI.

    The firmware contract is UART0 115200 8N1 and emits a ``> `` prompt after
    boot and after every command. pyserial is imported lazily so protocol unit
    tests do not require a serial device or pyserial installation.
    """

    PROMPT = b"> "

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
        except Exception as exc:  # pyserial uses several backend-specific exceptions
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
                if self.PROMPT in buf:
                    before_prompt = bytes(buf).split(self.PROMPT, 1)[0]
                    return before_prompt.decode("utf-8", errors="replace")
            else:
                time.sleep(0.002)

        preview = bytes(buf[-160:]).decode("utf-8", errors="replace")
        raise TransportTimeout(
            f"timeout waiting for SN32 prompt on {self.config.port}; received={preview!r}"
        )

    def synchronize(self, timeout_s: float = 3.0) -> str:
        """Consume the boot banner/current output until the first prompt."""
        return self._read_until_prompt(timeout_s)

    def transact(self, command: str, timeout_s: Optional[float] = None) -> TransportReply:
        if not self.is_open:
            raise TransportError("serial transport is not open")
        if not command or any(ch in command for ch in "\r\n"):
            raise ValueError("command must be one non-empty line")

        payload = (command + "\r\n").encode("ascii", errors="strict")
        start = time.perf_counter()
        try:
            self._serial.write(payload)
            self._serial.flush()
        except Exception as exc:
            raise TransportError(f"serial write failed: {exc}") from exc

        text = self._read_until_prompt(timeout_s)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        return TransportReply(text=text, elapsed_ms=elapsed_ms)
