# =============================================================================
#  crt0.s  -  Minimal boot loader for LARM-32 bare-metal RISC-V execution
# =============================================================================

.section .init
.global _start

_start:
    .cfi_startproc
    # Load the initial stack pointer from linker-defined address
    la  sp, _stack_top
    
    # Call C program main
    jal ra, main
    
_halt:
    # If main returns, loop infinitely
    j _halt
    .cfi_endproc
