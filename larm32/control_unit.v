// =============================================================================
//  control_unit.v  -  Main decode / control signals  (rev 2 - RV32IMC)
//
//  Changes from rev 1
//  ------------------
//  Added outputs:
//    is_csr_instr  - steer rd writeback from CSR read data instead of ALU
//    is_ecall      - raise environment-call trap
//    is_ebreak     - raise breakpoint trap
//    is_mret       - machine return from trap (PC ? mepc, MIE restored)
//    is_wfi        - wait-for-interrupt  (single-cycle NOP in this impl)
//    is_fence      - fence (NOP in this single-core in-order impl)
//    is_illegal    - unrecognised opcode ? illegal-instruction trap
//
//  The existing outputs are untouched so the rest of the pipeline requires
//  no changes other than connecting the new wires.
// =============================================================================

`timescale 1ns/1ps

module control_unit (
    input  wire [6:0] opcode,
    input  wire [6:0] funct7,
    input  wire [2:0] funct3,
    // New: sub-decode inputs needed for SYSTEM class
    input  wire        is_ecall_dec,   // from decoder
    input  wire        is_ebreak_dec,  // from decoder
    input  wire        is_mret_dec,    // from decoder
    input  wire        is_wfi_dec,     // from decoder
    input  wire        is_fence_dec,   // from decoder
    input  wire        is_csr_dec,     // from decoder

    // ---- Existing outputs (unchanged) -------------------------------------
    output reg         reg_write,
    output reg         alu_src_imm,
    output reg         alu_sub,
    output reg         branch,
    output reg         mem_read,
    output reg         mem_write,
    output reg         mem_to_reg,
    output reg         jal,
    output reg         jalr,
    output reg         lui,
    output reg         auipc,
    output reg         alu_add,
    output wire        is_rtype,

    // ---- New outputs ------------------------------------------------------
    output reg         is_csr_instr,   // writeback from CSR read data
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         is_wfi,
    output reg         is_fence,
    output reg         is_illegal      // illegal instruction ? trap
);

    assign is_rtype = (opcode == 7'b0110011);

    always @(*) begin
        // Defaults
        reg_write    = 1'b0;
        alu_src_imm  = 1'b0;
        alu_sub      = 1'b0;
        branch       = 1'b0;
        mem_read     = 1'b0;
        mem_write    = 1'b0;
        mem_to_reg   = 1'b0;
        jal          = 1'b0;
        jalr         = 1'b0;
        lui          = 1'b0;
        auipc        = 1'b0;
        alu_add      = 1'b0;
        is_csr_instr = 1'b0;
        is_ecall     = 1'b0;
        is_ebreak    = 1'b0;
        is_mret      = 1'b0;
        is_wfi       = 1'b0;
        is_fence     = 1'b0;
        is_illegal   = 1'b0;

        case (opcode)
            7'b0110011: begin   // R-type
                reg_write   = 1'b1;
                alu_src_imm = 1'b0;
                alu_sub     = (funct7 == 7'b0100000) ? 1'b1 : 1'b0;
            end

            7'b0010011: begin   // I-type ALU
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                alu_sub     = 1'b0;
            end

            7'b1100011: begin   // B-type branch
                reg_write   = 1'b0;
                alu_src_imm = 1'b0;
                alu_sub     = 1'b1;
                branch      = 1'b1;
            end

            7'b0000011: begin   // LOAD
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                alu_sub     = 1'b0;
                mem_read    = 1'b1;
                mem_to_reg  = 1'b1;
                alu_add     = 1'b1;
            end

            7'b0100011: begin   // STORE
                reg_write   = 1'b0;
                alu_src_imm = 1'b1;
                alu_sub     = 1'b0;
                mem_write   = 1'b1;
                alu_add     = 1'b1;
            end

            7'b1101111: begin   // JAL
                reg_write   = 1'b1;
                jal         = 1'b1;
            end

            7'b1100111: begin   // JALR
                jalr        = 1'b1;
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                alu_sub     = 1'b0;
            end

            7'b0110111: begin   // LUI
                reg_write   = 1'b1;
                lui         = 1'b1;
            end

            7'b0010111: begin   // AUIPC
                reg_write   = 1'b1;
                auipc       = 1'b1;
            end

            7'b0001111: begin   // FENCE / FENCE.I
                // Single-core in-order: fence is a no-op (drain is implicit).
                // reg_write stays 0; no side effects.
                is_fence    = 1'b1;
            end

            7'b1110011: begin   // SYSTEM (ECALL / EBREAK / MRET / WFI / CSR*)
                if (is_csr_dec) begin
                    // CSR instructions write rd = old CSR value
                    reg_write    = 1'b1;
                    is_csr_instr = 1'b1;
                end else if (is_ecall_dec) begin
                    is_ecall     = 1'b1;
                end else if (is_ebreak_dec) begin
                    is_ebreak    = 1'b1;
                end else if (is_mret_dec) begin
                    is_mret      = 1'b1;
                end else if (is_wfi_dec) begin
                    // WFI: architecturally a hint; treated as NOP here.
                    is_wfi       = 1'b1;
                end else begin
                    is_illegal   = 1'b1;
                end
            end

            7'b0001011: begin   // Trig custom CORDIC opcode
                reg_write   = 1'b0;
                is_illegal  = 1'b0;
            end

            7'b0001100: begin   // Hyp custom CORDIC opcode
                reg_write   = 1'b0;
                is_illegal  = 1'b0;
            end

            default: begin
                // Unknown opcode - raise illegal-instruction trap
                is_illegal   = 1'b1;
            end
        endcase
    end

endmodule