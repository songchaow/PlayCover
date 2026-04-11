; ModuleID = 'test_fragment_no_entry_input.air'
source_filename = "test_fragment_no_entry_input.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios11.0.0"

; Minimal fragment sample with no entry inputs.
; Real blocked family shape: the converter must not invent a ghost `[[position]]`
; parameter when metadata and IR signature both have zero inputs.
define <{ <4 x float>, <4 x float> }> @test_fragment_no_entry_input() local_unnamed_addr #0 {
  ret <{ <4 x float>, <4 x float> }> zeroinitializer
}

attributes #0 = { norecurse nounwind memory(none) "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "frame-pointer"="all" "less-precise-fpmad"="false" "no-infs-fp-math"="true" "no-jump-tables"="false" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" "use-soft-float"="false" }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}
!air.version = !{!2}
!air.language_version = !{!3}
!air.compile_options = !{!4, !5, !6}
!air.fragment = !{!7}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"Apple metal version 31001.660 (metalfe-31001.660.7-windows)"}
!2 = !{i32 2, i32 0, i32 0}
!3 = !{!"Metal", i32 2, i32 0, i32 0}
!4 = !{!"air.compile.denorms_disable"}
!5 = !{!"air.compile.fast_math_enable"}
!6 = !{!"air.compile.framebuffer_fetch_enable"}
!7 = !{ptr @test_fragment_no_entry_input, !8, !11}
!8 = !{!9, !10}
!9 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target0"}
!10 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target1"}
!11 = !{}
