; Test case for E-006a2e10: ___metal_* intrinsic + @__air_sampler_state + uint8_t2
; ModuleID = 'test_metal_intrinsic_sampler_state.air'
source_filename = "test_metal_intrinsic_sampler_state.metal"
target datalayout = "e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f16:16:16-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024"
target triple = "air64-apple-macos14.0.0"

@__air_sampler_state = external global i8

; Fragment shader testing:
; 1. @___metal_fract_v2float → fract() — LLVM inline intrinsic (not @air.* prefix)
; 2. @__air_sampler_state → sampler parameter mapping in texture calls
; 3. zext <2 x i1> to <2 x i8> → uchar2 (via irScalarTypeToMSL path)
define void @test_metal_intrinsic(ptr addrspace(1) readonly captures(none) %tex, ptr addrspace(2) readonly captures(none) %sampler_arg, <2 x float> %uv, <2 x half> %hv, <2 x float> %a, <2 x float> %b) local_unnamed_addr #0 {
entry:
  ; Test 1: ___metal_fract_v2float intrinsic — should translate to fract()
  %0 = call <2 x float> @___metal_fract_v2float(<2 x float> %uv)
  ; Test 2: ___metal_sin_f32 scalar intrinsic
  %1 = call float @___metal_sin_f32(float 3.141590e+00)
  ; Test 3: ___metal_clamp_v2float ternary intrinsic
  %2 = call <2 x float> @___metal_clamp_v2float(<2 x float> %a, <2 x float> %b, <2 x float> %uv)
  ; Test 4: @__air_sampler_state used as sampler arg — should map to sampler parameter
  %3 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %tex, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %uv, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #1
  ; Test 5: fcmp producing <2 x i1>, then zext to <2 x i8> — should be uchar2
  %4 = fcmp oeq <2 x float> %a, %b
  %5 = zext <2 x i1> %4 to <2 x i8>
  ; Test 6: ___metal_fabs_v2float
  %6 = call <2 x float> @___metal_fabs_v2float(<2 x float> %a)
  ; Test 7: ___metal_fma_v2float
  %7 = call <2 x float> @___metal_fma_v2float(<2 x float> %a, <2 x float> %b, <2 x float> %uv)
  ; Test 8: ___metal_fast_sin_v2float
  %8 = call <2 x float> @___metal_fast_sin_v2float(<2 x float> %uv)
  ret void
}

declare <2 x float> @___metal_fract_v2float(<2 x float>)
declare float @___metal_sin_f32(float)
declare <2 x float> @___metal_clamp_v2float(<2 x float>, <2 x float>, <2 x float>)
declare <2 x float> @___metal_fabs_v2float(<2 x float>)
declare <2 x float> @___metal_fma_v2float(<2 x float>, <2 x float>, <2 x float>)
declare <2 x float> @___metal_fast_sin_v2float(<2 x float>)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #1

attributes #0 = { "air.fragment" "no-frame-pointer-elim" "preserve-none" }
attributes #1 = { "air" }

!0 = !{i32 2, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_arg"}
!1 = !{i32 1, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"tex"}
!2 = !{i32 7, !"air.max_samplers", i32 16}
!3 = !{ptr @test_metal_intrinsic, !4, !6}
!4 = !{i32 1, !"air.vertex", null}
!5 = !{i32 2}
!6 = !{i32 0, i32 1, !7, !8, !9, !10}
!7 = !{!"air.position"}
!8 = !{i32 0, i32 0}
!9 = !{i32 3, !"air.arg_type_name", !"<2 x float>"}
!10 = !{i32 4, !"air.arg_type_name", !"<2 x float>"}
