#include <metal_stdlib>
using namespace metal;

// 聚焦 E-006a2d2 的 fast-math 二元运算泄漏：
// - 标量 `fdiv fast float`
// - 向量 `fadd fast <2 x float>`
// - 向量 `fmul fast <4 x float>`
// 目标是让 IRToMSLConverter 在这些模式上不再吐出 `/* parse error: fadd/fmul/fdiv fast ... */`。
kernel void test_fast_math_binary(
    device float2* vectorOut [[buffer(0)]],
    device float4* vector4Out [[buffer(1)]],
    device float* scalarOut [[buffer(2)]],
    constant float2* vectorIn [[buffer(3)]],
    constant float4* vector4In [[buffer(4)]],
    constant float* scalarIn [[buffer(5)]],
    uint tid [[thread_position_in_grid]])
{
    float2 biased = vectorIn[tid] + float2(-0.5, -0.5);
    float4 scaled = vector4In[tid] * float4(2.0, 2.0, 2.0, 2.0);
    float denom = max(scalarIn[tid], 0.25f);
    float ratio = 5.0f / denom;

    vectorOut[tid] = biased;
    vector4Out[tid] = scaled;
    scalarOut[tid] = ratio;
}
