#!/usr/bin/env python3
"""FPST SN32F407F ML-KEM-512 UART session bring-up helper.

Prefer ``fpst-host kem-session`` for the maintained deployment interface. This
standalone helper is retained for lab use and follows the same final dual-Primer
MCU framing.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import time
import zlib

try:
    import serial  # type: ignore
except ImportError as exc:  # pragma: no cover - user environment dependent
    raise SystemExit("pyserial is required: pip install pyserial") from exc

PK_BYTES = 800
CT_BYTES = 768
BAUD = 115200

CT_BEGIN_RE = re.compile(
    rb"^KEM_CT_BEGIN session=0x([0-9A-Fa-f]{8}) len=0x([0-9A-Fa-f]{4}) "
    rb"crc32=0x([0-9A-Fa-f]{8})$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Establish an FPST ML-KEM-512 P1-TX/P2-RX session over SN32 UART."
    )
    parser.add_argument("--port", required=True, help="Serial port, e.g. COM5 or /dev/ttyUSB0")
    parser.add_argument(
        "--public-key", required=True, type=pathlib.Path,
        help="800-byte receiver ML-KEM-512 public key",
    )
    parser.add_argument(
        "--session-id", required=True,
        help="Non-zero 32-bit session ID, decimal or 0x-prefixed",
    )
    parser.add_argument(
        "--ciphertext-out", required=True, type=pathlib.Path,
        help="Destination for the 768-byte ML-KEM ciphertext",
    )
    parser.add_argument(
        "--timeout", type=float, default=120.0,
        help="Overall response timeout in seconds (default: 120)",
    )
    return parser.parse_args()


def read_line(ser: serial.Serial, deadline: float) -> bytes:
    while time.monotonic() < deadline:
        line = ser.readline()
        if line:
            return line.strip(b"\r\n")
    raise TimeoutError("timed out waiting for SN32 UART response")


def wait_for_token(ser: serial.Serial, token: bytes, deadline: float) -> None:
    while True:
        line = read_line(ser, deadline)
        print(line.decode("ascii", errors="replace"))
        if token in line:
            return
        if b"BLOCKED:" in line or b"ERR code=" in line or b"REMOTE_ERR" in line:
            raise RuntimeError(line.decode("ascii", errors="replace"))


def main() -> int:
    args = parse_args()

    public_key = args.public_key.read_bytes()
    if len(public_key) != PK_BYTES:
        raise SystemExit(f"public key must be exactly {PK_BYTES} bytes, got {len(public_key)}")

    try:
        session_id = int(args.session_id, 0)
    except ValueError as exc:
        raise SystemExit("--session-id must be a valid 32-bit integer") from exc
    if not 1 <= session_id <= 0xFFFFFFFF:
        raise SystemExit("--session-id must be in 1..0xFFFFFFFF")

    public_key_crc = zlib.crc32(public_key) & 0xFFFFFFFF
    command = f"kem-session {session_id:08X} {public_key_crc:08X}\r\n".encode("ascii")

    deadline = time.monotonic() + args.timeout
    with serial.Serial(args.port, BAUD, timeout=0.25, write_timeout=5.0) as ser:
        ser.reset_input_buffer()
        ser.reset_output_buffer()

        print(f"TX: kem-session {session_id:08X} {public_key_crc:08X}")
        ser.write(command)
        ser.flush()
        wait_for_token(ser, b"KEM_PK_READY", deadline)

        encoded = public_key.hex().upper().encode("ascii") + b"\r\n"
        ser.write(encoded)
        ser.flush()

        begin_session = None
        expected_ct_crc = None
        ct_hex = None

        while time.monotonic() < deadline:
            line = read_line(ser, deadline)
            printable = line.decode("ascii", errors="replace")
            print(printable)

            if b"KEM_PK_CRC_FAIL" in line or b"KEM_PK_ABORT" in line:
                raise RuntimeError(printable)
            if b"kem-pair-session=FAILED" in line or b"REMOTE_ERR" in line:
                raise RuntimeError(printable)

            match = CT_BEGIN_RE.match(line)
            if match:
                begin_session = int(match.group(1), 16)
                ct_len = int(match.group(2), 16)
                expected_ct_crc = int(match.group(3), 16)
                if begin_session != session_id:
                    raise RuntimeError(
                        f"ciphertext session mismatch: expected 0x{session_id:08X}, "
                        f"got 0x{begin_session:08X}"
                    )
                if ct_len != CT_BYTES:
                    raise RuntimeError(
                        f"ciphertext length mismatch: expected {CT_BYTES}, got {ct_len}"
                    )
                continue

            if line.startswith(b"KEM_CT_HEX="):
                ct_hex = line[len(b"KEM_CT_HEX="):]
                continue

            if line == b"KEM_CT_END":
                break
        else:
            raise TimeoutError("timed out waiting for KEM_CT_END")

        if begin_session is None or expected_ct_crc is None or ct_hex is None:
            raise RuntimeError("incomplete ciphertext framing from SN32")
        if len(ct_hex) != 2 * CT_BYTES:
            raise RuntimeError(
                f"ciphertext hex length mismatch: expected {2 * CT_BYTES}, got {len(ct_hex)}"
            )

        try:
            ciphertext = bytes.fromhex(ct_hex.decode("ascii"))
        except ValueError as exc:
            raise RuntimeError("SN32 returned non-hex ciphertext data") from exc

        actual_ct_crc = zlib.crc32(ciphertext) & 0xFFFFFFFF
        if actual_ct_crc != expected_ct_crc:
            raise RuntimeError(
                f"ciphertext CRC mismatch: expected 0x{expected_ct_crc:08X}, "
                f"got 0x{actual_ct_crc:08X}"
            )

        # Final dual-Primer firmware acknowledges pair activation with this exact token.
        wait_for_token(ser, b"kem-pair-session=ACTIVE", deadline)

    args.ciphertext_out.write_bytes(ciphertext)
    print(
        f"PASS: session 0x{session_id:08X}, ciphertext {len(ciphertext)} bytes, "
        f"CRC32=0x{actual_ct_crc:08X} -> {args.ciphertext_out}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (TimeoutError, RuntimeError, serial.SerialException) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
