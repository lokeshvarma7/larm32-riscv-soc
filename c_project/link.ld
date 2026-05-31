/* =============================================================================
   link.ld  -  Memory layout mapping for LARM-32 RISC-V SoC
   ============================================================================= */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

MEMORY
{
    /* Instruction Memory: 16 KB = 16384 bytes */
    ROM_IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16384
    /* Data Memory: 16 KB = 16384 bytes, mapped above ROM boundary to avoid overlap */
    RAM_DMEM (rwx) : ORIGIN = 0x00004000, LENGTH = 16384
}

SECTIONS
{
    /* Text section (compiled machine instructions) goes strictly to IMEM ROM */
    .text : {
        . = ALIGN(4);
        *(.init)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > ROM_IMEM

    /* Data sections (variables, stack, constants) map to DMEM RAM */
    .data : {
        . = ALIGN(4);
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
    } > RAM_DMEM

    .bss : {
        . = ALIGN(4);
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
    } > RAM_DMEM

    /* Place the stack top at the very end of DMEM */
    _stack_top = ORIGIN(RAM_DMEM) + LENGTH(RAM_DMEM);

    /* Discard unused metadata sections to save memory space */
    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
    }
}
