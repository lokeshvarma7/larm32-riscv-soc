// =============================================================================
//  main.c  -  LARM-32 Full Benchmark (Fibonacci, Factorial, Division, CORDIC)
// =============================================================================

#include "larm_math.h"

#define GPIO_DIR     (*(volatile unsigned int *)0x10000000)
#define GPIO_OUT     (*(volatile unsigned int *)0x10000004)
#define GPIO_IN      (*(volatile unsigned int *)0x10000008)

#define UART_TX      (*(volatile unsigned int *)0x10000100)
#define UART_STAT    (*(volatile unsigned int *)0x10000108)
#define UART_CTRL    (*(volatile unsigned int *)0x1000010C)
#define UART_BAUD    (*(volatile unsigned int *)0x10000110)

void delay(volatile int count) {
    while (count > 0) {
        count--;
    }
}

void uart_putchar(char c) {
    while (UART_STAT & 4); // Wait while TX FIFO is FULL (bit 2 = value 4)
    UART_TX = c;
}

void print(const char *str) {
    while (*str) {
        uart_putchar(*str++);
    }
}

// Custom decimal printer to test hardware division/remainder (div / rem)
void print_dec(int val) {
    char buf[12];
    int i = 0;
    if (val < 0) {
        uart_putchar('-');
        val = -val;
    }
    if (val == 0) {
        uart_putchar('0');
        return;
    }
    while (val > 0) {
        buf[i++] = (val % 10) + '0'; // Compiles to 'rem' instruction
        val /= 10;                  // Compiles to 'div' instruction
    }
    for (int j = i - 1; j >= 0; j--) {
        uart_putchar(buf[j]);
    }
}

// Recursive Fibonacci Benchmark
int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

// Recursive Factorial Benchmark
int fact(int n) {
    if (n <= 1) return 1;
    return n * fact(n - 1);
}

int main() {
    // 1. Initialize Baud divisor to 108 (230,400 baud)
    UART_BAUD = 108;
    UART_CTRL = 3; // Enable TX and RX
    
    // 2. Set GPIO direction (lower 8 bits as outputs for the 8 LEDs)
    GPIO_DIR = 0xFF;
    
    // Print banner
    print("--- LARM-32 Full Benchmark ---\r\n");

    // 3. Test Multiplier (12 * 10 = 120)
    volatile int factor1 = 12;
    volatile int factor2 = 10;
    volatile int product = factor1 * factor2;
    print("Multiplier: ");
    print_dec(product);
    print("\r\n");

    // 4. Test Fibonacci Benchmark (fib(10) = 55)
    volatile int fib_result = fib(10);
    print("Fibonacci(10): ");
    print_dec(fib_result);
    print("\r\n");

    // 5. Test Factorial Benchmark (fact(6) = 720)
    volatile int fact_result = fact(6);
    print("Factorial(6): ");
    print_dec(fact_result);
    print("\r\n");

    // 6. Test CORDIC Trigonometric Accelerator (sin(90) = 2047)
    volatile int sin_90 = larm_sin(90);
    print("CORDIC Sin(90): ");
    print_dec(sin_90);
    print("\r\n");

    // 7. Verification: check all results
    if (product == 120 && fib_result == 55 && fact_result == 720 && sin_90 >= 2040) {
        GPIO_OUT = 0x0F; // Light up LD0, LD1, LD2, LD3 to confirm full success!
        print("[BENCHMARK] SUCCESS\r\n");
    } else {
        GPIO_OUT = 0x80; // Light up LD7 to indicate a fault
        print("[BENCHMARK] FAILED\r\n");
    }

    while (1) {
        // Echo switches to LEDs with toggle activity
        unsigned int switches = GPIO_IN;
        GPIO_OUT = (switches & 0xF0) | (GPIO_OUT & 0x0F); // Echo upper switches, preserve math LEDs
        delay(20000);
    }
    return 0;
}
