; ModuleID = 'test_scalar_select_vector.air'
source_filename = "test_scalar_select_vector.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

@_ZL7ImmCB_Test = internal unnamed_addr addrspace(2) constant [4 x <4 x float>] [<4 x float> <float 1.000000e+00, float 0.000000e+00, float 2.000000e+00, float 4.000000e+00>, <4 x float> <float -1.000000e+00, float 3.000000e+00, float 5.000000e+00, float 6.000000e+00>, <4 x float> <float 0.000000e+00, float 7.000000e+00, float 8.000000e+00, float 9.000000e+00>, <4 x float> <float 2.000000e+00, float 4.000000e+00, float 6.000000e+00, float 8.000000e+00>], align 16

define void @test_scalar_select_vector(ptr addrspace(1) %0, i32 %1) local_unnamed_addr #0 {
  %3 = and i32 %1, 3
  %4 = zext i32 %3 to i64
  %5 = getelementptr inbounds [4 x <4 x float>], ptr addrspace(2) @_ZL7ImmCB_Test, i64 0, i64 %4
  %6 = load <4 x float>, ptr addrspace(2) %5, align 16
  %7 = shufflevector <4 x float> %6, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %8 = extractelement <4 x float> %6, i64 0
  %9 = fcmp fast ogt float %8, 0.000000e+00
  %10 = select fast i1 %9, <3 x float> <float 1.000000e+00, float 2.000000e+00, float 3.000000e+00>, <3 x float> %7
  %11 = extractelement <3 x float> %10, i64 0
  %12 = insertelement <4 x float> undef, float %11, i64 0
  %13 = extractelement <3 x float> %10, i64 1
  %14 = insertelement <4 x float> %12, float %13, i64 1
  %15 = extractelement <3 x float> %10, i64 2
  %16 = insertelement <4 x float> %14, float %15, i64 2
  %17 = extractelement <4 x float> %6, i64 3
  %18 = insertelement <4 x float> %16, float %17, i64 3
  %19 = zext i32 %1 to i64
  %20 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %19
  store <4 x float> %18, ptr addrspace(1) %20, align 16
  ret void
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9}
!air.compile_options = !{!14, !15, !16}
!llvm.ident = !{!17}
!air.version = !{!18}
!air.language_version = !{!19}
!air.source_file_name = !{!20}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_scalar_select_vector, !10, !11}
!10 = !{}
!11 = !{!12, !13}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"output"}
!13 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!14 = !{!"air.compile.denorms_disable"}
!15 = !{!"air.compile.fast_math_enable"}
!16 = !{!"air.compile.framebuffer_fetch_enable"}
!17 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!18 = !{i32 2, i32 7, i32 0}
!19 = !{!"Metal", i32 3, i32 2, i32 0}
!20 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_scalar_select_vector.metal"}
