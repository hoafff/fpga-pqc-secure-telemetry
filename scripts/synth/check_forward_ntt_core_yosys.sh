#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
MEMORY_LOG="${BUILD_DIR}/yosys-forward-ntt-memory.log"
SYNTH_LOG="${BUILD_DIR}/yosys-forward-ntt-core.log"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

READ_RTL="read_verilog -sv -DSYNTHESIS \
rtl/arithmetic/mod_add.sv \
rtl/arithmetic/mod_sub.sv \
rtl/arithmetic/mod_mul_3329_pipe.sv \
rtl/ntt/ntt_butterfly_pipe.sv \
rtl/ntt/twiddle_rom_3329.sv \
rtl/ntt/forward_ntt_scheduler.sv \
rtl/ntt/true_dual_port_ram_256x16.sv \
rtl/ntt/coefficient_pingpong_memory_256x16.sv \
rtl/ntt/forward_ntt_core.sv"

# The hierarchy intentionally keeps the RAM implementation as a reusable module,
# so Yosys stores one memory object in the module definition and instantiates the
# module twice. Assert both facts instead of counting every memory in the design;
# the metadata FIFO and twiddle ROM are also valid inferred memories.
yosys -ql "${MEMORY_LOG}" -p "
    ${READ_RTL};
    hierarchy -check -top forward_ntt_core;
    select -assert-count 2 t:true_dual_port_ram_256x16;
    select -clear;
    proc;
    opt;
    memory_dff;
    memory_collect;
    select -assert-count 1 true_dual_port_ram_256x16/memory;
    select -clear;
    check;
    stat;
"

# Also run a complete technology-independent synthesis to catch hierarchy,
# driver and lowering failures. The resulting generic cell count is not an FPGA
# utilization estimate.
yosys -ql "${SYNTH_LOG}" -p "
    ${READ_RTL};
    hierarchy -check -top forward_ntt_core;
    synth -top forward_ntt_core;
    check;
    stat;
"

cat "${MEMORY_LOG}"
cat "${SYNTH_LOG}"
echo "PASS: Yosys inferred the RAM module, found two bank instances and synthesized forward_ntt_core"
