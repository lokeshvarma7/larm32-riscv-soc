module cordic_sct_trig (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire signed [15:0] angle_deg,

    output reg signed [11:0] sin_int,  
    output reg signed [11:0] cos_int,  
    output reg signed [11:0] tan_int,  
    output reg done
);

    // ==============================
    // INTERNAL SIGNALS
    // ==============================

    reg signed [15:0] atan_table [0:15];

    reg signed [15:0] x, y;
    reg signed [22:0] z;
    reg [4:0] iter;

    reg cordic_done;

    // Divider signals
    reg div_start;
    wire div_busy;
    wire div_done;
    wire [31:0] div_result;

    reg signed [31:0] div_dividend;
    reg signed [31:0] div_divisor;

    // FSM states
    reg [1:0] state;
    localparam IDLE = 2'd0,
               ITERATE = 2'd1,
               DIVIDE = 2'd2,
               FINISH = 2'd3;

    // ==============================
    // ATAN TABLE
    // ==============================
    initial begin
        atan_table[0]  = 16'd5760;
        atan_table[1]  = 16'd3390;
        atan_table[2]  = 16'd1790;
        atan_table[3]  = 16'd908;
        atan_table[4]  = 16'd456;
        atan_table[5]  = 16'd228;
        atan_table[6]  = 16'd114;
        atan_table[7]  = 16'd57;
        atan_table[8]  = 16'd28;
        atan_table[9]  = 16'd14;
        atan_table[10] = 16'd7;
        atan_table[11] = 16'd3;
        atan_table[12] = 16'd2;
        atan_table[13] = 16'd1;
        atan_table[14] = 16'd0;
        atan_table[15] = 16'd0;
    end

    // ==============================
    // DIVIDER INSTANCE
    // ==============================
    non_restoring_div divider_inst(
        .clk(clk),
        .rst(rst),
        .start(div_start),
        .is_signed(1'b1),
        .is_rem(1'b0),
        .dividend(div_dividend),
        .divisor(div_divisor),
        .result(div_result),
        .busy(div_busy),
        .done(div_done)
    );

    // ==============================
    // MAIN FSM
    // ==============================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 0;
            y <= 0;
            z <= 0;
            iter <= 0;
            sin_int <= 0;
            cos_int <= 0;
            tan_int <= 0;
            done <= 0;
            state <= IDLE;
            div_start <= 0;
        end else begin

            case(state)

            // ======================
            // IDLE
            // ======================
            IDLE: begin
                done <= 0;
                div_start <= 0;

                if(start) begin
                    x <= 16'd9949;
                    y <= 0;

                    // INTERNAL MULTIPLY BY 128
                    z <= angle_deg <<< 7;

                    iter <= 0;
                    state <= ITERATE;
                end
            end

            // ======================
            // CORDIC ITERATIONS
            // ======================
            ITERATE: begin
                if(iter < 16) begin

                    if (z >= 0) begin
                        x <= x - (y >>> iter);
                        y <= y + (x >>> iter);
                        z <= z - atan_table[iter];
                    end else begin
                        x <= x + (y >>> iter);
                        y <= y - (x >>> iter);
                        z <= z + atan_table[iter];
                    end

                    iter <= iter + 1;
                end
                else begin
                    // compute sin & cos immediately
                    sin_int <= y >>> 3;
                    cos_int <= x >>> 3;

                    // Prepare divider
                    div_dividend <= (y <<< 12);
                    div_divisor  <= x;
                    div_start <= 1;
                    state <= DIVIDE;
                end
            end

            // ======================
            // DIVISION STATE
            // ======================
            DIVIDE: begin
                div_start <= 0;

                if(div_done) begin
                    tan_int <= div_result[15:0] >>> 1;
                    state <= FINISH;
                end
            end

            // ======================
            // FINISH
            // ======================
            FINISH: begin
                done <= 1;
                state <= IDLE;
            end

            endcase
        end
    end

endmodule