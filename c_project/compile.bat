@echo off
rem ===========================================================================
rem  compile.bat  -  RISC-V C-Project Compiler Automation Script
rem ===========================================================================

set PATH=C:\RV32IM\xpack-riscv-none-elf-gcc-15.2.0-1\bin;%PATH%

set PROGRAM_NAME=%~1
if "%PROGRAM_NAME%"=="" (
    set PROGRAM_NAME=main
)

echo [1/3] Compiling C project (main.c and crt0.s) with size optimizations...
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -Os -ffunction-sections -fdata-sections "-Wl,--gc-sections" -nostartfiles -T link.ld crt0.s main.c -o program.elf
if %errorlevel% neq 0 (
    echo [ERROR] Compilation failed.
    exit /b 1
)

echo [2/3] Extracting raw binary bytes with riscv-none-elf-objcopy...
riscv-none-elf-objcopy -O binary program.elf program.bin
if %errorlevel% neq 0 (
    echo [ERROR] Binary extraction failed.
    exit /b 1
)

echo [3/3] Compiling into plain-text hex file...
echo ===========================================================================
python bin_to_imem.py program.bin "%PROGRAM_NAME%"
echo ===========================================================================
echo Compilation complete. Hex file '%PROGRAM_NAME%.hex' has been successfully compiled and deployed!
