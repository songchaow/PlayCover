; ModuleID = '/Users/songdogwang/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/7615CCD1E13E7FEE_6689/modules/cb4e668cb8007aedfae59bf8d24dab63110eab5801f5584d21d0509149443c67/module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.FGlobals_Type = type { <4 x half>, half, [25 x <4 x half>], i32 }

; Function Attrs: convergent nounwind optsize memory(read)
define <{ <4 x half> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(224) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) %1, ptr addrspace(2) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %3, ptr addrspace(1) %4, ptr addrspace(1) %5, ptr addrspace(1) %6, <2 x half> %7) local_unnamed_addr #0 {
  %9 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %7) #1
  %10 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %2, <2 x float> %9, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %11 = extractvalue { <4 x half>, i8 } %10, 0
  %12 = shufflevector <4 x half> %11, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %13 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %12) #1
  %14 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %3, <2 x float> %9, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %15 = extractvalue { <4 x half>, i8 } %14, 0
  %16 = extractelement <4 x half> %15, i64 0
  %17 = fpext half %16 to float
  %18 = fsub fast float 1.000000e+00, %17
  %19 = fcmp fast ogt float %18, 0x3FEFAE1480000000
  br i1 %19, label %20, label %88

20:                                               ; preds = %8
  %21 = shufflevector <3 x float> %13, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %22 = insertelement <4 x float> %21, float %18, i64 3
  %23 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 0
  %24 = load <4 x half>, ptr addrspace(2) %23, align 8, !alias.scope !31, !noalias !27
  %25 = extractelement <4 x half> %24, i64 0
  %26 = insertelement <2 x half> <half undef, half 0xH0000>, half %25, i64 0
  %27 = fsub fast <2 x half> %7, %26
  %28 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %27) #1
  %29 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %2, <2 x float> %28, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %30 = extractvalue { <4 x half>, i8 } %29, 0
  %31 = shufflevector <4 x half> %30, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %32 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %31) #1
  %33 = shufflevector <3 x float> %32, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %34 = fadd fast <2 x half> %26, %7
  %35 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %34) #1
  %36 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %2, <2 x float> %35, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %37 = extractvalue { <4 x half>, i8 } %36, 0
  %38 = shufflevector <4 x half> %37, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %39 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %38) #1
  %40 = shufflevector <3 x float> %39, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %41 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %3, <2 x float> %28, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %42 = extractvalue { <4 x half>, i8 } %41, 0
  %43 = extractelement <4 x half> %42, i64 0
  %44 = fpext half %43 to float
  %45 = fsub fast float 1.000000e+00, %44
  %46 = insertelement <4 x float> %33, float %45, i64 3
  %47 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %3, <2 x float> %35, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %48 = extractvalue { <4 x half>, i8 } %47, 0
  %49 = extractelement <4 x half> %48, i64 0
  %50 = fpext half %49 to float
  %51 = fsub fast float 1.000000e+00, %50
  %52 = insertelement <4 x float> %40, float %51, i64 3
  %53 = fsub fast half %49, %43
  %54 = fcmp fast ogt half %53, 0xH0000
  %55 = zext i1 %54 to i32
  %56 = fcmp fast olt half %53, 0xH0000
  %57 = sext i1 %56 to i32
  %58 = add nsw i32 %55, %57
  %59 = tail call fast float @air.convert.f.f32.s.i32(i32 %58) #1
  %60 = tail call fast float @air.fast_clamp.f32(float %59, float 0.000000e+00, float 1.000000e+00) #1
  %61 = fsub fast <4 x float> %52, %46
  %62 = insertelement <4 x float> undef, float %60, i64 0
  %63 = shufflevector <4 x float> %62, <4 x float> undef, <4 x i32> zeroinitializer
  %64 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %63, <4 x float> %61, <4 x float> %46) #1
  %65 = extractelement <4 x float> %64, i64 3
  %66 = fsub fast float %18, %65
  %67 = fptrunc float %66 to half
  %68 = fcmp fast ogt half %67, 0xH0000
  %69 = zext i1 %68 to i32
  %70 = fcmp fast olt half %67, 0xH0000
  %71 = sext i1 %70 to i32
  %72 = add nsw i32 %69, %71
  %73 = tail call fast float @air.convert.f.f32.s.i32(i32 %72) #1
  %74 = tail call fast float @air.fast_clamp.f32(float %73, float 0.000000e+00, float 1.000000e+00) #1
  %75 = insertelement <4 x float> undef, float %74, i64 0
  %76 = fsub fast <4 x float> %64, %22
  %77 = shufflevector <4 x float> %75, <4 x float> undef, <4 x i32> zeroinitializer
  %78 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %77, <4 x float> %76, <4 x float> %22) #1
  %79 = extractelement <4 x float> %78, i64 3
  %80 = fcmp fast ogt float %79, 0x3FEFAE1480000000
  br i1 %80, label %81, label %83

81:                                               ; preds = %20
  %82 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %78) #1
  br label %161

83:                                               ; preds = %20
  %84 = shufflevector <4 x float> %78, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %85 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %84) #1
  %86 = fptrunc float %79 to half
  %87 = insertelement <4 x half> undef, half %86, i64 3
  br label %95

88:                                               ; preds = %8
  %89 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %13) #1
  %90 = fptrunc float %18 to half
  %91 = insertelement <4 x half> undef, half %90, i64 3
  %92 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 0
  %93 = load <4 x half>, ptr addrspace(2) %92, align 8, !alias.scope !31, !noalias !27
  %94 = extractelement <4 x half> %93, i64 0
  br label %95

95:                                               ; preds = %88, %83
  %96 = phi half [ %94, %88 ], [ %25, %83 ]
  %97 = phi <3 x half> [ %89, %88 ], [ %85, %83 ]
  %98 = phi <4 x half> [ %91, %88 ], [ %87, %83 ]
  %99 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 1
  %100 = load half, ptr addrspace(2) %99, align 8, !tbaa !33, !alias.scope !31, !noalias !27
  %101 = fmul fast half %96, %100
  %102 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %4, ptr addrspace(2) readonly captures(none) %1, <2 x float> %9, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %103 = extractvalue { <4 x float>, i8 } %102, 0
  %104 = extractelement <4 x float> %103, i64 0
  %105 = fdiv fast float 0x4016AF6480000000, %104
  %106 = fptrunc float %105 to half
  %107 = fmul fast half %101, %106
  %108 = insertelement <2 x half> <half undef, half 0xH0000>, half %107, i64 0
  %109 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 2, i64 0
  %110 = load <4 x half>, ptr addrspace(2) %109, align 8, !alias.scope !31, !noalias !27
  %111 = shufflevector <4 x half> %110, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %112 = fmul fast <3 x half> %111, %97
  %113 = fmul fast half %101, 0xH66A5
  %114 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 3
  %115 = load i32, ptr addrspace(2) %114, align 8, !tbaa !39, !alias.scope !31, !noalias !27
  %116 = icmp sgt i32 %115, 1
  br i1 %116, label %117, label %157

117:                                              ; preds = %117, %95
  %118 = phi <3 x half> [ %154, %117 ], [ %112, %95 ]
  %119 = phi i32 [ %155, %117 ], [ 1, %95 ]
  %120 = zext i32 %119 to i64
  %121 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 2, i64 %120
  %122 = load <4 x half>, ptr addrspace(2) %121, align 8, !alias.scope !31, !noalias !27
  %123 = shufflevector <4 x half> %122, <4 x half> undef, <2 x i32> <i32 3, i32 3>
  %124 = tail call fast <2 x half> @air.fma.v2f16(<2 x half> %123, <2 x half> %108, <2 x half> %7) #1
  %125 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %124) #1
  %126 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %2, <2 x float> %125, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %127 = extractvalue { <4 x half>, i8 } %126, 0
  %128 = shufflevector <4 x half> %127, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %129 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %4, ptr addrspace(2) readonly captures(none) %1, <2 x float> %125, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %130 = extractvalue { <4 x float>, i8 } %129, 0
  %131 = extractelement <4 x float> %130, i64 0
  %132 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %3, <2 x float> %125, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !27, !noalias !31
  %133 = extractvalue { <4 x half>, i8 } %132, 0
  %134 = extractelement <4 x half> %133, i64 0
  %135 = fpext half %134 to float
  %136 = fsub fast float 1.000000e+00, %135
  %137 = fsub fast float %104, %131
  %138 = fptrunc float %137 to half
  %139 = tail call fast half @air.fabs.f16(half %138) #1
  %140 = fmul fast half %113, %139
  %141 = tail call fast half @air.clamp.f16(half %140, half 0xH0000, half 0xH3C00) #1
  %142 = insertelement <2 x half> undef, half %141, i64 0
  %143 = fsub fast <3 x half> %97, %128
  %144 = shufflevector <2 x half> %142, <2 x half> undef, <3 x i32> zeroinitializer
  %145 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %144, <3 x half> %143, <3 x half> %128) #1
  %146 = fsub fast <3 x half> %97, %145
  %147 = insertelement <3 x float> undef, float %136, i64 0
  %148 = shufflevector <3 x float> %147, <3 x float> undef, <3 x i32> zeroinitializer
  %149 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %146) #1
  %150 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %145) #1
  %151 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %148, <3 x float> %149, <3 x float> %150) #1
  %152 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %151) #1
  %153 = shufflevector <4 x half> %122, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %154 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %153, <3 x half> %152, <3 x half> %118) #1
  %155 = add nuw nsw i32 %119, 1
  %156 = icmp eq i32 %155, %115
  br i1 %156, label %157, label %117, !llvm.loop !40

157:                                              ; preds = %117, %95
  %158 = phi <3 x half> [ %112, %95 ], [ %154, %117 ]
  %159 = shufflevector <3 x half> %158, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %160 = shufflevector <4 x half> %159, <4 x half> %98, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %161

161:                                              ; preds = %157, %81
  %162 = phi <4 x half> [ %82, %81 ], [ %160, %157 ]
  %163 = insertvalue <{ <4 x half> }> undef, <4 x half> %162, 0
  ret <{ <4 x half> }> %163
}

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fma.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fabs.f16(half) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x half> @air.fma.v2f16(<2 x half>, <2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_clamp.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.convert.f.f32.s.i32(i32) local_unnamed_addr #1

attributes #0 = { convergent nounwind optsize memory(read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }
attributes #2 = { convergent nounwind memory(argmem: read) }

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
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_TARGET0"}
!17 = !{!18, !20, !21, !22, !23, !24, !25, !26}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 224, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 224, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"FGlobals_Type", !"air.arg_name", !"FGlobals"}
!19 = !{i32 0, i32 8, i32 0, !"half4", !"_QuarterDepthTexture_TexelSize", i32 8, i32 2, i32 0, !"half", !"_SSSScale", i32 16, i32 8, i32 25, !"half4", !"_Kernel", i32 216, i32 4, i32 0, !"int", !"_SamplerSteps"}
!20 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_QuarterLinearDepthTexture"}
!21 = !{i32 2, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SceneTex"}
!22 = !{i32 3, !"air.sampler", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SSSSkinAlphaTexture"}
!23 = !{i32 4, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_QuarterLinearDepthTexture"}
!24 = !{i32 5, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SceneTex"}
!25 = !{i32 6, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SSSSkinAlphaTexture"}
!26 = !{i32 7, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half2", !"air.arg_name", !"TEXCOORD0"}
!27 = !{!28, !30}
!28 = distinct !{!28, !29, !"air-alias-scope-samplers"}
!29 = distinct !{!29, !"air-alias-scopes(xlatMtlMain)"}
!30 = distinct !{!30, !29, !"air-alias-scope-textures"}
!31 = !{!32}
!32 = distinct !{!32, !29, !"air-alias-scope-arg(0)"}
!33 = !{!34, !37, i64 8}
!34 = !{!"_ZTS13FGlobals_Type", !35, i64 0, !37, i64 8, !35, i64 16, !38, i64 216}
!35 = !{!"omnipotent char", !36, i64 0}
!36 = !{!"Simple C++ TBAA"}
!37 = !{!"half", !35, i64 0}
!38 = !{!"int", !35, i64 0}
!39 = !{!34, !38, i64 216}
!40 = distinct !{!40, !41}
!41 = !{!"llvm.loop.mustprogress"}
