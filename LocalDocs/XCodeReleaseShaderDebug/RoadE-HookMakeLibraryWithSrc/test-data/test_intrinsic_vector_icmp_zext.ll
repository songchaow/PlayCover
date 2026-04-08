; Test for E-006a2e4: intrinsic type ambiguity + vector icmp/zext lowering
; Manually crafted to match real app (Genshin) IR patterns

source_filename = "test_intrinsic_vector_icmp_zext.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Fragment function testing all three E-006a2e4 blocker patterns
define <4 x float> @xlatMtlMain(<4 x float> noundef %0) local_unnamed_addr #0 {
entry:
  ; --- Pattern 1: intrinsic literal type ambiguity ---
  ; clamp(half_var, 0.0, 1.0) — bare double literals with half operand
  %1 = extractelement <4 x float> %0, i64 0
  %2 = fptrunc float %1 to half
  ; This is the real pattern from Genshin: air.clamp with half operand but double literal
  %3 = tail call fast half @air.clamp.f16(half %2, half 0.0, half 1.0) #2

  ; --- Pattern 2: vector icmp producing boolN ---
  ; fcmp oeq <2 x half> → <2 x i1>, result assigned via extractelement
  %4 = extractelement <4 x float> %0, i64 1
  %5 = fptrunc float %4 to half
  %6 = insertelement <2 x half> undef, half %2, i64 0
  %7 = insertelement <2 x half> %6, half %5, i64 1
  %8 = insertelement <2 x half> undef, half %5, i64 0
  %9 = insertelement <2 x half> %8, half %2, i64 1
  ; fcmp on vectors produces <2 x i1> — must become bool2
  %10 = fcmp fast oeq <2 x half> %7, %9
  %11 = extractelement <2 x i1> %10, i64 0
  %12 = extractelement <2 x i1> %10, i64 1

  ; --- Pattern 3: zext <N x i1> to <N x i8> → ucharN ---
  ; zext of vector bool to vector uint8 must use ucharN, not uint8_tN
  %13 = zext <2 x i1> %10 to <2 x i8>
  %14 = extractelement <2 x i8> %13, i64 0

; Assemble result so clamp / cmp / zext all remain behavior-observable
%15 = fpext half %3 to float
%16 = fpext half %5 to float
%17 = uitofp i1 %11 to float
%18 = uitofp i8 %14 to float
%19 = fadd float %17, %18
%20 = insertelement <4 x float> <float poison, float poison, float poison, float 0.000000e+00>, float %15, i64 0
%21 = insertelement <4 x float> %20, float %16, i64 1
%22 = insertelement <4 x float> %21, float %19, i64 2
ret <4 x float> %22

}

declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

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
!20 = !{!"test_intrinsic_vector_icmp_zext.metal"}
