; ModuleID = '/tmp/lysk-verify/shadow/library_330.module.bc'
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
define <{ float }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(592) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(304) "air-buffer-no-alias" %2, ptr addrspace(2) readonly captures(none) dereferenceable(1376) "air-buffer-no-alias" %3, ptr addrspace(2) readonly captures(none) dereferenceable(32) "air-buffer-no-alias" %4, ptr addrspace(2) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %6, ptr addrspace(1) %7, ptr addrspace(1) readonly captures(none) %8, <2 x float> %9) local_unnamed_addr #0 {
  %11 = shufflevector <2 x float> %9, <2 x float> undef, <3 x i32> <i32 0, i32 poison, i32 poison>
  %12 = getelementptr inbounds %struct._ScreenSpaceShadowParams_Type, ptr addrspace(2) %4, i64 0, i32 2
  %13 = load <4 x float>, ptr addrspace(2) %12, align 16, !alias.scope !33, !noalias !36
  %14 = shufflevector <4 x float> %13, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %15 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %14, <2 x float> splat (float 0x3FD3333340000000), <2 x float> %9) #1
  %16 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %8, ptr addrspace(2) readonly captures(none) %6, <2 x float> %15, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #5, !alias.scope !43, !noalias !44
  %17 = extractvalue { <4 x float>, i8 } %16, 0
  %18 = shufflevector <4 x float> %17, <4 x float> undef, <4 x i32> zeroinitializer
  %19 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 2
  %20 = load <4 x float>, ptr addrspace(2) %19, align 16, !tbaa !45, !alias.scope !48, !noalias !49
  %21 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 3
  %22 = load <4 x float>, ptr addrspace(2) %21, align 16, !tbaa !45, !alias.scope !48, !noalias !49
  %23 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %18, <4 x float> %20, <4 x float> %22) #1
  %24 = extractelement <2 x float> %9, i64 1
  %25 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 10
  %26 = load <4 x float>, ptr addrspace(2) %25, align 16, !alias.scope !50, !noalias !51
  %27 = extractelement <4 x float> %26, i64 0
  %28 = fmul fast float %27, %24
  %29 = insertelement <3 x float> %11, float %28, i64 1
  %30 = fsub fast float -0.000000e+00, %27
  %31 = insertelement <2 x float> <float -1.000000e+00, float undef>, float %30, i64 1
  %32 = shufflevector <3 x float> %29, <3 x float> undef, <2 x i32> <i32 0, i32 1>
  %33 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %32, <2 x float> splat (float 2.000000e+00), <2 x float> %31) #1
  %34 = shufflevector <2 x float> %33, <2 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %35 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 1
  %36 = load <4 x float>, ptr addrspace(2) %35, align 16, !tbaa !45, !alias.scope !48, !noalias !49
  %37 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %34, <4 x float> %36, <4 x float> %23) #1
  %38 = shufflevector <2 x float> %33, <2 x float> undef, <4 x i32> zeroinitializer
  %39 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 0
  %40 = load <4 x float>, ptr addrspace(2) %39, align 16, !tbaa !45, !alias.scope !48, !noalias !49
  %41 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %38, <4 x float> %40, <4 x float> %37) #1
  %42 = extractelement <4 x float> %41, i64 3
  %43 = fdiv fast float 1.000000e+00, %42
  %44 = insertelement <3 x float> undef, float %43, i64 0
  %45 = shufflevector <3 x float> %44, <3 x float> undef, <3 x i32> zeroinitializer
  %46 = shufflevector <4 x float> %41, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %47 = fmul fast <3 x float> %45, %46
  %48 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 5
  %49 = load <3 x float>, ptr addrspace(2) %48, align 16, !alias.scope !50, !noalias !51
  %50 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %46, <3 x float> %45, <3 x float> %49) #1
  %51 = shufflevector <3 x float> %47, <3 x float> undef, <2 x i32> <i32 1, i32 1>
  %52 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 1
  %53 = load <4 x float>, ptr addrspace(2) %52, align 16, !alias.scope !52, !noalias !53
  %54 = shufflevector <4 x float> %53, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %55 = fmul fast <2 x float> %51, %54
  %56 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 0
  %57 = load <4 x float>, ptr addrspace(2) %56, align 16, !alias.scope !52, !noalias !53
  %58 = shufflevector <4 x float> %57, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %59 = shufflevector <3 x float> %47, <3 x float> undef, <2 x i32> zeroinitializer
  %60 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %58, <2 x float> %59, <2 x float> %55) #1
  %61 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 2
  %62 = load <4 x float>, ptr addrspace(2) %61, align 16, !alias.scope !52, !noalias !53
  %63 = shufflevector <4 x float> %62, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %64 = shufflevector <3 x float> %47, <3 x float> undef, <2 x i32> <i32 2, i32 2>
  %65 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %63, <2 x float> %64, <2 x float> %60) #1
  %66 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 2, i64 3
  %67 = load <4 x float>, ptr addrspace(2) %66, align 16, !alias.scope !52, !noalias !53
  %68 = shufflevector <4 x float> %67, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %69 = fadd fast <2 x float> %68, %65
  %70 = shufflevector <2 x float> %69, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 poison, i32 poison>
  %71 = extractelement <2 x float> %69, i64 1
  %72 = fsub fast float 1.000000e+00, %71
  %73 = insertelement <4 x float> %70, float %72, i64 2
  %74 = shufflevector <4 x float> %73, <4 x float> undef, <2 x i32> <i32 0, i32 2>
  %75 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %74, <2 x float> splat (float 2.000000e+00), <2 x float> splat (float -1.000000e+00)) #1
  %76 = tail call fast <2 x float> @air.fast_fabs.v2f32(<2 x float> %75) #1
  %77 = fcmp fast olt <2 x float> %76, splat (float 0x3FEFAE1480000000)
  %78 = extractelement <2 x i1> %77, i64 1
  %79 = extractelement <2 x i1> %77, i64 0
  %80 = select i1 %78, i1 %79, i1 false
  %81 = select fast i1 %80, half 0xH3C00, half 0xH0000
  %82 = insertelement <4 x half> undef, half %81, i64 0
  %83 = fsub fast half 0xH3C00, %81
  %84 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 7
  %85 = load <4 x float>, ptr addrspace(2) %84, align 16, !alias.scope !54, !noalias !55
  %86 = shufflevector <4 x float> %85, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %87 = fsub fast <3 x float> %50, %86
  %88 = tail call fast float @air.dot.v3f32(<3 x float> %87, <3 x float> %87) #1
  %89 = insertelement <4 x float> undef, float %88, i64 2
  %90 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 5
  %91 = load <4 x float>, ptr addrspace(2) %90, align 16, !alias.scope !54, !noalias !55
  %92 = shufflevector <4 x float> %91, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %93 = fsub fast <3 x float> %50, %92
  %94 = tail call fast float @air.dot.v3f32(<3 x float> %93, <3 x float> %93) #1
  %95 = insertelement <4 x float> %89, float %94, i64 0
  %96 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 6
  %97 = load <4 x float>, ptr addrspace(2) %96, align 16, !alias.scope !54, !noalias !55
  %98 = shufflevector <4 x float> %97, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %99 = fsub fast <3 x float> %50, %98
  %100 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 7
  %101 = load <3 x float>, ptr addrspace(2) %100, align 16, !alias.scope !50, !noalias !51
  %102 = fsub fast <3 x float> %50, %101
  %103 = tail call fast float @air.dot.v3f32(<3 x float> %102, <3 x float> %102) #1
  %104 = fptrunc float %103 to half
  %105 = fpext half %104 to float
  %106 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 10
  %107 = load <4 x float>, ptr addrspace(2) %106, align 16, !alias.scope !54, !noalias !55
  %108 = extractelement <4 x float> %107, i64 3
  %109 = fcmp fast ole float %108, %105
  %110 = tail call fast float @air.dot.v3f32(<3 x float> %99, <3 x float> %99) #1
  %111 = insertelement <4 x float> %95, float %110, i64 1
  %112 = shufflevector <4 x float> %111, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %113 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 9
  %114 = load <4 x float>, ptr addrspace(2) %113, align 16, !alias.scope !54, !noalias !55
  %115 = shufflevector <4 x float> %114, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %116 = fcmp fast olt <3 x float> %112, %115
  %117 = fdiv fast <3 x float> %112, %115
  %118 = shufflevector <4 x float> %111, <4 x float> undef, <3 x i32> <i32 0, i32 0, i32 1>
  %119 = shufflevector <4 x float> %107, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %120 = fcmp fast oge <3 x float> %118, %119
  %121 = select reassoc nsz arcp contract afn <3 x i1> %120, <3 x float> splat (float 1.000000e+00), <3 x float> zeroinitializer
  %122 = shufflevector <3 x float> %121, <3 x float> undef, <4 x i32> <i32 poison, i32 0, i32 1, i32 2>
  %123 = extractelement <3 x i1> %116, i64 0
  %124 = select fast i1 %123, half 0xH3C00, half 0xH0000
  %125 = insertelement <4 x half> %82, half %124, i64 1
  %126 = extractelement <3 x i1> %116, i64 1
  %127 = select fast i1 %126, half 0xH3C00, half 0xH0000
  %128 = insertelement <4 x half> %125, half %127, i64 2
  %129 = extractelement <3 x i1> %116, i64 2
  %130 = select fast i1 %129, half 0xH3C00, half 0xH0000
  %131 = insertelement <4 x half> %128, half %130, i64 3
  %132 = shufflevector <4 x half> %128, <4 x half> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %133 = shufflevector <4 x half> %131, <4 x half> undef, <3 x i32> <i32 1, i32 2, i32 3>
  %134 = fsub fast <3 x half> %133, %132
  %135 = fpext half %127 to float
  %136 = select fast i1 %109, float %135, float 0.000000e+00
  %137 = insertelement <4 x float> %122, float %136, i64 0
  %138 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %134, <3 x half> zeroinitializer) #1
  %139 = insertelement <3 x half> undef, half %83, i64 0
  %140 = shufflevector <3 x half> %139, <3 x half> undef, <3 x i32> zeroinitializer
  %141 = fmul fast <3 x half> %138, %140
  %142 = shufflevector <3 x half> %141, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %143 = shufflevector <4 x half> %82, <4 x half> %142, <4 x i32> <i32 0, i32 4, i32 5, i32 6>
  %144 = tail call fast half @air.dot.v4f16(<4 x half> %143, <4 x half> <half 0xH3C00, half 0xH4400, half 0xH4200, half 0xH4000>) #1
  %145 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %141) #1
  %146 = tail call fast float @air.dot.v3f32(<3 x float> %117, <3 x float> %145) #1
  %147 = fptrunc float %146 to half
  %148 = tail call fast half @air.fma.f16(half %147, half 0xH4400, half 0xHC200) #1
  %149 = tail call fast half @air.clamp.f16(half %148, half 0xH0000, half 0xH3C00) #1
  %150 = fsub fast half 0xH4400, %144
  %151 = tail call fast half @air.fmax.f16(half %150, half 0xH0000) #1
  %152 = tail call fast half @air.fmin.f16(half %151, half 0xH4200) #1
  %153 = fpext half %152 to float
  %154 = tail call i32 @air.convert.u.i32.f.f32(float %153) #1
  %155 = sext i32 %154 to i64
  %156 = getelementptr inbounds [4 x <4 x float>], ptr addrspace(2) @_ZL7ImmCB_0, i64 0, i64 %155
  %157 = load <4 x float>, ptr addrspace(2) %156, align 16, !tbaa !45
  %158 = tail call fast float @air.dot.v4f32(<4 x float> %137, <4 x float> %157) #1
  %159 = fptrunc float %158 to half
  %160 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 10
  %161 = load <4 x half>, ptr addrspace(2) %160, align 8, !alias.scope !48, !noalias !49
  %162 = shufflevector <4 x half> %161, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %163 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %162) #1
  %164 = fmul fast <2 x float> %163, %9
  %165 = tail call <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float> %164) #1
  %166 = and <2 x i32> %165, splat (i32 -2147483648)
  %167 = sub <2 x i32> zeroinitializer, %165
  %168 = tail call <2 x i32> @air.max.s.v2i32(<2 x i32> %165, <2 x i32> %167) #1
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
  %183 = tail call <2 x i32> @air.max.s.v2i32(<2 x i32> %182, <2 x i32> zeroinitializer) #1
  %184 = extractelement <2 x i32> %183, i64 1
  %185 = shl nsw i32 %184, 2
  %186 = extractelement <2 x i32> %183, i64 0
  %187 = add nsw i32 %185, %186
  %188 = sext i32 %187 to i64
  %189 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 4, i64 %188
  %190 = load half, ptr addrspace(2) %189, align 2, !tbaa !56, !alias.scope !54, !noalias !55
  %191 = fcmp fast oge half %149, %190
  %192 = select fast i1 %191, half %159, half 0xH0000
  %193 = fadd fast half %192, %150
  %194 = tail call fast half @air.fmax.f16(half %193, half 0xH0000) #1
  %195 = tail call fast half @air.fmin.f16(half %194, half 0xH4200) #1
  %196 = fpext half %195 to float
  %197 = tail call i32 @air.convert.u.i32.f.f32(float %196) #1
  %198 = shl i32 %197, 2
  %199 = shufflevector <3 x float> %47, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %200 = or i32 %198, 1
  %201 = sext i32 %200 to i64
  %202 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %201
  %203 = load <4 x float>, ptr addrspace(2) %202, align 16, !alias.scope !54, !noalias !55
  %204 = shufflevector <4 x float> %203, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %205 = fmul fast <3 x float> %204, %199
  %206 = sext i32 %198 to i64
  %207 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %206
  %208 = load <4 x float>, ptr addrspace(2) %207, align 16, !alias.scope !54, !noalias !55
  %209 = shufflevector <4 x float> %208, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %210 = shufflevector <3 x float> %47, <3 x float> undef, <3 x i32> zeroinitializer
  %211 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %209, <3 x float> %210, <3 x float> %205) #1
  %212 = or i32 %198, 2
  %213 = sext i32 %212 to i64
  %214 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %213
  %215 = load <4 x float>, ptr addrspace(2) %214, align 16, !alias.scope !54, !noalias !55
  %216 = shufflevector <4 x float> %215, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %217 = shufflevector <3 x float> %47, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %218 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %216, <3 x float> %217, <3 x float> %211) #1
  %219 = or i32 %198, 3
  %220 = sext i32 %219 to i64
  %221 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 0, i64 %220
  %222 = load <4 x float>, ptr addrspace(2) %221, align 16, !alias.scope !54, !noalias !55
  %223 = shufflevector <4 x float> %222, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %224 = fadd fast <3 x float> %223, %218
  %225 = shufflevector <3 x float> %224, <3 x float> undef, <2 x i32> <i32 0, i32 1>
  %226 = getelementptr inbounds %struct._DirectionalShadowBuffer_Type, ptr addrspace(2) %3, i64 0, i32 18
  %227 = load <4 x float>, ptr addrspace(2) %226, align 16, !alias.scope !54, !noalias !55
  %228 = shufflevector <4 x float> %227, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %229 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %225, <2 x float> %228, <2 x float> splat (float -5.000000e-01)) #1
  %230 = extractelement <3 x float> %224, i64 2
  %231 = tail call fast float @air.fast_fmax.f32(float %230, float 0.000000e+00) #1
  %232 = tail call fast fastcc <2 x float> @___metal_fract_v2float(<2 x float> %229, i32 0) #6
  %233 = tail call fast <2 x float> @air.fast_floor.v2f32(<2 x float> %229) #1
  %234 = fsub fast <2 x float> splat (float 1.000000e+00), %232
  %235 = shufflevector <4 x float> %227, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %236 = fmul fast <2 x float> %235, splat (float 5.000000e-01)
  %237 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %233, <2 x float> %235, <2 x float> %236) #1
  %238 = shufflevector <4 x float> %227, <4 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %239 = shufflevector <2 x float> %237, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %240 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float 0.000000e+00, float -2.000000e+00, float 2.000000e+00, float -2.000000e+00>, <4 x float> %239) #1
  %241 = shufflevector <4 x float> %240, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %242 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %241, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %243 = extractvalue { <4 x float>, i8 } %242, 0
  %244 = shufflevector <4 x float> %240, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %245 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %244, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %246 = extractvalue { <4 x float>, i8 } %245, 0
  %247 = insertelement <4 x float> undef, float %231, i64 0
  %248 = shufflevector <4 x float> %247, <4 x float> undef, <4 x i32> zeroinitializer
  %249 = fcmp fast oge <4 x float> %248, %246
  %250 = select reassoc nsz arcp contract afn <4 x i1> %249, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %251 = fcmp fast oge <4 x float> %248, %243
  %252 = select reassoc nsz arcp contract afn <4 x i1> %251, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %253 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %235, <2 x float> splat (float -2.000000e+00), <2 x float> %237) #1
  %254 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %253, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %255 = extractvalue { <4 x float>, i8 } %254, 0
  %256 = fcmp fast oge <4 x float> %248, %255
  %257 = select reassoc nsz arcp contract afn <4 x i1> %256, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %258 = shufflevector <4 x float> %257, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %259 = shufflevector <2 x float> %234, <2 x float> undef, <2 x i32> zeroinitializer
  %260 = shufflevector <4 x float> %257, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %261 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %258, <2 x float> %259, <2 x float> %260) #1
  %262 = shufflevector <4 x float> %250, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %263 = shufflevector <4 x float> %250, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %264 = shufflevector <4 x float> %252, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %265 = fadd fast <2 x float> %264, %261
  %266 = fadd fast <2 x float> %265, %262
  %267 = fadd fast <2 x float> %266, %263
  %268 = shufflevector <4 x float> %252, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %269 = shufflevector <2 x float> %232, <2 x float> undef, <2 x i32> zeroinitializer
  %270 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %268, <2 x float> %269, <2 x float> %267) #1
  %271 = extractelement <2 x float> %270, i64 0
  %272 = extractelement <2 x float> %234, i64 1
  %273 = extractelement <2 x float> %270, i64 1
  %274 = tail call fast float @air.fma.f32(float %271, float %272, float %273) #1
  %275 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %237, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %276 = extractvalue { <4 x float>, i8 } %275, 0
  %277 = fcmp fast oge <4 x float> %248, %276
  %278 = select reassoc nsz arcp contract afn <4 x i1> %277, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %279 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float -2.000000e+00, float 0.000000e+00, float 2.000000e+00, float 0.000000e+00>, <4 x float> %239) #1
  %280 = shufflevector <4 x float> %279, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %281 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %280, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %282 = extractvalue { <4 x float>, i8 } %281, 0
  %283 = shufflevector <4 x float> %279, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %284 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %283, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %285 = extractvalue { <4 x float>, i8 } %284, 0
  %286 = fcmp fast oge <4 x float> %248, %285
  %287 = select reassoc nsz arcp contract afn <4 x i1> %286, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %288 = fcmp fast oge <4 x float> %248, %282
  %289 = select reassoc nsz arcp contract afn <4 x i1> %288, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %290 = shufflevector <4 x float> %289, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %291 = shufflevector <4 x float> %289, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %292 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %290, <2 x float> %259, <2 x float> %291) #1
  %293 = shufflevector <4 x float> %278, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %294 = fadd fast <2 x float> %293, %292
  %295 = shufflevector <4 x float> %278, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %296 = fadd fast <2 x float> %294, %295
  %297 = shufflevector <4 x float> %287, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %298 = fadd fast <2 x float> %296, %297
  %299 = shufflevector <4 x float> %287, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %300 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %299, <2 x float> %269, <2 x float> %298) #1
  %301 = extractelement <2 x float> %300, i64 1
  %302 = extractelement <2 x float> %300, i64 0
  %303 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %238, <4 x float> <float -2.000000e+00, float 2.000000e+00, float 0.000000e+00, float 2.000000e+00>, <4 x float> %239) #1
  %304 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %235, <2 x float> splat (float 2.000000e+00), <2 x float> %237) #1
  %305 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %304, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %306 = extractvalue { <4 x float>, i8 } %305, 0
  %307 = fcmp fast oge <4 x float> %248, %306
  %308 = select reassoc nsz arcp contract afn <4 x i1> %307, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %309 = shufflevector <4 x float> %303, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %310 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %309, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %311 = extractvalue { <4 x float>, i8 } %310, 0
  %312 = shufflevector <4 x float> %303, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %313 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %5, <2 x float> %312, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #2, !alias.scope !43, !noalias !44
  %314 = extractvalue { <4 x float>, i8 } %313, 0
  %315 = fcmp fast oge <4 x float> %248, %314
  %316 = fcmp fast oge <4 x float> %248, %311
  %317 = select reassoc nsz arcp contract afn <4 x i1> %316, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %318 = shufflevector <4 x float> %317, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %319 = shufflevector <4 x float> %317, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %320 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %318, <2 x float> %259, <2 x float> %319) #1
  %321 = select reassoc nsz arcp contract afn <4 x i1> %315, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %322 = shufflevector <4 x float> %321, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %323 = shufflevector <4 x float> %321, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %324 = shufflevector <4 x float> %308, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %325 = fadd fast <2 x float> %324, %320
  %326 = fadd fast <2 x float> %325, %322
  %327 = fadd fast <2 x float> %326, %323
  %328 = shufflevector <4 x float> %308, <4 x float> undef, <2 x i32> <i32 2, i32 1>
  %329 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %328, <2 x float> %269, <2 x float> %327) #1
  %330 = extractelement <2 x float> %329, i64 1
  %331 = extractelement <2 x float> %232, i64 1
  %332 = extractelement <2 x float> %329, i64 0
  %333 = tail call fast float @air.fma.f32(float %330, float %331, float %332) #1
  %334 = fadd fast float %302, %274
  %335 = fadd fast float %334, %301
  %336 = fadd fast float %335, %333
  %337 = fmul fast float %336, 0x3FA47AE140000000
  %338 = fmul fast float %337, %337
  %339 = insertvalue <{ float }> undef, float %338, 0
  ret <{ float }> %339
}

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i32, i32) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_floor.v2f32(<2 x float>) local_unnamed_addr #1

define internal fastcc <2 x float> @___metal_fract_v2float(<2 x float> %0, i32 %1) unnamed_addr #3 {
  %3 = tail call fastcc <2 x float> @_ZN11_fract_implIDv2_fvE4implIJLi0ELi1EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<2 x float> %0, i32 %1)
  ret <2 x float> %3
}

define internal fastcc <2 x float> @_ZN11_fract_implIDv2_fvE4implIJLi0ELi1EEEES0_S0_i17_integer_sequenceIiJXspT_EEE(<2 x float> %0, i32 %1) unnamed_addr #3 align 2 {
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
define internal fastcc float @_Z11_target_minff(float %0, float %1) unnamed_addr #4 {
  %3 = tail call float @air.fmin.f32(float %0, float %1) #1
  ret float %3
}

; Function Attrs: nounwind memory(none)
declare float @air.fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z13_target_floorf(float %0) unnamed_addr #4 {
  %2 = tail call float @air.floor.f32(float %0) #1
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.floor.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z18_target_fast_fractf(float %0) unnamed_addr #4 {
  %2 = tail call float @air.fast_fract.f32(float %0) #1
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.fast_fract.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmin.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fmax.f16(half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x i32> @air.max.s.v2i32(<2 x i32>, <2 x i32>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.fmax.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_fabs.v2f32(<2 x float>) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #5

attributes #0 = { convergent nounwind optsize "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }
attributes #2 = { nounwind memory(argmem: read) }
attributes #3 = { "frame-pointer"="all" "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #4 = { nounwind memory(none) "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #5 = { convergent nounwind memory(argmem: read) }
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
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float", !"air.arg_name", !"SV_Target0"}
!17 = !{!18, !20, !22, !24, !26, !28, !29, !30, !31, !32}
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
!30 = !{i32 7, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_DirectionalShadowmapTexture"}
!31 = !{i32 8, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_CameraDepthTexture"}
!32 = !{i32 9, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!33 = !{!34}
!34 = distinct !{!34, !35, !"air-alias-scope-arg(4)"}
!35 = distinct !{!35, !"air-alias-scopes(xlatMtlMain)"}
!36 = !{!37, !38, !39, !40, !41, !42}
!37 = distinct !{!37, !35, !"air-alias-scope-arg(0)"}
!38 = distinct !{!38, !35, !"air-alias-scope-arg(1)"}
!39 = distinct !{!39, !35, !"air-alias-scope-arg(2)"}
!40 = distinct !{!40, !35, !"air-alias-scope-arg(3)"}
!41 = distinct !{!41, !35, !"air-alias-scope-samplers"}
!42 = distinct !{!42, !35, !"air-alias-scope-textures"}
!43 = !{!41, !42}
!44 = !{!37, !38, !39, !40, !34}
!45 = !{!46, !46, i64 0}
!46 = !{!"omnipotent char", !47, i64 0}
!47 = !{!"Simple C++ TBAA"}
!48 = !{!38}
!49 = !{!37, !39, !40, !34, !41, !42}
!50 = !{!37}
!51 = !{!38, !39, !40, !34, !41, !42}
!52 = !{!39}
!53 = !{!37, !38, !40, !34, !41, !42}
!54 = !{!40}
!55 = !{!37, !38, !39, !34, !41, !42}
!56 = !{!57, !57, i64 0}
!57 = !{!"half", !46, i64 0}
