#include <metal_stdlib>
using namespace metal;

// 测试 fragment `stage_in` 与 `[[front_facing]]` builtin 并存。
// 回归目标：即使存在 `air.fragment_input`，converter 仍必须显式声明
// `bool mtl_FrontFace [[front_facing]]`，不能只在函数体里引用未声明的名字。
struct Test_fragment_front_facing_StageIn {
    float3 TEXCOORD0;
};

fragment float4 test_fragment_front_facing(
    Test_fragment_front_facing_StageIn stageIn [[stage_in]],
    bool mtl_FrontFace [[front_facing]]
) {
    float sign = mtl_FrontFace ? 1.0 : -1.0;
    return float4(sign, 0.0, stageIn.TEXCOORD0.z, 1.0);
}
