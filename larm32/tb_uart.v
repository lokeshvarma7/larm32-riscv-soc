// =============================================================================
//  tb_uart.v - Complete Loopback Testbench for the LARM-32 UART Peripheral
//
//  This testbench simulates the CPU bus interface, registers, and serial transceivers
//  of the uart.v module. It wires the transmitter (uart_tx) directly back to the
//  receiver (uart_rx) to simulate a physical loopback cable, validating
//  full-duplex serial transmission and reception.
// =============================================================================

`timescale 1ns/1ps

module tb_uart;

    // -------------------------------------------------------------------------
    // 1. Simulation Signals
    // -------------------------------------------------------------------------
    reg         clk;
    reg         rst;

    // CPU Bus Interface
    reg         sel;
    reg         we;
    reg  [31:0] addr;
    reg  [31:0] wdata;
    wire [31:0] rdata;

    // Serial Pins
    wire        uart_tx;
    wire        uart_rx;

    // Interrupt Lines
    wire        irq_tx;
    wire        irq_rx;

    // -------------------------------------------------------------------------
    // 2. Hardware Loopback (Connect TX directly to RX)
    // -------------------------------------------------------------------------
    assign uart_rx = uart_tx;

    // -------------------------------------------------------------------------
    // 3. Instantiate the Unit Under Test (UUT)
    // -------------------------------------------------------------------------
    uart #(
        .BASE(32'h1000_0100),
        .CLK_FREQ(50_000_000), // 50 MHz simulation clock
        .FIFO_DEPTH(16)
    ) uut (
        .clk(clk),
        .rst(rst),
        .sel(sel),
        .we(we),
        .addr(addr),
        .wdata(wdata),
        .rdata(rdata),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .irq_tx(irq_tx),
        .irq_rx(irq_rx)
    );

    // -------------------------------------------------------------------------
    // 4. Clock Generation (50 MHz -> Period = 20ns)
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #10 clk = ~clk; // Toggle clock every 10ns
    end

    // -------------------------------------------------------------------------
    // 5. Helper Tasks for CPU Bus Operations
    // -------------------------------------------------------------------------
    task cpu_write(input [31:0] reg_addr, input [31:0] data);
        begin
            @(posedge clk);
            sel   = 1'b1;
            we    = 1'b1;
            addr  = reg_addr;
            wdata = data;
            @(posedge clk);
            sel   = 1'b0;
            we    = 1'b0;
            addr  = 32'h0;
            wdata = 32'h0;
        end
    endtask

    task cpu_read(input [31:0] reg_addr, output [31:0] read_val);
        begin
            @(posedge clk);
            sel   = 1'b1;
            we    = 1'b0;
            addr  = reg_addr;
            @(posedge clk);
            read_val = rdata;
            sel   = 1'b0;
            addr  = 32'h0;
        end
    endtask

    // -------------------------------------------------------------------------
    // 6. Test Procedure
    // -------------------------------------------------------------------------
    reg [31:0] temp_rdata;
    integer bit_period_ns;

    initial begin
        // Initialize signals
        sel   = 0;
        we    = 0;
        addr  = 0;
        wdata = 0;
        rst   = 1;

        // Calculate bit period for 115200 Baud at 50 MHz clock:
        // Divisor = 50,000,000 / 115200 = 434 cycles.
        // 434 cycles * 20ns/cycle = 8680 ns per bit.
        bit_period_ns = 434 * 20;

        $display("[TB_UART] Starting UART Loopback Simulation...");
        
        // Assert reset for 100ns
        #100;
        rst = 0;
        #50;

        // ---------------------------------------------------------------------
        // STEP 1: Verify Default Register Settings
        // ---------------------------------------------------------------------
        $display("[TB_UART] Checking default registers...");
        cpu_read(32'h1000_0108, temp_rdata); // Read UART_STAT
        $display("[TB_UART] Default UART_STAT: 7'b%b (Expected TX_EMPTY bit high)", temp_rdata[6:0]);
        
        cpu_read(32'h1000_010C, temp_rdata); // Read UART_CTRL
        $display("[TB_UART] Default UART_CTRL: 7'b%b (Expected 7'b0000011: TX_EN|RX_EN)", temp_rdata[6:0]);

        // ---------------------------------------------------------------------
        // STEP 2: Transmit Character 'A' (0x41)
        // ---------------------------------------------------------------------
        $display("[TB_UART] Transmitting character 'A' (0x41) from CPU bus...");
        cpu_write(32'h1000_0100, 32'h0000_0041); // Write 'A' to UART_TX register

        // Wait for Start Bit (uart_tx transitions to 0)
        @(negedge uart_tx);
        $display("[TB_UART] Start bit detected on serial line at %0t ns", $time);

        // Let the 8 data bits and stop bit stream through the loopback cable
        // 10 bits total (1 start + 8 data + 1 stop) * 8680 ns/bit = 86,800 ns
        #(bit_period_ns * 10);
        $display("[TB_UART] Serial frame transmission completed at %0t ns", $time);

        // ---------------------------------------------------------------------
        // STEP 3: Verify Status Register after transmission
        // ---------------------------------------------------------------------
        cpu_read(32'h1000_0108, temp_rdata); // Read UART_STAT
        $display("[TB_UART] UART_STAT after receive: 7'b%b (Expected RX_EMPTY bit to be 0 / data ready)", temp_rdata[6:0]);

        if (temp_rdata[3] == 1'b0) begin
            $display("[TB_UART] RX FIFO has data ready! Proceeding to read...");
        end else begin
            $display("[TB_UART] ERROR: RX FIFO reports empty after transmission!");
        end

        // ---------------------------------------------------------------------
        // STEP 4: Read Received Character from UART_RX register
        // ---------------------------------------------------------------------
        cpu_read(32'h1000_0104, temp_rdata); // Read UART_RX register
        $display("[TB_UART] Read received value: 8'h%h (ASCII character: '%c')", temp_rdata[7:0], temp_rdata[7:0]);

        if (temp_rdata[7:0] == 8'h41) begin
            $display("=========================================================");
            $display("  [TB_UART] SUCCESS: Loopback Test Passed! ('A' == 'A')  ");
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display("  [TB_UART] FAILURE: Received character mismatch: 8'h%h ", temp_rdata[7:0]);
            $display("=========================================================");
        end

        // Finish simulation
        #500;
        $display("[TB_UART] Simulation completed.");
        $finish;
    end

endmodule
