#!/usr/bin/env python3
"""Generate and verify deterministic forward-NTT integration vectors.

The model uses canonical standard-domain coefficients and twiddles, matching the
current RTL datapath. Two independent implementations are compared:

1. the nested-loop reference structure;
2. the flattened scheduler transaction stream.

The committed input/output files are consumed by the SystemVerilog integration
testbench.
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

from generate_forward_ntt_schedule import build_schedule
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
    for item in build_schedule():
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


def write_or_check(path: Path, expected: str, check_only: bool) -> bool:
    if check_only:
        if not path.exists():
            print(f"ERROR: missing generated file: {path}", file=sys.stderr)
            return False
        actual = path.read_text(encoding="utf-8")
        if actual != expected:
            print(
                f"ERROR: generated file is stale: {path}\n"
                "Run: python3 software/reference/"
                "generate_forward_ntt_vectors.py --write",
                file=sys.stderr,
            )
            return False
        return True

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(expected, encoding="utf-8")
    print(f"WROTE: {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="regenerate vectors")
    mode.add_argument("--check", action="store_true", help="verify vectors")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
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

    targets = (
        (
            repo_root / "tb/vectors/forward_ntt_core_inputs.hex",
            render_hex(inputs),
        ),
        (
            repo_root / "tb/vectors/forward_ntt_core_expected.hex",
            render_hex(expected),
        ),
    )

    ok = all(write_or_check(path, text, args.check) for path, text in targets)
    if not ok:
        return 1

    action = "verified" if args.check else "generated"
    print(
        f"PASS: {action} {CASE_COUNT} forward-NTT vectors "
        f"({CASE_COUNT * N} coefficients); direct and flattened models agree"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
