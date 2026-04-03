; Test for E-006a2e5: integer literal half-suffix in intrinsic calls
; Pattern from Genshin live diagnostics: fma(half_var, -2.0h, 3h) → error
; The IR contains: air.fma.f16(half %t, half -2.0, half 3.000000e+00)
; After E-006a2e4 fix, -2.0 → -2.0h (ok), but 3.000000e+00 → 3h (error: integer literal can't use h suffix)
; Fix: integer literals should become 3.0h not 3h

source_filename = "test_int_literal_half_suffix.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Fragment function testing integer literal half-suffix pattern
define <4 x float> @xlatMtlMain(<4 x float> noundef %0) local_unnamed_addr #0 {
entry:
  %1 = extractelement <4 x float> %0, i64 0
  %2 = fptrunc float %1 to half

  ; Pattern 1: fma with integer literal 3.0 → should become 3.0h, not 3h
  %3 = tail call fast half @air.fma.f16(half %2, half -2.000000e+00, half 3.000000e+00) #2

  ; Pattern 2: fmax with integer literal 0 → should become 0.0h, not 0h
  ; Note: real Genshin pattern uses half2 vector
  %4 = insertelement <2 x half> undef, half %2, i64 0
  %5 = insertelement <2 x half> %4, half %2, i64 1
  %6 = tail call fast <2 x half> @air.fast_fmax.v2f16(<2 x half> %5, <2 x half> zeroinitializer) #2

  ; Assemble result
  %7 = fpext half %3 to float
  %8 = extractelement <2 x half> %6, i64 0
  %9 = fpext half %8 to float
  %10 = insertelement <4 x float> <float poison, float poison, float poison, float 0.000000e+00>, float %7, i64 0
  %11 = insertelement <4 x float> %10, float %9, i64 1
  ret <4 x float> %11
}

declare half @air.fma.f16(half, half, half) local_unnamed_addr #1
declare <2 x half> @air.fast_fmax.v2f16(<2 x half>, <2 x half>) local_unnamed_addr #1

attributes #0 = { mustprogress nofree nosync nounwind willreturn memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" "stack-protector-buffer-size"="8" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { nounwind willreturn memory(none) }

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
!20 = !{!"test_int_literal_half_suffix.metal"}
