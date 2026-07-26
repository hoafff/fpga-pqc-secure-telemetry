# Kiwi Primer 20K #1 FPST deployment timing baseline.
# On-board oscillator is 27 MHz: period = 37.037 ns.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]

# spi_sck_i is an asynchronous external serial clock handled inside btp_spi_slave;
# no generated relationship to sys_clk is assumed. The transport crosses into
# the 27 MHz domain through reviewed bundled-data/event synchronization.
# Hardware bring-up starts at 1 MHz SPI and the release SPI rate is qualified
# from measured board margin rather than guessed here.
