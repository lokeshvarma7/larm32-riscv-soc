//module dcache #(
//    parameter SETS = 32,
//    parameter IDLE = 0,
//    parameter MISS = 1,
//    parameter REFILL = 2
//)(
//    input  wire clk,
//    input  wire rst,

//    input  wire        req_valid,
//    output wire        req_ready,
//    input  wire        req_rw,
//    input  wire [31:0] req_addr,
//    input  wire [31:0] req_wdata,
//    input  wire [2:0]  req_funct3,

//    output reg         resp_valid,
//    input  wire        resp_ready,
//    output reg  [31:0] resp_rdata,

//    output reg         mem_req,
//    output reg         mem_rw,
//    output reg  [31:0] mem_addr,
//    output reg  [31:0] mem_wdata,
//    input  wire [31:0] mem_rdata,
//    input  wire        mem_ready
//);
    
////    reg [1:0] count;
//    reg [1:0] state;
//    reg [31:0] data_array [0:SETS-1][0:1];
//    reg [24:0] tag_array  [0:SETS-1][0:1];
//    reg        valid      [0:SETS-1][0:1];
//    reg        lru        [0:SETS-1];

//    reg [31:0] addr_reg;
//    reg        rw_reg;
//    reg [31:0] wdata_reg;

//    wire [4:0] index = req_addr[6:2];
//    wire [24:0] tag  = req_addr[31:7];

//    wire hit_way0 = valid[index][0] && (tag_array[index][0] == tag);
//    wire hit_way1 = valid[index][1] && (tag_array[index][1] == tag);
//    wire hit = hit_way0 || hit_way1;

//    reg [31:0] miss_addr;
//    wire [4:0] fill_index = miss_addr[6:2];
//    wire [24:0] fill_tag  = miss_addr[31:7];
//    reg [2:0] mem_delay;

//        assign req_ready = (state == IDLE);


//    integer i;

//    always @(posedge clk or posedge rst) begin
//        if (rst) begin
//            resp_valid <= 0;
//            mem_req    <= 0;
//            state      <= IDLE;
////            count <= 0;
            
//            for (i = 0; i < SETS; i = i + 1) begin
//                valid[i][0] <= 0;
//                valid[i][1] <= 0;
//                lru[i]      <= 0;
//            end
//        end
//        else begin

//            if (resp_valid && resp_ready)
//                resp_valid <= 0;
                
                
//            mem_req <= 1'b0;   // default: pulse only for one transaction
//            mem_rw  <= 1'b0;
            
            
//            if (state == REFILL)
//                mem_req <= 0;

//            if (req_valid && req_ready) begin
//                addr_reg  <= req_addr;
//                rw_reg    <= req_rw;
//                wdata_reg <= req_wdata;

//                // WRITE
//                if (req_rw) begin
//                    mem_req   <= 1;
//                    mem_rw    <= 1;
//                    mem_addr  <= req_addr;     // FIXED
//                    mem_wdata <= req_wdata;

//                    if (hit_way0) begin
//                        data_array[index][0] <= req_wdata;
//                        lru[index] <= 1;
//                    end
//                    else if (hit_way1) begin
//                        data_array[index][1] <= req_wdata;
//                        lru[index] <= 0;
//                    end

//                    resp_rdata <= 0;
////                    resp_valid <= 1;
//                end

//                // READ
//                else begin
//                    if (hit_way0) begin
//                        resp_rdata <= data_array[index][0];
//                        lru[index] <= 1;
//                        resp_valid <= 1;
//                    end
//                    else if (hit_way1) begin
//                        resp_rdata <= data_array[index][1];
//                        lru[index] <= 0;
//                        resp_valid <= 1;
//                    end
//                    else begin
//                        state      <= MISS;
//                        mem_req    <= 1;
//                        mem_rw     <= 0;
//                        mem_addr   <= req_addr;   // FIXED
//                        miss_addr  <= req_addr;
//                    end
//                end
//            end

//            else if (state == MISS && mem_ready) begin
////                count<=count+1;
////                if(count == 2)
//                state <= REFILL;
//            end

//            else if (state == REFILL) begin

//                if (!valid[fill_index][0]) begin
//                    data_array[fill_index][0] <= mem_rdata;
//                    tag_array[fill_index][0]  <= fill_tag;
//                    valid[fill_index][0]      <= 1;
//                    lru[fill_index]           <= 1;
//                end
//                else if (!valid[fill_index][1]) begin
//                    data_array[fill_index][1] <= mem_rdata;
//                    tag_array[fill_index][1]  <= fill_tag;
//                    valid[fill_index][1]      <= 1;
//                    lru[fill_index]           <= 0;
//                end
//                else begin
//                    data_array[fill_index][lru[fill_index]] <= mem_rdata;
//                    tag_array[fill_index][lru[fill_index]]  <= fill_tag;
//                    lru[fill_index] <= ~lru[fill_index];
//                end

//                resp_rdata <= mem_rdata;
//                resp_valid <= 1;

//                state      <= IDLE;
//            end

//        end
//    end

//endmodule










module dcache #(
    parameter SETS   = 32,
    parameter IDLE   = 2'd0,
    parameter MISS   = 2'd1,
    parameter REFILL = 2'd2
)(
    input  wire clk,
    input  wire rst,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_rw,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [2:0]  req_funct3,

    output wire        resp_valid,
    input  wire        resp_ready,
    output wire [31:0] resp_rdata,

    output reg         mem_req,
    output reg         mem_rw,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [2:0]  mem_funct3,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready
);

    reg [1:0] state;

    reg [31:0] data_array [0:SETS-1][0:1];
    reg [24:0] tag_array  [0:SETS-1][0:1];
    reg        valid      [0:SETS-1][0:1];
    reg        lru        [0:SETS-1];

    reg [31:0] miss_addr;
    reg        refill_way;
    reg [2:0]  miss_funct3;   // latch funct3 for REFILL extraction

    // One-cycle store buffer for store->load hazard resolution
    reg        pending_store_valid;
    reg [31:0] pending_store_addr;
    reg [31:0] pending_store_data;

    wire [4:0] index = req_addr[6:2];
    wire [24:0] tag  = req_addr[31:7];

    // -----------------------------------------------------------------------
    //  funct3-based byte/halfword extraction (mirrors dmem.v read path)
    //  Applies RISC-V LB/LH/LW/LBU/LHU semantics to a raw 32-bit word.
    // -----------------------------------------------------------------------
    function [31:0] apply_funct3;
        input [31:0] word;
        input [1:0]  byte_lane;
        input [2:0]  f3;
        reg   [7:0]  bv;
        reg   [15:0] hv;
        begin
            case (byte_lane)
                2'b00: bv = word[ 7: 0];
                2'b01: bv = word[15: 8];
                2'b10: bv = word[23:16];
                2'b11: bv = word[31:24];
            endcase
            hv = byte_lane[1] ? word[31:16] : word[15:0];
            case (f3)
                3'b000: apply_funct3 = {{24{bv[7]}},  bv};   // LB  sign-ext
                3'b001: apply_funct3 = {{16{hv[15]}}, hv};   // LH  sign-ext
                3'b010: apply_funct3 = word;                  // LW  full word
                3'b100: apply_funct3 = {24'b0, bv};           // LBU zero-ext
                3'b101: apply_funct3 = {16'b0, hv};           // LHU zero-ext
                default:apply_funct3 = word;
            endcase
        end
    endfunction

    wire is_mmio_addr = (req_addr[31:28] == 4'h1);
    wire miss_is_mmio = (miss_addr[31:28] == 4'h1);

    wire hit_way0 = !is_mmio_addr && valid[index][0] && (tag_array[index][0] == tag);
    wire hit_way1 = !is_mmio_addr && valid[index][1] && (tag_array[index][1] == tag);
    wire hit = hit_way0 || hit_way1;
    wire [4:0] miss_index = miss_addr[6:2];
    wire [24:0] miss_tag  = miss_addr[31:7];

    wire store_load_forward;
    assign store_load_forward = 1'b0;

    assign req_ready = (state == IDLE) && !resp_valid;

    assign resp_valid = (state == IDLE) && req_valid && !req_rw && (hit || store_load_forward)
                     || (state == REFILL) && (req_addr[31:2] == miss_addr[31:2]);

    assign resp_rdata = (state == REFILL) ? apply_funct3(mem_rdata, miss_addr[1:0], miss_funct3) :
                        store_load_forward ? apply_funct3(pending_store_data, req_addr[1:0], req_funct3) :
                        hit_way0 ? apply_funct3(data_array[index][0], req_addr[1:0], req_funct3) :
                        hit_way1 ? apply_funct3(data_array[index][1], req_addr[1:0], req_funct3) :
                        32'b0;

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;

            mem_req   <= 1'b0;
            mem_rw    <= 1'b0;
            mem_addr  <= 32'b0;
            mem_wdata <= 32'b0;
            mem_funct3 <= 3'b000;

            miss_addr  <= 32'b0;
            refill_way <= 1'b0;
            miss_funct3 <= 3'b010;

            pending_store_valid <= 1'b0;
            pending_store_addr  <= 32'b0;
            pending_store_data  <= 32'b0;

            for (i = 0; i < SETS; i = i + 1) begin
                valid[i][0] <= 1'b0;
                valid[i][1] <= 1'b0;
                lru[i]      <= 1'b0;
            end
        end else begin
            // Default: pulse memory request for one cycle only
            mem_req <= 1'b0;
            mem_rw  <= 1'b0;

            // Default: pending store lasts only until the next cycle
            if (pending_store_valid)
                pending_store_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (req_valid) begin
                        if (req_rw) begin
                            // WRITE-THROUGH, NO-WRITE-ALLOCATE
                            mem_req   <= 1'b1;
                            mem_rw    <= 1'b1;
                            mem_addr  <= req_addr;
                            mem_wdata <= req_wdata;
                            mem_funct3 <= req_funct3;

                            // Remember store for one cycle so a following load
                            // to the same address gets forwarded data.
                            pending_store_valid <= 1'b1;
                            pending_store_addr  <= req_addr;
                            pending_store_data  <= req_wdata;

                            // Update cache only on store hit with correct byte/halfword masking (using full-word assignments to prevent xsim X-state/latch issues)
                            if (hit_way0) begin
                                case (req_funct3[1:0])
                                    2'b00: begin // SB - store byte
                                        data_array[index][0] <= 
                                            (req_addr[1:0] == 2'b00) ? {data_array[index][0][31:8], req_wdata[7:0]} :
                                            (req_addr[1:0] == 2'b01) ? {data_array[index][0][31:16], req_wdata[7:0], data_array[index][0][7:0]} :
                                            (req_addr[1:0] == 2'b10) ? {data_array[index][0][31:24], req_wdata[7:0], data_array[index][0][15:0]} :
                                                                       {req_wdata[7:0], data_array[index][0][23:0]};
                                    end
                                    2'b01: begin // SH - store halfword
                                        data_array[index][0] <= 
                                            (req_addr[1] == 1'b0) ? {data_array[index][0][31:16], req_wdata[15:0]} :
                                                                    {req_wdata[15:0], data_array[index][0][15:0]};
                                    end
                                    default: begin // SW - store word
                                        data_array[index][0] <= req_wdata;
                                    end
                                endcase
                                lru[index] <= 1'b1;
                            end else if (hit_way1) begin
                                case (req_funct3[1:0])
                                    2'b00: begin // SB - store byte
                                        data_array[index][1] <= 
                                            (req_addr[1:0] == 2'b00) ? {data_array[index][1][31:8], req_wdata[7:0]} :
                                            (req_addr[1:0] == 2'b01) ? {data_array[index][1][31:16], req_wdata[7:0], data_array[index][1][7:0]} :
                                            (req_addr[1:0] == 2'b10) ? {data_array[index][1][31:24], req_wdata[7:0], data_array[index][1][15:0]} :
                                                                       {req_wdata[7:0], data_array[index][1][23:0]};
                                    end
                                    2'b01: begin // SH - store halfword
                                        data_array[index][1] <= 
                                            (req_addr[1] == 1'b0) ? {data_array[index][1][31:16], req_wdata[15:0]} :
                                                                    {req_wdata[15:0], data_array[index][1][15:0]};
                                    end
                                    default: begin // SW - store word
                                        data_array[index][1] <= req_wdata;
                                    end
                                endcase
                                lru[index] <= 1'b0;
                            end
                        end else begin
                            // LOAD

                            if (store_load_forward) begin
                                // Combinational path handles read
                            end
                            // Then normal cache hit
                            else if (hit_way0) begin
                                lru[index] <= 1'b1;
                            end else if (hit_way1) begin
                                lru[index] <= 1'b0;
                            end
                            // Cache miss
                            else begin
                                miss_addr   <= req_addr;
                                miss_funct3 <= req_funct3;
                                refill_way <= (!valid[index][0]) ? 1'b0 :
                                              (!valid[index][1]) ? 1'b1 :
                                              lru[index];

                                mem_req  <= 1'b1;
                                mem_rw   <= 1'b0;
                                mem_addr <= req_addr;
                                state    <= MISS;
                            end
                        end
                    end
                end

                MISS: begin
                    // Hold memory address and request stable for the missed load
                    mem_addr <= miss_addr;
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;

                    if (mem_ready)
                        state <= REFILL;
                end

                REFILL: begin
                    // Hold memory address and request stable during refill capture
                    mem_addr <= miss_addr;
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;

                    // Store the RAW full word only if it is NOT an MMIO address.
                    // This prevents caching read registers (like UART_STAT/GPIO_IN).
                    if (!miss_is_mmio) begin
                        data_array[miss_index][refill_way] <= mem_rdata;
                        tag_array[miss_index][refill_way]  <= miss_tag;
                        valid[miss_index][refill_way]      <= 1'b1;
                        lru[miss_index]                    <= ~refill_way;
                    end

                    state      <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule