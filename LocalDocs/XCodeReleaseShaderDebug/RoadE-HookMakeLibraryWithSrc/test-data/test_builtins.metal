#include <metal_stdlib>
using namespace metal;

// ============================================================
// 1. 纹理采样/读写
// ============================================================
kernel void test_texture_ops(
    texture2d<float, access::read>       texR  [[texture(0)]],
    texture2d<float, access::write>      texW  [[texture(1)]],
    texture2d<float, access::sample>     texS  [[texture(2)]],
    texture2d<half, access::sample>      texH  [[texture(3)]],
    texture3d<float, access::sample>     tex3D [[texture(4)]],
    texturecube<float, access::sample>   texCube [[texture(5)]],
    texture2d_array<float, access::sample> texArr [[texture(6)]],
    depth2d<float, access::sample>       depthTex [[texture(7)]],
    sampler                              smp   [[sampler(0)]],
    uint2                                gid   [[thread_position_in_grid]]
) {
    float2 uv = float2(gid) / 512.0;
    // sample
    float4 c1 = texS.sample(smp, uv);
    // sample with LOD
    float4 c2 = texS.sample(smp, uv, level(2.0));
    // sample with bias
    float4 c3 = texS.sample(smp, uv, bias(1.0));
    // sample with gradient
    float4 c4 = texS.sample(smp, uv, gradient2d(float2(0.1), float2(0.1)));
    // sample half texture
    half4 ch = texH.sample(smp, uv);
    // sample 3D
    float4 c3d = tex3D.sample(smp, float3(uv, 0.5));
    // sample cube
    float4 ccube = texCube.sample(smp, float3(0.0, 1.0, 0.0));
    // sample array
    float4 carr = texArr.sample(smp, uv, 0);
    // depth sample_compare
    float depth = depthTex.sample_compare(smp, uv, 0.5);
    // read
    float4 cr = texR.read(gid);
    // write
    texW.write(c1 + c2 + c3 + c4 + float4(ch) + c3d + ccube + carr + float4(depth) + cr, gid);
    // get_width / get_height
    uint w = texR.get_width();
    uint h = texR.get_height();
    if (w > 0 && h > 0) {
        texW.write(float4(float(w), float(h), 0, 1), uint2(0, 0));
    }
}

// ============================================================
// 2. 同步屏障
// ============================================================
kernel void test_barriers(
    device float4*     buf    [[buffer(0)]],
    threadgroup float4* shared [[threadgroup(0)]],
    uint tid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]]
) {
    shared[lid] = buf[tid];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    buf[tid] = shared[lid];

    threadgroup_barrier(mem_flags::mem_device);
    threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);

    simdgroup_barrier(mem_flags::mem_none);
}

// ============================================================
// 3. 数学函数
// ============================================================
kernel void test_math(
    device float4*       out  [[buffer(0)]],
    const device float4* in_  [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    float4 v = in_[tid];
    float4 result = float4(0);

    result += sin(v);
    result += cos(v);
    result += tan(v);
    result += exp(v);
    result += exp2(v);
    result += log(v);
    result += log2(v);
    result += sqrt(v);
    result += rsqrt(v);
    result += abs(v);
    result += floor(v);
    result += ceil(v);
    result += round(v);
    result += trunc(v);
    result += fract(v);
    result += sign(v);
    result += saturate(v);

    float4 a = v, b = float4(2.0);
    result += fmin(a, b);
    result += fmax(a, b);
    result += pow(a, b);
    result += fmod(a, b);
    result += step(a, b);
    result += smoothstep(float4(0), float4(1), v);
    result += mix(a, b, float4(0.5));
    result += clamp(v, float4(0), float4(1));

    float d = dot(v.xyz, float3(1, 0, 0));
    float3 cr = cross(v.xyz, float3(0, 1, 0));
    float len = length(v.xyz);
    float3 n = normalize(v.xyz);
    float dist = distance(v.xyz, float3(0));
    result += float4(d, len, dist, 0) + float4(cr, 0) + float4(n, 0);

    out[tid] = result;
}

// ============================================================
// 4. 整数数学和位操作
// ============================================================
kernel void test_integer_math(
    device int4*       out  [[buffer(0)]],
    const device int4* in_  [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    int4 v = in_[tid];
    int4 result = int4(0);

    result += abs(v);
    result += min(v, int4(100));
    result += max(v, int4(-100));
    result += clamp(v, int4(-50), int4(50));

    result.x += popcount(v.x);
    result.y += clz(v.y);
    result.z += ctz(v.z);
    result.w += extract_bits(v.w, 4u, 8u);
    result.x += insert_bits(v.x, v.y, 4u, 8u);
    result.y += reverse_bits(v.y);

    out[tid] = result;
}

// ============================================================
// 5. 类型转换
// ============================================================
kernel void test_conversions(
    device float4*        outF  [[buffer(0)]],
    device int4*          outI  [[buffer(1)]],
    const device float4*  inF   [[buffer(2)]],
    const device int4*    inI   [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    float4 f = inF[tid];
    int4 i = inI[tid];

    outI[tid] = int4(f);
    outF[tid] = float4(i);

    half4 h = half4(f);
    outF[tid] += float4(h);

    outI[tid] += as_type<int4>(f);
}

// ============================================================
// 6. SIMD group 操作
// ============================================================
kernel void test_simd(
    device float4*       out  [[buffer(0)]],
    const device float4* in_  [[buffer(1)]],
    uint tid [[thread_position_in_grid]],
    uint simd_lane [[thread_index_in_simdgroup]],
    uint simd_gid  [[simdgroup_index_in_threadgroup]]
) {
    float4 v = in_[tid];

    float4 shuffled = simd_shuffle(v, 0u);
    float4 shuffled_xor = simd_shuffle_xor(v, 1u);
    float4 shuffled_up = simd_shuffle_up(v, 1u);
    float4 shuffled_down = simd_shuffle_down(v, 1u);

    float4 sum = simd_sum(v);
    float4 prod = simd_product(v);
    float4 mn = simd_min(v);
    float4 mx = simd_max(v);

    float4 bc = simd_broadcast_first(v);

    float4 prefix = simd_prefix_exclusive_sum(v);

    out[tid] = shuffled + shuffled_xor + shuffled_up + shuffled_down
             + sum + prod + mn + mx + bc + prefix;
}

// ============================================================
// 7. 原子操作
// ============================================================
kernel void test_atomics(
    device atomic_uint* counter [[buffer(0)]],
    device atomic_int*  acc     [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    atomic_fetch_sub_explicit(acc, int(tid), memory_order_relaxed);
    atomic_fetch_min_explicit(acc, int(tid), memory_order_relaxed);
    atomic_fetch_max_explicit(acc, int(tid), memory_order_relaxed);
    atomic_fetch_and_explicit(counter, 0xFFu, memory_order_relaxed);
    atomic_fetch_or_explicit(counter, 0x1u, memory_order_relaxed);
    atomic_fetch_xor_explicit(counter, 0x3u, memory_order_relaxed);
    uint old = atomic_exchange_explicit(counter, tid, memory_order_relaxed);
    uint expected = old;
    atomic_compare_exchange_weak_explicit(counter, &expected, tid + 1,
                                          memory_order_relaxed, memory_order_relaxed);
    uint val = atomic_load_explicit(counter, memory_order_relaxed);
    atomic_store_explicit(counter, val + 1, memory_order_relaxed);
}

// ============================================================
// 8. 片段着色器内建 (dfdx/dfdy/fwidth)
// ============================================================
fragment float4 test_fragment_builtins(
    float4 position [[position]]
) {
    float dx = dfdx(position.x);
    float dy = dfdy(position.y);
    float fw = fwidth(position.x);
    return float4(dx, dy, fw, 1.0);
}

// ============================================================
// 9. pack/unpack
// ============================================================
kernel void test_pack_unpack(
    device uint*         outU [[buffer(0)]],
    device float4*       outF [[buffer(1)]],
    const device float4* inF  [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    float4 v = inF[tid];
    uint packed = pack_float_to_snorm4x8(v);
    outU[tid] = packed;
    float4 unpacked = unpack_snorm4x8_to_float(packed);
    outF[tid] = unpacked;

    uint packed2 = pack_float_to_unorm4x8(v);
    outU[tid] += packed2;
    float4 unpacked2 = unpack_unorm4x8_to_float(packed2);
    outF[tid] += unpacked2;
}
