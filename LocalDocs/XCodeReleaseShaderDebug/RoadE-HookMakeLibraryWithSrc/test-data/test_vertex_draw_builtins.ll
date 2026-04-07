; ModuleID = 'test_vertex_draw_builtins.air'
source_filename = "test_vertex_draw_builtins.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

define <4 x float> @test_base_vertex_builtin(i32 %0, i32 %1) local_unnamed_addr #0 {
  %3 = sub i32 %0, %1
  %4 = tail call fast float @air.convert.f.f32.u.i32(i32 %3) #1
  %5 = insertelement <4 x float> <float 0.000000e+00, float 0.000000e+00, float 0.000000e+00, float 1.000000e+00>, float %4, i64 0
  ret <4 x float> %5
}

define <4 x float> @test_base_instance_builtin(i32 %0, i32 %1) local_unnamed_addr #0 {
  %3 = add i32 %0, %1
  %4 = tail call fast float @air.convert.f.f32.u.i32(i32 %3) #1
  %5 = insertelement <4 x float> <float 0.000000e+00, float 0.000000e+00, float 0.000000e+00, float 1.000000e+00>, float %4, i64 1
  ret <4 x float> %5
}

declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #1

attributes #0 = { nounwind optsize memory(none) "frame-pointer"="all" "min-legal-vector-width"="64" "no-builtins" "stack-protector-buffer-size"="8" }
attributes #1 = { nounwind memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!llvm.ident = !{!8}
!air.version = !{!9}
!air.language_version = !{!10}
!air.vertex = !{!11, !17}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 1]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"air.max_device_buffers", i32 31}
!3 = !{i32 7, !"air.max_constant_buffers", i32 31}
!4 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!5 = !{i32 7, !"air.max_textures", i32 128}
!6 = !{i32 7, !"air.max_read_write_textures", i32 8}
!7 = !{i32 7, !"air.max_samplers", i32 16}
!8 = !{!"Apple metal version 32023.830 (metalfe-32023.830.2)"}
!9 = !{i32 2, i32 4, i32 0}
!10 = !{!"Metal", i32 2, i32 3, i32 0}
!11 = !{ptr @test_base_vertex_builtin, !12, !14}
!12 = !{!13}
!13 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!14 = !{!15, !16}
!15 = !{i32 0, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_VertexID"}
!16 = !{i32 1, !"air.base_vertex", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_BaseVertex"}
!17 = !{ptr @test_base_instance_builtin, !18, !20}
!18 = !{!19}
!19 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!20 = !{!21, !22}
!21 = !{i32 0, !"air.instance_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_InstanceID"}
!22 = !{i32 1, !"air.base_instance", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_BaseInstance"}
