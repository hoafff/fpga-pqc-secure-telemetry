#!/usr/bin/env python3
"""Generate and verify deterministic forward-NTT integration vectors.

The model uses canonical standard-domain coefficients and twiddles, matching the
current RTL datapath. Two independent implementations are compared:

1. the nested-loop reference structure;
2. the flattened scheduler transaction stream.

The SystemVerilog integration testbench consumes build-time vector files emitted
with ``--output-dir``. CI also runs ``--check`` to exercise both software models
without depending on committed generated data.
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

from generate_forward_ntt_schedule import generate_schedule
from generate_twiddles_3329 import Q, derive_standard_twiddles

N = 256
CASE_COUNT = 5
SEED = 0x4D4C4B45


def forward_ntt_direct(
    coefficients: list[int], twiddles: tuple[int, ...]
) -> list[int]:
    """Reference nested-loop forward NTT in canonical standard domain."""
    if len(coefficients) != N:
        raise ValueError(f"expected {N} coefficients")

    values = [value % Q for value in coefficients]
    k = 1

    for length in (128, 64, 32, 16, 8, 4, 2):
        start = 0
        while start < N:
            zeta = twiddles[k]
            k += 1
            for left in range(start, start + length):
                right = left + length
                t = (values[right] * zeta) % Q
                a = values[left]
                values[left] = (a + t) % Q
                values[right] = (a - t) % Q
            start += 2 * length

    if k != 128:
        raise AssertionError(f"unexpected terminal twiddle index: {k}")
    return values


def forward_ntt_flat(
    coefficients: list[int], twiddles: tuple[int, ...]
) -> list[int]:
    """Apply the independently generated flattened scheduler stream."""
    values = [value % Q for value in coefficients]
    for item in generate_schedule():
        left = item.left
        right = item.right
        t = (values[right] * twiddles[item.zeta_addr]) % Q
        a = values[left]
        values[left] = (a + t) % Q
        values[right] = (a - t) % Q
    return values


def build_cases() -> list[list[int]]:
    rng = random.Random(SEED)
    cases = [
        [0] * N,
        [1] + [0] * (N - 1),
        [index % Q for index in range(N)],
        [((index * index) + (17 * index) + 3) % Q for index in range(N)],
        [rng.randrange(Q) for _ in range(N)],
    ]
    if len(cases) != CASE_COUNT:
        raise AssertionError("case-count mismatch")
    return cases


def render_hex(vectors: list[list[int]]) -> str:
    return "".join(f"{value:04x}\n" for vector in vectors for value in vector)


def build_and_cross_check() -> tuple[list[list[int]], list[list[int]]]:
    twiddles = derive_standard_twiddles()
    inputs = build_cases()
    expected: list[list[int]] = []

    for case_index, vector in enumerate(inputs):
        direct = forward_ntt_direct(vector, twiddles)
        flattened = forward_ntt_flat(vector, twiddles)
        if direct != flattened:
            mismatch = next(
                index
                for index, pair in enumerate(zip(direct, flattened))
                if pair[0] != pair[1]
            )
            raise AssertionError(
                f"model mismatch case={case_index} coefficient={mismatch}: "
                f"direct={direct[mismatch]} flat={flattened[mismatch]}"
            )
        if any(not 0 <= value < Q for value in direct):
            raise AssertionError(f"non-canonical output in case {case_index}")
        expected.append(direct)

    return inputs, expected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="cross-check the two software models",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="write build-time input and expected-output hex files",
    )
    args = parser.parse_args()

    if not args.check and args.output_dir is None:
        parser.error("specify --check and/or --output-dir")

    inputs, expected = build_and_cross_check()

    if args.output_dir is not None:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        input_path = args.output_dir / "forward_ntt_core_inputs.hex"
        expected_path = args.output_dir / "forward_ntt_core_expected.hex"
        input_path.write_text(render_hex(inputs), encoding="utf-8")
        expected_path.write_text(render_hex(expected), encoding="utf-8")
        print(f"WROTE: {input_path}")
        print(f"WROTE: {expected_path}")

    print(
        f"PASS: verified {CASE_COUNT} forward-NTT vectors "
        f"({CASE_COUNT * N} coefficients); direct and flattened models agree"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
