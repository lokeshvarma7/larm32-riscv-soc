
module regfile#(parameter reg_count=32)(
    input wire clk,
    input wire rst,
    input wire [4:0]rd,
    input wire [4:0]rs1,
    input wire [4:0]rs2,
    input wire we,
    input wire [31:0]wd,
    output wire [31:0]rd1,
    output wire [31:0]rd2
    );
    integer i;
    reg [31:0]regs[0:reg_count-1];
//    assign rd1=(rs1==0)?32'b0:regs[rs1];
//    assign rd2=(rs2==0)?32'b0:regs[rs2];
    assign rd1 = (we && rd == rs1 && rd != 0) ? wd : regs[rs1];
    assign rd2 = (we && rd == rs2 && rd != 0) ? wd : regs[rs2];
    always@(posedge clk or posedge rst)begin
        if(rst) begin
             for(i=0;i<32;i=i+1)begin
              regs[i]<=32'b0; end  
                       regs[0]<=32'b0;end
        else if(we && rd!=0)begin
           regs[rd]<=wd; 
        end
    end
endmodule
