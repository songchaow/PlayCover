; ModuleID = '/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.air'
source_filename = "/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_scalar_casts(ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %0, ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %1, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %2, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %3, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %4, i32 noundef %5) local_unnamed_addr #0 {
  %7 = zext i32 %5 to i64
  %8 = getelementptr inbounds i32, ptr addrspace(1) %2, i64 %7
  %9 = load i32, ptr addrspace(1) %8, align 4, !tbaa !32, !alias.scope !36, !noalias !39
  %10 = and i32 %9, 1023
  %11 = getelementptr inbounds i32, ptr addrspace(1) %3, i64 %7
  %12 = load i32, ptr addrspace(1) %11, align 4, !tbaa !32, !alias.scope !44, !noalias !45
  %13 = srem i32 %12, 257
  %14 = getelementptr inbounds float, ptr addrspace(1) %4, i64 %7
  %15 = load float, ptr addrspace(1) %14, align 4, !tbaa !46, !alias.scope !48, !noalias !49
  %16 = fmul fast float %15, 8.000000e+00
  %17 = tail call fast float @air.convert.f.f32.u.i32(i32 %10) #3
  %18 = tail call fast float @air.convert.f.f32.s.i32(i32 %13) #3
  %19 = fadd fast float %16, 1.600000e+01
  %20 = tail call i32 @air.convert.u.i32.f.f32(float %19) #3
  %21 = fadd fast float %16, -7.000000e+00
  %22 = tail call i32 @air.convert.s.i32.f.f32(float %21) #3
  %23 = fadd fast float %18, %17
  %24 = tail call fast float @air.convert.f.f32.u.i32(i32 %20) #3
  %25 = fadd fast float %23, %24
  %26 = tail call fast float @air.convert.f.f32.s.i32(i32 %22) #3
  %27 = fadd fast float %25, %26
  %28 = getelementptr inbounds float, ptr addrspace(1) %0, i64 %7
  store float %27, ptr addrspace(1) %28, align 4, !tbaa !46, !alias.scope !50, !noalias !51
  %29 = add nsw i32 %22, %20
  %30 = getelementptr inbounds i32, ptr addrspace(1) %1, i64 %7
  store i32 %29, ptr addrspace(1) %30, align 4, !tbaa !32, !alias.scope !52, !noalias !53
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.s.i32(i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_vector_casts(ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %0, ptr addrspace(1) nocapture noundef writeonly "air-buffer-no-alias" %1, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %2, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %3, ptr addrspace(1) nocapture noundef readonly "air-buffer-no-alias" %4, i32 noundef %5) local_unnamed_addr #2 {
  %7 = zext i32 %5 to i64
  %8 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %2, i64 %7
  %9 = load <4 x i32>, ptr addrspace(1) %8, align 16, !tbaa !54, !alias.scope !55, !noalias !58
  %10 = and <4 x i32> %9, <i32 255, i32 511, i32 1023, i32 2047>
  %11 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %3, i64 %7
  %12 = load <4 x i32>, ptr addrspace(1) %11, align 16, !tbaa !54, !alias.scope !63, !noalias !64
  %13 = srem <4 x i32> %12, <i32 17, i32 31, i32 63, i32 127>
  %14 = getelementptr inbounds <4 x float>, ptr addrspace(1) %4, i64 %7
  %15 = load <4 x float>, ptr addrspace(1) %14, align 16, !tbaa !54, !alias.scope !65, !noalias !66
  %16 = fmul fast <4 x float> %15, <float 4.000000e+00, float 4.000000e+00, float 4.000000e+00, float 4.000000e+00>
  %17 = fadd fast <4 x float> %16, <float 8.000000e+00, float 8.000000e+00, float 8.000000e+00, float 8.000000e+00>
  %18 = tail call fast <4 x float> @air.convert.f.v4f32.u.v4i32(<4 x i32> %10) #3
  %19 = tail call fast <4 x float> @air.convert.f.v4f32.s.v4i32(<4 x i32> %13) #3
  %20 = tail call <4 x i32> @air.convert.u.v4i32.f.v4f32(<4 x float> %17) #3
  %21 = fadd fast <4 x float> %16, <float 5.000000e+00, float 5.000000e+00, float 5.000000e+00, float 5.000000e+00>
  %22 = tail call <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float> %21) #3
  %23 = fadd fast <4 x float> %19, %18
  %24 = tail call fast <4 x float> @air.convert.f.v4f32.u.v4i32(<4 x i32> %20) #3
  %25 = fadd fast <4 x float> %23, %24
  %26 = tail call fast <4 x float> @air.convert.f.v4f32.s.v4i32(<4 x i32> %22) #3
  %27 = fadd fast <4 x float> %25, %26
  %28 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %7
  store <4 x float> %27, ptr addrspace(1) %28, align 16, !tbaa !54, !alias.scope !67, !noalias !68
  %29 = tail call <4 x i32> @air.max.s.v4i32(<4 x i32> %22, <4 x i32> zeroinitializer) #3
  %30 = add <4 x i32> %29, %20
  %31 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %1, i64 %7
  store <4 x i32> %30, ptr addrspace(1) %31, align 16, !tbaa !54, !alias.scope !69, !noalias !70
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.u.v4i32(<4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.s.v4i32(<4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.convert.u.v4i32.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.max.s.v4i32(<4 x i32>, <4 x i32>) local_unnamed_addr #1

attributes #0 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #3 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9, !18}
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
!9 = !{ptr @test_scalar_casts, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14, !15, !16, !17}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"floatOut"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"intOut"}
!14 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"uintIn"}
!15 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"intIn"}
!16 = !{i32 4, !"air.buffer", !"air.location_index", i32 4, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"floatIn"}
!17 = !{i32 5, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!18 = !{ptr @test_vector_casts, !10, !19}
!19 = !{!20, !21, !22, !23, !24, !17}
!20 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"floatOut"}
!21 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"uint4", !"air.arg_name", !"uintOut"}
!22 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"uint4", !"air.arg_name", !"uintIn"}
!23 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"int4", !"air.arg_name", !"intIn"}
!24 = !{i32 4, !"air.buffer", !"air.location_index", i32 4, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"floatIn"}
!25 = !{!"air.compile.denorms_disable"}
!26 = !{!"air.compile.fast_math_enable"}
!27 = !{!"air.compile.framebuffer_fetch_enable"}
!28 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!29 = !{i32 2, i32 7, i32 0}
!30 = !{!"Metal", i32 3, i32 2, i32 0}
!31 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.metal"}
!32 = !{!33, !33, i64 0}
!33 = !{!"int", !34, i64 0}
!34 = !{!"omnipotent char", !35, i64 0}
!35 = !{!"Simple C++ TBAA"}
!36 = !{!37}
!37 = distinct !{!37, !38, !"air-alias-scope-arg(2)"}
!38 = distinct !{!38, !"air-alias-scopes(test_scalar_casts)"}
!39 = !{!40, !41, !42, !43}
!40 = distinct !{!40, !38, !"air-alias-scope-arg(0)"}
!41 = distinct !{!41, !38, !"air-alias-scope-arg(1)"}
!42 = distinct !{!42, !38, !"air-alias-scope-arg(3)"}
!43 = distinct !{!43, !38, !"air-alias-scope-arg(4)"}
!44 = !{!42}
!45 = !{!40, !41, !37, !43}
!46 = !{!47, !47, i64 0}
!47 = !{!"float", !34, i64 0}
!48 = !{!43}
!49 = !{!40, !41, !37, !42}
!50 = !{!40}
!51 = !{!41, !37, !42, !43}
!52 = !{!41}
!53 = !{!40, !37, !42, !43}
!54 = !{!34, !34, i64 0}
!55 = !{!56}
!56 = distinct !{!56, !57, !"air-alias-scope-arg(2)"}
!57 = distinct !{!57, !"air-alias-scopes(test_vector_casts)"}
!58 = !{!59, !60, !61, !62}
!59 = distinct !{!59, !57, !"air-alias-scope-arg(0)"}
!60 = distinct !{!60, !57, !"air-alias-scope-arg(1)"}
!61 = distinct !{!61, !57, !"air-alias-scope-arg(3)"}
!62 = distinct !{!62, !57, !"air-alias-scope-arg(4)"}
!63 = !{!61}
!64 = !{!59, !60, !56, !62}
!65 = !{!62}
!66 = !{!59, !60, !56, !61}
!67 = !{!59}
!68 = !{!60, !56, !61, !62}
!69 = !{!60}
!70 = !{!59, !56, !61, !62}
