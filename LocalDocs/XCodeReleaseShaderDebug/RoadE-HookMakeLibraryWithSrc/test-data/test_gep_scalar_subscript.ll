; Test: GEP indexing into a scalar struct field (E-006a2e14)
; IR pattern: getelementptr %struct.FGlobals, ptr %0, i64 0, i32 N, i64 %idx
; where field N is a scalar (float), not an array/vector
; MSL should emit: auto tmp = &struct.field; val = tmp[idx];

source_filename = "test_gep_scalar_subscript.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

%struct.FGlobals = type { float, float, float4, <2 x float> }

; vertex shader: GEP into scalar float field, then index with variable
define void @test_gep_scalar_subscript(ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(32) "air-buffer-no-alias" %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = zext i32 %1 to i64
  ; GEP: struct → field 0 (float) → index with variable (scalar subscript)
  %4 = getelementptr inbounds %struct.FGlobals, ptr addrspace(2) %0, i64 0, i32 0, i64 %3
  %5 = load float, ptr addrspace(2) %4, align 4
  ; GEP: struct → field 1 (float) → index with variable (scalar subscript)
  %6 = getelementptr inbounds %struct.FGlobals, ptr addrspace(2) %0, i64 0, i32 1, i64 %3
  %7 = load float, ptr addrspace(2) %6, align 4
  ; GEP: struct → field 2 (float4) → index with variable (vector subscript — should still work)
  %8 = getelementptr inbounds %struct.FGlobals, ptr addrspace(2) %0, i64 0, i32 2, i64 %3
  %9 = load float, ptr addrspace(2) %8, align 4
  ret void
}

; vertex shader: GEP into scalar float field with constant index
define void @test_gep_scalar_const(ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(32) "air-buffer-no-alias" %0) local_unnamed_addr #0 {
  ; GEP: struct → field 0 (float) → constant index 1 (scalar subscript)
  %2 = getelementptr inbounds %struct.FGlobals, ptr addrspace(2) %0, i64 0, i32 0, i64 1
  %3 = load float, ptr addrspace(2) %2, align 4
  ret void
}

; vertex shader: GEP into float4 vector field (should NOT trigger scalar fix)
define void @test_gep_vector_subscript(ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(32) "air-buffer-no-alias" %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = zext i32 %1 to i64
  ; GEP: struct → field 3 (<2 x float>) → index with variable (vector subscript)
  %4 = getelementptr inbounds %struct.FGlobals, ptr addrspace(2) %0, i64 0, i32 3, i64 %3
  %5 = load float, ptr addrspace(2) %4, align 4
  ret void
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-fath"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2}
!air.vertex = !{!3, !10, !14}
!air.compile_options = !{!17}
!llvm.ident = !{!18}
!air.version = !{!19}
!air.language_version = !{!20}
!air.source_file_name = !{!21}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}

!3 = !{ptr @test_gep_scalar_subscript, !4, !5}
!4 = !{!6}
!5 = !{!7, !8, !9}
!6 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!7 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 32, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !22, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"FGlobals", !"air.arg_name", !"fg"}
!8 = !{i32 1, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
!9 = !{i32 2, !"air.vertex_output", !"air.arg_type_name", !"float4", !"air.arg_name", !"out_pos"}

!10 = !{ptr @test_gep_scalar_const, !11, !12}
!11 = !{!6}
!12 = !{!13, !8, !9}
!13 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 32, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !22, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"FGlobals", !"air.arg_name", !"fg"}

!14 = !{ptr @test_gep_vector_subscript, !4, !15}
!15 = !{!16, !8, !9}
!16 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 32, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !22, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"FGlobals", !"air.arg_name", !"fg"}

!17 = !{!"air.compile.fast_math_enable"}
!18 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!19 = !{i32 2, i32 7, i32 0}
!20 = !{!"Metal", i32 3, i32 2, i32 0}
!21 = !{!"test_gep_scalar_subscript.metal"}

!22 = !{i32 0, i32 4, i32 0, !"float", !"alpha0", i32 4, i32 4, i32 0, !"float", !"alpha1", i32 8, i32 16, i32 0, !"float4", !"color", i32 24, i32 8, i32 0, !"float2", !"offset"}
