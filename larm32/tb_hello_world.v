// =============================================================================
//  tb_hello_world.v  -  Self-Decoding Simulation Testbench for LARM-32 C Code
//
//  Simulates the SoC and features a behavioral serial receiver that decodes
//  UART TX transmission into ASCII text and prints it to your simulator console!
// =============================================================================

`timescale 1ns/1ps

module tb_hello_world;

    reg         clk;
    reg         rst;
    reg  [31:0] gpio_in;
    
    wire [31:0] gpio_out;
    wire [31:0] gpio_dir;
    wire        uart_tx;
    wire        uart_rx;
    
    wire        pwm0_out;
    wire        pwm1_out;
    wire        irq_gpio;
    wire        irq_uart_tx;
    wire        irq_uart_rx;
    wire        irq_timer0;
    wire        irq_timer1;

    // Loopback TX to RX
    assign uart_rx = uart_tx;

    // Instantiate SoC
    soc_top #(
        .DMEM_DEPTH(4096) // Expanded 16 KB RAM depth matching hardware
    ) uut (
        .clk(clk),
        .rst(rst),
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_dir(gpio_dir),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .pwm0_out(pwm0_out),
        .pwm1_out(pwm1_out),
        .irq_gpio(irq_gpio),
        .irq_uart_tx(irq_uart_tx),
        .irq_uart_rx(irq_uart_rx),
        .irq_timer0(irq_timer0),
        .irq_timer1(irq_timer1)
    );

    // 50 MHz clock generation (Period = 20ns)
    initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end

    // Simulation parameters for 230,400 baud
    // Divisor = 108. 108 cycles * 20ns/cycle = 2160 ns per bit.
    parameter BIT_PERIOD = 108 * 20;

    // -------------------------------------------------------------------------
    // Behavioral UART Receiver: Reconstructs serial bits to ASCII
    // -------------------------------------------------------------------------
    reg [7:0] rx_char;
    integer i;

    initial begin
        $display("[SIM] Waiting for CPU boot and serial transmission...");
        @(negedge rst); // Wait until reset is released (200ns)
        
        // Wait until uart_tx is stably high for 10 consecutive clock cycles to clear all startup transients
        i = 0;
        while (i < 10) begin
            @(posedge clk);
            if (uart_tx === 1'b1) begin
                i = i + 1;
            end else begin
                i = 0; // Reset counter if any glitch/zero is detected
            end
        end
        
        forever begin
            @(negedge uart_tx); // Wait for UART start bit (falling edge)
            #(BIT_PERIOD / 2);  // Move to the middle of the start bit
            
            if (uart_tx == 1'b0) begin
                rx_char = 8'b0;
                // Sample 8 data bits at bit boundaries
                for (i = 0; i < 8; i = i + 1) begin
                    #BIT_PERIOD;
                    rx_char[i] = uart_tx;
                end
                // Wait for half of the stop bit to finish processing before the next start bit falls
                #(BIT_PERIOD / 2);
                // Print character to simulator console
                $write("%c", rx_char);
                $fflush();
            end
        end
    end

    // Test Procedure
    initial begin
        gpio_in = 32'h0000_0000;
        rst = 1;
        
        // Assert reset for 200ns
        #200;
        rst = 0;
        $display("[SIM] Reset released. CPU is now executing C bootloader...");

        // Run simulation for 4000 microseconds (plenty of time for all prints to complete)
        #4000000;
        
        $display("\n[SIM] Simulation finished.");
        $finish;
    end

//    always @(gpio_out) begin
//        $display("[DEBUG_GPIO_OUT] Time=%0d ns, gpio_out=8'h%h", $time, gpio_out[7:0]);
//    end

//    always @(uart_tx) begin
//        $display("[DEBUG_UART_TX] Time=%0d ns, uart_tx=%b", $time, uart_tx);
//    end

//    always @(uut.core_inst.pc) begin
//        if (!rst) begin
//            $display("[DEBUG_PC_CHANGE] Time=%0d ns, PC=32'h%h, Stall=%b", $time, uut.core_inst.pc, uut.core_inst.pipeline_stall);
//        end
//    end

//    always @(uut.core_inst.pipeline_stall) begin
//        if (!rst) begin
//            $display("[DEBUG_STALL_CHANGE] Time=%0d ns, Stall=%b, EX_PC=32'h%h, EX_Instr=32'h%h", $time, uut.core_inst.pipeline_stall, uut.core_inst.id_ex_pc, uut.core_inst.if_id_instr);
//        end
//    end

//    always @(posedge clk) begin
//        if (!rst && uut.core_inst.cordic_trig_inst.state == 2'd1) begin
//            $display("[DEBUG_CORDIC] iter=%d, x=%d, y=%d, z=%d", uut.core_inst.cordic_trig_inst.iter, uut.core_inst.cordic_trig_inst.x, uut.core_inst.cordic_trig_inst.y, uut.core_inst.cordic_trig_inst.z);
//        end
//        if (!rst && uut.core_inst.cordic_trig_inst.done) begin
//            $display("[DEBUG_CORDIC_DONE] Time=%0d ns, sin=%d, cos=%d, tan=%d", $time, uut.core_inst.cordic_trig_inst.sin_int, uut.core_inst.cordic_trig_inst.cos_int, uut.core_inst.cordic_trig_inst.tan_int);
//        end
//    end

//    always @(posedge clk) begin
//        if (!rst && uut.core_inst.divider.done) begin
//            $display("[DEBUG_DIVIDER] Time=%0d ns, dividend=%d, divisor=%d, is_rem=%b, result=%d",
//                     $time, uut.core_inst.divider.dividend, uut.core_inst.divider.divisor, uut.core_inst.divider.is_rem, uut.core_inst.divider.result);
//        end
//    end

//    always @(posedge clk) begin
//        if (!rst && uut.core_inst.cache_mem_req && !uut.core_inst.cache_mem_rw && uut.core_inst.cache_mem_addr == 32'h10000108 && uut.core_inst.cache_mem_ready) begin
//            $display("[DEBUG_UART_STAT_READ] Time=%0d ns, PC=32'h%h, rdata=7'b%b (tx_full=%b, tx_count=%d)",
//                     $time, uut.core_inst.pc, uut.core_inst.cache_mem_rdata[6:0], uut.core_inst.bus_inst.uart_inst.tx_full, uut.core_inst.bus_inst.uart_inst.tx_count);
//        end
//    end


endmodule
