module alu(
input wire [31:0]a,
input wire [31:0]b,
input wire [31:0]reg_rdata1,
input wire [31:0]reg_rdata2,
input wire sub,
input wire alu_add,
input wire [4:0]shamt,
input wire [2:0]funct3,
input wire [6:0]funct7,
input wire is_rtype,
output reg [31:0] result,
output wire zero,          // for beq and bne
output wire alu_neg,       // for signed branches (BLT/BGE)
output wire borrow,        // for unsigned branches (BLTU/BGEU)
output wire [31:0] sub_result  // a-b for branch condition flags
);
reg [63:0] mul_temp;
    always@(*)begin
        if(alu_add)begin
            result=a+b;
        end 
         else begin
            if (funct7 == 7'b0000001 && funct3 >=3'b100 )begin //M-extension
                case(funct3)
//                3'b000:begin mul_temp = $signed({{32{a[31]}},a}) * $signed({{32{b[31]}},b});
//                            result=mul_temp[31:0];
//                end//mul
//                3'b001:begin
//                mul_temp = $signed({{32{a[31]}},a})*$signed({{32{b[31]}},b}); 
//                result=mul_temp[63:32];
//                end//mulh upper 32 bits
//                3'b010:begin 
//                mul_temp= $signed({{32{a[31]}},a}) * $unsigned({32'b0,b});
//                       result=mul_temp[63:32];   
                      
//                end//mulhsu upper 32 bits
//               3'b011:begin 
//               mul_temp= $unsigned({32'b0,a})* $unsigned({32'b0,b});//mulhu upper 32 bits
//               result = mul_temp[63:32]; end
                default: result = 32'b0;
//                3'b100:begin
//                    if (b==32'b0) 
//                        result = 32'hFFFFFFFF;
//                    else if (a==32'h80000000 && b==32'hFFFFFFFF)
//                        result=32'h80000000;
//                    else
//                     result = $signed(a)/$signed(b);//div
//                end
//                3'b101:begin 
//                    if (b==32'b0)
//                        result = 32'hFFFFFFFF;
//                    else 
//                        result = a/b; // divu
                        
//                end
//                3'b110:begin
//                    if (b==32'b0)
//                        result = a;
//                    else if (a==32'h80000000 && b==32'hFFFFFFFF)
//                        result = 32'b0;
//                    else 
//                            result=$signed(a)%$signed(b); //Rem 
//                end
//                3'b111: begin
//                    if (b==32'b0)
//                        result=a;
//                    else 
//                        result=a%b;//remu
//                end
                endcase
            end 
            else begin
            case(funct3)
            3'b000: result = sub ? (a - b) : (a + b); // ADD / SUB
            3'b010: result = ($signed(a)<$signed(b)) ? 32'd1 : 32'd0;     // SLT (signed)
            3'b011: result = (a<b) ? 32'd1 : 32'd0;  // SLTU (unsigned)
            3'b100: result = a ^ b;
            3'b110: result = a | b;
            3'b111: result = a & b; 
            3'b001: 
            begin
            result = is_rtype?(a <<b[4:0]):(a<<shamt);
            end
            3'b101:
                    if (funct7 == 7'b0100000)begin
                        result = is_rtype?($signed(a)>>>b[4:0]):($signed(a)>>>shamt); //SRA SRAI
                     end else begin
                         result = is_rtype?(a>>b[4:0]):( a>>shamt);           //srl srli
                        end
             default: result = 32'd0;
            endcase
        end
       end
    end 
    assign sub_result = a-b;
    assign zero = (sub_result == 32'b0);
//            assign alu_neg=result[31];
            assign alu_neg=sub_result[31];
            assign borrow=(a<b);
endmodule