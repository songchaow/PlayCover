#include <metal_stdlib>
using namespace metal;

constant float4 _ZL7ImmCB_Test[4] = {
    float4(1.0, 0.0, 2.0, 4.0),
    float4(-1.0, 3.0, 5.0, 6.0),
    float4(0.0, 7.0, 8.0, 9.0),
    float4(2.0, 4.0, 6.0, 8.0),
};

// 回归目标：`select fast i1 ... -> <3 x float>` 必须生成合法的向量条件表达式，
// 不能再退化成 `/* select parse error */` 并把 `.x/.y/.z` 链式访问写坏。
kernel void test_scalar_select_vector(
    device float4* output [[buffer(0)]],
    uint tid [[thread_position_in_grid]]
) {
    ulong index = ulong(tid & 3u);
    float4 base = _ZL7ImmCB_Test[index];
    bool cond = base.x > 0.0;
    float3 selected = cond ? float3(1.0, 2.0, 3.0) : base.xyz;
    output[ulong(tid)] = float4(selected, base.w);
}
