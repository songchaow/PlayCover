#include <metal_stdlib>
using namespace metal;

constexpr sampler __air_sampler_state(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);
constexpr sampler __air_sampler_state_1(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less);

struct Test_sampler_state_globals_StageIn {
    float2 TEXCOORD0;
};

fragment float4 test_sampler_state_globals(
    Test_sampler_state_globals_StageIn stageIn [[stage_in]],
    texture2d<float> historyTexture [[texture(0)]],
    depth2d<float> shadowTexture [[texture(1)]]
) {
    auto sampled = historyTexture.sample(__air_sampler_state, stageIn.TEXCOORD0);
    auto compared = shadowTexture.sample_compare(__air_sampler_state_1, stageIn.TEXCOORD0, sampled.x);
    float4 result = sampled;
    result.w = compared;
    return result;
}
