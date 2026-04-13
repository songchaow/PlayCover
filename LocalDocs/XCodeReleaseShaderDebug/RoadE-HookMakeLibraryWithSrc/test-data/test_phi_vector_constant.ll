source_filename = "synthetic_phi_vector_constant.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_phi_vector_constant(ptr addrspace(1) writeonly %0, i32 %1) #0 {
entry:
  %2 = icmp eq i32 %1, 0
  br i1 %2, label %3, label %4

3:
  br label %5

4:
  br label %5

5:
  %6 = phi <2 x float> [ <float 0.000000e+00, float 0.000000e+00>, %3 ], [ <float 1.000000e+00, float 2.000000e+00>, %4 ]
  store <2 x float> %6, ptr addrspace(1) %0, align 8
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_phi_vector_constant, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
