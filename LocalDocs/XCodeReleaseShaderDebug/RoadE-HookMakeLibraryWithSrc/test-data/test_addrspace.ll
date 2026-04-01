; ModuleID = '/tmp/playtools-ir-test/test_addrspace.air'
source_filename = "test_addrspace.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

%struct.Uniforms = type <{ %"struct.metal::matrix", %"struct.metal::matrix", float, [12 x i8] }>
%"struct.metal::matrix" = type { [4 x <4 x float>] }

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read)
define <{ <4 x float>, <2 x float>, <3 x float> }> @test_vertex(<4 x float> %0, <2 x float> %1, <3 x float> %2, ptr addrspace(2) nocapture readonly align 16 dereferenceable(132) "air-buffer-no-alias" %3, ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %4, i32 %5) local_unnamed_addr #0 {
  %7 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 0, i32 0, i64 0
  %8 = load <4 x float>, ptr addrspace(2) %7, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %9 = shufflevector <4 x float> %0, <4 x float> poison, <4 x i32> zeroinitializer
  %10 = fmul fast <4 x float> %8, %9
  %11 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 0, i32 0, i64 1
  %12 = load <4 x float>, ptr addrspace(2) %11, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %13 = shufflevector <4 x float> %0, <4 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %14 = fmul fast <4 x float> %12, %13
  %15 = fadd fast <4 x float> %14, %10
  %16 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 0, i32 0, i64 2
  %17 = load <4 x float>, ptr addrspace(2) %16, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %18 = shufflevector <4 x float> %0, <4 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %19 = fmul fast <4 x float> %17, %18
  %20 = fadd fast <4 x float> %15, %19
  %21 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 0, i32 0, i64 3
  %22 = load <4 x float>, ptr addrspace(2) %21, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %23 = shufflevector <4 x float> %0, <4 x float> undef, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %24 = fmul fast <4 x float> %22, %23
  %25 = fadd fast <4 x float> %20, %24
  %26 = zext i32 %5 to i64
  %27 = getelementptr inbounds <4 x float>, ptr addrspace(1) %4, i64 %26
  %28 = load <4 x float>, ptr addrspace(1) %27, align 16, !tbaa !64, !alias.scope !70, !noalias !67
  %29 = fadd fast <4 x float> %25, %28
  %30 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 1, i32 0, i64 0
  %31 = load <4 x float>, ptr addrspace(2) %30, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %32 = shufflevector <3 x float> %2, <3 x float> undef, <4 x i32> <i32 0, i32 0, i32 0, i32 poison>
  %33 = fmul fast <4 x float> %31, %32
  %34 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 1, i32 0, i64 1
  %35 = load <4 x float>, ptr addrspace(2) %34, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %36 = shufflevector <3 x float> %2, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 poison>
  %37 = fmul fast <4 x float> %35, %36
  %38 = fadd fast <4 x float> %37, %33
  %39 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 1, i32 0, i64 2
  %40 = load <4 x float>, ptr addrspace(2) %39, align 16, !tbaa !64, !alias.scope !67, !noalias !70
  %41 = shufflevector <3 x float> %2, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 poison>
  %42 = fmul fast <4 x float> %40, %41
  %43 = fadd fast <4 x float> %38, %42
  %44 = shufflevector <4 x float> %43, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %45 = insertvalue <{ <4 x float>, <2 x float>, <3 x float> }> undef, <4 x float> %29, 0
  %46 = insertvalue <{ <4 x float>, <2 x float>, <3 x float> }> %45, <2 x float> %1, 1
  %47 = insertvalue <{ <4 x float>, <2 x float>, <3 x float> }> %46, <3 x float> %44, 2
  ret <{ <4 x float>, <2 x float>, <3 x float> }> %47
}

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
define <4 x float> @test_fragment(<4 x float> %0, <2 x float> %1, <3 x float> %2, ptr addrspace(2) nocapture readonly align 16 dereferenceable(132) "air-buffer-no-alias" %3, ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %4, ptr addrspace(1) nocapture readonly %5, ptr addrspace(2) nocapture readonly %6) local_unnamed_addr #1 {
  %8 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %5, ptr addrspace(2) nocapture readonly %6, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #7, !alias.scope !72, !noalias !76
  %9 = extractvalue { <4 x float>, i8 } %8, 0
  %10 = load float, ptr addrspace(1) %4, align 4, !tbaa !79, !alias.scope !81, !noalias !82
  %11 = insertelement <3 x float> poison, float %10, i64 0
  %12 = shufflevector <3 x float> %11, <3 x float> poison, <3 x i32> zeroinitializer
  %13 = shufflevector <4 x float> %9, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %14 = fmul fast <3 x float> %12, %13
  %15 = shufflevector <3 x float> %14, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %16 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %3, i64 0, i32 2
  %17 = load float, ptr addrspace(2) %16, align 16, !tbaa !83, !alias.scope !86, !noalias !87
  %18 = extractelement <4 x float> %9, i64 3
  %19 = fmul fast float %18, %17
  %20 = insertelement <4 x float> %15, float %19, i64 3
  ret <4 x float> %20
}

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_kernel(ptr addrspace(1) nocapture writeonly "air-buffer-no-alias" %0, ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %1, ptr addrspace(2) nocapture readonly align 4 dereferenceable(4) "air-buffer-no-alias" %2, ptr addrspace(3) nocapture "air-buffer-no-alias" %3, i32 %4, i32 %5, i32 %6) local_unnamed_addr #2 {
  %8 = load i32, ptr addrspace(2) %2, align 4, !tbaa !88, !alias.scope !90, !noalias !93
  %9 = icmp ugt i32 %8, %4
  br i1 %9, label %10, label %16

10:                                               ; preds = %7
  %11 = zext i32 %5 to i64
  %12 = getelementptr inbounds <4 x float>, ptr addrspace(3) %3, i64 %11
  %13 = zext i32 %4 to i64
  %14 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %13
  %15 = load <4 x float>, ptr addrspace(1) %14, align 16, !tbaa !64, !alias.scope !97, !noalias !98
  store <4 x float> %15, ptr addrspace(3) %12, align 16, !tbaa !64, !alias.scope !99, !noalias !100
  br label %16

16:                                               ; preds = %10, %7
  tail call void @air.wg.barrier(i32 2, i32 1) #8
  br i1 %9, label %17, label %24

17:                                               ; preds = %16
  %18 = zext i32 %4 to i64
  %19 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %18
  %20 = zext i32 %5 to i64
  %21 = getelementptr inbounds <4 x float>, ptr addrspace(3) %3, i64 %20
  %22 = load <4 x float>, ptr addrspace(3) %21, align 16, !tbaa !64, !alias.scope !99, !noalias !100
  %23 = fmul fast <4 x float> %22, <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>
  store <4 x float> %23, ptr addrspace(1) %19, align 16, !tbaa !64, !alias.scope !101, !noalias !102
  br label %24

24:                                               ; preds = %17, %16
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_types(ptr addrspace(1) nocapture writeonly "air-buffer-no-alias" %0, ptr addrspace(1) nocapture writeonly "air-buffer-no-alias" %1, ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %2, ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %3, ptr addrspace(2) nocapture readonly align 8 dereferenceable(8) "air-buffer-no-alias" %4, i32 %5) local_unnamed_addr #3 {
  %7 = zext i32 %5 to i64
  %8 = getelementptr inbounds <4 x half>, ptr addrspace(1) %2, i64 %7
  %9 = load <4 x half>, ptr addrspace(1) %8, align 8, !alias.scope !103, !noalias !106
  %10 = extractelement <4 x half> %9, i64 0
  %11 = fpext half %10 to float
  %12 = load <2 x float>, ptr addrspace(2) %4, align 8, !alias.scope !111, !noalias !112
  %13 = extractelement <2 x float> %12, i64 0
  %14 = fmul fast float %13, %11
  %15 = tail call i32 @air.convert.s.i32.f.f32(float %14) #9
  %16 = getelementptr inbounds i32, ptr addrspace(1) %0, i64 %7
  store i32 %15, ptr addrspace(1) %16, align 4, !tbaa !88, !alias.scope !113, !noalias !114
  %17 = getelementptr inbounds i8, ptr addrspace(1) %3, i64 %7
  %18 = load i8, ptr addrspace(1) %17, align 1, !tbaa !64, !alias.scope !115, !noalias !116
  %19 = zext i8 %18 to i16
  %20 = getelementptr inbounds i16, ptr addrspace(1) %1, i64 %7
  store i16 %19, ptr addrspace(1) %20, align 2, !tbaa !117, !alias.scope !119, !noalias !120
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #4

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read)
define <4 x float> @test_simple_vertex(ptr addrspace(1) nocapture readonly "air-buffer-no-alias" %0, ptr addrspace(2) nocapture readonly align 16 dereferenceable(64) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %4
  %6 = load <4 x float>, ptr addrspace(1) %5, align 16, !tbaa !64, !alias.scope !121, !noalias !124
  %7 = getelementptr inbounds %"struct.metal::matrix", ptr addrspace(2) %1, i64 0, i32 0, i64 0
  %8 = load <4 x float>, ptr addrspace(2) %7, align 16, !tbaa !64, !alias.scope !124, !noalias !121
  %9 = shufflevector <4 x float> %6, <4 x float> poison, <4 x i32> zeroinitializer
  %10 = fmul fast <4 x float> %8, %9
  %11 = getelementptr inbounds %"struct.metal::matrix", ptr addrspace(2) %1, i64 0, i32 0, i64 1
  %12 = load <4 x float>, ptr addrspace(2) %11, align 16, !tbaa !64, !alias.scope !124, !noalias !121
  %13 = shufflevector <4 x float> %6, <4 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %14 = fmul fast <4 x float> %12, %13
  %15 = fadd fast <4 x float> %14, %10
  %16 = getelementptr inbounds %"struct.metal::matrix", ptr addrspace(2) %1, i64 0, i32 0, i64 2
  %17 = load <4 x float>, ptr addrspace(2) %16, align 16, !tbaa !64, !alias.scope !124, !noalias !121
  %18 = shufflevector <4 x float> %6, <4 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %19 = fmul fast <4 x float> %17, %18
  %20 = fadd fast <4 x float> %15, %19
  %21 = getelementptr inbounds %"struct.metal::matrix", ptr addrspace(2) %1, i64 0, i32 0, i64 3
  %22 = load <4 x float>, ptr addrspace(2) %21, align 16, !tbaa !64, !alias.scope !124, !noalias !121
  %23 = shufflevector <4 x float> %6, <4 x float> undef, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %24 = fmul fast <4 x float> %22, %23
  %25 = fadd fast <4 x float> %20, %24
  ret <4 x float> %25
}

; Function Attrs: convergent mustprogress nounwind willreturn
declare void @air.wg.barrier(i32, i32) local_unnamed_addr #5

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #6

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #2 = { convergent mustprogress nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #3 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #4 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #5 = { convergent mustprogress nounwind willreturn }
attributes #6 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #7 = { convergent nounwind willreturn memory(argmem: read) }
attributes #8 = { convergent nounwind willreturn }
attributes #9 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.vertex = !{!9, !22}
!air.fragment = !{!29}
!air.kernel = !{!39, !49}
!air.compile_options = !{!57, !58, !59}
!llvm.ident = !{!60}
!air.version = !{!61}
!air.language_version = !{!62}
!air.source_file_name = !{!63}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_vertex, !10, !14}
!10 = !{!11, !12, !13}
!11 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!12 = !{!"air.vertex_output", !"generated(8texcoordDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!13 = !{!"air.vertex_output", !"generated(6normalDv3_f)", !"air.arg_type_name", !"float3", !"air.arg_name", !"normal"}
!14 = !{!15, !16, !17, !18, !20, !21}
!15 = !{i32 0, !"air.vertex_input", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!16 = !{i32 1, !"air.vertex_input", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!17 = !{i32 2, !"air.vertex_input", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"float3", !"air.arg_name", !"normal"}
!18 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !19, !"air.arg_type_size", i32 144, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
!19 = !{i32 0, i32 64, i32 0, !"float4x4", !"modelViewProjection", i32 64, i32 64, i32 0, !"float4x4", !"normalMatrix", i32 128, i32 4, i32 0, !"float", !"time"}
!20 = !{i32 4, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"positions"}
!21 = !{i32 5, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
!22 = !{ptr @test_simple_vertex, !23, !25}
!23 = !{!24}
!24 = !{!"air.position", !"air.arg_type_name", !"float4"}
!25 = !{!26, !27, !28}
!26 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"positions"}
!27 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 64, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 64, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4x4", !"air.arg_name", !"mvp"}
!28 = !{i32 2, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
!29 = !{ptr @test_fragment, !30, !32}
!30 = !{!31}
!31 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!32 = !{!33, !34, !35, !18, !36, !37, !38}
!33 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"position", !"air.arg_unused"}
!34 = !{i32 1, !"air.fragment_input", !"generated(8texcoordDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!35 = !{i32 2, !"air.fragment_input", !"generated(6normalDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"normal", !"air.arg_unused"}
!36 = !{i32 4, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"weights"}
!37 = !{i32 5, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"tex"}
!38 = !{i32 6, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"smp"}
!39 = !{ptr @test_kernel, !40, !41}
!40 = !{}
!41 = !{!42, !43, !44, !45, !46, !47, !48}
!42 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"output"}
!43 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"input"}
!44 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"count"}
!45 = !{i32 3, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 3, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"shared_data"}
!46 = !{i32 4, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!47 = !{i32 5, !"air.thread_position_in_threadgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"lid"}
!48 = !{i32 6, !"air.threadgroup_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid", !"air.arg_unused"}
!49 = !{ptr @test_types, !40, !50}
!50 = !{!51, !52, !53, !54, !55, !56}
!51 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"intBuf"}
!52 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 2, !"air.arg_type_align_size", i32 2, !"air.arg_type_name", !"short", !"air.arg_name", !"shortBuf"}
!53 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"half4", !"air.arg_name", !"halfBuf"}
!54 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 1, !"air.arg_type_align_size", i32 1, !"air.arg_type_name", !"uchar", !"air.arg_name", !"byteBuf"}
!55 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 8, !"air.location_index", i32 4, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"scale"}
!56 = !{i32 5, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!57 = !{!"air.compile.denorms_disable"}
!58 = !{!"air.compile.fast_math_enable"}
!59 = !{!"air.compile.framebuffer_fetch_enable"}
!60 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!61 = !{i32 2, i32 7, i32 0}
!62 = !{!"Metal", i32 2, i32 4, i32 0}
!63 = !{!"/private/tmp/playtools-ir-test/test_addrspace.metal"}
!64 = !{!65, !65, i64 0}
!65 = !{!"omnipotent char", !66, i64 0}
!66 = !{!"Simple C++ TBAA"}
!67 = !{!68}
!68 = distinct !{!68, !69, !"air-alias-scope-arg(3)"}
!69 = distinct !{!69, !"air-alias-scopes(test_vertex)"}
!70 = !{!71}
!71 = distinct !{!71, !69, !"air-alias-scope-arg(4)"}
!72 = !{!73, !75}
!73 = distinct !{!73, !74, !"air-alias-scope-textures"}
!74 = distinct !{!74, !"air-alias-scopes(test_fragment)"}
!75 = distinct !{!75, !74, !"air-alias-scope-samplers"}
!76 = !{!77, !78}
!77 = distinct !{!77, !74, !"air-alias-scope-arg(3)"}
!78 = distinct !{!78, !74, !"air-alias-scope-arg(4)"}
!79 = !{!80, !80, i64 0}
!80 = !{!"float", !65, i64 0}
!81 = !{!78}
!82 = !{!77, !73, !75}
!83 = !{!84, !80, i64 128}
!84 = !{!"_ZTS8Uniforms", !85, i64 0, !85, i64 64, !80, i64 128}
!85 = !{!"_ZTSN5metal6matrixIfLi4ELi4EvEE", !65, i64 0}
!86 = !{!77}
!87 = !{!78, !73, !75}
!88 = !{!89, !89, i64 0}
!89 = !{!"int", !65, i64 0}
!90 = !{!91}
!91 = distinct !{!91, !92, !"air-alias-scope-arg(2)"}
!92 = distinct !{!92, !"air-alias-scopes(test_kernel)"}
!93 = !{!94, !95, !96}
!94 = distinct !{!94, !92, !"air-alias-scope-arg(0)"}
!95 = distinct !{!95, !92, !"air-alias-scope-arg(1)"}
!96 = distinct !{!96, !92, !"air-alias-scope-arg(3)"}
!97 = !{!95}
!98 = !{!94, !91, !96}
!99 = !{!96}
!100 = !{!94, !95, !91}
!101 = !{!94}
!102 = !{!95, !91, !96}
!103 = !{!104}
!104 = distinct !{!104, !105, !"air-alias-scope-arg(2)"}
!105 = distinct !{!105, !"air-alias-scopes(test_types)"}
!106 = !{!107, !108, !109, !110}
!107 = distinct !{!107, !105, !"air-alias-scope-arg(0)"}
!108 = distinct !{!108, !105, !"air-alias-scope-arg(1)"}
!109 = distinct !{!109, !105, !"air-alias-scope-arg(3)"}
!110 = distinct !{!110, !105, !"air-alias-scope-arg(4)"}
!111 = !{!110}
!112 = !{!107, !108, !104, !109}
!113 = !{!107}
!114 = !{!108, !104, !109, !110}
!115 = !{!109}
!116 = !{!107, !108, !104, !110}
!117 = !{!118, !118, i64 0}
!118 = !{!"short", !65, i64 0}
!119 = !{!108}
!120 = !{!107, !104, !109, !110}
!121 = !{!122}
!122 = distinct !{!122, !123, !"air-alias-scope-arg(0)"}
!123 = distinct !{!123, !"air-alias-scopes(test_simple_vertex)"}
!124 = !{!125}
!125 = distinct !{!125, !123, !"air-alias-scope-arg(1)"}
