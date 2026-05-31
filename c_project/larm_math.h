// =============================================================================
//  larm_math.h  -  Custom CORDIC Hardware Acceleration Library for LARM-32
//
//  This library wraps the custom CORDIC trig and hyperbolic instructions
//  supported by the LARM-32 hardware into clean inline C functions.
// =============================================================================

#ifndef LARM_MATH_H
#define LARM_MATH_H

/**
 * @brief Computes the sine of an angle in degrees.
 * @param angle_deg Integer angle from 0 to 359 degrees.
 * @return 12-bit signed fixed-point sine value (scaled by 2048).
 */
static inline int larm_sin(int angle_deg) {
    int result;
    // Uses standard GAS .insn directive to emit LARM custom opcode 0x0B
    asm volatile (".insn i 0x0b, 0, %0, %1, 0" : "=r"(result) : "r"(angle_deg));
    return result;
}

/**
 * @brief Computes the cosine of an angle in degrees.
 * @param angle_deg Integer angle from 0 to 359 degrees.
 * @return 12-bit signed fixed-point cosine value (scaled by 2048).
 */
static inline int larm_cos(int angle_deg) {
    int result;
    asm volatile (".insn i 0x0b, 1, %0, %1, 0" : "=r"(result) : "r"(angle_deg));
    return result;
}

/**
 * @brief Computes the tangent of an angle in degrees.
 * @param angle_deg Integer angle from 0 to 359 degrees.
 * @return 12-bit signed fixed-point tangent value (scaled by 2048, clamped).
 */
static inline int larm_tan(int angle_deg) {
    int result;
    asm volatile (".insn i 0x0b, 2, %0, %1, 0" : "=r"(result) : "r"(angle_deg));
    return result;
}

/**
 * @brief Computes the hyperbolic sine.
 * @param x_in Q16 fixed-point input value (scaled by 65536).
 * @return Q16 fixed-point result.
 */
static inline int larm_sinh(int x_in) {
    int result;
    asm volatile (".insn i 0x0c, 0, %0, %1, 0" : "=r"(result) : "r"(x_in));
    return result;
}

/**
 * @brief Computes the hyperbolic cosine.
 * @param x_in Q16 fixed-point input value (scaled by 65536).
 * @return Q16 fixed-point result.
 */
static inline int larm_cosh(int x_in) {
    int result;
    asm volatile (".insn i 0x0c, 1, %0, %1, 0" : "=r"(result) : "r"(x_in));
    return result;
}

/**
 * @brief Computes the hyperbolic tangent.
 * @param x_in Q16 fixed-point input value (scaled by 65536).
 * @return Q16 fixed-point result.
 */
static inline int larm_tanh(int x_in) {
    int result;
    asm volatile (".insn i 0x0c, 2, %0, %1, 0" : "=r"(result) : "r"(x_in));
    return result;
}

/**
 * @brief Computes exp(x).
 * @param x_in Q16 fixed-point input value (scaled by 65536).
 * @return Q16 fixed-point result.
 */
static inline int larm_exp_pos(int x_in) {
    int result;
    asm volatile (".insn i 0x0c, 3, %0, %1, 0" : "=r"(result) : "r"(x_in));
    return result;
}

/**
 * @brief Computes exp(-x).
 * @param x_in Q16 fixed-point input value (scaled by 65536).
 * @return Q16 fixed-point result.
 */
static inline int larm_exp_neg(int x_in) {
    int result;
    asm volatile (".insn i 0x0c, 4, %0, %1, 0" : "=r"(result) : "r"(x_in));
    return result;
}

#endif // LARM_MATH_H
