#include <metal_stdlib>
using namespace metal;

// E-004e4a 补充测试：覆盖整数运算、位运算、类型转换等指令
// 目标：让编译器生成 udiv/sdiv/urem/srem/shl/lshr/ashr/and/or/xor/sext/trunc/fptrunc/fdiv/frem

// 1. 整数算术运算 (udiv, sdiv, urem, srem)
kernel void test_int_arith(
    device int* output [[buffer(0)]],
    device int* inputA [[buffer(1)]],
    device uint* inputB [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    int a = inputA[tid];
    uint b = inputB[tid];

    // sdiv, srem (有符号除法和取模)
    int div_result = a / 3;
    int rem_result = a % 5;

    // udiv, urem (无符号除法和取模)
    uint udiv_result = b / 7u;
    uint urem_result = b % 11u;

    output[tid] = div_result + rem_result + int(udiv_result) + int(urem_result);
}

// 2. 位运算 (shl, lshr, ashr, and, or, xor)
kernel void test_bitops(
    device uint* output [[buffer(0)]],
    device uint* inputA [[buffer(1)]],
    device int* inputB [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint a = inputA[tid];
    int b = inputB[tid];

    // shl (左移)
    uint shifted_left = a << 2u;

    // lshr (逻辑右移，无符号)
    uint logical_right = a >> 3u;

    // ashr (算术右移，有符号)
    int arith_right = b >> 1;

    // and, or, xor
    uint and_result = a & 0xFF00FF00u;
    uint or_result = a | 0x000000FFu;
    uint xor_result = a ^ 0xAAAAAAAAu;

    output[tid] = shifted_left + logical_right + uint(arith_right) + and_result + or_result + xor_result;
}

// 3. 类型转换 (sext, trunc, fptrunc, fdiv, frem)
kernel void test_conversions(
    device float* floatOut [[buffer(0)]],
    device int* intOut [[buffer(1)]],
    device short* shortIn [[buffer(2)]],
    device float* floatIn [[buffer(3)]],
    device half* halfOut [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    // sext: short → int (符号扩展)
    short s = shortIn[tid];
    int extended = int(s);
    intOut[tid] = extended;

    // trunc: int → short (截断)
    int big = extended * 1000;
    short truncated = short(big & 0x7FFF);

    // fptrunc: float → half
    float f = floatIn[tid];
    half h = half(f);
    halfOut[tid] = h;

    // fdiv (浮点除法)
    float div = f / 3.14;

    // frem (浮点取模) — MSL 中用 fmod
    float rem = fmod(f, 2.5);

    floatOut[tid] = div + rem + float(truncated);
}
