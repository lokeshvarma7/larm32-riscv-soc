// =============================================================================
//  uart.v  -  Simple UART Peripheral  (16-byte FIFOs, configurable baud)
//
//  Memory Map (base = 0x10000100):
//    0x00  UART_TX      Write: push byte to TX FIFO
//    0x04  UART_RX      Read:  pop byte from RX FIFO
//    0x08  UART_STAT    Status (read-only)
//    0x0C  UART_CTRL    Control
//    0x10  UART_BAUD    Baud divisor (clk_freq / baud_rate)
//    0x14  UART_FIFO_CTRL  FIFO control
//
//  UART_STAT bits:
//    [0] TX_EMPTY   [1] TX_FULL   [2] RX_EMPTY   [3] RX_FULL
//    [4] RX_OVF     [5] FRAME_ERR [6] PARITY_ERR
//
//  UART_CTRL bits:
//    [0] TX_EN  [1] RX_EN  [2] PARITY_EN  [3] PARITY_ODD
//    [4] STOP2  [5] IE_TX  [6] IE_RX
// =============================================================================
`timescale 1ns/1ps

module uart #(
    parameter BASE      = 32'h1000_0100,
    parameter CLK_FREQ  = 50_000_000,
    parameter FIFO_DEPTH = 16
)(
    input  wire        clk,
    input  wire        rst,

    // CPU bus
    input  wire        sel,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // UART pads
    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        irq_tx,
    output wire        irq_rx
);

    wire [7:0] offset = addr[7:0];

    // ---- Control registers ----
    reg [31:0] baud_div_r;   // clock divisor
    reg [6:0]  ctrl_r;

    // ---- TX FIFO (simple circular using discrete registers to prevent RAM decoding race issues) ----
    reg [7:0] tx_f0, tx_f1, tx_f2, tx_f3, tx_f4, tx_f5, tx_f6, tx_f7;
    reg [7:0] tx_f8, tx_f9, tx_f10, tx_f11, tx_f12, tx_f13, tx_f14, tx_f15;
    reg [$clog2(FIFO_DEPTH):0] tx_head, tx_tail;
    wire tx_empty = (tx_head == tx_tail);
    wire [$clog2(FIFO_DEPTH):0] tx_count = tx_tail - tx_head;
    wire tx_full  = (tx_count == FIFO_DEPTH);

    reg [7:0] tx_fifo_out;
    always @(*) begin
        case (tx_head[3:0])
            4'd0:  tx_fifo_out = tx_f0;
            4'd1:  tx_fifo_out = tx_f1;
            4'd2:  tx_fifo_out = tx_f2;
            4'd3:  tx_fifo_out = tx_f3;
            4'd4:  tx_fifo_out = tx_f4;
            4'd5:  tx_fifo_out = tx_f5;
            4'd6:  tx_fifo_out = tx_f6;
            4'd7:  tx_fifo_out = tx_f7;
            4'd8:  tx_fifo_out = tx_f8;
            4'd9:  tx_fifo_out = tx_f9;
            4'd10: tx_fifo_out = tx_f10;
            4'd11: tx_fifo_out = tx_f11;
            4'd12: tx_fifo_out = tx_f12;
            4'd13: tx_fifo_out = tx_f13;
            4'd14: tx_fifo_out = tx_f14;
            4'd15: tx_fifo_out = tx_f15;
            default: tx_fifo_out = 8'h00;
        endcase
    end

    // ---- RX FIFO ----
    reg [7:0]  rx_fifo [0:FIFO_DEPTH-1];
    reg [$clog2(FIFO_DEPTH):0] rx_head, rx_tail, rx_count;
    wire rx_empty = (rx_count == 0);
    wire rx_full  = (rx_count == FIFO_DEPTH);

    // ---- Baud generator ----
    reg [31:0] baud_cnt;
    wire baud_tick = (baud_cnt == 32'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) baud_cnt <= 32'd0;
        else if (sel && we && (addr[7:0] == 8'h10)) baud_cnt <= 32'd0;  // reset on baud write
        else if (baud_cnt == 32'd0) baud_cnt <= (baud_div_r == 0) ? 32'd0 : baud_div_r - 1;
        else baud_cnt <= baud_cnt - 1;
    end

    // ---- TX shift register ----
    reg [9:0] tx_shift;    // start + 8 data + stop
    reg [3:0] tx_bit_cnt;
    reg       tx_busy;
    reg [7:0] tx_sr_data;

    // ---- RX shift register ----
    reg [7:0] rx_shift;
    reg [3:0] rx_bit_cnt;
    reg       rx_busy;
    reg [1:0] rx_sync;     // 2-FF sync

    // ---- Status ----
    reg rx_ovf_r, frame_err_r;

    // CPU bus write
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            baud_div_r <= CLK_FREQ / 115200;
            ctrl_r     <= 7'h03;  // TX_EN + RX_EN
            tx_tail    <= 0;
            tx_f0  <= 8'h00; tx_f1  <= 8'h00; tx_f2  <= 8'h00; tx_f3  <= 8'h00;
            tx_f4  <= 8'h00; tx_f5  <= 8'h00; tx_f6  <= 8'h00; tx_f7  <= 8'h00;
            tx_f8  <= 8'h00; tx_f9  <= 8'h00; tx_f10 <= 8'h00; tx_f11 <= 8'h00;
            tx_f12 <= 8'h00; tx_f13 <= 8'h00; tx_f14 <= 8'h00; tx_f15 <= 8'h00;
        end else begin
            if (sel && we) begin
                case (offset)
                    8'h00: begin  // TX write
                        if (!tx_full) begin
                            case (tx_tail[3:0])
                                4'd0:  tx_f0  <= wdata[7:0];
                                4'd1:  tx_f1  <= wdata[7:0];
                                4'd2:  tx_f2  <= wdata[7:0];
                                4'd3:  tx_f3  <= wdata[7:0];
                                4'd4:  tx_f4  <= wdata[7:0];
                                4'd5:  tx_f5  <= wdata[7:0];
                                4'd6:  tx_f6  <= wdata[7:0];
                                4'd7:  tx_f7  <= wdata[7:0];
                                4'd8:  tx_f8  <= wdata[7:0];
                                4'd9:  tx_f9  <= wdata[7:0];
                                4'd10: tx_f10 <= wdata[7:0];
                                4'd11: tx_f11 <= wdata[7:0];
                                4'd12: tx_f12 <= wdata[7:0];
                                4'd13: tx_f13 <= wdata[7:0];
                                4'd14: tx_f14 <= wdata[7:0];
                                4'd15: tx_f15 <= wdata[7:0];
                            endcase
                            tx_tail  <= tx_tail + 1;
                        end
                    end
                    8'h0C: ctrl_r    <= wdata[6:0];
                    8'h10: baud_div_r<= wdata;
                endcase
            end
        end
    end

    // TX state machine - pop FIFO and load shift register atomically in one block.
    // This eliminates the original bug where tx_sr_data (popped via non-blocking
    // assignment in a separate always block) was stale when tx_shift read it on
    // the same clock edge.  Reading tx_fifo[tx_head] combinationally here gives
    // the current word directly.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_busy    <= 0;
            tx_shift   <= 10'h3FF;
            tx_bit_cnt <= 0;
            tx_sr_data <= 8'h0;
            tx_head    <= 0;
        end else if (baud_tick) begin
            if (!tx_busy && !tx_empty && ctrl_r[0]) begin
                tx_sr_data <= tx_fifo_out;         // for debug
                tx_shift   <= {1'b1, tx_fifo_out, 1'b0};
                tx_bit_cnt <= 4'd10;
                tx_busy    <= 1;
                tx_head    <= tx_head + 1;
            end else if (tx_busy) begin
                tx_shift   <= {1'b1, tx_shift[9:1]};
                tx_bit_cnt <= tx_bit_cnt - 1;
                if (tx_bit_cnt == 4'd1) tx_busy <= 0;
            end
        end
    end
    assign uart_tx = tx_shift[0];

    wire cpu_pop = (sel && !we && (offset == 8'h04) && !rx_empty);
    reg [31:0] rx_baud_cnt;
    wire rx_baud_tick = (rx_baud_cnt == 32'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_sync     <= 2'b11;
            rx_busy     <= 0;
            rx_shift    <= 8'h0;
            rx_bit_cnt  <= 0;
            rx_baud_cnt <= 32'd0;
            rx_head     <= 0;
            rx_tail     <= 0;
            rx_count    <= 0;
            rx_ovf_r    <= 0;
            frame_err_r <= 0;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};

            // 1. CPU Pop side (updates rx_head immediately)
            if (cpu_pop) begin
                rx_head <= rx_head + 1;
            end

            // 2. Serial Receiver side
            if (!rx_busy) begin
                // Detect falling edge (start bit) on every clock cycle
                if (rx_sync == 2'b10 && ctrl_r[1]) begin
                    rx_baud_cnt <= (baud_div_r >> 1);  // half period: sample at midpoint
                    rx_busy     <= 1;
                    rx_bit_cnt  <= 4'd9; // 9 ticks total (1 for start bit validation, 8 for data)
                    rx_shift    <= 8'h0;
                end
                
                // Track count logic if only pop happens
                if (cpu_pop) begin
                    rx_count <= rx_count - 1;
                end
            end else begin
                // Count down; reload each bit period
                if (rx_baud_cnt == 32'd0) begin
                    // Handled by reload
                end else begin
                    rx_baud_cnt <= rx_baud_cnt - 1;
                end

                if (rx_baud_tick) begin
                    if (rx_bit_cnt == 4'd9) begin
                        // Start bit validation check at midpoint
                        if (rx_sync[1] == 1'b0) begin
                            rx_baud_cnt <= baud_div_r; // Reload for full bit period
                            rx_bit_cnt  <= 4'd8;       // Next tick is Data Bit 0
                        end else begin
                            rx_busy <= 0; // Glitch, abort receiving
                        end
                        
                        if (cpu_pop) begin
                            rx_count <= rx_count - 1;
                        end
                    end else if (rx_bit_cnt > 0) begin
                        // Shift data bits 0 to 7
                        rx_shift   <= {rx_sync[1], rx_shift[7:1]};
                        rx_baud_cnt <= baud_div_r; // Reload for full bit period
                        rx_bit_cnt <= rx_bit_cnt - 1;
                        
                        if (cpu_pop) begin
                            rx_count <= rx_count - 1;
                        end
                    end else begin
                        // Stop bit check (rx_bit_cnt == 0)
                        rx_busy <= 0;
                        if (rx_sync[1] == 1'b1) begin
                            if (!rx_full) begin
                                rx_fifo[rx_tail % FIFO_DEPTH] <= rx_shift;
                                rx_tail  <= rx_tail + 1;
                                // Handle simultaneous push & pop to prevent count errors
                                if (cpu_pop) begin
                                    rx_count <= rx_count; // net 0 change
                                end else begin
                                    rx_count <= rx_count + 1;
                                end
                            end else begin
                                rx_ovf_r <= 1;
                                if (cpu_pop) begin
                                    rx_count <= rx_count - 1;
                                end
                            end
                        end else begin
                            frame_err_r <= 1;
                            if (cpu_pop) begin
                                rx_count <= rx_count - 1;
                            end
                        end
                    end
                end else begin
                    // No rx_baud_tick on this clock cycle
                    if (cpu_pop) begin
                        rx_count <= rx_count - 1;
                    end
                end
            end
        end
    end

    // CPU read
    wire [6:0] stat = {frame_err_r, rx_ovf_r, rx_full, rx_empty, tx_full, tx_empty, 1'b0};
    always @(*) begin
        rdata = 32'h0;
        if (sel) begin
            case (offset)
                8'h04: rdata = {24'h0, rx_empty ? 8'h0 : rx_fifo[rx_head % FIFO_DEPTH]};
                8'h08: rdata = {25'h0, stat};
                8'h0C: rdata = {25'h0, ctrl_r};
                8'h10: rdata = baud_div_r;
                default: rdata = 32'h0;
            endcase
        end
    end

    wire tx_ie = ctrl_r[5];
    wire rx_ie = ctrl_r[6];
    assign irq_tx = tx_ie && tx_empty;
    assign irq_rx = rx_ie && !rx_empty;

endmodule