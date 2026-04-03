#include <metal_stdlib>
using namespace metal;

// E-006a2e2 测试：覆盖 undef lowering 与 half 十六进制立即数
// 目标：让编译器生成包含 undef、half hex literal (0xH...) 的 IR

// 1. undef 在不同上下文中
// 未初始化的 vector 会产生 undef（被 freeze / select 消除前）
kernel void test_undef_contexts(
    device float4* output [[buffer(0)]],
    device float* input [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    float x = input[tid];
    // 条件分支中的 undef — 编译器可能产生 select 与 undef 混合
    float4 v;
    if (x > 0.5) {
        v = float4(x, 1.0, 0.0, 1.0);
    }
    // v 的部分分量可能是 undef
    output[tid] = v;
}

// 2. half 类型运算（触发 0xH hex literal 在 IR 中）
kernel void test_half_arithmetic(
    device half* halfOut [[buffer(0)]],
    device float* floatIn [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    half a = half(floatIn[tid]);
    half b = half(floatIn[tid + 1]);

    // half 算术运算 — 编译器 IR 中常量可能用 0xH 格式
    half sum = a + b;
    half diff = a - b;
    half prod = a * b;

    halfOut[tid] = sum + diff + prod;
}

// 3. half 向量操作
fragment float4 test_half_vector(
    device half4* input [[buffer(0)]],
    float4 pos [[position]]
) {
    uint tid = uint(pos.x);
    half4 h = input[tid];
    // half 向量与标量混合运算
    half s = h.x + h.y;
    return float4(h) * float4(s);
}
