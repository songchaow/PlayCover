; ModuleID = '/tmp/lysk-ssao-448/library_296.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.cb_SSAOBlur_Type = type { <2 x float>, <4 x float>, float, [12 x i8] }

@__air_sampler_state = internal addrspace(2) constant i64 -9188470239253747127, align 8

; Function Attrs: convergent nounwind optsize memory(read)
define <{ <4 x half> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(48) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) %1, ptr addrspace(1) %2, <2 x float> %3) local_unnamed_addr #0 {
  %5 = getelementptr inbounds %struct.cb_SSAOBlur_Type, ptr addrspace(2) %0, i64 0, i32 0
  %6 = load <2 x float>, ptr addrspace(2) %5, align 16, !alias.scope !24, !noalias !27
  %7 = shufflevector <2 x float> %6, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %8 = shufflevector <2 x float> %3, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %9 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %7, <4 x float> <float -1.500000e+00, float -1.500000e+00, float -1.500000e+00, float 1.500000e+00>, <4 x float> %8) #1
  %10 = shufflevector <4 x float> %9, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %11 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %10, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %12 = extractvalue { <4 x half>, i8 } %11, 0
  %13 = extractelement <4 x half> %12, i64 0
  %14 = fpext half %13 to float
  %15 = insertelement <4 x float> undef, float %14, i64 0
  %16 = shufflevector <4 x float> %9, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %17 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %16, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %18 = extractvalue { <4 x half>, i8 } %17, 0
  %19 = extractelement <4 x half> %18, i64 0
  %20 = fpext half %19 to float
  %21 = insertelement <4 x float> %15, float %20, i64 1
  %22 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %7, <4 x float> <float 1.500000e+00, float -1.500000e+00, float 1.500000e+00, float 1.500000e+00>, <4 x float> %8) #1
  %23 = shufflevector <4 x float> %22, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %24 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %23, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %25 = extractvalue { <4 x half>, i8 } %24, 0
  %26 = extractelement <4 x half> %25, i64 0
  %27 = fpext half %26 to float
  %28 = insertelement <4 x float> %21, float %27, i64 2
  %29 = shufflevector <4 x float> %22, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %30 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %29, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %31 = extractvalue { <4 x half>, i8 } %30, 0
  %32 = extractelement <4 x half> %31, i64 0
  %33 = fpext half %32 to float
  %34 = insertelement <4 x float> %28, float %33, i64 3
  %35 = tail call fast float @air.dot.v4f32(<4 x float> %34, <4 x float> splat (float 0x3FC47AE140000000)) #1
  %36 = fptrunc float %35 to half
  %37 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %3, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !24
  %38 = extractvalue { <4 x half>, i8 } %37, 0
  %39 = extractelement <4 x half> %38, i64 0
  %40 = tail call fast half @air.fma.f16(half %39, half 0xH291F, half %36) #1
  %41 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %7, <4 x float> <float -1.500000e+00, float -0.000000e+00, float 1.500000e+00, float -0.000000e+00>, <4 x float> %8) #1
  %42 = shufflevector <4 x float> %41, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %43 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %42, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %44 = extractvalue { <4 x half>, i8 } %43, 0
  %45 = extractelement <4 x half> %44, i64 0
  %46 = fpext half %45 to float
  %47 = insertelement <4 x float> undef, float %46, i64 0
  %48 = shufflevector <4 x float> %41, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %49 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %48, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %50 = extractvalue { <4 x half>, i8 } %49, 0
  %51 = extractelement <4 x half> %50, i64 0
  %52 = fpext half %51 to float
  %53 = insertelement <4 x float> %47, float %52, i64 1
  %54 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %7, <4 x float> <float -0.000000e+00, float -1.500000e+00, float -0.000000e+00, float 1.500000e+00>, <4 x float> %8) #1
  %55 = shufflevector <4 x float> %54, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %56 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %55, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %57 = extractvalue { <4 x half>, i8 } %56, 0
  %58 = extractelement <4 x half> %57, i64 0
  %59 = fpext half %58 to float
  %60 = insertelement <4 x float> %53, float %59, i64 2
  %61 = shufflevector <4 x float> %54, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %62 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) @__air_sampler_state, <2 x float> %61, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %63 = extractvalue { <4 x half>, i8 } %62, 0
  %64 = extractelement <4 x half> %63, i64 0
  %65 = fpext half %64 to float
  %66 = insertelement <4 x float> %60, float %65, i64 3
  %67 = tail call fast float @air.dot.v4f32(<4 x float> %66, <4 x float> splat (float 0x3FB47AE140000000)) #1
  %68 = fptrunc float %67 to half
  %69 = fadd fast half %40, %68
  %70 = insertelement <4 x half> undef, half %69, i64 0
  %71 = shufflevector <4 x half> %70, <4 x half> <half 0xH0000, half 0xH0000, half 0xH0000, half undef>, <4 x i32> <i32 0, i32 4, i32 5, i32 6>
  %72 = insertvalue <{ <4 x half> }> undef, <4 x half> %71, 0
  ret <{ <4 x half> }> %72
}

; Function Attrs: nounwind memory(none)
declare float @air.dot.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

attributes #0 = { convergent nounwind optsize memory(read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }
attributes #2 = { convergent nounwind memory(argmem: read) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!llvm.ident = !{!8}
!air.version = !{!9}
!air.language_version = !{!10}
!air.compile_options = !{!11, !12, !13}
!air.fragment = !{!14}
!air.sampler_states = !{!23}

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
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_TARGET0"}
!17 = !{!18, !20, !21, !22}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 48, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 48, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"cb_SSAOBlur_Type", !"air.arg_name", !"cb_SSAOBlur"}
!19 = !{i32 0, i32 8, i32 0, !"float2", !"_SSAO_PixelOffset", i32 16, i32 16, i32 0, !"float4", !"_SSAO_SampleParams", i32 32, i32 4, i32 0, !"float", !"_SSAO_Sharpness"}
!20 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_HalfAOAndDepthTexture"}
!21 = !{i32 2, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_HalfAOAndDepthTexture"}
!22 = !{i32 3, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!23 = !{!"air.sampler_state", ptr addrspace(2) @__air_sampler_state}
!24 = !{!25}
!25 = distinct !{!25, !26, !"air-alias-scope-arg(0)"}
!26 = distinct !{!26, !"air-alias-scopes(xlatMtlMain)"}
!27 = !{!28, !29}
!28 = distinct !{!28, !26, !"air-alias-scope-samplers"}
!29 = distinct !{!29, !26, !"air-alias-scope-textures"}
