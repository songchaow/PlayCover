#include <metal_stdlib>
using namespace metal;

constant float4 _ZL7ImmCB_Test[4] = {
    float4(1.0, 0.0, 2.0, 4.0),
    float4(0.0, 3.0, 0.0, 5.0),
    float4(6.0, 0.0, 7.0, 8.0),
    float4(0.0, 9.0, 10.0, 11.0),
};

kernel void test_vector_select_global_gep(
    device float4* output [[buffer(0)]],
    uint tid [[thread_position_in_grid]]
) {
    ulong index = ulong(tid & 3u);
    float4 base = _ZL7ImmCB_Test[index];
    bool3 mask = base.xyz > float3(0.0);
    float3 selected = float3(
        mask.x ? 1.0 : 0.0,
        mask.y ? 2.0 : 0.0,
        mask.z ? 3.0 : 0.0
    );
    output[ulong(tid)] = float4(selected, base.w);
}
