#!/usr/bin/env python3
"""Static source/CST gate for the Tiny J1-9 open-drain contract."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[3]
TOP = ROOT / "targets/tiny1p5/rtl/supervisor_top.sv"
CORE = ROOT / "rtl/supervisor/fpst_supervisor_core.sv"
CST = ROOT / "targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


top = TOP.read_text(encoding="utf-8")
core = CORE.read_text(encoding="utf-8")
cst = CST.read_text(encoding="utf-8")

assignments = re.findall(r"\bassign\s+tiny_fault_no\s*=\s*([^;]+);", top)
if assignments != ["tiny_fault_drive_low_w ? 1'b0 : 1'bz"]:
    fail(f"expected one exact 0/Z driver, found {assignments!r}")

if re.search(r"\btiny_fault_no\s*(?:<=|=)\s*1'b1", top):
    fail("RTL contains a direct HIGH drive for tiny_fault_no")

for retired in ("system_reset_no", "RESET_PULSE_MS", "RESET_ON_FATAL"):
    if retired in top or retired in core:
        fail(f"retired Tiny reset symbol remains in active RTL: {retired}")

pin_bindings = re.findall(r'^IO_LOC\s+"([^"]+)"\s+12\s*;', cst, re.MULTILINE)
if pin_bindings != ["tiny_fault_no"]:
    fail(f"FPGA pin 12 must bind only tiny_fault_no, found {pin_bindings!r}")

port_lines = re.findall(r'^IO_PORT\s+"tiny_fault_no"\s+([^;]+);', cst, re.MULTILINE)
if len(port_lines) != 1:
    fail(f"expected one Tiny_FAULT_N IO_PORT constraint, found {len(port_lines)}")

attributes = port_lines[0]
for required in ("IO_TYPE=LVCMOS33", "OPEN_DRAIN=ON", "PULL_MODE=NONE"):
    if required not in attributes:
        fail(f"Tiny_FAULT_N constraint is missing {required}")
if "DRIVE=" in attributes or "PULL_MODE=UP" in attributes:
    fail("Tiny_FAULT_N constraint enables a forbidden drive/pull attribute")

print("PASS: Tiny J1-9 static contract (single 0/Z driver, open drain, no pull)")
