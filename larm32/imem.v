// =============================================================================
//  imem.v  -  Instruction Memory preloaded with a Pure Assembly Bootloader
//
//  A hand-assembled, zero-dependency "Hello World" bootloader.
//  Bypasses GCC compilers, C stacks, RAM, and linker scripts entirely.
// =============================================================================

`timescale 1ns/1ps

module imem (
    input  wire [31:0] addr,
    output wire [31:0] instr
);

    // 4096-word instruction memory (16 KB ROM)
    reg [31:0] mem [0:4095];
    integer ii;

    initial begin
        // Default initialize all memory slots with NOP
        for (ii = 0; ii <= 4095; ii = ii + 1) begin
            mem[ii] = 32'h00000013;
        end
        // Load compiled program hex directly
        $readmemh("LARMRV32.hex", mem);
    end

    // Word indexing (12-bit index for 4096 words in range 0x0000 to 0x3FFF)
    assign instr = mem[addr[13:2]];

endmodule