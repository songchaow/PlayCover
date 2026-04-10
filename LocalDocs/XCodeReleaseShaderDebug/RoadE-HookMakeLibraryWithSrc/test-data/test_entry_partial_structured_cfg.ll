source_filename = "synthetic_entry_partial_structured_cfg.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_entry_partial_structured_cfg(ptr addrspace(1) writeonly %0, i32 %1) #0 {
entry:
  %2 = icmp eq i32 %1, 0
  br i1 %2, label %5, label %3

3:
  br label %5

5:
  %6 = phi i32 [ 1, %entry ], [ 2, %3 ]
  %7 = icmp slt i32 %6, 2
  br i1 %7, label %8, label %9

8:
  store i32 %6, ptr addrspace(1) %0, align 4
  br label %10

9:
  store i32 0, ptr addrspace(1) %0, align 4
  br label %10

10:
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_entry_partial_structured_cfg, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"int", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
