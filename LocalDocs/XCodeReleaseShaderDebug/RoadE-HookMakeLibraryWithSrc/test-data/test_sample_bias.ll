; Test case for E-006a2e8: texture sample bias/level option wrapping
; Verifies that air.sample_texture_cube with bias produces bias(value)
; and air.sample_texture_2d with level produces level(value)
; ModuleID = 'test_sample_bias.air'
source_filename = "test_sample_bias.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_sample_bias(ptr addrspace(1) readonly captures(none) %0, ptr addrspace(2) readonly captures(none) %1, <3 x float> %2, <2 x float> %3) local_unnamed_addr #0 {
  ; cube sample with bias(1.5) — i1 false → bias
  %5 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none) %0, ptr addrspace(2) readonly captures(none) %1, <3 x float> %2, i1 false, float 1.500000e+00, float 0.000000e+00, i32 0) #1, !alias.scope !0
  %6 = extractvalue { <4 x float>, i8 } %5, 0
  ; cube sample with level(0.5) — i1 true → level
  %7 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none) %0, ptr addrspace(2) readonly captures(none) %1, <3 x float> %2, i1 true, float 5.000000e-01, float 0.000000e+00, i32 0) #1, !alias.scope !0
  %8 = extractvalue { <4 x float>, i8 } %7, 0
  ; cube sample with bias(0.0) — should be filtered out (no-op)
  %9 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none) %0, ptr addrspace(2) readonly captures(none) %1, <3 x float> %2, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #1, !alias.scope !0
  %10 = extractvalue { <4 x float>, i8 } %9, 0
  ret void
}

declare { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <3 x float>, i1, float, float, i32) local_unnamed_addr #1

!llvm.module.flags = !{!2, !3}
!air.kernel = !{!4}

!0 = !{!1}
!1 = distinct !{!1, !"air-alias-scope-textures"}
!2 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!3 = !{i32 7, !"air.max_textures", i32 128}
!4 = !{ptr @test_sample_bias, !5, !6}
!5 = !{}
!6 = !{!7, !8, !9}
!7 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<float, sample>", !"air.arg_name", !"texCube"}
!8 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"smp"}
!9 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint3", !"air.arg_name", !"gid"}
