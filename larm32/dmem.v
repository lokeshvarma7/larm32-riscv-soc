// =============================================================================
//  dmem.v  -  Data Memory (byte-addressable, word-organized)
//
//  FIX: Read path now applies funct3-based byte/halfword extraction and
//       sign extension, matching the RISC-V load semantics:
//         LB  (funct3=000): sign-extended byte
//         LH  (funct3=001): sign-extended halfword
//         LW  (funct3=010): full word
//         LBU (funct3=100): zero-extended byte
//         LHU (funct3=101): zero-extended halfword
//
//  Write path uses funct3 for byte/halfword masking (unchanged from rev11).
//
//  Memory is word-organized: mem[word_addr] = 32-bit word.
//  Byte address ? word index: addr[31:2].
//  Byte lane    ? addr[1:0].
// =============================================================================

`timescale 1ns/1ps

module dmem #(
    parameter depth = 4096          // number of 32-bit words
)(
    input  wire        clk,
    input  wire [31:0] addr,        // byte address
    input  wire        mem_we,      // write enable
    input  wire [31:0] wdata,
    input  wire [2:0]  funct3,
    output wire [31:0] rdata
);

    // ?? Storage ??????????????????????????????????????????????????????????????
    reg [31:0] mem [0:depth-1];

    initial begin
        // For simulation on Harvard architecture: pre-initialize data memory
        // with the program hex so that ROM string reads (loads below 0x4000)
        // successfully find the data in DMEM.
        $readmemh("LARMRV32.hex", mem);
    end

    // ?? Word index & byte lane ????????????????????????????????????????????????
    wire [31:0] word_idx  = (addr >> 2) & (depth - 1);  // offset and wrap index within RAM bounds
    wire [1:0]  byte_lane = addr[1:0];          // byte offset within word

    // ?? Synchronous write with byte/halfword masking ???????????????????????
    always @(posedge clk) begin
        if (mem_we) begin
            case (funct3[1:0])
                2'b00: begin  // SB - store byte
                    case (byte_lane)
                        2'b00: mem[word_idx][ 7: 0] <= wdata[7:0];
                        2'b01: mem[word_idx][15: 8] <= wdata[7:0];
                        2'b10: mem[word_idx][23:16] <= wdata[7:0];
                        2'b11: mem[word_idx][31:24] <= wdata[7:0];
                    endcase
                end
                2'b01: begin  // SH - store halfword
                    case (byte_lane[1])
                        1'b0: mem[word_idx][15: 0] <= wdata[15:0];
                        1'b1: mem[word_idx][31:16] <= wdata[15:0];
                    endcase
                end
                default: begin  // SW - store word
                    mem[word_idx] <= wdata;
                end
            endcase
        end
    end

    // ?? Combinational read with funct3 extraction ??????????????????????????
    wire [31:0] raw_word = mem[word_idx];

    // Byte selected by byte_lane
    wire [7:0] byte_val =
        (byte_lane == 2'b00) ? raw_word[ 7: 0] :
        (byte_lane == 2'b01) ? raw_word[15: 8] :
        (byte_lane == 2'b10) ? raw_word[23:16] :
                               raw_word[31:24] ;

    // Halfword selected by byte_lane[1]
    wire [15:0] half_val =
        (byte_lane[1] == 1'b0) ? raw_word[15: 0] :
                                  raw_word[31:16] ;

    // Output mux based on funct3
    assign rdata =
        (funct3 == 3'b000) ? {{24{byte_val[7]}},  byte_val} :  // LB  sign-ext
        (funct3 == 3'b001) ? {{16{half_val[15]}}, half_val} :  // LH  sign-ext
        (funct3 == 3'b010) ? raw_word                        :  // LW  full word
        (funct3 == 3'b100) ? {24'b0, byte_val}              :  // LBU zero-ext
        (funct3 == 3'b101) ? {16'b0, half_val}              :  // LHU zero-ext
                             raw_word;                          // default: LW

endmodule