#include <metal_stdlib>
using namespace metal;

// 测试 fragment 返回值在 AIR 中被 lowered 为 packed struct `<{ <4 x float> }>` 的场景。
// 这个模式会触发 `IRToMSLConverter.irTypeToMSL(...)` 的返回类型路径；
// 若误把 `<{ ... }>` 当成 `<N x T>` 向量，就会生成类似 `fragment float4{ <4 ...` 的坏签名。
struct FragmentOut {
    float4 color [[color(0)]];
};

fragment FragmentOut test_fragment_packed(float4 position [[position]]) {
    FragmentOut out;
    out.color = position;
    return out;
}
