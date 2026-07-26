# Kiwi Primer 20K #1 — MCU/SPI + session + Ascon + forward NTT integration
# Top: kiwi_primer20k_primer1_top

rtl/arithmetic/mod_add.sv
rtl/arithmetic/mod_sub.sv
rtl/arithmetic/mod_mul_3329_pipe.sv
rtl/ntt/ntt_butterfly_pipe.sv
rtl/ntt/twiddle_rom_3329.sv
rtl/ntt/forward_ntt_scheduler.sv
rtl/ntt/true_dual_port_ram_256x16.sv
rtl/ntt/coefficient_pingpong_memory_256x16.sv
rtl/ntt/forward_ntt_core.sv

rtl/ascon/ascon_round.sv
rtl/ascon/ascon_permutation.sv
rtl/ascon/ascon_aead_encrypt.sv

rtl/link/fpst_spi_mem_slave.sv
rtl/endpoint/primer1_endpoint.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_primer1_top.sv

constraints/kiwi_primer_20k/kiwi_primer20k_primer1.cst
constraints/kiwi_primer_20k/kiwi_primer20k_primer1.sdc
