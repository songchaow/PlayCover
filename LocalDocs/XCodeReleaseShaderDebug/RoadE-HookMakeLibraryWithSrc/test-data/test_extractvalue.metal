#include <metal_stdlib>
using namespace metal;

// 测试 extractvalue/insertvalue + GEP 结构体路径还原
// E-004e4c: 覆盖以下 IR 模式:
// 1. air.sample_texture_2d 返回 { <4 x float>, i8 }，需 extractvalue 拆解
// 2. 结构体作为 vertex 输出，需 insertvalue 构建
// 3. GEP 访问结构体字段（buffer 中的结构体）

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

struct Uniforms {
    float4x4 modelViewProjection;
    float time;
};

// 测试 1: fragment shader 采样纹理 → extractvalue 从 {float4, i8} 中提取颜色
fragment float4 test_sample_extract(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float4 color = tex.sample(smp, in.texcoord);
    return color;
}

// 测试 2: vertex shader 输出结构体 → insertvalue 构建返回值
vertex VertexOut test_vertex_struct(
    const device float4* positions [[buffer(0)]],
    const device float2* texcoords [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    out.position = uniforms.modelViewProjection * positions[vid];
    out.texcoord = texcoords[vid];
    return out;
}

// 测试 3: kernel 访问结构体数组中的字段 → GEP 结构体路径
struct Particle {
    float3 position;
    float3 velocity;
    float mass;
};

kernel void test_gep_struct(
    device Particle* particles [[buffer(0)]],
    constant float& dt [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    // GEP 访问 particles[tid].position 和 .velocity
    float3 pos = particles[tid].position;
    float3 vel = particles[tid].velocity;
    float m = particles[tid].mass;
    
    // 简单积分
    pos += vel * dt;
    vel *= (1.0 - 0.01 * dt); // 阻尼
    
    particles[tid].position = pos;
    particles[tid].velocity = vel;
}
