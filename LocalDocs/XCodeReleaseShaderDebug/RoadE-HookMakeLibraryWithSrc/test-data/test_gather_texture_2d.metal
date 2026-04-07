#include <metal_stdlib>
using namespace metal;

struct TestGatherTexture2d_StageIn {
    float2 TEXCOORD0;
};

fragment float4 test_gather_texture_2d(
    TestGatherTexture2d_StageIn stageIn [[stage_in]],
    sampler shadowSampler [[sampler(0)]],
    texture2d<float> shadowTexture [[texture(0)]]
) {
    return shadowTexture.gather(shadowSampler, stageIn.TEXCOORD0);
}
