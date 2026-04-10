source_filename = "test_underscore_struct_reference.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-ios15.0.0"

%struct._ShadowParams_Type = type { float }

define <4 x float> @test_underscore_struct_reference(ptr addrspace(2) nocapture readonly align 4 dereferenceable(4) "air-buffer-no-alias" %0, i32 %1) local_unnamed_addr #0 {
entry:
  %bias.ptr = getelementptr inbounds %struct._ShadowParams_Type, ptr addrspace(2) %0, i64 0, i32 0
  %bias = load float, ptr addrspace(2) %bias.ptr, align 4
  %vid.f = sitofp i32 %1 to float
  %x = fadd float %bias, %vid.f
  %r0 = insertelement <4 x float> poison, float %x, i64 0
  %r1 = insertelement <4 x float> %r0, float 0.000000e+00, i64 1
  %r2 = insertelement <4 x float> %r1, float 0.000000e+00, i64 2
  %r3 = insertelement <4 x float> %r2, float 1.000000e+00, i64 3
  ret <4 x float> %r3
}

attributes #0 = { nounwind memory(read) "no-builtins" }

!air.vertex = !{!0}
!air.compile_options = !{!4}
!0 = !{ptr @test_underscore_struct_reference, !1, !2, !5}
!1 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!2 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !3, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"_ShadowParams_Type", !"air.arg_name", !"shadowParams"}
!3 = !{i32 0, i32 4, i32 0, !"float", !"bias"}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 1, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
