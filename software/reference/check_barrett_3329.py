#!/usr/bin/env python3
"""Exhaustive arithmetic check for the q=3329 Barrett reducer.

This verifies the exact reduction method used by rtl/arithmetic/mod_mul_3329.sv
for every possible canonical ML-KEM product x in [0, (q-1)^2].
"""

from __future__ import annotations

import random

Q = 3329
BARRETT_SHIFT = 24
BARRETT_MU = 5039


def barrett_reduce_3329(x: int) -> int:
    """Reduce a canonical coefficient product modulo 3329."""
    q_hat = (x * BARRETT_MU) >> BARRETT_SHIFT
    remainder = x - q_hat * Q
    if remainder >= Q:
        remainder -= Q
    return remainder


def check_reducer_exhaustive() -> int:
    max_product = (Q - 1) * (Q - 1)

    for x in range(max_product + 1):
        actual = barrett_reduce_3329(x)
        expected = x % Q
        if actual != expected:
            raise AssertionError(
                f"Barrett mismatch at x={x}: actual={actual}, expected={expected}"
            )

    return max_product + 1


def check_butterfly_random(case_count: int = 100_000) -> int:
    rng = random.Random(0x13579BDF)

    for _ in range(case_count):
        a = rng.randrange(Q)
        b = rng.randrange(Q)
        zeta = rng.randrange(Q)

        t = barrett_reduce_3329(b * zeta)
        a_out = a + t
        if a_out >= Q:
            a_out -= Q
        b_out = a - t if a >= t else a + Q - t

        expected_t = (b * zeta) % Q
        expected_a = (a + expected_t) % Q
        expected_b = (a - expected_t) % Q

        if (t, a_out, b_out) != (expected_t, expected_a, expected_b):
            raise AssertionError(
                "Butterfly mismatch: "
                f"a={a}, b={b}, zeta={zeta}, "
                f"actual={(t, a_out, b_out)}, "
                f"expected={(expected_t, expected_a, expected_b)}"
            )

    return case_count


def main() -> None:
    reducer_cases = check_reducer_exhaustive()
    butterfly_cases = check_butterfly_random()

    print(
        "PASS: Barrett q=3329 verified for "
        f"{reducer_cases:,} product values"
    )
    print(
        "PASS: butterfly arithmetic verified for "
        f"{butterfly_cases:,} deterministic random cases"
    )


if __name__ == "__main__":
    main()
