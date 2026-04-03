; ModuleID = 'test_fragment_depth_output.air'
source_filename = "test_fragment_depth_output.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; E-006a2e11: fragment shader with depth output.
; Key pattern: return struct with SV_Target (color) + mtl_Depth (depth).
; The depth output may not have "air.render_target" kind in metadata,
; so the converter must detect it by field name heuristic.

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn
define { <4 x float>, <4 x half>, float } @xlatMtlMain(<2 x float> %0, <4 x float> %1, <4 x float> %2, <4 x float> %3) local_unnamed_addr #0 {
  %5 = extractelement <2 x float> %0, i32 0
  %6 = extractelement <2 x float> %0, i32 1
  %7 = insertvalue { <4 x float>, <4 x half>, float } undef, <4 x float> zeroinitializer, 0
  %8 = insertvalue { <4 x float>, <4 x half>, float } %7, <4 x half> zeroinitializer, 1
  %9 = insertvalue { <4 x float>, <4 x half>, float } %8, float %5, 2
  ret { <4 x float>, <4 x half>, float } %9
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn "frame-pointer"="all" "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.fragment = !{!9}
!air.compile_options = !{!18, !19}
!llvm.ident = !{!20}
!air.version = !{!21}
!air.language_version = !{!22}
!air.source_file_name = !{!23}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}

; Fragment entry with 3 outputs: 2 color targets + 1 depth
; The depth output uses "i32 2" as kind (not "air.render_target"),
; matching the real pattern from Unity sky shaders.
!9 = !{ptr @xlatMtlMain, !10, !15}
!10 = !{!11, !12, !14}
; color target 0 — kind is "air.render_target"
!11 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target0"}
; color target 1 — kind is "air.render_target"
!12 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_Target1"}
; depth output — kind is just an index "i32 2", no explicit air.render_target / air.depth
!14 = !{i32 2, i32 0, !"air.arg_type_name", !"float", !"air.arg_name", !"mtl_Depth"}

; Inputs
!15 = !{!16}
!16 = !{i32 0, !"air.fragment_input", !"air.center", !"air.no_perspective", i32 0, i32 0, !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!17 = !{i32 1, !"air.fragment_input", !"air.center", !"air.no_perspective", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD1"}

!18 = !{!"air.compile.denorms_disable"}
!19 = !{!"air.compile.fast_math_enable"}
!20 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!21 = !{i32 2, i32 7, i32 0}
!22 = !{!"Metal", i32 2, i32 4, i32 0}
!23 = !{!"/Users/songdogwang/test_fragment_depth_output.metal"}
