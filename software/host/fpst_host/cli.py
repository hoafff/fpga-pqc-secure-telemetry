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
    # when it appears; if the board was already running and the old prompt was
    # lost before opening the port, the first real command is still valid.
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
    if args.action in {"zeroize", "reset"} and not _require_confirmation(args, args.action):
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


def _run_probe(args) -> int:
    transport, client = _open_client(args)
    try:
        results = [client.wiring(), client.status()]
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
        commands = ("wiring", "ping", "caps", "status")
        results = [client.command(command) for command in commands]
        if args.json:
            print(json.dumps([asdict(item) for item in results], ensure_ascii=False, indent=2))
        else:
            print("FPST host non-destructive bring-up")
            for result in results:
                print(
                    f"  {result.command:8s} {'PASS' if result.ok else 'FAIL':4s} "
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
    if args.command in {"zeroize", "reset"}:
        print("Destructive commands are not allowed in benchmark mode.", file=sys.stderr)
        return 2

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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fpst-host",
        description="FPST v1.1 PC deployment host for SONiX SN32F407F",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    ports = sub.add_parser("ports", help="list serial ports")
    ports.set_defaults(handler=lambda args: _list_ports(args.json))

    def add_serial_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--port", required=True, help="serial port, e.g. COM5 or /dev/ttyUSB0")
        p.add_argument("--baud", type=int, default=115200, help="default: 115200")
        p.add_argument("--timeout", type=float, default=2.0, help="command timeout in seconds")
        p.add_argument(
            "--sync-timeout",
            type=float,
            default=0.8,
            help="time to wait for a fresh MCU boot prompt after opening",
        )
        p.add_argument("--log", type=Path, help="append secret-safe JSONL results")

    probe = sub.add_parser("probe", help="check wiring/status through SN32")
    add_serial_args(probe)
    probe.set_defaults(handler=_run_probe)

    demo = sub.add_parser("demo", help="run non-destructive bring-up sequence")
    add_serial_args(demo)
    demo.set_defaults(handler=_run_demo)

    for action in sorted(Sn32CliClient.ALL_COMMANDS):
        cmd = sub.add_parser(action, help=f"send SN32 '{action}' command")
        add_serial_args(cmd)
        cmd.set_defaults(action=action, handler=_run_single)
        if action in {"zeroize", "reset"}:
            cmd.add_argument("--yes", action="store_true", help="confirm state-changing action")
        else:
            cmd.set_defaults(yes=False)

    bench = sub.add_parser("bench", help="benchmark a non-destructive SN32 command")
    add_serial_args(bench)
    bench.add_argument(
        "command",
        choices=sorted(Sn32CliClient.SAFE_COMMANDS - {"help"}),
        help="command to repeat",
    )
    bench.add_argument("--count", type=int, default=20)
    bench.set_defaults(handler=_run_benchmark)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (TransportError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
