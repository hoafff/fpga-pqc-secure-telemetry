from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fpst_host.cli import _run_demo, build_parser
from fpst_host.models import CommandResult


class _FakeTransport:
    def close(self) -> None:
        pass


class _FakeClient:
    def __init__(self):
        self.commands: list[str] = []

    def command(self, name: str, timeout_s=None) -> CommandResult:
        self.commands.append(name)
        return CommandResult(
            command=name,
            ok=True,
            status="OK",
            lines=("OK",),
            elapsed_ms=1.0,
        )


class CliTests(unittest.TestCase):
    def test_demo_sequence_matches_fix_008_acceptance(self):
        client = _FakeClient()
        args = SimpleNamespace(timeout=2.0, json=False, log=None)
        with patch("fpst_host.cli._open_client", return_value=(_FakeTransport(), client)):
            self.assertEqual(_run_demo(args), 0)
        self.assertEqual(
            client.commands,
            ["wiring", "discover", "selftest", "status", "status2", "rng-status"],
        )

    def test_kem_session_has_dedicated_streaming_arguments(self):
        parser = build_parser()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            args = parser.parse_args(
                [
                    "kem-session",
                    "--port",
                    "COM5",
                    "--public-key",
                    str(root / "receiver.pk"),
                    "--session-id",
                    "0x10203040",
                    "--ciphertext-out",
                    str(root / "session.ct"),
                    "--yes",
                ]
            )
        self.assertEqual(args.session_id, 0x10203040)
        self.assertEqual(args.timeout, 120.0)
        self.assertTrue(args.yes)

    def test_removed_legacy_host_commands_are_not_parsers(self):
        parser = build_parser()
        for removed in ("caps", "reset"):
            with self.subTest(command=removed):
                with self.assertRaises(SystemExit):
                    parser.parse_args([removed, "--port", "COM5"])

    def test_state_changing_simple_commands_require_yes_option(self):
        parser = build_parser()
        for command in ("rng-reseed", "zeroize", "telemetry"):
            with self.subTest(command=command):
                args = parser.parse_args([command, "--port", "COM5", "--yes"])
                self.assertTrue(args.yes)


if __name__ == "__main__":
    unittest.main()
