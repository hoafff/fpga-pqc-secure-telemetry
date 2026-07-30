#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

python3 "${ROOT_DIR}/software/reference/generate_forward_ntt_schedule.py" \
    --output "${BUILD_DIR}/forward_ntt_schedule.hex"

python3 "${ROOT_DIR}/software/reference/generate_forward_ntt_vectors.py" \
    --output-dir "${BUILD_DIR}"

run_test() {
    local top="$1"
    shift

    echo "==> Running ${top}"
    iverilog -g2012 -Wall -s "${top}" \
        -o "${BUILD_DIR}/${top}.vvp" \
        "$@"
    timeout 60s vvp "${BUILD_DIR}/${top}.vvp"
}

run_test tb_mod_arithmetic \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_arithmetic.sv"

run_test tb_mod_mul_3329 \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_mul_3329.sv"

run_test tb_ntt_butterfly \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329.sv" \
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly.sv" \
    "${ROOT_DIR}/tb/unit/tb_ntt_butterfly.sv"

run_test tb_mod_mul_3329_pipe \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_mul_3329_pipe.sv"

run_test tb_ntt_butterfly_pipe \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv" \
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly_pipe.sv" \
    "${ROOT_DIR}/tb/unit/tb_ntt_butterfly_pipe.sv"

run_test tb_twiddle_rom_3329 \
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv" \
    "${ROOT_DIR}/tb/unit/tb_twiddle_rom_3329.sv"

run_test tb_forward_ntt_scheduler \
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv" \
    "${ROOT_DIR}/tb/unit/tb_forward_ntt_scheduler.sv"

run_test tb_coefficient_pingpong_memory_256x16 \
    "${ROOT_DIR}/rtl/ntt/true_dual_port_ram_256x16.sv" \
    "${ROOT_DIR}/rtl/ntt/coefficient_pingpong_memory_256x16.sv" \
    "${ROOT_DIR}/tb/unit/tb_coefficient_pingpong_memory_256x16.sv"

COMMON_NTT_SOURCES=(
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv"
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv"
    "${ROOT_DIR}/rtl/ntt/true_dual_port_ram_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/coefficient_pingpong_memory_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/forward_ntt_core.sv"
)

run_test tb_forward_ntt_core \
    "${COMMON_NTT_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_forward_ntt_core.sv"

run_test tb_forward_ntt_board_selftest \
    "${COMMON_NTT_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected_rom.sv" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/forward_ntt_board_selftest.sv" \
    "${ROOT_DIR}/tb/integration/tb_forward_ntt_board_selftest.sv"

COMMON_NTT_INTT_SOURCES=(
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv"
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv"
    "${ROOT_DIR}/rtl/ntt/inverse_ntt_scheduler.sv"
    "${ROOT_DIR}/rtl/ntt/ntt_intt_butterfly_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/true_dual_port_ram_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/coefficient_pingpong_memory_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/mlkem_ntt_intt_core.sv"
)

run_test tb_mlkem_ntt_intt_core \
    "${COMMON_NTT_INTT_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_mlkem_ntt_intt_core.sv"

COMMON_PQC_SOURCES=(
    "${COMMON_NTT_INTT_SOURCES[@]}"
    "${ROOT_DIR}/rtl/ntt/mlkem_basemul_sequential.sv"
    "${ROOT_DIR}/rtl/ntt/mlkem_pqc_accelerator.sv"
)

run_test tb_mlkem_pqc_accelerator \
    "${COMMON_PQC_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_mlkem_pqc_accelerator.sv"

COMMON_ASCON_SOURCES=(
    "${ROOT_DIR}/rtl/ascon/ascon_round.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_permutation.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_aead_encrypt.sv"
)

run_test tb_ascon_aead_encrypt \
    "${COMMON_ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_ascon_aead_encrypt.sv"

run_test tb_ascon_encrypt_kat_selftest \
    "${COMMON_ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/ascon_encrypt_kat_selftest.sv" \
    "${ROOT_DIR}/tb/integration/tb_ascon_encrypt_kat_selftest.sv"

run_test tb_primer1_request_semantic_guard \
    "${ROOT_DIR}/rtl/transport/fpst_btp_pkg.sv" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv" \
    "${ROOT_DIR}/tb/unit/tb_primer1_request_semantic_guard.sv"

COMMON_PRIMER1_DEPLOY_SOURCES=(
    "${ROOT_DIR}/rtl/transport/fpst_btp_pkg.sv"
    "${ROOT_DIR}/rtl/transport/btp_spi_slave.sv"
    "${ROOT_DIR}/rtl/transport/btp_request_parser.sv"
    "${ROOT_DIR}/rtl/transport/btp_response_builder.sv"
    "${ROOT_DIR}/rtl/session/primer1_session_context.sv"
    "${COMMON_ASCON_SOURCES[@]}"
    "${ROOT_DIR}/rtl/telemetry/primer1_stp_tx.sv"
    "${COMMON_NTT_SOURCES[@]}"
    "${ROOT_DIR}/rtl/ntt/inverse_ntt_scheduler.sv"
    "${ROOT_DIR}/rtl/ntt/ntt_intt_butterfly_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/mlkem_ntt_intt_core.sv"
    "${ROOT_DIR}/rtl/ntt/mlkem_basemul_sequential.sv"
    "${ROOT_DIR}/rtl/ntt/mlkem_pqc_accelerator.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv"
)

# Use a short heartbeat terminal count only for simulation. Heartbeat is a pure
# liveness channel: align the period check on a real heartbeat edge, then prove
# that neither ZEROIZE_N assertion nor fatal_latched assertion stops the divider.
python3 - <<'PY'
from pathlib import Path
build = Path("build/sim")
for name in ("tb_primer1_deployment_btp.sv", "tb_primer1_deployment_btp_retry.sv"):
    src = (Path("tb/integration") / name).read_text()
    src = src.replace(".HEARTBEAT_BIT(8)", ".HEARTBEAT_TOGGLE_CYCLES(16)")
    if name == "tb_primer1_deployment_btp.sv":
        needle = "        rst_n = 1'b1;\n        repeat (8) @(posedge sys_clk);\n"
        insert = needle + r'''
        /* Align to a real transition and measure the next edge-to-edge period. */
        begin : check_heartbeat_period
            integer hb_cycles;
            logic hb_start;

            @(heartbeat);
            #1ns;
            hb_start = heartbeat;
            hb_cycles = 0;
            while ((heartbeat === hb_start) && (hb_cycles < 20)) begin
                @(posedge sys_clk);
                #1ns;
                hb_cycles = hb_cycles + 1;
            end
            if (hb_cycles != 16)
                $fatal(1, "Heartbeat period mismatch: observed %0d clocks expected 16", hb_cycles);
        end

        /* FIX-001 acceptance: security state must not masquerade as liveness. */
        begin : check_heartbeat_security_independence
            integer hb_edges;
            integer k;
            logic hb_prev;

            @(negedge sys_clk);
            zeroize_n = 1'b0;
            repeat (3) @(posedge sys_clk);
            hb_prev = heartbeat;
            hb_edges = 0;
            for (k = 0; k < 40; k = k + 1) begin
                @(posedge sys_clk);
                #1ns;
                if (heartbeat !== hb_prev) begin
                    hb_edges = hb_edges + 1;
                    hb_prev = heartbeat;
                end
            end
            if (hb_edges < 2)
                $fatal(1, "Heartbeat stopped while ZEROIZE_N asserted");

            @(negedge sys_clk);
            zeroize_n = 1'b1;
            while (dut.transport_zeroize !== 1'b0)
                @(negedge sys_clk);

            @(negedge sys_clk);
            fatal_latched = 1'b1;
            repeat (3) @(posedge sys_clk);
            hb_prev = heartbeat;
            hb_edges = 0;
            for (k = 0; k < 40; k = k + 1) begin
                @(posedge sys_clk);
                #1ns;
                if (heartbeat !== hb_prev) begin
                    hb_edges = hb_edges + 1;
                    hb_prev = heartbeat;
                end
            end
            if (hb_edges < 2)
                $fatal(1, "Heartbeat stopped while fatal_latched asserted");

            @(negedge sys_clk);
            fatal_latched = 1'b0;
            repeat (4) @(posedge sys_clk);
        end
'''
        if needle not in src:
            raise SystemExit("heartbeat insertion point not found")
        src = src.replace(needle, insert, 1)
    (build / name).write_text(src)
PY

run_test tb_primer1_deployment_btp \
    "${COMMON_PRIMER1_DEPLOY_SOURCES[@]}" \
    "${BUILD_DIR}/tb_primer1_deployment_btp.sv"

run_test tb_primer1_deployment_btp_retry \
    "${COMMON_PRIMER1_DEPLOY_SOURCES[@]}" \
    "${BUILD_DIR}/tb_primer1_deployment_btp_retry.sv"

echo "PASS: all RTL unit and integration tests completed"
