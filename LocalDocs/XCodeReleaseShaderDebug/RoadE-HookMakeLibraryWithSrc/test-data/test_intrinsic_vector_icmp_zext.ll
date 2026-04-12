; Test for CC-003.22: vector bool zext feeding shufflevector-based mask materialization

source_filename = "test_intrinsic_vector_icmp_zext.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define <4 x float> @xlatMtlMain(<4 x float> noundef %0) local_unnamed_addr #0 {
entry:
  %1 = shufflevector <4 x float> %0, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %2 = shufflevector <4 x float> %0, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %3 = fcmp fast oge <2 x float> %1, %2
  %4 = zext <2 x i1> %3 to <2 x i8>
  %5 = shufflevector <2 x i8> %4, <2 x i8> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %6 = fcmp fast oge <2 x float> %2, %1
  %7 = zext <2 x i1> %6 to <2 x i8>
  %8 = shufflevector <2 x i8> %7, <2 x i8> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %9 = shufflevector <4 x i8> %5, <4 x i8> %8, <4 x i32> <i32 0, i32 1, i32 4, i32 5>
  %10 = and <4 x i8> %9, <i8 1, i8 1, i8 1, i8 1>
  %11 = icmp ne <4 x i8> %10, zeroinitializer
  %12 = extractelement <4 x i1> %11, i64 0
  %13 = select i1 %12, float 1.000000e+00, float 0.000000e+00
  %14 = insertelement <4 x float> undef, float %13, i64 0
  %15 = extractelement <4 x i1> %11, i64 1
  %16 = select i1 %15, float 1.000000e+00, float 0.000000e+00
  %17 = insertelement <4 x float> %14, float %16, i64 1
  %18 = extractelement <4 x i1> %11, i64 2
  %19 = select i1 %18, float 1.000000e+00, float 0.000000e+00
  %20 = insertelement <4 x float> %17, float %19, i64 2
  %21 = extractelement <4 x i1> %11, i64 3
  %22 = select i1 %21, float 1.000000e+00, float 0.000000e+00
  %23 = insertelement <4 x float> %20, float %22, i64 3
  ret <4 x float> %23
}

attributes #0 = { mustprogress nofree nosync nounwind willreturn memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" "stack-protector-buffer-size"="8" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.fragment = !{!9}
!air.compile_options = !{!14}
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
!9 = !{ptr @xlatMtlMain, !10, !12}
!10 = !{!11}
!11 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!12 = !{!13}
!13 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"coord"}
!14 = !{!"air.compile.fast_math_enable"}
!17 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!18 = !{i32 2, i32 7, i32 0}
!19 = !{!"Metal", i32 3, i32 2, i32 0}
!20 = !{!"test_intrinsic_vector_icmp_zext.metal"}
