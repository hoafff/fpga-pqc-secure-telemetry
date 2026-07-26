#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

python3 - <<'PY'
from pathlib import Path

# Icarus copy-back workaround for nested task -> variable-indexed array element.
src = Path("tb/integration/tb_primer1_deployment_pqc.sv").read_text()
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

# Diagnostic-only copy of the PQC endpoint. Show exactly what the case statement
# sees, including the imported package constants, without changing production RTL.
ep = Path("rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv").read_text()
needle = "                        end else begin\n                            case (request_opcode_i)\n"
replacement = "                        end else begin\n                            $display(\"P1DISPATCH opcode=%02x constants=%02x/%02x/%02x/%02x/%02x/%02x/%02x/%02x/%02x txid=%04x len=%0d\", request_opcode_i, OP_PQC_WRITE_COEFF, OP_PQC_READ_COEFF, OP_PQC_LOAD_POLY, OP_PQC_READ_POLY, OP_PQC_START_NTT, OP_PQC_START_INTT, OP_PQC_POINTWISE_MUL, OP_PQC_POLY_ADD_SUB, OP_PQC_GET_RESULT, request_transaction_id_i, request_payload_len_i);\n                            case (request_opcode_i)\n"
if needle not in ep:
    raise SystemExit("PQC dispatch insertion point not found")
ep = ep.replace(needle, replacement, 1)
ep = ep.replace(
    "                                default: begin\n                                    request_accept_o <= 1'b1;\n                                    queue_response(ERR_UNSUPPORTED_OPCODE,16'h0,RESP_GENERIC,16'd0,1'b1);\n                                end\n",
    "                                default: begin\n                                    $display(\"P1DISPATCH DEFAULT opcode=%02x poly_add_const=%02x\", request_opcode_i, OP_PQC_POLY_ADD_SUB);\n                                    request_accept_o <= 1'b1;\n                                    queue_response(ERR_UNSUPPORTED_OPCODE,16'h0,RESP_GENERIC,16'd0,1'b1);\n                                end\n",
    1,
)
Path("build/sim/primer1_pqc_btp_endpoint_trace.sv").write_text(ep)
PY

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
    "${BUILD_DIR}/primer1_pqc_btp_endpoint_trace.sv" \
    rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv \
    rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv \
    "${BUILD_DIR}/tb_primer1_deployment_pqc_iverilog.sv"

timeout 120s vvp "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp"
echo "PASS: complete Primer #1 PQC wire-level regression"
