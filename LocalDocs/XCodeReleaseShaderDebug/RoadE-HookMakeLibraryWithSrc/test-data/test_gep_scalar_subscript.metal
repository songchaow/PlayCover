// Expected MSL for test_gep_scalar_subscript.ll (E-006a2e14)
// GEP into scalar struct fields should use pointer subscript, not direct scalar subscript

#include <metal_stdlib>
using namespace metal;

struct FGlobals {
    float alpha0;
    float alpha1;
    float4 color;
    float2 offset;
};

vertex float4 test_gep_scalar_subscript(constant FGlobals& fg [[buffer(0)]], uint vid [[vertex_id]]) {
    uint64_t t3 = uint64_t(vid);
    // GEP: struct → field 0 (float alpha0) → index with t3
    // scalar subscript: auto temp = &fg.alpha0; float val = temp[t3];
    auto t4 = &(fg.alpha0);
    float t5 = t4[t3];
    // GEP: struct → field 1 (float alpha1) → index with t3
    auto t6 = &(fg.alpha1);
    float t7 = t6[t3];
    // GEP: struct → field 2 (float4 color) → index with t3 (vector subscript, valid directly)
    // Note: float4[t3] is valid in MSL for vector element access
    // But with the fix, scalar detection checks currentType which is float after [4 x float] array access
    // Actually, float4 in IR is <4 x float> which starts with '<', so it goes to vector branch
    return float4(t5, t7, 0.0, 1.0);
}

vertex float4 test_gep_scalar_const(constant FGlobals& fg [[buffer(0)]]) {
    // GEP: struct → field 0 (float alpha0) → constant index 1
    auto t2 = &(fg.alpha0);
    float t3 = t2[1];
    return float4(t3, 0.0, 0.0, 1.0);
}

vertex float4 test_gep_vector_subscript(constant FGlobals& fg [[buffer(0)]], uint vid [[vertex_id]]) {
    uint64_t t3 = uint64_t(vid);
    // GEP: struct → field 3 (<2 x float> / float2) → index with t3
    // <2 x float> starts with '<', so vector branch handles it
    float t5 = fg.offset[t3];
    return float4(t5, 0.0, 0.0, 1.0);
}
