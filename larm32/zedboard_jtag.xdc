# ----------------------------------------------------------------------------
# ZedBoard Xilinx Design Constraints (XDC) file for LARM-32 JTAG-Only Testing
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# System Clock (100 MHz Onboard Oscillator)
# This is the only physical pin required for pure JTAG virtual testing!
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN Y9 [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -period 10.000 -name clk [get_ports clk]

# All other inputs (rst, gpio_in) and outputs (gpio_out, uart_tx, etc.)
# are connected internally to the VIO and ILA debug cores. 
# Therefore, they do NOT require physical package pin assignments.
# Vivado will treat them as internal debug nets routed over the JTAG cable.
