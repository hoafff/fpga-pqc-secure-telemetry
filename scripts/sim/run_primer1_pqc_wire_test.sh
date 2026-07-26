#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

# Temporary diagnostic copy. This does not change the architected testbench;
# it exposes only the first response bits and internal SPI indices when a wire
# regression fails, making CDC/transaction-boundary faults actionable in CI.
python3 - <<'PY'
from pathlib import Path
src = Path("tb/integration/tb_primer1_deployment_pqc.sv").read_text()
src = src.replace(
    '$fatal(1,"bad response header for opcode %02x",opcode);',
    '$fatal(1,"bad response header for opcode %02x got=%02x %02x %02x %02x flags=%02x rlen=%02x%02x",opcode,response[0],response[1],response[2],response[3],response[4],response[8],response[9]);'
)
trace = r'''
    integer p1_spi_trace_count;
    always @(negedge spi_cs_n) begin
        p1_spi_trace_count = 0;
        $display("P1SPITRACE cs_fall t=%0t ready=%0b done=%0b byte=%0d bit=%0d mem0=%02x mem1=%02x",
                 $time,
                 dut.u_btp_spi_slave.tx_ready_q,
                 dut.u_btp_spi_slave.tx_done_sck_q,
                 dut.u_btp_spi_slave.tx_byte_q,
                 dut.u_btp_spi_slave.tx_bit_q,
                 dut.u_btp_spi_slave.tx_mem[0],
                 dut.u_btp_spi_slave.tx_mem[1]);
    end
    always @(posedge spi_sck) begin
        if (dut.u_btp_spi_slave.tx_ready_q && p1_spi_trace_count < 16) begin
            $display("P1SPITRACE sck_rise t=%0t n=%0d miso=%0b ready=%0b done=%0b byte=%0d bit=%0d",
                     $time, p1_spi_trace_count, spi_miso,
                     dut.u_btp_spi_slave.tx_ready_q,
                     dut.u_btp_spi_slave.tx_done_sck_q,
                     dut.u_btp_spi_slave.tx_byte_q,
                     dut.u_btp_spi_slave.tx_bit_q);
            p1_spi_trace_count = p1_spi_trace_count + 1;
        end
    end
'''
pos = src.rfind("endmodule")
if pos < 0:
    raise SystemExit("endmodule not found in PQC wire test")
src = src[:pos] + trace + src[pos:]
Path("build/sim/tb_primer1_deployment_pqc_trace.sv").write_text(src)
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
    rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv \
    rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv \
    rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv \
    "${BUILD_DIR}/tb_primer1_deployment_pqc_trace.sv"

timeout 120s vvp "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp"
echo "PASS: complete Primer #1 PQC wire-level regression"
