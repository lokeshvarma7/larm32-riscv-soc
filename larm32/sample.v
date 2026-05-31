

module non_restoring_div(

    input clk,
    input rst,
    input wire start,
    input wire is_signed,
    input wire is_rem,
    input wire [31:0] dividend,
    input wire [31:0] divisor,
    output reg [31:0] result,
    output reg busy,
    output reg done );
    
    reg [63:0] rem;
    reg [31:0] div;
    reg [31:0] quo;
    reg [5:0] count;
    
    reg dividend_sign;
    reg divisor_sign;
    reg result_sign;
    reg [63:0] rem_next;
    reg [31:0]quo_next;
    reg [63:0] rem_final;
    reg [63:0] rem_tmp;
//    wire [31:0] final_rem;
//    wire [63:0] rem_corrected;
    
//    assign rem_corrected = rem_next[63] ? (rem_next + {32'b0, div}) : rem_next;
//    assign final_rem     = rem_corrected[31:0];
    
    always@(posedge clk or posedge rst) begin
        if(rst) begin
            busy <=1'b0;
            done <=1'b0;
            result <=32'b0;
            rem<=64'b0;
            quo<=32'b0;
            div<=32'b0;
            count<=6'b0;
        end
        else if(start && !busy)begin
            if(divisor==0) begin
                result<=is_rem?dividend:32'hFFFFFFFF;//division by zero
                done<=1'b1;
                busy<=1'b0;
            end
            else if(is_signed && dividend ==32'h80000000 && divisor == 32'hFFFFFFFF)begin
                result<=is_rem?32'b0:32'h80000000;
                done<=1'b1;
                busy<=1'b0;
            end
            else begin
                dividend_sign <=is_signed & dividend[31];
                divisor_sign <=is_signed & divisor[31];
                result_sign <=is_signed & (dividend[31] ^ divisor[31]);
                    
                rem<=64'b0;
                quo<=is_signed && dividend[31] ? -dividend :dividend;
                div<=is_signed && divisor[31] ? -divisor:divisor;
                count<=6'd32;
                busy<=1'b1;
                done<=1'b0;
            end
            
        end
        
        else if(busy)begin
            rem_next = {rem[62:0],quo[31]};
            quo_next = {quo[30:0],1'b0};  //shifting left operation
            
            if (rem_next[63]) 
                rem_next =rem_next +div;
            else 
                rem_next =rem_next - div ;
            quo_next[0] = ~rem_next[63];
            
            rem<=rem_next;
            quo<=quo_next;
            
            count<=count-1;
            
           if (count == 6'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            
                if (is_rem) begin
                    if (rem_next[63])
                        rem_tmp = rem_next + {32'b0, div};
                    else
                        rem_tmp = rem_next;
            
                    if (is_signed)
                        result <= dividend_sign ? -rem_tmp[31:0] : rem_tmp[31:0]; // REM
                    else
                        result <= rem_tmp[31:0];                                  // REMU
                end
                else begin
                    // DIV / DIVU
                    result <= result_sign ? -quo_next : quo_next;
                end
            
                rem <= rem_tmp;   // optional, but safe
            end

            
        end
        else begin
            done<=1'b0;
        end
    end

endmodule
