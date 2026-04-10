source_filename = "synthetic_unconditional_successor_gating.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_unconditional_successor_gating(ptr addrspace(1) writeonly %0, i32 %1) #0 {
entry:
  %2 = icmp eq i32 %1, 0
  br i1 %2, label %3, label %4

3:
  br label %10

4:
  %5 = icmp eq i32 %1, 1
  br i1 %5, label %6, label %8

6:
  br label %10

8:
  br label %10

10:
  %11 = phi float [ 1.000000e+00, %3 ], [ 2.000000e+00, %6 ], [ 3.000000e+00, %8 ]
  store float %11, ptr addrspace(1) %0, align 4
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_unconditional_successor_gating, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"float", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
