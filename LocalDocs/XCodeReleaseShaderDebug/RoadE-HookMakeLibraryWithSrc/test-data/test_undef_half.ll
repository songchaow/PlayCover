; ModuleID = '/tmp/test_undef_half.air'
source_filename = "test_undef_half.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_undef_contexts(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds float, ptr addrspace(1) %1, i64 %4
  %6 = load float, ptr addrspace(1) %5, align 4, !tbaa !32, !alias.scope !36, !noalias !39
  %7 = fcmp fast ogt float %6, 5.000000e-01
  %8 = insertelement <4 x float> <float poison, float 1.000000e+00, float 0.000000e+00, float 1.000000e+00>, float %6, i64 0
  %9 = select i1 %7, <4 x float> %8, <4 x float> undef
  %10 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %4
  store <4 x float> %9, ptr addrspace(1) %10, align 16, !tbaa !41, !alias.scope !39, !noalias !36
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_half_arithmetic(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds float, ptr addrspace(1) %1, i64 %4
  %6 = load float, ptr addrspace(1) %5, align 4, !tbaa !32, !alias.scope !42, !noalias !45
  %7 = fptrunc float %6 to half
  %8 = add i32 %2, 1
  %9 = zext i32 %8 to i64
  %10 = getelementptr inbounds float, ptr addrspace(1) %1, i64 %9
  %11 = load float, ptr addrspace(1) %10, align 4, !tbaa !32, !alias.scope !42, !noalias !45
  %12 = fptrunc float %11 to half
  %13 = fadd fast half %12, 0xH4000
  %14 = fmul fast half %13, %7
  %15 = getelementptr inbounds half, ptr addrspace(1) %0, i64 %4
  store half %14, ptr addrspace(1) %15, align 2, !tbaa !47, !alias.scope !45, !noalias !42
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: read)
define <4 x float> @test_half_vector(ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %0, <4 x float> noundef %1) local_unnamed_addr #1 {
  %3 = extractelement <4 x float> %1, i64 0
  %4 = tail call i32 @air.convert.u.i32.f.f32(float %3) #3
  %5 = zext i32 %4 to i64
  %6 = getelementptr inbounds <4 x half>, ptr addrspace(1) %0, i64 %5
  %7 = load <4 x half>, ptr addrspace(1) %6, align 8, !tbaa !41, !alias.scope !49
  %8 = extractelement <4 x half> %7, i64 0
  %9 = extractelement <4 x half> %7, i64 1
  %10 = fadd fast half %8, %9
  %11 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %7) #3
  %12 = fpext half %10 to float
  %13 = insertelement <4 x float> poison, float %12, i64 0
  %14 = shufflevector <4 x float> %13, <4 x float> poison, <4 x i32> zeroinitializer
  %15 = fmul fast <4 x float> %14, %11
  ret <4 x float> %15
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #2

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #2 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #3 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9, !15}
!air.fragment = !{!19}
!air.compile_options = !{!25, !26, !27}
!llvm.ident = !{!28}
!air.version = !{!29}
!air.language_version = !{!30}
!air.source_file_name = !{!31}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_undef_contexts, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"output"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"input"}
!14 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!15 = !{ptr @test_half_arithmetic, !10, !16}
!16 = !{!17, !18, !14}
!17 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 2, !"air.arg_type_align_size", i32 2, !"air.arg_type_name", !"half", !"air.arg_name", !"halfOut"}
!18 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"floatIn"}
!19 = !{ptr @test_half_vector, !20, !22}
!20 = !{!21}
!21 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!22 = !{!23, !24}
!23 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"half4", !"air.arg_name", !"input"}
!24 = !{i32 1, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"pos"}
!25 = !{!"air.compile.denorms_disable"}
!26 = !{!"air.compile.fast_math_enable"}
!27 = !{!"air.compile.framebuffer_fetch_enable"}
!28 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!29 = !{i32 2, i32 7, i32 0}
!30 = !{!"Metal", i32 3, i32 2, i32 0}
!31 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_undef_half.metal"}
!32 = !{!33, !33, i64 0}
!33 = !{!"float", !34, i64 0}
!34 = !{!"omnipotent char", !35, i64 0}
!35 = !{!"Simple C++ TBAA"}
!36 = !{!37}
!37 = distinct !{!37, !38, !"air-alias-scope-arg(1)"}
!38 = distinct !{!38, !"air-alias-scopes(test_undef_contexts)"}
!39 = !{!40}
!40 = distinct !{!40, !38, !"air-alias-scope-arg(0)"}
!41 = !{!34, !34, i64 0}
!42 = !{!43}
!43 = distinct !{!43, !44, !"air-alias-scope-arg(1)"}
!44 = distinct !{!44, !"air-alias-scopes(test_half_arithmetic)"}
!45 = !{!46}
!46 = distinct !{!46, !44, !"air-alias-scope-arg(0)"}
!47 = !{!48, !48, i64 0}
!48 = !{!"half", !34, i64 0}
!49 = !{!50}
!50 = distinct !{!50, !51, !"air-alias-scope-arg(0)"}
!51 = distinct !{!51, !"air-alias-scopes(test_half_vector)"}
