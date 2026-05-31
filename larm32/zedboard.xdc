# ----------------------------------------------------------------------------
# ZedBoard Xilinx Design Constraints (XDC) file for LARM-32 RISC-V SoC
# Matches the top-level zedboard_top.v wrapper ports exactly.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# System Clock (100 MHz Onboard Oscillator)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN Y9 [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -period 10.000 -name clk [get_ports clk]

# ----------------------------------------------------------------------------
# System Reset (Center Push Button - BTNC)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN T18 [get_ports {rst}]
set_property IOSTANDARD LVCMOS33 [get_ports {rst}]

# ----------------------------------------------------------------------------
# UART (Routed to PMOD JA Pins for connection with a USB-UART Module)
# Connect standard 3.3V USB-to-UART Adapter:
#   Adapter GND <-> PMOD JA GND (Pin 5 or Pin 11)
#   Adapter RXD <-> PMOD JA1 (Pin 1) - driven by CPU TX (uart_tx)
#   Adapter TXD <-> PMOD JA2 (Pin 2) - drives CPU RX (uart_rx)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN Y11  [get_ports {uart_tx}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_tx}]

set_property PACKAGE_PIN AA11 [get_ports {uart_rx}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rx}]

# ----------------------------------------------------------------------------
# PWM Outputs (Routed to PMOD JA Pins 3 and 4)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN Y10  [get_ports {pwm0_out}]
set_property IOSTANDARD LVCMOS33 [get_ports {pwm0_out}]

set_property PACKAGE_PIN AA9  [get_ports {pwm1_out}]
set_property IOSTANDARD LVCMOS33 [get_ports {pwm1_out}]

# ----------------------------------------------------------------------------
# GPIO Inputs - Slide Switches (SW0 - SW7 mapped to gpio_sw[7:0])
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN F22 [get_ports {gpio_sw[0]}]
set_property PACKAGE_PIN G22 [get_ports {gpio_sw[1]}]
set_property PACKAGE_PIN H22 [get_ports {gpio_sw[2]}]
set_property PACKAGE_PIN F21 [get_ports {gpio_sw[3]}]
set_property PACKAGE_PIN H19 [get_ports {gpio_sw[4]}]
set_property PACKAGE_PIN H18 [get_ports {gpio_sw[5]}]
set_property PACKAGE_PIN H17 [get_ports {gpio_sw[6]}]
set_property PACKAGE_PIN M15 [get_ports {gpio_sw[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_sw[*]}]

# ----------------------------------------------------------------------------
# GPIO Outputs - LEDs (LD0 - LD7 mapped to gpio_led[7:0])
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN T22 [get_ports {gpio_led[0]}]
set_property PACKAGE_PIN T21 [get_ports {gpio_led[1]}]
set_property PACKAGE_PIN U22 [get_ports {gpio_led[2]}]
set_property PACKAGE_PIN U21 [get_ports {gpio_led[3]}]
set_property PACKAGE_PIN V22 [get_ports {gpio_led[4]}]
set_property PACKAGE_PIN W22 [get_ports {gpio_led[5]}]
set_property PACKAGE_PIN U19 [get_ports {gpio_led[6]}]
set_property PACKAGE_PIN U14 [get_ports {gpio_led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_led[*]}]
