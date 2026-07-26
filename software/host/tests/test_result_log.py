from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from fpst_host.result_log import JsonlResultLog


class ResultLogTests(unittest.TestCase):
    def test_sensitive_field_names_are_redacted(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "result.jsonl"
            logger = JsonlResultLog(path)
            logger.append(
                "test",
                {
                    "status": "OK",
                    "shared_secret": "must-not-appear",
                    "session_key": "must-not-appear-either",
                },
            )
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("must-not-appear", text)
            record = json.loads(text)
            self.assertEqual(record["payload"]["status"], "OK")
            self.assertEqual(record["payload"]["shared_secret"], "<redacted>")
            self.assertEqual(record["payload"]["session_key"], "<redacted>")


if __name__ == "__main__":
    unittest.main()
