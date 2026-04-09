#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4 color; };

kernel void test_kernel_restrict_ptr(device float4* outColor [[buffer(0)]], constant Uniforms* __restrict u [[buffer(1)]], uint tid [[thread_position_in_grid]]) {
    outColor[tid] = u[0].color;
}
