// Test for E-006a2e4: intrinsic type ambiguity + vector icmp/zext lowering

#include <metal_stdlib>
using namespace metal;

fragment float4 xlatMtlMain(float4 coord [[position]]) {
    // Test 1: clamp with half operands — literal params must be half-typed
    half h = half(coord.x);
    half clamped = clamp(h, half(0.0), half(1.0));

    // Test 2: vector icmp producing boolN
    half a = half(coord.y);
    half2 v1 = half2(h, a);
    half2 v2 = half2(a, h);
    bool2 cmp = (v1 == v2);

    // Test 3: zext <N x i1> to <N x i8> → ucharN
    uchar2 extended = uchar2(cmp);

    // Keep clamp / cmp / zext all behavior-observable in the rendered output.
    return float4(float(clamped), float(a), float(cmp.x) + float(extended.x), 0.0);
}
