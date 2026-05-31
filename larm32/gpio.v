// =============================================================================
//  gpio.v  -  General Purpose I/O Peripheral
//
//  Memory Map (base = 0x10000000):
//    0x00  GPIO_DIR   Direction register (1=Output, 0=Input)
//    0x04  GPIO_OUT   Output data register
//    0x08  GPIO_IN    Input data register (read-only, from pad)
//    0x0C  GPIO_SET   Atomic set   (write 1 to set bits in GPIO_OUT)
//    0x10  GPIO_CLR   Atomic clear (write 1 to clear bits in GPIO_OUT)
//    0x14  GPIO_TOG   Atomic toggle
//    0x18  GPIO_IE    Interrupt enable (per-bit)
//    0x1C  GPIO_IF    Interrupt flag  (write 1 to clear - W1C)
// =============================================================================
`timescale 1ns/1ps

module gpio #(parameter BASE = 32'h1000_0000)(
    input  wire        clk,
    input  wire        rst,

    // CPU bus interface
    input  wire        sel,          // address in GPIO range
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // Physical GPIO pads
    input  wire [31:0] gpio_in,      // external input
    output wire [31:0] gpio_out,     // pad output
    output wire [31:0] gpio_dir,     // pad direction
    output wire        irq           // interrupt to CPU
);

    reg [31:0] dir_r, out_r, ie_r, if_r;

    wire [7:0] offset = addr[7:0];

    // Interrupt: any enabled pin where input != output (simple edge detect via level change)
    // Here we flag on any enabled input pin being high (level-trigger, simplest model)
    wire [31:0] new_if = if_r | (gpio_in & ie_r & ~dir_r);

    // Write
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dir_r <= 32'h0;
            out_r <= 32'h0;
            ie_r  <= 32'h0;
            if_r  <= 32'h0;
        end else begin
            if_r <= new_if;  // latch interrupts
            if (sel && we) begin
                case (offset)
                    8'h00: dir_r <= wdata;
                    8'h04: out_r <= wdata;
                    // 0x08 read-only
                    8'h0C: out_r <= out_r |  wdata;   // SET
                    8'h10: out_r <= out_r & ~wdata;   // CLR
                    8'h14: out_r <= out_r ^  wdata;   // TOG
                    8'h18: ie_r  <= wdata;
                    8'h1C: if_r  <= if_r & ~wdata;    // W1C
                endcase
            end
        end
    end

    // Read
    always @(*) begin
        rdata = 32'h0;
        if (sel) begin
            case (offset)
                8'h00: rdata = dir_r;
                8'h04: rdata = out_r;
                8'h08: rdata = gpio_in;
                8'h18: rdata = ie_r;
                8'h1C: rdata = if_r;
                default: rdata = 32'h0;
            endcase
        end
    end

    assign gpio_out = out_r;
    assign gpio_dir = dir_r;
    assign irq      = |(if_r & ie_r);

endmodule