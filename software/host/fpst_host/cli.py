from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from .benchmark import benchmark_command
from .protocol import Sn32CliClient
from .result_log import JsonlResultLog
from .transport import SerialConfig, SerialTransport, TransportError, TransportTimeout


def _print_obj(obj, as_json: bool) -> None:
    data = asdict(obj)
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
        return
    for key, value in data.items():
        if key == "lines" and value:
            print(f"{key}:")
            for line in value:
                print(f"  {line}")
        elif key == "fields" and value:
            print(f"{key}:")
            for field_key, field_value in value.items():
                print(f"  {field_key}={field_value}")
        elif key == "ciphertext_crc32":
            print(f"{key}: 0x{value:08X}")
        elif key == "session_id":
            print(f"{key}: 0x{value:08X}")
        else:
            print(f"{key}: {value}")


def _list_ports(as_json: bool) -> int:
    try:
        from serial.tools import list_ports  # type: ignore
    except ImportError:
        print("pyserial is not installed", file=sys.stderr)
        return 2

    ports = [
        {
            "device": port.device,
            "description": port.description,
            "hwid": port.hwid,
        }
        for port in list_ports.comports()
    ]
    if as_json:
        print(json.dumps(ports, ensure_ascii=False, indent=2))
    elif not ports:
        print("No serial ports found.")
    else:
        for port in ports:
            print(f"{port['device']}: {port['description']} [{port['hwid']}]")
    return 0


def _open_client(args):
    transport = SerialTransport(
        SerialConfig(
            port=args.port,
            baudrate=args.baud,
            response_timeout_s=args.timeout,
        )
    )
    transport.open()
    # Opening a USB-UART adapter may reset the MCU. Consume a fresh boot prompt
    # when it appears; if the board is already running, the first command remains valid.
    try:
        transport.synchronize(timeout_s=args.sync_timeout)
    except TransportTimeout:
        pass
    return transport, Sn32CliClient(transport)


def _require_confirmation(args, action: str) -> bool:
    if args.yes:
        return True
    print(
        f"Refusing state-changing command '{action}' without --yes.",
        file=sys.stderr,
    )
    return False


def _run_single(args) -> int:
    if (
        args.action in Sn32CliClient.STATE_CHANGING_COMMANDS
        and not _require_confirmation(args, args.action)
    ):
        return 2

    transport, client = _open_client(args)
    try:
        result = client.command(args.action, timeout_s=args.timeout)
        _print_obj(result, args.json)
        if args.log:
            JsonlResultLog(args.log).append("command", result)
        return 0 if result.ok else 1
    finally:
        transport.close()


def _run_kem_session(args) -> int:
    if not _require_confirmation(args, "kem-session"):
        return 2

    public_key = args.public_key.read_bytes()
    transport, client = _open_client(args)
    try:
        result, ciphertext = client.establish_kem_session(
            public_key=public_key,
            session_id=args.session_id,
            timeout_s=args.timeout,
        )
        _print_obj(result, args.json)
        if args.log:
            JsonlResultLog(args.log).append("kem-session", result)
        if not result.ok:
            return 1
        args.ciphertext_out.parent.mkdir(parents=True, exist_ok=True)
        args.ciphertext_out.write_bytes(ciphertext)
        if not args.json:
            print(f"ciphertext_out: {args.ciphertext_out}")
        return 0
    finally:
        transport.close()


def _run_probe(args) -> int:
    transport, client = _open_client(args)
    try:
        results = [client.wiring(), client.status(), client.status2()]
        if args.json:
            print(json.dumps([asdict(item) for item in results], ensure_ascii=False, indent=2))
        else:
            for result in results:
                print(f"[{result.command}] {'PASS' if result.ok else 'FAIL'} ({result.elapsed_ms:.2f} ms)")
                for line in result.lines:
                    print(f"  {line}")
        if args.log:
            logger = JsonlResultLog(args.log)
            for result in results:
                logger.append("probe", result)
        return 0 if all(item.ok for item in results) else 1
    finally:
        transport.close()


def _run_demo(args) -> int:
    transport, client = _open_client(args)
    try:
        # FIX-008 acceptance sequence: match the final dual-Primer MCU CLI exactly.
        commands = ("wiring", "discover", "selftest", "status", "status2", "rng-status")
        results = [client.command(command, timeout_s=args.timeout) for command in commands]
        if args.json:
            print(json.dumps([asdict(item) for item in results], ensure_ascii=False, indent=2))
        else:
            print("FPST host non-destructive dual-Primer bring-up")
            for result in results:
                print(
                    f"  {result.command:12s} {'PASS' if result.ok else 'FAIL':4s} "
                    f"{result.elapsed_ms:8.2f} ms  {result.status}"
                )
        if args.log:
            logger = JsonlResultLog(args.log)
            for result in results:
                logger.append("demo", result)
        return 0 if all(item.ok for item in results) else 1
    finally:
        transport.close()


def _run_benchmark(args) -> int:
    transport, client = _open_client(args)
    try:
        result = benchmark_command(
            args.command,
            lambda: client.command(args.command, timeout_s=args.timeout),
            args.count,
        )
        _print_obj(result, args.json)
        if args.log:
            JsonlResultLog(args.log).append("benchmark", result)
        return 0 if result.failure_count == 0 else 1
    finally:
        transport.close()


def _parse_session_id(value: str) -> int:
    try:
        session_id = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("session ID must be decimal or 0x-prefixed") from exc
    if not 1 <= session_id <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError("session ID must be in 1..0xFFFFFFFF")
    return session_id


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fpst-host",
        description="FPST v1.1 PC deployment host for SONiX SN32F407F",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    ports = sub.add_parser("ports", help="list serial ports")
    ports.set_defaults(handler=lambda args: _list_ports(args.json))

    def add_serial_args(p: argparse.ArgumentParser, *, default_timeout: float = 2.0) -> None:
        p.add_argument("--port", required=True, help="serial port, e.g. COM5 or /dev/ttyUSB0")
        p.add_argument("--baud", type=int, default=115200, help="default: 115200")
        p.add_argument(
            "--timeout",
            type=float,
            default=default_timeout,
            help=f"command timeout in seconds (default: {default_timeout:g})",
        )
        p.add_argument(
            "--sync-timeout",
            type=float,
            default=0.8,
            help="time to wait for a fresh MCU boot prompt after opening",
        )
        p.add_argument("--log", type=Path, help="append secret-safe JSONL results")

    probe = sub.add_parser("probe", help="check wiring and both endpoint statuses")
    add_serial_args(probe)
    probe.set_defaults(handler=_run_probe)

    demo = sub.add_parser("demo", help="run final non-destructive dual-Primer bring-up")
    add_serial_args(demo)
    demo.set_defaults(handler=_run_demo)

    simple_commands = Sn32CliClient.ALL_COMMANDS - Sn32CliClient.INTERACTIVE_COMMANDS
    for action in sorted(simple_commands):
        cmd = sub.add_parser(action, help=f"send SN32 '{action}' command")
        add_serial_args(cmd)
        cmd.set_defaults(action=action, handler=_run_single)
        if action in Sn32CliClient.STATE_CHANGING_COMMANDS:
            cmd.add_argument("--yes", action="store_true", help="confirm state-changing action")
        else:
            cmd.set_defaults(yes=False)

    kem = sub.add_parser(
        "kem-session",
        help="provision P1 TX/P2 RX with ML-KEM-512 and save the public ciphertext",
    )
    add_serial_args(kem, default_timeout=120.0)
    kem.add_argument(
        "--public-key",
        required=True,
        type=Path,
        help="exactly 800-byte receiver ML-KEM-512 public key",
    )
    kem.add_argument(
        "--session-id",
        required=True,
        type=_parse_session_id,
        help="non-zero 32-bit session ID, decimal or 0x-prefixed",
    )
    kem.add_argument(
        "--ciphertext-out",
        required=True,
        type=Path,
        help="destination for the validated 768-byte public ML-KEM ciphertext",
    )
    kem.add_argument("--yes", action="store_true", help="confirm session provisioning")
    kem.set_defaults(handler=_run_kem_session)

    bench = sub.add_parser("bench", help="benchmark a read-only SN32 command")
    add_serial_args(bench)
    bench.add_argument(
        "command",
        choices=sorted(Sn32CliClient.READ_ONLY_COMMANDS - {"help"}),
        help="read-only command to repeat",
    )
    bench.add_argument("--count", type=int, default=20)
    bench.set_defaults(handler=_run_benchmark)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (TransportError, ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
