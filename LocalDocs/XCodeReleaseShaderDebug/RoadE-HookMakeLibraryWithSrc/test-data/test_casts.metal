#include <metal_stdlib>
using namespace metal;

// E-004e4d test: cover float-int cast opcodes that are not represented by air.convert.
// Goal: force llvm-dis output to contain uitofp, sitofp, fptoui, and fptosi.

kernel void test_scalar_casts(
    device float* floatOut [[buffer(0)]],
    device int* intOut [[buffer(1)]],
    device uint* uintIn [[buffer(2)]],
    device int* intIn [[buffer(3)]],
    device float* floatIn [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    uint u = uintIn[tid] & 1023u;
    int s = intIn[tid] % 257;
    float f = floatIn[tid] * 8.0f;

    // uitofp: uint -> float
    float fromUnsigned = float(u);

    // sitofp: int -> float
    float fromSigned = float(s);

    // fptoui: float -> uint
    uint toUnsigned = uint(f + 16.0f);

    // fptosi: float -> int
    int toSigned = int(f - 7.0f);

    floatOut[tid] = fromUnsigned + fromSigned + float(toUnsigned) + float(toSigned);
    intOut[tid] = int(toUnsigned) + toSigned;
}

kernel void test_vector_casts(
    device float4* floatOut [[buffer(0)]],
    device uint4* uintOut [[buffer(1)]],
    device uint4* uintIn [[buffer(2)]],
    device int4* intIn [[buffer(3)]],
    device float4* floatIn [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    uint4 u = uintIn[tid] & uint4(255u, 511u, 1023u, 2047u);
    int4 s = intIn[tid] % int4(17, 31, 63, 127);
    float4 f = floatIn[tid] * 4.0f + float4(8.0f);

    // uitofp: uint4 -> float4
    float4 fromUnsigned = float4(u);

    // sitofp: int4 -> float4
    float4 fromSigned = float4(s);

    // fptoui: float4 -> uint4
    uint4 toUnsigned = uint4(f);

    // fptosi: float4 -> int4
    int4 toSigned = int4(f - float4(3.0f));

    floatOut[tid] = fromUnsigned + fromSigned + float4(toUnsigned) + float4(toSigned);
    uintOut[tid] = toUnsigned + uint4(max(toSigned, int4(0)));
}
