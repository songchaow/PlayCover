#include <metal_stdlib>
using namespace metal;

// 测试 phi 节点和多基本块控制流
// 编译器会在分支合并点生成 phi 指令

// 1. 简单 if-else → phi
// 条件分支选择不同的值，合并后使用
kernel void test_phi_simple(
    device float4* output [[buffer(0)]],
    device float4* input [[buffer(1)]],
    constant float& threshold [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    float4 val = input[tid];
    float4 result;
    if (val.x > threshold) {
        result = val * 2.0;
    } else {
        result = val * 0.5;
    }
    output[tid] = result;
}

// 2. 多层 if-else 嵌套 → 多 phi
kernel void test_phi_nested(
    device float* output [[buffer(0)]],
    device float* input [[buffer(1)]],
    constant float2& bounds [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    float val = input[tid];
    float result;
    if (val > bounds.x) {
        if (val > bounds.y) {
            result = 1.0;
        } else {
            result = 0.5;
        }
    } else {
        result = 0.0;
    }
    output[tid] = result;
}

// 3. 循环 → phi (loop back-edge)
kernel void test_phi_loop(
    device float* output [[buffer(0)]],
    device float* input [[buffer(1)]],
    constant uint& iterations [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    float sum = 0.0;
    for (uint i = 0; i < iterations; i++) {
        sum += input[tid + i];
    }
    output[tid] = sum;
}
