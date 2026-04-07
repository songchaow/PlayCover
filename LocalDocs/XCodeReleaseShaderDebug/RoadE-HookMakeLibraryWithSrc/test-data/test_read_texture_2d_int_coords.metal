#include <metal_stdlib>
using namespace metal;

struct TestReadTexture2dIntCoords_StageIn {
    float2 TEXCOORD0;
};

fragment half4 test_read_texture_2d_int_coords(
    TestReadTexture2dIntCoords_StageIn stageIn [[stage_in]],
    texture2d<half> inputTexture [[texture(0)]]
) {
    int2 signedCoord = int2(stageIn.TEXCOORD0);
    return inputTexture.read(uint2(signedCoord));
}
