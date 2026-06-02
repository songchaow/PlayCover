; ModuleID = '/tmp/lysk-ssao-447v/library_292.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }

; Function Attrs: nounwind optsize memory(none)
define <{ <2 x float>, <4 x float> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %0, i32 %1, i32 %2) local_unnamed_addr #0 {
  %4 = sub i32 %1, %2
  %5 = and i32 %4, 2
  %6 = tail call fast float @air.convert.f.f32.u.i32(i32 %5) #1
  %7 = insertelement <3 x float> undef, float %6, i64 1
  %8 = fsub fast float 1.000000e+00, %6
  %9 = insertelement <3 x float> %7, float %8, i64 2
  %10 = shl i32 %4, 1
  %11 = and i32 %10, 2
  %12 = tail call fast float @air.convert.f.f32.u.i32(i32 %11) #1
  %13 = insertelement <3 x float> %9, float %12, i64 0
  %14 = shufflevector <3 x float> %13, <3 x float> undef, <2 x i32> <i32 0, i32 2>
  %15 = shufflevector <3 x float> %13, <3 x float> undef, <2 x i32> <i32 0, i32 1>
  %16 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %15, <2 x float> splat (float 2.000000e+00), <2 x float> splat (float -1.000000e+00)) #1
  %17 = shufflevector <2 x float> %16, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 poison, i32 poison>
  %18 = extractelement <2 x float> %16, i64 1
  %19 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 10
  %20 = load <4 x float>, ptr addrspace(2) %19, align 16, !alias.scope !23
  %21 = extractelement <4 x float> %20, i64 0
  %22 = fsub fast float -0.000000e+00, %18
  %23 = fmul fast float %21, %22
  %24 = insertelement <4 x float> %17, float %23, i64 1
  %25 = shufflevector <4 x float> %24, <4 x float> <float 0.000000e+00, float 1.000000e+00, float undef, float undef>, <4 x i32> <i32 0, i32 1, i32 4, i32 5>
  %26 = insertvalue <{ <2 x float>, <4 x float> }> undef, <2 x float> %14, 0
  %27 = insertvalue <{ <2 x float>, <4 x float> }> %26, <4 x float> %25, 1
  ret <{ <2 x float>, <4 x float> }> %27
}

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #1

attributes #0 = { nounwind optsize memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="64" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!llvm.ident = !{!8}
!air.version = !{!9}
!air.language_version = !{!10}
!air.compile_options = !{!11, !12, !13}
!air.vertex = !{!14}

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
!14 = !{ptr @xlatMtlMain, !15, !18}
!15 = !{!16, !17}
!16 = !{!"air.vertex_output", !"user(TEXCOORD0)", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!17 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"mtl_Position"}
!18 = !{!19, !21, !22}
!19 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !20, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!20 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!21 = !{i32 1, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_VertexID"}
!22 = !{i32 2, !"air.base_vertex", !"air.arg_type_name", !"uint", !"air.arg_name", !"mtl_BaseVertex"}
!23 = !{!24}
!24 = distinct !{!24, !25, !"air-alias-scope-arg(0)"}
!25 = distinct !{!25, !"air-alias-scopes(xlatMtlMain)"}
