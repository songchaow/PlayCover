; Test case for E-006a2e12: sample_compare with bias/level and offset
; Verifies that sample_compare correctly wraps bias/level float as option struct
; and filters i32 compare func / offset / control flags
;
; Expected MSL:
;   depthTex.sample_compare(smp, uv, 0.5)              — basic
;   depthTex.sample_compare(smp, uv, 0.5, bias(1.0))   — with bias
;   depthTex.sample_compare(smp, uv, 0.5, int2(1, 2))  — with offset
; ModuleID = 'test_sample_compare.air'
source_filename = "test_sample_compare.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_sample_compare_ops(ptr addrspace(1) %0, ptr addrspace(1) captures(none) %1, ptr addrspace(1) %7, ptr addrspace(2) readonly captures(none) %8, <2 x i32> %9) local_unnamed_addr #0 {
  %11 = tail call fast <2 x float> @air.convert.f.v2f32.u.v2i32(<2 x i32> %9) #12
  ; Test 1: basic sample_compare — no bias/level
  %12 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, i32 1, <2 x float> %11, float 5.000000e-01, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13
  %13 = extractvalue { float, i8 } %12, 0
  ; Test 2: sample_compare with bias(1.0) — i1 false → bias
  %14 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, i32 1, <2 x float> %11, float 5.000000e-01, i1 true, <2 x i32> zeroinitializer, i1 false, float 1.000000e+00, float 0.000000e+00, i32 0) #13
  %15 = extractvalue { float, i8 } %14, 0
  ; Test 3: sample_compare with offset
  %16 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, i32 1, <2 x float> %11, float 3.000000e-01, i1 true, <2 x i32> <i32 1, i32 2>, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13
  %17 = extractvalue { float, i8 } %16, 0
  ; Test 4: sample_compare with level(2.0) — i1 true → level
  %18 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, i32 1, <2 x float> %11, float 5.000000e-01, i1 true, <2 x i32> zeroinitializer, i1 true, float 2.000000e+00, float 0.000000e+00, i32 0) #13
  %19 = extractvalue { float, i8 } %18, 0
  %20 = insertelement <4 x float> poison, float %13, i64 0
  %21 = shufflevector <4 x float> %20, <4 x float> poison, <4 x i32> zeroinitializer
  %22 = insertelement <4 x float> %21, float %15, i64 1
  %23 = insertelement <4 x float> %22, float %17, i64 2
  %24 = insertelement <4 x float> %23, float %19, i64 3
  tail call void @air.write_texture_2d.v4f32(ptr addrspace(1) captures(none) %1, <2 x i32> %9, <4 x float> %24, i32 0, i32 2) #15
  ret void
}

declare <2 x float> @air.convert.f.v2f32.u.v2i32(<2 x i32>) local_unnamed_addr #1
declare { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), i32, <2 x float>, float, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #7
declare void @air.write_texture_2d.v4f32(ptr addrspace(1) captures(none), <2 x i32>, <4 x float>, i32, i32) local_unnamed_addr #9

attributes #0 = { convergent mustprogress nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #7 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #9 = { mustprogress nounwind willreturn memory(argmem: readwrite) }
attributes #12 = { nounwind willreturn memory(none) }
attributes #13 = { convergent nounwind willreturn memory(argmem: read) }
attributes #15 = { nounwind willreturn memory(argmem: readwrite) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5}
!air.kernel = !{!6}
!air.compile_options = !{!7}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_textures", i32 128}
!4 = !{i32 7, !"air.max_samplers", i32 16}
!5 = !{i32 7, !"air.max_read_write_textures", i32 8}
!6 = !{ptr @test_sample_compare_ops, !8, !9}
!7 = !{!"air.compile.fast_math_enable"}
!8 = !{}
!9 = !{!10, !11, !12, !13, !14}
!10 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.read", !"air.arg_type_name", !"texture2d<float, read>", !"air.arg_name", !"texR"}
!11 = !{i32 1, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.write", !"air.arg_type_name", !"texture2d<float, write>", !"air.arg_name", !"texW"}
!12 = !{i32 2, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"depth2d<float, sample>", !"air.arg_name", !"depthTex"}
!13 = !{i32 3, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"smp"}
!14 = !{i32 4, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"gid"}
