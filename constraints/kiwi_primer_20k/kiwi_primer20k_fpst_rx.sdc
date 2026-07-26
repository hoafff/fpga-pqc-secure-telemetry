# Kiwi Primer 20K #2 FPST deployment timing baseline.
# On-board oscillator is 27 MHz: period = 37.037 ns.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]

# btp_spi_slave contains SCK-domain sequential logic on both SPI edges.
# 5 MHz is the implementation envelope; physical bring-up begins at 1 MHz.
create_clock -name spi_sck -period 200.000 [get_ports {spi_sck_i}]

# SN32 SPI clock and the Primer oscillator are asynchronous.  Crossing is only
# through the reviewed transport CDC boundary.
set_clock_groups -asynchronous -group {sys_clk} -group {spi_sck}
