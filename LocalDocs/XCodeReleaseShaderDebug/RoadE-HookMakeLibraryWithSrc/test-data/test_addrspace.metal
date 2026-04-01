#include <metal_stdlib>
using namespace metal;

// 测试各种地址空间和参数类型

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
    float3 normal   [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
    float3 normal;
};

struct Uniforms {
    float4x4 modelViewProjection;
    float4x4 normalMatrix;
    float time;
};

// 1. vertex shader — device buffer + constant buffer + stage_in
vertex VertexOut test_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    device float4* positions [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    out.position = uniforms.modelViewProjection * in.position + positions[vid];
    out.texcoord = in.texcoord;
    out.normal = (uniforms.normalMatrix * float4(in.normal, 0.0)).xyz;
    return out;
}

// 2. fragment shader — device buffer (readonly) + constant buffer + textures
fragment float4 test_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    device float* weights [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float4 color = tex.sample(smp, in.texcoord);
    color.rgb *= weights[0];
    color.a *= uniforms.time;
    return color;
}

// 3. kernel shader — device read/write + constant + threadgroup
kernel void test_kernel(
    device float4* output [[buffer(0)]],
    device float4* input [[buffer(1)]],
    constant uint& count [[buffer(2)]],
    threadgroup float4* shared_data [[threadgroup(0)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint gid [[threadgroup_position_in_grid]]
) {
    if (tid < count) {
        shared_data[lid] = input[tid];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < count) {
        output[tid] = shared_data[lid] * 2.0;
    }
}

// 4. 更多类型：int/short/half/bool 参数
kernel void test_types(
    device int* intBuf [[buffer(0)]],
    device short* shortBuf [[buffer(1)]],
    device half4* halfBuf [[buffer(2)]],
    device uint8_t* byteBuf [[buffer(3)]],
    constant float2& scale [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    intBuf[tid] = int(halfBuf[tid].x * scale.x);
    shortBuf[tid] = short(byteBuf[tid]);
}

// 5. vertex shader 返回 float4（简单情况）
vertex float4 test_simple_vertex(
    device float4* positions [[buffer(0)]],
    constant float4x4& mvp [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    return mvp * positions[vid];
}
