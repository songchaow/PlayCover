source_filename = "synthetic_self_loop_exit_merge_values.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_self_loop_exit_merge_values(ptr addrspace(1) writeonly %0, i32 %1) #0 {
entry:
  %2 = icmp sgt i32 %1, 0
  br i1 %2, label %3, label %7

3:
  br label %4

4:
  %5 = phi float [ 0.000000e+00, %3 ], [ %9, %4 ]
  %6 = phi float [ 1.000000e+00, %3 ], [ %8, %4 ]
  %8 = fadd fast float %6, %5
  %9 = fadd fast float %5, 1.000000e+00
  %10 = fcmp fast olt float %9, 2.000000e+00
  br i1 %10, label %4, label %7

7:
  %11 = phi float [ 4.200000e+01, %entry ], [ %8, %4 ]
  %12 = phi float [ -1.000000e+00, %entry ], [ %9, %4 ]
  %13 = icmp eq i32 %1, 10
  br i1 %13, label %14, label %16

14:
  %15 = fadd fast float %11, %12
  br label %18

16:
  %17 = fsub fast float %11, %12
  br label %18

18:
  %19 = phi float [ %15, %14 ], [ %17, %16 ]
  store float %19, ptr addrspace(1) %0, align 4
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_self_loop_exit_merge_values, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"float", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
