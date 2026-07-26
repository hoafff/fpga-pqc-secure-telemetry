# Kiwi Primer 20K onboard oscillator: 27 MHz at SYS_CLK / H11.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk_i}]

# The MCU SPI pins are asynchronous inputs that are deliberately synchronized
# and oversampled in the 27 MHz system domain. SPI is limited to 3 MHz by the
# matching MCU profile, giving nine system-clock samples per SCLK period.
set_false_path -from [get_ports {spi_sclk_i spi_cs_ni spi_mosi_i fpga_zeroize_ni}]
