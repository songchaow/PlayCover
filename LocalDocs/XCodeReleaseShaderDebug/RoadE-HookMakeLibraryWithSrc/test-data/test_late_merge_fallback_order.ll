source_filename = "synthetic_late_merge_fallback_order.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_late_merge_fallback_order(ptr addrspace(1) writeonly %0, i32 %1) #0 {
entry:
  %2 = icmp eq i32 %1, 0
  br i1 %2, label %3, label %4

3:
  br label %5

4:
  br label %5

5:
  %6 = phi i32 [ 1, %3 ], [ 2, %4 ]
  store i32 %6, ptr addrspace(1) %0, align 4
  br label %7

7:
  %8 = phi i32 [ 0, %5 ], [ %10, %7 ]
  %9 = icmp slt i32 %8, 1
  %10 = add nuw nsw i32 %8, 1
  br i1 %9, label %7, label %11

11:
  %12 = icmp eq i32 %1, 10
  br i1 %12, label %15, label %13

13:
  %14 = icmp eq i32 %1, 20
  br i1 %14, label %17, label %15

15:
  br label %18

17:
  br label %18

18:
  %19 = phi i32 [ 30, %15 ], [ 40, %17 ]
  store i32 %19, ptr addrspace(1) %0, align 4
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_late_merge_fallback_order, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"int", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
