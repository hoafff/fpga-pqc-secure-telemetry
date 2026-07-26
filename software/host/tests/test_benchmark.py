from __future__ import annotations

import unittest

from fpst_host.benchmark import benchmark_command
from fpst_host.models import CommandResult


class BenchmarkTests(unittest.TestCase):
    def test_statistics_and_failures(self):
        samples = iter(
            [
                CommandResult("ping", True, "OK", elapsed_ms=1.0),
                CommandResult("ping", False, "ERR", elapsed_ms=2.0),
                CommandResult("ping", True, "OK", elapsed_ms=3.0),
            ]
        )
        result = benchmark_command("ping", lambda: next(samples), 3)
        self.assertEqual(result.success_count, 2)
        self.assertEqual(result.failure_count, 1)
        self.assertEqual(result.min_ms, 1.0)
        self.assertEqual(result.max_ms, 3.0)
        self.assertAlmostEqual(result.mean_ms, 2.0)
        self.assertAlmostEqual(result.p50_ms, 2.0)

    def test_reject_zero_count(self):
        with self.assertRaises(ValueError):
            benchmark_command("ping", lambda: None, 0)


if __name__ == "__main__":
    unittest.main()
