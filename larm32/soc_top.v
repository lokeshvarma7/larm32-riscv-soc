// =============================================================================
//  soc_top.v  -  Top-level SoC: risc_core + MMIO bus + Peripherals
//
//  This wraps risc_core (rev 12) and replaces the cache_mem_bridge with
//  mmio_bus, adding GPIO, UART, TIMER0, and TIMER1 peripherals.
//
//  The risc_core module is left UNCHANGED.  All peripheral wiring is done
//  by overriding only the bridge_inst submodule through parameter/port
//  remapping at this level.
//
//  Strategy: We cannot directly substitute bridge_inst inside risc_core
//  without editing risc_core.v.  Instead, we provide a modified version
//  of risc_core that instantiates mmio_bus instead of cache_mem_bridge.
//  See risc_core_soc.v for the modified top-level pipeline module.
// =============================================================================
`timescale 1ns/1ps

module soc_top #(
    parameter DMEM_DEPTH = 4096
)(
    input  wire        clk,
    input  wire        rst,

    // GPIO pads
    input  wire [31:0] gpio_in,
    output wire [31:0] gpio_out,
    output wire [31:0] gpio_dir,

    // UART pads
    output wire        uart_tx,
    input  wire        uart_rx,

    // PWM outputs
    output wire        pwm0_out,
    output wire        pwm1_out,

    // Interrupt lines (can be wired to CSR MIP register if needed)
    output wire        irq_gpio,
    output wire        irq_uart_tx,
    output wire        irq_uart_rx,
    output wire        irq_timer0,
    output wire        irq_timer1
);

    risc_core_soc #(.dmem_depth(DMEM_DEPTH)) core_inst (
        .clk(clk), .rst(rst),
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_dir(gpio_dir),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .pwm0_out(pwm0_out),
        .pwm1_out(pwm1_out),
        .irq_gpio(irq_gpio),
        .irq_uart_tx(irq_uart_tx),
        .irq_uart_rx(irq_uart_rx),
        .irq_timer0(irq_timer0),
        .irq_timer1(irq_timer1)
    );

endmodule