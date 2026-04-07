#include <metal_stdlib>
using namespace metal;

// 测试 vertex draw-offset builtins：base_vertex / base_instance

vertex float4 test_base_vertex_builtin(
    uint mtl_VertexID [[vertex_id]],
    uint mtl_BaseVertex [[base_vertex]]
) {
    int t0 = mtl_VertexID - mtl_BaseVertex;
    return float4(float(t0), 0.0, 0.0, 1.0);
}

vertex float4 test_base_instance_builtin(
    uint mtl_InstanceID [[instance_id]],
    uint mtl_BaseInstance [[base_instance]]
) {
    int t0 = mtl_InstanceID + mtl_BaseInstance;
    return float4(0.0, float(t0), 0.0, 1.0);
}
