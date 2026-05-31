// =============================================================================
//  zedboard_top.v  -  Top-Level Hardware Wrapper for ZedBoard Deployment
//
//  This wrapper serves as the physical interface layer between the LARM-32 SoC
//  and the physical pins on the Xilinx ZedBoard.
//
//  Key Responsibilities:
//  1. Exposes ONLY the pins that physically exist on the board (Clock, Reset,
//     8 Switches, 8 LEDs, UART, and PWM), resolving the Vivado IO Placement
//     Error (Place 30-58) by keeping internal debug/interrupt lines on-chip.
//  2. Steps down the physical 100 MHz clock to a stable 25 MHz for the CPU
//     pipeline to avoid hardware timing setup violations.
// =============================================================================

`timescale 1ns/1ps

module zedboard_top (
    input  wire        clk,          // Physical 100 MHz oscillator (pin Y9)
    input  wire        rst,          // Center push button BTNC (pin T18)
    
    input  wire [7:0]  gpio_sw,      // 8 physical slide switches (SW0-SW7)
    output wire [7:0]  gpio_led,     // 8 physical green LEDs (LD0-LD7)
    
    output wire        uart_tx,      // PMOD JA1 (TX output to laptop)
    input  wire        uart_rx,      // PMOD JA2 (RX input from laptop)
    
    output wire        pwm0_out,     // PMOD JA3
    output wire        pwm1_out      // PMOD JA4
);

    // -------------------------------------------------------------------------
    // 1. Clock Divider (Step down 100 MHz to 25 MHz)
    // -------------------------------------------------------------------------
    reg [1:0] clk_div = 2'b0;
    always @(posedge clk) begin
        clk_div <= clk_div + 1'b1;
    end
    wire clk_25mhz = clk_div[1]; // Stable 25 MHz clock for the CPU core

    // -------------------------------------------------------------------------
    // 2. Bus Adaptation & Instantiation
    // -------------------------------------------------------------------------
    wire [31:0] full_gpio_in;
    wire [31:0] full_gpio_out;
    wire [31:0] full_gpio_dir;

    // Map physical 8 switches to the lower 8 bits of the 32-bit CPU GPIO input bus
    assign full_gpio_in = {24'b0, gpio_sw};

    // Route lower 8 bits of the 32-bit CPU GPIO output bus to the physical LEDs
    assign gpio_led = full_gpio_out[7:0];

    // Instantiate LARM-32 SoC Top Level
    soc_top #(
        .DMEM_DEPTH(4096)
    ) u_soc_top (
        .clk(clk_25mhz),
        .rst(rst),
        
        .gpio_in(full_gpio_in),
        .gpio_out(full_gpio_out),
        .gpio_dir(full_gpio_dir),
        
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        
        .pwm0_out(pwm0_out),
        .pwm1_out(pwm1_out),
        
        // Interrupt/internal outputs left open (no physical pins needed)
        .irq_gpio(),
        .irq_uart_tx(),
        .irq_uart_rx(),
        .irq_timer0(),
        .irq_timer1()
    );

endmodule
