; ModuleID = 'test_struct_array_field'
; 测试 air.struct_type_info elementCount>1 时正确生成数组字段（E-006c3 修复）
; _AlphasArray: elementCount=4, typeName="float" → float _AlphasArray[4]
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios11.0.0"

%struct.FGlobals_Type = type { <4 x float>, [4 x float] }

define <4 x float> @xlatMtlMain(ptr addrspace(2) %0, <2 x float> %stageIn_uv) {
  %2 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 0
  %3 = load <4 x float>, ptr addrspace(2) %2, align 16
  %4 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 0
  %5 = load float, ptr addrspace(2) %4, align 4
  %6 = insertelement <4 x float> %3, float %5, i32 0
  ret <4 x float> %6
}

!air.vertex = !{!0}
!0 = !{ptr @xlatMtlMain, !1, !2, !4}
!1 = !{!"air.result", !"air.arg_type_name", !"float4", !"air.arg_name", !""}
!2 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !3, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"FGlobals_Type", !"air.arg_name", !"FGlobals"}
!3 = !{i32 0, i32 16, i32 0, !"float4", !"_BaseColor", i32 16, i32 4, i32 4, !"float", !"_AlphasArray"}
!4 = !{i32 1, !"air.vertex_input", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv", !"air.location_index", i32 0, i32 1}
