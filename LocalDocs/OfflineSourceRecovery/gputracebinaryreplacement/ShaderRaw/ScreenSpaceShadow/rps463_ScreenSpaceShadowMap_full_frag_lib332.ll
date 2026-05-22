; ModuleID = '/tmp/lysk-verify/shadow/library_332.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct._ScreenSpaceShadowParams_Type = type { <2 x float>, float, <4 x float> }
%struct.UnityPerPass_Type = type { [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, [6 x <4 x half>] }
%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }
%struct._LocalLightShadowBuffer_Type = type { [12 x <4 x float>], <4 x half>, [4 x <4 x float>], <4 x float>, <4 x float> }
%struct._DirectionalShadowBuffer_Type = type { [20 x <4 x float>], [20 x <4 x float>], [16 x <4 x float>], [5 x <4 x float>], [16 x half], <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, [4 x float], <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x float>, [4 x <4 x float>], <4 x float>, float, float, float, [5 x <4 x float>] }

@_ZL7ImmCB_0 = internal unnamed_addr addrspace(2) constant [4 x <4 x float>] [<4 x float> <float 1.000000e+00, float 0.000000e+00, float 0.000000e+00, float 0.000000e+00>, <4 x float> <float 0.000000e+00, float 1.000000e+00, float 0.000000e+00, float 0.000000e+00>, <4 x float> <float 0.000000e+00, float 0.000000e+00, float 1.000000e+00, float 0.000000e+00>, <4 x float> <float 0.000000e+00, float 0.000000e+00, float 0.000000e+00, float 1.000000e+00>], align 16

; Function Attrs: convergent nounwind optsize
define <{ <4 x float> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(592) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(304) "air-buffer-no-alias" %2, ptr addrspace(2) readonly captures(none) dereferenceable(1376) "air-buffer-no-alias" %3, ptr addrspace(2) readonly captures(none) dereferenceable(32) "air-buffer-no-alias" %4, ptr addrspace(2) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %7, ptr addrspace(1) %8, ptr addrspace(1) %9, ptr addrspace(1) %10, <2 x float> %11) local_unnamed_addr #0 {
  %13 = shufflevector <2 x float> %11, <2 x float> undef, <3 x i32> <i32 0, i32 poison, i32 poison>
  %14 = getelementptr inbounds %struct._ScreenSpaceShadowParams_Type, ptr addrspace(2) %4, i64 0, i32 2
  %15 = load <4 x float>, ptr addrspace(2) %14, align 16, !alias.scope !35, !noalias !38
  %16 = shufflevector <4 x float> %15, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %17 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %16, <2 x float> splat (float 0x3FD3333340000000), <2 x float> %11) #2
  %18 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %9, ptr addrspace(2) readonly captures(none) %6, <2 x float> %17, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #1, !alias.scope !45, !noalias !46
  %19 = extractvalue { <4 x float>, i8 } %18, 0
  %20 = shufflevector <4 x float> %19, <4 x float> undef, <4 x i32> zeroinitializer
  %21 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 2
  %22 = load <4 x float>, ptr addrspace(2) %21, align 16, !tbaa !47, !alias.scope !50, !noalias !51
  %23 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 3
  %24 = load <4 x float>, ptr addrspace(2) %23, align 16, !tbaa !47, !alias.scope !50, !noalias !51
  %25 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %20, <4 x float> %22, <4 x float> %24) #2
  %26 = extractelement <2 x float> %11, i64 1
  %27 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 10
  %28 = load <4 x float>, ptr addrspace(2) %27, align 16, !alias.scope !52, !noalias !53
  %29 = extractelement <4 x float> %28, i64 0
  %30 = fmul fast float %29, %26
  %31 = insertelement <3 x float> %13, float %30, i64 1
  %32 = fsub fast float -0.000000e+00, %29
  %33 = insertelement <2 x float> <float -1.000000e+00, float undef>, float %32, i64 1
  %34 = shufflevector <3 x float> %31, <3 x float> undef, <2 x i32> <i32 0, i32 1>
  %35 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %34, <2 x float> splat (float 2.000000e+00), <2 x float> %33) #2
  %36 = shufflevector <2 x float> %35, <2 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %37 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 1
  %38 = load <4 x float>, ptr addrspace(2) %37, align 16, !tbaa !47, !alias.scope !50, !noalias !51
  %39 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %36, <4 x float> %38, <4 x float> %25) #2
  %40 = shufflevector <2 x float> %35, <2 x float> undef, <4 x i32> zeroinitializer
  %41 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 0
  %42 = load <4 x float>, ptr addrspace(2) %41, align 16, !tbaa !47, !alias.scope !50, !noalias !51
  %43 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %40, <4 x float> %42, <4 x float> %39) #2
  %44 = extractelement <4 x float> %43, i64 3
  %45 = fdiv fast float 1.000000e+00, %44
  %46 = insertelement <3 x float> undef, float %45, i64 0
  %47 = shufflevector <3 x float> %46, <3 x float> undef, <3 x i32> zeroinitializer
  %48 = shufflevector <4 x float> %43, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %49 = fmul fast <3 x float> %47, %48
  %50 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5
  %51 = load <3 x float>, ptr addrspace(2) %50, align 16, !alias.scope !52, !noalias !53
  %52 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %48, <3 x float> %47, <3 x float> %51) #2
  %53 = shufflevector <3 x float> %49, <3 x float> undef, <2 x i32> <i32 1, i32 1>
  %54 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 1
  %55 = load <4 x float>, ptr addrspace(2) %54, align 16, !alias.scope !54, !noalias !55
  %56 = shufflevector <4 x float> %55, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %57 = fmul fast <2 x float> %53, %56
  %58 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 0
  %59 = load <4 x float>, ptr addrspace(2) %58, align 16, !alias.scope !54, !noalias !55
  %60 = shufflevector <4 x float> %59, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %61 = shufflevector <3 x float> %49, <3 x float> undef, <2 x i32> zeroinitializer
  %62 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %60, <2 x float> %61, <2 x float> %57) #2
  %63 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 2
  %64 = load <4 x float>, ptr addrspace(2) %63, align 16, !alias.scope !54, !noalias !55
  %65 = shufflevector <4 x float> %64, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %66 = shufflevector <3 x float> %49, <3 x float> undef, <2 x i32> <i32 2, i32 2>
  %67 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %65, <2 x float> %66, <2 x float> %62) #2
  %68 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 3
  %69 = load <4 x float>, ptr addrspace(2) %68, align 16, !alias.scope !54, !noalias !55
  %70 = shufflevector <4 x float> %69, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %71 = fadd fast <2 x float> %70, %67
  %72 = shufflevector <2 x float> %71, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 poison, i32 poison>
  %73 = extractelement <2 x float> %71, i64 1
  %74 = fsub fast float 1.000000e+00, %73
  %75 = insertelement <4 x float> %72, float %74, i64 2
  %76 = shufflevector <4 x float> %75, <4 x float> undef, <2 x i32> <i32 0, i32 2>
  %77 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %76, <2 x float> splat (float 2.000000e+00), <2 x float> splat (float -1.000000e+00)) #2
  %78 = tail call fast <2 x float> @air.fast_fabs.v2f32(<2 x float> %77) #2
  %79 = fcmp fast olt <2 x float> %78, splat (float 0x3FEFAE1480000000)
  %80 = extractelement <2 x i1> %79, i64 1
  %81 = extractelement <2 x i1> %79, i64 0
  %82 = select i1 %80, i1 %81, i1 false
  %83 = select fast i1 %82, half 0xH3C00, half 0xH0000
  %84 = insertelement <4 x half> undef, half %83, i64 0
  %85 = fsub fast half 0xH3C00, %83
  %86 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 7
  %87 = load <4 x float>, ptr addrspace(2) %86, align 16, !alias.scope !56, !noalias !57
  %88 = shufflevector <4 x float> %87, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %89 = fsub fast <3 x float> %52, %88
  %90 = tail call fast float @air.dot.v3f32(<3 x float> %89, <3 x float> %89) #2
  %91 = insertelement <4 x float> undef, float %90, i64 2
  %92 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 5
  %93 = load <4 x float>, ptr addrspace(2) %92, align 16, !alias.scope !56, !noalias !57
  %94 = shufflevector <4 x float> %93, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %95 = fsub fast <3 x float> %52, %94
  %96 = tail call fast float @air.dot.v3f32(<3 x float> %95, <3 x float> %95) #2
  %97 = insertelement <4 x float> %91, float %96, i64 0
  %98 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 6
  %99 = load <4 x float>, ptr addrspace(2) %98, align 16, !alias.scope !56, !noalias !57
  %100 = shufflevector <4 x float> %99, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %101 = fsub fast <3 x float> %52, %100
  %102 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 7
  %103 = load <3 x float>, ptr addrspace(2) %102, align 16, !alias.scope !52, !noalias !53
  %104 = fsub fast <3 x float> %52, %103
  %105 = tail call fast float @air.dot.v3f32(<3 x float> %104, <3 x float> %104) #2
  %106 = fptrunc float %105 to half
  %107 = fpext half %106 to float
  %108 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 10
  %109 = load <4 x float>, ptr addrspace(2) %108, align 16, !alias.scope !56, !noalias !57
  %110 = extractelement <4 x float> %109, i64 3
  %111 = fcmp fast ole float %110, %107
  %112 = tail call fast float @air.dot.v3f32(<3 x float> %101, <3 x float> %101) #2
  %113 = insertelement <4 x float> %97, float %112, i64 1
  %114 = shufflevector <4 x float> %113, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %115 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 9
  %116 = load <4 x float>, ptr addrspace(2) %115, align 16, !alias.scope !56, !noalias !57
  %117 = shufflevector <4 x float> %116, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %118 = fcmp fast olt <3 x float> %114, %117
  %119 = fdiv fast <3 x float> %114, %117
  %120 = shufflevector <4 x float> %113, <4 x float> undef, <3 x i32> <i32 0, i32 0, i32 1>
  %121 = shufflevector <4 x float> %109, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %122 = fcmp fast oge <3 x float> %120, %121
  %123 = select reassoc nsz arcp contract afn <3 x i1> %122, <3 x float> splat (float 1.000000e+00), <3 x float> zeroinitializer
  %124 = shufflevector <3 x float> %123, <3 x float> undef, <4 x i32> <i32 poison, i32 0, i32 1, i32 2>
  %125 = extractelement <3 x i1> %118, i64 0
  %126 = select fast i1 %125, half 0xH3C00, half 0xH0000
  %127 = insertelement <4 x half> %84, half %126, i64 1
  %128 = extractelement <3 x i1> %118, i64 1
  %129 = select fast i1 %128, half 0xH3C00, half 0xH0000
  %130 = insertelement <4 x half> %127, half %129, i64 2
  %131 = extractelement <3 x i1> %118, i64 2
  %132 = select fast i1 %131, half 0xH3C00, half 0xH0000
  %133 = insertelement <4 x half> %130, half %132, i64 3
  %134 = shufflevector <4 x half> %130, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %135 = shufflevector <4 x half> %133, <4 x half> undef, <3 x i32> <i32 1, i32 2, i32 3>
  %136 = fsub fast <3 x half> %135, %134
  %137 = fpext half %129 to float
  %138 = select fast i1 %111, float %137, float 0.000000e+00
  %139 = insertelement <4 x float> %124, float %138, i64 0
  %140 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %136, <3 x half> zeroinitializer) #2
  %141 = insertelement <3 x half> undef, half %85, i64 0
  %142 = shufflevector <3 x half> %141, <3 x half> undef, <3 x i32> zeroinitializer
  %143 = fmul fast <3 x half> %140, %142
  %144 = shufflevector <3 x half> %143, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %145 = shufflevector <4 x half> %84, <4 x half> %144, <4 x i32> <i32 0, i32 4, i32 5, i32 6>
  %146 = tail call fast half @air.dot.v4f16(<4 x half> %145, <4 x half> <half 0xH3C00, half 0xH4400, half 0xH4200, half 0xH4000>) #2
  %147 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %143) #2
  %148 = tail call fast float @air.dot.v3f32(<3 x float> %119, <3 x float> %147) #2
  %149 = fptrunc float %148 to half
  %150 = tail call fast half @air.fma.f16(half %149, half 0xH4400, half 0xHC200) #2
  %151 = tail call fast half @air.clamp.f16(half %150, half 0xH0000, half 0xH3C00) #2
  %152 = fsub fast half 0xH4400, %146
  %153 = tail call fast half @air.fmax.f16(half %152, half 0xH0000) #2
  %154 = tail call fast half @air.fmin.f16(half %153, half 0xH4200) #2
  %155 = fpext half %154 to float
  %156 = tail call i32 @air.convert.u.i32.f.f32(float %155) #2
  %157 = sext i32 %156 to i64
  %158 = getelementptr inbounds [4 x <4 x float>], ptr addrspace(2) @_ZL7ImmCB_0, i64 0, i64 %157
  %159 = load <4 x float>, ptr addrspace(2) %158, align 16, !tbaa !47
  %160 = tail call fast float @air.dot.v4f32(<4 x float> %139, <4 x float> %159) #2
  %161 = fptrunc float %160 to half
  %162 = getelementptr inbounds %struct._ScreenSpaceShadowParams_Type, ptr addrspace(2) %4, i64 0, i32 0
  %163 = load <2 x float>, ptr addrspace(2) %162, align 16, !alias.scope !35, !noalias !38
  %164 = fmul fast <2 x float> %163, %11
  %165 = tail call <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float> %164) #2
  %166 = and <2 x i32> %165, splat (i32 -2147483648)
  %167 = sub <2 x i32> zeroinitializer, %165
  %168 = tail call <2 x i32> @air.max.s.v2i32(<2 x i32> %165, <2 x i32> %167) #2
  %169 = and <2 x i32> %168, splat (i32 3)
  %170 = sub nsw <2 x i32> zeroinitializer, %169
  %171 = extractelement <2 x i32> %166, i64 0
  %172 = icmp eq i32 %171, 0
  %173 = extractelement <2 x i32> %170, i64 0
  %174 = extractelement <2 x i32> %169, i64 0
  %175 = select i1 %172, i32 %174, i32 %173
  %176 = insertelement <2 x i32> undef, i32 %175, i64 0
  %177 = extractelement <2 x i32> %166, i64 1
  %178 = icmp eq i32 %177, 0
  %179 = extractelement <2 x i32> %170, i64 1
  %180 = extractelement <2 x i32> %169, i64 1
  %181 = select i1 %178, i32 %180, i32 %179
  %182 = insertelement <2 x i32> %176, i32 %181, i64 1
  %183 = tail call <2 x i32> @air.max.s.v2i32(<2 x i32> %182, <2 x i32> zeroinitializer) #2
  %184 = extractelement <2 x i32> %183, i64 1
  %185 = shl nsw i32 %184, 2
  %186 = extractelement <2 x i32> %183, i64 0
  %187 = add nsw i32 %185, %186
  %188 = sext i32 %187 to i64
  %189 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 4, i64 %188
  %190 = load half, ptr addrspace(2) %189, align 2, !tbaa !58, !alias.scope !56, !noalias !57
  %191 = fcmp fast oge half %151, %190
  %192 = select fast i1 %191, half %161, half 0xH0000
  %193 = fadd fast half %192, %152
  %194 = tail call fast half @air.fmax.f16(half %193, half 0xH0000) #2
  %195 = tail call fast half @air.fmin.f16(half %194, half 0xH4200) #2
  %196 = fpext half %195 to float
  %197 = tail call i32 @air.convert.u.i32.f.f32(float %196) #2
  %198 = shl i32 %197, 2
  %199 = shufflevector <3 x float> %49, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %200 = or i32 %198, 1
  %201 = sext i32 %200 to i64
  %202 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %201
  %203 = load <4 x float>, ptr addrspace(2) %202, align 16, !alias.scope !56, !noalias !57
  %204 = shufflevector <4 x float> %203, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %205 = fmul fast <3 x float> %204, %199
  %206 = sext i32 %198 to i64
  %207 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %206
  %208 = load <4 x float>, ptr addrspace(2) %207, align 16, !alias.scope !56, !noalias !57
  %209 = shufflevector <4 x float> %208, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %210 = shufflevector <3 x float> %49, <3 x float> undef, <3 x i32> zeroinitializer
  %211 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %209, <3 x float> %210, <3 x float> %205) #2
  %212 = or i32 %198, 2
  %213 = sext i32 %212 to i64
  %214 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %213
  %215 = load <4 x float>, ptr addrspace(2) %214, align 16, !alias.scope !56, !noalias !57
  %216 = shufflevector <4 x float> %215, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %217 = shufflevector <3 x float> %49, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %218 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %216, <3 x float> %217, <3 x float> %211) #2
  %219 = or i32 %198, 3
  %220 = sext i32 %219 to i64
  %221 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %220
  %222 = load <4 x float>, ptr addrspace(2) %221, align 16, !alias.scope !56, !noalias !57
  %223 = shufflevector <4 x float> %222, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %224 = fadd fast <3 x float> %223, %218
  %225 = shufflevector <3 x float> %224, <3 x float> undef, <2 x i32> <i32 0, i32 1>
  %226 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 18
  %227 = load <4 x float>, ptr addrspace(2) %226, align 16, !alias.scope !56, !noalias !57
  %228 = shufflevector <4 x float> %227, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %229 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %225, <2 x float> %228, <2 x float> splat (float -5.000000e-01)) #2
  %230 = extractelement <3 x float> %224, i64 2
  %231 = tail call fast float @air.fast_fmax.f32(float %230, float 0.000000e+00) #2
  %232 = tail call fast fastcc <2 x float> @___metal_fract_v2float(<2 x float> %229, i32 0) #6
  %233 = tail call fast <2 x float> @air.fast_floor.v2f32(<2 x float> %229) #2
  %234 = fsub fast <2 x float> splat (float 1.000000e+00), %232
  %235 = shufflevector <4 x float> %227, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %236 = fmul fast <2 x float> %235, splat (float 5.000000e-01)
  %237 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %233, <2 x float> %235, <2 x float> %236) #2
  %238 = shufflevector <4 x float> %227, <4 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %239 = shufflevector <2 x float> %237, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %240 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float 0.000000e+00, float -2.000000e+00, float 2.000000e+00, float -2.000000e+00>, <4 x float> %239) #2
  %241 = shufflevector <4 x float> %240, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %242 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %241, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %243 = extractvalue { <4 x float>, i8 } %242, 0
  %244 = shufflevector <4 x float> %240, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %245 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %244, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %246 = extractvalue { <4 x float>, i8 } %245, 0
  %247 = insertelement <4 x float> undef, float %231, i64 0
  %248 = shufflevector <4 x float> %247, <4 x float> undef, <4 x i32> zeroinitializer
  %249 = fcmp fast oge <4 x float> %248, %246
  %250 = select reassoc nsz arcp contract afn <4 x i1> %249, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %251 = fcmp fast oge <4 x float> %248, %243
  %252 = select reassoc nsz arcp contract afn <4 x i1> %251, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %253 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %235, <2 x float> splat (float -2.000000e+00), <2 x float> %237) #2
  %254 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %253, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %255 = extractvalue { <4 x float>, i8 } %254, 0
  %256 = fcmp fast oge <4 x float> %248, %255
  %257 = select reassoc nsz arcp contract afn <4 x i1> %256, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %258 = shufflevector <4 x float> %257, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %259 = shufflevector <2 x float> %234, <2 x float> undef, <2 x i32> zeroinitializer
  %260 = shufflevector <4 x float> %257, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %261 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %258, <2 x float> %259, <2 x float> %260) #2
  %262 = shufflevector <4 x float> %250, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %263 = shufflevector <4 x float> %250, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %264 = shufflevector <4 x float> %252, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %265 = fadd fast <2 x float> %264, %261
  %266 = fadd fast <2 x float> %265, %262
  %267 = fadd fast <2 x float> %266, %263
  %268 = shufflevector <4 x float> %252, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %269 = shufflevector <2 x float> %232, <2 x float> undef, <2 x i32> zeroinitializer
  %270 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %268, <2 x float> %269, <2 x float> %267) #2
  %271 = extractelement <2 x float> %270, i64 0
  %272 = extractelement <2 x float> %234, i64 1
  %273 = extractelement <2 x float> %270, i64 1
  %274 = tail call fast float @air.fma.f32(float %271, float %272, float %273) #2
  %275 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %237, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %276 = extractvalue { <4 x float>, i8 } %275, 0
  %277 = fcmp fast oge <4 x float> %248, %276
  %278 = select reassoc nsz arcp contract afn <4 x i1> %277, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %279 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float -2.000000e+00, float 0.000000e+00, float 2.000000e+00, float 0.000000e+00>, <4 x float> %239) #2
  %280 = shufflevector <4 x float> %279, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %281 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %280, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %282 = extractvalue { <4 x float>, i8 } %281, 0
  %283 = shufflevector <4 x float> %279, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %284 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %283, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %285 = extractvalue { <4 x float>, i8 } %284, 0
  %286 = fcmp fast oge <4 x float> %248, %285
  %287 = select reassoc nsz arcp contract afn <4 x i1> %286, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %288 = fcmp fast oge <4 x float> %248, %282
  %289 = select reassoc nsz arcp contract afn <4 x i1> %288, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %290 = shufflevector <4 x float> %289, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %291 = shufflevector <4 x float> %289, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %292 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %290, <2 x float> %259, <2 x float> %291) #2
  %293 = shufflevector <4 x float> %278, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %294 = fadd fast <2 x float> %293, %292
  %295 = shufflevector <4 x float> %278, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %296 = fadd fast <2 x float> %294, %295
  %297 = shufflevector <4 x float> %287, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %298 = fadd fast <2 x float> %296, %297
  %299 = shufflevector <4 x float> %287, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %300 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %299, <2 x float> %269, <2 x float> %298) #2
  %301 = extractelement <2 x float> %300, i64 1
  %302 = extractelement <2 x float> %300, i64 0
  %303 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float -2.000000e+00, float 2.000000e+00, float 0.000000e+00, float 2.000000e+00>, <4 x float> %239) #2
  %304 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %235, <2 x float> splat (float 2.000000e+00), <2 x float> %237) #2
  %305 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %304, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %306 = extractvalue { <4 x float>, i8 } %305, 0
  %307 = fcmp fast oge <4 x float> %248, %306
  %308 = select reassoc nsz arcp contract afn <4 x i1> %307, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %309 = shufflevector <4 x float> %303, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %310 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %309, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %311 = extractvalue { <4 x float>, i8 } %310, 0
  %312 = shufflevector <4 x float> %303, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %313 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %5, <2 x float> %312, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !45, !noalias !46
  %314 = extractvalue { <4 x float>, i8 } %313, 0
  %315 = fcmp fast oge <4 x float> %248, %314
  %316 = fcmp fast oge <4 x float> %248, %311
  %317 = select reassoc nsz arcp contract afn <4 x i1> %316, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %318 = shufflevector <4 x float> %317, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %319 = shufflevector <4 x float> %317, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %320 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %318, <2 x float> %259, <2 x float> %319) #2
  %321 = select reassoc nsz arcp contract afn <4 x i1> %315, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %322 = shufflevector <4 x float> %321, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %323 = shufflevector <4 x float> %321, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %324 = shufflevector <4 x float> %308, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %325 = fadd fast <2 x float> %324, %320
  %326 = fadd fast <2 x float> %325, %322
  %327 = fadd fast <2 x float> %326, %323
  %328 = shufflevector <4 x float> %308, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %329 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %328, <2 x float> %269, <2 x float> %327) #2
  %330 = extractelement <2 x float> %329, i64 1
  %331 = extractelement <2 x float> %232, i64 1
  %332 = extractelement <2 x float> %329, i64 0
  %333 = tail call fast float @air.fma.f32(float %330, float %331, float %332) #2
  %334 = fadd fast float %302, %274
  %335 = fadd fast float %334, %301
  %336 = fadd fast float %335, %333
  %337 = fmul fast float %336, 0x3FA47AE140000000
  %338 = fmul fast float %337, %337
  %339 = insertelement <4 x float> undef, float %338, i64 0
  %340 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %10, ptr addrspace(2) readonly captures(none) %7, <2 x float> %11, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #1, !alias.scope !45, !noalias !46
  %341 = extractvalue { <4 x half>, i8 } %340, 0
  %342 = extractelement <4 x half> %341, i64 0
  %343 = fpext half %342 to float
  %344 = insertelement <4 x float> %339, float %343, i64 3
  %345 = shufflevector <4 x float> %344, <4 x float> <float 1.000000e+00, float 1.000000e+00, float undef, float undef>, <4 x i32> <i32 0, i32 4, i32 5, i32 3>
  %346 = insertvalue <{ <4 x float> }> undef, <4 x float> %345, 0
  ret <{ <4 x float> }> %346
}

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i32, i32) local_unnamed_addr #3

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_floor.v2f32(<2 x float>) local_unnamed_addr #2

define internal fastcc <2 x float> @___metal_fract_v2float(<2 x float> %0, i32 %1) unnamed_addr #4 {
  %3 = tail call fastcc <2 x float> @_ZN11_fract_implIDv2_fvE4implIJLi0ELi1EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<2 x float> %0, i32 %1)
  ret <2 x float> %3
}

define internal fastcc <2 x float> @_ZN11_fract_implIDv2_fvE4implIJLi0ELi1EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<2 x float> %0, i32 %1) unnamed_addr #4 align 2 {
  %3 = extractelement <2 x float> %0, i64 0
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
  %22 = extractelement <2 x float> %0, i64 1
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
  %40 = insertelement <2 x float> undef, float %21, i64 0
  %41 = insertelement <2 x float> %40, float %39, i64 1
  ret <2 x float> %41
}

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z11_target_minff(float %0, float %1) unnamed_addr #5 {
  %3 = tail call float @air.fmin.f32(float %0, float %1) #2
  ret float %3
}

; Function Attrs: nounwind memory(none)
declare float @air.fmin.f32(float, float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z13_target_floorf(float %0) unnamed_addr #5 {
  %2 = tail call float @air.floor.f32(float %0) #2
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.floor.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z18_target_fast_fractf(float %0) unnamed_addr #5 {
  %2 = tail call float @air.fast_fract.f32(float %0) #2
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.fast_fract.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare half @air.fmin.f16(half, half) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare half @air.fmax.f16(half, half) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x i32> @air.max.s.v2i32(<2 x i32>, <2 x i32>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.dot.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fmax.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_fabs.v2f32(<2 x float>) local_unnamed_addr #2

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #1

attributes #0 = { convergent nounwind optsize "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { convergent nounwind memory(argmem: read) }
attributes #2 = { nounwind memory(none) }
attributes #3 = { nounwind memory(argmem: read) }
attributes #4 = { "frame-pointer"="all" "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #5 = { nounwind memory(none) "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #6 = { nounwind }

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
!17 = !{!18, !20, !22, !24, !26, !28, !29, !30, !31, !32, !33, !34}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!19 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!20 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 592, !"air.location_index", i32 1, i32 1, !"air.read", !"air.struct_type_info", !21, !"air.arg_type_size", i32 592, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerPass_Type", !"air.arg_name", !"UnityPerPass"}
!21 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_PrevViewProjMatrix", i32 64, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewProjMatrix", i32 128, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_NonJitteredViewProjMatrix", i32 192, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewMatrix", i32 256, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ProjMatrix", i32 320, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewProjMatrix", i32 384, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewMatrix", i32 448, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvProjMatrix", i32 512, i32 16, i32 0, !"float4", !"_InvProjParam", i32 528, i32 8, i32 0, !"half4", !"_ScreenSize", i32 536, i32 8, i32 0, !"half4", !"_HDRSize", i32 544, i32 8, i32 6, !"half4", !"_FrustumPlanes"}
!22 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 304, !"air.location_index", i32 2, i32 1, !"air.read", !"air.struct_type_info", !23, !"air.arg_type_size", i32 304, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"_LocalLightShadowBuffer_Type", !"air.arg_name", !"_LocalLightShadowBuffer"}
!23 = !{i32 0, i32 16, i32 12, !"float4", !"hlslcc_mtx4x4_LocalLightWorldToShadow", i32 192, i32 8, i32 0, !"half4", !"_LocalShadowStrength", i32 208, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_CloseUpWorldToShadow", i32 272, i32 16, i32 0, !"float4", !"_LocalLightShadowmapSize", i32 288, i32 16, i32 0, !"float4", !"_LocalLightCloseUpShadowSliceTransform"}
!24 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 1376, !"air.location_index", i32 3, i32 1, !"air.read", !"air.struct_type_info", !25, !"air.arg_type_size", i32 1376, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"_DirectionalShadowBuffer_Type", !"air.arg_name", !"_DirectionalShadowBuffer"}
!25 = !{i32 0, i32 16, i32 20, !"float4", !"hlslcc_mtx4x4_WorldToShadowArray", i32 320, i32 16, i32 20, !"float4", !"hlslcc_mtx4x4_ShadowToWorldArray", i32 640, i32 16, i32 16, !"float4", !"hlslcc_mtx4x4_ShadowInvProjArray", i32 896, i32 16, i32 5, !"float4", !"_ShadowCameraPosArray", i32 976, i32 2, i32 16, !"half", !"DitherFilters", i32 1008, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres0", i32 1024, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres1", i32 1040, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres2", i32 1056, i32 16, i32 0, !"float4", !"_DirShadowSplitSpheres3", i32 1072, i32 16, i32 0, !"float4", !"_DirShadowSplitSphereRadii", i32 1088, i32 16, i32 0, !"float4", !"_ShadowMapClipRanges", i32 1104, i32 16, i32 0, !"float4", !"_ShadowMapSplitDistances", i32 1120, i32 4, i32 4, !"float", !"_InvShadowMapSplitDistances", i32 1136, i32 8, i32 0, !"half4", !"_ShadowOffset0", i32 1144, i32 8, i32 0, !"half4", !"_ShadowOffset1", i32 1152, i32 8, i32 0, !"half4", !"_ShadowOffset2", i32 1160, i32 8, i32 0, !"half4", !"_ShadowOffset3", i32 1168, i32 8, i32 0, !"half4", !"_ShadowData", i32 1184, i32 16, i32 0, !"float4", !"_ShadowmapSize", i32 1200, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_AuroraShadowTransform", i32 1264, i32 16, i32 0, !"float4", !"_AuroraShadowCameraPos", i32 1280, i32 4, i32 0, !"float", !"BlurSize", i32 1284, i32 4, i32 0, !"float", !"_PenumbraBias", i32 1288, i32 4, i32 0, !"float", !"_AutoBiasScale", i32 1296, i32 16, i32 5, !"float4", !"_BiasRange"}
!26 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 32, !"air.location_index", i32 4, i32 1, !"air.read", !"air.struct_type_info", !27, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"_ScreenSpaceShadowParams_Type", !"air.arg_name", !"_ScreenSpaceShadowParams"}
!27 = !{i32 0, i32 8, i32 0, !"float2", !"_ShadowMaskSize", i32 8, i32 4, i32 0, !"float", !"_ZMax", i32 16, i32 16, i32 0, !"float4", !"_CameraDepthTexture_TexelSize"}
!28 = !{i32 5, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_DirectionalShadowmapTexture"}
!29 = !{i32 6, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraDepthTexture"}
!30 = !{i32 7, !"air.sampler", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_SSAOTexture"}
!31 = !{i32 8, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_DirectionalShadowmapTexture"}
!32 = !{i32 9, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_CameraDepthTexture"}
!33 = !{i32 10, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_SSAOTexture"}
!34 = !{i32 11, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!35 = !{!36}
!36 = distinct !{!36, !37, !"air-alias-scope-arg(4)"}
!37 = distinct !{!37, !"air-alias-scopes(xlatMtlMain)"}
!38 = !{!39, !40, !41, !42, !43, !44}
!39 = distinct !{!39, !37, !"air-alias-scope-arg(0)"}
!40 = distinct !{!40, !37, !"air-alias-scope-arg(1)"}
!41 = distinct !{!41, !37, !"air-alias-scope-arg(2)"}
!42 = distinct !{!42, !37, !"air-alias-scope-arg(3)"}
!43 = distinct !{!43, !37, !"air-alias-scope-samplers"}
!44 = distinct !{!44, !37, !"air-alias-scope-textures"}
!45 = !{!43, !44}
!46 = !{!39, !40, !41, !42, !36}
!47 = !{!48, !48, i64 0}
!48 = !{!"omnipotent char", !49, i64 0}
!49 = !{!"Simple C++ TBAA"}
!50 = !{!40}
!51 = !{!39, !41, !42, !36, !43, !44}
!52 = !{!39}
!53 = !{!40, !41, !42, !36, !43, !44}
!54 = !{!41}
!55 = !{!39, !40, !42, !36, !43, !44}
!56 = !{!42}
!57 = !{!39, !40, !41, !36, !43, !44}
!58 = !{!59, !59, i64 0}
!59 = !{!"half", !48, i64 0}
