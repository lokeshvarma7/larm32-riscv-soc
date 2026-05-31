
module pc#(parameter addr_w=32)(
input wire clk,
input wire rst,
input wire pc_en,
input wire[addr_w-1:0]pc_next,
output reg [addr_w-1:0]pc);
always @(posedge clk or posedge rst)begin
    if(rst)begin
        pc<=0;
    end
    else if(pc_en)begin
        pc<=pc_next;
    end
end
endmodule
