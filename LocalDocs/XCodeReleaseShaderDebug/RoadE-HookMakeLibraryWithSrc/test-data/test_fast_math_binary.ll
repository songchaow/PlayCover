; ModuleID = 'build/road-e-test/test_fast_math_binary.air'
source_filename = "LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fast_math_binary.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: write)
define void @test_fast_math_binary(ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %0, ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %1, ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %2, ptr addrspace(2) nocapture noundef readonly "air-buffer-no-alias" %3, ptr addrspace(2) nocapture noundef readonly "air-buffer-no-alias" %4, ptr addrspace(2) nocapture noundef readonly "air-buffer-no-alias" %5, i32 noundef %6) local_unnamed_addr #0 {
  %8 = zext i32 %6 to i64
  %9 = getelementptr inbounds <2 x float>, ptr addrspace(2) %3, i64 %8
  %10 = load <2 x float>, ptr addrspace(2) %9, align 8, !tbaa !26, !alias.scope !29, !noalias !32
  %11 = fadd fast <2 x float> %10, <float -5.000000e-01, float -5.000000e-01>
  %12 = getelementptr inbounds <4 x float>, ptr addrspace(2) %4, i64 %8
  %13 = load <4 x float>, ptr addrspace(2) %12, align 16, !tbaa !26, !alias.scope !38, !noalias !39
  %14 = fmul fast <4 x float> %13, <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>
  %15 = getelementptr inbounds float, ptr addrspace(2) %5, i64 %8
  %16 = load float, ptr addrspace(2) %15, align 4, !tbaa !40, !alias.scope !42, !noalias !43
  %17 = tail call fast float @air.fast_fmax.f32(float %16, float 2.500000e-01) #2
  %18 = fdiv fast float 5.000000e+00, %17
  %19 = getelementptr inbounds <2 x float>, ptr addrspace(1) %0, i64 %8
  store <2 x float> %11, ptr addrspace(1) %19, align 8, !tbaa !26, !alias.scope !44, !noalias !45
  %20 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %8
  store <4 x float> %14, ptr addrspace(1) %20, align 16, !tbaa !26, !alias.scope !46, !noalias !47
  %21 = getelementptr inbounds float, ptr addrspace(1) %2, i64 %8
  store float %18, ptr addrspace(1) %21, align 4, !tbaa !40, !alias.scope !48, !noalias !49
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #1

attributes #0 = { mustprogress nofree nosync nounwind willreturn memory(argmem: write) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9}
!air.compile_options = !{!19, !20, !21}
!llvm.ident = !{!22}
!air.version = !{!23}
!air.language_version = !{!24}
!air.source_file_name = !{!25}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_fast_math_binary, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14, !15, !16, !17, !18}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"vectorOut"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"vector4Out"}
!14 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"scalarOut"}
!15 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"vectorIn"}
!16 = !{i32 4, !"air.buffer", !"air.location_index", i32 4, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"vector4In"}
!17 = !{i32 5, !"air.buffer", !"air.location_index", i32 5, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"scalarIn"}
!18 = !{i32 6, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!19 = !{!"air.compile.denorms_disable"}
!20 = !{!"air.compile.fast_math_enable"}
!21 = !{!"air.compile.framebuffer_fetch_enable"}
!22 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!23 = !{i32 2, i32 7, i32 0}
!24 = !{!"Metal", i32 3, i32 2, i32 0}
!25 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fast_math_binary.metal"}
!26 = !{!27, !27, i64 0}
!27 = !{!"omnipotent char", !28, i64 0}
!28 = !{!"Simple C++ TBAA"}
!29 = !{!30}
!30 = distinct !{!30, !31, !"air-alias-scope-arg(3)"}
!31 = distinct !{!31, !"air-alias-scopes(test_fast_math_binary)"}
!32 = !{!33, !34, !35, !36, !37}
!33 = distinct !{!33, !31, !"air-alias-scope-arg(0)"}
!34 = distinct !{!34, !31, !"air-alias-scope-arg(1)"}
!35 = distinct !{!35, !31, !"air-alias-scope-arg(2)"}
!36 = distinct !{!36, !31, !"air-alias-scope-arg(4)"}
!37 = distinct !{!37, !31, !"air-alias-scope-arg(5)"}
!38 = !{!36}
!39 = !{!33, !34, !35, !30, !37}
!40 = !{!41, !41, i64 0}
!41 = !{!"float", !27, i64 0}
!42 = !{!37}
!43 = !{!33, !34, !35, !30, !36}
!44 = !{!33}
!45 = !{!34, !35, !30, !36, !37}
!46 = !{!34}
!47 = !{!33, !35, !30, !36, !37}
!48 = !{!35}
!49 = !{!33, !34, !30, !36, !37}
