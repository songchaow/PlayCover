// Test for E-006a2e4: intrinsic type ambiguity + vector icmp/zext lowering

#include <metal_stdlib>
using namespace metal;

fragment float4 xlatMtlMain(float4 coord [[position]]) {
    // Test 1: clamp with half operands — literal params must be half-typed
    half h = half(coord.x);
    half clamped = clamp(h, half(0.0), half(1.0));

    // Test 2: fma with half operands
    half a = half(coord.y);
    half b = half(coord.z);
    half c = half(coord.w);
    half result = fma(a, b, c);

    // Test 3: vector icmp producing boolN
    half2 v1 = half2(half(coord.x), half(coord.y));
    half2 v2 = half2(half(coord.z), half(coord.w));
    bool2 cmp = (v1 == v2);

    // Test 4: zext <N x i1> to <N x i8> → ucharN
    uchar2 extended = uchar2(cmp);

    // Use results to prevent dead code elimination
    return float4(float(clamped), float(result), float(cmp.x) + float(extended.x), 0.0);
}
