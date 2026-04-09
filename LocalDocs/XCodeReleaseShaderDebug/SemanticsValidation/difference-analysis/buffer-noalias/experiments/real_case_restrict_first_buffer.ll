; ModuleID = '/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_restrict_first_buffer.bc'
source_filename = "/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_restrict_first_buffer.metal"
target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx15.0.0"

%struct.FGlobals_Type = type { <4 x float>, <3 x float>, <4 x float>, <4 x float>, <4 x float>, [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x half>, <4 x float>, [4 x <4 x float>], <4 x float>, [12 x <4 x float>], [4 x <4 x float>], [4 x float], i32, <4 x float>, <4 x float>, half, <4 x half>, <3 x half>, [16 x <4 x half>], <4 x float>, <4 x float>, <4 x float>, <4 x half>, <4 x half>, <4 x half>, half, half, <3 x half>, <3 x half>, <3 x half>, float, float, float, float, i32, i32, float, <4 x float>, float, float, <3 x half>, <4 x half>, half }

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(read)
define <{ <4 x half>, <4 x half> }> @xlatMtlMain(ptr addrspace(2) noalias nocapture noundef readonly align 16 dereferenceable(992) %0, ptr addrspace(2) nocapture readonly %1, ptr addrspace(2) nocapture readonly %2, ptr addrspace(2) nocapture readonly %3, ptr addrspace(2) nocapture readonly %4, ptr addrspace(2) nocapture readonly %5, ptr addrspace(2) nocapture readonly %6, ptr addrspace(2) nocapture readonly %7, ptr addrspace(2) nocapture readonly %8, ptr addrspace(2) nocapture readnone %9, ptr addrspace(2) nocapture readnone %10, ptr addrspace(2) nocapture readnone %11, ptr addrspace(1) %12, ptr addrspace(1) %13, ptr addrspace(1) %14, ptr addrspace(1) %15, ptr addrspace(1) %16, ptr addrspace(1) %17, ptr addrspace(1) %18, ptr addrspace(1) %19, ptr addrspace(1) nocapture readnone %20, ptr addrspace(1) nocapture readnone %21, ptr addrspace(1) nocapture readnone %22, ptr addrspace(1) %23, <4 x float> %24, <3 x float> %25) local_unnamed_addr #0 {
  %27 = shufflevector <4 x float> %24, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %28 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %12, ptr addrspace(2) nocapture readonly %3, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %29 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %13, ptr addrspace(2) nocapture readonly %4, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %30 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %14, ptr addrspace(2) nocapture readonly %5, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %31 = extractvalue { <4 x half>, i8 } %30, 0
  %32 = extractelement <4 x half> %31, i64 3
  %33 = fpext half %32 to float
  %34 = tail call fast float @air.fma.f32(float %33, float 2.550000e+02, float 5.000000e-01) #4
  %35 = tail call fast float @air.fast_floor.f32(float %34) #4
  %36 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %15, ptr addrspace(2) nocapture readonly %7, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %37 = extractvalue { <4 x float>, i8 } %36, 0
  %38 = extractelement <4 x float> %37, i64 0
  %39 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 3
  %40 = load <4 x float>, ptr addrspace(2) %39, align 16, !tbaa !52
  %41 = extractelement <4 x float> %40, i64 0
  %42 = extractelement <4 x float> %40, i64 1
  %43 = tail call fast float @air.fma.f32(float %41, float %38, float %42) #4
  %44 = fdiv fast float 1.000000e+00, %43
  %45 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %16, ptr addrspace(2) nocapture readonly %6, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %46 = insertelement <3 x float> poison, float %44, i64 0
  %47 = shufflevector <3 x float> %46, <3 x float> poison, <3 x i32> zeroinitializer
  %48 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 1
  %49 = load <3 x float>, ptr addrspace(2) %48, align 16, !tbaa !52
  %50 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %25, <3 x float> %47, <3 x float> %49) #4
  %51 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %17, ptr addrspace(2) nocapture readonly %1, <2 x float> %27, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %52 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 7
  %53 = load <4 x half>, ptr addrspace(2) %52, align 16, !tbaa !52
  %54 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 8
  %55 = load <4 x half>, ptr addrspace(2) %54, align 8, !tbaa !52
  %56 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 9
  %57 = load <4 x half>, ptr addrspace(2) %56, align 16, !tbaa !52
  %58 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 10
  %59 = load <4 x half>, ptr addrspace(2) %58, align 8, !tbaa !52
  %60 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 11
  %61 = load <4 x half>, ptr addrspace(2) %60, align 16, !tbaa !52
  %62 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 12
  %63 = load <4 x half>, ptr addrspace(2) %62, align 8, !tbaa !52
  %64 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 13
  %65 = load <4 x half>, ptr addrspace(2) %64, align 16, !tbaa !52
  %66 = tail call i32 @air.convert.u.i32.f.f32(float %35) #4
  %67 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 6
  %68 = load <4 x float>, ptr addrspace(2) %67, align 16, !tbaa !52
  %69 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 14
  %70 = shufflevector <3 x float> %50, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %71 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 16, i64 1
  %72 = load <4 x float>, ptr addrspace(2) %71, align 16, !tbaa !52
  %73 = shufflevector <4 x float> %72, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %74 = fmul fast <3 x float> %73, %70
  %75 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 16, i64 0
  %76 = load <4 x float>, ptr addrspace(2) %75, align 16, !tbaa !52
  %77 = shufflevector <4 x float> %76, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %78 = shufflevector <3 x float> %50, <3 x float> poison, <3 x i32> zeroinitializer
  %79 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %77, <3 x float> %78, <3 x float> %74) #4
  %80 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 16, i64 2
  %81 = load <4 x float>, ptr addrspace(2) %80, align 16, !tbaa !52
  %82 = shufflevector <4 x float> %81, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %83 = shufflevector <3 x float> %50, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %84 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %82, <3 x float> %83, <3 x float> %79) #4
  %85 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 16, i64 3
  %86 = load <4 x float>, ptr addrspace(2) %85, align 16, !tbaa !52
  %87 = shufflevector <4 x float> %86, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %88 = fadd fast <3 x float> %87, %84
  %89 = tail call { <4 x half>, i8 } @air.sample_texture_cube.v4f16(ptr addrspace(1) nocapture readonly %18, ptr addrspace(2) nocapture readonly %2, <3 x float> %88, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %90 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 15
  %91 = load <4 x float>, ptr addrspace(2) %90, align 16, !tbaa !52
  %92 = load <4 x half>, ptr addrspace(2) %69, align 8, !tbaa !52
  %93 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 17
  %94 = load <4 x float>, ptr addrspace(2) %93, align 16, !tbaa !52
  %95 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 21
  %96 = load i32, ptr addrspace(2) %95, align 16, !tbaa !55
  %97 = icmp sgt i32 %96, 1
  br i1 %97, label %127, label %98

98:                                               ; preds = %26
  %99 = extractelement <3 x float> %50, i64 0
  %100 = insertelement <4 x float> <float poison, float poison, float poison, float 1.000000e+00>, float %99, i64 0
  %101 = extractelement <3 x float> %50, i64 1
  %102 = insertelement <4 x float> %100, float %101, i64 1
  %103 = extractelement <3 x float> %50, i64 2
  %104 = insertelement <4 x float> %102, float %103, i64 2
  %105 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 20, i64 0
  %106 = load float, ptr addrspace(2) %105, align 16, !tbaa !60
  %107 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 19, i64 0
  %108 = load <4 x float>, ptr addrspace(2) %107, align 16, !tbaa !52
  %109 = shufflevector <4 x float> %108, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %110 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 4
  %111 = load <4 x float>, ptr addrspace(2) %110, align 16, !tbaa !52
  %112 = shufflevector <4 x float> %111, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %113 = tail call fast float @air.dot.v3f32(<3 x float> %109, <3 x float> %112) #4
  %114 = extractelement <4 x float> %108, i64 3
  %115 = fadd fast float %113, %114
  %116 = insertelement <4 x float> %108, float %115, i64 3
  %117 = tail call fast float @air.dot.v4f32(<4 x float> %116, <4 x float> %104) #4
  %118 = tail call fast float @air.fast_clamp.f32(float %117, float 0.000000e+00, float 1.000000e+00) #4
  %119 = tail call fast float @air.fma.f32(float %118, float -2.000000e+00, float 3.000000e+00) #4
  %120 = fneg fast float %119
  %121 = fmul fast float %118, %118
  %122 = tail call fast float @air.fma.f32(float %120, float %121, float 1.000000e+00) #4
  %123 = fmul fast float %121, %119
  %124 = tail call fast float @air.fma.f32(float %106, float %122, float %123) #4
  %125 = fptrunc float %124 to half
  %126 = fpext half %125 to float
  br label %127

127:                                              ; preds = %26, %98
  %128 = phi float [ %126, %98 ], [ 1.000000e+00, %26 ]
  %129 = insertelement <4 x i32> poison, i32 %66, i64 0
  %130 = shufflevector <4 x i32> %129, <4 x i32> poison, <4 x i32> zeroinitializer
  %131 = icmp eq <4 x i32> %130, <i32 13, i32 8, i32 14, i32 6>
  %132 = tail call <4 x i8> @air.convert.u.v4i8.u.v4i1(<4 x i1> %131) #4
  %133 = insertelement <3 x i32> poison, i32 %66, i64 0
  %134 = shufflevector <3 x i32> %133, <3 x i32> poison, <3 x i32> zeroinitializer
  %135 = icmp eq <3 x i32> %134, <i32 16, i32 19, i32 18>
  %136 = tail call <3 x i32> @air.convert.u.v3i32.u.v3i1(<3 x i1> %135) #4
  %137 = sub <3 x i32> zeroinitializer, %136
  %138 = extractelement <3 x i32> %137, i64 1
  %139 = extractelement <3 x i32> %137, i64 0
  %140 = or i32 %138, %139
  %141 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 22
  %142 = load <4 x float>, ptr addrspace(2) %141, align 16, !tbaa !52
  %143 = shufflevector <4 x float> %142, <4 x float> poison, <2 x i32> <i32 2, i32 3>
  %144 = fmul fast <2 x float> %27, <float 5.000000e-01, float 5.000000e-01>
  %145 = fmul fast <2 x float> %144, %143
  %146 = tail call fast <2 x float> @air.fast_floor.v2f32(<2 x float> %145) #4
  %147 = shufflevector <4 x float> %142, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %148 = fmul fast <2 x float> %146, %147
  %149 = fmul fast <2 x float> %148, <float 2.000000e+00, float 2.000000e+00>
  %150 = shufflevector <2 x float> %148, <2 x float> poison, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %151 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 23
  %152 = load <4 x float>, ptr addrspace(2) %151, align 16, !tbaa !52
  %153 = shufflevector <4 x float> %152, <4 x float> poison, <4 x i32> <i32 0, i32 1, i32 1, i32 2>
  %154 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %150, <4 x float> <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>, <4 x float> %153) #4
  %155 = shufflevector <4 x float> %154, <4 x float> poison, <2 x i32> <i32 2, i32 3>
  %156 = shufflevector <4 x float> %152, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %157 = fadd fast <2 x float> %155, %156
  %158 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %19, ptr addrspace(2) nocapture readonly %8, <2 x float> %149, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %159 = shufflevector <4 x float> %154, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %160 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %19, ptr addrspace(2) nocapture readonly %8, <2 x float> %159, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %161 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %19, ptr addrspace(2) nocapture readonly %8, <2 x float> %155, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %162 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %19, ptr addrspace(2) nocapture readonly %8, <2 x float> %157, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %163 = extractelement <4 x i8> %132, i64 3
  %164 = icmp ne i8 %163, 0
  %165 = shufflevector <4 x half> %31, <4 x half> poison, <2 x i32> <i32 0, i32 1>
  %166 = select fast i1 %164, <2 x half> <half 0xH291F, half 0xH291F>, <2 x half> %165
  %167 = extractelement <4 x i8> %132, i64 0
  %168 = zext i8 %167 to i32
  %169 = sub nsw i32 0, %168
  %170 = or i32 %140, %169
  %171 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 34
  %172 = load half, ptr addrspace(2) %171, align 8, !tbaa !61
  %173 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 35
  %174 = load half, ptr addrspace(2) %173, align 2, !tbaa !62
  %175 = extractelement <4 x half> %31, i64 2
  %176 = icmp ne i32 %170, 0
  br i1 %176, label %177, label %186

177:                                              ; preds = %127
  %178 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %166) #4
  %179 = extractelement <2 x float> %178, i64 0
  %180 = insertelement <3 x float> poison, float %179, i64 0
  %181 = extractelement <2 x float> %178, i64 1
  %182 = insertelement <3 x float> %180, float %181, i64 1
  %183 = fpext half %175 to float
  %184 = insertelement <3 x float> %182, float %183, i64 2
  %185 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %184) #4
  br label %186

186:                                              ; preds = %127, %177
  %187 = phi fast <3 x half> [ %185, %177 ], [ zeroinitializer, %127 ]
  %188 = fpext half %172 to float
  %189 = fcmp fast ogt float %188, 0x3FE99800A0000000
  %190 = fcmp fast une half %172, 0xH4000
  %191 = and i1 %190, %189
  %192 = fcmp fast oeq half %174, 0xH3C00
  %193 = or i1 %192, %191
  %194 = select i1 %193, i32 -1, i32 %139
  %195 = extractvalue { <4 x half>, i8 } %28, 0
  %196 = shufflevector <4 x half> %195, <4 x half> poison, <4 x i32> <i32 3, i32 0, i32 1, i32 2>
  %197 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %196) #4
  %198 = shufflevector <4 x float> %197, <4 x float> poison, <3 x i32> <i32 1, i32 2, i32 3>
  %199 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %198, <3 x float> <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>, <3 x float> <float -1.000000e+00, float -1.000000e+00, float -1.000000e+00>) #4
  %200 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %199) #4
  %201 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %200) #4
  %202 = fneg fast <3 x float> %50
  %203 = shufflevector <4 x float> %68, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %204 = shufflevector <4 x float> %68, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %205 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %202, <3 x float> %203, <3 x float> %204) #4
  %206 = tail call fast float @air.dot.v3f32(<3 x float> %205, <3 x float> %205) #4
  %207 = tail call fast float @air.fast_rsqrt.f32(float %206) #4
  %208 = insertelement <3 x float> poison, float %207, i64 0
  %209 = shufflevector <3 x float> %208, <3 x float> poison, <3 x i32> zeroinitializer
  %210 = fmul fast <3 x float> %209, %205
  %211 = tail call fast float @air.dot.v3f32(<3 x float> %201, <3 x float> %210) #4
  %212 = fptrunc float %211 to half
  %213 = extractvalue { <4 x half>, i8 } %51, 0
  %214 = extractelement <4 x half> %213, i64 0
  %215 = fpext half %214 to float
  %216 = extractvalue { <4 x half>, i8 } %45, 0
  %217 = shufflevector <4 x half> %216, <4 x half> undef, <2 x i32> zeroinitializer
  %218 = fmul fast <2 x half> %217, <half 0xH43F8, half 0xH440C>
  %219 = extractelement <2 x half> %218, i64 0
  %220 = fpext half %219 to float
  %221 = tail call fast float @air.fast_trunc.f32(float %220) #4
  %222 = tail call i32 @air.convert.s.i32.f.f32(float %221) #4
  %223 = tail call fast half @air.clamp.f16(half %212, half 0xH0000, half 0xH3C00) #4
  %224 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 24
  %225 = load half, ptr addrspace(2) %224, align 16, !tbaa !63
  %226 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 50
  %227 = load <4 x half>, ptr addrspace(2) %226, align 16, !tbaa !52
  %228 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 51
  %229 = load half, ptr addrspace(2) %228, align 8, !tbaa !64
  %230 = fneg fast half %229
  %231 = tail call fast half @air.fma.f16(half %230, half 0xH4000, half 0xH4000) #4
  %232 = shufflevector <3 x half> %200, <3 x half> undef, <2 x i32> <i32 1, i32 1>
  %233 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %232) #4
  %234 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 1
  %235 = load <4 x float>, ptr addrspace(2) %234, align 16, !tbaa !52
  %236 = shufflevector <4 x float> %235, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %237 = fmul fast <2 x float> %236, %233
  %238 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 0
  %239 = load <4 x float>, ptr addrspace(2) %238, align 16, !tbaa !52
  %240 = shufflevector <4 x float> %239, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %241 = shufflevector <3 x half> %200, <3 x half> undef, <2 x i32> zeroinitializer
  %242 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %241) #4
  %243 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %240, <2 x float> %242, <2 x float> %237) #4
  %244 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 5, i64 2
  %245 = load <4 x float>, ptr addrspace(2) %244, align 16, !tbaa !52
  %246 = shufflevector <4 x float> %245, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %247 = shufflevector <3 x half> %200, <3 x half> undef, <2 x i32> <i32 2, i32 2>
  %248 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %247) #4
  %249 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %246, <2 x float> %248, <2 x float> %243) #4
  %250 = shufflevector <2 x float> %249, <2 x float> poison, <3 x i32> <i32 0, i32 1, i32 poison>
  %251 = insertelement <3 x float> %250, float 0x3F50624DE0000000, i64 2
  %252 = tail call fast float @air.dot.v3f32(<3 x float> %251, <3 x float> %251) #4
  %253 = fptrunc float %252 to half
  %254 = tail call fast half @air.rsqrt.f16(half %253) #4
  %255 = insertelement <2 x half> poison, half %254, i64 0
  %256 = shufflevector <2 x half> %255, <2 x half> poison, <2 x i32> zeroinitializer
  %257 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %256) #4
  %258 = fmul fast <2 x float> %257, %249
  %259 = tail call fast <2 x half> @air.convert.f.v2f16.f.v2f32(<2 x float> %258) #4
  %260 = insertelement <2 x half> poison, half %231, i64 0
  %261 = shufflevector <2 x half> %260, <2 x half> poison, <2 x i32> zeroinitializer
  %262 = fmul fast <2 x half> %259, %261
  %263 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %262) #4
  %264 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %263, <2 x float> <float 0x3F50624DE0000000, float 0x3F50624DE0000000>, <2 x float> %27) #4
  %265 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly %15, ptr addrspace(2) nocapture readonly %7, <2 x float> %264, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %266 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 49
  %267 = load <3 x half>, ptr addrspace(2) %266, align 8, !tbaa !52
  %268 = fadd fast float %215, 0x3F1A36E2E0000000
  %269 = fptrunc float %268 to half
  %270 = tail call fast half @air.log2.f16(half %269) #4
  %271 = fpext half %270 to float
  %272 = fmul fast float %271, 0x3FC997FE80000000
  %273 = fptrunc float %272 to half
  %274 = tail call fast half @air.exp2.f16(half %273) #4
  %275 = fmul fast half %274, %223
  %276 = tail call fast half @air.fma.f16(half %275, half 0xH3800, half 0xH3800) #4
  %277 = insertelement <2 x half> <half poison, half 0xH0000>, half %276, i64 0
  %278 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %277) #4
  %279 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %23, ptr addrspace(2) nocapture readonly %8, <2 x float> %278, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #3, !alias.scope !48
  %280 = tail call i32 @air.min.s.i32(i32 %222, i32 3) #4
  %281 = mul nsw i32 %280, 3
  %282 = sext i32 %281 to i64
  %283 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 18, i64 %282
  %284 = load <4 x float>, ptr addrspace(2) %283, align 16, !tbaa !52
  %285 = add nsw i32 %281, 1
  %286 = sext i32 %285 to i64
  %287 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 18, i64 %286
  %288 = load <4 x float>, ptr addrspace(2) %287, align 16, !tbaa !52
  %289 = add nsw i32 %281, 2
  %290 = sext i32 %289 to i64
  %291 = getelementptr inbounds %struct.FGlobals_Type, ptr addrspace(2) %0, i64 0, i32 18, i64 %290
  %292 = load <4 x float>, ptr addrspace(2) %291, align 16, !tbaa !52
  %293 = extractvalue { <4 x half>, i8 } %162, 0
  %294 = shufflevector <4 x half> %293, <4 x half> poison, <3 x i32> <i32 2, i32 3, i32 1>
  %295 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %294) #4
  %296 = extractvalue { <4 x half>, i8 } %29, 0
  %297 = extractelement <4 x half> %296, i64 3
  %298 = fpext half %297 to float
  %299 = insertelement <4 x float> %197, float %298, i64 1
  %300 = shufflevector <4 x float> %299, <4 x float> poison, <2 x i32> <i32 1, i32 0>
  %301 = tail call fast <2 x half> @air.convert.f.v2f16.f.v2f32(<2 x float> %300) #4
  %302 = shufflevector <2 x half> %301, <2 x half> poison, <4 x i32> <i32 poison, i32 1, i32 poison, i32 poison>
  %303 = fcmp fast ogt float %298, 0x3FDCCBFF40000000
  %304 = fcmp fast olt float %298, 0x3FE05000C0000000
  %305 = and i1 %303, %304
  %306 = tail call i32 @air.convert.s.i32.f.f32(float %35) #4
  %307 = insertelement <3 x i32> poison, i32 %306, i64 0
  %308 = shufflevector <3 x i32> %307, <3 x i32> poison, <3 x i32> zeroinitializer
  %309 = icmp eq <3 x i32> %308, <i32 11, i32 13, i32 1>
  %310 = tail call <3 x i8> @air.convert.u.v3i8.u.v3i1(<3 x i1> %309) #4
  %311 = extractelement <3 x i8> %310, i64 0
  %312 = extractelement <3 x i8> %310, i64 1
  %313 = or i8 %311, %312
  %314 = extractelement <3 x i8> %310, i64 2
  %315 = or i8 %313, %314
  %316 = icmp ne i8 %315, 0
  %317 = and i1 %305, %316
  %318 = fneg fast float %221
  %319 = extractelement <2 x half> %218, i64 1
  %320 = fpext half %319 to float
  %321 = tail call fast float @air.fma.f32(float %318, float 0x3FF04100E0000000, float %320) #4
  %322 = select fast i1 %317, float 0.000000e+00, float %321
  %323 = insertelement <3 x float> poison, float %322, i64 0
  %324 = shufflevector <3 x float> %323, <3 x float> poison, <3 x i32> zeroinitializer
  %325 = shufflevector <4 x float> %284, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %326 = shufflevector <4 x half> %296, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %327 = insertelement <3 x half> poison, half %223, i64 0
  %328 = shufflevector <3 x half> %327, <3 x half> poison, <3 x i32> zeroinitializer
  %329 = insertelement <3 x float> poison, float %128, i64 0
  %330 = shufflevector <3 x float> %329, <3 x float> poison, <3 x i32> zeroinitializer
  %331 = extractelement <4 x float> %94, i64 0
  %332 = extractelement <4 x float> %94, i64 1
  %333 = fneg fast float %332
  %334 = tail call fast float @air.fma.f32(float %44, float %331, float %333) #4
  %335 = tail call fast float @air.fast_clamp.f32(float %334, float 0.000000e+00, float 1.000000e+00) #4
  %336 = extractelement <4 x float> %94, i64 3
  %337 = fneg fast float %336
  %338 = tail call fast float @air.fma.f32(float %335, float %336, float %337) #4
  %339 = tail call fast float @air.fast_exp2.f32(float %338) #4
  %340 = fmul fast float %339, %335
  %341 = insertelement <3 x float> poison, float %340, i64 0
  %342 = shufflevector <3 x float> %341, <3 x float> poison, <3 x i32> zeroinitializer
  %343 = shufflevector <4 x float> %94, <4 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %344 = extractelement <4 x float> %91, i64 0
  %345 = tail call fast float @air.fma.f32(float %206, float %344, float 1.000000e+00) #4
  %346 = fdiv fast float 1.000000e+00, %345
  %347 = tail call fast float @air.fma.f32(float %346, float 0x3FF0A3D700000000, float 0xBFA47AE140000000) #4
  %348 = tail call fast float @air.fast_clamp.f32(float %347, float 0.000000e+00, float 1.000000e+00) #4
  %349 = extractvalue { <4 x half>, i8 } %89, 0
  %350 = extractelement <4 x half> %349, i64 3
  %351 = fpext half %350 to float
  %352 = fmul fast float %348, %351
  %353 = insertelement <3 x float> poison, float %352, i64 0
  %354 = shufflevector <3 x float> %353, <3 x float> poison, <3 x i32> zeroinitializer
  %355 = shufflevector <4 x half> %92, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %356 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %355) #4
  %357 = fmul fast <3 x float> %354, %356
  %358 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %357) #4
  %359 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %358) #4
  %360 = fmul fast <3 x float> %359, %343
  %361 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %342, <3 x float> %360, <3 x float> %359) #4
  %362 = fmul fast <3 x float> %361, %330
  %363 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %362) #4
  %364 = fmul fast <3 x half> %363, %328
  %365 = shufflevector <4 x half> %213, <4 x half> undef, <3 x i32> zeroinitializer
  %366 = fmul fast <3 x half> %364, %365
  %367 = shufflevector <4 x half> %227, <4 x half> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %368 = shufflevector <4 x half> %227, <4 x half> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %369 = shufflevector <4 x half> %65, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %370 = shufflevector <3 x half> %200, <3 x half> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %371 = extractelement <3 x half> %200, i64 0
  %372 = extractelement <3 x half> %200, i64 1
  %373 = fneg fast half %372
  %374 = fmul fast half %372, %373
  %375 = tail call fast half @air.fma.f16(half %371, half %371, half %374) #4
  %376 = insertelement <3 x half> poison, half %375, i64 0
  %377 = shufflevector <3 x half> %376, <3 x half> poison, <3 x i32> zeroinitializer
  %378 = shufflevector <3 x half> %200, <3 x half> poison, <4 x i32> <i32 1, i32 2, i32 2, i32 0>
  %379 = shufflevector <3 x half> %200, <3 x half> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 2>
  %380 = fmul fast <4 x half> %378, %379
  %381 = tail call fast half @air.dot.v4f16(<4 x half> %59, <4 x half> %380) #4
  %382 = insertelement <4 x half> <half poison, half poison, half poison, half 0xH0000>, half %381, i64 0
  %383 = tail call fast half @air.dot.v4f16(<4 x half> %61, <4 x half> %380) #4
  %384 = insertelement <4 x half> %382, half %383, i64 1
  %385 = tail call fast half @air.dot.v4f16(<4 x half> %63, <4 x half> %380) #4
  %386 = insertelement <4 x half> %384, half %385, i64 2
  %387 = shufflevector <4 x half> %386, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %388 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %369, <3 x half> %377, <3 x half> %387) #4
  %389 = insertelement <4 x half> %370, half 0xH3C00, i64 3
  %390 = tail call fast half @air.dot.v4f16(<4 x half> %53, <4 x half> %389) #4
  %391 = insertelement <3 x half> undef, half %390, i64 0
  %392 = tail call fast half @air.dot.v4f16(<4 x half> %55, <4 x half> %389) #4
  %393 = insertelement <3 x half> %391, half %392, i64 1
  %394 = tail call fast half @air.dot.v4f16(<4 x half> %57, <4 x half> %389) #4
  %395 = insertelement <3 x half> %393, half %394, i64 2
  %396 = fadd fast <3 x half> %395, %388
  %397 = tail call fast <3 x half> @air.fmax.v3f16(<3 x half> %396, <3 x half> zeroinitializer) #4
  %398 = fmul fast <3 x half> %397, %368
  %399 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %366, <3 x half> %367, <3 x half> %398) #4
  %400 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %326, <3 x half> %399, <3 x half> %399) #4
  %401 = extractelement <3 x i32> %137, i64 2
  %402 = icmp ne i32 %401, 0
  %403 = zext i8 %163 to i32
  %404 = sub nsw i32 0, %403
  %405 = extractelement <4 x i8> %132, i64 2
  %406 = zext i8 %405 to i32
  %407 = sub nsw i32 0, %406
  %408 = or i32 %404, %407
  %409 = or i32 %408, %170
  %410 = icmp eq i32 %409, 0
  %411 = select fast i1 %410, <2 x half> %165, <2 x half> <half 0xH291F, half 0xH291F>
  %412 = icmp ne i8 %405, 0
  %413 = select fast i1 %412, <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>, <3 x half> %187
  %414 = shufflevector <3 x half> %413, <3 x half> poison, <2 x i32> <i32 0, i32 1>
  %415 = select fast i1 %402, <2 x half> %411, <2 x half> %414
  %416 = extractelement <2 x half> %415, i64 0
  %417 = insertelement <3 x half> poison, half %416, i64 0
  %418 = extractelement <2 x half> %415, i64 1
  %419 = insertelement <3 x half> %417, half %418, i64 1
  %420 = extractelement <3 x half> %413, i64 2
  %421 = select fast i1 %402, half %175, half %420
  %422 = insertelement <3 x half> %419, half %421, i64 2
  %423 = select fast i1 %164, <3 x half> %400, <3 x half> %422
  %424 = icmp eq i32 %138, 0
  %425 = extractelement <4 x float> %152, i64 3
  %426 = fneg fast float %425
  %427 = insertelement <4 x float> poison, float %426, i64 0
  %428 = shufflevector <4 x float> %427, <4 x float> poison, <4 x i32> zeroinitializer
  %429 = extractvalue { <4 x half>, i8 } %158, 0
  %430 = shufflevector <4 x half> %429, <4 x half> undef, <3 x i32> <i32 poison, i32 2, i32 3>
  %431 = shufflevector <3 x half> %430, <3 x half> poison, <2 x i32> <i32 1, i32 2>
  %432 = tail call fast half @air.dot.v2f16(<2 x half> %431, <2 x half> <half 0xH3C00, half 0xH1C00>) #4
  %433 = fpext half %432 to float
  %434 = fmul fast float %433, 0x3FF0001500000000
  %435 = insertelement <4 x float> poison, float %434, i64 0
  %436 = extractvalue { <4 x half>, i8 } %160, 0
  %437 = shufflevector <4 x half> %436, <4 x half> undef, <3 x i32> <i32 poison, i32 2, i32 3>
  %438 = shufflevector <3 x half> %437, <3 x half> poison, <2 x i32> <i32 1, i32 2>
  %439 = tail call fast half @air.dot.v2f16(<2 x half> %438, <2 x half> <half 0xH3C00, half 0xH1C00>) #4
  %440 = fpext half %439 to float
  %441 = fmul fast float %440, 0x3FF0001500000000
  %442 = insertelement <4 x float> %435, float %441, i64 1
  %443 = extractvalue { <4 x half>, i8 } %161, 0
  %444 = shufflevector <4 x half> %443, <4 x half> undef, <3 x i32> <i32 poison, i32 2, i32 3>
  %445 = shufflevector <3 x half> %444, <3 x half> poison, <2 x i32> <i32 1, i32 2>
  %446 = tail call fast half @air.dot.v2f16(<2 x half> %445, <2 x half> <half 0xH3C00, half 0xH1C00>) #4
  %447 = fpext half %446 to float
  %448 = fmul fast float %447, 0x3FF0001500000000
  %449 = insertelement <4 x float> %442, float %448, i64 2
  %450 = shufflevector <3 x float> %295, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %451 = shufflevector <4 x float> %154, <4 x float> %450, <4 x i32> <i32 0, i32 4, i32 5, i32 6>
  %452 = shufflevector <4 x float> %451, <4 x float> poison, <2 x i32> <i32 1, i32 2>
  %453 = tail call fast float @air.dot.v2f32(<2 x float> %452, <2 x float> <float 1.000000e+00, float 3.906250e-03>) #4
  %454 = fptrunc float %453 to half
  %455 = fpext half %454 to float
  %456 = fmul fast float %455, 0x3FF0001500000000
  %457 = insertelement <4 x float> %449, float %456, i64 3
  %458 = insertelement <4 x float> poison, float %44, i64 0
  %459 = shufflevector <4 x float> %458, <4 x float> poison, <4 x i32> zeroinitializer
  %460 = fdiv fast <4 x float> %457, %459
  %461 = fadd fast <4 x float> %460, <float -1.000000e+00, float -1.000000e+00, float -1.000000e+00, float -1.000000e+00>
  %462 = tail call fast <4 x float> @air.fast_fabs.v4f32(<4 x float> %461) #4
  %463 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %428, <4 x float> %462, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>) #4
  %464 = tail call fast <4 x float> @air.fast_clamp.v4f32(<4 x float> %463, <4 x float> zeroinitializer, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>) #4
  %465 = tail call fast float @air.dot.v4f32(<4 x float> %464, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>) #4
  %466 = fptrunc float %465 to half
  %467 = tail call fast half @air.fmax.f16(half %466, half 0xH068E) #4
  %468 = fpext half %467 to float
  %469 = fcmp fast oge float %468, 0x3F847BFB20000000
  %470 = select fast i1 %469, float 1.000000e+00, float 0.000000e+00
  %471 = extractelement <4 x half> %429, i64 1
  %472 = fpext half %471 to float
  %473 = insertelement <4 x float> %451, float %472, i64 0
  %474 = extractelement <4 x half> %436, i64 1
  %475 = fpext half %474 to float
  %476 = insertelement <4 x float> %473, float %475, i64 1
  %477 = extractelement <4 x half> %443, i64 1
  %478 = fpext half %477 to float
  %479 = insertelement <4 x float> %476, float %478, i64 2
  %480 = tail call fast float @air.dot.v4f32(<4 x float> %464, <4 x float> %479) #4
  %481 = fptrunc float %480 to half
  %482 = fdiv fast half %481, %467
  %483 = tail call fast half @air.clamp.f16(half %482, half 0xH0000, half 0xH3C00) #4
  %484 = fsub fast half %483, %471
  %485 = fpext half %484 to float
  %486 = tail call fast float @air.fma.f32(float %470, float %485, float %472) #4
  %487 = extractelement <2 x half> %301, i64 0
  %488 = fneg fast half %487
  %489 = tail call fast half @air.fma.f16(half %488, half 0xH399A, half 0xH3C00) #4
  %490 = fpext half %489 to float
  %491 = tail call fast float @air.fast_fmin.f32(float %486, float %490) #4
  %492 = fptrunc float %491 to half
  %493 = insertelement <3 x half> poison, half %492, i64 0
  %494 = shufflevector <3 x half> %493, <3 x half> poison, <3 x i32> zeroinitializer
  %495 = fmul fast <3 x half> %397, <half 0xH3A48, half 0xH3A48, half 0xH3A48>
  %496 = tail call fast half @air.dot.v3f16(<3 x half> %397, <3 x half> <half 0xH32CE, half 0xH39B9, half 0xH2C9F>) #4
  %497 = tail call fast half @air.fmax.f16(half %496, half 0xH3C00) #4
  %498 = insertelement <3 x half> poison, half %497, i64 0
  %499 = shufflevector <3 x half> %498, <3 x half> poison, <3 x i32> zeroinitializer
  %500 = fdiv fast <3 x half> %495, %499
  %501 = fsub fast <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>, %500
  %502 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %494, <3 x half> %501, <3 x half> %500) #4
  %503 = select fast i1 %424, <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>, <3 x half> %502
  %504 = fmul fast <3 x half> %503, %423
  %505 = shufflevector <2 x half> %301, <2 x half> poison, <4 x i32> <i32 0, i32 poison, i32 poison, i32 poison>
  %506 = insertelement <4 x half> %505, half 0xH291F, i64 3
  %507 = icmp eq i32 %194, -1
  %508 = icmp eq i32 %194, 0
  %509 = fmul fast <2 x half> %301, <half 0xH4500, half 0xH4D00>
  %510 = extractelement <2 x half> %509, i64 1
  %511 = extractelement <2 x half> %301, i64 1
  %512 = fmul fast half %510, %511
  %513 = select i1 %508, half 0xH0000, half %512
  %514 = select i1 %507, half %513, half 0xH0000
  %515 = insertelement <4 x half> %506, half %514, i64 2
  %516 = shufflevector <4 x half> %515, <4 x half> poison, <3 x i32> <i32 3, i32 0, i32 2>
  %517 = shufflevector <2 x half> %166, <2 x half> undef, <4 x i32> <i32 0, i32 poison, i32 poison, i32 poison>
  %518 = insertelement <4 x half> %517, half 0xH0000, i64 2
  %519 = shufflevector <4 x half> %518, <4 x half> %302, <3 x i32> <i32 0, i32 5, i32 2>
  %520 = select fast i1 %176, <3 x half> %516, <3 x half> %519
  %521 = extractelement <3 x half> %520, i64 1
  %522 = fmul fast half %521, %521
  %523 = fmul fast half %522, 0xH4D00
  %524 = extractelement <3 x half> %520, i64 0
  %525 = fmul fast half %524, 0xH5BF8
  %526 = fpext half %525 to float
  %527 = tail call i32 @air.convert.u.i32.f.f32(float %526) #4
  %528 = and i32 %527, 127
  %529 = tail call fast float @air.convert.f.f32.u.i32(i32 %528) #4
  %530 = fmul fast float %529, 0x3F80204120000000
  %531 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %363) #4
  %532 = insertelement <3 x float> poison, float %215, i64 0
  %533 = shufflevector <3 x float> %532, <3 x float> poison, <3 x i32> zeroinitializer
  %534 = fmul fast <3 x float> %531, %533
  %535 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %534) #4
  %536 = tail call fast half @air.dot.v3f16(<3 x half> %535, <3 x half> <half 0xH2914, half 0xH3754, half 0xH1E3E>) #4
  %537 = extractelement <2 x half> %509, i64 0
  %538 = fmul fast half %536, %537
  %539 = fpext half %538 to float
  %540 = fmul fast float %530, %539
  %541 = fptrunc float %540 to half
  %542 = select i1 %193, half %541, half 0xH0000
  %543 = extractelement <3 x half> %520, i64 2
  %544 = select fast i1 %412, half %542, half %543
  %545 = select fast i1 %402, half %523, half %544
  %546 = insertelement <3 x half> poison, half %545, i64 0
  %547 = shufflevector <3 x half> %546, <3 x half> poison, <3 x i32> zeroinitializer
  %548 = extractvalue { <4 x half>, i8 } %279, 0
  %549 = extractelement <4 x half> %548, i64 0
  %550 = fpext half %549 to float
  %551 = insertelement <3 x float> poison, float %550, i64 0
  %552 = shufflevector <3 x float> %551, <3 x float> poison, <3 x i32> zeroinitializer
  %553 = fmul fast <3 x float> %356, %552
  %554 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %553) #4
  %555 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %397, <3 x half> %502, <3 x half> %554) #4
  %556 = fadd fast <3 x half> %423, <half 0xHBC00, half 0xHBC00, half 0xHBC00>
  %557 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %556, <3 x half> <half 0xH3800, half 0xH3800, half 0xH3800>, <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>) #4
  %558 = fneg fast <3 x float> %25
  %559 = tail call fast float @air.dot.v3f32(<3 x float> %25, <3 x float> %25) #4
  %560 = tail call fast float @air.fast_rsqrt.f32(float %559) #4
  %561 = insertelement <3 x float> poison, float %560, i64 0
  %562 = shufflevector <3 x float> %561, <3 x float> poison, <3 x i32> zeroinitializer
  %563 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %558, <3 x float> %562, <3 x float> %210) #4
  %564 = tail call fast float @air.dot.v3f32(<3 x float> %563, <3 x float> %563) #4
  %565 = tail call fast float @air.fast_rsqrt.f32(float %564) #4
  %566 = insertelement <3 x float> poison, float %565, i64 0
  %567 = shufflevector <3 x float> %566, <3 x float> poison, <3 x i32> zeroinitializer
  %568 = fmul fast <3 x float> %567, %563
  %569 = tail call fast float @air.dot.v3f32(<3 x float> %210, <3 x float> %568) #4
  %570 = tail call fast float @air.fast_clamp.f32(float %569, float 0.000000e+00, float 1.000000e+00) #4
  %571 = fsub fast float 1.000000e+00, %570
  %572 = fmul fast float %571, %571
  %573 = fmul fast float %572, %572
  %574 = fmul fast float %573, %571
  %575 = insertelement <3 x float> poison, float %574, i64 0
  %576 = shufflevector <3 x float> %575, <3 x float> poison, <3 x i32> zeroinitializer
  %577 = fcmp fast une half %225, 0xH0000
  %578 = insertelement <2 x i32> poison, i32 %409, i64 0
  %579 = shufflevector <2 x i32> %578, <2 x i32> poison, <2 x i32> zeroinitializer
  %580 = shufflevector <3 x i32> %137, <3 x i32> undef, <2 x i32> <i32 2, i32 2>
  %581 = or <2 x i32> %579, %580
  %582 = extractelement <2 x i32> %581, i64 0
  %583 = icmp eq i32 %582, 0
  %584 = extractelement <4 x half> %31, i64 0
  %585 = select i1 %583, half %584, half 0xH291F
  %586 = insertelement <4 x half> %386, half %585, i64 0
  %587 = extractelement <2 x i32> %581, i64 1
  %588 = icmp eq i32 %587, 0
  %589 = extractelement <4 x half> %31, i64 1
  %590 = select i1 %588, half %589, half 0xH291F
  %591 = insertelement <4 x half> %586, half %590, i64 1
  %592 = shufflevector <4 x half> %591, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 0>
  %593 = tail call fast half @air.dot.v3f16(<3 x half> %592, <3 x half> <half 0xH2914, half 0xH3754, half 0xH1E3E>) #4
  %594 = insertelement <3 x half> poison, half %593, i64 0
  %595 = shufflevector <3 x half> %594, <3 x half> poison, <4 x i32> <i32 0, i32 0, i32 0, i32 poison>
  %596 = select i1 %402, half 0xH291F, half %175
  %597 = insertelement <4 x half> %591, half %596, i64 2
  %598 = select fast i1 %577, <4 x half> %595, <4 x half> %597
  %599 = shufflevector <4 x half> %598, <4 x half> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %600 = fsub fast <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>, %599
  %601 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %600) #4
  %602 = fmul fast <3 x float> %576, %601
  %603 = or i32 %170, %401
  %604 = icmp eq i32 %603, 0
  %605 = select fast i1 %604, half %511, half %487
  %606 = fsub fast half 0xH3C00, %605
  %607 = fmul fast half %606, %606
  %608 = fneg fast half %607
  %609 = tail call fast half @air.fma.f16(half %608, half %607, half 0xH3C00) #4
  %610 = fmul fast half %609, 0xH4000
  %611 = insertelement <3 x half> poison, half %610, i64 0
  %612 = shufflevector <3 x half> %611, <3 x half> poison, <3 x i32> zeroinitializer
  %613 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %612) #4
  %614 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %599) #4
  %615 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %602, <3 x float> %613, <3 x float> %614) #4
  %616 = fmul fast half %607, %607
  %617 = fpext half %616 to float
  %618 = fmul fast float %617, 0x3FD45F30E0000000
  %619 = tail call fast float @air.dot.v3f32(<3 x float> %201, <3 x float> %568) #4
  %620 = tail call fast float @air.fast_clamp.f32(float %619, float 0.000000e+00, float 1.000000e+00) #4
  %621 = fneg fast float %620
  %622 = tail call fast float @air.fma.f32(float %620, float %617, float %621) #4
  %623 = tail call fast float @air.fma.f32(float %622, float %620, float 1.000000e+00) #4
  %624 = fmul fast float %623, %623
  %625 = tail call fast float @air.fast_fmax.f32(float %624, float 0x3F1A36E2E0000000) #4
  %626 = fdiv fast float %618, %625
  %627 = tail call fast float @air.fast_fmin.f32(float %626, float 1.200000e+01) #4
  %628 = insertelement <3 x float> poison, float %627, i64 0
  %629 = shufflevector <3 x float> %628, <3 x float> poison, <3 x i32> zeroinitializer
  %630 = fmul fast <3 x float> %629, %615
  %631 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %630) #4
  %632 = fmul fast <3 x half> %631, %364
  %633 = extractvalue { <4 x float>, i8 } %265, 0
  %634 = extractelement <4 x float> %633, i64 0
  %635 = tail call fast float @air.fma.f32(float %41, float %634, float %42) #4
  %636 = fdiv fast float 1.000000e+00, %635
  %637 = fsub fast float %636, %44
  %638 = fptrunc float %637 to half
  %639 = tail call fast half @air.fmax.f16(half %638, half 0xH1419) #4
  %640 = tail call fast half @air.log2.f16(half %639) #4
  %641 = fpext half %640 to float
  %642 = fmul fast float %641, 0x3FA47BFE80000000
  %643 = fptrunc float %642 to half
  %644 = tail call fast half @air.exp2.f16(half %643) #4
  %645 = fpext half %644 to float
  %646 = fadd fast float %645, 0xBFE99800A0000000
  %647 = fptrunc float %646 to half
  %648 = fmul fast half %647, 0xH4900
  %649 = tail call fast half @air.clamp.f16(half %648, half 0xH0000, half 0xH3C00) #4
  %650 = tail call fast half @air.fma.f16(half %649, half 0xHC000, half 0xH4200) #4
  %651 = fsub fast float 2.000000e+00, %44
  %652 = fptrunc float %651 to half
  %653 = fpext half %652 to float
  %654 = tail call fast float @air.fma.f32(float %653, float 0x3FD3333340000000, float %44) #4
  %655 = fptrunc float %654 to half
  %656 = tail call fast half @air.fmin.f16(half %655, half 0xH3C00) #4
  %657 = fmul fast half %649, %649
  %658 = fmul fast half %657, %223
  %659 = fmul fast half %658, %650
  %660 = fmul fast half %659, %656
  %661 = insertelement <3 x half> poison, half %660, i64 0
  %662 = shufflevector <3 x half> %661, <3 x half> poison, <3 x i32> zeroinitializer
  %663 = fmul fast <3 x half> %326, <half 0xH4500, half 0xH4500, half 0xH4500>
  %664 = tail call fast <3 x half> @air.clamp.v3f16(<3 x half> %663, <3 x half> zeroinitializer, <3 x half> <half 0xH3C00, half 0xH3C00, half 0xH3C00>) #4
  %665 = fneg fast <3 x float> %25
  %666 = fmul fast <3 x float> %562, %665
  %667 = tail call fast float @air.dot.v3f32(<3 x float> %666, <3 x float> %201) #4
  %668 = fptrunc float %667 to half
  %669 = fsub fast half 0xH3C00, %668
  %670 = tail call fast half @air.clamp.f16(half %669, half 0xH0000, half 0xH3C00) #4
  %671 = tail call fast half @air.fmax.f16(half %670, half 0xH211F) #4
  %672 = fmul fast half %671, %671
  %673 = fmul fast half %672, %672
  %674 = fmul fast half %673, %671
  %675 = insertelement <3 x half> poison, half %674, i64 0
  %676 = shufflevector <3 x half> %675, <3 x half> poison, <3 x i32> zeroinitializer
  %677 = fmul fast <3 x half> %664, %267
  %678 = fmul fast <3 x half> %677, %662
  %679 = fmul fast <3 x half> %678, %676
  %680 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %632, <3 x half> %365, <3 x half> %679) #4
  %681 = fmul fast <3 x half> %680, %557
  %682 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %681) #4
  %683 = fmul fast <3 x float> %682, <float 0x3FE3333340000000, float 0x3FE3333340000000, float 0x3FE3333340000000>
  %684 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %683) #4
  %685 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %555, <3 x half> %326, <3 x half> %684) #4
  %686 = tail call fast <3 x half> @air.fma.v3f16(<3 x half> %504, <3 x half> %547, <3 x half> %685) #4
  %687 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %686) #4
  %688 = tail call fast <3 x float> @air.fast_fmax.v3f32(<3 x float> %687, <3 x float> <float 0x3F1A36E2E0000000, float 0x3F1A36E2E0000000, float 0x3F1A36E2E0000000>) #4
  %689 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %688) #4
  %690 = tail call fast half @air.dot.v3f16(<3 x half> %689, <3 x half> <half 0xH32CE, half 0xH39B9, half 0xH2C9F>) #4
  %691 = fneg fast half %690
  %692 = insertelement <3 x half> poison, half %691, i64 0
  %693 = shufflevector <3 x half> %692, <3 x half> poison, <3 x i32> zeroinitializer
  %694 = fadd fast <3 x half> %693, %689
  %695 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %694) #4
  %696 = fpext half %690 to float
  %697 = insertelement <3 x float> poison, float %696, i64 0
  %698 = shufflevector <3 x float> %697, <3 x float> poison, <3 x i32> zeroinitializer
  %699 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %325, <3 x float> %695, <3 x float> %698) #4
  %700 = tail call fast <3 x float> @air.fast_fmax.v3f32(<3 x float> %699, <3 x float> zeroinitializer) #4
  %701 = tail call fast <3 x float> @air.fast_log2.v3f32(<3 x float> %700) #4
  %702 = extractelement <3 x float> %701, i64 0
  %703 = extractelement <4 x float> %284, i64 3
  %704 = fmul fast float %702, %703
  %705 = insertelement <3 x float> poison, float %704, i64 0
  %706 = extractelement <4 x float> %288, i64 3
  %707 = extractelement <3 x float> %701, i64 1
  %708 = fmul fast float %707, %706
  %709 = insertelement <3 x float> %705, float %708, i64 1
  %710 = extractelement <4 x float> %292, i64 3
  %711 = extractelement <3 x float> %701, i64 2
  %712 = fmul fast float %711, %710
  %713 = insertelement <3 x float> %709, float %712, i64 2
  %714 = tail call fast <3 x float> @air.fast_exp2.v3f32(<3 x float> %713) #4
  %715 = shufflevector <4 x float> %288, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %716 = shufflevector <4 x float> %292, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %717 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %714, <3 x float> %715, <3 x float> %716) #4
  %718 = tail call fast <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half> %689) #4
  %719 = fsub fast <3 x float> %717, %718
  %720 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %324, <3 x float> %719, <3 x float> %718) #4
  %721 = tail call fast float @air.convert.f.f32.u.i32(i32 %66) #4
  %722 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %720) #4
  %723 = extractelement <3 x half> %722, i64 0
  %724 = extractelement <3 x half> %722, i64 1
  %725 = extractelement <3 x half> %722, i64 2
  %726 = insertelement <4 x half> poison, half %723, i64 0
  %727 = insertelement <4 x half> %726, half %724, i64 1
  %728 = insertelement <4 x half> %727, half %725, i64 2
  %729 = fptrunc float %721 to half
  %730 = insertelement <4 x half> %728, half %729, i64 3
  %731 = insertvalue <{ <4 x half>, <4 x half> }> undef, <4 x half> %730, 0
  %732 = insertvalue <{ <4 x half>, <4 x half> }> %731, <4 x half> %730, 1
  ret <{ <4 x half>, <4 x half> }> %732
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x i8> @air.convert.u.v3i8.u.v3i1(<3 x i1>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.convert.u.i32.f.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x float> @air.convert.f.v3f32.f.v3f16(<3 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i8> @air.convert.u.v4i8.u.v4i1(<4 x i1>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x i32> @air.convert.u.v3i32.u.v3i1(<3 x i1>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x half> @air.convert.f.v2f16.f.v2f32(<2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_floor.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_trunc.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x half> @air.fma.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x half> @air.fmax.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_clamp.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_exp2.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.dot.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.fast_floor.v2f32(<2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.dot.v2f16(<2 x half>, <2 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fabs.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_clamp.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.fmax.f16(half, half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.dot.v3f16(<3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.rsqrt.f16(half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.log2.f16(half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.exp2.f16(half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare half @air.fmin.f16(half, half) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x half> @air.clamp.v3f16(<3 x half>, <3 x half>, <3 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x float> @air.fast_fmax.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.min.s.i32(i32, i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x float> @air.fast_log2.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <3 x float> @air.fast_exp2.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_cube.v4f16(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, <3 x float>, i1, float, float, i32) local_unnamed_addr #2

attributes #0 = { convergent mustprogress nofree nounwind willreturn memory(read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #3 = { convergent nounwind willreturn memory(argmem: read) }
attributes #4 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.fragment = !{!9}
!air.compile_options = !{!41, !42, !43}
!llvm.ident = !{!44}
!air.version = !{!45}
!air.language_version = !{!46}
!air.source_file_name = !{!47}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @xlatMtlMain, !10, !13}
!10 = !{!11, !12}
!11 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_Target0"}
!12 = !{!"air.render_target", i32 1, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_Target1"}
!13 = !{!14, !16, !17, !18, !19, !20, !21, !22, !23, !24, !25, !26, !27, !28, !29, !30, !31, !32, !33, !34, !35, !36, !37, !38, !39, !40}
!14 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 992, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !15, !"air.arg_type_size", i32 992, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"FGlobals_Type", !"air.arg_name", !"FGlobals"}
!15 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 32, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 48, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 64, i32 16, i32 0, !"float4", !"_mhyWorldOffset", i32 80, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4unity_WorldToCamera", i32 144, i32 16, i32 0, !"float4", !"_WorldSpaceLightPos0", i32 160, i32 8, i32 0, !"half4", !"unity_SHAr", i32 168, i32 8, i32 0, !"half4", !"unity_SHAg", i32 176, i32 8, i32 0, !"half4", !"unity_SHAb", i32 184, i32 8, i32 0, !"half4", !"unity_SHBr", i32 192, i32 8, i32 0, !"half4", !"unity_SHBg", i32 200, i32 8, i32 0, !"half4", !"unity_SHBb", i32 208, i32 8, i32 0, !"half4", !"unity_SHC", i32 216, i32 8, i32 0, !"half4", !"_LightColor0", i32 224, i32 16, i32 0, !"float4", !"_mhyMainLightParam", i32 240, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_MHYWorldToLightCookie", i32 304, i32 16, i32 0, !"float4", !"_ES_MainLightIntensityIncreaseParams", i32 320, i32 16, i32 12, !"float4", !"_ColorGradingProfileArray", i32 512, i32 16, i32 4, !"float4", !"_MainLightClipPlaneBaseParamsList", i32 576, i32 4, i32 4, !"float", !"_MainLightClipPlaneAlphas", i32 592, i32 4, i32 0, !"uint", !"_MainLightClipPlaneCount", i32 608, i32 16, i32 0, !"float4", !"_CameraDepthTexture_TexelSize", i32 624, i32 16, i32 0, !"float4", !"_BlurKernel", i32 640, i32 2, i32 0, !"half", !"_ElementViewEleDrawOn", i32 648, i32 8, i32 0, !"half4", !"_ElementViewSceneBackgroundColor", i32 656, i32 8, i32 0, !"half3", !"_ElementViewSceneLightColor", i32 664, i32 8, i32 16, !"half4", !"_ElementViewEleColors", i32 800, i32 16, i32 0, !"float4", !"_ElementViewParamsFloat1", i32 816, i32 16, i32 0, !"float4", !"_ElementViewParamsFloat2", i32 832, i32 16, i32 0, !"float4", !"_ElementViewParamsFloat3", i32 848, i32 8, i32 0, !"half4", !"_ElementViewParamsHalf1", i32 856, i32 8, i32 0, !"half4", !"_ElementViewParamsHalf2", i32 864, i32 8, i32 0, !"half4", !"_ElementViewParamsHalf3", i32 872, i32 2, i32 0, !"half", !"_SpecialElementViewID", i32 874, i32 2, i32 0, !"half", !"_ShamanViewOn", i32 880, i32 8, i32 0, !"half3", !"_ShamanViewWaveColorA", i32 888, i32 8, i32 0, !"half3", !"_ShamanViewWaveColorB", i32 896, i32 8, i32 0, !"half3", !"_ShamanViewDarkenColor", i32 904, i32 4, i32 0, !"float", !"_ShamanViewSymbolScale", i32 908, i32 4, i32 0, !"float", !"_ShamanSymbolBreathSpeed", i32 912, i32 4, i32 0, !"float", !"_ShamanViewRandomX", i32 916, i32 4, i32 0, !"float", !"_ShamanViewRandomY", i32 920, i32 4, i32 0, !"int", !"_ShamanViewXpattern", i32 924, i32 4, i32 0, !"int", !"_ShamanViewYpattern", i32 928, i32 4, i32 0, !"float", !"_waveSymbolScale", i32 944, i32 16, i32 0, !"float4", !"_ShamanSymbolMaskUV", i32 960, i32 4, i32 0, !"float", !"_ShamanViewOffset", i32 964, i32 4, i32 0, !"float", !"_ShamanViewLength", i32 968, i32 8, i32 0, !"half3", !"_ES_SceneFrontRimColor", i32 976, i32 8, i32 0, !"half4", !"_SandGliter_TillPowerGamma", i32 984, i32 2, i32 0, !"half", !"_StaticObjectRimWidthScaleReverse"}
!16 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ShadowMapTexture"}
!17 = !{i32 2, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_MHYLightTexture0"}
!18 = !{i32 3, !"air.sampler", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraNormalsTexture"}
!19 = !{i32 4, !"air.sampler", !"air.location_index", i32 3, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraAlbedoTexture"}
!20 = !{i32 5, !"air.sampler", !"air.location_index", i32 4, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraSpecularTexture"}
!21 = !{i32 6, !"air.sampler", !"air.location_index", i32 5, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraColorGradingVolumeMaskTexture"}
!22 = !{i32 7, !"air.sampler", !"air.location_index", i32 6, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraDepthTexture"}
!23 = !{i32 8, !"air.sampler", !"air.location_index", i32 7, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_AOHalfTexture"}
!24 = !{i32 9, !"air.sampler", !"air.location_index", i32 8, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ElementViewScenePatternTex", !"air.arg_unused"}
!25 = !{i32 10, !"air.sampler", !"air.location_index", i32 9, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ElementViewSceneWaveTex", !"air.arg_unused"}
!26 = !{i32 11, !"air.sampler", !"air.location_index", i32 10, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_ElementViewElePatternTex", !"air.arg_unused"}
!27 = !{i32 12, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_CameraNormalsTexture"}
!28 = !{i32 13, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_CameraAlbedoTexture"}
!29 = !{i32 14, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_CameraSpecularTexture"}
!30 = !{i32 15, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_CameraDepthTexture"}
!31 = !{i32 16, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_CameraColorGradingVolumeMaskTexture"}
!32 = !{i32 17, !"air.texture", !"air.location_index", i32 5, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ShadowMapTexture"}
!33 = !{i32 18, !"air.texture", !"air.location_index", i32 6, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<half, sample>", !"air.arg_name", !"_MHYLightTexture0"}
!34 = !{i32 19, !"air.texture", !"air.location_index", i32 7, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_AOHalfTexture"}
!35 = !{i32 20, !"air.texture", !"air.location_index", i32 8, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ElementViewElePatternTex", !"air.arg_unused"}
!36 = !{i32 21, !"air.texture", !"air.location_index", i32 9, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ElementViewSceneWaveTex", !"air.arg_unused"}
!37 = !{i32 22, !"air.texture", !"air.location_index", i32 10, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_ElementViewScenePatternTex", !"air.arg_unused"}
!38 = !{i32 23, !"air.texture", !"air.location_index", i32 11, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_DeferredToonRampTex"}
!39 = !{i32 24, !"air.fragment_input", !"generated(9TEXCOORD0Dv4_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD0"}
!40 = !{i32 25, !"air.fragment_input", !"generated(9TEXCOORD1Dv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"TEXCOORD1"}
!41 = !{!"air.compile.denorms_disable"}
!42 = !{!"air.compile.fast_math_enable"}
!43 = !{!"air.compile.framebuffer_fetch_enable"}
!44 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!45 = !{i32 2, i32 7, i32 0}
!46 = !{!"Metal", i32 3, i32 2, i32 0}
!47 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_restrict_first_buffer.metal"}
!48 = !{!49, !51}
!49 = distinct !{!49, !50, !"air-alias-scope-samplers"}
!50 = distinct !{!50, !"air-alias-scopes(xlatMtlMain)"}
!51 = distinct !{!51, !50, !"air-alias-scope-textures"}
!52 = !{!53, !53, i64 0}
!53 = !{!"omnipotent char", !54, i64 0}
!54 = !{!"Simple C++ TBAA"}
!55 = !{!56, !57, i64 592}
!56 = !{!"_ZTS13FGlobals_Type", !53, i64 0, !53, i64 16, !53, i64 32, !53, i64 48, !53, i64 64, !53, i64 80, !53, i64 144, !53, i64 160, !53, i64 168, !53, i64 176, !53, i64 184, !53, i64 192, !53, i64 200, !53, i64 208, !53, i64 216, !53, i64 224, !53, i64 240, !53, i64 304, !53, i64 320, !53, i64 512, !53, i64 576, !57, i64 592, !53, i64 608, !53, i64 624, !58, i64 640, !53, i64 648, !53, i64 656, !53, i64 664, !53, i64 800, !53, i64 816, !53, i64 832, !53, i64 848, !53, i64 856, !53, i64 864, !58, i64 872, !58, i64 874, !53, i64 880, !53, i64 888, !53, i64 896, !59, i64 904, !59, i64 908, !59, i64 912, !59, i64 916, !57, i64 920, !57, i64 924, !59, i64 928, !53, i64 944, !59, i64 960, !59, i64 964, !53, i64 968, !53, i64 976, !58, i64 984}
!57 = !{!"int", !53, i64 0}
!58 = !{!"half", !53, i64 0}
!59 = !{!"float", !53, i64 0}
!60 = !{!59, !59, i64 0}
!61 = !{!56, !58, i64 872}
!62 = !{!56, !58, i64 874}
!63 = !{!56, !58, i64 640}
!64 = !{!56, !58, i64 984}
