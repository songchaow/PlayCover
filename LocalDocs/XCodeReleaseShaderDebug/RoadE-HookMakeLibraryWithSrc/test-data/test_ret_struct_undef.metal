// Test case: E-006a2e6 — ret with struct return type and undef/zeroinitializer
// Expected: return XlatMtlMain_Out(); instead of return 0;

#include <metal_stdlib>
using namespace metal;

struct XlatMtlMain_Out {
    float4 SV_Target0 [[color(0)]];
    float4 SV_Target1 [[color(1)]];
};

// This should compile: return with struct zero-initialization
fragment XlatMtlMain_Out xlatMtlMain(float4 position [[position]]) {
    return XlatMtlMain_Out();
}
