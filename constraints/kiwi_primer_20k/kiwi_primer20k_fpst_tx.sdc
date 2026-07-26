# Kiwi Primer 20K #1 FPST deployment timing baseline.
# 27 MHz oscillator: period = 37.037 ns.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]

# SPI pins are asynchronous external inputs sampled through explicit two-flop
# synchronizers in btp_spi_slave.  They are intentionally not declared as an
# FPGA clock domain.  Bring-up is fixed to 1 MHz until real-board margin is
# measured and a characterized release rate is recorded.
