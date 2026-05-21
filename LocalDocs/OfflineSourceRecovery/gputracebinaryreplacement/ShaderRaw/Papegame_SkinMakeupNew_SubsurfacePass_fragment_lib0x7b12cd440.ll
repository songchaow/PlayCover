; ModuleID = '/var/folders/5r/zwp4q1153b76l363s2tttjf40000gn/T/lysk-trace-XXXXXX.vOgZqXTYY2/rps491/library_390.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.UnityPerMaterial_Type = type { <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, half, half, half, half, half, half, half, half, half, half, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, <3 x half>, half, half, half, half, half, half, half, half, half, half, half, half, half, half, half, <3 x half> }
%struct.AsukaPerShader_PerCamera_Type = type { [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float>, half, half, half, [10 x i8] }
%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }
%struct.PapePerRendererCB_Type = type { [7 x <4 x half>], [7 x <4 x half>], <4 x half>, half, half, half, half, half, half }
%struct.Character_Param_Type = type { <4 x float>, <4 x half>, <4 x half>, <4 x half>, <3 x half>, half, half, half, half, half, half, <4 x half>, <4 x half>, <4 x half>, <4 x half>, half, [14 x i8] }
%struct.AsukaPerShader_AddLightParams_PerCamera_Type = type { [30 x <4 x float>], [30 x <4 x float>], <4 x half>, [30 x <4 x half>], [30 x <4 x half>], [30 x <4 x float>], [30 x <4 x half>] }

; Function Attrs: convergent nounwind optsize memory(read)
define <{ <4 x half>, half }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(2176) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(144) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %2, ptr addrspace(2) readonly captures(none) dereferenceable(112) "air-buffer-no-alias" %3, ptr addrspace(2) readonly captures(none) dereferenceable(280) "air-buffer-no-alias" %4, ptr addrspace(2) readonly captures(none) dereferenceable(136) "air-buffer-no-alias" %5, ptr addrspace(2) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %9, ptr addrspace(2) readonly captures(none) %10, ptr addrspace(1) %11, ptr addrspace(1) %12, ptr addrspace(1) %13, ptr addrspace(1) %14, ptr addrspace(1) %15, <4 x half> %16, <4 x half> %17, <3 x float> %18, <4 x half> %19, <4 x half> %20, <4 x half> %21, <4 x float> %22) local_unnamed_addr #0 {
  %24 = shufflevector <4 x half> %16, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %25 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %24) #1
  %26 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %12, ptr addrspace(2) readonly captures(none) %7, <2 x float> %25, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !48, !noalias !52
  %27 = extractelement <4 x half> %16, i64 0
  %28 = fcmp fast oge half %27, 0xH3800
  %29 = select fast i1 %28, float 1.000000e+00, float 0.000000e+00
  %30 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %4, i64 0, i32 14
  %31 = load half, ptr addrspace(2) %30, align 8, !alias.scope !59, !noalias !60
  %32 = fpext half %31 to float
  %33 = select reassoc contract i1 %28, float 0.000000e+00, float %32
  %34 = getelementptr inbounds %struct.UnityPerMaterial_Type, ptr addrspace(2) %4, i64 0, i32 13
  %35 = load half, ptr addrspace(2) %34, align 2, !tbaa !61, !alias.scope !59, !noalias !60
  %36 = fpext half %35 to float
  %37 = tail call fast float @air.fma.f32(float %36, float %29, float %33) #1
  %38 = fptrunc float %37 to half
  %39 = insertelement <4 x half> undef, half %38, i64 0
  %40 = shufflevector <4 x half> %17, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %41 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %40) #1
  %42 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %14, ptr addrspace(2) readonly captures(none) %9, <2 x float> %41, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !48, !noalias !52
  %43 = extractvalue { <4 x half>, i8 } %42, 0
  %44 = shufflevector <4 x half> %43, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %45 = tail call fast <2 x half> @air.fma.v2f16(<2 x half> %44, <2 x half> splat (half 0xH4000), <2 x half> splat (half 0xHBC00)) #1
  %46 = shufflevector <2 x half> %45, <2 x half> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %47 = tail call fast half @air.dot.v2f16(<2 x half> %45, <2 x half> %45) #1
  %48 = tail call fast half @air.fmin.f16(half %47, half 0xH3C00) #1
  %49 = fsub fast half 0xH3C00, %48
  %50 = tail call fast half @air.sqrt.f16(half %49) #1
  %51 = insertelement <4 x half> %46, half %50, i64 2
  %52 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 8
  %53 = load half, ptr addrspace(2) %52, align 4, !tbaa !66, !alias.scope !68, !noalias !69
  %54 = fpext half %53 to float
  %55 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %13, ptr addrspace(2) readonly captures(none) %8, <2 x float> %25, i1 true, <2 x i32> zeroinitializer, i1 false, float %54, float 0.000000e+00, i32 0) #2, !alias.scope !48, !noalias !52
  %56 = extractvalue { <4 x half>, i8 } %55, 0
  %57 = tail call fast <4 x half> @air.fma.v4f16(<4 x half> %56, <4 x half> splat (half 0xH4000), <4 x half> splat (half 0xHBC00)) #1
  %58 = shufflevector <4 x half> %57, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %59 = tail call fast half @air.dot.v2f16(<2 x half> %58, <2 x half> %58) #1
  %60 = tail call fast half @air.fmin.f16(half %59, half 0xH3C00) #1
  %61 = fsub fast half 0xH3C00, %60
  %62 = tail call fast half @air.sqrt.f16(half %61) #1
  %63 = shufflevector <4 x half> %57, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %64 = tail call fast half @air.dot.v2f16(<2 x half> %63, <2 x half> %63) #1
  %65 = tail call fast half @air.fmin.f16(half %64, half 0xH3C00) #1
  %66 = fsub fast half 0xH3C00, %65
  %67 = tail call fast half @air.sqrt.f16(half %66) #1
  %68 = insertelement <4 x half> %57, half %62, i64 2
  %69 = shufflevector <4 x half> %68, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %70 = fsub fast <4 x half> %51, %68
  %71 = shufflevector <4 x half> %70, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %72 = shufflevector <4 x half> %43, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %73 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %72, <3 x half> %71, <3 x half> %69) #1
  %74 = shufflevector <2 x half> %63, <2 x half> undef, <3 x i32> <i32 0, i32 1, i32 poison>
  %75 = insertelement <3 x half> %74, half %67, i64 2
  %76 = fsub fast <3 x half> %75, %73
  %77 = shufflevector <4 x half> %39, <4 x half> undef, <3 x i32> zeroinitializer
  %78 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %77, <3 x half> %76, <3 x half> %73) #1
  %79 = shufflevector <3 x half> %78, <3 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %80 = shufflevector <4 x half> %21, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %81 = fmul fast <3 x half> %80, %79
  %82 = shufflevector <3 x half> %78, <3 x half> undef, <3 x i32> zeroinitializer
  %83 = shufflevector <4 x half> %20, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %84 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %82, <3 x half> %83, <3 x half> %81) #1
  %85 = shufflevector <3 x half> %78, <3 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %86 = shufflevector <4 x half> %19, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %87 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %85, <3 x half> %86, <3 x half> %84) #1
  %88 = tail call fast half @air.dot.v3f16(<3 x half> %87, <3 x half> %87) #1
  %89 = tail call fast half @air.rsqrt.f16(half %88) #1
  %90 = insertelement <3 x half> undef, half %89, i64 0
  %91 = shufflevector <3 x half> %90, <3 x half> undef, <3 x i32> zeroinitializer
  %92 = fmul fast <3 x half> %87, %91
  %93 = extractelement <4 x float> %22, i64 0
  %94 = insertelement <2 x float> undef, float %93, i64 0
  %95 = extractelement <4 x float> %22, i64 1
  %96 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %2, i64 0, i32 10
  %97 = load <4 x float>, ptr addrspace(2) %96, align 16, !alias.scope !70, !noalias !71
  %98 = extractelement <4 x float> %97, i64 0
  %99 = fmul fast float %95, %98
  %100 = insertelement <2 x float> %94, float %99, i64 1
  %101 = shufflevector <4 x float> %22, <4 x float> undef, <2 x i32> <i32 3, i32 3>
  %102 = fdiv fast <2 x float> %100, %101
  %103 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %102, <2 x float> splat (float 5.000000e-01), <2 x float> splat (float 5.000000e-01)) #1
  %104 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 0
  %105 = load <4 x half>, ptr addrspace(2) %104, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %106 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 1
  %107 = load <4 x half>, ptr addrspace(2) %106, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %108 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 2
  %109 = load <4 x half>, ptr addrspace(2) %108, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %110 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 3
  %111 = load <4 x half>, ptr addrspace(2) %110, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %112 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 4
  %113 = load <4 x half>, ptr addrspace(2) %112, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %114 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 5
  %115 = load <4 x half>, ptr addrspace(2) %114, align 8, !tbaa !72, !alias.scope !73, !noalias !74
  %116 = getelementptr inbounds %struct.PapePerRendererCB_Type, ptr addrspace(2) %5, i64 0, i32 0, i64 6
  %117 = load <4 x half>, ptr addrspace(2) %116, align 8, !alias.scope !73, !noalias !74
  %118 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %15, ptr addrspace(2) readonly captures(none) %10, <2 x float> %103, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !48, !noalias !52
  %119 = extractvalue { <4 x half>, i8 } %118, 0
  %120 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 6
  %121 = load half, ptr addrspace(2) %120, align 2, !tbaa !75, !alias.scope !77, !noalias !78
  %122 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %92) #1
  %123 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 1
  %124 = load <4 x float>, ptr addrspace(2) %123, align 16, !alias.scope !68, !noalias !69
  %125 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 2
  %126 = load <4 x half>, ptr addrspace(2) %125, align 8, !alias.scope !77, !noalias !78
  %127 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 0
  %128 = load <4 x float>, ptr addrspace(2) %127, align 16, !alias.scope !77, !noalias !78
  %129 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 3
  %130 = load <4 x half>, ptr addrspace(2) %129, align 16, !alias.scope !77, !noalias !78
  %131 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 4
  %132 = load <3 x half>, ptr addrspace(2) %131, align 8, !alias.scope !77, !noalias !78
  %133 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 7
  %134 = load half, ptr addrspace(2) %133, align 4, !tbaa !79, !alias.scope !77, !noalias !78
  %135 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 1
  %136 = load <4 x half>, ptr addrspace(2) %135, align 16, !alias.scope !77, !noalias !78
  %137 = getelementptr inbounds %struct.Character_Param_Type, ptr addrspace(2) %3, i64 0, i32 5
  %138 = load half, ptr addrspace(2) %137, align 16, !tbaa !80, !alias.scope !77, !noalias !78
  %139 = shufflevector <3 x float> %18, <3 x float> undef, <2 x i32> <i32 0, i32 2>
  %140 = getelementptr inbounds %struct.AsukaPerShader_PerCamera_Type, ptr addrspace(2) %1, i64 0, i32 4
  %141 = load <4 x half>, ptr addrspace(2) %140, align 16, !alias.scope !68, !noalias !69
  %142 = shufflevector <4 x half> %141, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %143 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %142) #1
  %144 = fsub fast <2 x float> %139, %143
  %145 = shufflevector <4 x half> %141, <4 x half> undef, <2 x i32> <i32 2, i32 3>
  %146 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %145) #1
  %147 = fdiv fast <2 x float> %144, %146
  %148 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %11, ptr addrspace(2) readonly captures(none) %6, <2 x float> %147, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !48, !noalias !52
  %149 = extractvalue { <4 x half>, i8 } %148, 0
  %150 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %149) #1
  %151 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %150, <4 x float> splat (float 2.550000e+02), <4 x float> splat (float 5.000000e-01)) #1
  %152 = tail call fast <4 x float> @air.fast_floor.v4f32(<4 x float> %151) #1
  %153 = fsub fast <4 x half> splat (half 0xH3C00), %119
  %154 = fcmp fast olt <4 x float> %152, splat (float 3.000000e+01)
  %155 = extractelement <4 x i1> %154, i64 0
  br i1 %155, label %156, label %164

156:                                              ; preds = %23
  %157 = extractelement <4 x float> %152, i64 0
  %158 = tail call i32 @air.convert.u.i32.f.f32(float %157) #1
  %159 = sext i32 %158 to i64
  %160 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %159
  %161 = load <4 x half>, ptr addrspace(2) %160, align 8, !tbaa !72, !alias.scope !81, !noalias !82
  %162 = tail call fast half @air.dot.v4f16(<4 x half> %153, <4 x half> %161) #1
  %163 = insertelement <4 x half> undef, half %162, i64 0
  br label %164

164:                                              ; preds = %156, %23
  %165 = phi <4 x half> [ %163, %156 ], [ <half 0xH3C00, half undef, half undef, half undef>, %23 ]
  %166 = extractelement <4 x i1> %154, i64 1
  br i1 %166, label %167, label %175

167:                                              ; preds = %164
  %168 = extractelement <4 x float> %152, i64 1
  %169 = tail call i32 @air.convert.u.i32.f.f32(float %168) #1
  %170 = sext i32 %169 to i64
  %171 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %170
  %172 = load <4 x half>, ptr addrspace(2) %171, align 8, !tbaa !72, !alias.scope !81, !noalias !82
  %173 = tail call fast half @air.dot.v4f16(<4 x half> %153, <4 x half> %172) #1
  %174 = insertelement <4 x half> %165, half %173, i64 1
  br label %177

175:                                              ; preds = %164
  %176 = insertelement <4 x half> %165, half 0xH3C00, i64 1
  br label %177

177:                                              ; preds = %175, %167
  %178 = phi <4 x half> [ %174, %167 ], [ %176, %175 ]
  %179 = extractelement <4 x i1> %154, i64 2
  br i1 %179, label %180, label %188

180:                                              ; preds = %177
  %181 = extractelement <4 x float> %152, i64 2
  %182 = tail call i32 @air.convert.u.i32.f.f32(float %181) #1
  %183 = sext i32 %182 to i64
  %184 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %183
  %185 = load <4 x half>, ptr addrspace(2) %184, align 8, !tbaa !72, !alias.scope !81, !noalias !82
  %186 = tail call fast half @air.dot.v4f16(<4 x half> %153, <4 x half> %185) #1
  %187 = insertelement <4 x half> %178, half %186, i64 2
  br label %190

188:                                              ; preds = %177
  %189 = insertelement <4 x half> %178, half 0xH3C00, i64 2
  br label %190

190:                                              ; preds = %188, %180
  %191 = phi <4 x half> [ %187, %180 ], [ %189, %188 ]
  %192 = extractelement <4 x i1> %154, i64 3
  br i1 %192, label %193, label %201

193:                                              ; preds = %190
  %194 = extractelement <4 x float> %152, i64 3
  %195 = tail call i32 @air.convert.u.i32.f.f32(float %194) #1
  %196 = sext i32 %195 to i64
  %197 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 6, i64 %196
  %198 = load <4 x half>, ptr addrspace(2) %197, align 8, !tbaa !72, !alias.scope !81, !noalias !82
  %199 = tail call fast half @air.dot.v4f16(<4 x half> %153, <4 x half> %198) #1
  %200 = insertelement <4 x half> %191, half %199, i64 3
  br label %203

201:                                              ; preds = %190
  %202 = insertelement <4 x half> %191, half 0xH3C00, i64 3
  br label %203

203:                                              ; preds = %201, %193
  %204 = phi <4 x half> [ %200, %193 ], [ %202, %201 ]
  %205 = extractelement <4 x float> %152, i64 0
  %206 = fcmp fast olt float %205, 2.550000e+02
  br i1 %206, label %207, label %463

207:                                              ; preds = %203
  %208 = fsub fast <4 x half> splat (half 0xH3C00), %204
  %209 = extractelement <4 x half> %208, i64 0
  %210 = fcmp fast ogt half %209, 0xH1419
  br i1 %210, label %211, label %268

211:                                              ; preds = %207
  %212 = tail call i32 @air.convert.s.i32.f.f32(float %205) #1
  %213 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %18
  %214 = sext i32 %212 to i64
  %215 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %214
  %216 = load <4 x float>, ptr addrspace(2) %215, align 16, !alias.scope !81, !noalias !82
  %217 = shufflevector <4 x float> %216, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %218 = shufflevector <4 x float> %216, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %219 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %213, <3 x float> %217, <3 x float> %218) #1
  %220 = tail call fast float @air.dot.v3f32(<3 x float> %219, <3 x float> %219) #1
  %221 = tail call fast float @air.fast_fmax.f32(float %220, float 0x3810000000000000) #1
  %222 = tail call fast float @air.fast_rsqrt.f32(float %221) #1
  %223 = insertelement <3 x float> undef, float %222, i64 0
  %224 = shufflevector <3 x float> %223, <3 x float> undef, <3 x i32> zeroinitializer
  %225 = fmul fast <3 x float> %219, %224
  %226 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %214
  %227 = load <4 x half>, ptr addrspace(2) %226, align 8, !alias.scope !81, !noalias !82
  %228 = extractelement <4 x half> %227, i64 0
  %229 = fpext half %228 to float
  %230 = tail call fast float @air.fma.f32(float %221, float %229, float 1.000000e+00) #1
  %231 = extractelement <4 x half> %227, i64 1
  %232 = fpext half %231 to float
  %233 = extractelement <4 x half> %227, i64 2
  %234 = fpext half %233 to float
  %235 = tail call fast float @air.fma.f32(float %221, float %232, float %234) #1
  %236 = tail call fast float @air.fast_clamp.f32(float %235, float 0.000000e+00, float 1.000000e+00) #1
  %237 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %214
  %238 = load <4 x float>, ptr addrspace(2) %237, align 16, !alias.scope !81, !noalias !82
  %239 = shufflevector <4 x float> %238, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %240 = tail call fast float @air.dot.v3f32(<3 x float> %239, <3 x float> %225) #1
  %241 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %214
  %242 = load <4 x float>, ptr addrspace(2) %241, align 16, !alias.scope !81, !noalias !82
  %243 = extractelement <4 x float> %242, i64 0
  %244 = extractelement <4 x float> %242, i64 1
  %245 = tail call fast float @air.fma.f32(float %240, float %243, float %244) #1
  %246 = tail call fast float @air.fast_clamp.f32(float %245, float 0.000000e+00, float 1.000000e+00) #1
  %247 = fmul fast float %246, %246
  %248 = fmul fast float %236, %247
  %249 = fdiv fast float %248, %230
  %250 = shufflevector <4 x half> %208, <4 x half> undef, <3 x i32> zeroinitializer
  %251 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %214
  %252 = load <4 x half>, ptr addrspace(2) %251, align 8, !alias.scope !81, !noalias !82
  %253 = shufflevector <4 x half> %252, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %254 = fmul fast <3 x half> %250, %253
  %255 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %225) #1
  %256 = fptrunc float %255 to half
  %257 = tail call fast half @air.fmax.f16(half %256, half 0xH0000) #1
  %258 = fmul fast <3 x half> %254, splat (half 0xH3518)
  %259 = insertelement <3 x float> undef, float %249, i64 0
  %260 = shufflevector <3 x float> %259, <3 x float> undef, <3 x i32> zeroinitializer
  %261 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %258) #1
  %262 = fmul fast <3 x float> %260, %261
  %263 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %262) #1
  %264 = insertelement <3 x half> undef, half %257, i64 0
  %265 = shufflevector <3 x half> %264, <3 x half> undef, <3 x i32> zeroinitializer
  %266 = fmul fast <3 x half> %265, %263
  %267 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %266, <3 x half> zeroinitializer) #1
  br label %268

268:                                              ; preds = %211, %207
  %269 = phi <3 x half> [ %267, %211 ], [ zeroinitializer, %207 ]
  %270 = extractelement <4 x float> %152, i64 1
  %271 = fcmp fast olt float %270, 2.550000e+02
  br i1 %271, label %272, label %463

272:                                              ; preds = %268
  %273 = extractelement <4 x half> %208, i64 1
  %274 = fcmp fast ogt half %273, 0xH1419
  br i1 %274, label %275, label %333

275:                                              ; preds = %272
  %276 = tail call i32 @air.convert.s.i32.f.f32(float %270) #1
  %277 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %18
  %278 = sext i32 %276 to i64
  %279 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %278
  %280 = load <4 x float>, ptr addrspace(2) %279, align 16, !alias.scope !81, !noalias !82
  %281 = shufflevector <4 x float> %280, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %282 = shufflevector <4 x float> %280, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %283 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %277, <3 x float> %281, <3 x float> %282) #1
  %284 = tail call fast float @air.dot.v3f32(<3 x float> %283, <3 x float> %283) #1
  %285 = tail call fast float @air.fast_fmax.f32(float %284, float 0x3810000000000000) #1
  %286 = tail call fast float @air.fast_rsqrt.f32(float %285) #1
  %287 = insertelement <3 x float> undef, float %286, i64 0
  %288 = shufflevector <3 x float> %287, <3 x float> undef, <3 x i32> zeroinitializer
  %289 = fmul fast <3 x float> %283, %288
  %290 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %278
  %291 = load <4 x half>, ptr addrspace(2) %290, align 8, !alias.scope !81, !noalias !82
  %292 = extractelement <4 x half> %291, i64 0
  %293 = fpext half %292 to float
  %294 = tail call fast float @air.fma.f32(float %285, float %293, float 1.000000e+00) #1
  %295 = extractelement <4 x half> %291, i64 1
  %296 = fpext half %295 to float
  %297 = extractelement <4 x half> %291, i64 2
  %298 = fpext half %297 to float
  %299 = tail call fast float @air.fma.f32(float %285, float %296, float %298) #1
  %300 = tail call fast float @air.fast_clamp.f32(float %299, float 0.000000e+00, float 1.000000e+00) #1
  %301 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %278
  %302 = load <4 x float>, ptr addrspace(2) %301, align 16, !alias.scope !81, !noalias !82
  %303 = shufflevector <4 x float> %302, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %304 = tail call fast float @air.dot.v3f32(<3 x float> %303, <3 x float> %289) #1
  %305 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %278
  %306 = load <4 x float>, ptr addrspace(2) %305, align 16, !alias.scope !81, !noalias !82
  %307 = extractelement <4 x float> %306, i64 0
  %308 = extractelement <4 x float> %306, i64 1
  %309 = tail call fast float @air.fma.f32(float %304, float %307, float %308) #1
  %310 = tail call fast float @air.fast_clamp.f32(float %309, float 0.000000e+00, float 1.000000e+00) #1
  %311 = fmul fast float %310, %310
  %312 = fmul fast float %300, %311
  %313 = fdiv fast float %312, %294
  %314 = shufflevector <4 x half> %208, <4 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %315 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %278
  %316 = load <4 x half>, ptr addrspace(2) %315, align 8, !alias.scope !81, !noalias !82
  %317 = shufflevector <4 x half> %316, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %318 = fmul fast <3 x half> %314, %317
  %319 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %289) #1
  %320 = fptrunc float %319 to half
  %321 = tail call fast half @air.fmax.f16(half %320, half 0xH0000) #1
  %322 = fmul fast <3 x half> %318, splat (half 0xH3518)
  %323 = insertelement <3 x float> undef, float %313, i64 0
  %324 = shufflevector <3 x float> %323, <3 x float> undef, <3 x i32> zeroinitializer
  %325 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %322) #1
  %326 = fmul fast <3 x float> %324, %325
  %327 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %326) #1
  %328 = insertelement <3 x half> undef, half %321, i64 0
  %329 = shufflevector <3 x half> %328, <3 x half> undef, <3 x i32> zeroinitializer
  %330 = fmul fast <3 x half> %329, %327
  %331 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %330, <3 x half> zeroinitializer) #1
  %332 = fadd fast <3 x half> %269, %331
  br label %333

333:                                              ; preds = %275, %272
  %334 = phi <3 x half> [ %332, %275 ], [ %269, %272 ]
  %335 = extractelement <4 x float> %152, i64 2
  %336 = fcmp fast olt float %335, 2.550000e+02
  br i1 %336, label %337, label %463

337:                                              ; preds = %333
  %338 = extractelement <4 x half> %208, i64 2
  %339 = fcmp fast ogt half %338, 0xH1419
  br i1 %339, label %340, label %398

340:                                              ; preds = %337
  %341 = tail call i32 @air.convert.s.i32.f.f32(float %335) #1
  %342 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %18
  %343 = sext i32 %341 to i64
  %344 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %343
  %345 = load <4 x float>, ptr addrspace(2) %344, align 16, !alias.scope !81, !noalias !82
  %346 = shufflevector <4 x float> %345, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %347 = shufflevector <4 x float> %345, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %348 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %342, <3 x float> %346, <3 x float> %347) #1
  %349 = tail call fast float @air.dot.v3f32(<3 x float> %348, <3 x float> %348) #1
  %350 = tail call fast float @air.fast_fmax.f32(float %349, float 0x3810000000000000) #1
  %351 = tail call fast float @air.fast_rsqrt.f32(float %350) #1
  %352 = insertelement <3 x float> undef, float %351, i64 0
  %353 = shufflevector <3 x float> %352, <3 x float> undef, <3 x i32> zeroinitializer
  %354 = fmul fast <3 x float> %348, %353
  %355 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %343
  %356 = load <4 x half>, ptr addrspace(2) %355, align 8, !alias.scope !81, !noalias !82
  %357 = extractelement <4 x half> %356, i64 0
  %358 = fpext half %357 to float
  %359 = tail call fast float @air.fma.f32(float %350, float %358, float 1.000000e+00) #1
  %360 = extractelement <4 x half> %356, i64 1
  %361 = fpext half %360 to float
  %362 = extractelement <4 x half> %356, i64 2
  %363 = fpext half %362 to float
  %364 = tail call fast float @air.fma.f32(float %350, float %361, float %363) #1
  %365 = tail call fast float @air.fast_clamp.f32(float %364, float 0.000000e+00, float 1.000000e+00) #1
  %366 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %343
  %367 = load <4 x float>, ptr addrspace(2) %366, align 16, !alias.scope !81, !noalias !82
  %368 = shufflevector <4 x float> %367, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %369 = tail call fast float @air.dot.v3f32(<3 x float> %368, <3 x float> %354) #1
  %370 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %343
  %371 = load <4 x float>, ptr addrspace(2) %370, align 16, !alias.scope !81, !noalias !82
  %372 = extractelement <4 x float> %371, i64 0
  %373 = extractelement <4 x float> %371, i64 1
  %374 = tail call fast float @air.fma.f32(float %369, float %372, float %373) #1
  %375 = tail call fast float @air.fast_clamp.f32(float %374, float 0.000000e+00, float 1.000000e+00) #1
  %376 = fmul fast float %375, %375
  %377 = fmul fast float %365, %376
  %378 = fdiv fast float %377, %359
  %379 = shufflevector <4 x half> %208, <4 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %380 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %343
  %381 = load <4 x half>, ptr addrspace(2) %380, align 8, !alias.scope !81, !noalias !82
  %382 = shufflevector <4 x half> %381, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %383 = fmul fast <3 x half> %379, %382
  %384 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %354) #1
  %385 = fptrunc float %384 to half
  %386 = tail call fast half @air.fmax.f16(half %385, half 0xH0000) #1
  %387 = fmul fast <3 x half> %383, splat (half 0xH3518)
  %388 = insertelement <3 x float> undef, float %378, i64 0
  %389 = shufflevector <3 x float> %388, <3 x float> undef, <3 x i32> zeroinitializer
  %390 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %387) #1
  %391 = fmul fast <3 x float> %389, %390
  %392 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %391) #1
  %393 = insertelement <3 x half> undef, half %386, i64 0
  %394 = shufflevector <3 x half> %393, <3 x half> undef, <3 x i32> zeroinitializer
  %395 = fmul fast <3 x half> %394, %392
  %396 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %395, <3 x half> zeroinitializer) #1
  %397 = fadd fast <3 x half> %334, %396
  br label %398

398:                                              ; preds = %340, %337
  %399 = phi <3 x half> [ %397, %340 ], [ %334, %337 ]
  %400 = extractelement <4 x float> %152, i64 3
  %401 = fcmp fast olt float %400, 2.550000e+02
  %402 = extractelement <4 x half> %208, i64 3
  %403 = fcmp fast ogt half %402, 0xH1419
  %404 = select i1 %401, i1 %403, i1 false
  br i1 %404, label %405, label %463

405:                                              ; preds = %398
  %406 = tail call i32 @air.convert.s.i32.f.f32(float %400) #1
  %407 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %18
  %408 = sext i32 %406 to i64
  %409 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 0, i64 %408
  %410 = load <4 x float>, ptr addrspace(2) %409, align 16, !alias.scope !81, !noalias !82
  %411 = shufflevector <4 x float> %410, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %412 = shufflevector <4 x float> %410, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %413 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %407, <3 x float> %411, <3 x float> %412) #1
  %414 = tail call fast float @air.dot.v3f32(<3 x float> %413, <3 x float> %413) #1
  %415 = tail call fast float @air.fast_fmax.f32(float %414, float 0x3810000000000000) #1
  %416 = tail call fast float @air.fast_rsqrt.f32(float %415) #1
  %417 = insertelement <3 x float> undef, float %416, i64 0
  %418 = shufflevector <3 x float> %417, <3 x float> undef, <3 x i32> zeroinitializer
  %419 = fmul fast <3 x float> %413, %418
  %420 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 4, i64 %408
  %421 = load <4 x half>, ptr addrspace(2) %420, align 8, !alias.scope !81, !noalias !82
  %422 = extractelement <4 x half> %421, i64 0
  %423 = fpext half %422 to float
  %424 = tail call fast float @air.fma.f32(float %415, float %423, float 1.000000e+00) #1
  %425 = extractelement <4 x half> %421, i64 1
  %426 = fpext half %425 to float
  %427 = extractelement <4 x half> %421, i64 2
  %428 = fpext half %427 to float
  %429 = tail call fast float @air.fma.f32(float %415, float %426, float %428) #1
  %430 = tail call fast float @air.fast_clamp.f32(float %429, float 0.000000e+00, float 1.000000e+00) #1
  %431 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 %408
  %432 = load <4 x float>, ptr addrspace(2) %431, align 16, !alias.scope !81, !noalias !82
  %433 = shufflevector <4 x float> %432, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %434 = tail call fast float @air.dot.v3f32(<3 x float> %433, <3 x float> %419) #1
  %435 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 1, i64 %408
  %436 = load <4 x float>, ptr addrspace(2) %435, align 16, !alias.scope !81, !noalias !82
  %437 = extractelement <4 x float> %436, i64 0
  %438 = extractelement <4 x float> %436, i64 1
  %439 = tail call fast float @air.fma.f32(float %434, float %437, float %438) #1
  %440 = tail call fast float @air.fast_clamp.f32(float %439, float 0.000000e+00, float 1.000000e+00) #1
  %441 = fmul fast float %440, %440
  %442 = fmul fast float %430, %441
  %443 = fdiv fast float %442, %424
  %444 = shufflevector <4 x half> %208, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %445 = getelementptr inbounds %struct.AsukaPerShader_AddLightParams_PerCamera_Type, ptr addrspace(2) %0, i64 0, i32 3, i64 %408
  %446 = load <4 x half>, ptr addrspace(2) %445, align 8, !alias.scope !81, !noalias !82
  %447 = shufflevector <4 x half> %446, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %448 = fmul fast <3 x half> %444, %447
  %449 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %419) #1
  %450 = fptrunc float %449 to half
  %451 = tail call fast half @air.fmax.f16(half %450, half 0xH0000) #1
  %452 = insertelement <4 x half> undef, half %451, i64 0
  %453 = fmul fast <3 x half> %448, splat (half 0xH3518)
  %454 = insertelement <3 x float> undef, float %443, i64 0
  %455 = shufflevector <3 x float> %454, <3 x float> undef, <3 x i32> zeroinitializer
  %456 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %453) #1
  %457 = fmul fast <3 x float> %455, %456
  %458 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %457) #1
  %459 = shufflevector <4 x half> %452, <4 x half> undef, <3 x i32> zeroinitializer
  %460 = fmul fast <3 x half> %459, %458
  %461 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %460, <3 x half> zeroinitializer) #1
  %462 = fadd fast <3 x half> %399, %461
  br label %463

463:                                              ; preds = %405, %398, %333, %268, %203
  %464 = phi <3 x half> [ %462, %405 ], [ %399, %398 ], [ %334, %333 ], [ %269, %268 ], [ zeroinitializer, %203 ]
  %465 = shufflevector <3 x half> %92, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %466 = insertelement <4 x half> %465, half 0xH3C00, i64 3
  %467 = tail call fast half @air.dot.v4f16(<4 x half> %105, <4 x half> %466) #1
  %468 = insertelement <3 x half> undef, half %467, i64 0
  %469 = tail call fast half @air.dot.v4f16(<4 x half> %107, <4 x half> %466) #1
  %470 = insertelement <3 x half> %468, half %469, i64 1
  %471 = tail call fast half @air.dot.v4f16(<4 x half> %109, <4 x half> %466) #1
  %472 = insertelement <3 x half> %470, half %471, i64 2
  %473 = shufflevector <4 x float> %128, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %474 = shufflevector <4 x half> %136, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %475 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %474) #1
  %476 = shufflevector <4 x half> %117, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %477 = extractelement <3 x half> %92, i64 0
  %478 = extractelement <3 x half> %92, i64 1
  %479 = fsub nnan ninf nsz arcp afn half 0xH8000, %478
  %480 = fmul fast half %478, %479
  %481 = tail call fast half @air.fma.f16(half %477, half %477, half %480) #1
  %482 = insertelement <3 x half> undef, half %481, i64 0
  %483 = shufflevector <3 x half> %482, <3 x half> undef, <3 x i32> zeroinitializer
  %484 = shufflevector <3 x half> %92, <3 x half> undef, <4 x i32> <i32 1, i32 2, i32 2, i32 0>
  %485 = shufflevector <3 x half> %92, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 2>
  %486 = fmul fast <4 x half> %484, %485
  %487 = tail call fast half @air.dot.v4f16(<4 x half> %111, <4 x half> %486) #1
  %488 = insertelement <3 x half> undef, half %487, i64 0
  %489 = tail call fast half @air.dot.v4f16(<4 x half> %113, <4 x half> %486) #1
  %490 = insertelement <3 x half> %488, half %489, i64 1
  %491 = tail call fast half @air.dot.v4f16(<4 x half> %115, <4 x half> %486) #1
  %492 = insertelement <3 x half> %490, half %491, i64 2
  %493 = fadd fast <3 x half> %472, %492
  %494 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %476, <3 x half> %483, <3 x half> %493) #1
  %495 = shufflevector <3 x half> %494, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %496 = shufflevector <4 x float> %124, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %497 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %496) #1
  %498 = fptrunc float %497 to half
  %499 = insertelement <4 x half> %495, half %498, i64 3
  %500 = tail call fast <4 x half> @air.fmax.v4f16(<4 x half> %499, <4 x half> zeroinitializer) #1
  %501 = shufflevector <4 x half> %500, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %502 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %501) #1
  %503 = fsub nnan ninf nsz arcp afn <3 x float> splat (float -0.000000e+00), %502
  %504 = extractelement <3 x float> %18, i64 1
  %505 = extractelement <3 x half> %132, i64 1
  %506 = fpext half %505 to float
  %507 = fsub fast float %504, %506
  %508 = tail call fast float @air.fast_fmax.f32(float %507, float -1.000000e+00) #1
  %509 = tail call fast float @air.fast_fmin.f32(float %508, float 1.000000e+00) #1
  %510 = fpext half %134 to float
  %511 = tail call fast float @air.fma.f32(float %509, float %510, float 1.000000e+00) #1
  %512 = insertelement <3 x float> undef, float %511, i64 0
  %513 = shufflevector <3 x float> %512, <3 x float> undef, <3 x i32> zeroinitializer
  %514 = shufflevector <4 x half> %136, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %515 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %514) #1
  %516 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %502, <3 x float> %513, <3 x float> %515) #1
  %517 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %516) #1
  %518 = tail call fast <3 x half> @air.clamp.v3f16(<3 x half> %517, <3 x half> zeroinitializer, <3 x half> splat (half 0xH3C00)) #1
  %519 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %518) #1
  %520 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %503, <3 x float> %513, <3 x float> %519) #1
  %521 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %520) #1
  %522 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %521) #1
  %523 = fmul fast <3 x float> %502, %513
  %524 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %475, <3 x float> %522, <3 x float> %523) #1
  %525 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %524) #1
  %526 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %525) #1
  %527 = tail call fast float @air.dot.v3f32(<3 x float> %523, <3 x float> <float 0x3FD322D0E0000000, float 0x3FE2C8B440000000, float 0x3FBD2F1AA0000000>) #1
  %528 = fptrunc float %527 to half
  %529 = fpext half %528 to float
  %530 = insertelement <3 x float> undef, float %529, i64 0
  %531 = shufflevector <3 x float> %530, <3 x float> undef, <3 x i32> zeroinitializer
  %532 = fsub fast <3 x float> %526, %531
  %533 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %473, <3 x float> %532, <3 x float> %531) #1
  %534 = fpext half %138 to float
  %535 = insertelement <3 x float> undef, float %534, i64 0
  %536 = shufflevector <3 x float> %535, <3 x float> undef, <3 x i32> zeroinitializer
  %537 = fmul fast <3 x float> %536, %533
  %538 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %537) #1
  %539 = shufflevector <4 x half> %119, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %540 = shufflevector <4 x float> %128, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %541 = tail call fast float @air.dot.v3f32(<3 x float> %122, <3 x float> %540) #1
  %542 = fptrunc float %541 to half
  %543 = tail call fast half @air.fmax.f16(half %542, half 0xH0000) #1
  %544 = insertelement <3 x half> undef, half %543, i64 0
  %545 = shufflevector <3 x half> %544, <3 x half> undef, <3 x i32> zeroinitializer
  %546 = shufflevector <4 x half> %130, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %547 = fmul fast <3 x half> %546, %545
  %548 = fmul fast <3 x half> %547, splat (half 0xH3518)
  %549 = extractelement <4 x half> %119, i64 0
  %550 = fadd fast half %549, 0xHBC00
  %551 = tail call fast half @air.fma.f16(half %550, half %121, half 0xH3C00) #1
  %552 = fcmp fast ogt half %551, 0xH1419
  %553 = insertelement <3 x half> undef, half %551, i64 0
  %554 = shufflevector <3 x half> %553, <3 x half> undef, <3 x i32> zeroinitializer
  %555 = shufflevector <4 x half> %500, <4 x half> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %556 = shufflevector <4 x half> %126, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %557 = fmul fast <3 x half> %556, %555
  %558 = fmul fast <3 x half> %557, %554
  %559 = fmul fast <3 x half> %558, splat (half 0xH3518)
  %560 = select fast i1 %552, <3 x half> %559, <3 x half> zeroinitializer
  %561 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %548, <3 x half> %539, <3 x half> %560) #1
  %562 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %538, <3 x half> %539, <3 x half> %561) #1
  %563 = extractvalue { <4 x half>, i8 } %26, 0
  %564 = extractelement <4 x half> %563, i64 1
  %565 = fadd fast <3 x half> %464, %562
  %566 = shufflevector <3 x half> %565, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %567 = fsub fast half 0xH3C00, %564
  %568 = insertelement <4 x half> %566, half %567, i64 3
  %569 = insertvalue <{ <4 x half>, half }> undef, <4 x half> %568, 0
  %570 = insertvalue <{ <4 x half>, half }> %569, half %567, 1
  ret <{ <4 x half>, half }> %570
}

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fma.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmax.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.clamp.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.fmax.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fmax.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_clamp.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fast_floor.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.rsqrt.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.sqrt.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmin.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v2f16(<2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.fma.v4f16(<4 x half>, <4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x half> @air.fma.v2f16(<2 x half>, <2 x half>, <2 x half>) local_unnamed_addr #1

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
!14 = !{ptr @xlatMtlMain, !15, !18}
!15 = !{!16, !17}
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_TARGET0"}
!17 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"half", !"air.arg_name", !"SV_TARGET1"}
!18 = !{!19, !21, !23, !25, !27, !29, !31, !32, !33, !34, !35, !36, !37, !38, !39, !40, !41, !42, !43, !44, !45, !46, !47}
!19 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 2176, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !20, !"air.arg_type_size", i32 2176, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"AsukaPerShader_AddLightParams_PerCamera_Type", !"air.arg_name", !"AsukaPerShader_AddLightParams_PerCamera"}
!20 = !{i32 0, i32 16, i32 30, !"float4", !"_AdditionalLightPosition", i32 480, i32 16, i32 30, !"float4", !"_AdditionalLightSpotAttenuation", i32 960, i32 8, i32 0, !"half4", !"_AdditionalLightCount", i32 968, i32 8, i32 30, !"half4", !"_AdditionalLightColor", i32 1208, i32 8, i32 30, !"half4", !"_AdditionalLightDistanceAttenuation", i32 1456, i32 16, i32 30, !"float4", !"_AdditionalLightSpotDir", i32 1936, i32 8, i32 30, !"half4", !"_AdditionalLightShadowWeight"}
!21 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 1, i32 1, !"air.read", !"air.struct_type_info", !22, !"air.arg_type_size", i32 144, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"AsukaPerShader_PerCamera_Type", !"air.arg_name", !"AsukaPerShader_PerCamera"}
!22 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_WorldToLight", i32 64, i32 16, i32 0, !"float4", !"_MainLightPosition", i32 80, i32 8, i32 0, !"half4", !"_MainLightColor", i32 88, i32 8, i32 0, !"half4", !"_ScaledScreenParams", i32 96, i32 8, i32 0, !"half4", !"_GridInfo", i32 112, i32 16, i32 0, !"float4", !"_AuroraGridInfo", i32 128, i32 2, i32 0, !"half", !"_MainLightRealtime", i32 130, i32 2, i32 0, !"half", !"_DOFEnable", i32 132, i32 2, i32 0, !"half", !"_GlobalMipBias"}
!23 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 2, i32 1, !"air.read", !"air.struct_type_info", !24, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!24 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!25 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 3, i32 1, !"air.read", !"air.struct_type_info", !26, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Character_Param_Type", !"air.arg_name", !"Character_Param"}
!26 = !{i32 0, i32 16, i32 0, !"float4", !"_CharLightPosition", i32 16, i32 8, i32 0, !"half4", !"_CharShColor", i32 24, i32 8, i32 0, !"half4", !"_CharMainLightColor", i32 32, i32 8, i32 0, !"half4", !"_CharLightColor", i32 40, i32 8, i32 0, !"half3", !"_RootMPosition", i32 48, i32 2, i32 0, !"half", !"_CharShIntensity", i32 50, i32 2, i32 0, !"half", !"_CharShadowIntensity", i32 52, i32 2, i32 0, !"half", !"_CharShHeight", i32 54, i32 2, i32 0, !"half", !"_ClipYValue", i32 56, i32 2, i32 0, !"half", !"_HomeLightingEnable", i32 58, i32 2, i32 0, !"half", !"_EyeAdaptionInverseExposureEnable", i32 64, i32 8, i32 0, !"half4", !"_HomeLightingPPVScale", i32 72, i32 8, i32 0, !"half4", !"_HomeLightingPPVColor0", i32 80, i32 8, i32 0, !"half4", !"_HomeLightingPPVColor1", i32 88, i32 8, i32 0, !"half4", !"_HomeRimLightingPPVColor", i32 96, i32 2, i32 0, !"half", !"_POSMEnabled"}
!27 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 280, !"air.location_index", i32 4, i32 1, !"air.read", !"air.struct_type_info", !28, !"air.arg_type_size", i32 280, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"UnityPerMaterial_Type", !"air.arg_name", !"UnityPerMaterial"}
!28 = !{i32 0, i32 8, i32 0, !"half4", !"_MainTex_ST", i32 8, i32 8, i32 0, !"half4", !"_Color", i32 16, i32 8, i32 0, !"half4", !"_FresnelColor", i32 24, i32 8, i32 0, !"half4", !"_OverlayColor", i32 32, i32 8, i32 0, !"half4", !"_SparkleUV", i32 40, i32 8, i32 0, !"half4", !"_SSSSkinTexture_TexelSize", i32 48, i32 2, i32 0, !"half", !"_Cutoff", i32 50, i32 2, i32 0, !"half", !"_ShadowIntensity", i32 52, i32 2, i32 0, !"half", !"_AOIntensity", i32 54, i32 2, i32 0, !"half", !"_NonMetalSpecular", i32 56, i32 2, i32 0, !"half", !"_FresnelIntensity", i32 58, i32 2, i32 0, !"half", !"_Fresnelpower", i32 60, i32 2, i32 0, !"half", !"_LerpValue", i32 62, i32 2, i32 0, !"half", !"_LeftEyeInfo", i32 64, i32 2, i32 0, !"half", !"_RightEyeInfo", i32 66, i32 2, i32 0, !"half", !"_DOFBlurFlag", i32 72, i32 8, i32 0, !"half4", !"_MakeupColor1", i32 80, i32 8, i32 0, !"half4", !"_MakeupColor2", i32 88, i32 8, i32 0, !"half4", !"_MakeupColor3", i32 96, i32 8, i32 0, !"half4", !"_MakeupColor4", i32 104, i32 8, i32 0, !"half4", !"_MakeupColor5", i32 112, i32 8, i32 0, !"half4", !"_MakeupColor6", i32 120, i32 8, i32 0, !"half4", !"_DecorateUV", i32 128, i32 8, i32 0, !"half4", !"_Decorate2UV", i32 136, i32 8, i32 0, !"half4", !"_MorphPartColor", i32 144, i32 8, i32 0, !"half4", !"_MorphPartShinningColor", i32 152, i32 8, i32 0, !"half4", !"_MorphPartSpreadColor", i32 160, i32 8, i32 0, !"half4", !"_MorphPartParam", i32 168, i32 8, i32 0, !"half4", !"_MorphPartTexUV", i32 176, i32 8, i32 0, !"half3", !"_EyebrowColor", i32 184, i32 8, i32 0, !"half3", !"_EyeshadowColor", i32 192, i32 8, i32 0, !"half3", !"_EyelinerColor", i32 200, i32 8, i32 0, !"half3", !"_LipColor", i32 208, i32 8, i32 0, !"half3", !"_BlusherColor", i32 216, i32 8, i32 0, !"half3", !"_DecorateColor", i32 224, i32 8, i32 0, !"half3", !"_Decorate2Color", i32 232, i32 8, i32 0, !"half3", !"_MakeupMultiplyColor", i32 240, i32 2, i32 0, !"half", !"_MakeupRoughness5", i32 242, i32 2, i32 0, !"half", !"_EyebrowDensity", i32 244, i32 2, i32 0, !"half", !"_EyeshadowDensity", i32 246, i32 2, i32 0, !"half", !"_EyelinerDensity", i32 248, i32 2, i32 0, !"half", !"_BlusherDensity", i32 250, i32 2, i32 0, !"half", !"_LipDensity", i32 252, i32 2, i32 0, !"half", !"_LipRoughness", i32 254, i32 2, i32 0, !"half", !"_LipSpecular", i32 256, i32 2, i32 0, !"half", !"_DecorateDensity", i32 258, i32 2, i32 0, !"half", !"_Decorate2Density", i32 260, i32 2, i32 0, !"half", !"_MorphPartId", i32 262, i32 2, i32 0, !"half", !"_MorphPartRange", i32 264, i32 2, i32 0, !"half", !"_MorphPartShinningAlpha", i32 266, i32 2, i32 0, !"half", !"_MorphPartWaveLength", i32 268, i32 2, i32 0, !"half", !"_MorphPartBreathAlpha", i32 272, i32 8, i32 0, !"half3", !"_EyelidColor"}
!29 = !{i32 5, !"air.buffer", !"air.buffer_size", i32 136, !"air.location_index", i32 5, i32 1, !"air.read", !"air.struct_type_info", !30, !"air.arg_type_size", i32 136, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"PapePerRendererCB_Type", !"air.arg_name", !"PapePerRendererCB"}
!30 = !{i32 0, i32 8, i32 7, !"half4", !"_SHMaps", i32 56, i32 8, i32 7, !"half4", !"_CubeSHs", i32 112, i32 8, i32 0, !"half4", !"_VegColor", i32 120, i32 2, i32 0, !"half", !"_VegetationInShadowLighting", i32 122, i32 2, i32 0, !"half", !"_VegetationIndirectSpecIntensity", i32 124, i32 2, i32 0, !"half", !"_IsNightMode", i32 126, i32 2, i32 0, !"half", !"_RampColorID0", i32 128, i32 2, i32 0, !"half", !"_RampColorID1", i32 130, i32 2, i32 0, !"half", !"_RampColorBlend"}
!31 = !{i32 6, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_LightIndexMap"}
!32 = !{i32 7, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SpecularTex"}
!33 = !{i32 8, !"air.sampler", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_NormalTex"}
!34 = !{i32 9, !"air.sampler", !"air.location_index", i32 3, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_EyelidTex"}
!35 = !{i32 10, !"air.sampler", !"air.location_index", i32 4, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ScreenShadowTexture"}
!36 = !{i32 11, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_LightIndexMap"}
!37 = !{i32 12, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SpecularTex"}
!38 = !{i32 13, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_NormalTex"}
!39 = !{i32 14, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_EyelidTex"}
!40 = !{i32 15, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ScreenShadowTexture"}
!41 = !{i32 16, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD0"}
!42 = !{i32 17, !"air.fragment_input", !"user(TEXCOORD1)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD1"}
!43 = !{i32 18, !"air.fragment_input", !"user(TEXCOORD2)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"TEXCOORD2"}
!44 = !{i32 19, !"air.fragment_input", !"user(TEXCOORD3)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD3"}
!45 = !{i32 20, !"air.fragment_input", !"user(TEXCOORD4)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD4"}
!46 = !{i32 21, !"air.fragment_input", !"user(TEXCOORD5)", !"air.center", !"air.perspective", !"air.arg_type_name", !"half4", !"air.arg_name", !"TEXCOORD5"}
!47 = !{i32 22, !"air.fragment_input", !"user(TEXCOORD6)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD6"}
!48 = !{!49, !51}
!49 = distinct !{!49, !50, !"air-alias-scope-samplers"}
!50 = distinct !{!50, !"air-alias-scopes(xlatMtlMain)"}
!51 = distinct !{!51, !50, !"air-alias-scope-textures"}
!52 = !{!53, !54, !55, !56, !57, !58}
!53 = distinct !{!53, !50, !"air-alias-scope-arg(0)"}
!54 = distinct !{!54, !50, !"air-alias-scope-arg(1)"}
!55 = distinct !{!55, !50, !"air-alias-scope-arg(2)"}
!56 = distinct !{!56, !50, !"air-alias-scope-arg(3)"}
!57 = distinct !{!57, !50, !"air-alias-scope-arg(4)"}
!58 = distinct !{!58, !50, !"air-alias-scope-arg(5)"}
!59 = !{!57}
!60 = !{!53, !54, !55, !56, !58, !49, !51}
!61 = !{!62, !65, i64 62}
!62 = !{!"_ZTS21UnityPerMaterial_Type", !63, i64 0, !63, i64 8, !63, i64 16, !63, i64 24, !63, i64 32, !63, i64 40, !65, i64 48, !65, i64 50, !65, i64 52, !65, i64 54, !65, i64 56, !65, i64 58, !65, i64 60, !65, i64 62, !65, i64 64, !65, i64 66, !63, i64 72, !63, i64 80, !63, i64 88, !63, i64 96, !63, i64 104, !63, i64 112, !63, i64 120, !63, i64 128, !63, i64 136, !63, i64 144, !63, i64 152, !63, i64 160, !63, i64 168, !63, i64 176, !63, i64 184, !63, i64 192, !63, i64 200, !63, i64 208, !63, i64 216, !63, i64 224, !63, i64 232, !65, i64 240, !65, i64 242, !65, i64 244, !65, i64 246, !65, i64 248, !65, i64 250, !65, i64 252, !65, i64 254, !65, i64 256, !65, i64 258, !65, i64 260, !65, i64 262, !65, i64 264, !65, i64 266, !65, i64 268, !63, i64 272}
!63 = !{!"omnipotent char", !64, i64 0}
!64 = !{!"Simple C++ TBAA"}
!65 = !{!"half", !63, i64 0}
!66 = !{!67, !65, i64 132}
!67 = !{!"_ZTS29AsukaPerShader_PerCamera_Type", !63, i64 0, !63, i64 64, !63, i64 80, !63, i64 88, !63, i64 96, !63, i64 112, !65, i64 128, !65, i64 130, !65, i64 132}
!68 = !{!54}
!69 = !{!53, !55, !56, !57, !58, !49, !51}
!70 = !{!55}
!71 = !{!53, !54, !56, !57, !58, !49, !51}
!72 = !{!63, !63, i64 0}
!73 = !{!58}
!74 = !{!53, !54, !55, !56, !57, !49, !51}
!75 = !{!76, !65, i64 50}
!76 = !{!"_ZTS20Character_Param_Type", !63, i64 0, !63, i64 16, !63, i64 24, !63, i64 32, !63, i64 40, !65, i64 48, !65, i64 50, !65, i64 52, !65, i64 54, !65, i64 56, !65, i64 58, !63, i64 64, !63, i64 72, !63, i64 80, !63, i64 88, !65, i64 96}
!77 = !{!56}
!78 = !{!53, !54, !55, !57, !58, !49, !51}
!79 = !{!76, !65, i64 52}
!80 = !{!76, !65, i64 48}
!81 = !{!53}
!82 = !{!54, !55, !56, !57, !58, !49, !51}
