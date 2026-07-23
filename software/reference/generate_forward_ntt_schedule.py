#!/usr/bin/env python3
"""Generate and verify the ML-KEM forward-NTT butterfly schedule.

The schedule follows the reference loop exactly:

    k = 1
    for length in (128, 64, 32, 16, 8, 4, 2):
        for start in range(0, 256, 2 * length):
            zeta = k
            k += 1
            for j in range(start, start + length):
                butterfly(j, j + length, zeta)

Each generated 40-bit word packs one butterfly transaction:

    [39:37] stage
    [36:29] length
    [28:21] left address
    [20:13] right address
    [12:6]  zeta ROM address
    [5]     group_first
    [4]     group_last
    [3]     stage_first
    [2]     stage_last
    [1]     transform_first
    [0]     transform_last
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

N = 256
LENGTHS = (128, 64, 32, 16, 8, 4, 2)
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "build" / "sim" / "forward_ntt_schedule.hex"


@dataclass(frozen=True)
class Transaction:
    stage: int
    length: int
    left: int
    right: int
    zeta_addr: int
    group_first: bool
    group_last: bool
    stage_first: bool
    stage_last: bool
    transform_first: bool
    transform_last: bool

    def pack(self) -> int:
        flags = (
            (int(self.group_first) << 5)
            | (int(self.group_last) << 4)
            | (int(self.stage_first) << 3)
            | (int(self.stage_last) << 2)
            | (int(self.transform_first) << 1)
            | int(self.transform_last)
        )
        return (
            (self.stage << 37)
            | (self.length << 29)
            | (self.left << 21)
            | (self.right << 13)
            | (self.zeta_addr << 6)
            | flags
        )


def generate_schedule() -> list[Transaction]:
    schedule: list[Transaction] = []
    zeta_addr = 1

    for stage, length in enumerate(LENGTHS):
        starts = range(0, N, 2 * length)
        for start in starts:
            group_zeta = zeta_addr
            zeta_addr += 1

            for left in range(start, start + length):
                right = left + length
                group_first = left == start
                group_last = left == start + length - 1
                stage_first = start == 0 and group_first
                stage_last = start + 2 * length == N and group_last
                transform_first = stage == 0 and stage_first
                transform_last = stage == len(LENGTHS) - 1 and stage_last

                schedule.append(
                    Transaction(
                        stage=stage,
                        length=length,
                        left=left,
                        right=right,
                        zeta_addr=group_zeta,
                        group_first=group_first,
                        group_last=group_last,
                        stage_first=stage_first,
                        stage_last=stage_last,
                        transform_first=transform_first,
                        transform_last=transform_last,
                    )
                )

    if zeta_addr != 128:
        raise AssertionError(f"expected final zeta cursor 128, got {zeta_addr}")
    return schedule


def validate_schedule(schedule: list[Transaction]) -> None:
    if len(schedule) != 896:
        raise AssertionError(f"expected 896 butterflies, got {len(schedule)}")

    if sum(t.transform_first for t in schedule) != 1:
        raise AssertionError("transform_first must occur exactly once")
    if sum(t.transform_last for t in schedule) != 1:
        raise AssertionError("transform_last must occur exactly once")

    for stage, length in enumerate(LENGTHS):
        stage_tx = [t for t in schedule if t.stage == stage]
        if len(stage_tx) != 128:
            raise AssertionError(
                f"stage {stage}: expected 128 butterflies, got {len(stage_tx)}"
            )
        if any(t.length != length for t in stage_tx):
            raise AssertionError(f"stage {stage}: unexpected length")

        touched = [t.left for t in stage_tx] + [t.right for t in stage_tx]
        if sorted(touched) != list(range(N)):
            raise AssertionError(f"stage {stage}: coefficient coverage is not 0..255")

        if sum(t.stage_first for t in stage_tx) != 1:
            raise AssertionError(f"stage {stage}: stage_first count is not one")
        if sum(t.stage_last for t in stage_tx) != 1:
            raise AssertionError(f"stage {stage}: stage_last count is not one")

        expected_zetas = list(range(1 << stage, 1 << (stage + 1)))
        actual_zetas: list[int] = []
        for t in stage_tx:
            if t.group_first:
                actual_zetas.append(t.zeta_addr)
        if actual_zetas != expected_zetas:
            raise AssertionError(
                f"stage {stage}: zeta addresses {actual_zetas} != {expected_zetas}"
            )

    for index, t in enumerate(schedule):
        if not (0 <= t.stage < 7):
            raise AssertionError(f"transaction {index}: invalid stage {t.stage}")
        if t.length not in LENGTHS:
            raise AssertionError(f"transaction {index}: invalid length {t.length}")
        if not (0 <= t.left < t.right < N):
            raise AssertionError(
                f"transaction {index}: invalid pair ({t.left}, {t.right})"
            )
        if t.right - t.left != t.length:
            raise AssertionError(
                f"transaction {index}: pair distance does not match length"
            )
        if not (1 <= t.zeta_addr <= 127):
            raise AssertionError(
                f"transaction {index}: invalid zeta address {t.zeta_addr}"
            )

    first = schedule[0]
    last = schedule[-1]
    if (first.stage, first.length, first.left, first.right, first.zeta_addr) != (
        0,
        128,
        0,
        128,
        1,
    ):
        raise AssertionError(f"unexpected first transaction: {first}")
    if (last.stage, last.length, last.left, last.right, last.zeta_addr) != (
        6,
        2,
        253,
        255,
        127,
    ):
        raise AssertionError(f"unexpected last transaction: {last}")


def render_hex(schedule: list[Transaction]) -> str:
    return "".join(f"{transaction.pack():010x}\n" for transaction in schedule)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    schedule = generate_schedule()
    validate_schedule(schedule)
    rendered = render_hex(schedule)

    if args.check:
        print(
            "PASS: forward NTT schedule verified: "
            "7 stages, 127 twiddle groups, 896 butterflies"
        )
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    print(f"wrote {len(schedule)} schedule entries to {args.output}")


if __name__ == "__main__":
    main()
