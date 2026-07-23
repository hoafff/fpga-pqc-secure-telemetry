# Kiwi Primer 20K onboard oscillator: 27 MHz at SYS_CLK / H11.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]
