// =============================================================================
//  mmio_bus.v  -  MMIO Address Decoder / Bus Fabric
//
//  Sits between the CPU pipeline (dcache/dmem) and the peripherals.
//  The CPU's cache_mem_bridge is replaced by this module for addresses
//  in the MMIO range; normal DMEM accesses are pass-through.
//
//  Address Map:
//    0x00000000 - 0x0FFFFFFF   DMEM  (existing data memory)
//    0x10000000 - 0x1000001F   GPIO
//    0x10000100 - 0x10000117   UART
//    0x10000200 - 0x10000217   TIMER0
//    0x10000300 - 0x10000317   TIMER1
//
//  Interface mirrors cache_mem_bridge so risc_core.v needs only one
//  substitution: replace `cache_mem_bridge bridge_inst` with
//  `mmio_bus bus_inst`.
// =============================================================================
`timescale 1ns/1ps

module mmio_bus #(
    parameter DMEM_DEPTH = 4096
)(
    input  wire        clk,
    input  wire        rst,

    // From dcache (same as cache_mem_bridge ports)
    input  wire        mem_req,
    input  wire        mem_rw,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    output reg  [31:0] mem_rdata,
    output wire        mem_ready,
    input  wire [2:0]  mem_funct3,

    // Physical GPIO pads
    input  wire [31:0] gpio_in,
    output wire [31:0] gpio_out,
    output wire [31:0] gpio_dir,

    // Physical UART pads
    output wire        uart_tx,
    input  wire        uart_rx,

    // PWM outputs
    output wire        pwm0_out,
    output wire        pwm1_out,

    // Interrupt outputs
    output wire        irq_gpio,
    output wire        irq_uart_tx,
    output wire        irq_uart_rx,
    output wire        irq_timer0,
    output wire        irq_timer1
);

    // -----------------------------------------------------------------------
    //  Address decode
    // -----------------------------------------------------------------------
    wire sel_dmem   = (mem_addr[31:28] != 4'h1);  // below 0x10000000
    wire sel_gpio   = (mem_addr[31:8]  == 24'h100000);   // 0x10000000-0x1000001F
    wire sel_uart   = (mem_addr[31:8]  == 24'h100001);   // 0x10000100-0x100001FF
    wire sel_timer0 = (mem_addr[31:8]  == 24'h100002);   // 0x10000200-0x100002FF
    wire sel_timer1 = (mem_addr[31:8]  == 24'h100003);   // 0x10000300-0x100003FF

    // -----------------------------------------------------------------------
    //  DMEM instance
    // -----------------------------------------------------------------------
    wire [31:0] dmem_rdata;
    // For cache fills always fetch LW; writes use real funct3
    wire [2:0] dmem_f3 = mem_rw ? mem_funct3 : 3'b010;

    dmem #(.depth(DMEM_DEPTH)) backing_mem (
        .clk(clk),
        .addr(mem_addr),
        .mem_we(mem_req & mem_rw & sel_dmem),
        .wdata(mem_wdata),
        .funct3(dmem_f3),
        .rdata(dmem_rdata)
    );

    // -----------------------------------------------------------------------
    //  GPIO instance
    // -----------------------------------------------------------------------
    wire [31:0] gpio_rdata;
    gpio gpio_inst (
        .clk(clk), .rst(rst),
        .sel(sel_gpio & mem_req), .we(mem_rw),
        .addr(mem_addr), .wdata(mem_wdata), .rdata(gpio_rdata),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .irq(irq_gpio)
    );

    // -----------------------------------------------------------------------
    //  UART instance
    // -----------------------------------------------------------------------
    wire [31:0] uart_rdata;
    uart uart_inst (
        .clk(clk), .rst(rst),
        .sel(sel_uart & mem_req), .we(mem_rw),
        .addr(mem_addr), .wdata(mem_wdata), .rdata(uart_rdata),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .irq_tx(irq_uart_tx), .irq_rx(irq_uart_rx)
    );

    // -----------------------------------------------------------------------
    //  TIMER0 instance
    // -----------------------------------------------------------------------
    wire [31:0] timer0_rdata;
    timer #(.BASE(32'h1000_0200)) timer0_inst (
        .clk(clk), .rst(rst),
        .sel(sel_timer0 & mem_req), .we(mem_rw),
        .addr(mem_addr), .wdata(mem_wdata), .rdata(timer0_rdata),
        .pwm_out(pwm0_out), .irq(irq_timer0)
    );

    // -----------------------------------------------------------------------
    //  TIMER1 instance
    // -----------------------------------------------------------------------
    wire [31:0] timer1_rdata;
    timer #(.BASE(32'h1000_0300)) timer1_inst (
        .clk(clk), .rst(rst),
        .sel(sel_timer1 & mem_req), .we(mem_rw),
        .addr(mem_addr), .wdata(mem_wdata), .rdata(timer1_rdata),
        .pwm_out(pwm1_out), .irq(irq_timer1)
    );

    // -----------------------------------------------------------------------
    //  Read mux
    // -----------------------------------------------------------------------
    always @(*) begin
        if      (sel_gpio)   mem_rdata = gpio_rdata;
        else if (sel_uart)   mem_rdata = uart_rdata;
        else if (sel_timer0) mem_rdata = timer0_rdata;
        else if (sel_timer1) mem_rdata = timer1_rdata;
        else                 mem_rdata = dmem_rdata;
    end

    // Peripherals respond in one cycle (no wait states)
    assign mem_ready = 1'b1;

endmodule