#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4 color; };

fragment float4 test_frag_restrict_ptr(float4 pos [[position]], constant Uniforms* __restrict u [[buffer(0)]]) {
    return u[0].color;
}
