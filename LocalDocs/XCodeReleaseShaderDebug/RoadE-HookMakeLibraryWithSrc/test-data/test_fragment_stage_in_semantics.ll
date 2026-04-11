; ModuleID = 'test_fragment_stage_in_semantics'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios11.0.0"

%struct.FGlobals_Type = type { <4 x float> }

; Function Attrs: convergent nounwind memory(read)
define <{ <4 x float>, <4 x half>, float }> @xlatMtlMain(ptr addrspace(2) noalias nocapture readonly dereferenceable(16) %0, ptr addrspace(2) nocapture readonly %1, ptr addrspace(2) nocapture readonly %2, ptr addrspace(1) %3, ptr addrspace(1) %4, <2 x float> %5, <4 x float> %6, <4 x float> %7) local_unnamed_addr #0 {
  %9 = shufflevector <2 x float> %5, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %10 = fadd fast <4 x float> %9, %6
  %11 = shufflevector <4 x float> %10, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %12 = tail call fast <4 x float> @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %3, ptr addrspace(2) nocapture readonly %1, <2 x float> %11, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, i32 0) #1
  %13 = extractelement <4 x float> %12, i64 0
  %14 = shufflevector <4 x float> %10, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %15 = tail call fast <4 x float> @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %3, ptr addrspace(2) nocapture readonly %1, <2 x float> %14, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, i32 0) #1
  %16 = extractelement <4 x float> %15, i64 0
  %17 = shufflevector <4 x float> %15, <4 x float> undef, <3 x i32> <i32 0, i32 poison, i32 poison>
  %18 = fcmp fast olt float %16, %13
  %19 = shufflevector <2 x float> %14, <2 x float> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %20 = shufflevector <3 x float> %17, <3 x float> %19, <3 x i32> <i32 0, i32 3, i32 4>
  %21 = shufflevector <4 x float> %12, <4 x float> %10, <4 x i32> <i32 0, i32 4, i32 5, i32 poison>
  %22 = shufflevector <4 x float> %21, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %23 = select i1 %18, <3 x float> %20, <3 x float> %22
  %24 = shufflevector <2 x float> %5, <2 x float> undef, <4 x i32> <i32 0, i32 0, i32 1, i32 1>
  %25 = shufflevector <4 x float> %7, <4 x float> undef, <4 x i32> <i32 0, i32 2, i32 3, i32 1>
  %26 = fadd fast <4 x float> %25, %24
  %27 = shufflevector <4 x float> %26, <4 x float> undef, <2 x i32> <i32 0, i32 3>
  %28 = tail call fast <4 x float> @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %3, ptr addrspace(2) nocapture readonly %1, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, i32 0) #1
  %29 = extractelement <4 x float> %28, i64 0
  %30 = shufflevector <4 x float> %28, <4 x float> undef, <3 x i32> <i32 0, i32 poison, i32 poison>
  %31 = extractelement <3 x float> %23, i32 0
  %32 = fcmp fast olt float %29, %31
  %33 = shufflevector <2 x float> %27, <2 x float> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %34 = shufflevector <3 x float> %30, <3 x float> %33, <3 x i32> <i32 0, i32 3, i32 4>
  %35 = select i1 %32, <3 x float> %34, <3 x float> %23
  %36 = shufflevector <4 x float> %26, <4 x float> undef, <2 x i32> <i32 1, i32 2>
  %37 = tail call fast <4 x float> @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %3, ptr addrspace(2) nocapture readonly %1, <2 x float> %36, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, i32 0) #1
  %38 = extractelement <4 x float> %37, i64 0
  %39 = shufflevector <4 x float> %26, <4 x float> %37, <4 x i32> <i32 4, i32 1, i32 2, i32 poison>
  %40 = extractelement <3 x float> %35, i32 0
  %41 = fcmp fast olt float %38, %40
  %42 = shufflevector <4 x float> %39, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %43 = select i1 %41, <3 x float> %42, <3 x float> %35
  %44 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 0
  %45 = load <4 x float>, ptr addrspace(2) %44, align 16
  %46 = extractelement <4 x float> %45, i64 0
  %47 = extractelement <3 x float> %43, i32 0
  %48 = extractelement <4 x float> %45, i64 1
  %49 = tail call fast float @air.fma.f32(float %46, float %47, float %48) #2
  %50 = insertelement <4 x float> undef, float %49, i32 0
  %51 = fdiv fast <4 x float> <float 1.000000e+00, float undef, float undef, float undef>, %50
  %52 = shufflevector <4 x float> %51, <4 x float> undef, <4 x i32> zeroinitializer
  %53 = shufflevector <3 x float> %43, <3 x float> undef, <2 x i32> <i32 1, i32 2>
  %54 = tail call fast <4 x half> @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %4, ptr addrspace(2) nocapture readonly %2, <2 x float> %53, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, i32 0) #1
  %55 = insertvalue <{ <4 x float>, <4 x half>, float }> undef, <4 x float> %52, 0
  %56 = insertvalue <{ <4 x float>, <4 x half>, float }> %55, <4 x half> %54, 1
  %57 = insertvalue <{ <4 x float>, <4 x half>, float }> %56, float %47, 2
  ret <{ <4 x float>, <4 x half>, float }> %57
}

; Function Attrs: convergent nounwind memory(argmem: read)
declare <4 x half> @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, i32) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #2

; Function Attrs: convergent nounwind memory(argmem: read)
declare <4 x float> @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, i32) local_unnamed_addr #1

attributes #0 = { convergent nounwind memory(read) "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "frame-pointer"="all" "less-precise-fpmad"="false" "no-infs-fp-math"="true" "no-jump-tables"="false" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" "use-soft-float"="false" }
attributes #1 = { convergent nounwind memory(argmem: read) }
attributes #2 = { nounwind memory(none) }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}
!air.version = !{!2}
!air.language_version = !{!3}
!air.compile_options = !{!4, !5, !6}
!air.fragment = !{!7}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"Apple metal version 31001.660 (metalfe-31001.660.7-windows)"}
!2 = !{i32 2, i32 0, i32 0}
!3 = !{!"Metal", i32 2, i32 0, i32 0}
!4 = !{!"air.compile.denorms_disable"}
!5 = !{!"air.compile.fast_math_enable"}
!6 = !{!"air.compile.framebuffer_fetch_enable"}
!7 = !{ptr @xlatMtlMain, !8, !12}
!8 = !{!9, !10, !11}
!9 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target0"}
!10 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_Target1"}
!11 = !{!"air.depth", !"air.depth_qualifier", !"air.any", !"air.arg_type_name", !"float", !"air.arg_name", !"mtl_Depth"}
!12 = !{!13, !15, !16, !17, !18, !19, !20, !21}
!13 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !14, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"FGlobals_Type", !"air.arg_name", !"FGlobals"}
!14 = !{i32 0, i32 16, i32 0, !"float4", !"_ZBufferParams"}
!15 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraDepthTexture"}
!16 = !{i32 2, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraNormalsTexture"}
!17 = !{i32 3, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_CameraDepthTexture"}
!18 = !{i32 4, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_CameraNormalsTexture"}
!19 = !{i32 5, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!20 = !{i32 6, !"air.fragment_input", !"user(TEXCOORD1)", !"air.flat", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD1"}
!21 = !{i32 7, !"air.fragment_input", !"user(TEXCOORD2)", !"air.flat", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD2"}
