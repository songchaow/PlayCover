//
// Auto-generated MSL source by PlayTools IRToMSLConverter
// E-004e: LLVM IR → MSL stub conversion
// Generated at: 2026-04-07T12:32:18Z
// Functions: 1
//

#include <metal_stdlib>
using namespace metal;

// [0] kernel: test_fast_math_select
kernel void test_fast_math_select(device half* output [[buffer(0)]], device half* input [[buffer(1)]], uint tid [[thread_position_in_grid]]) {
    ulong t0 = ulong(tid);
    half t1 = input[t0];
    bool t2 = t1 < 0.0;
    half t3 = t2 ? 0.495117 : 0.504883;
    output[t0] = t3;
    return;
}
