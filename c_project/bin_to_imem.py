# =============================================================================
#  bin_to_imem.py  -  Binary to Plain-Text .hex File Generator
#
#  Takes a raw binary file and compiles it into a 32-bit hexadecimal text file
#  suitable for Verilog's $readmemh task. Automatically deploys the hex file
#  to all local and Vivado simulation/synthesis folders.
# =============================================================================
import struct
import sys
import os
import shutil

def convert_bin_to_hex(bin_path, hex_name, word_limit=4096):
    try:
        with open(bin_path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        print(f"Error: Binary file '{bin_path}' not found.")
        return False

    # Pad binary data to be a multiple of 4 bytes (32-bit words)
    padding_needed = (4 - (len(data) % 4)) % 4
    data += b"\x00" * padding_needed

    num_words = len(data) // 4
    print(f"Loaded {num_words} words from binary file.")

    # Write .hex file in current directory
    hex_filename = f"{hex_name}.hex"
    with open(hex_filename, "w") as f:
        for i in range(min(num_words, word_limit)):
            word_bytes = data[i*4 : (i+1)*4]
            word_val = struct.unpack("<I", word_bytes)[0]
            f.write(f"{word_val:08X}\n")

    print(f"Generated hex file: {hex_filename}")

    if num_words > word_limit:
        print(f"WARNING: Program size ({num_words} words) exceeds limit ({word_limit} words).")

    # Paths to automatically deploy the generated hex file
    destinations = [
        # Relative paths
        r"../larm32",
        r"../../soc_testing/soc_testing.sim/sim_1/behav/xsim",
        r"../../soc_testing/soc_testing.srcs/sources_1/imports/larm32",
        # Absolute paths
        r"c:\Users\PULIPATI LOKESHVARMA\OneDrive\Desktop\Antigravity\larm32",
        r"P:\Vivado\Verilog\soc_testing\soc_testing.sim\sim_1\behav\xsim",
        r"P:\Vivado\Verilog\soc_testing\soc_testing.srcs\sources_1\imports\larm32"
    ]

    copied_count = 0
    for dest in destinations:
        if os.path.exists(dest):
            try:
                shutil.copy(hex_filename, os.path.join(dest, hex_filename))
                print(f"Deployed {hex_filename} to: {dest}")
                copied_count += 1
            except Exception as e:
                pass # Suppress permission/access warnings for non-active configurations
                
    return True

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python bin_to_imem.py <bin_path> <hex_name>")
        sys.exit(1)
        
    bin_path = sys.argv[1]
    hex_name = sys.argv[2]
    
    # Extract filename without extension if name includes it
    hex_name = os.path.splitext(hex_name)[0]
    
    convert_bin_to_hex(bin_path, hex_name)
