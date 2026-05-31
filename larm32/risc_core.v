// =============================================================================
//  risc_core.v  (rev 12 - testbench bug-fix release)
//
//  Fixes vs rev 11
//  ---------------
//  FIX-1  rvc_expander: PC[1] selects upper vs lower 16-bit half of the
//         fetched 32-bit word.  Without this, every compressed instruction
//         at a 2-byte-aligned address that is NOT 4-byte aligned (PC%4==2)
//         re-executed the first half of the previous word.
//         Symptoms: Test 10 x1=10(exp5), x2=0(exp7), x3=10(exp12).
//
//  FIX-2  EX/MEM forwarding for LUI/AUIPC/JAL/JALR:
//         The forwarding mux for forwardA==01 used ex_mem_alu_result,
//         which is WRONG for LUI (WB value = ex_mem_imm, not ALU result).
//         Added ex_mem_fwd_data register that captures the "real" WB value
//         as the instruction leaves EX, mirroring what MEM/WB will later write.
//         Symptoms: Test 3 all load/store failures (LUI?ADDI?SW stores 0x678).
//
//  FIX-3  CSR writeback timing:
//         The old code used `id_ex_is_csr` and `id_ex_csr_rdata` in the
//         MEM/WB always block - but by the time MEM/WB fires, id_ex holds
//         the NEXT instruction.  Added ex_mem_csr_rdata and ex_mem_is_csr
//         (already existed) to latch the old-CSR-value correctly.
//         Symptoms: Test 8 CSRRWI x5 = 0x40 (exp 0), mtvec final = 1 (exp 11).
//
//  FIX-4  CSR mcause readback one cycle after trap:
//         csr_rdata_id_wire was an async read of the register BEFORE write.
//         For the first CSR read inside the trap handler (immediately after
//         ECALL), mcause had not yet been committed to the register because
//         trap_enter arrives in the same cycle as the CSR read begins.
//         Fix: csr_regfile now updates mcause synchronously at trap_enter and
//         the id-stage read port is fully combinational from the updated reg.
//         Symptoms: Test 9 x10=8 (exp 11).
//
//  FIX-5  minstret counter:
//         instret_inc was wired as (mem_wb_valid && !pipeline_stall).
//         mem_wb_valid is 0 for the NOP bubbles that the pipeline emits
//         during reset and stalls, so the counter under-counts.
//         Fixed: use ex_mem_valid (instruction retiring from EX stage) with
//         a simple one-cycle pulse, matching how cycle_count is counted.
//         Symptoms: Test 12 minstret = 0.
//
//  All rev-11 features retained:
//    rvc_expander, csr_regfile, trap controller, dcache, CORDIC extensions,
//    Radix-4 multiplier, non-restoring divider, 2-bit branch predictor.
// =============================================================================

`timescale 1ns/1ps

// ======================================================================
//  CACHE-DMEM BRIDGE  (unchanged)
// ======================================================================
module cache_mem_bridge #(parameter depth = 4096)(
    input  wire        clk,
    input  wire        mem_req,  input  wire        mem_rw,
    input  wire [31:0] mem_addr, input  wire [31:0] mem_wdata,
    output wire [31:0] mem_rdata,output wire        mem_ready,
    input  wire [2:0]  mem_funct3
);
    wire [31:0] dmem_rdata_wire;
    // For cache fills (reads) always fetch the full 32-bit word so the cache
    // stores a complete word.  Byte/halfword extraction is done by the dcache
    // using the latched miss_funct3.  Writes still use the real funct3 for
    // correct SB/SH/SW byte-lane masking.
    wire [2:0] effective_funct3 = mem_rw ? mem_funct3 : 3'b010;
    dmem #(.depth(depth)) backing_mem (
        .clk(clk), .addr(mem_addr), .mem_we(mem_req & mem_rw),
        .wdata(mem_wdata), .funct3(effective_funct3), .rdata(dmem_rdata_wire));
    assign mem_rdata = dmem_rdata_wire;
    assign mem_ready = 1'b1;
endmodule


// ======================================================================
//  RVC EXPANDER  - FIX-1: PC[1] selects which 16-bit half to expand
// ======================================================================
module rvc_expander (
    input  wire [31:0] instr_in,   // raw 32-bit word from imem
    input  wire        pc1,        // PC[1]: 0 ? use [15:0], 1 ? use [31:16]
    output reg  [31:0] instr_out,  // expanded 32-bit instruction
    output wire        is_rvc      // 1 if compressed (PC advances by 2)
);
    // Select the correct 16-bit half based on PC[1]
    wire [15:0] ci = pc1 ? instr_in[31:16] : instr_in[15:0];

    assign is_rvc = (ci[1:0] != 2'b11);

    // Compressed register specifiers (x8-x15)
    wire [4:0] rdp  = {2'b01, ci[4:2]};
    wire [4:0] rs1p = {2'b01, ci[9:7]};
    wire [4:0] rs2p = {2'b01, ci[4:2]};  // same field as rdp

    // Full register specifiers
    wire [4:0] rd_f  = ci[11:7];
    wire [4:0] rs1_f = ci[11:7];
    wire [4:0] rs2_f = ci[6:2];

    // Immediates
    wire [31:0] imm_ci    = {{26{ci[12]}}, ci[12], ci[6:2]};          // ADDI/LI/ANDI
    wire [31:0] imm_lui   = {{14{ci[12]}}, ci[12], ci[6:2], 12'b0};   // C.LUI
    wire [31:0] imm_addi16= {{22{ci[12]}},
                              ci[12], ci[4:3], ci[5], ci[2], ci[6], 4'b0}; // C.ADDI16SP
    wire [31:0] imm_lw    = {25'b0, ci[5], ci[12:10], ci[6], 2'b0};  // C.LW/C.SW offset
    wire [31:0] imm_4spn  = {22'b0, ci[10:7], ci[12:11], ci[5], ci[6], 2'b0}; // C.ADDI4SPN
    wire [31:0] imm_lwsp  = {24'b0, ci[3:2], ci[12], ci[6:4], 2'b0};
    wire [31:0] imm_swsp  = {24'b0, ci[8:7], ci[12:9], 2'b0};
    wire [31:0] imm_j     = {{20{ci[12]}},
                              ci[12], ci[8], ci[10:9], ci[6],
                              ci[7],  ci[2], ci[11],   ci[5:3], 1'b0};
    wire [31:0] imm_b     = {{23{ci[12]}},
                              ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};

    always @(*) begin
        instr_out = 32'h0000_0013; // default NOP (catches illegal compressed)
        if (!is_rvc) begin
            // 32-bit instruction: pass through whichever half we didn't pick,
            // combined with the other half from the raw word.
            // When pc1=0 the full word is aligned; when pc1=1 we can't
            // represent it (unaligned 32-bit) - keep NOP (will trap).
            instr_out = pc1 ? 32'h0000_0013 : instr_in;
        end else begin
            case (ci[1:0])
            2'b00: begin  // Quadrant 0
                case (ci[15:13])
                3'b000: // C.ADDI4SPN ? ADDI rdp, x2, nzuimm
                    instr_out = {imm_4spn[11:0], 5'd2, 3'b000, rdp, 7'b0010011};
                3'b010: // C.LW ? LW rdp, offset(rs1p)
                    instr_out = {imm_lw[11:0], rs1p, 3'b010, rdp, 7'b0000011};
                3'b110: // C.SW ? SW rs2p, offset(rs1p)
                    instr_out = {imm_lw[11:5], rs2p, rs1p, 3'b010,
                                 imm_lw[4:0], 7'b0100011};
                default: instr_out = 32'h0; // illegal ? trap
                endcase
            end
            2'b01: begin  // Quadrant 1
                case (ci[15:13])
                3'b000: // C.NOP / C.ADDI
                    instr_out = (rd_f == 5'b0) ? 32'h0000_0013 :
                                {imm_ci[11:0], rd_f, 3'b000, rd_f, 7'b0010011};
                3'b001: // C.JAL ? JAL x1, offset
                    instr_out = {imm_j[20], imm_j[10:1], imm_j[11],
                                 imm_j[19:12], 5'd1, 7'b1101111};
                3'b010: // C.LI ? ADDI rd, x0, imm
                    instr_out = {imm_ci[11:0], 5'b0, 3'b000, rd_f, 7'b0010011};
                3'b011: // C.ADDI16SP or C.LUI
                    instr_out = (rd_f == 5'd2) ?
                        {imm_addi16[11:0], 5'd2, 3'b000, 5'd2, 7'b0010011} :
                        {imm_lui[31:12], rd_f, 7'b0110111};
                3'b100: begin  // Arithmetic / shift group
                    case (ci[11:10])
                    2'b00: // C.SRLI
                        instr_out = {7'b0000000, ci[6:2], rs1p, 3'b101, rs1p, 7'b0010011};
                    2'b01: // C.SRAI
                        instr_out = {7'b0100000, ci[6:2], rs1p, 3'b101, rs1p, 7'b0010011};
                    2'b10: // C.ANDI
                        instr_out = {imm_ci[11:0], rs1p, 3'b111, rs1p, 7'b0010011};
                    2'b11: begin
                        case ({ci[12], ci[6:5]})
                        3'b000: instr_out={7'b0100000,rs2p,rs1p,3'b000,rs1p,7'b0110011}; // SUB
                        3'b001: instr_out={7'b0000000,rs2p,rs1p,3'b100,rs1p,7'b0110011}; // XOR
                        3'b010: instr_out={7'b0000000,rs2p,rs1p,3'b110,rs1p,7'b0110011}; // OR
                        3'b011: instr_out={7'b0000000,rs2p,rs1p,3'b111,rs1p,7'b0110011}; // AND
                        default: instr_out=32'h0;
                        endcase
                    end
                    endcase
                end
                3'b101: // C.J ? JAL x0, offset
                    instr_out = {imm_j[20], imm_j[10:1], imm_j[11],
                                 imm_j[19:12], 5'b0, 7'b1101111};
                3'b110: // C.BEQZ ? BEQ rs1p, x0, offset
                    instr_out = {imm_b[12],imm_b[10:5],5'b0,rs1p,
                                 3'b000,imm_b[4:1],imm_b[11],7'b1100011};
                3'b111: // C.BNEZ ? BNE rs1p, x0, offset
                    instr_out = {imm_b[12],imm_b[10:5],5'b0,rs1p,
                                 3'b001,imm_b[4:1],imm_b[11],7'b1100011};
                endcase
            end
            2'b10: begin  // Quadrant 2
                case (ci[15:13])
                3'b000: // C.SLLI
                    instr_out = {7'b0000000, ci[6:2], rd_f, 3'b001, rd_f, 7'b0010011};
                3'b010: // C.LWSP ? LW rd, offset(x2)
                    instr_out = {imm_lwsp[11:0], 5'd2, 3'b010, rd_f, 7'b0000011};
                3'b100: begin
                    if (!ci[12]) begin
                        if (rs2_f == 5'b0)  // C.JR ? JALR x0, rs1, 0
                            instr_out = {12'h0, rs1_f, 3'b000, 5'b0, 7'b1100111};
                        else                // C.MV ? ADD rd, x0, rs2
                            instr_out = {7'b0, rs2_f, 5'b0, 3'b000, rd_f, 7'b0110011};
                    end else begin
                        if (rs1_f==0 && rs2_f==0) // C.EBREAK
                            instr_out = 32'h0010_0073;
                        else if (rs2_f == 5'b0)   // C.JALR ? JALR x1, rs1, 0
                            instr_out = {12'h0, rs1_f, 3'b000, 5'd1, 7'b1100111};
                        else                       // C.ADD ? ADD rd, rd, rs2
                            instr_out = {7'b0, rs2_f, rd_f, 3'b000, rd_f, 7'b0110011};
                    end
                end
                3'b110: // C.SWSP ? SW rs2, offset(x2)
                    instr_out = {imm_swsp[11:5], rs2_f, 5'd2, 3'b010,
                                 imm_swsp[4:0], 7'b0100011};
                default: instr_out = 32'h0;
                endcase
            end
            default: instr_out = instr_in; // should not reach (is_rvc guards)
            endcase
        end
    end
endmodule


// ======================================================================
//  CSR REGISTER FILE - FIX-4: combinational read, sync write
// ======================================================================
module csr_regfile (
    input  wire        clk, rst,

    // EX-stage write port
    input  wire        csr_en,
    input  wire [11:0] csr_addr,
    input  wire [2:0]  csr_funct3,
    input  wire [31:0] csr_wdata,   // rs1 value or zimm (pre-selected)
    output wire [31:0] csr_rdata,   // current value (post-write this cycle)
    
    // ID-stage pre-read port (old value for writeback)
    input  wire [11:0] id_csr_addr,
    output wire [31:0] id_csr_rdata,

    output wire        csr_illegal,

    // Trap interface
    input  wire        trap_enter,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_tval,
    input  wire        mret_en,
    output wire [31:0] trap_ret_pc,
    output wire        mie_global,
    output wire [31:0] mtvec_out,

    // Performance counters
    input  wire        cycle_inc,
    input  wire        instret_inc
);
    // Machine-mode CSRs
    reg [31:0] mstatus_r;   // [3]=MIE, [7]=MPIE, [12:11]=MPP
    reg [31:0] mie_r;
    reg [31:0] mtvec_r;
    reg [31:0] mscratch_r;
    reg [31:0] mepc_r;
    reg [31:0] mcause_r;
    reg [31:0] mtval_r;
    reg [63:0] mcycle_r;
    reg [63:0] minstret_r;

    localparam MISA = 32'h4000_1104; // RV32IMC + X(CORDIC)

    // Combinational read: returns CURRENT register value
    function [31:0] csr_read;
        input [11:0] addr;
        begin
            case (addr)
            12'h300: csr_read = mstatus_r;
            12'h301: csr_read = MISA;
            12'h304: csr_read = mie_r;
            12'h305: csr_read = mtvec_r;
            12'h340: csr_read = mscratch_r;
            12'h341: csr_read = mepc_r;
            12'h342: csr_read = mcause_r;
            12'h343: csr_read = mtval_r;
            12'hB00: csr_read = mcycle_r[31:0];
            12'hB80: csr_read = mcycle_r[63:32];
            12'hB02: csr_read = minstret_r[31:0];
            12'hB82: csr_read = minstret_r[63:32];
            12'hF14: csr_read = 32'h0;   // mhartid
            12'hF11: csr_read = 32'h0;   // mvendorid
            default: csr_read = 32'h0;
            endcase
        end
    endfunction

    assign csr_rdata    = csr_read(csr_addr);
    // id_csr_rdata forwarding: if the EX stage is currently writing the same
    // CSR that the ID stage is about to read, forward the new (post-write)
    // value so back-to-back CSR instructions see a consistent value.
    function [31:0] csr_new_value;
        input [11:0] addr;
        input [31:0] wdata;
        input [2:0]  f3;
        begin
            csr_new_value = apply_op(csr_read(addr), wdata, f3);
        end
    endfunction
    assign id_csr_rdata = (csr_en && (csr_addr == id_csr_addr)) ?
                          csr_new_value(csr_addr, csr_wdata, csr_funct3) :
                          csr_read(id_csr_addr);
    assign csr_illegal  = 1'b0; // extend if needed

    assign mtvec_out   = mtvec_r;
    assign mie_global  = mstatus_r[3];
    assign trap_ret_pc = mepc_r;

    // CSRRW / CSRRS / CSRRC write logic
    function [31:0] apply_op;
        input [31:0] old;
        input [31:0] wdata;
        input [2:0]  f3;
        begin
            // f3[1:0]: 01=RW, 10=RS, 11=RC  (f3[2] selects zimm vs rs1, already resolved)
            case (f3[1:0])
            2'b01: apply_op = wdata;
            2'b10: apply_op = old | wdata;
            2'b11: apply_op = old & ~wdata;
            default: apply_op = old;
            endcase
        end
    endfunction

    // Performance counters
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mcycle_r   <= 64'h0;
            minstret_r <= 64'h0;
        end else begin
            if (cycle_inc)   mcycle_r   <= mcycle_r   + 1;
            if (instret_inc) minstret_r <= minstret_r + 1;
        end
    end
      reg [31:0] nv;
                      reg [31:0] nv2;

    // Main CSR register update
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mstatus_r  <= 32'h0000_1800; // MPP=11 (M-mode), MIE=0
            mie_r      <= 32'h0;
            mtvec_r    <= 32'h0000_0000; // default trap vector (overridden by test)
            mscratch_r <= 32'h0;
            mepc_r     <= 32'h0;
            mcause_r   <= 32'h0;
            mtval_r    <= 32'h0;
        end
        else if (trap_enter) begin
            // Save state, disable interrupts
            mstatus_r[7]     <= mstatus_r[3]; // MPIE = MIE
            mstatus_r[3]     <= 1'b0;         // MIE  = 0
            mstatus_r[12:11] <= 2'b11;        // MPP  = M-mode
            mepc_r   <= {trap_pc[31:1], 1'b0};
            mcause_r <= trap_cause;
            mtval_r  <= trap_tval;
        end
        else if (mret_en) begin
            mstatus_r[3] <= mstatus_r[7]; // MIE = MPIE
            mstatus_r[7] <= 1'b1;
        end
        else if (csr_en) begin
            case (csr_addr)
            12'h300: begin
              
                nv = apply_op(mstatus_r, csr_wdata, csr_funct3);
                mstatus_r[3]     <= nv[3];
                mstatus_r[7]     <= nv[7];
                mstatus_r[12:11] <= nv[12:11];
            end
            12'h304: mie_r      <= apply_op(mie_r,      csr_wdata, csr_funct3) & 32'h0000_0888;
            12'h305: mtvec_r    <= apply_op(mtvec_r,    csr_wdata, csr_funct3);
            12'h340: mscratch_r <= apply_op(mscratch_r, csr_wdata, csr_funct3);
            12'h341: begin
                nv2 = apply_op(mepc_r, csr_wdata, csr_funct3);
                mepc_r <= {nv2[31:1], 1'b0};
            end
            12'h342: mcause_r   <= apply_op(mcause_r,   csr_wdata, csr_funct3);
            12'h343: mtval_r    <= apply_op(mtval_r,    csr_wdata, csr_funct3);
            default: ;
            endcase
        end
    end
endmodule


// ======================================================================
//  TOP-LEVEL RISC CORE  (rev 12)
// ======================================================================
(* DONT_TOUCH = "yes" *) (* KEEP_HIERARCHY = "yes" *)
module risc_core #(
    parameter data_width  = 32,
    parameter instr_width = 32,
    parameter reg_count   = 32,
    parameter addr_w      = 32,
    parameter dmem_depth  = 4096
)(
    input  wire clk,
    input  wire rst
);

    // ?? MUL / DIV / CORDIC wires (unchanged from rev11) ?????????????????
    reg  mul_busy, mul_start, mul_issued, mul_done_r;
    reg  [31:0] mul_op_a, mul_op_b;
    reg  [4:0]  mul_rd;
    wire [63:0] mul_result;
    wire        mul_done;
    wire        is_mul, is_mulh, is_mulhsu, is_mulhu;
    reg         mul_unsigned, mul_wb_is_upper, mul_wb_is_mulhsu;
    reg         mul_is_mulh, mul_is_mulhu, mul_is_mulhsu;

    wire is_div, is_divu, is_rem, is_remu;
    reg  div_busy, div_start, div_issued, div_done_r;
    reg  [31:0] div_op_a, div_op_b;
    reg  [4:0]  div_rd;
    wire [31:0] div_result;
    wire        div_done;
    reg         div_is_signed, div_is_rem;
    reg         trig_executed, hyp_executed;

    wire        is_trig_op;
    reg         trig_busy, trig_issued, trig_start;
    reg  [4:0]  trig_rd;
    reg  [2:0]  trig_funct3;
    reg  [31:0] trig_operand, trig_cached_operand;
    wire        trig_done_raw;
    reg         trig_done_r;
    wire        trig_done_pulse = trig_done_raw & ~trig_done_r;
    reg         trig_result_valid, trig_wb_pending;
    wire        trig_reuse_done;
    wire signed [11:0] trig_sin_out, trig_cos_out, trig_tan_out;
    reg  signed [11:0] trig_sin_reg, trig_cos_reg, trig_tan_reg;
    wire [31:0] trig_sin_32 = {{20{trig_sin_reg[11]}}, trig_sin_reg};
    wire [31:0] trig_cos_32 = {{20{trig_cos_reg[11]}}, trig_cos_reg};
    wire [31:0] trig_tan_32 = {{20{trig_tan_reg[11]}}, trig_tan_reg};
    (* KEEP="yes" *) reg [2:0] id_ex_funct3;
    wire [31:0] trig_wb_data =
        (trig_funct3    == 3'b000) ? trig_sin_32 :
        (trig_funct3    == 3'b001) ? trig_cos_32 : trig_tan_32;
    wire [31:0] trig_fwd_data =
        (id_ex_funct3 == 3'b000) ? trig_sin_32 :
        (id_ex_funct3 == 3'b001) ? trig_cos_32 : trig_tan_32;

    wire        is_hyp_op;
    reg         hyp_busy, hyp_issued, hyp_start;
    reg  [4:0]  hyp_rd;
    reg  [2:0]  hyp_funct3;
    reg  [31:0] hyp_operand, hyp_cached_operand;
    wire        hyp_done_raw;
    reg         hyp_done_r;
    wire        hyp_done_pulse = hyp_done_raw & ~hyp_done_r;
    reg         hyp_result_valid, hyp_wb_pending;
    wire        hyp_reuse_done;
    wire signed [31:0] hyp_sinh_out,hyp_cosh_out,hyp_tanh_out,hyp_exp_pos,hyp_exp_neg;
    reg  signed [31:0] hyp_sinh_reg,hyp_cosh_reg,hyp_tanh_reg,hyp_exp_pos_reg,hyp_exp_neg_reg;
    wire [31:0] hyp_wb_data =
        (hyp_funct3==3'b000)?hyp_sinh_reg:(hyp_funct3==3'b001)?hyp_cosh_reg:
        (hyp_funct3==3'b010)?hyp_tanh_reg:(hyp_funct3==3'b011)?hyp_exp_pos_reg:hyp_exp_neg_reg;
    wire [31:0] hyp_fwd_data =
        (id_ex_funct3==3'b000)?hyp_sinh_reg:(id_ex_funct3==3'b001)?hyp_cosh_reg:
        (id_ex_funct3==3'b010)?hyp_tanh_reg:(id_ex_funct3==3'b011)?hyp_exp_pos_reg:hyp_exp_neg_reg;

    (* KEEP="yes" *) reg halt;
    (* KEEP="yes" *) reg [63:0] cycle_count, instr_count, stall_count;
    (* KEEP="yes" *) reg [63:0] branch_flush_count, cache_miss_count;

    localparam reg_addr_w = $clog2(reg_count);

    // ?? PC / pipeline signals ?????????????????????????????????????????????
    wire [addr_w-1:0] pc, pc_next;
    wire        pc_src, branch, alu_zero, alu_neg, alu_borrow;
    wire [31:0] imm_gen, fwd_imm_gen;
    wire [2:0]  funct3;
    wire        jal, jalr;
    wire [31:0] jalr_target;
    wire        lui, auipc, alu_add_for_addr;
    wire [31:0] sub_result;
    wire        pipeline_stall, later_stage_stall, mul_stall, div_stall, trig_stall, hyp_stall;
    wire        trig_will_start, hyp_will_start, cache_stall;
    wire        load_use_hazard;

    // ?? CSR / trap wires ??????????????????????????????????????????????????
    wire        is_ecall_dec, is_ebreak_dec, is_mret_dec, is_wfi_dec;
    wire        is_fence_dec, is_csr_dec;
    wire [11:0] csr_addr_dec;
    wire [31:0] csr_zimm_dec;
    wire        cu_is_csr, cu_is_ecall, cu_is_ebreak, cu_is_mret;
    wire        cu_is_wfi, cu_is_fence, cu_is_illegal;

    (* KEEP="yes" *) reg        id_ex_is_csr;
    (* KEEP="yes" *) reg [11:0] id_ex_csr_addr;
    (* KEEP="yes" *) reg [31:0] id_ex_csr_wdata, id_ex_csr_rdata;
    (* KEEP="yes" *) reg [2:0]  id_ex_csr_funct3;
    (* KEEP="yes" *) reg        id_ex_is_ecall, id_ex_is_ebreak, id_ex_is_mret;
    (* KEEP="yes" *) reg        id_ex_is_wfi, id_ex_is_fence, id_ex_is_illegal;

    // FIX-3: EX/MEM CSR fields for correct writeback timing
    (* KEEP="yes" *) reg        ex_mem_is_csr;
    (* KEEP="yes" *) reg [31:0] ex_mem_csr_rdata; // old CSR value latched at EX?MEM

    wire        trap_taken, trap_enter, mret_en;
    wire [31:0] trap_cause, trap_tval, trap_ret_pc, mtvec_out;
    wire        mie_global;
    wire        csr_en;
    wire [11:0] csr_addr_pipe;
    wire [2:0]  csr_funct3_pipe;
    wire [31:0] csr_wdata_pipe, csr_rdata_wire, csr_rdata_id_wire;

    // ?? IF/ID register ????????????????????????????????????????????????????
    (* KEEP="yes" *) reg [31:0] if_id_pc, if_id_instr;
    (* KEEP="yes" *) reg        if_id_is_branch, if_id_predict_taken;

    // ?? ID/EX register ????????????????????????????????????????????????????
    (* KEEP="yes" *) reg [31:0] id_ex_pc, id_ex_rdata1, id_ex_rdata2, id_ex_imm;
    (* KEEP="yes" *) reg [4:0]  id_ex_rd, id_ex_rs1, id_ex_rs2, id_ex_shamt;
    (* KEEP="yes" *) reg [6:0]  id_ex_funct7;
    (* KEEP="yes" *) reg        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
    (* KEEP="yes" *) reg        id_ex_mem_to_reg, id_ex_alu_src, id_ex_alu_sub;
    (* KEEP="yes" *) reg        id_ex_branch, id_ex_jal, id_ex_jalr;
    (* KEEP="yes" *) reg        id_ex_lui, id_ex_auipc, id_ex_alu_add;
    (* KEEP="yes" *) reg        id_ex_is_branch, id_ex_valid, id_ex_is_halt;
    (* KEEP="yes" *) reg        id_ex_predict_taken, id_ex_is_trig, id_ex_is_hyp;
    (* KEEP="yes" *) reg        id_ex_is_rtype;
    (* KEEP="yes" *) reg        id_ex_is_mul, id_ex_is_mulh, id_ex_is_mulhu, id_ex_is_mulhsu;
    (* KEEP="yes" *) reg        id_ex_is_div, id_ex_is_rem, id_ex_div_signed;
    (* KEEP="yes" *) reg        mul_active;

    // ?? Branch predictor ??????????????????????????????????????????????????
    (* KEEP="yes" *) reg [1:0] pht [0:63];
    wire [5:0] pht_idx_if = pc[7:2];
    wire [5:0] pht_idx_ex = id_ex_pc[7:2];
    wire predict_taken_if = pht[pht_idx_if][1];

    // ?? EX/MEM register ???????????????????????????????????????????????????
    (* KEEP="yes" *) reg [31:0] ex_mem_alu_result, ex_mem_rdata2;
    (* KEEP="yes" *) reg [4:0]  ex_mem_rd;
    (* KEEP="yes" *) reg [2:0]  ex_mem_funct3;
    (* KEEP="yes" *) reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    (* KEEP="yes" *) reg        ex_mem_mem_to_reg, ex_mem_jal, ex_mem_jalr;
    (* KEEP="yes" *) reg        ex_mem_lui, ex_mem_auipc;
    (* KEEP="yes" *) reg [31:0] ex_mem_pc, ex_mem_imm;
    (* KEEP="yes" *) reg        ex_mem_branch, ex_mem_valid;
    // FIX-2: precomputed forward value so EX/MEM forwarding is always correct
    (* KEEP="yes" *) reg [31:0] ex_mem_fwd_data;

    wire actual_taken = pc_src;
    wire mispredict   = id_ex_valid && id_ex_is_branch &&
                        (actual_taken != id_ex_predict_taken);
    wire [31:0] branch_target_ex = id_ex_pc + id_ex_imm;
    wire [31:0] correct_pc       = actual_taken ? branch_target_ex : (id_ex_pc + 4);

    // ?? MEM/WB register ???????????????????????????????????????????????????
    reg  [31:0] mem_wb_data;
    (* KEEP="yes" *) reg [4:0]  mem_wb_rd;
    (* KEEP="yes" *) reg        mem_wb_reg_write, mem_wb_mem_write;
    (* KEEP="yes" *) reg        mem_wb_from_mul_div, mem_wb_valid;

    reg [1:0] forwardA, forwardB;
    (* KEEP="yes" *) reg prev_pipeline_stall;
    wire        mul_will_start, div_will_start;
    wire [31:0] alu_b_final;
    wire [4:0]  rd, rs1, rs2;

    wire [31:0] mul_fwd_data = mul_wb_is_upper ? mul_result[63:32] : mul_result[31:0];

    // FIX-2: forwarding uses ex_mem_fwd_data (correct for LUI/AUIPC/JAL/JALRinstrs)
    wire [31:0] alu_in1 =
        (mul_done        && mul_rd  != 0 && mul_rd  == id_ex_rs1) ? mul_fwd_data   :
        (div_done        && div_rd  != 0 && div_rd  == id_ex_rs1) ? div_result     :
        (trig_done_pulse && trig_rd != 0 && trig_rd == id_ex_rs1) ? trig_fwd_data  :
        (hyp_done_pulse  && hyp_rd  != 0 && hyp_rd  == id_ex_rs1) ? hyp_fwd_data   :
        (forwardA == 2'b01) ? ex_mem_fwd_data :   // ? was ex_mem_alu_result
        (forwardA == 2'b10) ? mem_wb_data      :
        id_ex_rdata1;

    wire [31:0] alu_in2_raw =
        (mul_done        && mul_rd  != 0 && mul_rd  == id_ex_rs2) ? mul_fwd_data   :
        (div_done        && div_rd  != 0 && div_rd  == id_ex_rs2) ? div_result     :
        (trig_done_pulse && trig_rd != 0 && trig_rd == id_ex_rs2) ? trig_fwd_data  :
        (hyp_done_pulse  && hyp_rd  != 0 && hyp_rd  == id_ex_rs2) ? hyp_fwd_data   :
        (forwardB == 2'b01) ? ex_mem_fwd_data :   // ? was ex_mem_alu_result
        (forwardB == 2'b10) ? mem_wb_data      :
        id_ex_rdata2;

    assign load_use_hazard =
           id_ex_valid && id_ex_mem_read && (id_ex_rd != 0) &&
           (id_ex_rd == rs1 || id_ex_rd == rs2);

    assign pc_src =
        (id_ex_branch && id_ex_funct3==3'b000 &&  alu_zero)  ||
        (id_ex_branch && id_ex_funct3==3'b001 && !alu_zero)  ||
        (id_ex_branch && id_ex_funct3==3'b100 &&  alu_neg)   ||
        (id_ex_branch && id_ex_funct3==3'b101 && !alu_neg)   ||
        (id_ex_branch && id_ex_funct3==3'b110 &&  alu_borrow)||
        (id_ex_branch && id_ex_funct3==3'b111 && !alu_borrow);

    // ?? Trap logic ????????????????????????????????????????????????????????
    wire is_halt_instr = id_ex_valid && id_ex_is_halt;
    assign trap_taken = id_ex_valid && !id_ex_is_halt &&
                        (id_ex_is_ecall || id_ex_is_ebreak || id_ex_is_illegal);
    assign mret_en    = id_ex_valid && id_ex_is_mret;
    assign trap_enter = trap_taken;
    assign trap_cause =
        id_ex_is_ecall   ? 32'h0000_000B :
        id_ex_is_ebreak  ? 32'h0000_0003 :
        id_ex_is_illegal ? 32'h0000_0002 : 32'h0;
    assign trap_tval  = id_ex_is_illegal ? id_ex_imm : 32'h0;

    wire do_redirect  = trap_taken || mret_en || mispredict || id_ex_jal || id_ex_jalr;
    wire [31:0] redirect_pc =
        trap_taken ? ({mtvec_out[31:2],2'b00} +
                      (mtvec_out[0] ? (trap_cause<<2) : 32'h0)) :
        mret_en    ? trap_ret_pc  :
        mispredict ? correct_pc   :
        id_ex_jalr ? jalr_target  :
                     (id_ex_pc + id_ex_imm);

    // ?? RVC fetch ?????????????????????????????????????????????????????????
    wire [31:0] instr_raw;
    wire [31:0] instr_fetch;
    wire        is_rvc_fetch;

    wire [31:0] imm_gen_if;
    wire        is_branch_if     = (instr_fetch[6:0] == 7'b1100011);
    wire [31:0] branch_target_if = pc + imm_gen_if;
    wire [31:0] pc_inc           = is_rvc_fetch ? 32'd2 : 32'd4;

    assign pc_next =
        do_redirect                        ? redirect_pc      :
        (is_branch_if && predict_taken_if) ? branch_target_if :
        pc + pc_inc;

    // ?? CSR EX wiring ?????????????????????????????????????????????????????
    assign csr_en          = id_ex_valid && id_ex_is_csr;
    assign csr_addr_pipe   = id_ex_csr_addr;
    assign csr_funct3_pipe = id_ex_csr_funct3;
    assign csr_wdata_pipe  = id_ex_csr_funct3[2] ? id_ex_csr_wdata : alu_in1;

    // ????????????????????????????????????????????????????????????????????
    //  SUBMODULE INSTANCES
    // ????????????????????????????????????????????????????????????????????

    (* DONT_TOUCH="yes" *)
    pc inst_pc (.clk(clk),.rst(rst),
        .pc_en(!halt && !pipeline_stall),.pc_next(pc_next),.pc(pc));

    (* DONT_TOUCH="yes" *)
    imem inst_imem (.addr(pc),.instr(instr_raw));

    // FIX-1: pass pc[1] so the expander selects the correct 16-bit half
    (* DONT_TOUCH="yes" *)
    rvc_expander rvc_exp_inst (
        .instr_in(instr_raw), .pc1(pc[1]),
        .instr_out(instr_fetch), .is_rvc(is_rvc_fetch));

    wire [6:0] funct7, opcode;
    assign opcode = if_id_instr[6:0];
    wire [4:0] shift_count;

    (* DONT_TOUCH="yes" *)
    decoder decoder_inst (
        .instr(if_id_instr), .opcode(opcode), .rd(rd), .rs1(rs1), .rs2(rs2),
        .funct3(funct3), .funct7(funct7), .shamt(shift_count),
        .is_ecall(is_ecall_dec), .is_ebreak(is_ebreak_dec),
        .is_mret(is_mret_dec),   .is_wfi(is_wfi_dec),
        .is_fence(is_fence_dec), .is_csr(is_csr_dec),
        .csr_addr(csr_addr_dec), .csr_zimm(csr_zimm_dec));

    (* DONT_TOUCH="yes" *)
    imm_gen imm_gen_inst  (.instr(if_id_instr), .imm_gen(imm_gen));
    (* DONT_TOUCH="yes" *)
    imm_gen imm_gen_if_inst (.instr(instr_fetch), .imm_gen(imm_gen_if));

    wire [31:0] reg_rdata1, reg_rdata2;
    wire        reg_write;

    (* DONT_TOUCH="yes" *)
    regfile #(.reg_count(reg_count)) regfile_inst (
        .clk(clk),.rst(rst),.rd(mem_wb_rd),.rs1(rs1),.rs2(rs2),
        .we(mem_wb_reg_write),.wd(mem_wb_data),.rd1(reg_rdata1),.rd2(reg_rdata2));

    wire [31:0] alu_result;
    wire        alu_sub, alu_src_imm, mem_to_reg, is_rtype;

    assign alu_b_final = id_ex_alu_src ? id_ex_imm : alu_in2_raw;

    (* DONT_TOUCH="yes" *)
    alu alu_inst (
        .a(alu_in1), .b(alu_b_final),
        .reg_rdata1(alu_in1), .reg_rdata2(alu_b_final),
        .sub(id_ex_alu_sub), .result(alu_result),
        .zero(alu_zero), .alu_neg(alu_neg), .borrow(alu_borrow),
        .funct3(id_ex_funct3), .funct7(id_ex_funct7), .shamt(id_ex_shamt),
        .sub_result(sub_result), .alu_add(id_ex_alu_add), .is_rtype(id_ex_is_rtype));

    wire mem_read, mem_write;
    assign jalr_target = {alu_result[31:1], 1'b0};

    (* DONT_TOUCH="yes" *)
    control_unit cu_inst (
        .opcode(opcode), .funct7(funct7), .funct3(funct3),
        .is_ecall_dec(is_ecall_dec), .is_ebreak_dec(is_ebreak_dec),
        .is_mret_dec(is_mret_dec),   .is_wfi_dec(is_wfi_dec),
        .is_fence_dec(is_fence_dec), .is_csr_dec(is_csr_dec),
        .reg_write(reg_write), .alu_src_imm(alu_src_imm), .alu_sub(alu_sub),
        .branch(branch), .mem_read(mem_read), .mem_write(mem_write),
        .mem_to_reg(mem_to_reg), .jal(jal), .jalr(jalr),
        .lui(lui), .auipc(auipc), .alu_add(alu_add_for_addr), .is_rtype(is_rtype),
        .is_csr_instr(cu_is_csr), .is_ecall(cu_is_ecall),
        .is_ebreak(cu_is_ebreak),  .is_mret(cu_is_mret),
        .is_wfi(cu_is_wfi), .is_fence(cu_is_fence), .is_illegal(cu_is_illegal));

    // FIX-5: instret counts instructions retiring from EX/MEM (valid, non-stall)
    wire instret_pulse = ex_mem_valid && !pipeline_stall &&
                         !mul_stall && !div_stall && !trig_stall && !hyp_stall;

    (* DONT_TOUCH="yes" *)
    csr_regfile csr_inst (
        .clk(clk), .rst(rst),
        .csr_en(csr_en), .csr_addr(csr_addr_pipe),
        .csr_funct3(csr_funct3_pipe), .csr_wdata(csr_wdata_pipe),
        .csr_rdata(csr_rdata_wire),
        .id_csr_addr(csr_addr_dec), .id_csr_rdata(csr_rdata_id_wire),
        .csr_illegal(),
        .trap_enter(trap_enter), .trap_pc(id_ex_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval),
        .mret_en(mret_en), .trap_ret_pc(trap_ret_pc),
        .mie_global(mie_global), .mtvec_out(mtvec_out),
        .cycle_inc(!halt), .instret_inc(instret_pulse));  // FIX-5

    // ?? DCACHE + BRIDGE ???????????????????????????????????????????????????
    wire cache_req_valid, cache_req_ready, cache_req_rw;
    wire [31:0] cache_req_addr, cache_req_wdata;
    wire [2:0]  cache_req_funct3;
    wire cache_resp_valid, cache_resp_ready;
    wire [31:0] cache_resp_rdata;
    wire cache_mem_req, cache_mem_rw;
    wire [31:0] cache_mem_addr, cache_mem_wdata, cache_mem_rdata;
    wire cache_mem_ready;

    assign cache_req_valid  = ex_mem_valid && (ex_mem_mem_read||ex_mem_mem_write);
    assign cache_req_rw     = ex_mem_mem_write;
    assign cache_req_addr   = ex_mem_alu_result;
    assign cache_req_wdata  = ex_mem_rdata2;
    assign cache_req_funct3 = ex_mem_funct3;
    assign cache_resp_ready = 1'b1;
    assign cache_stall      = ex_mem_valid && ex_mem_mem_read && !cache_resp_valid;

    (* DONT_TOUCH="yes" *)
    dcache #(.SETS(32)) dcache_inst (
        .clk(clk),.rst(rst),
        .req_valid(cache_req_valid),.req_ready(cache_req_ready),
        .req_rw(cache_req_rw),.req_addr(cache_req_addr),
        .req_wdata(cache_req_wdata),.req_funct3(cache_req_funct3),
        .resp_valid(cache_resp_valid),.resp_ready(cache_resp_ready),
        .resp_rdata(cache_resp_rdata),
        .mem_req(cache_mem_req),.mem_rw(cache_mem_rw),
        .mem_addr(cache_mem_addr),.mem_wdata(cache_mem_wdata),
        .mem_rdata(cache_mem_rdata),.mem_ready(cache_mem_ready));

    (* DONT_TOUCH="yes" *)
    cache_mem_bridge #(.depth(dmem_depth)) bridge_inst (
        .clk(clk),.mem_req(cache_mem_req),.mem_rw(cache_mem_rw),
        .mem_addr(cache_mem_addr),.mem_wdata(cache_mem_wdata),
        .mem_rdata(cache_mem_rdata),.mem_ready(cache_mem_ready),
        .mem_funct3(cache_req_funct3));

    // ?? Multiplier / Divider / CORDIC ?????????????????????????????????????
    (* DONT_TOUCH="yes" *)
    radix_4 multiplier (.clk(clk),.rst(rst),
        .a(mul_op_a),.b(mul_op_b),.start(mul_start),.done(mul_done),
        .unsigned_mul(mul_unsigned),.mulhsu_mode(mul_wb_is_mulhsu),.result(mul_result));

    (* DONT_TOUCH="yes" *)
    non_restoring_div divider (.clk(clk),.rst(rst),
        .start(div_start),.is_signed(div_is_signed),.is_rem(div_is_rem),
        .dividend(div_op_a),.divisor(div_op_b),.result(div_result),.busy(),.done(div_done));

    (* DONT_TOUCH="yes" *)
    cordic_sct_trig cordic_trig_inst (.clk(clk),.rst(rst),.start(trig_start),
        .angle_deg(trig_operand[15:0]),
        .sin_int(trig_sin_out),.cos_int(trig_cos_out),.tan_int(trig_tan_out),.done(trig_done_raw));

    (* DONT_TOUCH="yes" *)
    cordic_cam_hyp cordic_hyp_inst (.clk(clk),.rst(rst),.start(hyp_start),
        .x_in(hyp_operand),
        .sinh_out(hyp_sinh_out),.cosh_out(hyp_cosh_out),.tanh_out(hyp_tanh_out),
        .exp_pos(hyp_exp_pos),.exp_neg(hyp_exp_neg),.done(hyp_done_raw));

    // ?? CORDIC done edge detect + output latches ??????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin trig_done_r<=0; hyp_done_r<=0; end
        else     begin trig_done_r<=trig_done_raw; hyp_done_r<=hyp_done_raw; end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin trig_sin_reg<=0;trig_cos_reg<=0;trig_tan_reg<=0; end
        else if (trig_done_pulse) begin
            trig_sin_reg<=trig_sin_out; trig_cos_reg<=trig_cos_out; trig_tan_reg<=trig_tan_out;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hyp_sinh_reg<=0;hyp_cosh_reg<=0;hyp_tanh_reg<=0;
            hyp_exp_pos_reg<=0;hyp_exp_neg_reg<=0;
        end else if (hyp_done_pulse) begin
            hyp_sinh_reg<=hyp_sinh_out; hyp_cosh_reg<=hyp_cosh_out;
            hyp_tanh_reg<=hyp_tanh_out; hyp_exp_pos_reg<=hyp_exp_pos;
            hyp_exp_neg_reg<=hyp_exp_neg;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin trig_wb_pending<=0; hyp_wb_pending<=0; end
        else     begin trig_wb_pending<=trig_done_pulse; hyp_wb_pending<=hyp_done_pulse; end
    end

    // ?? Performance counters ??????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) cycle_count<=0; else if (!halt) cycle_count<=cycle_count+1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) instr_count<=0;
        else if (!halt) begin
            if (mul_done||div_done||trig_done_pulse||trig_reuse_done||
                hyp_done_pulse||hyp_reuse_done)
                instr_count<=instr_count+1;
            else if ((ex_mem_valid&&ex_mem_reg_write&&ex_mem_rd!=0)||
                     (ex_mem_valid&&ex_mem_mem_write)||(ex_mem_valid&&ex_mem_branch))
                instr_count<=instr_count+1;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) cache_miss_count<=0;
        else if (cache_mem_req&&!cache_mem_rw) cache_miss_count<=cache_miss_count+1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) halt<=0; else if (is_halt_instr) halt<=1;
    end

    // ?? IF/ID register ????????????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_pc<=0; if_id_instr<=32'h0000_0013;
            if_id_is_branch<=0; if_id_predict_taken<=0;
        end else if (halt) begin end
        else if (do_redirect) begin
            if_id_instr<=32'h0000_0013; if_id_pc<=0;
            if_id_is_branch<=0; if_id_predict_taken<=0;
        end else if (pipeline_stall) begin end
        else begin
            if_id_pc<=pc; if_id_instr<=instr_fetch;
            if_id_is_branch<=is_branch_if; if_id_predict_taken<=predict_taken_if;
        end
    end

    // ?? ID/EX register ????????????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_pc<=0; id_ex_rdata1<=0; id_ex_rdata2<=0; id_ex_imm<=0;
            id_ex_rd<=0; id_ex_funct3<=0; id_ex_funct7<=0; id_ex_reg_write<=0;
            id_ex_mem_read<=0; id_ex_mem_write<=0; id_ex_mem_to_reg<=0;
            id_ex_alu_src<=0; id_ex_alu_sub<=0; id_ex_branch<=0;
            id_ex_jal<=0; id_ex_jalr<=0; id_ex_lui<=0; id_ex_auipc<=0;
            id_ex_alu_add<=0; id_ex_rs1<=0; id_ex_rs2<=0; id_ex_shamt<=0;
            id_ex_valid<=0; id_ex_is_branch<=0; id_ex_is_halt<=0;
            id_ex_is_mul<=0; id_ex_is_mulh<=0; id_ex_is_mulhu<=0; id_ex_is_mulhsu<=0;
            id_ex_is_div<=0; id_ex_is_rem<=0; id_ex_div_signed<=0;
            id_ex_predict_taken<=0; mul_active<=0;
            id_ex_is_trig<=0; id_ex_is_hyp<=0; id_ex_is_rtype<=0;
            id_ex_is_csr<=0; id_ex_csr_addr<=0; id_ex_csr_wdata<=0;
            id_ex_csr_funct3<=0; id_ex_csr_rdata<=0;
            id_ex_is_ecall<=0; id_ex_is_ebreak<=0; id_ex_is_mret<=0;
            id_ex_is_wfi<=0; id_ex_is_fence<=0; id_ex_is_illegal<=0;
        end
        else if (later_stage_stall) begin
            // Freeze - later stage is stalled, so keep current state
        end
        else if (load_use_hazard) begin
            // Inject bubble
            id_ex_valid<=0; id_ex_mem_read<=0; id_ex_reg_write<=0;
            id_ex_mem_write<=0; id_ex_branch<=0; id_ex_jal<=0; id_ex_jalr<=0;
            id_ex_is_mul<=0; id_ex_is_mulh<=0; id_ex_is_mulhu<=0; id_ex_is_mulhsu<=0;
            id_ex_is_div<=0; id_ex_is_rem<=0; id_ex_div_signed<=0;
            id_ex_predict_taken<=0;
            id_ex_is_trig<=0; id_ex_is_hyp<=0; id_ex_is_rtype<=0;
            id_ex_is_csr<=0; id_ex_is_ecall<=0; id_ex_is_ebreak<=0;
            id_ex_is_mret<=0; id_ex_is_wfi<=0; id_ex_is_fence<=0; id_ex_is_illegal<=0;
        end
        else if (do_redirect) begin
            id_ex_valid<=0; id_ex_is_branch<=0; id_ex_reg_write<=0;
            id_ex_mem_read<=0; id_ex_mem_write<=0; id_ex_jal<=0; id_ex_jalr<=0;
            id_ex_branch<=0; id_ex_lui<=0; id_ex_auipc<=0;
            id_ex_is_mul<=0; id_ex_is_mulh<=0; id_ex_is_mulhu<=0; id_ex_is_mulhsu<=0;
            id_ex_is_div<=0; id_ex_is_rem<=0; id_ex_div_signed<=0;
            id_ex_predict_taken<=0;
            id_ex_is_trig<=0; id_ex_is_hyp<=0; id_ex_is_rtype<=0;
            id_ex_is_csr<=0; id_ex_is_ecall<=0; id_ex_is_ebreak<=0;
            id_ex_is_mret<=0; id_ex_is_wfi<=0; id_ex_is_fence<=0; id_ex_is_illegal<=0;
        end
        else begin
            id_ex_pc        <= if_id_pc;
            id_ex_rdata1    <= reg_rdata1;
            id_ex_rdata2    <= reg_rdata2;
            id_ex_imm       <= imm_gen;
            id_ex_rd        <= ((opcode==7'b0100011)||(opcode==7'b1100011)) ? 5'b0 : rd;
            id_ex_funct3    <= funct3;
            id_ex_funct7    <= funct7;
            id_ex_reg_write <= reg_write;
            id_ex_mem_read  <= mem_read;
            id_ex_mem_write <= mem_write;
            id_ex_mem_to_reg<= mem_to_reg;
            id_ex_alu_src   <= alu_src_imm;
            id_ex_alu_sub   <= alu_sub;
            id_ex_branch    <= branch;
            id_ex_jal       <= jal;
            id_ex_jalr      <= jalr;
            id_ex_lui       <= lui;
            id_ex_auipc     <= auipc;
            id_ex_alu_add   <= alu_add_for_addr;
            id_ex_rs1       <= rs1;
            id_ex_rs2       <= rs2;
            id_ex_shamt     <= shift_count;
            id_ex_valid     <= 1'b1;
            id_ex_is_branch <= if_id_is_branch;
            id_ex_is_halt   <= (if_id_instr == 32'hFFFFFFFF);
            id_ex_is_mul    <= is_mul;    id_ex_is_mulh   <= is_mulh;
            id_ex_is_mulhu  <= is_mulhu;  id_ex_is_mulhsu <= is_mulhsu;
            id_ex_is_div    <= is_div||is_divu;
            id_ex_is_rem    <= is_rem||is_remu;
            id_ex_div_signed<= is_div||is_rem;
            id_ex_predict_taken <= if_id_predict_taken;
            id_ex_is_trig   <= is_trig_op;
            id_ex_is_hyp    <= is_hyp_op;
            id_ex_is_rtype  <= is_rtype;
            id_ex_is_csr    <= cu_is_csr;
            id_ex_csr_addr  <= csr_addr_dec;
            id_ex_csr_wdata <= csr_zimm_dec;
            id_ex_csr_funct3<= funct3;
            id_ex_csr_rdata <= csr_rdata_id_wire; // old value (pre-write) for WB
            id_ex_is_ecall  <= cu_is_ecall;
            id_ex_is_ebreak <= cu_is_ebreak;
            id_ex_is_mret   <= cu_is_mret;
            id_ex_is_wfi    <= cu_is_wfi;
            id_ex_is_fence  <= cu_is_fence;
            id_ex_is_illegal<= cu_is_illegal;
        end
    end

    // FIX-2: compute true WB value at EX stage (used for both forwarding and WB)
    wire [31:0] ex_stage_fwd_data =
        (id_ex_is_csr)              ? id_ex_csr_rdata    : // FIX-3 also: correct timing
        (id_ex_jal || id_ex_jalr)   ? (id_ex_pc + 4)     :
        id_ex_lui                   ? id_ex_imm           :
        id_ex_auipc                 ? (id_ex_pc + id_ex_imm) :
                                      alu_result;

    // ?? EX/MEM register ???????????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_alu_result<=0; ex_mem_rdata2<=0; ex_mem_rd<=0;
            ex_mem_reg_write<=0; ex_mem_mem_read<=0; ex_mem_mem_write<=0;
            ex_mem_mem_to_reg<=0; ex_mem_jal<=0; ex_mem_jalr<=0;
            ex_mem_lui<=0; ex_mem_auipc<=0; ex_mem_pc<=0; ex_mem_imm<=0;
            ex_mem_branch<=0; ex_mem_valid<=0; ex_mem_funct3<=0;
            ex_mem_is_csr<=0; ex_mem_csr_rdata<=0;
            ex_mem_fwd_data<=0;  // FIX-2
        end
        else if (cache_stall||mul_stall||div_stall||trig_stall||hyp_stall) begin
            // Freeze
        end
        else begin
            ex_mem_alu_result <= alu_result;
            ex_mem_rdata2     <=
                (mul_done&&mul_rd!=0&&mul_rd==id_ex_rs2)         ? mul_fwd_data  :
                (div_done&&div_rd!=0&&div_rd==id_ex_rs2)         ? div_result    :
                (trig_done_pulse&&trig_rd!=0&&trig_rd==id_ex_rs2)? trig_fwd_data :
                (hyp_done_pulse&&hyp_rd!=0&&hyp_rd==id_ex_rs2)   ? hyp_fwd_data  :
                (mem_wb_reg_write&&mem_wb_rd!=0&&mem_wb_rd==id_ex_rs2) ? mem_wb_data :
                alu_in2_raw;
            ex_mem_rd          <= id_ex_rd;
            ex_mem_reg_write   <= id_ex_reg_write &&
                                  !(id_ex_is_mul||id_ex_is_mulh||id_ex_is_mulhu||id_ex_is_mulhsu||
                                    id_ex_is_div||id_ex_is_rem||id_ex_is_trig||id_ex_is_hyp);
            ex_mem_mem_read    <= id_ex_mem_read;
            ex_mem_mem_write   <= id_ex_mem_write;
            ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
            ex_mem_jal         <= id_ex_jal;
            ex_mem_jalr        <= id_ex_jalr;
            ex_mem_lui         <= id_ex_lui;
            ex_mem_auipc       <= id_ex_auipc;
            ex_mem_pc          <= id_ex_pc;
            ex_mem_imm         <= id_ex_imm;
            ex_mem_funct3      <= id_ex_funct3;
            ex_mem_branch      <= id_ex_branch;
            ex_mem_is_csr      <= id_ex_is_csr;
            ex_mem_csr_rdata   <= id_ex_csr_rdata;    // FIX-3: carry old value
            ex_mem_fwd_data    <= ex_stage_fwd_data;  // FIX-2: true WB value
            ex_mem_valid       <= id_ex_valid && !trap_taken;
        end
    end

    // ?? MUL FSM (unchanged) ???????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mul_busy<=0;mul_start<=0;mul_issued<=0;mul_done_r<=0;
            mul_op_a<=0;mul_op_b<=0;mul_rd<=0;
            mul_is_mulh<=0;mul_is_mulhu<=0;mul_unsigned<=0;mul_is_mulhsu<=0;
            mul_wb_is_upper<=0;mul_wb_is_mulhsu<=0;
        end else begin
            mul_start<=0;
            if ((!mul_busy||mul_done)&&(!mul_issued||mul_done)&&
                !mul_done&&id_ex_valid&&!cache_stall&&
                (id_ex_is_mul||id_ex_is_mulh||id_ex_is_mulhu||id_ex_is_mulhsu)) begin
                mul_op_a<=alu_in1; mul_op_b<=alu_in2_raw; mul_rd<=id_ex_rd;
                mul_is_mulh<=id_ex_is_mulh; mul_is_mulhu<=id_ex_is_mulhu;
                mul_unsigned<=id_ex_is_mulhu; mul_is_mulhsu<=id_ex_is_mulhsu;
                mul_start<=1; mul_busy<=1; mul_issued<=1;
                mul_wb_is_upper<=id_ex_is_mulh||id_ex_is_mulhu||id_ex_is_mulhsu;
                mul_wb_is_mulhsu<=id_ex_is_mulhsu;
            end
            if (mul_done) begin mul_busy<=0;mul_issued<=0;mul_done_r<=1; end
            else mul_done_r<=0;
        end
    end

    // ?? DIV FSM (unchanged) ???????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_busy<=0;div_start<=0;div_issued<=0;div_done_r<=0;
            div_op_a<=0;div_op_b<=0;div_rd<=0;div_is_signed<=0;div_is_rem<=0;
        end else begin
            div_start<=0;
            if ((!div_busy||div_done)&&(!div_issued||div_done)&&
                !div_done&&id_ex_valid&&!cache_stall&&(id_ex_is_div||id_ex_is_rem)) begin
                div_op_a<=alu_in1; div_op_b<=alu_in2_raw; div_rd<=id_ex_rd;
                div_is_signed<=id_ex_div_signed; div_is_rem<=id_ex_is_rem;
                div_start<=1; div_busy<=1; div_issued<=1;
            end
            if (div_done) begin div_busy<=0;div_issued<=0;div_done_r<=1; end
            else div_done_r<=0;
        end
    end

    // ?? TRIG CORDIC FSM (unchanged) ???????????????????????????????????????
    assign trig_reuse_done = id_ex_valid && !cache_stall && id_ex_is_trig && trig_result_valid &&
                             !trig_busy && !trig_done_pulse && (alu_in1==trig_cached_operand);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            trig_busy<=0;trig_start<=0;trig_issued<=0;trig_result_valid<=0;
            trig_operand<=0;trig_rd<=0;trig_funct3<=0;trig_cached_operand<=32'hFFFFFFFF;
            trig_executed <= 0;
        end else begin
            trig_start<=0;
            if (!later_stage_stall && !load_use_hazard) begin
                trig_executed <= 0;
            end else if (trig_start) begin
                trig_executed <= 1;
            end

            if (id_ex_valid&&!cache_stall&&id_ex_is_trig&&trig_result_valid&&!trig_busy&&
                !trig_done_pulse&&!trig_executed&&(alu_in1!=trig_cached_operand)) begin
                trig_result_valid<=0; trig_operand<=alu_in1; trig_cached_operand<=alu_in1;
                trig_rd<=id_ex_rd; trig_funct3<=id_ex_funct3;
                trig_start<=1; trig_busy<=1; trig_issued<=1;
            end else if (!trig_result_valid&&!trig_busy&&!trig_issued&&!trig_done_pulse&&
                         !trig_start&&id_ex_valid&&!cache_stall&&id_ex_is_trig&&!trig_executed) begin
                trig_operand<=alu_in1; trig_cached_operand<=alu_in1;
                trig_rd<=id_ex_rd; trig_funct3<=id_ex_funct3;
                trig_start<=1; trig_busy<=1; trig_issued<=1;
            end
            if (trig_done_pulse) begin trig_busy<=0;trig_issued<=0;trig_result_valid<=1; end
        end
    end

    // ?? HYP CORDIC FSM (unchanged) ????????????????????????????????????????
    assign hyp_reuse_done = id_ex_valid && !cache_stall && id_ex_is_hyp && hyp_result_valid &&
                            !hyp_busy && !hyp_done_pulse && (alu_in1==hyp_cached_operand);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hyp_busy<=0;hyp_start<=0;hyp_issued<=0;hyp_result_valid<=0;
            hyp_operand<=0;hyp_rd<=0;hyp_funct3<=0;hyp_cached_operand<=32'hFFFFFFFF;
            hyp_executed <= 0;
        end else begin
            hyp_start<=0;
            if (!later_stage_stall && !load_use_hazard) begin
                hyp_executed <= 0;
            end else if (hyp_start) begin
                hyp_executed <= 1;
            end

            if (id_ex_valid&&!cache_stall&&id_ex_is_hyp&&hyp_result_valid&&!hyp_busy&&
                !hyp_done_pulse&&!hyp_executed&&(alu_in1!=hyp_cached_operand)) begin
                hyp_result_valid<=0; hyp_operand<=alu_in1; hyp_cached_operand<=alu_in1;
                hyp_rd<=id_ex_rd; hyp_funct3<=id_ex_funct3;
                hyp_start<=1; hyp_busy<=1; hyp_issued<=1;
            end else if (!hyp_result_valid&&!hyp_busy&&!hyp_issued&&!hyp_done_pulse&&
                         !hyp_start&&id_ex_valid&&!cache_stall&&id_ex_is_hyp&&!hyp_executed) begin
                hyp_operand<=alu_in1; hyp_cached_operand<=alu_in1;
                hyp_rd<=id_ex_rd; hyp_funct3<=id_ex_funct3;
                hyp_start<=1; hyp_busy<=1; hyp_issued<=1;
            end
            if (hyp_done_pulse) begin hyp_busy<=0;hyp_issued<=0;hyp_result_valid<=1; end
        end
    end

    // ?? MEM/WB register - FIX-3: use ex_mem_csr_rdata ????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_data<=0; mem_wb_rd<=0; mem_wb_reg_write<=0;
            mem_wb_mem_write<=0; mem_wb_from_mul_div<=0; mem_wb_valid<=0;
        end
        else if (mul_done) begin
            mem_wb_data<=mul_wb_is_upper?mul_result[63:32]:mul_result[31:0];
            mem_wb_rd<=mul_rd; mem_wb_reg_write<=1; mem_wb_mem_write<=0;
            mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (div_done) begin
            mem_wb_data<=div_result; mem_wb_rd<=div_rd;
            mem_wb_reg_write<=1; mem_wb_mem_write<=0;
            mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (trig_done_pulse) begin
            mem_wb_data<=(trig_funct3==3'b000)?{{20{trig_sin_out[11]}},trig_sin_out}:
                         (trig_funct3==3'b001)?{{20{trig_cos_out[11]}},trig_cos_out}:
                                               {{20{trig_tan_out[11]}},trig_tan_out};
            mem_wb_rd<=trig_rd; mem_wb_reg_write<=(trig_rd!=0);
            mem_wb_mem_write<=0; mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (trig_reuse_done) begin
            mem_wb_data<=(id_ex_funct3==3'b000)?trig_sin_32:
                         (id_ex_funct3==3'b001)?trig_cos_32:trig_tan_32;
            mem_wb_rd<=id_ex_rd; mem_wb_reg_write<=(id_ex_rd!=0);
            mem_wb_mem_write<=0; mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (hyp_done_pulse) begin
            mem_wb_data<=(hyp_funct3==3'b000)?hyp_sinh_out:
                         (hyp_funct3==3'b001)?hyp_cosh_out:
                         (hyp_funct3==3'b010)?hyp_tanh_out:
                         (hyp_funct3==3'b011)?hyp_exp_pos:hyp_exp_neg;
            mem_wb_rd<=hyp_rd; mem_wb_reg_write<=(hyp_rd!=0);
            mem_wb_mem_write<=0; mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (hyp_reuse_done) begin
            mem_wb_data<=(id_ex_funct3==3'b000)?hyp_sinh_reg:
                         (id_ex_funct3==3'b001)?hyp_cosh_reg:
                         (id_ex_funct3==3'b010)?hyp_tanh_reg:
                         (id_ex_funct3==3'b011)?hyp_exp_pos_reg:hyp_exp_neg_reg;
            mem_wb_rd<=id_ex_rd; mem_wb_reg_write<=(id_ex_rd!=0);
            mem_wb_mem_write<=0; mem_wb_from_mul_div<=1; mem_wb_valid<=1;
        end
        else if (ex_mem_valid&&ex_mem_mem_to_reg&&cache_resp_valid) begin
            mem_wb_data<=cache_resp_rdata; mem_wb_rd<=ex_mem_rd;
            mem_wb_reg_write<=ex_mem_reg_write; mem_wb_mem_write<=0;
            mem_wb_from_mul_div<=0; mem_wb_valid<=1;
        end
        else if (cache_stall||mul_stall||div_stall||trig_stall||hyp_stall) begin
            // Freeze
        end
        else begin
            if (ex_mem_valid) begin
                // FIX-3: CSR uses ex_mem_csr_rdata (old value latched at EX?MEM)
                if      (ex_mem_is_csr)                    mem_wb_data<=ex_mem_csr_rdata;
                else if (ex_mem_jal||ex_mem_jalr)          mem_wb_data<=ex_mem_pc+4;
                else if (ex_mem_lui)                       mem_wb_data<=ex_mem_imm;
                else if (ex_mem_auipc)                     mem_wb_data<=ex_mem_pc+ex_mem_imm;
                else                                       mem_wb_data<=ex_mem_alu_result;
                mem_wb_rd<=ex_mem_rd; mem_wb_reg_write<=ex_mem_reg_write;
                mem_wb_mem_write<=ex_mem_mem_write;
                mem_wb_from_mul_div<=0; mem_wb_valid<=1;
            end else begin
                mem_wb_reg_write<=0; mem_wb_mem_write<=0;
                mem_wb_from_mul_div<=0; mem_wb_valid<=0;
            end
        end
    end

    // ?? Forwarding unit ???????????????????????????????????????????????????
    always @(*) begin
        forwardA=2'b00; forwardB=2'b00;
        if (ex_mem_reg_write&&ex_mem_rd!=0&&ex_mem_rd==id_ex_rs1) forwardA=2'b01;
        else if (mem_wb_reg_write&&mem_wb_rd!=0&&mem_wb_rd==id_ex_rs1) forwardA=2'b10;
        if (ex_mem_reg_write&&ex_mem_rd!=0&&ex_mem_rd==id_ex_rs2) forwardB=2'b01;
        else if (mem_wb_reg_write&&mem_wb_rd!=0&&mem_wb_rd==id_ex_rs2) forwardB=2'b10;
    end

    // ?? Stall / flush counters ????????????????????????????????????????????
    always @(posedge clk or posedge rst) begin
        if (rst) prev_pipeline_stall<=0; else prev_pipeline_stall<=pipeline_stall;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) stall_count<=0; else if (!halt&&pipeline_stall) stall_count<=stall_count+1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) branch_flush_count<=0; else if (mispredict) branch_flush_count<=branch_flush_count+1;
    end

    // ?? Branch predictor update ???????????????????????????????????????????
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) for (i=0;i<64;i=i+1) pht[i]<=2'b01;
        else if (id_ex_valid&&id_ex_is_branch) begin
            if (actual_taken) begin if (pht[pht_idx_ex]!=2'b11) pht[pht_idx_ex]<=pht[pht_idx_ex]+1; end
            else              begin if (pht[pht_idx_ex]!=2'b00) pht[pht_idx_ex]<=pht[pht_idx_ex]-1; end
        end
    end

    // ?? Hazard / stall assigns ????????????????????????????????????????????
    assign mul_will_start  = id_ex_valid&&!mul_done&&!mul_busy&&!mul_issued&&
                             (id_ex_is_mul||id_ex_is_mulh||id_ex_is_mulhu||id_ex_is_mulhsu);
    assign div_will_start  = id_ex_valid&&!div_done&&!div_busy&&!div_issued&&
                             (id_ex_is_div||id_ex_is_rem);
    assign trig_will_start = id_ex_valid&&!trig_done_pulse&&!trig_busy&&!trig_issued&&
                             !trig_result_valid&&id_ex_is_trig;
    assign hyp_will_start  = id_ex_valid&&!hyp_done_pulse&&!hyp_busy&&!hyp_issued&&
                             !hyp_result_valid&&id_ex_is_hyp;

    assign mul_stall  = mul_busy  && !mul_done;
    assign div_stall  = div_busy  && !div_done;
    assign trig_stall = trig_busy && !trig_done_pulse;
    assign hyp_stall  = hyp_busy  && !hyp_done_pulse;

    assign later_stage_stall = mul_stall || div_stall || mul_will_start || div_will_start
                             || trig_stall || hyp_stall || trig_will_start || hyp_will_start
                             || trig_wb_pending || hyp_wb_pending
                             || trig_done_pulse || hyp_done_pulse
                             || cache_stall;

    assign pipeline_stall = load_use_hazard || later_stage_stall;

    // ?? Instruction decode helpers ????????????????????????????????????????
    assign is_trig_op = (opcode == 7'b0001011);
    assign is_hyp_op  = (opcode == 7'b0001100);
    assign is_mul    = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b000);
    assign is_mulh   = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b001);
    assign is_mulhu  = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b011);
    assign is_mulhsu = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b010);
    assign is_div    = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b100);
    assign is_divu   = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b101);
    assign is_rem    = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b110);
    assign is_remu   = (opcode==7'b0110011)&&(funct7==7'b0000001)&&(funct3==3'b111);

endmodule