; ModuleID = '/Users/songdogwang/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/C2F2D89403D39FBF_7593/modules/0aae7e0986955774b1126afa4878163b49fe0e39c7b8e3b212e08aa9613b4477/module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.UnityPerDraw_Type = type { [4 x <4 x float>], [4 x <4 x float>], <4 x float>, <4 x float>, [4 x <4 x float>], [4 x <4 x float>], <4 x float>, i32, [12 x i8] }
%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }
%struct.UnityPerPass_Type = type { [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, [6 x <4 x half>] }

; Function Attrs: nounwind optsize memory(none)
define <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(592) "air-buffer-no-alias" %2, <4 x float> %3, <3 x half> %4, <4 x half> %5, <2 x float> %6, <2 x float> %7, <2 x float> %8, <2 x float> %9) local_unnamed_addr #0 {
  %11 = shufflevector <4 x float> %3, <4 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %12 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 0, i64 1
  %13 = load <4 x float>, ptr addrspace(2) %12, align 16, !alias.scope !38, !noalias !41
  %14 = shufflevector <4 x float> %13, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %15 = fmul nnan ninf nsz arcp afn <3 x float> %11, %14
  %16 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 0, i64 0
  %17 = load <4 x float>, ptr addrspace(2) %16, align 16, !alias.scope !38, !noalias !41
  %18 = shufflevector <4 x float> %17, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %19 = shufflevector <4 x float> %3, <4 x float> undef, <3 x i32> zeroinitializer
  %20 = tail call nnan ninf nsz arcp afn <3 x float> @air.fma.v3f32(<3 x float> %18, <3 x float> %19, <3 x float> %15) #1
  %21 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 0, i64 2
  %22 = load <4 x float>, ptr addrspace(2) %21, align 16, !alias.scope !38, !noalias !41
  %23 = shufflevector <4 x float> %22, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %24 = shufflevector <4 x float> %3, <4 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %25 = tail call nnan ninf nsz arcp afn <3 x float> @air.fma.v3f32(<3 x float> %23, <3 x float> %24, <3 x float> %20) #1
  %26 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 0, i64 3
  %27 = load <4 x float>, ptr addrspace(2) %26, align 16, !alias.scope !38, !noalias !41
  %28 = shufflevector <4 x float> %27, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %29 = fadd nnan ninf nsz arcp afn <3 x float> %25, %28
  %30 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5
  %31 = load <3 x float>, ptr addrspace(2) %30, align 16, !alias.scope !44, !noalias !45
  %32 = fsub nnan ninf nsz arcp afn <3 x float> %29, %31
  %33 = shufflevector <3 x float> %32, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %34 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %2, i64 0, i32 1, i64 1
  %35 = load <4 x float>, ptr addrspace(2) %34, align 16, !tbaa !46, !alias.scope !49, !noalias !50
  %36 = fmul nnan ninf nsz arcp afn <4 x float> %35, %33
  %37 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %2, i64 0, i32 1, i64 0
  %38 = load <4 x float>, ptr addrspace(2) %37, align 16, !tbaa !46, !alias.scope !49, !noalias !50
  %39 = shufflevector <3 x float> %32, <3 x float> undef, <4 x i32> zeroinitializer
  %40 = tail call nnan ninf nsz arcp afn <4 x float> @air.fma.v4f32(<4 x float> %38, <4 x float> %39, <4 x float> %36) #1
  %41 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %2, i64 0, i32 1, i64 2
  %42 = load <4 x float>, ptr addrspace(2) %41, align 16, !tbaa !46, !alias.scope !49, !noalias !50
  %43 = shufflevector <3 x float> %32, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %44 = tail call nnan ninf nsz arcp afn <4 x float> @air.fma.v4f32(<4 x float> %42, <4 x float> %43, <4 x float> %40) #1
  %45 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %2, i64 0, i32 1, i64 3
  %46 = load <4 x float>, ptr addrspace(2) %45, align 16, !tbaa !46, !alias.scope !49, !noalias !50
  %47 = fadd nnan ninf nsz arcp afn <4 x float> %44, %46
  %48 = extractelement <4 x float> %47, i64 3
  %49 = tail call nnan ninf nsz arcp afn float @air.fast_fabs.f32(float %48) #1
  %50 = extractelement <4 x float> %47, i64 2
  %51 = tail call nnan ninf nsz arcp afn float @air.fma.f32(float %49, float 0x3F4A36E2E0000000, float %50) #1
  %52 = insertelement <4 x float> undef, float %51, i64 2
  %53 = shufflevector <4 x float> %47, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 3>
  %54 = shufflevector <3 x float> %53, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %55 = shufflevector <4 x float> %52, <4 x float> %54, <4 x i32> <i32 4, i32 5, i32 2, i32 6>
  %56 = shufflevector <2 x float> %6, <2 x float> %7, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %57 = tail call nnan ninf nsz arcp afn <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %56) #1
  %58 = shufflevector <2 x float> %8, <2 x float> %9, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %59 = tail call nnan ninf nsz arcp afn <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %58) #1
  %60 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 7
  %61 = load <3 x float>, ptr addrspace(2) %60, align 16, !alias.scope !44, !noalias !45
  %62 = fsub nnan ninf nsz arcp afn <3 x float> %61, %29
  %63 = extractelement <3 x float> %62, i64 0
  %64 = fptrunc float %63 to half
  %65 = tail call nnan ninf nsz arcp afn <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %4) #1
  %66 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 1, i64 0
  %67 = load <4 x float>, ptr addrspace(2) %66, align 16, !alias.scope !38, !noalias !41
  %68 = shufflevector <4 x float> %67, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %69 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %65, <3 x float> %68) #1
  %70 = fptrunc float %69 to half
  %71 = insertelement <3 x half> undef, half %70, i64 0
  %72 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 1, i64 1
  %73 = load <4 x float>, ptr addrspace(2) %72, align 16, !alias.scope !38, !noalias !41
  %74 = shufflevector <4 x float> %73, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %75 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %65, <3 x float> %74) #1
  %76 = fptrunc float %75 to half
  %77 = insertelement <3 x half> %71, half %76, i64 1
  %78 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 1, i64 2
  %79 = load <4 x float>, ptr addrspace(2) %78, align 16, !alias.scope !38, !noalias !41
  %80 = shufflevector <4 x float> %79, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %81 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %65, <3 x float> %80) #1
  %82 = fptrunc float %81 to half
  %83 = insertelement <3 x half> %77, half %82, i64 2
  %84 = tail call nnan ninf nsz arcp afn half @air.dot.v3f16(<3 x half> %83, <3 x half> %83) #1
  %85 = tail call nnan ninf nsz arcp afn half @air.rsqrt.f16(half %84) #1
  %86 = insertelement <3 x half> undef, half %85, i64 0
  %87 = shufflevector <3 x half> %86, <3 x half> undef, <3 x i32> zeroinitializer
  %88 = fmul nnan ninf nsz arcp afn <3 x half> %83, %87
  %89 = shufflevector <3 x half> %88, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %90 = insertelement <4 x half> %89, half %64, i64 3
  %91 = extractelement <3 x float> %62, i64 1
  %92 = fptrunc float %91 to half
  %93 = extractelement <3 x float> %62, i64 2
  %94 = fptrunc float %93 to half
  %95 = extractelement <4 x float> %17, i64 0
  %96 = insertelement <3 x float> undef, float %95, i64 0
  %97 = extractelement <4 x float> %13, i64 0
  %98 = insertelement <3 x float> %96, float %97, i64 1
  %99 = extractelement <4 x float> %22, i64 0
  %100 = insertelement <3 x float> %98, float %99, i64 2
  %101 = shufflevector <4 x half> %5, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %102 = tail call nnan ninf nsz arcp afn <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %101) #1
  %103 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %100, <3 x float> %102) #1
  %104 = fptrunc float %103 to half
  %105 = insertelement <3 x half> undef, half %104, i64 0
  %106 = extractelement <4 x float> %17, i64 1
  %107 = insertelement <3 x float> undef, float %106, i64 0
  %108 = extractelement <4 x float> %13, i64 1
  %109 = insertelement <3 x float> %107, float %108, i64 1
  %110 = extractelement <4 x float> %22, i64 1
  %111 = insertelement <3 x float> %109, float %110, i64 2
  %112 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %111, <3 x float> %102) #1
  %113 = fptrunc float %112 to half
  %114 = insertelement <3 x half> %105, half %113, i64 1
  %115 = extractelement <4 x float> %17, i64 2
  %116 = insertelement <3 x float> undef, float %115, i64 0
  %117 = extractelement <4 x float> %13, i64 2
  %118 = insertelement <3 x float> %116, float %117, i64 1
  %119 = extractelement <4 x float> %22, i64 2
  %120 = insertelement <3 x float> %118, float %119, i64 2
  %121 = tail call nnan ninf nsz arcp afn float @air.dot.v3f32(<3 x float> %120, <3 x float> %102) #1
  %122 = fptrunc float %121 to half
  %123 = insertelement <3 x half> %114, half %122, i64 2
  %124 = tail call nnan ninf nsz arcp afn half @air.dot.v3f16(<3 x half> %123, <3 x half> %123) #1
  %125 = tail call nnan ninf nsz arcp afn half @air.rsqrt.f16(half %124) #1
  %126 = insertelement <3 x half> undef, half %125, i64 0
  %127 = shufflevector <3 x half> %126, <3 x half> undef, <3 x i32> zeroinitializer
  %128 = fmul nnan ninf nsz arcp afn <3 x half> %123, %127
  %129 = shufflevector <3 x half> %128, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %130 = insertelement <4 x half> %129, half %92, i64 3
  %131 = shufflevector <3 x half> %88, <3 x half> undef, <3 x i32> <i32 2, i32 0, i32 1>
  %132 = shufflevector <3 x half> %128, <3 x half> undef, <3 x i32> <i32 1, i32 2, i32 0>
  %133 = shufflevector <3 x half> %88, <3 x half> undef, <3 x i32> <i32 1, i32 2, i32 0>
  %134 = shufflevector <3 x half> %128, <3 x half> undef, <3 x i32> <i32 2, i32 0, i32 1>
  %135 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %131
  %136 = fmul nnan ninf nsz arcp afn <3 x half> %132, %135
  %137 = tail call nnan ninf nsz arcp afn <3 x half> @air.fma.v3f16(<3 x half> %133, <3 x half> %134, <3 x half> %136) #1
  %138 = extractelement <4 x half> %5, i64 3
  %139 = fpext half %138 to float
  %140 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %1, i64 0, i32 2
  %141 = load <4 x float>, ptr addrspace(2) %140, align 16, !alias.scope !38, !noalias !41
  %142 = extractelement <4 x float> %141, i64 3
  %143 = fmul nnan ninf nsz arcp afn float %142, %139
  %144 = fptrunc float %143 to half
  %145 = insertelement <3 x half> undef, half %144, i64 0
  %146 = shufflevector <3 x half> %145, <3 x half> undef, <3 x i32> zeroinitializer
  %147 = fmul nnan ninf nsz arcp afn <3 x half> %137, %146
  %148 = shufflevector <3 x half> %147, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %149 = insertelement <4 x half> %148, half %94, i64 3
  %150 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> undef, <4 x float> %55, 0
  %151 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %150, <4 x half> %57, 1
  %152 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %151, <4 x half> %59, 2
  %153 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %152, <3 x float> %29, 3
  %154 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %153, <4 x half> %90, 4
  %155 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %154, <4 x half> %130, 5
  %156 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %155, <4 x half> %149, 6
  %157 = insertvalue <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %156, <4 x float> %47, 7
  ret <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> %157
}

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fma.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.rsqrt.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fabs.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

attributes #0 = { nounwind optsize memory(none) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
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
!12 = !{!"air.compile.fast_math_disable"}
!13 = !{!"air.compile.framebuffer_fetch_enable"}
!14 = !{ptr @xlatMtlMain, !15, !24}
!15 = !{!16, !17, !18, !19, !20, !21, !22, !23}
!16 = !{!"air.position", !"air.invariant", !"air.arg_type_name", !"float4", !"air.arg_name", !"mtl_Position"}
!17 = !{!"air.vertex_output", !"user(TEXCOORD0)", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD0"}
!18 = !{!"air.vertex_output", !"user(TEXCOORD1)", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD1"}
!19 = !{!"air.vertex_output", !"user(TEXCOORD2)", !"air.arg_type_name", !"float3", !"air.arg_name", !"TEXCOORD2"}
!20 = !{!"air.vertex_output", !"user(TEXCOORD3)", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD3"}
!21 = !{!"air.vertex_output", !"user(TEXCOORD4)", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD4"}
!22 = !{!"air.vertex_output", !"user(TEXCOORD5)", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD5"}
!23 = !{!"air.vertex_output", !"user(TEXCOORD6)", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD6"}
!24 = !{!25, !27, !29, !31, !32, !33, !34, !35, !36, !37}
!25 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !26, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!26 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!27 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 1, i32 1, !"air.read", !"air.struct_type_info", !28, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerDraw_Type", !"air.arg_name", !"UnityPerDraw"}
!28 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_ObjectToWorld", i32 64, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_WorldToObject", i32 128, i32 16, i32 0, !"float4", !"unity_WorldTransformParams", i32 144, i32 16, i32 0, !"float4", !"unity_SpecCube0_HDR", i32 160, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_MatrixPreviousM", i32 224, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_MatrixPreviousMI", i32 288, i32 16, i32 0, !"float4", !"unity_MotionVectorsParams", i32 304, i32 4, i32 0, !"uint", !"Pape_SpecCubeArrayMaxMip"}
!29 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 592, !"air.location_index", i32 2, i32 1, !"air.read", !"air.struct_type_info", !30, !"air.arg_type_size", i32 592, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerPass_Type", !"air.arg_name", !"UnityPerPass"}
!30 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_PrevViewProjMatrix", i32 64, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewProjMatrix", i32 128, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_NonJitteredViewProjMatrix", i32 192, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewMatrix", i32 256, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ProjMatrix", i32 320, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewProjMatrix", i32 384, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewMatrix", i32 448, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvProjMatrix", i32 512, i32 16, i32 0, !"float4", !"_InvProjParam", i32 528, i32 8, i32 0, !"half4", !"_ScreenSize", i32 536, i32 8, i32 0, !"half4", !"_HDRSize", i32 544, i32 8, i32 6, !"half4", !"_FrustumPlanes"}
!31 = !{i32 3, !"air.vertex_input", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"POSITION0"}
!32 = !{i32 4, !"air.vertex_input", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"half3", !"air.arg_name", !"NORMAL0"}
!33 = !{i32 5, !"air.vertex_input", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"half4", !"air.arg_name", !"TANGENT0"}
!34 = !{i32 6, !"air.vertex_input", !"air.location_index", i32 3, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!35 = !{i32 7, !"air.vertex_input", !"air.location_index", i32 4, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD1"}
!36 = !{i32 8, !"air.vertex_input", !"air.location_index", i32 5, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD2"}
!37 = !{i32 9, !"air.vertex_input", !"air.location_index", i32 6, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD3"}
!38 = !{!39}
!39 = distinct !{!39, !40, !"air-alias-scope-arg(1)"}
!40 = distinct !{!40, !"air-alias-scopes(xlatMtlMain)"}
!41 = !{!42, !43}
!42 = distinct !{!42, !40, !"air-alias-scope-arg(0)"}
!43 = distinct !{!43, !40, !"air-alias-scope-arg(2)"}
!44 = !{!42}
!45 = !{!39, !43}
!46 = !{!47, !47, i64 0}
!47 = !{!"omnipotent char", !48, i64 0}
!48 = !{!"Simple C++ TBAA"}
!49 = !{!43}
!50 = !{!42, !39}
