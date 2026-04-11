source_filename = "synthetic_nested_common_merge_with_unstructured_tail.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_nested_common_merge_with_unstructured_tail(ptr addrspace(1) writeonly %0, i32 %1, i32 %2) #0 {
entry:
  %3 = icmp eq i32 %1, 0
  br i1 %3, label %10, label %40

10:
  %11 = icmp eq i32 %2, 0
  br i1 %11, label %30, label %20

20:
  br label %31

30:
  br label %31

31:
  %32 = phi i32 [ 1, %20 ], [ 2, %30 ]
  br label %50

40:
  br label %50

50:
  %51 = phi i32 [ %32, %31 ], [ 4, %40 ]
  store i32 %51, ptr addrspace(1) %0, align 4
  br label %60

60:
  %61 = phi i32 [ 0, %50 ], [ %63, %60 ]
  %62 = icmp slt i32 %61, 2
  %63 = add nuw nsw i32 %61, 1
  br i1 %62, label %60, label %70

70:
  ret void
}

attributes #0 = { nounwind memory(argmem: write) "no-builtins" }

!air.kernel = !{!0}
!air.compile_options = !{!1}
!0 = !{ptr @test_nested_common_merge_with_unstructured_tail, !2, !3}
!1 = !{!4}
!2 = !{}
!3 = !{!5, !6, !7}
!4 = !{!"air.compile.fast_math_enable"}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_name", !"int", !"air.arg_name", !"output"}
!6 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid0"}
!7 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid1"}
