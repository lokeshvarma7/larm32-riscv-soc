// =============================================================================
//  soc_top_jtag_wrapper.v - JTAG Virtual Testing Wrapper for LARM-32 SoC
//
//  This wrapper allows you to test the entire RISC-V processor on your ZedBoard
//  using only the standard micro-USB JTAG programming cable (no external USB-UART
//  adapters, buttons, or switches needed!).
//
//  Key Updates:
//  1. Clock Division + Global Clock Buffer (BUFG): Steps down the 100 MHz clock
//     to 25 MHz for timing closure, but routes it through a dedicated FPGA global
//     clock buffer (BUFG). This eliminates logic-skew, solving the JTAG read
//     corruption error [Labtools 27-3312].
//  2. Activates the VIO and ILA instantiations.
// =============================================================================

`timescale 1ns/1ps

module soc_top_jtag_wrapper(
    input wire clk // Physical 100 MHz clock input from pin Y9
);

    // -------------------------------------------------------------------------
    // 1. Clock Generation (Divide 100 MHz down to 25 MHz + BUFG)
    // -------------------------------------------------------------------------
    reg [1:0] clk_div = 2'b0;
    always @(posedge clk) begin
        clk_div <= clk_div + 1'b1;
    end
    
    wire clk_25mhz_raw = clk_div[1];
    wire clk_25mhz;
    
    // Route the divided clock through a Global Clock Buffer (BUFG)
    // to provide a low-skew, stable clock distribution for VIO, ILA, and CPU.
    BUFG clk_bufg_inst (
        .I(clk_25mhz_raw),
        .O(clk_25mhz)
    );

    // -------------------------------------------------------------------------
    // 2. Internal Nets for Debug Cores
    // -------------------------------------------------------------------------
    wire        virtual_rst;
    wire [31:0] virtual_gpio_in;
    wire [31:0] virtual_gpio_out;
    wire [31:0] virtual_gpio_dir;
    wire        virtual_uart_tx;
    wire        virtual_uart_rx;
    wire        virtual_pwm0_out;
    wire        virtual_pwm1_out;

    // -------------------------------------------------------------------------
    // 3. Instantiate the LARM-32 RISC-V SoC Top Level
    // -------------------------------------------------------------------------
    soc_top #(
        .DMEM_DEPTH(4096)
    ) u_soc_top (
        .clk(clk_25mhz),
        .rst(virtual_rst),

        // GPIO
        .gpio_in(virtual_gpio_in),
        .gpio_out(virtual_gpio_out),
        .gpio_dir(virtual_gpio_dir),

        // UART
        .uart_tx(virtual_uart_tx),
        .uart_rx(1'b1), // Tie RX high (idle state)

        // PWM
        .pwm0_out(virtual_pwm0_out),
        .pwm1_out(virtual_pwm1_out),

        // Interrupt monitors (left open/unconnected for JTAG testing)
        .irq_gpio(),
        .irq_uart_tx(),
        .irq_uart_rx(),
        .irq_timer0(),
        .irq_timer1()
    );

    // -------------------------------------------------------------------------
    // 4. Xilinx Virtual I/O (VIO) IP Core Instantiation
    // -------------------------------------------------------------------------
    vio_0 u_vio (
        .clk(clk_25mhz),
        .probe_in0(virtual_gpio_out),
        .probe_in1(virtual_uart_tx),
        .probe_out0(virtual_rst),
        .probe_out1(virtual_gpio_in)
    );

    // -------------------------------------------------------------------------
    // 5. Xilinx Integrated Logic Analyzer (ILA) IP Core Instantiation
    // -------------------------------------------------------------------------
    ila_0 u_ila (
        .clk(clk_25mhz),
        .probe0(virtual_uart_tx),
        .probe1(virtual_gpio_out),
        .probe2(virtual_rst)
    );

endmodule
