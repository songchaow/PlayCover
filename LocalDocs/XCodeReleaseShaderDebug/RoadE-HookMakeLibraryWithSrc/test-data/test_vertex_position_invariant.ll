; ModuleID = 'test_vertex_position_invariant.air'
source_filename = "test_vertex_position_invariant.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Toolchain-generated minimal sample for vertex position invariant preservation.
; Key pattern: multi-output vertex return where `air.position` carries `air.invariant`.
define <{ <4 x float>, <2 x float> }> @test_vertex_position_invariant(i32 %0) local_unnamed_addr #0 {
  %2 = uitofp i32 %0 to float
  %3 = insertelement <4 x float> poison, float %2, i64 0
  %4 = insertelement <4 x float> %3, float 0.000000e+00, i64 1
  %5 = insertelement <4 x float> %4, float 0.000000e+00, i64 2
  %6 = insertelement <4 x float> %5, float 1.000000e+00, i64 3
  %7 = insertelement <2 x float> poison, float %2, i64 0
  %8 = insertelement <2 x float> %7, float 1.000000e+00, i64 1
  %9 = insertvalue <{ <4 x float>, <2 x float> }> undef, <4 x float> %6, 0
  %10 = insertvalue <{ <4 x float>, <2 x float> }> %9, <2 x float> %8, 1
  ret <{ <4 x float>, <2 x float> }> %10
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="64" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!air.vertex = !{!8}
!air.compile_options = !{!13}
!llvm.ident = !{!14}
!air.version = !{!15}
!air.language_version = !{!16}
!air.source_file_name = !{!17}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_samplers", i32 16}
!8 = !{ptr @test_vertex_position_invariant, !9, !12}
!9 = !{!10, !11}
!10 = !{!"air.position", !"air.invariant", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!11 = !{!"air.vertex_output", !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!12 = !{!18}
!13 = !{!"air.compile.fast_math_enable"}
!14 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!15 = !{i32 2, i32 7, i32 0}
!16 = !{!"Metal", i32 2, i32 4, i32 0}
!17 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_vertex_position_invariant.metal"}
!18 = !{i32 0, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
