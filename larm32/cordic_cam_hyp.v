module cordic_cam_hyp (
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire signed [31:0] x_in,   // Q16.16

    output reg  signed [31:0] sinh_out,
    output reg  signed [31:0] cosh_out,
    output reg  signed [31:0] tanh_out,
    output reg  signed [31:0] exp_pos,
    output reg  signed [31:0] exp_neg,
    output reg  done
);

    //--------------------------------------------------
    // STATES
    //--------------------------------------------------
    localparam IDLE       = 5'd0;
    localparam MUL_X2     = 5'd1;
    localparam WAIT_X2    = 5'd2;
    localparam MUL_X3     = 5'd3;
    localparam WAIT_X3    = 5'd4;
    localparam MUL_X4     = 5'd5;
    localparam WAIT_X4    = 5'd6;
    localparam MUL_DIV6   = 5'd7;
    localparam WAIT_DIV6  = 5'd8;
    localparam MUL_DIV24  = 5'd9;
    localparam WAIT_DIV24 = 5'd10;
    localparam CALC_EXP   = 5'd11;
    localparam CALC_SHCH  = 5'd12;
    localparam DIV_TAN    = 5'd13;
    localparam WAIT_TAN   = 5'd14;
    localparam FINISH     = 5'd15;

    reg [4:0] state;

    //--------------------------------------------------
    // INTERNAL REGISTERS
    //--------------------------------------------------
    reg signed [31:0] x;
    reg signed [31:0] x2, x3, x4;
    reg signed [31:0] x3_div6, x4_div24;
    reg signed [31:0] sinh_tmp, cosh_tmp;

    //--------------------------------------------------
    // MULTIPLIER
    //--------------------------------------------------
    reg mul_start;
    reg signed [31:0] mul_a, mul_b;
    wire signed [63:0] mul_result;
    wire mul_done;
    reg mul_busy;
    reg mul_unsigned;
    reg mulhsu_mode;

    radix_4 MUL (
        .clk(clk),
        .rst(rst),
        .a(mul_a),
        .b(mul_b),
        .unsigned_mul(mul_unsigned),
        .mulhsu_mode(mulhsu_mode),
        .start(mul_start),
        .result(mul_result),
        .done(mul_done)
    );

    //--------------------------------------------------
    // DIVIDER
    //--------------------------------------------------
    reg div_start;
    reg signed [31:0] div_a, div_b;
    wire signed [31:0] div_result;
    wire div_done;

    non_restoring_div DIV (
        .clk(clk),
        .rst(rst),
        .start(div_start),
        .is_signed(1'b1),
        .is_rem(1'b0),
        .dividend(div_a),
        .divisor(div_b),
        .result(div_result),
        .busy(),
        .done(div_done)
    );

    //--------------------------------------------------
    // MUL BUSY TRACK
    //--------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            mul_busy <= 0;
        else begin
            if (mul_start)
                mul_busy <= 1;
            else if (mul_done)
                mul_busy <= 0;
        end
    end

    //--------------------------------------------------
    // FSM
    //--------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            done  <= 0;
            mul_start <= 0;
            div_start <= 0;

            x<=0; x2<=0; x3<=0; x4<=0;
            x3_div6<=0; x4_div24<=0;
            exp_pos<=0; exp_neg<=0;
            sinh_tmp<=0; cosh_tmp<=0;
            sinh_out<=0; cosh_out<=0; tanh_out<=0;
        end
        else begin

            mul_start <= 0;
            div_start <= 0;
            done <= 0;

            // DEFAULT MODE (IMPORTANT)
            mul_unsigned <= 1'b0;
            mulhsu_mode  <= 1'b0;

            case(state)

            IDLE:
                if(start) begin
                    x <= x_in;
                    state <= MUL_X2;
                end

            // x 
            MUL_X2: begin
                mul_a<=x; mul_b<=x; mul_start<=1;
                state<=WAIT_X2;
            end

            WAIT_X2:
                if(mul_done) begin
                    x2 <= mul_result[47:16];
                    state <= MUL_X3;
                end

            // x 
            MUL_X3: begin
                mul_a<=x2; mul_b<=x; mul_start<=1;
                state<=WAIT_X3;
            end

            WAIT_X3:
                if(mul_done) begin
                    x3 <= mul_result[47:16];
                    state <= MUL_X4;
                end

            // x?
            MUL_X4: begin
                mul_a<=x3; mul_b<=x; mul_start<=1;
                state<=WAIT_X4;
            end

            WAIT_X4:
                if(mul_done) begin
                    x4 <= mul_result[47:16];
                    state <= MUL_DIV6;
                end

            // x  / 6
            MUL_DIV6: begin
                mul_a<=x3;
                mul_b<=32'sd10923;
                mul_start<=1;
                state<=WAIT_DIV6;
            end

            WAIT_DIV6:
                if(mul_done) begin
                    x3_div6 <= mul_result[47:16];
                    state <= MUL_DIV24;
                end

            // x? / 24
            MUL_DIV24: begin
                mul_a<=x4;
                mul_b<=32'sd2731;
                mul_start<=1;
                state<=WAIT_DIV24;
            end

            WAIT_DIV24:
                if(mul_done) begin
                    x4_div24 <= mul_result[47:16];
                    state <= CALC_EXP;
                end

            CALC_EXP:
            begin
                exp_pos <= 32'sd65536 + x + (x2>>>1) + x3_div6 + x4_div24;
                exp_neg <= 32'sd65536 - x + (x2>>>1) - x3_div6 + x4_div24;
                state <= CALC_SHCH;
            end

            CALC_SHCH:
            begin
                sinh_tmp <= (exp_pos - exp_neg) >>> 1;
                cosh_tmp <= (exp_pos + exp_neg) >>> 1;
                state <= DIV_TAN;
            end

            DIV_TAN:
            begin
                div_a <= sinh_tmp <<< 16;
                div_b <= cosh_tmp;
                div_start <= 1;
                state <= WAIT_TAN;
            end

            WAIT_TAN:
                if(div_done) begin
                    tanh_out <= div_result;
                    state <= FINISH;
                end

            FINISH:
            begin
                sinh_out <= sinh_tmp;
                cosh_out <= cosh_tmp;
                done <= 1;
                state <= IDLE;
            end

            endcase
        end
    end

endmodule