# Kiwi Primer 20K #2 — FPST v1.1 secure RX deployment source manifest
# Top: kiwi_primer20k_fpst_rx_top
# Device: GW2A-LV18PG256C8/I7
# System clock: 27 MHz
# Constraint: constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst
# Timing:     constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.sdc

# BTP protocol / transport
rtl/transport/fpst_btp_pkg.sv
rtl/transport/btp_spi_slave.sv
rtl/transport/btp_request_parser.sv
rtl/transport/btp_response_builder.sv

# Session context and NIST SP 800-232 Ascon-AEAD128
rtl/session/primer2_session_context.sv
rtl/ascon/ascon_round.sv
rtl/ascon/ascon_permutation.sv
rtl/ascon/ascon_aead_encrypt.sv
rtl/ascon/ascon_aead_decrypt.sv
rtl/ascon/ascon_aead_core.sv

# Secure telemetry RX / replay / quarantine
rtl/telemetry/primer2_stp_rx.sv

# Deployment integration
rtl/boards/kiwi_primer_20k/primer2_btp_endpoint_deploy.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_rx_top.sv
