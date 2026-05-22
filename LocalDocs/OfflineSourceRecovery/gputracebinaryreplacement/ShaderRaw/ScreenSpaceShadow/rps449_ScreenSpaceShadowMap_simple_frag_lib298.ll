; ModuleID = '/tmp/lysk-verify/shadow/library_298.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct._DirectionalShadowBuffer_Type = type { [20 x <4 x float>], [20 x <4 x float>], [16 x <4 x float>], [5 x <4 x float>], [16 x half], <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, [4 x float], <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x float>, [4 x <4 x float>], <4 x float>, float, float, float, [5 x <4 x float>] }

; Function Attrs: convergent nounwind optsize
define <{ <4 x float> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(1376) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) %1, ptr addrspace(2) readonly captures(none) %2, ptr addrspace(1) %3, ptr addrspace(1) readonly captures(none) %4, <2 x float> %5) local_unnamed_addr #0 {
  %7 = tail call { <4 x half>, i8 } @air.gather_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %4, ptr addrspace(2) readonly captures(none) %2, <2 x float> %5, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #4, !alias.scope !25, !noalias !29
  %8 = extractvalue { <4 x half>, i8 } %7, 0
  %9 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %8) #3
  %10 = extractelement <4 x float> %9, i64 1
  %11 = extractelement <4 x float> %9, i64 0
  %12 = fadd fast float %10, %11
  %13 = extractelement <4 x float> %9, i64 2
  %14 = fadd fast float %12, %13
  %15 = extractelement <4 x float> %9, i64 3
  %16 = fadd fast float %14, %15
  %17 = fmul fast float %16, 2.500000e-01
  %18 = fcmp fast ogt float %16, 0x3FA47AE140000000
  %19 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %0, i64 0, i32 22
  %20 = load float, ptr addrspace(2) %19, align 4, !tbaa !31, !alias.scope !29, !noalias !25
  %21 = fcmp fast olt float %17, %20
  %22 = select i1 %21, i1 %18, i1 false
  br i1 %22, label %23, label %24

23:                                               ; preds = %6
  tail call void @air.discard_fragment() #2
  br label %24

24:                                               ; preds = %23, %6
  %25 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %3, ptr addrspace(2) readonly captures(none) %1, <2 x float> %5, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #1, !alias.scope !25, !noalias !29
  %26 = extractvalue { <4 x half>, i8 } %25, 0
  %27 = extractelement <4 x half> %26, i64 0
  %28 = fpext half %27 to float
  %29 = insertelement <4 x float> <float undef, float 1.000000e+00, float 1.000000e+00, float undef>, float %28, i64 3
  %30 = insertelement <4 x float> %29, float %17, i64 0
  %31 = insertvalue <{ <4 x float> }> undef, <4 x float> %30, 0
  ret <{ <4 x float> }> %31
}

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #1

; Function Attrs: nounwind
declare void @air.discard_fragment() local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #3

; Function Attrs: nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.gather_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i32, i32) local_unnamed_addr #4

attributes #0 = { convergent nounwind optsize "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="64" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { convergent nounwind memory(argmem: read) }
attributes #2 = { nounwind }
attributes #3 = { nounwind memory(none) }
attributes #4 = { nounwind memory(argmem: read) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!llvm.ident = !{!8}
!air.version = !{!9}
!air.language_version = !{!10}
!air.compile_options = !{!11, !12, !13}
!air.fragment = !{!14}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 1]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"air.max_device_buffers", i32 31}
!3 = !{i32 7, !"air.max_constant_buffers", i32 31}
!4 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!5 = !{i32 7, !"air.max_textures", i32 128}
!6 = !{i32 7, !"air.max_read_write_textures", i32 8}
!7 = !{i32 7, !"air.max_samplers", i32 16}
!8 = !{!"Apple metal version 32023.830 (metalfe-32023.830.2)"}
!9 = !{i32 2, i32 4, i32 0}
!10 = !{!"Metal", i32 2, i32 3, i32 0}
!11 = !{!"air.compile.denorms_disable"}
!12 = !{!"air.compile.fast_math_enable"}
!13 = !{!"air.compile.framebuffer_fetch_enable"}
!14 = !{ptr @xlatMtlMain, !15, !17}
!15 = !{!16}
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target0"}
!17 = !{!18, !20, !21, !22, !23, !24}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 1376, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 1376, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"_DirectionalShadowBuffer_Type", !"air.arg_name", !"_DirectionalShadowBuffer"}
!19 = !{i32 0, i32 16, i32 20, !"float4", !"hlslcc_mtx4x4_WorldToShadowArray", i32 320, i32 16, i32 20, !"float4", !"hlslcc_mtx4x4_ShadowToWorldArray", i32 640, i32 16, i32 16, !"float4", !"hlslcc_mtx4x4_ShadowInvProjArray", i32 896, i32 16, i32 5, !"float4", !"_ShadowCameraPosArray", i32 976, i32 2, i32 16, !"half", !"DitherFilters", i32 1008, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres0", i32 1024, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres1", i32 1040, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres2", i32 1056, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres3", i32 1072, i32 16, i32 0, !"float4", !"_DirShadowSplitSphereRadii", i32 1088, i32 16, i32 0, !"float4", !"_ShadowMapClipRanges", i32 1104, i32 16, i32 0, !"float4", !"_ShadowMapSplitDistances", i32 1120, i32 4, i32 4, !"float", !"_InvShadowMapSplitDistances", i32 1136, i32 8, i32 0, !"half4", !"_ShadowOffset0", i32 1144, i32 8, i32 0, !"half4", !"_ShadowOffset1", i32 1152, i32 8, i32 0, !"half4", !"_ShadowOffset2", i32 1160, i32 8, i32 0, !"half4", !"_ShadowOffset3", i32 1168, i32 8, i32 0, !"half4", !"_ShadowData", i32 1184, i32 16, i32 0, !"float4", !"_ShadowmapSize", i32 1200, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_AuroraShadowTransform", i32 1264, i32 16, i32 0, !"float4", !"_AuroraShadowCameraPos", i32 1280, i32 4, i32 0, !"float", !"BlurSize", i32 1284, i32 4, i32 0, !"float", !"_PenumbraBias", i32 1288, i32 4, i32 0, !"float", !"_AutoBiasScale", i32 1296, i32 16, i32 5, !"float4", !"_BiasRange"}
!20 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SSAOTexture"}
!21 = !{i32 2, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_PenumbraMask"}
!22 = !{i32 3, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SSAOTexture"}
!23 = !{i32 4, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_PenumbraMask"}
!24 = !{i32 5, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!25 = !{!26, !28}
!26 = distinct !{!26, !27, !"air-alias-scope-samplers"}
!27 = distinct !{!27, !"air-alias-scopes(xlatMtlMain)"}
!28 = distinct !{!28, !27, !"air-alias-scope-textures"}
!29 = !{!30}
!30 = distinct !{!30, !27, !"air-alias-scope-arg(0)"}
!31 = !{!32, !35, i64 1284}
!32 = !{!"_ZTS29_DirectionalShadowBuffer_Type", !33, i64 0, !33, i64 320, !33, i64 640, !33, i64 896, !33, i64 976, !33, i64 1008, !33, i64 1024, !33, i64 1040, !33, i64 1056, !33, i64 1072, !33, i64 1088, !33, i64 1104, !33, i64 1120, !33, i64 1136, !33, i64 1144, !33, i64 1152, !33, i64 1160, !33, i64 1168, !33, i64 1184, !33, i64 1200, !33, i64 1264, !35, i64 1280, !35, i64 1284, !35, i64 1288, !33, i64 1296}
!33 = !{!"omnipotent char", !34, i64 0}
!34 = !{!"Simple C++ TBAA"}
!35 = !{!"float", !33, i64 0}
