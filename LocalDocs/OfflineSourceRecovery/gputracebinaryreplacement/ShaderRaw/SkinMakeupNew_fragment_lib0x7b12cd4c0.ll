; ModuleID = '/Users/songdogwang/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/61F4807E5636D024_28097/modules/21b9a2299bb9dac99a7a20d403db700be3c80095ce28596ab02955d4d4c3bf5b/module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.UnityPerMaterial_Type = type { <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, half, half, half, half, half, half, half, half, half, half, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, half, half, half, half, half, half, half, half, half, half, half, half, half, half, half, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, half, half, <3 x half> }
%struct.AsukaPerShader_PerCamera_Type = type { [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float>, half, half, half, [10 x i8] }
%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }
%struct.PapePerRendererCB_Type = type { [7 x <4 x half>], [7 x <4 x half>], <4 x half>, half, half, half, half, half, half }
%struct.Character_Param_Type = type { <4 x float>, <4 x half>, <4 x half>, <4 x half>, <3 x half>, half, half, half, half, half, half, <4 x half>, <4 x half>, <4 x half>, <4 x half>, half, [14 x i8] }
%struct.UnityPerDraw_Type = type { [4 x <4 x float>], [4 x <4 x float>], <4 x float>, <4 x float>, [4 x <4 x float>], [4 x <4 x float>], <4 x float>, i32, [12 x i8] }
%struct.AsukaPerShader_AddLightParams_PerCamera_Type = type { [30 x <4 x float>], [30 x <4 x float>], <4 x half>, [30 x <4 x half>], [30 x <4 x half>], [30 x <4 x float>], [30 x <4 x half>] }

; Function Attrs: convergent nounwind optsize
define <{ <4 x half>, half }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(2176) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(144) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %2, ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %3, ptr addrspace(2) readonly captures(none) dereferenceable(112) "air-buffer-no-alias" %4, ptr addrspace(2) readonly captures(none) dereferenceable(336) "air-buffer-no-alias" %5, ptr addrspace(2) readonly captures(none) dereferenceable(136) "air-buffer-no-alias" %6, ptr addrspace(2) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %9, ptr addrspace(2) readonly captures(none) %10, ptr addrspace(2) readonly captures(none) %11, ptr addrspace(2) readonly captures(none) %12, ptr addrspace(2) readonly captures(none) %13, ptr addrspace(2) readonly captures(none) %14, ptr addrspace(2) readonly captures(none) %15, ptr addrspace(2) readonly captures(none) %16, ptr addrspace(2) readonly captures(none) %17, ptr addrspace(1) %18, ptr addrspace(1) %19, ptr addrspace(1) %20, ptr addrspace(1) %21, ptr addrspace(1) %22, ptr addrspace(1) %23, ptr addrspace(1) %24, ptr addrspace(1) %25, ptr addrspace(1) %26, ptr addrspace(1) %27, ptr addrspace(1) %28, ptr addrspace(1) %29, ptr addrspace(1) %30, ptr addrspace(1) %31, ptr addrspace(1) %32, ptr addrspace(1) %33, <4 x half> %34, <4 x half> %35, <3 x float> %36, <4 x half> %37, <4 x half> %38, <4 x half> %39, <4 x float> %40) local_unnamed_addr #0 {
  %42 = shufflevector <4 x half> %34, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %43 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %42) #1
  %44 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %21, ptr addrspace(2) readonly captures(none) %10, <2 x float> %43, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %45 = extractvalue { <4 x half>, i8 } %44, 0
  %46 = shufflevector <4 x half> %45, <4 x half> undef, <2 x i32> <i32 0, i32 2>
  %47 = extractelement <4 x half> %34, i64 0
  %48 = fcmp fast oge half %47, 0xH3800
  %49 = select fast i1 %48, float 1.000000e+00, float 0.000000e+00
  %50 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 14
  %51 = load half, ptr addrspace(2) %50, align 8, !alias.scope !79, !noalias !80
  %52 = select fast i1 %48, half 0xH0000, half %51
  %53 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 13
  %54 = load half, ptr addrspace(2) %53, align 2, !tbaa !81, !alias.scope !79, !noalias !80
  %55 = fpext half %54 to float
  %56 = fpext half %52 to float
  %57 = tail call fast float @air.fma.f32(float %55, float %49, float %56) #1
  %58 = fptrunc float %57 to half
  %59 = insertelement <3 x half> undef, half %58, i64 0
  %60 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 8
  %61 = load half, ptr addrspace(2) %60, align 4, !tbaa !86, !alias.scope !88, !noalias !89
  %62 = fpext half %61 to float
  %63 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %20, ptr addrspace(2) readonly captures(none) %9, <2 x float> %43, i1 true, <2 x i32> zeroinitializer, i1 false, float %62, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %64 = extractvalue { <4 x half>, i8 } %63, 0
  %65 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 1
  %66 = load <4 x half>, ptr addrspace(2) %65, align 8, !alias.scope !79, !noalias !80
  %67 = shufflevector <4 x half> %35, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %68 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %67) #1
  %69 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %23, ptr addrspace(2) readonly captures(none) %9, <2 x float> %68, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %70 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 38
  %71 = load half, ptr addrspace(2) %70, align 2, !tbaa !90, !alias.scope !79, !noalias !80
  %72 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 29
  %73 = load <3 x half>, ptr addrspace(2) %72, align 8, !alias.scope !79, !noalias !80
  %74 = shufflevector <4 x half> %35, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %75 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %74) #1
  %76 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %24, ptr addrspace(2) readonly captures(none) %12, <2 x float> %75, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %77 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 30
  %78 = load <3 x half>, ptr addrspace(2) %77, align 8, !alias.scope !79, !noalias !80
  %79 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 39
  %80 = load half, ptr addrspace(2) %79, align 4, !tbaa !91, !alias.scope !79, !noalias !80
  %81 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 36
  %82 = load <3 x half>, ptr addrspace(2) %81, align 8, !alias.scope !79, !noalias !80
  %83 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %25, ptr addrspace(2) readonly captures(none) %9, <2 x float> %75, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %84 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 31
  %85 = load <3 x half>, ptr addrspace(2) %84, align 8, !alias.scope !79, !noalias !80
  %86 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 40
  %87 = load half, ptr addrspace(2) %86, align 2, !tbaa !92, !alias.scope !79, !noalias !80
  %88 = shufflevector <4 x half> %34, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %89 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %88) #1
  %90 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %26, ptr addrspace(2) readonly captures(none) %9, <2 x float> %89, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %91 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 41
  %92 = load half, ptr addrspace(2) %91, align 8, !tbaa !93, !alias.scope !79, !noalias !80
  %93 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 33
  %94 = load <3 x half>, ptr addrspace(2) %93, align 8, !alias.scope !79, !noalias !80
  %95 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %27, ptr addrspace(2) readonly captures(none) %13, <2 x float> %68, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %96 = extractvalue { <4 x half>, i8 } %95, 0
  %97 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 32
  %98 = load <3 x half>, ptr addrspace(2) %97, align 8, !alias.scope !79, !noalias !80
  %99 = extractelement <4 x half> %96, i64 3
  %100 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 42
  %101 = load half, ptr addrspace(2) %100, align 2, !tbaa !94, !alias.scope !79, !noalias !80
  %102 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 43
  %103 = load half, ptr addrspace(2) %102, align 4, !tbaa !95, !alias.scope !79, !noalias !80
  %104 = insertelement <2 x half> undef, half %103, i64 0
  %105 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 44
  %106 = load half, ptr addrspace(2) %105, align 2, !tbaa !96, !alias.scope !79, !noalias !80
  %107 = insertelement <2 x half> %104, half %106, i64 1
  %108 = fadd fast <2 x half> %107, splat (half 0xHBC00)
  %109 = shufflevector <4 x half> %96, <4 x half> undef, <2 x i32> <i32 3, i32 3>
  %110 = tail call fast <2 x half> @air.fma.v2f16(<2 x half> %109, <2 x half> %108, <2 x half> splat (half 0xH3C00)) #1
  %111 = fmul fast <2 x half> %46, %110
  %112 = shufflevector <2 x half> %111, <2 x half> undef, <3 x i32> <i32 0, i32 poison, i32 poison>
  %113 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 22
  %114 = load <4 x half>, ptr addrspace(2) %113, align 8, !alias.scope !79, !noalias !80
  %115 = shufflevector <4 x half> %114, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %116 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %115) #1
  %117 = fadd fast <2 x float> %89, %116
  %118 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 23
  %119 = load <4 x half>, ptr addrspace(2) %118, align 8, !alias.scope !79, !noalias !80
  %120 = shufflevector <4 x half> %119, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %121 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %120) #1
  %122 = fadd fast <2 x float> %89, %121
  %123 = shufflevector <2 x float> %117, <2 x float> %122, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %124 = fadd fast <4 x float> %123, splat (float -5.000000e-01)
  %125 = shufflevector <4 x half> %114, <4 x half> %119, <4 x i32> <i32 2, i32 poison, i32 6, i32 poison>
  %126 = shufflevector <4 x half> %125, <4 x half> undef, <4 x i32> <i32 0, i32 0, i32 2, i32 2>
  %127 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %126) #1
  %128 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %124, <4 x float> %127, <4 x float> splat (float 5.000000e-01)) #1
  %129 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %128) #1
  %130 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %129, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %131 = shufflevector <4 x half> %130, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %132 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %131) #1
  %133 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %28, ptr addrspace(2) readonly captures(none) %9, <2 x float> %132, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %134 = shufflevector <4 x half> %130, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %135 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %134) #1
  %136 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %29, ptr addrspace(2) readonly captures(none) %9, <2 x float> %135, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %137 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 34
  %138 = load <3 x half>, ptr addrspace(2) %137, align 8, !alias.scope !79, !noalias !80
  %139 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 45
  %140 = load half, ptr addrspace(2) %139, align 8, !tbaa !97, !alias.scope !79, !noalias !80
  %141 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 35
  %142 = load <3 x half>, ptr addrspace(2) %141, align 8, !alias.scope !79, !noalias !80
  %143 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 46
  %144 = load half, ptr addrspace(2) %143, align 2, !tbaa !98, !alias.scope !79, !noalias !80
  %145 = extractelement <4 x half> %34, i64 1
  %146 = fcmp fast ole half %145, 0xH3800
  %147 = select fast i1 %146, float 1.000000e+00, float 0.000000e+00
  %148 = insertelement <4 x float> undef, float %147, i64 0
  %149 = extractelement <4 x half> %64, i64 3
  %150 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 58
  %151 = load half, ptr addrspace(2) %150, align 8, !tbaa !99, !alias.scope !79, !noalias !80
  %152 = fmul fast half %149, %151
  %153 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 56
  %154 = load <4 x half>, ptr addrspace(2) %153, align 8, !alias.scope !79, !noalias !80
  %155 = shufflevector <4 x half> %154, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %156 = insertelement <3 x half> %155, half %152, i64 2
  %157 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 57
  %158 = load <4 x half>, ptr addrspace(2) %157, align 8, !alias.scope !79, !noalias !80
  %159 = fsub fast <4 x half> %158, %154
  %160 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 59
  %161 = load half, ptr addrspace(2) %160, align 2, !tbaa !100, !alias.scope !79, !noalias !80
  %162 = fsub nnan ninf nsz arcp afn half 0xH8000, %152
  %163 = tail call fast half @air.fma.f16(half %99, half %161, half %162) #1
  %164 = insertelement <4 x half> %159, half %163, i64 2
  %165 = shufflevector <4 x float> %148, <4 x float> undef, <3 x i32> zeroinitializer
  %166 = shufflevector <4 x half> %164, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %167 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %166) #1
  %168 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %156) #1
  %169 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %165, <3 x float> %167, <3 x float> %168) #1
  %170 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %169) #1
  %171 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 54
  %172 = load <4 x half>, ptr addrspace(2) %171, align 8, !tbaa !101, !alias.scope !79, !noalias !80
  %173 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 55
  %174 = load <4 x half>, ptr addrspace(2) %173, align 8, !tbaa !101, !alias.scope !79, !noalias !80
  %175 = fsub fast <4 x half> %174, %172
  %176 = shufflevector <4 x float> %148, <4 x float> undef, <4 x i32> zeroinitializer
  %177 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %175) #1
  %178 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %172) #1
  %179 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %176, <4 x float> %177, <4 x float> %178) #1
  %180 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %179) #1
  %181 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 52
  %182 = load <4 x half>, ptr addrspace(2) %181, align 8, !alias.scope !79, !noalias !80
  %183 = shufflevector <4 x half> %182, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %184 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 53
  %185 = load <4 x half>, ptr addrspace(2) %184, align 8, !alias.scope !79, !noalias !80
  %186 = fsub fast <4 x half> %185, %182
  %187 = shufflevector <4 x half> %186, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %188 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %187) #1
  %189 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %183) #1
  %190 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %165, <3 x float> %188, <3 x float> %189) #1
  %191 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %190) #1
  %192 = shufflevector <3 x half> %170, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %193 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %192) #1
  %194 = shufflevector <4 x half> %34, <4 x half> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %195 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %194) #1
  %196 = fmul fast <4 x float> %193, %195
  %197 = shufflevector <4 x float> %196, <4 x float> undef, <3 x i32> <i32 2, i32 3, i32 2>
  %198 = tail call fast <3 x float> @air.fast_floor.v3f32(<3 x float> %197) #1
  %199 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %196, i32 0) #5
  %200 = shufflevector <4 x float> %199, <4 x float> undef, <3 x i32> <i32 3, i32 2, i32 3>
  %201 = fadd fast <3 x float> %200, splat (float -5.000000e-01)
  %202 = shufflevector <3 x float> %201, <3 x float> undef, <3 x i32> <i32 2, i32 1, i32 2>
  %203 = fcmp fast ogt <3 x float> %202, zeroinitializer
  %204 = tail call <3 x i32> @air.convert.u.v3i32.u.v3i1(<3 x i1> %203) #1
  %205 = fcmp fast olt <3 x float> %201, zeroinitializer
  %206 = tail call <3 x i32> @air.convert.u.v3i32.u.v3i1(<3 x i1> %205) #1
  %207 = sub <3 x i32> %204, %206
  %208 = tail call fast <3 x float> @air.convert.f.v3f32.s.v3i32(<3 x i32> %207) #1
  %209 = shufflevector <3 x float> %208, <3 x float> undef, <4 x i32> <i32 poison, i32 0, i32 1, i32 2>
  %210 = insertelement <4 x float> %209, float 0.000000e+00, i64 0
  %211 = shufflevector <3 x float> %198, <3 x float> undef, <3 x i32> <i32 2, i32 1, i32 2>
  %212 = shufflevector <4 x float> %210, <4 x float> undef, <3 x i32> <i32 0, i32 0, i32 2>
  %213 = fadd fast <3 x float> %211, %212
  %214 = shufflevector <3 x half> %170, <3 x half> undef, <3 x i32> <i32 0, i32 1, i32 0>
  %215 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %214) #1
  %216 = fdiv fast <3 x float> %213, %215
  %217 = shufflevector <4 x float> %210, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %218 = fadd fast <3 x float> %198, %217
  %219 = fdiv fast <3 x float> %218, %215
  %220 = shufflevector <3 x float> %216, <3 x float> undef, <2 x i32> <i32 1, i32 1>
  %221 = shufflevector <3 x float> %216, <3 x float> undef, <2 x i32> <i32 0, i32 2>
  %222 = fmul fast <2 x float> %220, %221
  %223 = fadd fast <2 x float> %220, %221
  %224 = fmul fast <2 x float> %223, splat (float 0x3FE3333340000000)
  %225 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %222, <2 x float> splat (float 0x3FD99999A0000000), <2 x float> %224) #1
  %226 = shufflevector <2 x float> %225, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 1, i32 poison>
  %227 = fmul fast <2 x float> %223, %222
  %228 = shufflevector <2 x float> %227, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %229 = shufflevector <4 x float> %226, <4 x float> %228, <4 x i32> <i32 0, i32 4, i32 2, i32 5>
  %230 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %229, <4 x float> splat (float 0x40A4664820000000), <4 x float> splat (float 0x40158624E0000000)) #1
  %231 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %230, i32 0) #5
  %232 = fmul fast <4 x float> %231, splat (float 0x404FE3F7C0000000)
  %233 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %232, i32 0) #5
  %234 = shufflevector <3 x float> %219, <3 x float> undef, <2 x i32> <i32 1, i32 1>
  %235 = shufflevector <3 x float> %219, <3 x float> undef, <2 x i32> <i32 0, i32 2>
  %236 = fmul fast <2 x float> %234, %235
  %237 = fadd fast <2 x float> %234, %235
  %238 = fmul fast <2 x float> %237, splat (float 0x3FE3333340000000)
  %239 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %236, <2 x float> splat (float 0x3FD99999A0000000), <2 x float> %238) #1
  %240 = shufflevector <2 x float> %239, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 1, i32 poison>
  %241 = fmul fast <2 x float> %237, %236
  %242 = shufflevector <2 x float> %241, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %243 = shufflevector <4 x float> %240, <4 x float> %242, <4 x i32> <i32 0, i32 4, i32 2, i32 5>
  %244 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %243, <4 x float> splat (float 0x40A4664820000000), <4 x float> splat (float 0x40158624E0000000)) #1
  %245 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %244, i32 0) #5
  %246 = fmul fast <4 x float> %245, splat (float 0x404FE3F7C0000000)
  %247 = shufflevector <4 x float> %246, <4 x float> undef, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  %248 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %247, i32 0) #5
  %249 = shufflevector <4 x float> %210, <4 x float> undef, <4 x i32> <i32 0, i32 0, i32 2, i32 0>
  %250 = fadd fast <4 x float> %249, %233
  %251 = shufflevector <4 x float> %248, <4 x float> undef, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  %252 = fadd fast <4 x float> %210, %251
  %253 = shufflevector <4 x float> %233, <4 x float> undef, <2 x i32> <i32 0, i32 2>
  %254 = shufflevector <2 x float> %253, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %255 = shufflevector <4 x float> %254, <4 x float> %248, <4 x i32> <i32 0, i32 1, i32 4, i32 5>
  %256 = shufflevector <4 x half> %180, <4 x half> undef, <4 x i32> zeroinitializer
  %257 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %256) #1
  %258 = fcmp fast oge <4 x float> %257, %255
  %259 = extractelement <4 x half> %180, i64 1
  %260 = fpext half %259 to float
  %261 = fsub fast float 1.000000e+00, %260
  %262 = insertelement <4 x float> undef, float %261, i64 0
  %263 = shufflevector <4 x float> %262, <4 x float> undef, <4 x i32> zeroinitializer
  %264 = shufflevector <4 x half> %180, <4 x half> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %265 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %264) #1
  %266 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %255, <4 x float> %263, <4 x float> %265) #1
  %267 = fadd fast <4 x float> %266, splat (float 0x3F1A36E2E0000000)
  %268 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %267) #1
  %269 = fdiv fast <4 x half> splat (half 0xH3C00), %268
  %270 = shufflevector <4 x float> %199, <4 x float> undef, <4 x i32> <i32 2, i32 3, i32 2, i32 3>
  %271 = fsub fast <4 x float> %270, %250
  %272 = shufflevector <4 x half> %269, <4 x half> undef, <4 x i32> <i32 0, i32 0, i32 1, i32 1>
  %273 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %272) #1
  %274 = tail call fast <4 x float> @air.fast_fabs.v4f32(<4 x float> %271) #1
  %275 = fmul fast <4 x float> %273, %274
  %276 = fsub fast <4 x float> %199, %252
  %277 = shufflevector <4 x half> %269, <4 x half> undef, <4 x i32> <i32 2, i32 2, i32 3, i32 3>
  %278 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %277) #1
  %279 = tail call fast <4 x float> @air.fast_fabs.v4f32(<4 x float> %276) #1
  %280 = fmul fast <4 x float> %278, %279
  %281 = shufflevector <4 x float> %275, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %282 = tail call fast float @air.dot.v2f32(<2 x float> %281, <2 x float> %281) #1
  %283 = fptrunc float %282 to half
  %284 = insertelement <4 x half> undef, half %283, i64 0
  %285 = shufflevector <4 x float> %275, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %286 = tail call fast float @air.dot.v2f32(<2 x float> %285, <2 x float> %285) #1
  %287 = fptrunc float %286 to half
  %288 = insertelement <4 x half> %284, half %287, i64 1
  %289 = shufflevector <4 x float> %280, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %290 = tail call fast float @air.dot.v2f32(<2 x float> %289, <2 x float> %289) #1
  %291 = fptrunc float %290 to half
  %292 = insertelement <4 x half> %288, half %291, i64 2
  %293 = shufflevector <4 x float> %280, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %294 = tail call fast float @air.dot.v2f32(<2 x float> %293, <2 x float> %293) #1
  %295 = fptrunc float %294 to half
  %296 = insertelement <4 x half> %292, half %295, i64 3
  %297 = fsub nnan ninf nsz arcp afn <4 x half> splat (half 0xH8000), %296
  %298 = tail call fast <4 x half> @air.fma.v4f16(<4 x half> %297, <4 x half> splat (half 0xH4400), <4 x half> splat (half 0xH3C00)) #1
  %299 = tail call fast <4 x half> @air.fmax.v4f16(<4 x half> %298, <4 x half> zeroinitializer) #1
  %300 = extractelement <4 x i1> %258, i64 0
  %301 = extractelement <4 x half> %299, i64 0
  %302 = select fast i1 %300, half %301, half 0xH0000
  %303 = insertelement <4 x half> undef, half %302, i64 0
  %304 = extractelement <4 x i1> %258, i64 1
  %305 = extractelement <4 x half> %299, i64 1
  %306 = select fast i1 %304, half %305, half 0xH0000
  %307 = insertelement <4 x half> %303, half %306, i64 1
  %308 = extractelement <4 x i1> %258, i64 2
  %309 = extractelement <4 x half> %299, i64 2
  %310 = select fast i1 %308, half %309, half 0xH0000
  %311 = insertelement <4 x half> %307, half %310, i64 2
  %312 = extractelement <4 x i1> %258, i64 3
  %313 = extractelement <4 x half> %299, i64 3
  %314 = select fast i1 %312, half %313, half 0xH0000
  %315 = insertelement <4 x half> %311, half %314, i64 3
  %316 = shufflevector <3 x half> %170, <3 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %317 = fmul fast <3 x half> %316, %191
  %318 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 27
  %319 = load <4 x half>, ptr addrspace(2) %318, align 8, !alias.scope !79, !noalias !80
  %320 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 28
  %321 = load <4 x half>, ptr addrspace(2) %320, align 8, !alias.scope !79, !noalias !80
  %322 = shufflevector <4 x half> %321, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %323 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %322) #1
  %324 = shufflevector <4 x half> %321, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %325 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %324) #1
  %326 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %43, <2 x float> %323, <2 x float> %325) #1
  %327 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %30, ptr addrspace(2) readonly captures(none) %14, <2 x float> %326, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %328 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 47
  %329 = load half, ptr addrspace(2) %328, align 4, !tbaa !102, !alias.scope !79, !noalias !80
  %330 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 48
  %331 = load half, ptr addrspace(2) %330, align 2, !tbaa !103, !alias.scope !79, !noalias !80
  %332 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 26
  %333 = load <4 x half>, ptr addrspace(2) %332, align 8, !alias.scope !79, !noalias !80
  %334 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 50
  %335 = load half, ptr addrspace(2) %334, align 2, !tbaa !104, !alias.scope !79, !noalias !80
  %336 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 25
  %337 = load <4 x half>, ptr addrspace(2) %336, align 8, !alias.scope !79, !noalias !80
  %338 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 49
  %339 = load half, ptr addrspace(2) %338, align 8, !tbaa !105, !alias.scope !79, !noalias !80
  %340 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 24
  %341 = load <4 x half>, ptr addrspace(2) %340, align 8, !alias.scope !79, !noalias !80
  %342 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 51
  %343 = load half, ptr addrspace(2) %342, align 4, !tbaa !106, !alias.scope !79, !noalias !80
  %344 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %31, ptr addrspace(2) readonly captures(none) %15, <2 x float> %75, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %345 = extractvalue { <4 x half>, i8 } %344, 0
  %346 = shufflevector <4 x half> %345, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %347 = tail call fast <2 x half> @air.fma.v2f16(<2 x half> %346, <2 x half> splat (half 0xH4000), <2 x half> splat (half 0xHBC00)) #1
  %348 = shufflevector <2 x half> %347, <2 x half> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %349 = tail call fast half @air.dot.v2f16(<2 x half> %347, <2 x half> %347) #1
  %350 = tail call fast half @air.fmin.f16(half %349, half 0xH3C00) #1
  %351 = fsub fast half 0xH3C00, %350
  %352 = tail call fast half @air.sqrt.f16(half %351) #1
  %353 = insertelement <4 x half> %348, half %352, i64 2
  %354 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 60
  %355 = load <3 x half>, ptr addrspace(2) %354, align 8, !alias.scope !79, !noalias !80
  %356 = shufflevector <3 x half> %59, <3 x half> undef, <3 x i32> zeroinitializer
  %357 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %22, ptr addrspace(2) readonly captures(none) %11, <2 x float> %43, i1 true, <2 x i32> zeroinitializer, i1 false, float %62, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %358 = extractvalue { <4 x half>, i8 } %357, 0
  %359 = tail call fast <4 x half> @air.fma.v4f16(<4 x half> %358, <4 x half> splat (half 0xH4000), <4 x half> splat (half 0xHBC00)) #1
  %360 = shufflevector <4 x half> %359, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %361 = tail call fast half @air.dot.v2f16(<2 x half> %360, <2 x half> %360) #1
  %362 = tail call fast half @air.fmin.f16(half %361, half 0xH3C00) #1
  %363 = fsub fast half 0xH3C00, %362
  %364 = tail call fast half @air.sqrt.f16(half %363) #1
  %365 = shufflevector <4 x half> %359, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %366 = tail call fast half @air.dot.v2f16(<2 x half> %365, <2 x half> %365) #1
  %367 = tail call fast half @air.fmin.f16(half %366, half 0xH3C00) #1
  %368 = fsub fast half 0xH3C00, %367
  %369 = tail call fast half @air.sqrt.f16(half %368) #1
  %370 = shufflevector <4 x half> %359, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %371 = insertelement <3 x half> %370, half %364, i64 2
  %372 = shufflevector <4 x half> %353, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %373 = fsub fast <3 x half> %372, %371
  %374 = shufflevector <4 x half> %345, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %375 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %374, <3 x half> %373, <3 x half> %371) #1
  %376 = shufflevector <2 x half> %365, <2 x half> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %377 = insertelement <3 x half> %376, half %369, i64 2
  %378 = fsub fast <3 x half> %377, %375
  %379 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %356, <3 x half> %378, <3 x half> %375) #1
  %380 = shufflevector <4 x half> %37, <4 x half> undef, <4 x i32> <i32 3, i32 poison, i32 poison, i32 poison>
  %381 = shufflevector <4 x half> %380, <4 x half> %38, <4 x i32> <i32 0, i32 7, i32 poison, i32 poison>
  %382 = shufflevector <4 x half> %381, <4 x half> %39, <3 x i32> <i32 0, i32 1, i32 7>
  %383 = tail call fast half @air.dot.v3f16(<3 x half> %382, <3 x half> %382) #1
  %384 = tail call fast half @air.rsqrt.f16(half %383) #1
  %385 = insertelement <3 x half> undef, half %384, i64 0
  %386 = shufflevector <3 x half> %385, <3 x half> undef, <3 x i32> zeroinitializer
  %387 = fmul fast <3 x half> %382, %386
  %388 = shufflevector <3 x half> %379, <3 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %389 = shufflevector <4 x half> %39, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %390 = fmul fast <3 x half> %389, %388
  %391 = shufflevector <3 x half> %379, <3 x half> undef, <3 x i32> zeroinitializer
  %392 = shufflevector <4 x half> %38, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %393 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %391, <3 x half> %392, <3 x half> %390) #1
  %394 = shufflevector <3 x half> %379, <3 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %395 = shufflevector <4 x half> %37, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %396 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %394, <3 x half> %395, <3 x half> %393) #1
  %397 = tail call fast half @air.dot.v3f16(<3 x half> %396, <3 x half> %396) #1
  %398 = tail call fast half @air.rsqrt.f16(half %397) #1
  %399 = insertelement <3 x half> undef, half %398, i64 0
  %400 = shufflevector <3 x half> %399, <3 x half> undef, <3 x i32> zeroinitializer
  %401 = fmul fast <3 x half> %396, %400
  %402 = extractelement <4 x float> %40, i64 0
  %403 = insertelement <2 x float> undef, float %402, i64 0
  %404 = extractelement <4 x float> %40, i64 1
  %405 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %2, i64 0, i32 10
  %406 = load <4 x float>, ptr addrspace(2) %405, align 16, !alias.scope !107, !noalias !108
  %407 = extractelement <4 x float> %406, i64 0
  %408 = fmul fast float %404, %407
  %409 = insertelement <2 x float> %403, float %408, i64 1
  %410 = shufflevector <4 x float> %40, <4 x float> undef, <2 x i32> <i32 3, i32 3>
  %411 = fdiv fast <2 x float> %409, %410
  %412 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %411, <2 x float> splat (float 5.000000e-01), <2 x float> splat (float 5.000000e-01)) #1
  %413 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 0
  %414 = load <4 x half>, ptr addrspace(2) %413, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %415 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 1
  %416 = load <4 x half>, ptr addrspace(2) %415, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %417 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 2
  %418 = load <4 x half>, ptr addrspace(2) %417, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %419 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 3
  %420 = load <4 x half>, ptr addrspace(2) %419, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %421 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 4
  %422 = load <4 x half>, ptr addrspace(2) %421, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %423 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 5
  %424 = load <4 x half>, ptr addrspace(2) %423, align 8, !tbaa !101, !alias.scope !109, !noalias !110
  %425 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %6, i64 0, i32 0, i64 6
  %426 = load <4 x half>, ptr addrspace(2) %425, align 8, !alias.scope !109, !noalias !110
  %427 = extractelement <2 x half> %111, i64 1
  %428 = fpext half %427 to float
  %429 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 9
  %430 = load half, ptr addrspace(2) %429, align 2, !tbaa !111, !alias.scope !79, !noalias !80
  %431 = fpext half %430 to float
  %432 = fmul fast float %428, %431
  %433 = fmul fast float %432, 0x3FB47AE140000000
  %434 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %33, ptr addrspace(2) readonly captures(none) %17, <2 x float> %412, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %435 = extractvalue { <4 x half>, i8 } %434, 0
  %436 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %4, i64 0, i32 6
  %437 = load half, ptr addrspace(2) %436, align 2, !tbaa !112, !alias.scope !114, !noalias !115
  %438 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %32, ptr addrspace(2) readonly captures(none) %16, <2 x float> %412, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %439 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %401) #1
  %440 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 1
  %441 = load <4 x float>, ptr addrspace(2) %440, align 16, !alias.scope !88, !noalias !89
  %442 = shufflevector <4 x float> %441, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %443 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %442) #1
  %444 = fptrunc float %443 to half
  %445 = insertelement <3 x half> %112, half %444, i64 2
  %446 = shufflevector <3 x half> %445, <3 x half> undef, <2 x i32> <i32 0, i32 2>
  %447 = tail call fast <2 x half> @air.fmax.v2f16(<2 x half> %446, <2 x half> <half 0xH211F, half 0xH0000>) #1
  %448 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %382) #1
  %449 = fpext half %384 to float
  %450 = insertelement <3 x float> undef, float %449, i64 0
  %451 = shufflevector <3 x float> %450, <3 x float> undef, <3 x i32> zeroinitializer
  %452 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %448, <3 x float> %451, <3 x float> %442) #1
  %453 = tail call fast float @air.dot.v3f32(<3 x float> %452, <3 x float> %452) #1
  %454 = tail call fast float @air.fast_fmax.f32(float %453, float 0x3F10000000000000) #1
  %455 = tail call fast float @air.fast_rsqrt.f32(float %454) #1
  %456 = insertelement <4 x float> undef, float %455, i64 0
  %457 = shufflevector <4 x float> %456, <4 x float> undef, <3 x i32> zeroinitializer
  %458 = fmul fast <3 x float> %452, %457
  %459 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %387) #1
  %460 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %458) #1
  %461 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %4, i64 0, i32 2
  %462 = load <4 x half>, ptr addrspace(2) %461, align 8, !alias.scope !114, !noalias !115
  %463 = extractelement <2 x half> %447, i64 0
  %464 = fmul fast half %463, %463
  %465 = insertelement <2 x half> undef, half %464, i64 0
  %466 = shufflevector <2 x half> %465, <2 x half> undef, <2 x i32> zeroinitializer
  %467 = tail call fast <2 x half> @air.fmax.v2f16(<2 x half> %466, <2 x half> <half 0xH211F, half 0xH2E66>) #1
  %468 = shufflevector <2 x half> %467, <2 x half> undef, <4 x i32> <i32 poison, i32 1, i32 poison, i32 poison>
  %469 = extractelement <2 x half> %467, i64 0
  %470 = fdiv fast half 0xH3C00, %469
  %471 = fpext half %470 to float
  %472 = fpext half %469 to float
  %473 = fsub fast float %472, %471
  %474 = tail call fast float @air.fma.f32(float %460, float 5.000000e-01, float 5.000000e-01) #1
  %475 = insertelement <4 x float> undef, float %474, i64 0
  %476 = shufflevector <4 x float> %233, <4 x float> undef, <2 x i32> <i32 1, i32 3>
  %477 = shufflevector <2 x float> %476, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %478 = shufflevector <4 x float> %477, <4 x float> %248, <4 x i32> <i32 0, i32 1, i32 6, i32 7>
  %479 = shufflevector <4 x half> %180, <4 x half> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %480 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %479) #1
  %481 = shufflevector <4 x float> %475, <4 x float> undef, <4 x i32> zeroinitializer
  %482 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %478, <4 x float> %480, <4 x float> %481) #1
  %483 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %482, i32 0) #5
  %484 = fadd fast <4 x float> %483, splat (float -5.000000e-01)
  %485 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %484) #1
  %486 = tail call fast <4 x half> @air.fabs.v4f16(<4 x half> %485) #1
  %487 = fadd fast <4 x half> %486, %486
  %488 = extractelement <4 x half> %180, i64 3
  %489 = fmul fast half %488, %488
  %490 = tail call fast half @air.fmax.f16(half %489, half 0xH211F) #1
  %491 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %487) #1
  %492 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %491, <4 x float> splat (float 0x3FEFF7CEE0000000)) #1
  %493 = fmul fast <4 x float> %492, %492
  %494 = fdiv fast half 0xH3C00, %490
  %495 = fpext half %490 to float
  %496 = fpext half %494 to float
  %497 = fsub fast float %495, %496
  %498 = insertelement <4 x float> undef, float %497, i64 0
  %499 = shufflevector <4 x float> %498, <4 x float> undef, <4 x i32> zeroinitializer
  %500 = insertelement <4 x float> undef, float %496, i64 0
  %501 = shufflevector <4 x float> %500, <4 x float> undef, <4 x i32> zeroinitializer
  %502 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %493, <4 x float> %499, <4 x float> %501) #1
  %503 = fdiv fast <4 x float> splat (float 1.000000e+00), %502
  %504 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %503, <4 x float> splat (float 1.000000e+01)) #1
  %505 = fmul fast <4 x float> %504, %504
  %506 = fmul fast <4 x float> %505, splat (float 0x3FD45F3060000000)
  %507 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %315) #1
  %508 = fmul fast <4 x float> %507, %506
  %509 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %508) #1
  %510 = tail call fast half @air.dot.v4f16(<4 x half> splat (half 0xH3C00), <4 x half> %509) #1
  %511 = insertelement <3 x half> undef, half %510, i64 0
  %512 = shufflevector <3 x half> %511, <3 x half> undef, <3 x i32> zeroinitializer
  %513 = fmul fast <3 x half> %317, %512
  %514 = shufflevector <3 x half> %513, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %515 = shufflevector <4 x half> %468, <4 x half> %514, <4 x i32> <i32 4, i32 1, i32 5, i32 6>
  %516 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %4, i64 0, i32 0
  %517 = load <4 x float>, ptr addrspace(2) %516, align 16, !alias.scope !114, !noalias !115
  %518 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %4, i64 0, i32 3
  %519 = load <4 x half>, ptr addrspace(2) %518, align 16, !alias.scope !114, !noalias !115
  %520 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %387
  %521 = tail call fast half @air.dot.v3f16(<3 x half> %520, <3 x half> %401) #1
  %522 = fadd fast half %521, %521
  %523 = insertelement <3 x half> undef, half %522, i64 0
  %524 = shufflevector <3 x half> %523, <3 x half> undef, <3 x i32> zeroinitializer
  %525 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %524
  %526 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %401, <3 x half> %525, <3 x half> %520) #1
  %527 = fsub nnan ninf nsz arcp afn half 0xH8000, %463
  %528 = tail call fast half @air.fma.f16(half %527, half 0xH399A, half 0xH3ECD) #1
  %529 = fmul fast half %463, %528
  %530 = fmul fast half %529, 0xH4600
  %531 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %526) #1
  %532 = fpext half %530 to float
  %533 = tail call { <4 x half>, i8 } @air.sample_texture_cube.v4f16(ptr addrspace(1) readonly captures(none) %18, ptr addrspace(2) readonly captures(none) %7, <3 x float> %531, i1 true, float %532, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %534 = getelementptr inbounds %struct.UnityPerDraw_Type, ptr addrspace(2) %3, i64 0, i32 3
  %535 = load <4 x float>, ptr addrspace(2) %534, align 16, !alias.scope !116, !noalias !117
  %536 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %4, i64 0, i32 5
  %537 = load half, ptr addrspace(2) %536, align 16, !tbaa !118, !alias.scope !114, !noalias !115
  %538 = shufflevector <3 x float> %36, <3 x float> undef, <2 x i32> <i32 0, i32 2>
  %539 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 4
  %540 = load <4 x half>, ptr addrspace(2) %539, align 16, !alias.scope !88, !noalias !89
  %541 = shufflevector <4 x half> %540, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %542 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %541) #1
  %543 = fsub fast <2 x float> %538, %542
  %544 = shufflevector <4 x half> %540, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %545 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %544) #1
  %546 = fdiv fast <2 x float> %543, %545
  %547 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %19, ptr addrspace(2) readonly captures(none) %8, <2 x float> %546, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #4, !alias.scope !67, !noalias !71
  %548 = extractvalue { <4 x half>, i8 } %547, 0
  %549 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %548) #1
  %550 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %549, <4 x float> splat (float 2.550000e+02), <4 x float> splat (float 5.000000e-01)) #1
  %551 = tail call fast <4 x float> @air.fast_floor.v4f32(<4 x float> %550) #1
  %552 = fsub fast <4 x half> splat (half 0xH3C00), %435
  %553 = fcmp fast olt <4 x float> %551, splat (float 3.000000e+01)
  %554 = extractelement <4 x i1> %553, i64 0
  br i1 %554, label %555, label %563

555:                                              ; preds = %41
  %556 = extractelement <4 x float> %551, i64 0
  %557 = tail call i32 @air.convert.u.i32.f.f32(float %556) #1
  %558 = sext i32 %557 to i64
  %559 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %558
  %560 = load <4 x half>, ptr addrspace(2) %559, align 8, !tbaa !101, !alias.scope !119, !noalias !120
  %561 = tail call fast half @air.dot.v4f16(<4 x half> %552, <4 x half> %560) #1
  %562 = insertelement <4 x half> undef, half %561, i64 0
  br label %563

563:                                              ; preds = %555, %41
  %564 = phi <4 x half> [ %562, %555 ], [ <half 0xH3C00, half undef, half undef, half undef>, %41 ]
  %565 = extractelement <4 x i1> %553, i64 1
  br i1 %565, label %566, label %574

566:                                              ; preds = %563
  %567 = extractelement <4 x float> %551, i64 1
  %568 = tail call i32 @air.convert.u.i32.f.f32(float %567) #1
  %569 = sext i32 %568 to i64
  %570 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %569
  %571 = load <4 x half>, ptr addrspace(2) %570, align 8, !tbaa !101, !alias.scope !119, !noalias !120
  %572 = tail call fast half @air.dot.v4f16(<4 x half> %552, <4 x half> %571) #1
  %573 = insertelement <4 x half> %564, half %572, i64 1
  br label %576

574:                                              ; preds = %563
  %575 = insertelement <4 x half> %564, half 0xH3C00, i64 1
  br label %576

576:                                              ; preds = %574, %566
  %577 = phi <4 x half> [ %573, %566 ], [ %575, %574 ]
  %578 = extractelement <4 x i1> %553, i64 2
  br i1 %578, label %579, label %587

579:                                              ; preds = %576
  %580 = extractelement <4 x float> %551, i64 2
  %581 = tail call i32 @air.convert.u.i32.f.f32(float %580) #1
  %582 = sext i32 %581 to i64
  %583 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %582
  %584 = load <4 x half>, ptr addrspace(2) %583, align 8, !tbaa !101, !alias.scope !119, !noalias !120
  %585 = tail call fast half @air.dot.v4f16(<4 x half> %552, <4 x half> %584) #1
  %586 = insertelement <4 x half> %577, half %585, i64 2
  br label %589

587:                                              ; preds = %576
  %588 = insertelement <4 x half> %577, half 0xH3C00, i64 2
  br label %589

589:                                              ; preds = %587, %579
  %590 = phi <4 x half> [ %586, %579 ], [ %588, %587 ]
  %591 = extractelement <4 x i1> %553, i64 3
  br i1 %591, label %592, label %600

592:                                              ; preds = %589
  %593 = extractelement <4 x float> %551, i64 3
  %594 = tail call i32 @air.convert.u.i32.f.f32(float %593) #1
  %595 = sext i32 %594 to i64
  %596 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %595
  %597 = load <4 x half>, ptr addrspace(2) %596, align 8, !tbaa !101, !alias.scope !119, !noalias !120
  %598 = tail call fast half @air.dot.v4f16(<4 x half> %552, <4 x half> %597) #1
  %599 = insertelement <4 x half> %590, half %598, i64 3
  br label %602

600:                                              ; preds = %589
  %601 = insertelement <4 x half> %590, half 0xH3C00, i64 3
  br label %602

602:                                              ; preds = %600, %592
  %603 = phi <4 x half> [ %599, %592 ], [ %601, %600 ]
  %604 = extractelement <4 x float> %551, i64 0
  %605 = fcmp fast olt float %604, 2.550000e+02
  br i1 %605, label %606, label %1097

606:                                              ; preds = %602
  %607 = insertelement <4 x half> undef, half %437, i64 0
  %608 = shufflevector <4 x half> %607, <4 x half> undef, <4 x i32> zeroinitializer
  %609 = fsub nnan ninf nsz arcp afn <4 x half> splat (half 0xH8000), %603
  %610 = tail call fast <4 x half> @air.fma.v4f16(<4 x half> %608, <4 x half> %609, <4 x half> splat (half 0xH3C00)) #1
  %611 = extractelement <4 x half> %610, i64 0
  %612 = fcmp fast ogt half %611, 0xH1419
  br i1 %612, label %613, label %728

613:                                              ; preds = %606
  %614 = tail call i32 @air.convert.s.i32.f.f32(float %604) #1
  %615 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %36
  %616 = sext i32 %614 to i64
  %617 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %616
  %618 = load <4 x float>, ptr addrspace(2) %617, align 16, !alias.scope !119, !noalias !120
  %619 = shufflevector <4 x float> %618, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %620 = shufflevector <4 x float> %618, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %621 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %615, <3 x float> %619, <3 x float> %620) #1
  %622 = tail call fast float @air.dot.v3f32(<3 x float> %621, <3 x float> %621) #1
  %623 = tail call fast float @air.fast_fmax.f32(float %622, float 0x3810000000000000) #1
  %624 = tail call fast float @air.fast_rsqrt.f32(float %623) #1
  %625 = insertelement <3 x float> undef, float %624, i64 0
  %626 = shufflevector <3 x float> %625, <3 x float> undef, <3 x i32> zeroinitializer
  %627 = fmul fast <3 x float> %621, %626
  %628 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %616
  %629 = load <4 x half>, ptr addrspace(2) %628, align 8, !alias.scope !119, !noalias !120
  %630 = extractelement <4 x half> %629, i64 0
  %631 = fpext half %630 to float
  %632 = tail call fast float @air.fma.f32(float %623, float %631, float 1.000000e+00) #1
  %633 = extractelement <4 x half> %629, i64 1
  %634 = fpext half %633 to float
  %635 = extractelement <4 x half> %629, i64 2
  %636 = fpext half %635 to float
  %637 = tail call fast float @air.fma.f32(float %623, float %634, float %636) #1
  %638 = tail call fast float @air.fast_clamp.f32(float %637, float 0.000000e+00, float 1.000000e+00) #1
  %639 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %616
  %640 = load <4 x float>, ptr addrspace(2) %639, align 16, !alias.scope !119, !noalias !120
  %641 = shufflevector <4 x float> %640, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %642 = tail call fast float @air.dot.v3f32(<3 x float> %641, <3 x float> %627) #1
  %643 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %616
  %644 = load <4 x float>, ptr addrspace(2) %643, align 16, !alias.scope !119, !noalias !120
  %645 = extractelement <4 x float> %644, i64 0
  %646 = extractelement <4 x float> %644, i64 1
  %647 = tail call fast float @air.fma.f32(float %642, float %645, float %646) #1
  %648 = tail call fast float @air.fast_clamp.f32(float %647, float 0.000000e+00, float 1.000000e+00) #1
  %649 = fmul fast float %648, %648
  %650 = fmul fast float %638, %649
  %651 = fdiv fast float %650, %632
  %652 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %627) #1
  %653 = fptrunc float %652 to half
  %654 = tail call fast half @air.fmax.f16(half %653, half 0xH0000) #1
  %655 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %621, <3 x float> %626, <3 x float> %459) #1
  %656 = tail call fast float @air.dot.v3f32(<3 x float> %655, <3 x float> %655) #1
  %657 = tail call fast float @air.fast_fmax.f32(float %656, float 0x3F10000000000000) #1
  %658 = tail call fast float @air.fast_rsqrt.f32(float %657) #1
  %659 = insertelement <3 x float> undef, float %658, i64 0
  %660 = shufflevector <3 x float> %659, <3 x float> undef, <3 x i32> zeroinitializer
  %661 = fmul fast <3 x float> %655, %660
  %662 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %661) #1
  %663 = tail call fast float @air.fast_fmax.f32(float %662, float 0.000000e+00) #1
  %664 = insertelement <3 x half> undef, half %654, i64 0
  %665 = shufflevector <3 x half> %664, <3 x half> undef, <3 x i32> zeroinitializer
  %666 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %616
  %667 = load <4 x half>, ptr addrspace(2) %666, align 8, !alias.scope !119, !noalias !120
  %668 = shufflevector <4 x half> %667, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %669 = fmul fast <3 x half> %665, %668
  %670 = insertelement <3 x float> undef, float %651, i64 0
  %671 = shufflevector <3 x float> %670, <3 x float> undef, <3 x i32> zeroinitializer
  %672 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %669) #1
  %673 = fmul fast <3 x float> %671, %672
  %674 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %673) #1
  %675 = fcmp fast ogt half %654, 0xH0000
  %676 = tail call fast half @air.fma.f16(half %463, half 0xH3400, half 0xH3400) #1
  %677 = tail call fast float @air.fast_fmin.f32(float %663, float 0x3FEFF7CEE0000000) #1
  %678 = fmul fast float %677, %677
  %679 = tail call fast float @air.fma.f32(float %678, float %473, float %471) #1
  %680 = fdiv fast float 1.000000e+00, %679
  %681 = tail call fast float @air.fast_fmin.f32(float %680, float 1.000000e+01) #1
  %682 = fmul fast float %681, %681
  %683 = fmul fast float %682, 0x3FD45F3060000000
  %684 = fpext half %676 to float
  %685 = fmul fast float %683, %684
  %686 = fptrunc float %685 to half
  %687 = fpext half %686 to float
  %688 = fmul fast float %433, %687
  %689 = fptrunc float %688 to half
  %690 = insertelement <3 x half> undef, half %689, i64 0
  %691 = shufflevector <3 x half> %690, <3 x half> undef, <3 x i32> zeroinitializer
  %692 = fmul fast <3 x half> %674, %691
  %693 = select fast i1 %675, <3 x half> %692, <3 x half> zeroinitializer
  %694 = extractelement <4 x half> %667, i64 3
  %695 = fcmp fast oeq half %694, 0xHBC00
  br i1 %695, label %696, label %723

696:                                              ; preds = %613
  %697 = tail call fast float @air.fma.f32(float %662, float 5.000000e-01, float 5.000000e-01) #1
  %698 = insertelement <4 x float> undef, float %697, i64 0
  %699 = shufflevector <4 x float> %698, <4 x float> undef, <4 x i32> zeroinitializer
  %700 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %478, <4 x float> %480, <4 x float> %699) #1
  %701 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %700, i32 0) #5
  %702 = fadd fast <4 x float> %701, splat (float -5.000000e-01)
  %703 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %702) #1
  %704 = tail call fast <4 x half> @air.fabs.v4f16(<4 x half> %703) #1
  %705 = fadd fast <4 x half> %704, %704
  %706 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %705) #1
  %707 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %706, <4 x float> splat (float 0x3FEFF7CEE0000000)) #1
  %708 = fmul fast <4 x float> %707, %707
  %709 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %708, <4 x float> %499, <4 x float> %501) #1
  %710 = fdiv fast <4 x float> splat (float 1.000000e+00), %709
  %711 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %710, <4 x float> splat (float 1.000000e+01)) #1
  %712 = fmul fast <4 x float> %711, %711
  %713 = fmul fast <4 x float> %712, splat (float 0x3FD45F3060000000)
  %714 = fmul fast <4 x float> %507, %713
  %715 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %714) #1
  %716 = tail call fast half @air.dot.v4f16(<4 x half> splat (half 0xH3C00), <4 x half> %715) #1
  %717 = insertelement <3 x half> undef, half %716, i64 0
  %718 = shufflevector <3 x half> %717, <3 x half> undef, <3 x i32> zeroinitializer
  %719 = fmul fast <3 x half> %317, %718
  %720 = shufflevector <3 x half> %719, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %721 = shufflevector <4 x half> %720, <4 x half> %515, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  %722 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %719, <3 x half> %668, <3 x half> %693) #1
  br label %723

723:                                              ; preds = %696, %613
  %724 = phi <4 x half> [ %721, %696 ], [ %515, %613 ]
  %725 = phi <3 x half> [ %722, %696 ], [ %693, %613 ]
  %726 = shufflevector <4 x half> %610, <4 x half> undef, <3 x i32> zeroinitializer
  %727 = fmul fast <3 x half> %726, %725
  br label %728

728:                                              ; preds = %723, %606
  %729 = phi <4 x half> [ %724, %723 ], [ %515, %606 ]
  %730 = phi <3 x half> [ %727, %723 ], [ zeroinitializer, %606 ]
  %731 = extractelement <4 x float> %551, i64 1
  %732 = fcmp fast olt float %731, 2.550000e+02
  br i1 %732, label %733, label %1097

733:                                              ; preds = %728
  %734 = extractelement <4 x half> %610, i64 1
  %735 = fcmp fast ogt half %734, 0xH1419
  br i1 %735, label %736, label %853

736:                                              ; preds = %733
  %737 = tail call i32 @air.convert.s.i32.f.f32(float %731) #1
  %738 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %36
  %739 = sext i32 %737 to i64
  %740 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %739
  %741 = load <4 x float>, ptr addrspace(2) %740, align 16, !alias.scope !119, !noalias !120
  %742 = shufflevector <4 x float> %741, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %743 = shufflevector <4 x float> %741, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %744 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %738, <3 x float> %742, <3 x float> %743) #1
  %745 = tail call fast float @air.dot.v3f32(<3 x float> %744, <3 x float> %744) #1
  %746 = tail call fast float @air.fast_fmax.f32(float %745, float 0x3810000000000000) #1
  %747 = tail call fast float @air.fast_rsqrt.f32(float %746) #1
  %748 = insertelement <3 x float> undef, float %747, i64 0
  %749 = shufflevector <3 x float> %748, <3 x float> undef, <3 x i32> zeroinitializer
  %750 = fmul fast <3 x float> %744, %749
  %751 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %739
  %752 = load <4 x half>, ptr addrspace(2) %751, align 8, !alias.scope !119, !noalias !120
  %753 = extractelement <4 x half> %752, i64 0
  %754 = fpext half %753 to float
  %755 = tail call fast float @air.fma.f32(float %746, float %754, float 1.000000e+00) #1
  %756 = extractelement <4 x half> %752, i64 1
  %757 = fpext half %756 to float
  %758 = extractelement <4 x half> %752, i64 2
  %759 = fpext half %758 to float
  %760 = tail call fast float @air.fma.f32(float %746, float %757, float %759) #1
  %761 = tail call fast float @air.fast_clamp.f32(float %760, float 0.000000e+00, float 1.000000e+00) #1
  %762 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %739
  %763 = load <4 x float>, ptr addrspace(2) %762, align 16, !alias.scope !119, !noalias !120
  %764 = shufflevector <4 x float> %763, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %765 = tail call fast float @air.dot.v3f32(<3 x float> %764, <3 x float> %750) #1
  %766 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %739
  %767 = load <4 x float>, ptr addrspace(2) %766, align 16, !alias.scope !119, !noalias !120
  %768 = extractelement <4 x float> %767, i64 0
  %769 = extractelement <4 x float> %767, i64 1
  %770 = tail call fast float @air.fma.f32(float %765, float %768, float %769) #1
  %771 = tail call fast float @air.fast_clamp.f32(float %770, float 0.000000e+00, float 1.000000e+00) #1
  %772 = fmul fast float %771, %771
  %773 = fmul fast float %761, %772
  %774 = fdiv fast float %773, %755
  %775 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %750) #1
  %776 = fptrunc float %775 to half
  %777 = tail call fast half @air.fmax.f16(half %776, half 0xH0000) #1
  %778 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %744, <3 x float> %749, <3 x float> %459) #1
  %779 = tail call fast float @air.dot.v3f32(<3 x float> %778, <3 x float> %778) #1
  %780 = tail call fast float @air.fast_fmax.f32(float %779, float 0x3F10000000000000) #1
  %781 = tail call fast float @air.fast_rsqrt.f32(float %780) #1
  %782 = insertelement <3 x float> undef, float %781, i64 0
  %783 = shufflevector <3 x float> %782, <3 x float> undef, <3 x i32> zeroinitializer
  %784 = fmul fast <3 x float> %778, %783
  %785 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %784) #1
  %786 = tail call fast float @air.fast_fmax.f32(float %785, float 0.000000e+00) #1
  %787 = insertelement <3 x half> undef, half %777, i64 0
  %788 = shufflevector <3 x half> %787, <3 x half> undef, <3 x i32> zeroinitializer
  %789 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %739
  %790 = load <4 x half>, ptr addrspace(2) %789, align 8, !alias.scope !119, !noalias !120
  %791 = shufflevector <4 x half> %790, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %792 = fmul fast <3 x half> %788, %791
  %793 = insertelement <3 x float> undef, float %774, i64 0
  %794 = shufflevector <3 x float> %793, <3 x float> undef, <3 x i32> zeroinitializer
  %795 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %792) #1
  %796 = fmul fast <3 x float> %794, %795
  %797 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %796) #1
  %798 = fcmp fast ogt half %777, 0xH0000
  %799 = tail call fast half @air.fma.f16(half %463, half 0xH3400, half 0xH3400) #1
  %800 = tail call fast float @air.fast_fmin.f32(float %786, float 0x3FEFF7CEE0000000) #1
  %801 = fmul fast float %800, %800
  %802 = tail call fast float @air.fma.f32(float %801, float %473, float %471) #1
  %803 = fdiv fast float 1.000000e+00, %802
  %804 = tail call fast float @air.fast_fmin.f32(float %803, float 1.000000e+01) #1
  %805 = fmul fast float %804, %804
  %806 = fmul fast float %805, 0x3FD45F3060000000
  %807 = fpext half %799 to float
  %808 = fmul fast float %806, %807
  %809 = fptrunc float %808 to half
  %810 = fpext half %809 to float
  %811 = fmul fast float %433, %810
  %812 = fptrunc float %811 to half
  %813 = insertelement <3 x half> undef, half %812, i64 0
  %814 = shufflevector <3 x half> %813, <3 x half> undef, <3 x i32> zeroinitializer
  %815 = fmul fast <3 x half> %797, %814
  %816 = select fast i1 %798, <3 x half> %815, <3 x half> zeroinitializer
  %817 = shufflevector <3 x half> %816, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %818 = shufflevector <4 x half> %817, <4 x half> %729, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  %819 = extractelement <4 x half> %790, i64 3
  %820 = fcmp fast oeq half %819, 0xHBC00
  br i1 %820, label %821, label %848

821:                                              ; preds = %736
  %822 = tail call fast float @air.fma.f32(float %785, float 5.000000e-01, float 5.000000e-01) #1
  %823 = insertelement <4 x float> undef, float %822, i64 0
  %824 = shufflevector <4 x float> %823, <4 x float> undef, <4 x i32> zeroinitializer
  %825 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %478, <4 x float> %480, <4 x float> %824) #1
  %826 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %825, i32 0) #5
  %827 = fadd fast <4 x float> %826, splat (float -5.000000e-01)
  %828 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %827) #1
  %829 = tail call fast <4 x half> @air.fabs.v4f16(<4 x half> %828) #1
  %830 = fadd fast <4 x half> %829, %829
  %831 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %830) #1
  %832 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %831, <4 x float> splat (float 0x3FEFF7CEE0000000)) #1
  %833 = fmul fast <4 x float> %832, %832
  %834 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %833, <4 x float> %499, <4 x float> %501) #1
  %835 = fdiv fast <4 x float> splat (float 1.000000e+00), %834
  %836 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %835, <4 x float> splat (float 1.000000e+01)) #1
  %837 = fmul fast <4 x float> %836, %836
  %838 = fmul fast <4 x float> %837, splat (float 0x3FD45F3060000000)
  %839 = fmul fast <4 x float> %507, %838
  %840 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %839) #1
  %841 = tail call fast half @air.dot.v4f16(<4 x half> splat (half 0xH3C00), <4 x half> %840) #1
  %842 = insertelement <3 x half> undef, half %841, i64 0
  %843 = shufflevector <3 x half> %842, <3 x half> undef, <3 x i32> zeroinitializer
  %844 = fmul fast <3 x half> %317, %843
  %845 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %844, <3 x half> %791, <3 x half> %816) #1
  %846 = shufflevector <3 x half> %845, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %847 = shufflevector <4 x half> %846, <4 x half> %818, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %848

848:                                              ; preds = %821, %736
  %849 = phi <4 x half> [ %847, %821 ], [ %818, %736 ]
  %850 = shufflevector <4 x half> %849, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %851 = shufflevector <4 x half> %610, <4 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %852 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %850, <3 x half> %851, <3 x half> %730) #1
  br label %853

853:                                              ; preds = %848, %733
  %854 = phi <4 x half> [ %849, %848 ], [ %729, %733 ]
  %855 = phi <3 x half> [ %852, %848 ], [ %730, %733 ]
  %856 = extractelement <4 x float> %551, i64 2
  %857 = fcmp fast olt float %856, 2.550000e+02
  br i1 %857, label %858, label %1097

858:                                              ; preds = %853
  %859 = extractelement <4 x half> %610, i64 2
  %860 = fcmp fast ogt half %859, 0xH1419
  br i1 %860, label %861, label %978

861:                                              ; preds = %858
  %862 = tail call i32 @air.convert.s.i32.f.f32(float %856) #1
  %863 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %36
  %864 = sext i32 %862 to i64
  %865 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %864
  %866 = load <4 x float>, ptr addrspace(2) %865, align 16, !alias.scope !119, !noalias !120
  %867 = shufflevector <4 x float> %866, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %868 = shufflevector <4 x float> %866, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %869 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %863, <3 x float> %867, <3 x float> %868) #1
  %870 = tail call fast float @air.dot.v3f32(<3 x float> %869, <3 x float> %869) #1
  %871 = tail call fast float @air.fast_fmax.f32(float %870, float 0x3810000000000000) #1
  %872 = tail call fast float @air.fast_rsqrt.f32(float %871) #1
  %873 = insertelement <3 x float> undef, float %872, i64 0
  %874 = shufflevector <3 x float> %873, <3 x float> undef, <3 x i32> zeroinitializer
  %875 = fmul fast <3 x float> %869, %874
  %876 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %864
  %877 = load <4 x half>, ptr addrspace(2) %876, align 8, !alias.scope !119, !noalias !120
  %878 = extractelement <4 x half> %877, i64 0
  %879 = fpext half %878 to float
  %880 = tail call fast float @air.fma.f32(float %871, float %879, float 1.000000e+00) #1
  %881 = extractelement <4 x half> %877, i64 1
  %882 = fpext half %881 to float
  %883 = extractelement <4 x half> %877, i64 2
  %884 = fpext half %883 to float
  %885 = tail call fast float @air.fma.f32(float %871, float %882, float %884) #1
  %886 = tail call fast float @air.fast_clamp.f32(float %885, float 0.000000e+00, float 1.000000e+00) #1
  %887 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %864
  %888 = load <4 x float>, ptr addrspace(2) %887, align 16, !alias.scope !119, !noalias !120
  %889 = shufflevector <4 x float> %888, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %890 = tail call fast float @air.dot.v3f32(<3 x float> %889, <3 x float> %875) #1
  %891 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %864
  %892 = load <4 x float>, ptr addrspace(2) %891, align 16, !alias.scope !119, !noalias !120
  %893 = extractelement <4 x float> %892, i64 0
  %894 = extractelement <4 x float> %892, i64 1
  %895 = tail call fast float @air.fma.f32(float %890, float %893, float %894) #1
  %896 = tail call fast float @air.fast_clamp.f32(float %895, float 0.000000e+00, float 1.000000e+00) #1
  %897 = fmul fast float %896, %896
  %898 = fmul fast float %886, %897
  %899 = fdiv fast float %898, %880
  %900 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %875) #1
  %901 = fptrunc float %900 to half
  %902 = tail call fast half @air.fmax.f16(half %901, half 0xH0000) #1
  %903 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %869, <3 x float> %874, <3 x float> %459) #1
  %904 = tail call fast float @air.dot.v3f32(<3 x float> %903, <3 x float> %903) #1
  %905 = tail call fast float @air.fast_fmax.f32(float %904, float 0x3F10000000000000) #1
  %906 = tail call fast float @air.fast_rsqrt.f32(float %905) #1
  %907 = insertelement <3 x float> undef, float %906, i64 0
  %908 = shufflevector <3 x float> %907, <3 x float> undef, <3 x i32> zeroinitializer
  %909 = fmul fast <3 x float> %903, %908
  %910 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %909) #1
  %911 = tail call fast float @air.fast_fmax.f32(float %910, float 0.000000e+00) #1
  %912 = insertelement <3 x half> undef, half %902, i64 0
  %913 = shufflevector <3 x half> %912, <3 x half> undef, <3 x i32> zeroinitializer
  %914 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %864
  %915 = load <4 x half>, ptr addrspace(2) %914, align 8, !alias.scope !119, !noalias !120
  %916 = shufflevector <4 x half> %915, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %917 = fmul fast <3 x half> %913, %916
  %918 = insertelement <3 x float> undef, float %899, i64 0
  %919 = shufflevector <3 x float> %918, <3 x float> undef, <3 x i32> zeroinitializer
  %920 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %917) #1
  %921 = fmul fast <3 x float> %919, %920
  %922 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %921) #1
  %923 = fcmp fast ogt half %902, 0xH0000
  %924 = tail call fast half @air.fma.f16(half %463, half 0xH3400, half 0xH3400) #1
  %925 = tail call fast float @air.fast_fmin.f32(float %911, float 0x3FEFF7CEE0000000) #1
  %926 = fmul fast float %925, %925
  %927 = tail call fast float @air.fma.f32(float %926, float %473, float %471) #1
  %928 = fdiv fast float 1.000000e+00, %927
  %929 = tail call fast float @air.fast_fmin.f32(float %928, float 1.000000e+01) #1
  %930 = fmul fast float %929, %929
  %931 = fmul fast float %930, 0x3FD45F3060000000
  %932 = fpext half %924 to float
  %933 = fmul fast float %931, %932
  %934 = fptrunc float %933 to half
  %935 = fpext half %934 to float
  %936 = fmul fast float %433, %935
  %937 = fptrunc float %936 to half
  %938 = insertelement <3 x half> undef, half %937, i64 0
  %939 = shufflevector <3 x half> %938, <3 x half> undef, <3 x i32> zeroinitializer
  %940 = fmul fast <3 x half> %922, %939
  %941 = select fast i1 %923, <3 x half> %940, <3 x half> zeroinitializer
  %942 = shufflevector <3 x half> %941, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %943 = shufflevector <4 x half> %942, <4 x half> %854, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  %944 = extractelement <4 x half> %915, i64 3
  %945 = fcmp fast oeq half %944, 0xHBC00
  br i1 %945, label %946, label %973

946:                                              ; preds = %861
  %947 = tail call fast float @air.fma.f32(float %910, float 5.000000e-01, float 5.000000e-01) #1
  %948 = insertelement <4 x float> undef, float %947, i64 0
  %949 = shufflevector <4 x float> %948, <4 x float> undef, <4 x i32> zeroinitializer
  %950 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %478, <4 x float> %480, <4 x float> %949) #1
  %951 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %950, i32 0) #5
  %952 = fadd fast <4 x float> %951, splat (float -5.000000e-01)
  %953 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %952) #1
  %954 = tail call fast <4 x half> @air.fabs.v4f16(<4 x half> %953) #1
  %955 = fadd fast <4 x half> %954, %954
  %956 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %955) #1
  %957 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %956, <4 x float> splat (float 0x3FEFF7CEE0000000)) #1
  %958 = fmul fast <4 x float> %957, %957
  %959 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %958, <4 x float> %499, <4 x float> %501) #1
  %960 = fdiv fast <4 x float> splat (float 1.000000e+00), %959
  %961 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %960, <4 x float> splat (float 1.000000e+01)) #1
  %962 = fmul fast <4 x float> %961, %961
  %963 = fmul fast <4 x float> %962, splat (float 0x3FD45F3060000000)
  %964 = fmul fast <4 x float> %507, %963
  %965 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %964) #1
  %966 = tail call fast half @air.dot.v4f16(<4 x half> splat (half 0xH3C00), <4 x half> %965) #1
  %967 = insertelement <3 x half> undef, half %966, i64 0
  %968 = shufflevector <3 x half> %967, <3 x half> undef, <3 x i32> zeroinitializer
  %969 = fmul fast <3 x half> %317, %968
  %970 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %969, <3 x half> %916, <3 x half> %941) #1
  %971 = shufflevector <3 x half> %970, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %972 = shufflevector <4 x half> %971, <4 x half> %943, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %973

973:                                              ; preds = %946, %861
  %974 = phi <4 x half> [ %972, %946 ], [ %943, %861 ]
  %975 = shufflevector <4 x half> %974, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %976 = shufflevector <4 x half> %610, <4 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %977 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %975, <3 x half> %976, <3 x half> %855) #1
  br label %978

978:                                              ; preds = %973, %858
  %979 = phi <3 x half> [ %977, %973 ], [ %855, %858 ]
  %980 = extractelement <4 x float> %551, i64 3
  %981 = fcmp fast olt float %980, 2.550000e+02
  %982 = extractelement <4 x half> %610, i64 3
  %983 = fcmp fast ogt half %982, 0xH1419
  %984 = select i1 %981, i1 %983, i1 false
  br i1 %984, label %985, label %1097

985:                                              ; preds = %978
  %986 = tail call i32 @air.convert.s.i32.f.f32(float %980) #1
  %987 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %36
  %988 = sext i32 %986 to i64
  %989 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %988
  %990 = load <4 x float>, ptr addrspace(2) %989, align 16, !alias.scope !119, !noalias !120
  %991 = shufflevector <4 x float> %990, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %992 = shufflevector <4 x float> %990, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %993 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %987, <3 x float> %991, <3 x float> %992) #1
  %994 = tail call fast float @air.dot.v3f32(<3 x float> %993, <3 x float> %993) #1
  %995 = tail call fast float @air.fast_fmax.f32(float %994, float 0x3810000000000000) #1
  %996 = tail call fast float @air.fast_rsqrt.f32(float %995) #1
  %997 = insertelement <3 x float> undef, float %996, i64 0
  %998 = shufflevector <3 x float> %997, <3 x float> undef, <3 x i32> zeroinitializer
  %999 = fmul fast <3 x float> %993, %998
  %1000 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %988
  %1001 = load <4 x half>, ptr addrspace(2) %1000, align 8, !alias.scope !119, !noalias !120
  %1002 = extractelement <4 x half> %1001, i64 0
  %1003 = fpext half %1002 to float
  %1004 = tail call fast float @air.fma.f32(float %995, float %1003, float 1.000000e+00) #1
  %1005 = extractelement <4 x half> %1001, i64 1
  %1006 = fpext half %1005 to float
  %1007 = extractelement <4 x half> %1001, i64 2
  %1008 = fpext half %1007 to float
  %1009 = tail call fast float @air.fma.f32(float %995, float %1006, float %1008) #1
  %1010 = tail call fast float @air.fast_clamp.f32(float %1009, float 0.000000e+00, float 1.000000e+00) #1
  %1011 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %988
  %1012 = load <4 x float>, ptr addrspace(2) %1011, align 16, !alias.scope !119, !noalias !120
  %1013 = shufflevector <4 x float> %1012, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1014 = tail call fast float @air.dot.v3f32(<3 x float> %1013, <3 x float> %999) #1
  %1015 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %988
  %1016 = load <4 x float>, ptr addrspace(2) %1015, align 16, !alias.scope !119, !noalias !120
  %1017 = extractelement <4 x float> %1016, i64 0
  %1018 = extractelement <4 x float> %1016, i64 1
  %1019 = tail call fast float @air.fma.f32(float %1014, float %1017, float %1018) #1
  %1020 = tail call fast float @air.fast_clamp.f32(float %1019, float 0.000000e+00, float 1.000000e+00) #1
  %1021 = fmul fast float %1020, %1020
  %1022 = fmul fast float %1010, %1021
  %1023 = fdiv fast float %1022, %1004
  %1024 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %999) #1
  %1025 = fptrunc float %1024 to half
  %1026 = tail call fast half @air.fmax.f16(half %1025, half 0xH0000) #1
  %1027 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %993, <3 x float> %998, <3 x float> %459) #1
  %1028 = tail call fast float @air.dot.v3f32(<3 x float> %1027, <3 x float> %1027) #1
  %1029 = tail call fast float @air.fast_fmax.f32(float %1028, float 0x3F10000000000000) #1
  %1030 = tail call fast float @air.fast_rsqrt.f32(float %1029) #1
  %1031 = insertelement <3 x float> undef, float %1030, i64 0
  %1032 = shufflevector <3 x float> %1031, <3 x float> undef, <3 x i32> zeroinitializer
  %1033 = fmul fast <3 x float> %1027, %1032
  %1034 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %1033) #1
  %1035 = tail call fast float @air.fast_fmax.f32(float %1034, float 0.000000e+00) #1
  %1036 = insertelement <3 x half> undef, half %1026, i64 0
  %1037 = shufflevector <3 x half> %1036, <3 x half> undef, <3 x i32> zeroinitializer
  %1038 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %988
  %1039 = load <4 x half>, ptr addrspace(2) %1038, align 8, !alias.scope !119, !noalias !120
  %1040 = shufflevector <4 x half> %1039, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1041 = fmul fast <3 x half> %1037, %1040
  %1042 = insertelement <3 x float> undef, float %1023, i64 0
  %1043 = shufflevector <3 x float> %1042, <3 x float> undef, <3 x i32> zeroinitializer
  %1044 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1041) #1
  %1045 = fmul fast <3 x float> %1043, %1044
  %1046 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %1045) #1
  %1047 = fcmp fast ogt half %1026, 0xH0000
  %1048 = tail call fast half @air.fma.f16(half %463, half 0xH3400, half 0xH3400) #1
  %1049 = tail call fast float @air.fast_fmin.f32(float %1035, float 0x3FEFF7CEE0000000) #1
  %1050 = fmul fast float %1049, %1049
  %1051 = tail call fast float @air.fma.f32(float %1050, float %473, float %471) #1
  %1052 = fdiv fast float 1.000000e+00, %1051
  %1053 = tail call fast float @air.fast_fmin.f32(float %1052, float 1.000000e+01) #1
  %1054 = fmul fast float %1053, %1053
  %1055 = fmul fast float %1054, 0x3FD45F3060000000
  %1056 = fpext half %1048 to float
  %1057 = fmul fast float %1055, %1056
  %1058 = fptrunc float %1057 to half
  %1059 = fpext half %1058 to float
  %1060 = fmul fast float %433, %1059
  %1061 = fptrunc float %1060 to half
  %1062 = insertelement <3 x half> undef, half %1061, i64 0
  %1063 = shufflevector <3 x half> %1062, <3 x half> undef, <3 x i32> zeroinitializer
  %1064 = fmul fast <3 x half> %1046, %1063
  %1065 = select fast i1 %1047, <3 x half> %1064, <3 x half> zeroinitializer
  %1066 = extractelement <4 x half> %1039, i64 3
  %1067 = fcmp fast oeq half %1066, 0xHBC00
  br i1 %1067, label %1068, label %1093

1068:                                             ; preds = %985
  %1069 = tail call fast float @air.fma.f32(float %1034, float 5.000000e-01, float 5.000000e-01) #1
  %1070 = insertelement <4 x float> undef, float %1069, i64 0
  %1071 = shufflevector <4 x float> %1070, <4 x float> undef, <4 x i32> zeroinitializer
  %1072 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %478, <4 x float> %480, <4 x float> %1071) #1
  %1073 = tail call fast fastcc <4 x float> @___metal_fract_v4float(<4 x float> %1072, i32 0) #5
  %1074 = fadd fast <4 x float> %1073, splat (float -5.000000e-01)
  %1075 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %1074) #1
  %1076 = tail call fast <4 x half> @air.fabs.v4f16(<4 x half> %1075) #1
  %1077 = fadd fast <4 x half> %1076, %1076
  %1078 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %1077) #1
  %1079 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %1078, <4 x float> splat (float 0x3FEFF7CEE0000000)) #1
  %1080 = fmul fast <4 x float> %1079, %1079
  %1081 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %1080, <4 x float> %499, <4 x float> %501) #1
  %1082 = fdiv fast <4 x float> splat (float 1.000000e+00), %1081
  %1083 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %1082, <4 x float> splat (float 1.000000e+01)) #1
  %1084 = fmul fast <4 x float> %1083, %1083
  %1085 = fmul fast <4 x float> %1084, splat (float 0x3FD45F3060000000)
  %1086 = fmul fast <4 x float> %507, %1085
  %1087 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %1086) #1
  %1088 = tail call fast half @air.dot.v4f16(<4 x half> splat (half 0xH3C00), <4 x half> %1087) #1
  %1089 = insertelement <3 x half> undef, half %1088, i64 0
  %1090 = shufflevector <3 x half> %1089, <3 x half> undef, <3 x i32> zeroinitializer
  %1091 = fmul fast <3 x half> %317, %1090
  %1092 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1091, <3 x half> %1040, <3 x half> %1065) #1
  br label %1093

1093:                                             ; preds = %1068, %985
  %1094 = phi <3 x half> [ %1092, %1068 ], [ %1065, %985 ]
  %1095 = shufflevector <4 x half> %610, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %1096 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1094, <3 x half> %1095, <3 x half> %979) #1
  br label %1097

1097:                                             ; preds = %1093, %978, %853, %728, %602
  %1098 = phi <3 x half> [ %1096, %1093 ], [ %979, %978 ], [ %855, %853 ], [ %730, %728 ], [ zeroinitializer, %602 ]
  %1099 = shufflevector <4 x half> %337, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1100 = insertelement <3 x half> undef, half %339, i64 0
  %1101 = shufflevector <3 x half> %1100, <3 x half> undef, <3 x i32> zeroinitializer
  %1102 = fmul fast <3 x half> %1099, %1101
  %1103 = extractvalue { <4 x half>, i8 } %327, 0
  %1104 = extractelement <4 x half> %1103, i64 0
  %1105 = fsub nnan ninf nsz arcp afn half 0xH8000, %329
  %1106 = tail call fast half @air.fma.f16(half %1104, half 0xH5BF8, half %1105) #1
  %1107 = tail call fast half @air.fabs.f16(half %1106) #1
  %1108 = fcmp fast oge half %331, %1107
  %1109 = extractelement <4 x half> %1103, i64 1
  %1110 = select fast i1 %1108, half %1109, half 0xH0000
  %1111 = insertelement <3 x half> undef, half %1110, i64 0
  %1112 = shufflevector <3 x half> %1111, <3 x half> undef, <3 x i32> zeroinitializer
  %1113 = shufflevector <4 x half> %1103, <4 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %1114 = shufflevector <4 x half> %333, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1115 = fmul fast <3 x half> %1113, %1114
  %1116 = shufflevector <4 x half> %319, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %1117 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %1116) #1
  %1118 = fsub fast <2 x float> %1117, %43
  %1119 = tail call fast float @air.dot.v2f32(<2 x float> %1118, <2 x float> %1118) #1
  %1120 = tail call fast float @air.fast_sqrt.f32(float %1119) #1
  %1121 = extractelement <4 x half> %319, i64 2
  %1122 = fpext half %1121 to float
  %1123 = fsub fast float %1120, %1122
  %1124 = fptrunc float %1123 to half
  %1125 = tail call fast half @air.fabs.f16(half %1124) #1
  %1126 = fsub fast half %335, %1125
  %1127 = fdiv fast half %1126, %335
  %1128 = tail call fast half @air.clamp.f16(half %1127, half 0xH0000, half 0xH3C00) #1
  %1129 = fmul fast half %1128, %1128
  %1130 = tail call fast half @air.fma.f16(half %1128, half 0xHC000, half 0xH4200) #1
  %1131 = fmul fast half %1129, %1130
  %1132 = insertelement <3 x half> undef, half %1131, i64 0
  %1133 = shufflevector <3 x half> %1132, <3 x half> undef, <3 x i32> zeroinitializer
  %1134 = shufflevector <4 x half> %341, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1135 = insertelement <3 x half> undef, half %343, i64 0
  %1136 = shufflevector <3 x half> %1135, <3 x half> undef, <3 x i32> zeroinitializer
  %1137 = fmul fast <3 x half> %1134, %1136
  %1138 = extractvalue { <4 x half>, i8 } %136, 0
  %1139 = extractelement <4 x half> %1138, i64 3
  %1140 = fmul fast half %1139, %144
  %1141 = insertelement <3 x half> undef, half %1140, i64 0
  %1142 = shufflevector <3 x half> %1141, <3 x half> undef, <3 x i32> zeroinitializer
  %1143 = shufflevector <4 x half> %1138, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1144 = fmul fast <3 x half> %1143, %142
  %1145 = extractvalue { <4 x half>, i8 } %133, 0
  %1146 = extractelement <4 x half> %1145, i64 3
  %1147 = fmul fast half %1146, %140
  %1148 = insertelement <3 x half> undef, half %1147, i64 0
  %1149 = shufflevector <3 x half> %1148, <3 x half> undef, <3 x i32> zeroinitializer
  %1150 = shufflevector <4 x half> %1145, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1151 = fmul fast <3 x half> %1150, %138
  %1152 = fmul fast half %99, %101
  %1153 = insertelement <3 x half> undef, half %1152, i64 0
  %1154 = shufflevector <3 x half> %1153, <3 x half> undef, <3 x i32> zeroinitializer
  %1155 = shufflevector <4 x half> %96, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1156 = fmul fast <3 x half> %98, %1155
  %1157 = extractvalue { <4 x half>, i8 } %83, 0
  %1158 = extractelement <4 x half> %1157, i64 3
  %1159 = fmul fast half %1158, %87
  %1160 = insertelement <3 x half> undef, half %1159, i64 0
  %1161 = shufflevector <3 x half> %1160, <3 x half> undef, <3 x i32> zeroinitializer
  %1162 = shufflevector <4 x half> %1157, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1163 = fmul fast <3 x half> %85, %1162
  %1164 = extractvalue { <4 x half>, i8 } %76, 0
  %1165 = extractelement <4 x half> %1164, i64 3
  %1166 = fmul fast half %1165, %80
  %1167 = insertelement <3 x half> undef, half %1166, i64 0
  %1168 = shufflevector <3 x half> %1167, <3 x half> undef, <3 x i32> zeroinitializer
  %1169 = shufflevector <4 x half> %1164, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1170 = fmul fast <3 x half> %78, %1169
  %1171 = extractvalue { <4 x half>, i8 } %69, 0
  %1172 = extractelement <4 x half> %1171, i64 3
  %1173 = fmul fast half %71, %1172
  %1174 = tail call fast half @air.clamp.f16(half %1173, half 0xH0000, half 0xH3C00) #1
  %1175 = insertelement <3 x half> undef, half %1174, i64 0
  %1176 = shufflevector <3 x half> %1175, <3 x half> undef, <3 x i32> zeroinitializer
  %1177 = shufflevector <4 x half> %1171, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1178 = fmul fast <4 x half> %64, %66
  %1179 = shufflevector <4 x half> %1178, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1180 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1179
  %1181 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1177, <3 x half> %73, <3 x half> %1180) #1
  %1182 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1176, <3 x half> %1181, <3 x half> %1179) #1
  %1183 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1182
  %1184 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1170, <3 x half> %82, <3 x half> %1183) #1
  %1185 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1168, <3 x half> %1184, <3 x half> %1182) #1
  %1186 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1185
  %1187 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1163, <3 x half> %82, <3 x half> %1186) #1
  %1188 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1161, <3 x half> %1187, <3 x half> %1185) #1
  %1189 = extractvalue { <4 x half>, i8 } %90, 0
  %1190 = extractelement <4 x half> %1189, i64 3
  %1191 = fmul fast half %92, %1190
  %1192 = tail call fast half @air.clamp.f16(half %1191, half 0xH0000, half 0xH3C00) #1
  %1193 = insertelement <3 x half> undef, half %1192, i64 0
  %1194 = shufflevector <3 x half> %1193, <3 x half> undef, <3 x i32> zeroinitializer
  %1195 = shufflevector <4 x half> %1189, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1196 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1195, <3 x half> %94, <3 x half> splat (half 0xHBC00)) #1
  %1197 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1194, <3 x half> %1196, <3 x half> splat (half 0xH3C00)) #1
  %1198 = fmul fast <3 x half> %1188, %1197
  %1199 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1198
  %1200 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1156, <3 x half> %82, <3 x half> %1199) #1
  %1201 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1154, <3 x half> %1200, <3 x half> %1198) #1
  %1202 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1201
  %1203 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1151, <3 x half> %82, <3 x half> %1202) #1
  %1204 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1149, <3 x half> %1203, <3 x half> %1201) #1
  %1205 = fsub nnan ninf nsz arcp afn <3 x half> splat (half 0xH8000), %1204
  %1206 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1144, <3 x half> %82, <3 x half> %1205) #1
  %1207 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1142, <3 x half> %1206, <3 x half> %1204) #1
  %1208 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1137, <3 x half> %1112, <3 x half> %1207) #1
  %1209 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1115, <3 x half> %1133, <3 x half> %1208) #1
  %1210 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1102, <3 x half> %1112, <3 x half> %1209) #1
  %1211 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1210) #1
  %1212 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %1211
  %1213 = shufflevector <4 x half> %345, <4 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %1214 = fsub fast <3 x half> splat (half 0xH3C00), %355
  %1215 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1213, <3 x half> %1214, <3 x half> %355) #1
  %1216 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1215) #1
  %1217 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %1212, <3 x float> %1216, <3 x float> %1211) #1
  %1218 = extractvalue { <4 x half>, i8 } %533, 0
  %1219 = shufflevector <4 x half> %1218, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1220 = extractelement <4 x float> %535, i64 0
  %1221 = extractelement <4 x float> %535, i64 1
  %1222 = extractelement <4 x float> %535, i64 3
  %1223 = extractelement <4 x half> %1218, i64 3
  %1224 = fadd fast half %1223, 0xHBC00
  %1225 = fpext half %1224 to float
  %1226 = tail call fast float @air.fma.f32(float %1222, float %1225, float 1.000000e+00) #1
  %1227 = fptrunc float %1226 to half
  %1228 = tail call fast half @air.fmax.f16(half %1227, half 0xH0000) #1
  %1229 = tail call fast half @air.log2.f16(half %1228) #1
  %1230 = fpext half %1229 to float
  %1231 = fmul fast float %1221, %1230
  %1232 = fptrunc float %1231 to half
  %1233 = tail call fast half @air.exp2.f16(half %1232) #1
  %1234 = fpext half %1233 to float
  %1235 = fmul fast float %1220, %1234
  %1236 = fptrunc float %1235 to half
  %1237 = insertelement <3 x half> undef, half %1236, i64 0
  %1238 = shufflevector <3 x half> %1237, <3 x half> undef, <3 x i32> zeroinitializer
  %1239 = fmul fast <3 x half> %1219, %1238
  %1240 = insertelement <3 x float> undef, float %433, i64 0
  %1241 = shufflevector <3 x float> %1240, <3 x float> undef, <3 x i32> zeroinitializer
  %1242 = shufflevector <4 x half> %426, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1243 = extractelement <3 x half> %401, i64 0
  %1244 = extractelement <3 x half> %401, i64 1
  %1245 = fsub nnan ninf nsz arcp afn half 0xH8000, %1244
  %1246 = fmul fast half %1244, %1245
  %1247 = tail call fast half @air.fma.f16(half %1243, half %1243, half %1246) #1
  %1248 = insertelement <3 x half> undef, half %1247, i64 0
  %1249 = shufflevector <3 x half> %1248, <3 x half> undef, <3 x i32> zeroinitializer
  %1250 = shufflevector <3 x half> %401, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %1251 = insertelement <4 x half> %1250, half 0xH3C00, i64 3
  %1252 = tail call fast half @air.dot.v4f16(<4 x half> %414, <4 x half> %1251) #1
  %1253 = insertelement <3 x half> undef, half %1252, i64 0
  %1254 = tail call fast half @air.dot.v4f16(<4 x half> %416, <4 x half> %1251) #1
  %1255 = insertelement <3 x half> %1253, half %1254, i64 1
  %1256 = tail call fast half @air.dot.v4f16(<4 x half> %418, <4 x half> %1251) #1
  %1257 = insertelement <3 x half> %1255, half %1256, i64 2
  %1258 = shufflevector <3 x half> %401, <3 x half> undef, <4 x i32> <i32 1, i32 2, i32 2, i32 0>
  %1259 = shufflevector <3 x half> %401, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 2>
  %1260 = fmul fast <4 x half> %1258, %1259
  %1261 = tail call fast half @air.dot.v4f16(<4 x half> %420, <4 x half> %1260) #1
  %1262 = insertelement <3 x half> undef, half %1261, i64 0
  %1263 = tail call fast half @air.dot.v4f16(<4 x half> %422, <4 x half> %1260) #1
  %1264 = insertelement <3 x half> %1262, half %1263, i64 1
  %1265 = tail call fast half @air.dot.v4f16(<4 x half> %424, <4 x half> %1260) #1
  %1266 = insertelement <3 x half> %1264, half %1265, i64 2
  %1267 = fadd fast <3 x half> %1257, %1266
  %1268 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1242, <3 x half> %1249, <3 x half> %1267) #1
  %1269 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %1268, <3 x half> zeroinitializer) #1
  %1270 = fmul fast <3 x half> %1239, %1269
  %1271 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1270) #1
  %1272 = fmul fast <3 x float> %1241, %1271
  %1273 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %1272) #1
  %1274 = insertelement <3 x half> undef, half %537, i64 0
  %1275 = shufflevector <3 x half> %1274, <3 x half> undef, <3 x i32> zeroinitializer
  %1276 = shufflevector <4 x float> %517, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1277 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %1276) #1
  %1278 = fptrunc float %1277 to half
  %1279 = tail call fast half @air.fmax.f16(half %1278, half 0xH0000) #1
  %1280 = fcmp fast ogt half %1279, 0xH0000
  %1281 = insertelement <3 x half> undef, half %1279, i64 0
  %1282 = shufflevector <3 x half> %1281, <3 x half> undef, <3 x i32> zeroinitializer
  %1283 = shufflevector <4 x half> %519, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1284 = fmul fast <3 x half> %1283, %1282
  %1285 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %448, <3 x float> %451, <3 x float> %1276) #1
  %1286 = tail call fast float @air.dot.v3f32(<3 x float> %1285, <3 x float> %1285) #1
  %1287 = tail call fast float @air.fast_fmax.f32(float %1286, float 0x3F10000000000000) #1
  %1288 = tail call fast float @air.fast_rsqrt.f32(float %1287) #1
  %1289 = insertelement <3 x float> undef, float %1288, i64 0
  %1290 = shufflevector <3 x float> %1289, <3 x float> undef, <3 x i32> zeroinitializer
  %1291 = fmul fast <3 x float> %1285, %1290
  %1292 = tail call fast float @air.dot.v3f32(<3 x float> %439, <3 x float> %1291) #1
  %1293 = tail call fast float @air.fast_fmax.f32(float %1292, float 0.000000e+00) #1
  %1294 = tail call fast float @air.fast_fmin.f32(float %1293, float 0x3FEFF7CEE0000000) #1
  %1295 = fmul fast float %1294, %1294
  %1296 = tail call fast float @air.fma.f32(float %1295, float %473, float %471) #1
  %1297 = fdiv fast float 1.000000e+00, %1296
  %1298 = tail call fast float @air.fast_fmin.f32(float %1297, float 1.000000e+01) #1
  %1299 = fmul fast float %1298, %1298
  %1300 = insertelement <2 x float> undef, float %1299, i64 0
  %1301 = tail call fast half @air.dot.v3f16(<3 x half> %401, <3 x half> %387) #1
  %1302 = fpext half %1301 to float
  %1303 = tail call fast float @air.fast_fmax.f32(float %1302, float 0.000000e+00) #1
  %1304 = fadd fast float %1303, 0x3EE4F8B580000000
  %1305 = extractelement <2 x half> %467, i64 1
  %1306 = fsub fast half 0xH3C00, %1305
  %1307 = fpext half %1306 to float
  %1308 = fpext half %1305 to float
  %1309 = tail call fast float @air.fma.f32(float %1304, float %1307, float %1308) #1
  %1310 = fptrunc float %1309 to half
  %1311 = tail call fast half @air.fma.f16(half %1279, half %1306, half %1305) #1
  %1312 = fpext half %1311 to float
  %1313 = fmul fast float %1304, %1312
  %1314 = fptrunc float %1313 to half
  %1315 = tail call fast half @air.fma.f16(half %1279, half %1310, half %1314) #1
  %1316 = fpext half %1315 to float
  %1317 = fadd fast float %1316, 0x3F1A36E2E0000000
  %1318 = fdiv fast float 1.000000e+00, %1317
  %1319 = insertelement <2 x float> %1300, float %1318, i64 1
  %1320 = fmul fast <2 x float> %1319, <float 0x3FD45F3060000000, float 5.000000e-01>
  %1321 = extractelement <2 x float> %1320, i64 1
  %1322 = tail call fast float @air.fast_fmin.f32(float %1321, float 1.000000e+01) #1
  %1323 = extractelement <2 x float> %1320, i64 0
  %1324 = fmul fast float %432, 4.000000e+00
  %1325 = fptrunc float %1324 to half
  %1326 = tail call fast half @air.clamp.f16(half %1325, half 0xH0000, half 0xH3C00) #1
  %1327 = fpext half %1326 to float
  %1328 = tail call fast float @air.dot.v3f32(<3 x float> %459, <3 x float> %1291) #1
  %1329 = tail call fast float @air.fast_fmax.f32(float %1328, float 0.000000e+00) #1
  %1330 = fsub fast float 1.000000e+00, %1329
  %1331 = fmul fast float %1330, %1330
  %1332 = fmul fast float %1331, %1331
  %1333 = fmul fast float %1330, %1332
  %1334 = fsub nnan ninf nsz arcp afn float -0.000000e+00, %1332
  %1335 = tail call fast float @air.fma.f32(float %1334, float %1330, float 1.000000e+00) #1
  %1336 = fmul fast float %433, %1335
  %1337 = tail call fast float @air.fma.f32(float %1327, float %1333, float %1336) #1
  %1338 = fmul fast float %1323, %1337
  %1339 = fptrunc float %1338 to half
  %1340 = fpext half %1339 to float
  %1341 = fmul fast float %1322, %1340
  %1342 = fptrunc float %1341 to half
  %1343 = insertelement <3 x half> undef, half %1342, i64 0
  %1344 = shufflevector <3 x half> %1343, <3 x half> undef, <3 x i32> zeroinitializer
  %1345 = fmul fast <3 x half> %1284, %1344
  %1346 = select fast i1 %1280, <3 x half> %1345, <3 x half> zeroinitializer
  %1347 = shufflevector <4 x half> %435, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %1348 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %356) #1
  %1349 = fmul fast <3 x float> %1211, %1216
  %1350 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %1348, <3 x float> %1217, <3 x float> %1349) #1
  %1351 = extractvalue { <4 x half>, i8 } %438, 0
  %1352 = shufflevector <4 x half> %1351, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1353 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1352) #1
  %1354 = extractelement <4 x half> %435, i64 0
  %1355 = fadd fast half %1354, 0xHBC00
  %1356 = tail call fast half @air.fma.f16(half %437, half %1355, half 0xH3C00) #1
  %1357 = insertelement <3 x half> undef, half %1356, i64 0
  %1358 = shufflevector <3 x half> %1357, <3 x half> undef, <3 x i32> zeroinitializer
  %1359 = shufflevector <4 x half> %462, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %1360 = extractelement <2 x half> %447, i64 1
  %1361 = fcmp fast ogt half %1360, 0xH0000
  %1362 = shufflevector <2 x half> %447, <2 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %1363 = fmul fast <3 x half> %1362, %1359
  %1364 = tail call fast half @air.fma.f16(half %1360, half %1306, half %1305) #1
  %1365 = fpext half %1364 to float
  %1366 = fmul fast float %1304, %1365
  %1367 = fptrunc float %1366 to half
  %1368 = tail call fast half @air.fma.f16(half %1360, half %1310, half %1367) #1
  %1369 = fpext half %1368 to float
  %1370 = fadd fast float %1369, 0x3F1A36E2E0000000
  %1371 = fdiv fast float 5.000000e-01, %1370
  %1372 = tail call fast float @air.fast_fmin.f32(float %1371, float 1.000000e+01) #1
  %1373 = tail call fast float @air.fast_fmax.f32(float %460, float 0.000000e+00) #1
  %1374 = tail call fast float @air.fast_fmin.f32(float %1373, float 0x3FEFF7CEE0000000) #1
  %1375 = fmul fast float %1374, %1374
  %1376 = tail call fast float @air.fma.f32(float %1375, float %473, float %471) #1
  %1377 = fdiv fast float 1.000000e+00, %1376
  %1378 = tail call fast float @air.fast_fmin.f32(float %1377, float 1.000000e+01) #1
  %1379 = fmul fast float %1378, %1378
  %1380 = fmul fast float %1379, 0x3FD45F3060000000
  %1381 = tail call fast float @air.dot.v3f32(<3 x float> %459, <3 x float> %458) #1
  %1382 = tail call fast float @air.fast_fmax.f32(float %1381, float 0.000000e+00) #1
  %1383 = fsub fast float 1.000000e+00, %1382
  %1384 = fmul fast float %1383, %1383
  %1385 = fmul fast float %1384, %1384
  %1386 = fmul fast float %1383, %1385
  %1387 = fsub nnan ninf nsz arcp afn float -0.000000e+00, %1385
  %1388 = tail call fast float @air.fma.f32(float %1387, float %1383, float 1.000000e+00) #1
  %1389 = fmul fast float %433, %1388
  %1390 = tail call fast float @air.fma.f32(float %1327, float %1386, float %1389) #1
  %1391 = fmul fast float %1380, %1390
  %1392 = fptrunc float %1391 to half
  %1393 = fpext half %1392 to float
  %1394 = fmul fast float %1372, %1393
  %1395 = fptrunc float %1394 to half
  %1396 = insertelement <3 x half> undef, half %1395, i64 0
  %1397 = shufflevector <3 x half> %1396, <3 x half> undef, <3 x i32> zeroinitializer
  %1398 = fmul fast <3 x half> %1363, %1397
  %1399 = select fast i1 %1361, <3 x half> %1398, <3 x half> zeroinitializer
  %1400 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %513, <3 x half> %1359, <3 x half> %1399) #1
  %1401 = fmul fast <3 x half> %1358, %1400
  %1402 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %1401) #1
  %1403 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %1350, <3 x float> %1353, <3 x float> %1402) #1
  %1404 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %1403) #1
  %1405 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1346, <3 x half> %1347, <3 x half> %1404) #1
  %1406 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %1273, <3 x half> %1275, <3 x half> %1405) #1
  %1407 = fadd fast <3 x half> %1098, %1406
  %1408 = shufflevector <3 x half> %1407, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %1409 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %5, i64 0, i32 15
  %1410 = load half, ptr addrspace(2) %1409, align 2, !tbaa !121, !alias.scope !79, !noalias !80
  %1411 = fadd fast half %1410, 0xHBC00
  %1412 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 7
  %1413 = load half, ptr addrspace(2) %1412, align 2, !tbaa !122, !alias.scope !88, !noalias !89
  %1414 = tail call fast half @air.fma.f16(half %1413, half %1411, half 0xH3C00) #1
  %1415 = insertelement <4 x half> %1408, half %1414, i64 3
  %1416 = insertvalue <{ <4 x half>, half }> undef, <4 x half> %1415, 0
  %1417 = insertvalue <{ <4 x half>, half }> %1416, half %1414, 1
  ret <{ <4 x half>, half }> %1417
}

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fma.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmax.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fmax.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.exp2.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.log2.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fabs.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_sqrt.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fast_fmin.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.fabs.v4f16(<4 x half>) local_unnamed_addr #1

define internal fastcc <4 x float> @___metal_fract_v4float(<4 x float> %0, i32 %1) unnamed_addr #2 {
  %3 = tail call fastcc <4 x float> @_ZN11_fract_implIDv4_fvE4implIJLi0ELi1ELi2ELi3EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<4 x float> %0, i32 %1)
  ret <4 x float> %3
}

define internal fastcc <4 x float> @_ZN11_fract_implIDv4_fvE4implIJLi0ELi1ELi2ELi3EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<4 x float> %0, i32 %1) unnamed_addr #2 align 2 {
  %3 = extractelement <4 x float> %0, i64 0
  %4 = icmp eq i32 %1, 0
  br i1 %4, label %5, label %7

5:                                                ; preds = %2
  %6 = tail call fastcc float @_Z18_target_fast_fractf(float %3)
  br label %20

7:                                                ; preds = %2
  %8 = bitcast float %3 to i32
  %9 = and i32 %8, 2147483647
  %10 = icmp eq i32 %9, 2139095040
  br i1 %10, label %11, label %14

11:                                               ; preds = %7
  %12 = and i32 %8, -2147483648
  %13 = bitcast i32 %12 to float
  br label %20

14:                                               ; preds = %7
  %15 = icmp ugt i32 %9, 2139095040
  br i1 %15, label %20, label %16

16:                                               ; preds = %14
  %17 = tail call fastcc float @_Z13_target_floorf(float %3)
  %18 = fsub float %3, %17
  %19 = tail call fastcc float @_Z11_target_minff(float %18, float 0x3FEFFFFFE0000000)
  br label %20

20:                                               ; preds = %16, %14, %11, %5
  %21 = phi float [ %6, %5 ], [ %13, %11 ], [ %19, %16 ], [ %3, %14 ]
  %22 = extractelement <4 x float> %0, i64 1
  br i1 %4, label %23, label %25

23:                                               ; preds = %20
  %24 = tail call fastcc float @_Z18_target_fast_fractf(float %22)
  br label %38

25:                                               ; preds = %20
  %26 = bitcast float %22 to i32
  %27 = and i32 %26, 2147483647
  %28 = icmp eq i32 %27, 2139095040
  br i1 %28, label %29, label %32

29:                                               ; preds = %25
  %30 = and i32 %26, -2147483648
  %31 = bitcast i32 %30 to float
  br label %38

32:                                               ; preds = %25
  %33 = icmp ugt i32 %27, 2139095040
  br i1 %33, label %38, label %34

34:                                               ; preds = %32
  %35 = tail call fastcc float @_Z13_target_floorf(float %22)
  %36 = fsub float %22, %35
  %37 = tail call fastcc float @_Z11_target_minff(float %36, float 0x3FEFFFFFE0000000)
  br label %38

38:                                               ; preds = %34, %32, %29, %23
  %39 = phi float [ %24, %23 ], [ %31, %29 ], [ %37, %34 ], [ %22, %32 ]
  %40 = extractelement <4 x float> %0, i64 2
  br i1 %4, label %41, label %43

41:                                               ; preds = %38
  %42 = tail call fastcc float @_Z18_target_fast_fractf(float %40)
  br label %56

43:                                               ; preds = %38
  %44 = bitcast float %40 to i32
  %45 = and i32 %44, 2147483647
  %46 = icmp eq i32 %45, 2139095040
  br i1 %46, label %47, label %50

47:                                               ; preds = %43
  %48 = and i32 %44, -2147483648
  %49 = bitcast i32 %48 to float
  br label %56

50:                                               ; preds = %43
  %51 = icmp ugt i32 %45, 2139095040
  br i1 %51, label %56, label %52

52:                                               ; preds = %50
  %53 = tail call fastcc float @_Z13_target_floorf(float %40)
  %54 = fsub float %40, %53
  %55 = tail call fastcc float @_Z11_target_minff(float %54, float 0x3FEFFFFFE0000000)
  br label %56

56:                                               ; preds = %52, %50, %47, %41
  %57 = phi float [ %42, %41 ], [ %49, %47 ], [ %55, %52 ], [ %40, %50 ]
  %58 = extractelement <4 x float> %0, i64 3
  br i1 %4, label %59, label %61

59:                                               ; preds = %56
  %60 = tail call fastcc float @_Z18_target_fast_fractf(float %58)
  br label %74

61:                                               ; preds = %56
  %62 = bitcast float %58 to i32
  %63 = and i32 %62, 2147483647
  %64 = icmp eq i32 %63, 2139095040
  br i1 %64, label %65, label %68

65:                                               ; preds = %61
  %66 = and i32 %62, -2147483648
  %67 = bitcast i32 %66 to float
  br label %74

68:                                               ; preds = %61
  %69 = icmp ugt i32 %63, 2139095040
  br i1 %69, label %74, label %70

70:                                               ; preds = %68
  %71 = tail call fastcc float @_Z13_target_floorf(float %58)
  %72 = fsub float %58, %71
  %73 = tail call fastcc float @_Z11_target_minff(float %72, float 0x3FEFFFFFE0000000)
  br label %74

74:                                               ; preds = %70, %68, %65, %59
  %75 = phi float [ %60, %59 ], [ %67, %65 ], [ %73, %70 ], [ %58, %68 ]
  %76 = insertelement <4 x float> undef, float %21, i64 0
  %77 = insertelement <4 x float> %76, float %39, i64 1
  %78 = insertelement <4 x float> %77, float %57, i64 2
  %79 = insertelement <4 x float> %78, float %75, i64 3
  ret <4 x float> %79
}

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z11_target_minff(float %0, float %1) unnamed_addr #3 {
  %3 = tail call float @air.fmin.f32(float %0, float %1) #1
  ret float %3
}

; Function Attrs: nounwind memory(none)
declare float @air.fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z13_target_floorf(float %0) unnamed_addr #3 {
  %2 = tail call float @air.floor.f32(float %0) #1
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.floor.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z18_target_fast_fractf(float %0) unnamed_addr #3 {
  %2 = tail call float @air.fast_fract.f32(float %0) #1
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.fast_fract.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_clamp.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.fma.v4f16(<4 x half>, <4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fast_floor.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #4

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_cube.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <3 x float>, i1, float, float, i32) local_unnamed_addr #4

; Function Attrs: nounwind memory(none)
declare <2 x half> @air.fmax.v2f16(<2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.rsqrt.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.sqrt.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmin.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v2f16(<2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x half> @air.fma.v2f16(<2 x half>, <2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.fmax.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fast_fabs.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.s.v3i32(<3 x i32>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x i32> @air.convert.u.v3i32.u.v3i1(<3 x i1>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fast_floor.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.clamp.v4f16(<4 x half>, <4 x half>, <4 x half>) local_unnamed_addr #1

attributes #0 = { convergent nounwind optsize "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }
attributes #2 = { "frame-pointer"="all" "min-legal-vector-width"="128" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #3 = { nounwind memory(none) "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #4 = { convergent nounwind memory(argmem: read) }
attributes #5 = { nounwind }

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
!12 = !{!"air.compile.fast_math_disable"}
!13 = !{!"air.compile.framebuffer_fetch_enable"}
!14 = !{ptr @xlatMtlMain, !15, !18}
!15 = !{!16, !17}
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_TARGET0"}
!17 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"half", !"air.arg_name", !"SV_TARGET1"}
!18 = !{!19, !21, !23, !25, !27, !29, !31, !33, !34, !35, !36, !37, !38, !39, !40, !41, !42, !43, !44, !45, !46, !47, !48, !49, !50, !51, !52, !53, !54, !55, !56, !57, !58, !59, !60, !61, !62, !63, !64, !65, !66}
!19 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 2176, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !20, !"air.arg_type_size", i32 2176, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"AsukaPerShader_AddLightParams_PerCamera_Type", !"air.arg_name", !"AsukaPerShader_AddLightParams_PerCamera"}
!20 = !{i32 0, i32 16, i32 30, !"float4", !"_AdditionalLightPosition", i32 480, i32 16, i32 30, !"float4", !"_AdditionalLightSpotAttenuation", i32 960, i32 8, i32 0, !"half4", !"_AdditionalLightCount", i32 968, i32 8, i32 30, !"half4", !"_AdditionalLightColor", i32 1208, i32 8, i32 30, !"half4", !"_AdditionalLightDistanceAttenuation", i32 1456, i32 16, i32 30, !"float4", !"_AdditionalLightSpotDir", i32 1936, i32 8, i32 30, !"half4", !"_AdditionalLightShadowWeight"}
!21 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 1, i32 1, !"air.read", !"air.struct_type_info", !22, !"air.arg_type_size", i32 144, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"AsukaPerShader_PerCamera_Type", !"air.arg_name", !"AsukaPerShader_PerCamera"}
!22 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_WorldToLight", i32 64, i32 16, i32 0, !"float4", !"_MainLightPosition", i32 80, i32 8, i32 0, !"half4", !"_MainLightColor", i32 88, i32 8, i32 0, !"half4", !"_ScaledScreenParams", i32 96, i32 8, i32 0, !"half4", !"_GridInfo", i32 112, i32 16, i32 0, !"float4", !"_AuroraGridInfo", i32 128, i32 2, i32 0, !"half", !"_MainLightRealtime", i32 130, i32 2, i32 0, !"half", !"_DOFEnable", i32 132, i32 2, i32 0, !"half", !"_GlobalMipBias"}
!23 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 2, i32 1, !"air.read", !"air.struct_type_info", !24, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!24 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!25 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 3, i32 1, !"air.read", !"air.struct_type_info", !26, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerDraw_Type", !"air.arg_name", !"UnityPerDraw"}
!26 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_ObjectToWorld", i32 64, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_WorldToObject", i32 128, i32 16, i32 0, !"float4", !"unity_WorldTransformParams", i32 144, i32 16, i32 0, !"float4", !"unity_SpecCube0_HDR", i32 160, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_MatrixPreviousM", i32 224, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_MatrixPreviousMI", i32 288, i32 16, i32 0, !"float4", !"unity_MotionVectorsParams", i32 304, i32 4, i32 0, !"uint", !"Pape_SpecCubeArrayMaxMip"}
!27 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 4, i32 1, !"air.read", !"air.struct_type_info", !28, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Character_Param_Type", !"air.arg_name", !"Character_Param"}
!28 = !{i32 0, i32 16, i32 0, !"float4", !"_CharLightPosition", i32 16, i32 8, i32 0, !"half4", !"_CharShColor", i32 24, i32 8, i32 0, !"half4", !"_CharMainLightColor", i32 32, i32 8, i32 0, !"half4", !"_CharLightColor", i32 40, i32 8, i32 0, !"half3", !"_RootMPosition", i32 48, i32 2, i32 0, !"half", !"_CharShIntensity", i32 50, i32 2, i32 0, !"half", !"_CharShadowIntensity", i32 52, i32 2, i32 0, !"half", !"_CharShHeight", i32 54, i32 2, i32 0, !"half", !"_ClipYValue", i32 56, i32 2, i32 0, !"half", !"_HomeLightingEnable", i32 58, i32 2, i32 0, !"half", !"_EyeAdaptionInverseExposureEnable", i32 64, i32 8, i32 0, !"half4", !"_HomeLightingPPVScale", i32 72, i32 8, i32 0, !"half4", !"_HomeLightingPPVColor0", i32 80, i32 8, i32 0, !"half4", !"_HomeLightingPPVColor1", i32 88, i32 8, i32 0, !"half4", !"_HomeRimLightingPPVColor", i32 96, i32 2, i32 0, !"half", !"_POSMEnabled"}
!29 = !{i32 5, !"air.buffer", !"air.buffer_size", i32 336, !"air.location_index", i32 5, i32 1, !"air.read", !"air.struct_type_info", !30, !"air.arg_type_size", i32 336, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"UnityPerMaterial_Type", !"air.arg_name", !"UnityPerMaterial"}
!30 = !{i32 0, i32 8, i32 0, !"half4", !"_MainTex_ST", i32 8, i32 8, i32 0, !"half4", !"_Color", i32 16, i32 8, i32 0, !"half4", !"_FresnelColor", i32 24, i32 8, i32 0, !"half4", !"_OverlayColor", i32 32, i32 8, i32 0, !"half4", !"_SparkleUV", i32 40, i32 8, i32 0, !"half4", !"_SSSSkinTexture_TexelSize", i32 48, i32 2, i32 0, !"half", !"_Cutoff", i32 50, i32 2, i32 0, !"half", !"_ShadowIntensity", i32 52, i32 2, i32 0, !"half", !"_AOIntensity", i32 54, i32 2, i32 0, !"half", !"_NonMetalSpecular", i32 56, i32 2, i32 0, !"half", !"_FresnelIntensity", i32 58, i32 2, i32 0, !"half", !"_Fresnelpower", i32 60, i32 2, i32 0, !"half", !"_LerpValue", i32 62, i32 2, i32 0, !"half", !"_LeftEyeInfo", i32 64, i32 2, i32 0, !"half", !"_RightEyeInfo", i32 66, i32 2, i32 0, !"half", !"_DOFBlurFlag", i32 72, i32 8, i32 0, !"half4", !"_MakeupColor1", i32 80, i32 8, i32 0, !"half4", !"_MakeupColor2", i32 88, i32 8, i32 0, !"half4", !"_MakeupColor3", i32 96, i32 8, i32 0, !"half4", !"_MakeupColor4", i32 104, i32 8, i32 0, !"half4", !"_MakeupColor5", i32 112, i32 8, i32 0, !"half4", !"_MakeupColor6", i32 120, i32 8, i32 0, !"half4", !"_DecorateUV", i32 128, i32 8, i32 0, !"half4", !"_Decorate2UV", i32 136, i32 8, i32 0, !"half4", !"_MorphPartColor", i32 144, i32 8, i32 0, !"half4", !"_MorphPartShinningColor", i32 152, i32 8, i32 0, !"half4", !"_MorphPartSpreadColor", i32 160, i32 8, i32 0, !"half4", !"_MorphPartParam", i32 168, i32 8, i32 0, !"half4", !"_MorphPartTexUV", i32 176, i32 8, i32 0, !"half3", !"_EyebrowColor", i32 184, i32 8, i32 0, !"half3", !"_EyeshadowColor", i32 192, i32 8, i32 0, !"half3", !"_EyelinerColor", i32 200, i32 8, i32 0, !"half3", !"_LipColor", i32 208, i32 8, i32 0, !"half3", !"_BlusherColor", i32 216, i32 8, i32 0, !"half3", !"_DecorateColor", i32 224, i32 8, i32 0, !"half3", !"_Decorate2Color", i32 232, i32 8, i32 0, !"half3", !"_MakeupMultiplyColor", i32 240, i32 2, i32 0, !"half", !"_MakeupRoughness5", i32 242, i32 2, i32 0, !"half", !"_EyebrowDensity", i32 244, i32 2, i32 0, !"half", !"_EyeshadowDensity", i32 246, i32 2, i32 0, !"half", !"_EyelinerDensity", i32 248, i32 2, i32 0, !"half", !"_BlusherDensity", i32 250, i32 2, i32 0, !"half", !"_LipDensity", i32 252, i32 2, i32 0, !"half", !"_LipRoughness", i32 254, i32 2, i32 0, !"half", !"_LipSpecular", i32 256, i32 2, i32 0, !"half", !"_DecorateDensity", i32 258, i32 2, i32 0, !"half", !"_Decorate2Density", i32 260, i32 2, i32 0, !"half", !"_MorphPartId", i32 262, i32 2, i32 0, !"half", !"_MorphPartRange", i32 264, i32 2, i32 0, !"half", !"_MorphPartShinningAlpha", i32 266, i32 2, i32 0, !"half", !"_MorphPartWaveLength", i32 268, i32 2, i32 0, !"half", !"_MorphPartBreathAlpha", i32 272, i32 8, i32 0, !"half4", !"_EyeSparkleColor", i32 280, i32 8, i32 0, !"half4", !"_LipSparkleColor", i32 288, i32 8, i32 0, !"half4", !"_EyeSparkleParams", i32 296, i32 8, i32 0, !"half4", !"_LipSparkleParams", i32 304, i32 8, i32 0, !"half4", !"_EyeSparkleSize", i32 312, i32 8, i32 0, !"half4", !"_LipSparkleSize", i32 320, i32 2, i32 0, !"half", !"_EyeSparkle", i32 322, i32 2, i32 0, !"half", !"_LipSparkle", i32 328, i32 8, i32 0, !"half3", !"_EyelidColor"}
!31 = !{i32 6, !"air.buffer", !"air.buffer_size", i32 136, !"air.location_index", i32 6, i32 1, !"air.read", !"air.struct_type_info", !32, !"air.arg_type_size", i32 136, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"PapePerRendererCB_Type", !"air.arg_name", !"PapePerRendererCB"}
!32 = !{i32 0, i32 8, i32 7, !"half4", !"_SHMaps", i32 56, i32 8, i32 7, !"half4", !"_CubeSHs", i32 112, i32 8, i32 0, !"half4", !"_VegColor", i32 120, i32 2, i32 0, !"half", !"_VegetationInShadowLighting", i32 122, i32 2, i32 0, !"half", !"_VegetationIndirectSpecIntensity", i32 124, i32 2, i32 0, !"half", !"_IsNightMode", i32 126, i32 2, i32 0, !"half", !"_RampColorID0", i32 128, i32 2, i32 0, !"half", !"_RampColorID1", i32 130, i32 2, i32 0, !"half", !"_RampColorBlend"}
!33 = !{i32 7, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"samplerunity_SpecCube0"}
!34 = !{i32 8, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_LightIndexMap"}
!35 = !{i32 9, !"air.sampler", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_MainTex"}
!36 = !{i32 10, !"air.sampler", !"air.location_index", i32 3, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SpecularTex"}
!37 = !{i32 11, !"air.sampler", !"air.location_index", i32 4, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_NormalTex"}
!38 = !{i32 12, !"air.sampler", !"air.location_index", i32 5, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_EyeshadowTex"}
!39 = !{i32 13, !"air.sampler", !"air.location_index", i32 6, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_LipTex"}
!40 = !{i32 14, !"air.sampler", !"air.location_index", i32 7, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_MorphPartTex"}
!41 = !{i32 15, !"air.sampler", !"air.location_index", i32 8, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_EyelidTex"}
!42 = !{i32 16, !"air.sampler", !"air.location_index", i32 9, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SSSSkinTexture"}
!43 = !{i32 17, !"air.sampler", !"air.location_index", i32 10, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ScreenShadowTexture"}
!44 = !{i32 18, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<half, sample>", !"air.arg_name", !"unity_SpecCube0"}
!45 = !{i32 19, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_LightIndexMap"}
!46 = !{i32 20, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_MainTex"}
!47 = !{i32 21, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SpecularTex"}
!48 = !{i32 22, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_NormalTex"}
!49 = !{i32 23, !"air.texture", !"air.location_index", i32 5, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_EyebrowTex"}
!50 = !{i32 24, !"air.texture", !"air.location_index", i32 6, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_EyeshadowTex"}
!51 = !{i32 25, !"air.texture", !"air.location_index", i32 7, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_EyelinerTex"}
!52 = !{i32 26, !"air.texture", !"air.location_index", i32 8, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_BlusherTex"}
!53 = !{i32 27, !"air.texture", !"air.location_index", i32 9, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_LipTex"}
!54 = !{i32 28, !"air.texture", !"air.location_index", i32 10, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_DecorateTex"}
!55 = !{i32 29, !"air.texture", !"air.location_index", i32 11, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_Decorate2Tex"}
!56 = !{i32 30, !"air.texture", !"air.location_index", i32 12, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_MorphPartTex"}
!57 = !{i32 31, !"air.texture", !"air.location_index", i32 13, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_EyelidTex"}
!58 = !{i32 32, !"air.texture", !"air.location_index", i32 14, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SSSSkinTexture"}
!59 = !{i32 33, !"air.texture", !"air.location_index", i32 15, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ScreenShadowTexture"}
!60 = !{i32 34, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD0"}
!61 = !{i32 35, !"air.fragment_input", !"user(TEXCOORD1)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD1"}
!62 = !{i32 36, !"air.fragment_input", !"user(TEXCOORD2)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"TEXCOORD2"}
!63 = !{i32 37, !"air.fragment_input", !"user(TEXCOORD3)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD3"}
!64 = !{i32 38, !"air.fragment_input", !"user(TEXCOORD4)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD4"}
!65 = !{i32 39, !"air.fragment_input", !"user(TEXCOORD5)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD5"}
!66 = !{i32 40, !"air.fragment_input", !"user(TEXCOORD6)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD6"}
!67 = !{!68, !70}
!68 = distinct !{!68, !69, !"air-alias-scope-samplers"}
!69 = distinct !{!69, !"air-alias-scopes(xlatMtlMain)"}
!70 = distinct !{!70, !69, !"air-alias-scope-textures"}
!71 = !{!72, !73, !74, !75, !76, !77, !78}
!72 = distinct !{!72, !69, !"air-alias-scope-arg(0)"}
!73 = distinct !{!73, !69, !"air-alias-scope-arg(1)"}
!74 = distinct !{!74, !69, !"air-alias-scope-arg(2)"}
!75 = distinct !{!75, !69, !"air-alias-scope-arg(3)"}
!76 = distinct !{!76, !69, !"air-alias-scope-arg(4)"}
!77 = distinct !{!77, !69, !"air-alias-scope-arg(5)"}
!78 = distinct !{!78, !69, !"air-alias-scope-arg(6)"}
!79 = !{!77}
!80 = !{!72, !73, !74, !75, !76, !78, !68, !70}
!81 = !{!82, !85, i64 62}
!82 = !{!"_ZTS21UnityPerMaterial_Type", !83, i64 0, !83, i64 8, !83, i64 16, !83, i64 24, !83, i64 32, !83, i64 40, !85, i64 48, !85, i64 50, !85, i64 52, !85, i64 54, !85, i64 56, !85, i64 58, !85, i64 60, !85, i64 62, !85, i64 64, !85, i64 66, !83, i64 72, !83, i64 80, !83, i64 88, !83, i64 96, !83, i64 104, !83, i64 112, !83, i64 120, !83, i64 128, !83, i64 136, !83, i64 144, !83, i64 152, !83, i64 160, !83, i64 168, !83, i64 176, !83, i64 184, !83, i64 192, !83, i64 200, !83, i64 208, !83, i64 216, !83, i64 224, !83, i64 232, !85, i64 240, !85, i64 242, !85, i64 244, !85, i64 246, !85, i64 248, !85, i64 250, !85, i64 252, !85, i64 254, !85, i64 256, !85, i64 258, !85, i64 260, !85, i64 262, !85, i64 264, !85, i64 266, !85, i64 268, !83, i64 272, !83, i64 280, !83, i64 288, !83, i64 296, !83, i64 304, !83, i64 312, !85, i64 320, !85, i64 322, !83, i64 328}
!83 = !{!"omnipotent char", !84, i64 0}
!84 = !{!"Simple C++ TBAA"}
!85 = !{!"half", !83, i64 0}
!86 = !{!87, !85, i64 132}
!87 = !{!"_ZTS29AsukaPerShader_PerCamera_Type", !83, i64 0, !83, i64 64, !83, i64 80, !83, i64 88, !83, i64 96, !83, i64 112, !85, i64 128, !85, i64 130, !85, i64 132}
!88 = !{!73}
!89 = !{!72, !74, !75, !76, !77, !78, !68, !70}
!90 = !{!82, !85, i64 242}
!91 = !{!82, !85, i64 244}
!92 = !{!82, !85, i64 246}
!93 = !{!82, !85, i64 248}
!94 = !{!82, !85, i64 250}
!95 = !{!82, !85, i64 252}
!96 = !{!82, !85, i64 254}
!97 = !{!82, !85, i64 256}
!98 = !{!82, !85, i64 258}
!99 = !{!82, !85, i64 320}
!100 = !{!82, !85, i64 322}
!101 = !{!83, !83, i64 0}
!102 = !{!82, !85, i64 260}
!103 = !{!82, !85, i64 262}
!104 = !{!82, !85, i64 266}
!105 = !{!82, !85, i64 264}
!106 = !{!82, !85, i64 268}
!107 = !{!74}
!108 = !{!72, !73, !75, !76, !77, !78, !68, !70}
!109 = !{!78}
!110 = !{!72, !73, !74, !75, !76, !77, !68, !70}
!111 = !{!82, !85, i64 54}
!112 = !{!113, !85, i64 50}
!113 = !{!"_ZTS20Character_Param_Type", !83, i64 0, !83, i64 16, !83, i64 24, !83, i64 32, !83, i64 40, !85, i64 48, !85, i64 50, !85, i64 52, !85, i64 54, !85, i64 56, !85, i64 58, !83, i64 64, !83, i64 72, !83, i64 80, !83, i64 88, !85, i64 96}
!114 = !{!76}
!115 = !{!72, !73, !74, !75, !77, !78, !68, !70}
!116 = !{!75}
!117 = !{!72, !73, !74, !76, !77, !78, !68, !70}
!118 = !{!113, !85, i64 48}
!119 = !{!72}
!120 = !{!73, !74, !75, !76, !77, !78, !68, !70}
!121 = !{!82, !85, i64 66}
!122 = !{!87, !85, i64 130}
