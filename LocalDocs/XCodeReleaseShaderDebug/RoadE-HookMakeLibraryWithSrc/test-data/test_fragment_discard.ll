; ModuleID = 'test_fragment_discard.air'
source_filename = "test_fragment_discard.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Minimal fragment sample that preserves real fragment termination.
; The converter must emit `discard_fragment();` rather than a placeholder comment,
; otherwise regenerated AIR linearizes the branch and loses `air.discard_fragment`.
define <4 x float> @test_fragment_discard(float %0) local_unnamed_addr #0 {
entry:
  %1 = fcmp olt float %0, 0.000000e+00
  br i1 %1, label %2, label %3

2:
  tail call void @air.discard_fragment() #1
  br label %3

3:
  ret <4 x float> <float 1.000000e+00, float 0.000000e+00, float 0.000000e+00, float 1.000000e+00>
}

declare void @air.discard_fragment() #1

attributes #0 = { nounwind memory(none) "no-builtins" }
attributes #1 = { convergent nounwind }

!llvm.module.flags = !{!0}
!air.compile_options = !{!1}
!air.fragment = !{!2}
!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!3}
!2 = !{ptr @test_fragment_discard, !4, !6}
!3 = !{!"air.compile.fast_math_enable"}
!4 = !{!5}
!5 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!6 = !{!7}
!7 = !{i32 0, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float", !"air.arg_name", !"TEXCOORD0"}
