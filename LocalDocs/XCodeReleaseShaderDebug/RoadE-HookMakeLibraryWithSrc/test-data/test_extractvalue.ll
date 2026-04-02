; ModuleID = 'test_extractvalue.air'
source_filename = "test_extractvalue.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

%struct.Uniforms = type <{ %"struct.metal::matrix", float, [12 x i8] }>
%"struct.metal::matrix" = type { [4 x <4 x float>] }
%struct.Particle = type { <3 x float>, <3 x float>, float, [12 x i8] }

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
define <4 x float> @test_sample_extract(<4 x float> %0, <2 x float> %1, ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %3) local_unnamed_addr #0 {
  %5 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %3, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !41
  %6 = extractvalue { <4 x float>, i8 } %5, 0
  ret <4 x float> %6
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read)
define <{ <4 x float>, <2 x float> }> @test_vertex_struct(ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(2) noundef readonly align 16 captures(none) dereferenceable(68) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #1 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %5
  %7 = load <4 x float>, ptr addrspace(1) %6, align 16, !tbaa !45, !alias.scope !48, !noalias !51
  %8 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 0
  %9 = load <4 x float>, ptr addrspace(2) %8, align 16, !tbaa !45, !alias.scope !54, !noalias !55
  %10 = shufflevector <4 x float> %7, <4 x float> poison, <4 x i32> zeroinitializer
  %11 = fmul fast <4 x float> %9, %10
  %12 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 1
  %13 = load <4 x float>, ptr addrspace(2) %12, align 16, !tbaa !45, !alias.scope !54, !noalias !55
  %14 = shufflevector <4 x float> %7, <4 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %15 = fmul fast <4 x float> %13, %14
  %16 = fadd fast <4 x float> %15, %11
  %17 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 2
  %18 = load <4 x float>, ptr addrspace(2) %17, align 16, !tbaa !45, !alias.scope !54, !noalias !55
  %19 = shufflevector <4 x float> %7, <4 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %20 = fmul fast <4 x float> %18, %19
  %21 = fadd fast <4 x float> %16, %20
  %22 = getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 3
  %23 = load <4 x float>, ptr addrspace(2) %22, align 16, !tbaa !45, !alias.scope !54, !noalias !55
  %24 = shufflevector <4 x float> %7, <4 x float> undef, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %25 = fmul fast <4 x float> %23, %24
  %26 = fadd fast <4 x float> %21, %25
  %27 = getelementptr inbounds <2 x float>, ptr addrspace(1) %1, i64 %5
  %28 = load <2 x float>, ptr addrspace(1) %27, align 8, !tbaa !45, !alias.scope !56, !noalias !57
  %29 = insertvalue <{ <4 x float>, <2 x float> }> undef, <4 x float> %26, 0
  %30 = insertvalue <{ <4 x float>, <2 x float> }> %29, <2 x float> %28, 1
  ret <{ <4 x float>, <2 x float> }> %30
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_gep_struct(ptr addrspace(1) noundef captures(none) "air-buffer-no-alias" %0, ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(4) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #2 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds %struct.Particle, ptr addrspace(1) %0, i64 %4, i32 0
  %6 = load <3 x float>, ptr addrspace(1) %5, align 16, !tbaa !45, !alias.scope !58, !noalias !61
  %7 = getelementptr inbounds %struct.Particle, ptr addrspace(1) %0, i64 %4, i32 1
  %8 = load <3 x float>, ptr addrspace(1) %7, align 16, !tbaa !45, !alias.scope !58, !noalias !61
  %9 = load float, ptr addrspace(2) %1, align 4, !tbaa !63, !alias.scope !61, !noalias !58
  %10 = insertelement <3 x float> poison, float %9, i64 0
  %11 = shufflevector <3 x float> %10, <3 x float> poison, <3 x i32> zeroinitializer
  %12 = fmul fast <3 x float> %11, %8
  %13 = fadd fast <3 x float> %12, %6
  %14 = fmul fast float %9, 0x3F847AE140000000
  %15 = fsub fast float 1.000000e+00, %14
  %16 = insertelement <3 x float> poison, float %15, i64 0
  %17 = shufflevector <3 x float> %16, <3 x float> poison, <3 x i32> zeroinitializer
  %18 = fmul fast <3 x float> %17, %8
  store <3 x float> %13, ptr addrspace(1) %5, align 16, !tbaa !45, !alias.scope !58, !noalias !61
  store <3 x float> %18, ptr addrspace(1) %7, align 16, !tbaa !45, !alias.scope !58, !noalias !61
  ret void
}

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #3

attributes #0 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #3 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #4 = { convergent nounwind willreturn memory(argmem: read) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.fragment = !{!9}
!air.vertex = !{!17}
!air.kernel = !{!27}
!air.compile_options = !{!34, !35, !36}
!llvm.ident = !{!37}
!air.version = !{!38}
!air.language_version = !{!39}
!air.source_file_name = !{!40}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_sample_extract, !10, !12}
!10 = !{!11}
!11 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!12 = !{!13, !14, !15, !16}
!13 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"position", !"air.arg_unused"}
!14 = !{i32 1, !"air.fragment_input", !"generated(8texcoordDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!15 = !{i32 2, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"tex"}
!16 = !{i32 3, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"smp"}
!17 = !{ptr @test_vertex_struct, !18, !21}
!18 = !{!19, !20}
!19 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!20 = !{!"air.vertex_output", !"generated(8texcoordDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoord"}
!21 = !{!22, !23, !24, !26}
!22 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"positions"}
!23 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"texcoords"}
!24 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 80, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !25, !"air.arg_type_size", i32 80, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
!25 = !{i32 0, i32 64, i32 0, !"float4x4", !"modelViewProjection", i32 64, i32 4, i32 0, !"float", !"time"}
!26 = !{i32 3, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
!27 = !{ptr @test_gep_struct, !28, !29}
!28 = !{}
!29 = !{!30, !32, !33}
!30 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.struct_type_info", !31, !"air.arg_type_size", i32 48, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Particle", !"air.arg_name", !"particles"}
!31 = !{i32 0, i32 16, i32 0, !"float3", !"position", i32 16, i32 16, i32 0, !"float3", !"velocity", i32 32, i32 4, i32 0, !"float", !"mass"}
!32 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"dt"}
!33 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!34 = !{!"air.compile.denorms_disable"}
!35 = !{!"air.compile.fast_math_enable"}
!36 = !{!"air.compile.framebuffer_fetch_enable"}
!37 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!38 = !{i32 2, i32 7, i32 0}
!39 = !{!"Metal", i32 3, i32 2, i32 0}
!40 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_extractvalue.metal"}
!41 = !{!42, !44}
!42 = distinct !{!42, !43, !"air-alias-scope-textures"}
!43 = distinct !{!43, !"air-alias-scopes(test_sample_extract)"}
!44 = distinct !{!44, !43, !"air-alias-scope-samplers"}
!45 = !{!46, !46, i64 0}
!46 = !{!"omnipotent char", !47, i64 0}
!47 = !{!"Simple C++ TBAA"}
!48 = !{!49}
!49 = distinct !{!49, !50, !"air-alias-scope-arg(0)"}
!50 = distinct !{!50, !"air-alias-scopes(test_vertex_struct)"}
!51 = !{!52, !53}
!52 = distinct !{!52, !50, !"air-alias-scope-arg(1)"}
!53 = distinct !{!53, !50, !"air-alias-scope-arg(2)"}
!54 = !{!53}
!55 = !{!49, !52}
!56 = !{!52}
!57 = !{!49, !53}
!58 = !{!59}
!59 = distinct !{!59, !60, !"air-alias-scope-arg(0)"}
!60 = distinct !{!60, !"air-alias-scopes(test_gep_struct)"}
!61 = !{!62}
!62 = distinct !{!62, !60, !"air-alias-scope-arg(1)"}
!63 = !{!64, !64, i64 0}
!64 = !{!"float", !46, i64 0}
