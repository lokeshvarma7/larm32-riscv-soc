// =============================================================================
//  risc_core_soc.v  -  risc_core rev12 with mmio_bus replacing cache_mem_bridge
//
//  Changes vs risc_core.v:
//    1. Module renamed risc_core_soc (keeps risc_core available for standalone tb)
//    2. Added peripheral I/O ports
//    3. `cache_mem_bridge bridge_inst` replaced with `mmio_bus bus_inst`
//    4. Everything else is 100% identical to risc_core.v rev 12
// =============================================================================

`timescale 1ns/1ps

// ======================================================================
//  CACHE-DMEM BRIDGE  (kept for reference - NOT instantiated here)
// ======================================================================
// (same module as in risc_core.v - included so this file is self-contained
//  when cache_mem_bridge is needed elsewhere.  The SOC uses mmio_bus.)

// ======================================================================
//  RVC EXPANDER  (identical to risc_core.v)
// ======================================================================
// Defined in risc_core.v - do not redefine here; include risc_core.v first.

// ======================================================================
//  TOP-LEVEL SOC CORE
// ======================================================================
(* DONT_TOUCH = "yes" *) (* KEEP_HIERARCHY = "yes" *)
module risc_core_soc #(
    parameter data_width  = 32,
    parameter instr_width = 32,
    parameter reg_count   = 32,
    parameter addr_w      = 32,
    parameter dmem_depth  = 4096
)(
    input  wire clk,
    input  wire rst,

    // ---- Peripheral I/O (new vs risc_core) ----
    input  wire [31:0] gpio_in,
    output wire [31:0] gpio_out,
    output wire [31:0] gpio_dir,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire        pwm0_out,
    output wire        pwm1_out,
    output wire        irq_gpio,
    output wire        irq_uart_tx,
    output wire        irq_uart_rx,
    output wire        irq_timer0,
    output wire        irq_timer1
);

    // =========================================================================
    //  All internal signals are IDENTICAL to risc_core.v - copy verbatim
    // =========================================================================

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

    (* KEEP="yes" *) reg        ex_mem_is_csr;
    (* KEEP="yes" *) reg [31:0] ex_mem_csr_rdata;

    wire        trap_taken, trap_enter, mret_en;
    wire [31:0] trap_cause, trap_tval, trap_ret_pc, mtvec_out;
    wire        mie_global;
    wire        csr_en;
    wire [11:0] csr_addr_pipe;
    wire [2:0]  csr_funct3_pipe;
    wire [31:0] csr_wdata_pipe, csr_rdata_wire, csr_rdata_id_wire;

    (* KEEP="yes" *) reg [31:0] if_id_pc, if_id_instr;
    (* KEEP="yes" *) reg        if_id_is_branch, if_id_predict_taken;

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

    (* KEEP="yes" *) reg [1:0] pht [0:63];
    wire [5:0] pht_idx_if = pc[7:2];
    wire [5:0] pht_idx_ex = id_ex_pc[7:2];
    wire predict_taken_if = pht[pht_idx_if][1];

    (* KEEP="yes" *) reg [31:0] ex_mem_alu_result, ex_mem_rdata2;
    (* KEEP="yes" *) reg [4:0]  ex_mem_rd;
    (* KEEP="yes" *) reg [2:0]  ex_mem_funct3;
    (* KEEP="yes" *) reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    (* KEEP="yes" *) reg        ex_mem_mem_to_reg, ex_mem_jal, ex_mem_jalr;
    (* KEEP="yes" *) reg        ex_mem_lui, ex_mem_auipc;
    (* KEEP="yes" *) reg [31:0] ex_mem_pc, ex_mem_imm;
    (* KEEP="yes" *) reg        ex_mem_branch, ex_mem_valid;
    (* KEEP="yes" *) reg [31:0] ex_mem_fwd_data;

    wire actual_taken = pc_src;
    wire mispredict   = id_ex_valid && id_ex_is_branch &&
                        (actual_taken != id_ex_predict_taken);
    wire [31:0] branch_target_ex = id_ex_pc + id_ex_imm;
    wire [31:0] correct_pc       = actual_taken ? branch_target_ex : (id_ex_pc + 4);

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

    wire [31:0] alu_in1 =
        (mul_done        && mul_rd  != 0 && mul_rd  == id_ex_rs1) ? mul_fwd_data   :
        (div_done        && div_rd  != 0 && div_rd  == id_ex_rs1) ? div_result     :
        (trig_done_pulse && trig_rd != 0 && trig_rd == id_ex_rs1) ? trig_fwd_data  :
        (hyp_done_pulse  && hyp_rd  != 0 && hyp_rd  == id_ex_rs1) ? hyp_fwd_data   :
        (forwardA == 2'b01) ? ex_mem_fwd_data :
        (forwardA == 2'b10) ? mem_wb_data      :
        id_ex_rdata1;

    wire [31:0] alu_in2_raw =
        (mul_done        && mul_rd  != 0 && mul_rd  == id_ex_rs2) ? mul_fwd_data   :
        (div_done        && div_rd  != 0 && div_rd  == id_ex_rs2) ? div_result     :
        (trig_done_pulse && trig_rd != 0 && trig_rd == id_ex_rs2) ? trig_fwd_data  :
        (hyp_done_pulse  && hyp_rd  != 0 && hyp_rd  == id_ex_rs2) ? hyp_fwd_data   :
        (forwardB == 2'b01) ? ex_mem_fwd_data :
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

    assign csr_en          = id_ex_valid && id_ex_is_csr;
    assign csr_addr_pipe   = id_ex_csr_addr;
    assign csr_funct3_pipe = id_ex_csr_funct3;
    assign csr_wdata_pipe  = id_ex_csr_funct3[2] ? id_ex_csr_wdata : alu_in1;

    // =========================================================================
    //  SUBMODULE INSTANCES (same as risc_core.v except bridge -> mmio_bus)
    // =========================================================================

    pc inst_pc (.clk(clk),.rst(rst),
        .pc_en(!halt && !pipeline_stall),.pc_next(pc_next),.pc(pc));

    imem inst_imem (.addr(pc),.instr(instr_raw));

    rvc_expander rvc_exp_inst (
        .instr_in(instr_raw), .pc1(pc[1]),
        .instr_out(instr_fetch), .is_rvc(is_rvc_fetch));

    wire [6:0] funct7, opcode;
    assign opcode = if_id_instr[6:0];
    wire [4:0] shift_count;

    decoder decoder_inst (
        .instr(if_id_instr), .opcode(opcode), .rd(rd), .rs1(rs1), .rs2(rs2),
        .funct3(funct3), .funct7(funct7), .shamt(shift_count),
        .is_ecall(is_ecall_dec), .is_ebreak(is_ebreak_dec),
        .is_mret(is_mret_dec),   .is_wfi(is_wfi_dec),
        .is_fence(is_fence_dec), .is_csr(is_csr_dec),
        .csr_addr(csr_addr_dec), .csr_zimm(csr_zimm_dec));

    imm_gen imm_gen_inst  (.instr(if_id_instr), .imm_gen(imm_gen));
    imm_gen imm_gen_if_inst (.instr(instr_fetch), .imm_gen(imm_gen_if));

    wire [31:0] reg_rdata1, reg_rdata2;
    wire        reg_write;

    regfile #(.reg_count(reg_count)) regfile_inst (
        .clk(clk),.rst(rst),.rd(mem_wb_rd),.rs1(rs1),.rs2(rs2),
        .we(mem_wb_reg_write),.wd(mem_wb_data),.rd1(reg_rdata1),.rd2(reg_rdata2));

    wire [31:0] alu_result;
    wire        alu_sub, alu_src_imm, mem_to_reg, is_rtype;

    assign alu_b_final = id_ex_alu_src ? id_ex_imm : alu_in2_raw;

    alu alu_inst (
        .a(alu_in1), .b(alu_b_final),
        .reg_rdata1(alu_in1), .reg_rdata2(alu_b_final),
        .sub(id_ex_alu_sub), .result(alu_result),
        .zero(alu_zero), .alu_neg(alu_neg), .borrow(alu_borrow),
        .funct3(id_ex_funct3), .funct7(id_ex_funct7), .shamt(id_ex_shamt),
        .sub_result(sub_result), .alu_add(id_ex_alu_add), .is_rtype(id_ex_is_rtype));

    wire mem_read, mem_write;
    assign jalr_target = {alu_result[31:1], 1'b0};

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

    wire instret_pulse = ex_mem_valid && !pipeline_stall &&
                         !mul_stall && !div_stall && !trig_stall && !hyp_stall;

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
        .cycle_inc(!halt), .instret_inc(instret_pulse));

    // ---- DCACHE (unchanged) ----
    wire cache_req_valid, cache_req_ready, cache_req_rw;
    wire [31:0] cache_req_addr, cache_req_wdata;
    wire [2:0]  cache_req_funct3;
    wire cache_resp_valid, cache_resp_ready;
    wire [31:0] cache_resp_rdata;
    wire cache_mem_req, cache_mem_rw;
    wire [31:0] cache_mem_addr, cache_mem_wdata, cache_mem_rdata;
    wire [2:0]  cache_mem_funct3;
    wire cache_mem_ready;

    assign cache_req_valid  = ex_mem_valid && (ex_mem_mem_read||ex_mem_mem_write);
    assign cache_req_rw     = ex_mem_mem_write;
    assign cache_req_addr   = ex_mem_alu_result;
    assign cache_req_wdata  = ex_mem_rdata2;
    assign cache_req_funct3 = ex_mem_funct3;
    assign cache_resp_ready = 1'b1;
    assign cache_stall      = ex_mem_valid && ex_mem_mem_read && !cache_resp_valid;

    dcache #(.SETS(32)) dcache_inst (
        .clk(clk),.rst(rst),
        .req_valid(cache_req_valid),.req_ready(cache_req_ready),
        .req_rw(cache_req_rw),.req_addr(cache_req_addr),
        .req_wdata(cache_req_wdata),.req_funct3(cache_req_funct3),
        .resp_valid(cache_resp_valid),.resp_ready(cache_resp_ready),
        .resp_rdata(cache_resp_rdata),
        .mem_req(cache_mem_req),.mem_rw(cache_mem_rw),
        .mem_addr(cache_mem_addr),.mem_wdata(cache_mem_wdata),
        .mem_funct3(cache_mem_funct3),
        .mem_rdata(cache_mem_rdata),.mem_ready(cache_mem_ready));

    // ---- MMIO BUS (replaces cache_mem_bridge) ----
    mmio_bus #(.DMEM_DEPTH(dmem_depth)) bus_inst (
        .clk(clk), .rst(rst),
        .mem_req(cache_mem_req), .mem_rw(cache_mem_rw),
        .mem_addr(cache_mem_addr), .mem_wdata(cache_mem_wdata),
        .mem_rdata(cache_mem_rdata), .mem_ready(cache_mem_ready),
        .mem_funct3(cache_mem_funct3),
        // Peripheral I/O
        .gpio_in(gpio_in),   .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .uart_tx(uart_tx),   .uart_rx(uart_rx),
        .pwm0_out(pwm0_out), .pwm1_out(pwm1_out),
        .irq_gpio(irq_gpio), .irq_uart_tx(irq_uart_tx),
        .irq_uart_rx(irq_uart_rx),
        .irq_timer0(irq_timer0), .irq_timer1(irq_timer1)
    );

    // ---- Multiplier / Divider / CORDIC (unchanged) ----
    radix_4 multiplier (.clk(clk),.rst(rst),
        .a(mul_op_a),.b(mul_op_b),.start(mul_start),.done(mul_done),
        .unsigned_mul(mul_unsigned),.mulhsu_mode(mul_wb_is_mulhsu),.result(mul_result));

    non_restoring_div divider (.clk(clk),.rst(rst),
        .start(div_start),.is_signed(div_is_signed),.is_rem(div_is_rem),
        .dividend(div_op_a),.divisor(div_op_b),.result(div_result),.busy(),.done(div_done));

    cordic_sct_trig cordic_trig_inst (.clk(clk),.rst(rst),.start(trig_start),
        .angle_deg(trig_operand[15:0]),
        .sin_int(trig_sin_out),.cos_int(trig_cos_out),.tan_int(trig_tan_out),.done(trig_done_raw));

    cordic_cam_hyp cordic_hyp_inst (.clk(clk),.rst(rst),.start(hyp_start),
        .x_in(hyp_operand),
        .sinh_out(hyp_sinh_out),.cosh_out(hyp_cosh_out),.tanh_out(hyp_tanh_out),
        .exp_pos(hyp_exp_pos),.exp_neg(hyp_exp_neg),.done(hyp_done_raw));

    // =========================================================================
    //  All always blocks are IDENTICAL to risc_core.v
    // =========================================================================

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
        else if (later_stage_stall) begin end
        else if (load_use_hazard) begin
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
            id_ex_csr_rdata <= csr_rdata_id_wire;
            id_ex_is_ecall  <= cu_is_ecall;
            id_ex_is_ebreak <= cu_is_ebreak;
            id_ex_is_mret   <= cu_is_mret;
            id_ex_is_wfi    <= cu_is_wfi;
            id_ex_is_fence  <= cu_is_fence;
            id_ex_is_illegal<= cu_is_illegal;
        end
    end

    wire [31:0] ex_stage_fwd_data =
        (id_ex_is_csr)              ? id_ex_csr_rdata    :
        (id_ex_jal || id_ex_jalr)   ? (id_ex_pc + 4)     :
        id_ex_lui                   ? id_ex_imm           :
        id_ex_auipc                 ? (id_ex_pc + id_ex_imm) :
                                      alu_result;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_alu_result<=0; ex_mem_rdata2<=0; ex_mem_rd<=0;
            ex_mem_reg_write<=0; ex_mem_mem_read<=0; ex_mem_mem_write<=0;
            ex_mem_mem_to_reg<=0; ex_mem_jal<=0; ex_mem_jalr<=0;
            ex_mem_lui<=0; ex_mem_auipc<=0; ex_mem_pc<=0; ex_mem_imm<=0;
            ex_mem_branch<=0; ex_mem_valid<=0; ex_mem_funct3<=0;
            ex_mem_is_csr<=0; ex_mem_csr_rdata<=0;
            ex_mem_fwd_data<=0;
        end
        else if (cache_stall||mul_stall||div_stall||trig_stall||hyp_stall) begin end
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
            ex_mem_csr_rdata   <= id_ex_csr_rdata;
            ex_mem_fwd_data    <= ex_stage_fwd_data;
            ex_mem_valid       <= id_ex_valid && !trap_taken;
        end
    end

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
        else if (cache_stall||mul_stall||div_stall||trig_stall||hyp_stall) begin end
        else begin
            if (ex_mem_valid) begin
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

    always @(*) begin
        forwardA=2'b00; forwardB=2'b00;
        if (ex_mem_reg_write&&ex_mem_rd!=0&&ex_mem_rd==id_ex_rs1) forwardA=2'b01;
        else if (mem_wb_reg_write&&mem_wb_rd!=0&&mem_wb_rd==id_ex_rs1) forwardA=2'b10;
        if (ex_mem_reg_write&&ex_mem_rd!=0&&ex_mem_rd==id_ex_rs2) forwardB=2'b01;
        else if (mem_wb_reg_write&&mem_wb_rd!=0&&mem_wb_rd==id_ex_rs2) forwardB=2'b10;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) prev_pipeline_stall<=0; else prev_pipeline_stall<=pipeline_stall;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) stall_count<=0; else if (!halt&&pipeline_stall) stall_count<=stall_count+1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) branch_flush_count<=0; else if (mispredict) branch_flush_count<=branch_flush_count+1;
    end

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) for (i=0;i<64;i=i+1) pht[i]<=2'b01;
        else if (id_ex_valid&&id_ex_is_branch) begin
            if (actual_taken) begin if (pht[pht_idx_ex]!=2'b11) pht[pht_idx_ex]<=pht[pht_idx_ex]+1; end
            else              begin if (pht[pht_idx_ex]!=2'b00) pht[pht_idx_ex]<=pht[pht_idx_ex]-1; end
        end
    end

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