from __future__ import annotations

import unittest
import zlib

from fpst_host.models import TransportReply
from fpst_host.protocol import Sn32CliClient


class FakeTransport:
    def __init__(self, replies: dict[str, str], kem_reply: str | None = None):
        self.replies = replies
        self.kem_reply = kem_reply
        self.kem_command: str | None = None
        self.kem_public_key: bytes | None = None

    def transact(self, command: str, timeout_s=None) -> TransportReply:
        return TransportReply(text=self.replies[command], elapsed_ms=1.25)

    def transact_kem_session(
        self, command: str, public_key: bytes, timeout_s=None
    ) -> TransportReply:
        self.kem_command = command
        self.kem_public_key = public_key
        if self.kem_reply is None:
            raise AssertionError("unexpected KEM session")
        return TransportReply(text=self.kem_reply, elapsed_ms=12.5)


class ProtocolTests(unittest.TestCase):
    def test_final_command_registry_matches_dual_mcu_cli(self):
        self.assertEqual(
            Sn32CliClient.READ_ONLY_COMMANDS,
            frozenset(
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
            ),
        )
        self.assertEqual(
            Sn32CliClient.STATE_CHANGING_COMMANDS,
            frozenset({"rng-reseed", "zeroize", "telemetry", "kem-session"}),
        )
        self.assertNotIn("caps", Sn32CliClient.ALL_COMMANDS)
        self.assertNotIn("reset", Sn32CliClient.ALL_COMMANDS)

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

    def test_blocked_command_is_not_false_positive(self):
        client = Sn32CliClient(
            FakeTransport({"status": "BLOCKED: two-Primer harness is not verified/initialized.\r\n"})
        )
        result = client.status()
        self.assertFalse(result.ok)
        self.assertTrue(result.status.startswith("BLOCKED:"))

    def test_unverified_wiring_is_failure(self):
        client = Sn32CliClient(FakeTransport({"wiring": "wiring=UNVERIFIED\r\n"}))
        result = client.wiring()
        self.assertFalse(result.ok)
        self.assertEqual(result.fields["wiring"], "UNVERIFIED")
        self.assertEqual(result.status, "UNVERIFIED")

    def test_verified_two_primer_wiring_is_success(self):
        client = Sn32CliClient(
            FakeTransport({"wiring": "wiring=verified-two-primer\r\n"})
        )
        result = client.wiring()
        self.assertTrue(result.ok)
        self.assertEqual(result.status, "verified-two-primer")

    def test_retained_telemetry_timeout_is_failure(self):
        client = Sn32CliClient(
            FakeTransport(
                {
                    "telemetry": (
                        "telemetry=RETRY_PENDING seq=0x0000000000000002\r\n"
                        "ERR code=0x00000005\r\n"
                    )
                }
            )
        )
        result = client.command("telemetry")
        self.assertFalse(result.ok)
        self.assertEqual(result.status, "ERR code=0x00000005")

    def test_final_status2_field_without_terminal_ok(self):
        client = Sn32CliClient(FakeTransport({"status2": "state2=0x00000002\r\n"}))
        result = client.status2()
        self.assertTrue(result.ok)
        self.assertEqual(result.fields["state2"], "0x00000002")

    def test_reject_unknown_host_command(self):
        client = Sn32CliClient(FakeTransport({}))
        with self.assertRaises(ValueError):
            client.command("stage-secret")

    def test_reject_plain_kem_session_command(self):
        client = Sn32CliClient(FakeTransport({}))
        with self.assertRaises(ValueError):
            client.command("kem-session")

    def test_interactive_kem_session_validates_ciphertext(self):
        public_key = bytes((i * 7) & 0xFF for i in range(800))
        ciphertext = bytes((i * 11 + 3) & 0xFF for i in range(768))
        session_id = 0x10203040
        ct_crc = zlib.crc32(ciphertext) & 0xFFFFFFFF
        reply = (
            "KEM_PK_READY bytes=800 encoding=hex\r\n"
            "KEM_PK_OK; establishing ML-KEM-512 P1-TX/P2-RX session...\r\n"
            f"KEM_CT_BEGIN session=0x{session_id:08X} len=0x0300 crc32=0x{ct_crc:08X}\r\n"
            f"KEM_CT_HEX={ciphertext.hex().upper()}\r\n"
            "KEM_CT_END\r\n"
            f"kem-pair-session=ACTIVE session=0x{session_id:08X} p1_seq=0 p2_expected=0\r\n"
        )
        transport = FakeTransport({}, kem_reply=reply)
        client = Sn32CliClient(transport)

        result, returned_ciphertext = client.establish_kem_session(
            public_key, session_id, timeout_s=120.0
        )

        self.assertTrue(result.ok)
        self.assertEqual(result.status, "ACTIVE")
        self.assertEqual(result.ciphertext_len, 768)
        self.assertEqual(result.ciphertext_crc32, ct_crc)
        self.assertEqual(returned_ciphertext, ciphertext)
        self.assertEqual(transport.kem_public_key, public_key)
        pk_crc = zlib.crc32(public_key) & 0xFFFFFFFF
        self.assertEqual(
            transport.kem_command,
            f"kem-session {session_id:08X} {pk_crc:08X}",
        )

    def test_interactive_kem_failure_is_reported(self):
        public_key = bytes(800)
        transport = FakeTransport(
            {},
            kem_reply=(
                "KEM_PK_READY bytes=800 encoding=hex\r\n"
                "kem-pair-session=FAILED ERR code=0x00000005\r\n"
            ),
        )
        result, ciphertext = Sn32CliClient(transport).establish_kem_session(
            public_key, 1
        )
        self.assertFalse(result.ok)
        self.assertEqual(ciphertext, b"")


if __name__ == "__main__":
    unittest.main()
