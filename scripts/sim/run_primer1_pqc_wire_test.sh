#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

# Icarus-specific build-time compatibility only. Production/Gowin/Yosys sources
# remain package-based and unmodified.
python3 - <<'PY'
from pathlib import Path

# Icarus copy-back corner case: a variable-indexed unpacked-array element cannot
# be passed reliably as the output of a nested automatic task. Receive into a
# scalar byte, then assign response[k] explicitly in the simulator-only copy.
src = Path("tb/integration/tb_primer1_deployment_pqc.sv").read_text()
src = src.replace(
    ".HEARTBEAT_BIT(8)",
    ".HEARTBEAT_TOGGLE_CYCLES(16)",
)
src = src.replace(
    "        integer response_payload_len;\n",
    "        integer response_payload_len;\n        logic [7:0] rx_byte;\n",
    1,
)
src = src.replace(
    "            for (k=0; k<10; k=k+1)\n                spi_recv_byte(response[k]);\n",
    "            for (k=0; k<10; k=k+1) begin\n                spi_recv_byte(rx_byte);\n                response[k] = rx_byte;\n            end\n",
    1,
)
src = src.replace(
    "            for (k=10; k<response_total; k=k+1)\n                spi_recv_byte(response[k]);\n",
    "            for (k=10; k<response_total; k=k+1) begin\n                spi_recv_byte(rx_byte);\n                response[k] = rx_byte;\n            end\n",
    1,
)
src = src.replace(
    '$fatal(1,"opcode %02x returned error flag",opcode);',
    '$fatal(1,"opcode %02x returned error flag status=%02x%02x detail=%02x%02x",opcode,response[10],response[11],response[12],response[13]);',
    1,
)
Path("build/sim/tb_primer1_deployment_pqc_iverilog.sv").write_text(src)
PY

# primer1_pqc_btp_endpoint.sv is a simulator compatibility wrapper. It adds an
# explicit compilation-unit import for OP_PQC_POLY_ADD_SUB before including the
# production package-based endpoint. This avoids an Icarus 12 wildcard-import
# bug without duplicating or changing the normative opcode in production RTL.
iverilog -g2012 -Wall -s tb_primer1_deployment_pqc \
    -o "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp" \
    rtl/transport/fpst_btp_pkg.sv \
    rtl/transport/btp_spi_slave.sv \
    rtl/transport/btp_request_parser.sv \
    rtl/transport/btp_response_builder.sv \
    rtl/session/primer1_session_context.sv \
    rtl/ascon/ascon_round.sv \
    rtl/ascon/ascon_permutation.sv \
    rtl/ascon/ascon_aead_encrypt.sv \
    rtl/telemetry/primer1_stp_tx.sv \
    rtl/arithmetic/mod_add.sv \
    rtl/arithmetic/mod_sub.sv \
    rtl/arithmetic/mod_mul_3329_pipe.sv \
    rtl/ntt/twiddle_rom_3329.sv \
    rtl/ntt/forward_ntt_scheduler.sv \
    rtl/ntt/inverse_ntt_scheduler.sv \
    rtl/ntt/ntt_intt_butterfly_pipe.sv \
    rtl/ntt/true_dual_port_ram_256x16.sv \
    rtl/ntt/coefficient_pingpong_memory_256x16.sv \
    rtl/ntt/mlkem_ntt_intt_core.sv \
    rtl/ntt/mlkem_basemul_sequential.sv \
    rtl/ntt/mlkem_pqc_accelerator.sv \
    rtl/boards/kiwi_primer_20k/forward_ntt_core_disabled.sv \
    rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv \
    rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv \
    rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint.sv \
    rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv \
    rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv \
    "${BUILD_DIR}/tb_primer1_deployment_pqc_iverilog.sv"

timeout 120s vvp "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp"
echo "PASS: complete Primer #1 PQC wire-level regression"
