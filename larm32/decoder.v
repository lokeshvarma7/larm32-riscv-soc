// =============================================================================
//  decoder.v  -  Instruction decoder  (rev 2 - RV32IMC compliance)
//
//  Changes from rev 1
//  ------------------
//  Added outputs for every privileged / Zicsr instruction class:
//    is_ecall   - ECALL   (opcode 1110011, funct12 000000000000)
//    is_ebreak  - EBREAK  (opcode 1110011, funct12 000000000001)
//    is_mret    - MRET    (opcode 1110011, funct12 001100000010)
//    is_wfi     - WFI     (opcode 1110011, funct12 000100000101)
//    is_fence   - FENCE   (opcode 0001111)  - includes FENCE.I (0001111 funct3=001)
//    is_csr     - any CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI
//    csr_addr   - CSR address field (instr[31:20]) when is_csr is asserted
//    csr_zimm   - zero-extended 5-bit immediate for CSRRWI/CSRRSI/CSRRCI
//
//  The existing outputs (opcode..shamt) are unchanged - no downstream logic
//  needs to be modified beyond hooking up the new wires.
// =============================================================================

`timescale 1ns/1ps

module decoder (
    input  wire [31:0] instr,

    // ---- Existing outputs (unchanged) -------------------------------------
    output wire [6:0]  opcode,
    output wire [4:0]  rd,
    output wire [2:0]  funct3,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [6:0]  funct7,
    output wire [4:0]  shamt,

    // ---- New: privileged / Zicsr instruction flags -----------------------
    output wire        is_ecall,    // environment call
    output wire        is_ebreak,   // breakpoint
    output wire        is_mret,     // machine-mode return from trap
    output wire        is_wfi,      // wait for interrupt
    output wire        is_fence,    // memory fence (FENCE + FENCE.I)
    output wire        is_csr,      // any CSR instruction (funct3 != 000)
    output wire [11:0] csr_addr,    // CSR address when is_csr is asserted
    output wire [31:0] csr_zimm     // zero-extended rs1 field for *I variants
);

    // -------------------------------------------------------------------------
    //  Standard RISC-V field extraction (unchanged)
    // -------------------------------------------------------------------------
    assign opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct7 = instr[31:25];
    assign shamt  = instr[24:20];   // shift amount (same bits as rs2)

    // -------------------------------------------------------------------------
    //  SYSTEM opcode (7'b1110011) sub-decoding
    // -------------------------------------------------------------------------
    wire        is_system = (instr[6:0] == 7'b1110011);
    wire [11:0] funct12   = instr[31:20];   // full 12-bit immediate for PRIV insns

    // PRIV sub-class: funct3 == 3'b000 selects privileged instructions
    wire        is_priv   = is_system && (funct3 == 3'b000);

    assign is_ecall  = is_priv && (funct12 == 12'b000000000000);
    assign is_ebreak = is_priv && (funct12 == 12'b000000000001);
    assign is_mret   = is_priv && (funct12 == 12'b001100000010);
    assign is_wfi    = is_priv && (funct12 == 12'b000100000101);

    // CSR instructions: SYSTEM opcode + funct3 != 000
    assign is_csr    = is_system && (funct3 != 3'b000);
    assign csr_addr  = instr[31:20];
    assign csr_zimm  = {27'b0, instr[19:15]};   // zero-extend 5-bit rs1 field

    // -------------------------------------------------------------------------
    //  FENCE / FENCE.I  (opcode 7'b0001111)
    // -------------------------------------------------------------------------
    assign is_fence  = (instr[6:0] == 7'b0001111);

endmodule