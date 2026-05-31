// =============================================================================
//  imm_gen.v  -  Immediate Generator for RV32I
//
//  FIX: B-type and J-type immediates were being left-shifted by 1 extra bit,
//       doubling all branch/jump offsets.  The RISC-V spec already implies
//       bit[0]=0 (all branches/jumps are at least 2-byte aligned); imm_gen
//       must reconstruct the offset by scattering the instruction bits and
//       appending exactly ONE implicit 1'b0 - no further shift.
//
//  Immediate formats (sign-extended to 32 bits):
//    I-type : instr[31:20]  (12-bit, bits [11:0])
//    S-type : instr[31:25] | instr[11:7]
//    B-type : instr[31] instr[7] instr[30:25] instr[11:8] 0
//    U-type : instr[31:12] 000000000000
//    J-type : instr[31] instr[19:12] instr[20] instr[30:21] 0
// =============================================================================

`timescale 1ns/1ps

module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm_gen
);
    wire [6:0] opcode = instr[6:0];

    always @(*) begin
        case (opcode)

            // I-type: ADDI, SLTI, ANDI, ORI, XORI, SLLI, SRLI, SRAI,
            //         LW, LH, LHU, LB, LBU, JALR
            7'b0010011,   // ALU immediate
            7'b0000011,   // Loads
            7'b1100111:   // JALR
                imm_gen = {{20{instr[31]}}, instr[31:20]};

            // S-type: SW, SH, SB
            7'b0100011:
                imm_gen = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            // B-type: BEQ, BNE, BLT, BGE, BLTU, BGEU
            //  Bit layout in instruction:
            //    instr[31]   = imm[12]
            //    instr[30:25]= imm[10:5]
            //    instr[11:8] = imm[4:1]
            //    instr[7]    = imm[11]
            //    bit[0] is always 0 (implicit, NOT a separate shift)
            7'b1100011:
                imm_gen = {{19{instr[31]}},
                           instr[31],       // imm[12]
                           instr[7],        // imm[11]
                           instr[30:25],    // imm[10:5]
                           instr[11:8],     // imm[4:1]
                           1'b0};           // imm[0] = 0

            // U-type: LUI, AUIPC
            7'b0110111,
            7'b0010111:
                imm_gen = {instr[31:12], 12'b0};

            // J-type: JAL
            //  Bit layout in instruction:
            //    instr[31]   = imm[20]
            //    instr[30:21]= imm[10:1]
            //    instr[20]   = imm[11]
            //    instr[19:12]= imm[19:12]
            //    bit[0] is always 0 (implicit, NOT a separate shift)
            7'b1101111:
                imm_gen = {{11{instr[31]}},
                           instr[31],       // imm[20]
                           instr[19:12],    // imm[19:12]
                           instr[20],       // imm[11]
                           instr[30:21],    // imm[10:1]
                           1'b0};           // imm[0] = 0

            // CSR / SYSTEM: zimm field in rs1 position [19:15]
            7'b1110011:
                imm_gen = {27'b0, instr[19:15]};   // zero-extended 5-bit zimm

            default:
                imm_gen = 32'h0;

        endcase
    end

endmodule