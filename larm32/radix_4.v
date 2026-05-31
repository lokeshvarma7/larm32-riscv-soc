`timescale 1ns/1ps
//
//  radix_4.v  (rev 3 - two further fixes on top of rev 2)
//
//  BUGS FIXED vs rev 2:
//  --------------------
//  BUG-MULHSU-STALE-B
//      In FINISH the correction subtracts {b, 32'd0} where `b` is the INPUT
//      PORT, not a captured register.  By the time FINISH executes (~19 cycles
//      after LOAD) the pipeline has advanced and `b` holds the operand of the
//      NEXT instruction, not the one that was multiplied.  For mulhsu(-1, x)
//      this made the correction subtract the wrong value, producing 0 instead
//      of -1 in the upper word.
//      FIX: Latch `b` into `b_raw` at LOAD time; use `b_raw` in FINISH.
//
//  BUG-CORRECTED-VAR
//      `corrected` was declared as a module-level `reg` and assigned with a
//      blocking statement inside the clocked always block.  Some simulators
//      (including XSim) treat module-level regs with blocking assignments
//      inconsistently across delta cycles, yielding stale values for the
//      subsequent non-blocking `result <=` assignment.  This caused mulh and
//      mulhu upper-word results to read back 0 or garbage.
//      FIX: Eliminate the intermediate `corrected` variable entirely; compute
//      the final 64-bit value in a single expression and assign directly to
//      `result` with a non-blocking statement.
//
//  All rev-2 fixes (BUG-ACCUM, BUG-MULHSU algorithm) are retained.
//

module radix_4 (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        unsigned_mul,
    input  wire        mulhsu_mode,
    input  wire        start,
    output reg  [63:0] result,
    output reg         done
);

    // ------------------------------------------------------------------
    //  FSM states
    // ------------------------------------------------------------------
    localparam IDLE   = 2'd0;
    localparam LOAD   = 2'd1;
    localparam ACCUM  = 2'd2;
    localparam FINISH = 2'd3;

    reg [1:0]  state;

    // ------------------------------------------------------------------
    //  Datapath registers
    // ------------------------------------------------------------------
    reg [63:0] a_reg;       // current partial-product weight (a_mag << 2*count)
    reg [31:0] b_reg;       // remaining bits of b_mag, shifted right 2 each cycle
    reg [63:0] sum_reg;     // accumulator
    reg [4:0]  count;       // iteration counter (0..15)

    // Sign / magnitude decisions - captured at LOAD
    reg        sign;        // 1 -> negate final result
    reg        do_mulhsu;   // 1 -> subtract (b_raw << 32) correction after loop
    reg [31:0] b_raw;       // BUG-MULHSU-STALE-B fix: latch b at LOAD time

    // ------------------------------------------------------------------
    //  Magnitude inputs (combinational, only valid when start pulses)
    // ------------------------------------------------------------------
    wire [31:0] a_mag =
        (unsigned_mul || mulhsu_mode) ? a :
        (a[31] ? (~a + 1'b1) : a);

    wire [31:0] b_mag =
        (unsigned_mul || mulhsu_mode) ? b :
        (b[31] ? (~b + 1'b1) : b);

    // ------------------------------------------------------------------
    //  Radix-4 partial product (combinational, uses CURRENT a_reg/b_reg)
    // ------------------------------------------------------------------
    wire [1:0]  b_bits = b_reg[1:0];

    wire [63:0] partial =
        (b_bits == 2'b01) ?  a_reg :
        (b_bits == 2'b10) ? (a_reg << 1) :
        (b_bits == 2'b11) ? (a_reg + (a_reg << 1)) :
        64'd0;

    // ------------------------------------------------------------------
    //  FSM
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= IDLE;
            a_reg     <= 64'd0;
            b_reg     <= 32'd0;
            b_raw     <= 32'd0;
            sum_reg   <= 64'd0;
            count     <= 5'd0;
            sign      <= 1'b0;
            do_mulhsu <= 1'b0;
            result    <= 64'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)

            // ----------------------------------------------------------
            IDLE: begin
                if (start)
                    state <= LOAD;
            end

            // ----------------------------------------------------------
            LOAD: begin
                // ---- sign / correction flags ----
                if (mulhsu_mode) begin
                    // signed(a) x unsigned(b):
                    //   run unsigned loop over raw a and b,
                    //   then if a[31] subtract (b_raw << 32).
                    sign      <= 1'b0;
                    do_mulhsu <= a[31];
                end else if (unsigned_mul) begin
                    sign      <= 1'b0;
                    do_mulhsu <= 1'b0;
                end else begin
                    // signed x signed: negate iff operands have opposite signs
                    sign      <= a[31] ^ b[31];
                    do_mulhsu <= 1'b0;
                end

                // ---- latch raw b for mulhsu correction ----
                b_raw   <= b;           // BUG-MULHSU-STALE-B fix

                // ---- datapath init ----
                a_reg   <= {32'd0, a_mag};
                b_reg   <= b_mag;
                sum_reg <= 64'd0;
                count   <= 5'd0;
                state   <= ACCUM;
            end

            // ----------------------------------------------------------
            // One 64-bit accumulation per cycle; process 2 bits of b per step.
            // After 16 steps (count 0..15) the full 32-bit b has been consumed.
            // ----------------------------------------------------------
            ACCUM: begin
                sum_reg <= sum_reg + partial;   // full 64-bit add - no split
                a_reg   <= a_reg << 2;
                b_reg   <= b_reg >> 2;
                if (count == 5'd15) begin
                    count <= 5'd0;
                    state <= FINISH;
                end else begin
                    count <= count + 1'b1;
                end
            end

            // ----------------------------------------------------------
            FINISH: begin
                // BUG-CORRECTED-VAR fix: no intermediate reg variable.
                // Compute directly into result with a single non-blocking assign.
                // BUG-MULHSU-STALE-B fix: use b_raw (latched at LOAD), not port b.
                //
                // mulhsu correction: signed(a) x unsigned(b)
                //   = unsigned(a) x unsigned(b)  - (b_raw << 32) when a[31]=1
                if (do_mulhsu) begin
                    // mulhsu, a was negative: subtract correction
                    result <= sum_reg - {b_raw, 32'd0};
                end else if (sign) begin
                    // signed x signed, opposite signs: negate
                    result <= ~sum_reg + 1'b1;
                end else begin
                    // unsigned or same-sign signed: result is the raw sum
                    result <= sum_reg;
                end
                done  <= 1'b1;
                state <= IDLE;
            end

            endcase
        end
    end

endmodule