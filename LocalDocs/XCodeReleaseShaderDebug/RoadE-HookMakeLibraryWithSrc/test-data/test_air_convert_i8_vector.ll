; Test case for E-006a2e12: air.convert with vNi8/vNu8 vector suffixes
; Verifies that airTypeSuffixToMSL correctly maps v2i8/v4u8 to uchar2/uchar4
; (not uint8_t2/uint8_t4 which is invalid in Metal)
;
; Expected MSL for air.convert calls:
;   air.convert.f.v2f32.u.v2i8(<2 x i8>) → float2(uchar2_val)
;   air.convert.f.v4f32.u.v4u8(<4 x i8>) → float4(uchar4_val)
; ModuleID = 'test_air_convert_i8_vector.air'
source_filename = "test_air_convert_i8_vector.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Test air.convert with v2i8 source — should produce uchar2, NOT uint8_t2
define void @test_convert_v2i8(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %4
  %6 = load <2 x i8>, ptr addrspace(1) %5, align 2
  ; air.convert.f.v2f32.u.v2i8 — should NOT produce uint8_t2
  %7 = tail call fast <2 x float> @air.convert.f.v2f32.u.v2i8(<2 x i8> %6) #1
  %8 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %4
  %9 = shufflevector <2 x float> %7, <2 x float> poison, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  store <4 x float> %9, ptr addrspace(1) %8, align 16
  ret void
}

; Test air.convert with v4u8 source — should produce uchar4, NOT uint8_t4
define void @test_convert_v4u8(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %4
  %6 = load <4 x i8>, ptr addrspace(1) %5, align 4
  ; air.convert.f.v4f32.u.v4u8 — should NOT produce uint8_t4
  %7 = tail call fast <4 x float> @air.convert.f.v4f32.u.v4u8(<4 x i8> %6) #1
  %8 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %4
  store <4 x float> %7, ptr addrspace(1) %8, align 16
  ret void
}

declare <2 x float> @air.convert.f.v2f32.u.v2i8(<2 x i8>) local_unnamed_addr #1
declare <4 x float> @air.convert.f.v4f32.u.v4u8(<4 x i8>) local_unnamed_addr #1

attributes #0 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1}
!air.kernel = !{!2, !3}
!air.compile_options = !{!4}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 7, !"air.max_textures", i32 128}
!2 = !{ptr @test_convert_v2i8, !5, !6}
!3 = !{ptr @test_convert_v4u8, !5, !7}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{}
!6 = !{!8, !9, !10}
!7 = !{!8, !9, !11}
!8 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"out"}
!9 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"in_"}
!10 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!11 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
