# Kiwi Primer 20K #1 — FPST v1.1 deployment source manifest
# Top: kiwi_primer20k_fpst_tx_top
# Device: GW2A-LV18PG256C8/I7
# System clock: 27 MHz
#
# IMPORTANT: This manifest intentionally does not include a final deployment
# .cst yet. SPI/security-sideband package pins must be locked from measured
# board/header evidence before generating a release bitstream.

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

# Forward NTT accelerator already verified independently
rtl/arithmetic/mod_add.sv
rtl/arithmetic/mod_sub.sv
rtl/arithmetic/mod_mul_3329_pipe.sv
rtl/ntt/ntt_butterfly_pipe.sv
rtl/ntt/twiddle_rom_3329.sv
rtl/ntt/forward_ntt_scheduler.sv
rtl/ntt/true_dual_port_ram_256x16.sv
rtl/ntt/coefficient_pingpong_memory_256x16.sv
rtl/ntt/forward_ntt_core.sv

# Deployment integration
rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv
