// SPDX-License-Identifier: MIT
/*
 * Safe Math Library for Tolk
 * 
 * This library provides overflow-safe arithmetic operations for Tolk's 257-bit signed integers.
 * 
 * Error codes:
 * 0 - No error (success)
 * 1 - Positive overflow
 * 2 - Negative overflow (underflow)  
 * 3 - Division/modulo by zero
 * 
 * Usage patterns:
 * 1. Use safe* functions when you want to handle errors gracefully
 * 2. Use must* functions when you want to throw on overflow (fail-fast)
 * 3. All functions are designed to be gas-efficient and secure
 */

// int is a 257-bit signed integer
// These are its max/min values
// For a 257-bit signed integer: max = 2^256 - 1, min = -2^256
// We calculate max as: 2^255 - 1 + 2^255 = 2^256 - 1 (avoiding overflow)
const INT_MAX: int = ((1 << 255) - 1) + (1 << 255);
const INT_MIN: int = -(1 << 255) - (1 << 255);

// 2^(15×8) - 1 = 2^120 - 1
const COIN_MAX: int = (1 << 120) - 1;

// Returns (result, errorCode), where errorCode is 0 if no error.
fun safeAdd(a: int, b: int): (int, int) {
    // Check for positive overflow: a > INT_MAX - b
    if (b > 0 && a > INT_MAX - b) {
        return (0, 1); // overflow error
    }
    
    // Check for negative overflow: a < INT_MIN - b
    if (b < 0 && a < INT_MIN - b) {
        return (0, 2); // underflow error
    }
    
    return (a + b, 0); // success
}

// Returns (result, errorCode), where errorCode is 0 if no error.
fun safeProd(a: int, b: int): (int, int) {
    // Handle zero cases
    if (a == 0 || b == 0) {
        return (0, 0);
    }
    
    // Handle -1 special case to avoid division by zero
    if (a == -1) {
        if (b == INT_MIN) {
            return (0, 1); // overflow: -1 * INT_MIN = overflow
        }
        return (-b, 0);
    }
    
    if (b == -1) {
        if (a == INT_MIN) {
            return (0, 1); // overflow: INT_MIN * -1 = overflow
        }
        return (-a, 0);
    }
    
    // Check for overflow by division
    // If a > 0 and b > 0: check a <= INT_MAX / b
    // If a < 0 and b < 0: check a >= INT_MAX / b (both negative)
    // If a > 0 and b < 0: check a <= INT_MIN / b (will be negative check)
    // If a < 0 and b > 0: check a >= INT_MIN / b (will be negative check)
    
    if (a > 0 && b > 0) {
        if (a > INT_MAX / b) {
            return (0, 1); // overflow
        }
    } else if (a < 0 && b < 0) {
        if (a < INT_MAX / b) {
            return (0, 1); // overflow (both negative, result positive)
        }
    } else if (a > 0 && b < 0) {
        if (b < INT_MIN / a) {
            return (0, 2); // underflow
        }
    } else { // a < 0 && b > 0
        if (a < INT_MIN / b) {
            return (0, 2); // underflow
        }
    }
    
    return (a * b, 0); // success
}

// Returns result or throws errCode on overflow.
fun mustAdd(a: int, b: int, errCode: int): int {
    var (res, err) = safeAdd(a, b);
    if (err != 0) {
        throw errCode;
    }
    return res;
}

// Returns result or throws errCode on overflow.
fun mustProd(a: int, b: int, errCode: int): int {
    var (res, err) = safeProd(a, b);
    if (err != 0) {
        throw errCode;
    }
    return res;
}

fun mustCastToCoin(value: int, errCode: int): coins {
    if (value < 0 || value > COIN_MAX) {
        throw errCode;
    }
    return value;
}
