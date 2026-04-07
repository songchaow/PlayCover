; ModuleID = 'test_fragment_front_facing.air'
source_filename = "test_fragment_front_facing.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

; Toolchain-derived minimal sample for fragment `air.front_facing`.
; Key pattern: a fragment function with both `air.fragment_input` and `air.front_facing`.
; Before E-006g3a, the converter generated `mtl_FrontFace` in the body but never declared
; a `[[front_facing]]` parameter when `stage_in` was also present, causing Metal compile failure.
; Function Attrs: nounwind optsize memory(none)
define <4 x float> @test_fragment_front_facing(i1 %0, <3 x float> %1) local_unnamed_addr #0 {
  %3 = select i1 %0, float 1.000000e+00, float -1.000000e+00
  %4 = insertelement <4 x float> zeroinitializer, float %3, i64 0
  %5 = extractelement <3 x float> %1, i64 2
  %6 = insertelement <4 x float> %4, float %5, i64 2
  %7 = insertelement <4 x float> %6, float 1.000000e+00, i64 3
  ret <4 x float> %7
}

attributes #0 = { nounwind optsize memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!llvm.ident = !{!8}
!air.version = !{!9}
!air.language_version = !{!10}
!air.compile_options = !{!11, !12, !13}
!air.fragment = !{!14}

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
!11 = !{!"air.compile.denorms_disable"}
!12 = !{!"air.compile.fast_math_enable"}
!13 = !{!"air.compile.framebuffer_fetch_enable"}
!14 = !{ptr @test_fragment_front_facing, !15, !17}
!15 = !{!16}
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!17 = !{!18, !19}
!18 = !{i32 0, !"air.front_facing", !"air.arg_type_name", !"bool", !"air.arg_name", !"mtl_FrontFace"}
!19 = !{i32 1, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"TEXCOORD0"}
