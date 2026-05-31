// =============================================================================
//  timer.v  -  Programmable Timer / Counter with PWM
//
//  Memory Map (relative to base, e.g. 0x10000200 or 0x10000300):
//    0x00  TMR_CTRL      Control
//    0x04  TMR_LOAD      Reload value
//    0x08  TMR_VAL       Current counter value (read-only)
//    0x0C  TMR_PRESCALE  Prescaler divisor
//    0x10  TMR_STAT      Status / interrupt flag (W1C bit[0])
//    0x14  TMR_CMP       Compare value (PWM duty)
//
//  TMR_CTRL bits:
//    [0] EN        Enable
//    [1] MODE      0=One-shot, 1=Periodic
//    [2] IE        Interrupt enable
//    [3] PWM_EN    PWM output enable
//    [4] DIR       0=Count down, 1=Count up
// =============================================================================
`timescale 1ns/1ps

module timer #(parameter BASE = 32'h1000_0200)(
    input  wire        clk,
    input  wire        rst,

    input  wire        sel,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    output wire        pwm_out,
    output wire        irq
);

    wire [7:0] offset = addr[7:0];

    reg [31:0] ctrl_r, load_r, val_r, prescale_r, cmp_r;
    reg        stat_r;  // interrupt flag

    wire en      = ctrl_r[0];
    wire periodic= ctrl_r[1];
    wire ie      = ctrl_r[2];
    wire pwm_en  = ctrl_r[3];
    wire count_up= ctrl_r[4];

    // Prescaler
    reg [31:0] pre_cnt;
    wire pre_tick = (pre_cnt == 32'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) pre_cnt <= 32'd0;
        else if (en) begin
            if (pre_tick) pre_cnt <= (prescale_r == 0) ? 0 : prescale_r - 1;
            else          pre_cnt <= pre_cnt - 1;
        end
    end

    // Counter
    wire terminal = count_up ? (val_r >= load_r) : (val_r == 32'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ctrl_r    <= 32'h0;
            load_r    <= 32'hFFFF_FFFF;
            val_r     <= 32'hFFFF_FFFF;
            prescale_r<= 32'h0;
            cmp_r     <= 32'h0;
            stat_r    <= 1'b0;
        end else begin
            // CPU write
            if (sel && we) begin
                case (offset)
                    8'h00: begin ctrl_r <= wdata; val_r <= load_r; end
                    8'h04: load_r    <= wdata;
                    8'h0C: prescale_r<= wdata;
                    8'h10: stat_r    <= stat_r & ~wdata[0];  // W1C
                    8'h14: cmp_r     <= wdata;
                endcase
            end
            // Counter logic
            if (en && pre_tick) begin
                if (terminal) begin
                    stat_r <= 1'b1;   // interrupt flag
                    if (periodic)
                        val_r <= count_up ? 32'd0 : load_r;
                    else
                        ctrl_r[0] <= 1'b0;  // stop one-shot
                end else begin
                    val_r <= count_up ? val_r + 1 : val_r - 1;
                end
            end
        end
    end

    // CPU read
    always @(*) begin
        rdata = 32'h0;
        if (sel) begin
            case (offset)
                8'h00: rdata = ctrl_r;
                8'h04: rdata = load_r;
                8'h08: rdata = val_r;
                8'h0C: rdata = prescale_r;
                8'h10: rdata = {31'h0, stat_r};
                8'h14: rdata = cmp_r;
                default: rdata = 32'h0;
            endcase
        end
    end

    assign pwm_out = pwm_en && (count_up ? (val_r < cmp_r) : (val_r > cmp_r));
    assign irq     = ie && stat_r;

endmodule