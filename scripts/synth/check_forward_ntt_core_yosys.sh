#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
MEMORY_LOG="${BUILD_DIR}/yosys-forward-ntt-memory.log"
SYNTH_LOG="${BUILD_DIR}/yosys-forward-ntt-core.log"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

RTL_SOURCES="
    rtl/arithmetic/mod_add.sv
    rtl/arithmetic/mod_sub.sv
    rtl/arithmetic/mod_mul_3329_pipe.sv
    rtl/ntt/ntt_butterfly_pipe.sv
    rtl/ntt/twiddle_rom_3329.sv
    rtl/ntt/forward_ntt_scheduler.sv
    rtl/ntt/true_dual_port_ram_256x16.sv
    rtl/ntt/coefficient_pingpong_memory_256x16.sv
    rtl/ntt/forward_ntt_core.sv
"

# Stop before generic memory mapping and require exactly two collected memory
# cells. This proves that the two 256x16 coefficient banks survive RTL lowering
# as memories instead of becoming thousands of flip-flops and muxes.
yosys -ql "${MEMORY_LOG}" -p "
    read_verilog -sv -DSYNTHESIS ${RTL_SOURCES};
    hierarchy -check -top forward_ntt_core;
    proc;
    opt;
    memory_dff;
    memory_collect;
    select -assert-count 2 t:\$mem_v2;
    select -clear;
    check;
    stat;
"

# Also run a complete technology-independent synthesis to catch hierarchy,
# driver and lowering failures. The resulting generic cell count is not an FPGA
# utilization estimate.
yosys -ql "${SYNTH_LOG}" -p "
    read_verilog -sv -DSYNTHESIS ${RTL_SOURCES};
    hierarchy -check -top forward_ntt_core;
    synth -top forward_ntt_core;
    check;
    stat;
"

cat "${MEMORY_LOG}"
cat "${SYNTH_LOG}"
echo "PASS: Yosys preserved two coefficient memories and synthesized forward_ntt_core"
