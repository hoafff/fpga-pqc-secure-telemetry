# Kiwi Primer 20K #1 FPST deployment timing baseline.
# On-board oscillator is 27 MHz: period = 37.037 ns.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]

# btp_spi_slave contains real SCK-domain sequential logic on both SPI edges, so
# spi_sck_i must be constrained as a clock rather than left unconstrained.
# 5 MHz is the implementation envelope; physical bring-up still begins at
# 1 MHz and the final release rate is qualified from measured board margin.
create_clock -name spi_sck -period 200.000 [get_ports {spi_sck_i}]

# BTP crosses between spi_sck and sys_clk only through the reviewed event /
# stable bundled-data CDC boundary. There is no phase relationship between the
# MCU clock and the Primer oscillator.
set_clock_groups -asynchronous -group {sys_clk} -group {spi_sck}
