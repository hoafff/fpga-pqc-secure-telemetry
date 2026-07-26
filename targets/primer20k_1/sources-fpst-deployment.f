# Kiwi Primer 20K #1 — FPST v1.1 deployment source manifest
# Top: kiwi_primer20k_fpst_tx_top
# Device: GW2A-LV18PG256C8/I7
# System clock: 27 MHz
# Constraint: constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
# Timing:     constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
#
# IMPORTANT: the .cst freezes the FPGA-side J2 harness mapping. The physical
# SN32/Tiny wiring SHALL follow that profile and SHALL be continuity-checked
# before board sign-off. Do not silently remap deployment pins in Gowin.

# BTP protocol / transport
rtl/transport/fpst_btp_pkg.sv
rtl/transport/btp_spi_slave.sv
rtl/transport/btp_request_parser.sv
rtl/transport/btp_response_builder.sv

# Session and secure telemetry TX
rtl/session/primer1_session_context.sv
rtl/ascon/ascon_round.sv
rtl/ascon/ascon_permutation.sv
rtl/ascon/ascon_aead_encrypt.sv
rtl/telemetry/primer1_stp_tx.sv

# Shared ML-KEM arithmetic / transform datapath
rtl/arithmetic/mod_add.sv
rtl/arithmetic/mod_sub.sv
rtl/arithmetic/mod_mul_3329_pipe.sv
rtl/ntt/twiddle_rom_3329.sv
rtl/ntt/forward_ntt_scheduler.sv
rtl/ntt/inverse_ntt_scheduler.sv
rtl/ntt/ntt_intt_butterfly_pipe.sv
rtl/ntt/true_dual_port_ram_256x16.sv
rtl/ntt/coefficient_pingpong_memory_256x16.sv
rtl/ntt/mlkem_ntt_intt_core.sv
rtl/ntt/mlkem_basemul_sequential.sv
rtl/ntt/mlkem_pqc_accelerator.sv

# The legacy control endpoint still has a forward_ntt_core instance in its
# source for backward compatibility. Deployment routes every PQC opcode to the
# accelerator above, so bind that unreachable instance to a fail-closed stub.
rtl/boards/kiwi_primer_20k/forward_ntt_core_disabled.sv

# Deployment integration
rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv
rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv
rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv
rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv
