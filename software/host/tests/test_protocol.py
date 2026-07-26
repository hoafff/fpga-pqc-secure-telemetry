from __future__ import annotations

import unittest

from fpst_host.models import TransportReply
from fpst_host.protocol import Sn32CliClient


class FakeTransport:
    def __init__(self, replies: dict[str, str]):
        self.replies = replies

    def transact(self, command: str, timeout_s=None) -> TransportReply:
        return TransportReply(text=self.replies[command], elapsed_ms=1.25)


class ProtocolTests(unittest.TestCase):
    def test_ok_command(self):
        client = Sn32CliClient(FakeTransport({"ping": "OK\r\n"}))
        result = client.ping()
        self.assertTrue(result.ok)
        self.assertEqual(result.status, "OK")

    def test_error_command(self):
        client = Sn32CliClient(FakeTransport({"status": "ERR\r\n"}))
        result = client.status()
        self.assertFalse(result.ok)
        self.assertEqual(result.status, "ERR")

    def test_wiring_field(self):
        client = Sn32CliClient(FakeTransport({"wiring": "wiring=UNVERIFIED\r\n"}))
        result = client.wiring()
        self.assertTrue(result.ok)
        self.assertEqual(result.fields["wiring"], "UNVERIFIED")

    def test_forward_compatible_fields_before_ok(self):
        client = Sn32CliClient(
            FakeTransport({"status": "state=READY\r\nerror_code=0000\r\nOK\r\n"})
        )
        result = client.status()
        self.assertTrue(result.ok)
        self.assertEqual(result.fields["state"], "READY")
        self.assertEqual(result.fields["error_code"], "0000")

    def test_reject_unknown_host_command(self):
        client = Sn32CliClient(FakeTransport({}))
        with self.assertRaises(ValueError):
            client.command("stage-secret")


if __name__ == "__main__":
    unittest.main()
