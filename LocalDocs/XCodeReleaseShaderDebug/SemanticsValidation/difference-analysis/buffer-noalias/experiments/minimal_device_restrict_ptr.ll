; ModuleID = '/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_device_restrict_ptr.bc'
source_filename = "/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_device_restrict_ptr.metal"
target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx15.0.0"

%struct.Uniforms = type { <4 x float> }

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write)
define void @test_kernel_restrict_ptr(ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %0, ptr addrspace(2) noalias nocapture noundef readonly %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %1, i64 0, i32 0
  %5 = load <4 x float>, ptr addrspace(2) %4, align 16, !tbaa !23
  %6 = zext i32 %2 to i64
  %7 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %6
  store <4 x float> %5, ptr addrspace(1) %7, align 16, !tbaa !23, !alias.scope !26
  ret void
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9}
!air.compile_options = !{!16, !17, !18}
!llvm.ident = !{!19}
!air.version = !{!20}
!air.language_version = !{!21}
!air.source_file_name = !{!22}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_kernel_restrict_ptr, !10, !11}
!10 = !{}
!11 = !{!12, !13, !15}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"outColor"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !14, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"u"}
!14 = !{i32 0, i32 16, i32 0, !"float4", !"color"}
!15 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!16 = !{!"air.compile.denorms_disable"}
!17 = !{!"air.compile.fast_math_enable"}
!18 = !{!"air.compile.framebuffer_fetch_enable"}
!19 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!20 = !{i32 2, i32 7, i32 0}
!21 = !{!"Metal", i32 3, i32 2, i32 0}
!22 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_device_restrict_ptr.metal"}
!23 = !{!24, !24, i64 0}
!24 = !{!"omnipotent char", !25, i64 0}
!25 = !{!"Simple C++ TBAA"}
!26 = !{!27}
!27 = distinct !{!27, !28, !"air-alias-scope-arg(0)"}
!28 = distinct !{!28, !"air-alias-scopes(test_kernel_restrict_ptr)"}
