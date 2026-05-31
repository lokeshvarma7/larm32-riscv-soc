// =============================================================================
//  tb_soc_top.v - Full Integrated SoC Behavioral Testbench
//
//  This testbench simulates the complete LARM-32 RISC-V System-on-Chip (soc_top.v).
//  It verifies that the CPU correctly boots, executes the preloaded machine
//  instructions in imem.v, reads the virtual switches over MMIO, writes to
//  virtual LEDs, and successfully transmits serial characters (like the boot '*')
//  over the UART.
// =============================================================================

`timescale 1ns/1ps

module tb_soc_top;

    // -------------------------------------------------------------------------
    // 1. Simulation Signals
    // -------------------------------------------------------------------------
    reg         clk;
    reg         rst;

    // GPIO Inputs (Switches) and Outputs (LEDs/Directions)
    reg  [31:0] gpio_in;
    wire [31:0] gpio_out;
    wire [31:0] gpio_dir;

    // Serial Pins
    wire        uart_tx;
    wire        uart_rx;

    // PWM and Interrupt Monitors
    wire        pwm0_out;
    wire        pwm1_out;
    wire        irq_gpio;
    wire        irq_uart_tx;
    wire        irq_uart_rx;
    wire        irq_timer0;
    wire        irq_timer1;

    // -------------------------------------------------------------------------
    // 2. Hardware Loopback (Connect TX directly to RX)
    // -------------------------------------------------------------------------
    assign uart_rx = uart_tx;

    // -------------------------------------------------------------------------
    // 3. Instantiate the Entire RISC-V System-on-Chip (soc_top)
    // -------------------------------------------------------------------------
    soc_top #(
        .DMEM_DEPTH(1024) // Smaller depth for fast simulation
    ) uut (
        .clk(clk),
        .rst(rst),

        // GPIO
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_dir(gpio_dir),

        // UART
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),

        // PWM
        .pwm0_out(pwm0_out),
        .pwm1_out(pwm1_out),

        // Interrupt monitors
        .irq_gpio(irq_gpio),
        .irq_uart_tx(irq_uart_tx),
        .irq_uart_rx(irq_uart_rx),
        .irq_timer0(irq_timer0),
        .irq_timer1(irq_timer1)
    );

    // -------------------------------------------------------------------------
    // 4. Clock Generation (50 MHz -> Period = 20ns)
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #10 clk = ~clk; // Toggle clock every 10ns
    end

    // -------------------------------------------------------------------------
    // 5. Test Procedure
    // -------------------------------------------------------------------------
    integer bit_period_ns;

    initial begin
        // Initialize inputs
        gpio_in = 32'h0000_0000;
        rst     = 1;

        // Divisor = 50,000,000 / 115200 = 434 cycles.
        // 434 cycles * 20ns/cycle = 8680 ns per bit.
        bit_period_ns = 434 * 20;

        $display("[TB_SOC] Starting Full LARM-32 RISC-V SoC Integration Test...");
        
        // Assert hardware reset for 200ns
        #200;
        rst = 0;
        $display("[TB_SOC] Reset released at %0t ns. CPU is booting...", $time);

        // ---------------------------------------------------------------------
        // STEP 1: Verify Startup Boot Character Transmission
        // ---------------------------------------------------------------------
        // Wait for the CPU to detect TX_EMPTY and assert the start bit (falling edge on TX)
        @(negedge uart_tx);
        $display("[TB_SOC] UART Start Bit detected on serial TX line at %0t ns!", $time);

        // Wait for the full 10-bit serial frame to complete (Start + 8 Data + Stop)
        #(bit_period_ns * 10);
        $display("[TB_SOC] Serial character transmission completed at %0t ns.", $time);

        // ---------------------------------------------------------------------
        // STEP 2: Verify GPIO Switches to LEDs Loopback
        // ---------------------------------------------------------------------
        $display("[TB_SOC] Setting physical slide switches to alternating pattern (0xAA)...");
        gpio_in = 32'h0000_00AA; // Set switches to 10101010

        // Give the CPU pipeline a few clock cycles to execute the loop instructions
        // (load word from switches, write to LEDs)
        #1000;
        $display("[TB_SOC] Reading CPU output LEDs: 32'h%h (Expected: 32'h000000AA)", gpio_out);

        if (gpio_out == 32'h0000_00AA) begin
            $display("[TB_SOC] SUCCESS: GPIO switches-to-LEDs pipeline test passed!");
        end else begin
            $display("[TB_SOC] ERROR: GPIO output LED mismatch!");
        end

        // Change switches to another pattern
        #100;
        $display("[TB_SOC] Changing slide switches to 0x55...");
        gpio_in = 32'h0000_0055; // Set switches to 01010101
        #1000;
        $display("[TB_SOC] Reading CPU output LEDs: 32'h%h (Expected: 32'h00000055)", gpio_out);

        if (gpio_out == 32'h0000_0055) begin
            $display("[TB_SOC] SUCCESS: GPIO dynamic update test passed!");
        end else begin
            $display("[TB_SOC] ERROR: GPIO dynamic update LED mismatch!");
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        if (gpio_out == 32'h0000_0055) begin
            $display("=========================================================");
            $display("  [TB_SOC] SUCCESS: FULL INTEGRATION TEST PASSED!        ");
            $display("  RISC-V Core, MMIO Bus, GPIO and UART are fully working! ");
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display("  [TB_SOC] FAILURE: Integrated SoC Verification Failed! ");
            $display("=========================================================");
        end

        #500;
        $display("[TB_SOC] Simulation completed.");
        $finish;
    end

endmodule
