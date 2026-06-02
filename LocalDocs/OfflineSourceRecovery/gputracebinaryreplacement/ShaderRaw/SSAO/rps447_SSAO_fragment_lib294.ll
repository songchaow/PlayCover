; ModuleID = '/tmp/lysk-ssao-447/library_294.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.cb_SSAO_Type = type { [4 x <4 x float>], <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x half>, <4 x half> }

; Function Attrs: convergent nounwind optsize memory(read)
define <{ <4 x half> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(144) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) %1, ptr addrspace(1) %2, <4 x float> %3, <2 x float> %4) local_unnamed_addr #0 {
  %6 = shufflevector <2 x float> %4, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %7 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 4
  %8 = load <4 x float>, ptr addrspace(2) %7, align 16, !tbaa !24, !alias.scope !27, !noalias !30
  %9 = fadd fast <4 x float> %8, %6
  %10 = shufflevector <4 x float> %9, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %11 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %10, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !30, !noalias !27
  %12 = extractvalue { <4 x float>, i8 } %11, 0
  %13 = shufflevector <4 x float> %12, <4 x float> undef, <2 x i32> <i32 0, i32 2>
  %14 = shufflevector <4 x float> %9, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %15 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %14, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #3, !alias.scope !30, !noalias !27
  %16 = extractvalue { <4 x float>, i8 } %15, 0
  %17 = shufflevector <4 x float> %16, <4 x float> undef, <2 x i32> <i32 0, i32 2>
  %18 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %4, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %19 = extractvalue { <4 x float>, i8 } %18, 0
  %20 = extractelement <4 x float> %19, i64 0
  %21 = shufflevector <4 x float> %19, <4 x float> undef, <2 x i32> zeroinitializer
  %22 = fsub fast <2 x float> %13, %21
  %23 = shufflevector <2 x float> %17, <2 x float> undef, <2 x i32> <i32 1, i32 0>
  %24 = fsub fast <2 x float> %23, %21
  %25 = tail call fast <2 x float> @air.fast_fabs.v2f32(<2 x float> %22) #1
  %26 = tail call fast <2 x float> @air.fast_fabs.v2f32(<2 x float> %24) #1
  %27 = fcmp fast olt <2 x float> %25, %26
  %28 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 3
  %29 = load <4 x float>, ptr addrspace(2) %28, align 16, !tbaa !24, !alias.scope !27, !noalias !30
  %30 = fsub fast <4 x float> %6, %29
  %31 = shufflevector <4 x float> %30, <4 x float> undef, <4 x i32> <i32 3, i32 0, i32 2, i32 1>
  %32 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 1
  %33 = load <4 x float>, ptr addrspace(2) %32, align 16, !alias.scope !27, !noalias !30
  %34 = shufflevector <4 x float> %33, <4 x float> undef, <4 x i32> <i32 1, i32 0, i32 0, i32 1>
  %35 = shufflevector <4 x float> %33, <4 x float> undef, <4 x i32> <i32 3, i32 2, i32 2, i32 3>
  %36 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %31, <4 x float> %34, <4 x float> %35) #1
  %37 = shufflevector <4 x float> %36, <4 x float> undef, <2 x i32> <i32 1, i32 3>
  %38 = shufflevector <2 x float> %37, <2 x float> undef, <4 x i32> <i32 poison, i32 0, i32 1, i32 poison>
  %39 = insertelement <4 x float> %38, float -1.000000e+00, i64 0
  %40 = shufflevector <2 x float> %4, <2 x float> undef, <2 x i32> <i32 1, i32 0>
  %41 = shufflevector <4 x float> %33, <4 x float> undef, <2 x i32> <i32 1, i32 0>
  %42 = shufflevector <4 x float> %33, <4 x float> undef, <2 x i32> <i32 3, i32 2>
  %43 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %40, <2 x float> %41, <2 x float> %42) #1
  %44 = shufflevector <2 x float> %43, <2 x float> undef, <4 x i32> <i32 0, i32 poison, i32 1, i32 poison>
  %45 = insertelement <4 x float> %44, float -1.000000e+00, i64 1
  %46 = shufflevector <4 x float> %19, <4 x float> undef, <3 x i32> zeroinitializer
  %47 = shufflevector <4 x float> %45, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %48 = fmul fast <3 x float> %47, %46
  %49 = shufflevector <3 x float> %48, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %50 = shufflevector <4 x float> %45, <4 x float> %49, <4 x i32> <i32 4, i32 1, i32 5, i32 6>
  %51 = shufflevector <4 x float> %39, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %52 = fsub fast <3 x float> splat (float -0.000000e+00), %51
  %53 = shufflevector <4 x float> %12, <4 x float> undef, <3 x i32> zeroinitializer
  %54 = shufflevector <4 x float> %50, <4 x float> undef, <3 x i32> <i32 2, i32 3, i32 0>
  %55 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %52, <3 x float> %53, <3 x float> %54) #1
  %56 = fadd fast <4 x float> %29, %6
  %57 = shufflevector <4 x float> %56, <4 x float> undef, <4 x i32> <i32 3, i32 0, i32 2, i32 1>
  %58 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %57, <4 x float> %34, <4 x float> %35) #1
  %59 = shufflevector <4 x float> %58, <4 x float> undef, <2 x i32> <i32 1, i32 3>
  %60 = shufflevector <2 x float> %59, <2 x float> undef, <4 x i32> <i32 poison, i32 0, i32 1, i32 poison>
  %61 = insertelement <4 x float> %60, float -1.000000e+00, i64 0
  %62 = shufflevector <4 x float> %61, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %63 = shufflevector <4 x float> %16, <4 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %64 = fsub fast <3 x float> splat (float -0.000000e+00), %54
  %65 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %62, <3 x float> %63, <3 x float> %64) #1
  %66 = shufflevector <2 x i1> %27, <2 x i1> undef, <3 x i32> zeroinitializer
  %67 = select fast <3 x i1> %66, <3 x float> %55, <3 x float> %65
  %68 = insertelement <4 x float> %36, float -1.000000e+00, i64 1
  %69 = shufflevector <4 x float> %68, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %70 = fsub fast <3 x float> splat (float -0.000000e+00), %69
  %71 = shufflevector <4 x float> %12, <4 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %72 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %70, <3 x float> %71, <3 x float> %48) #1
  %73 = insertelement <4 x float> %58, float -1.000000e+00, i64 1
  %74 = shufflevector <4 x float> %73, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %75 = shufflevector <4 x float> %16, <4 x float> undef, <3 x i32> zeroinitializer
  %76 = fsub fast <3 x float> splat (float -0.000000e+00), %48
  %77 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %74, <3 x float> %75, <3 x float> %76) #1
  %78 = shufflevector <2 x i1> %27, <2 x i1> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %79 = select fast <3 x i1> %78, <3 x float> %72, <3 x float> %77
  %80 = shufflevector <3 x float> %67, <3 x float> undef, <3 x i32> <i32 2, i32 0, i32 1>
  %81 = shufflevector <3 x float> %79, <3 x float> undef, <3 x i32> <i32 1, i32 2, i32 0>
  %82 = fsub fast <3 x float> splat (float -0.000000e+00), %67
  %83 = fmul fast <3 x float> %79, %82
  %84 = tail call fast <3 x float> @air.fma.v3f32(<3 x float> %80, <3 x float> %81, <3 x float> %83) #1
  %85 = tail call fast float @air.dot.v3f32(<3 x float> %84, <3 x float> %84) #1
  %86 = tail call fast float @air.fast_rsqrt.f32(float %85) #1
  %87 = insertelement <3 x float> undef, float %86, i64 0
  %88 = shufflevector <3 x float> %87, <3 x float> undef, <3 x i32> zeroinitializer
  %89 = fmul fast <3 x float> %88, %84
  %90 = shufflevector <4 x float> %3, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %91 = tail call fast float @air.dot.v2f32(<2 x float> %90, <2 x float> <float 0x3FB12E2860000000, float 0x3F77E8B200000000>) #1
  %92 = tail call fast float @air.fast_fract.f32(float %91) #1
  %93 = fmul fast float %92, 0x404A7DD040000000
  %94 = tail call fast float @air.fast_fract.f32(float %93) #1
  %95 = fmul fast float %94, 0x400921FB60000000
  %96 = fptrunc float %95 to half
  %97 = tail call fast half @air.cos.f16(half %96) #1
  %98 = insertelement <2 x half> undef, half %97, i64 0
  %99 = tail call fast half @air.sin.f16(half %96) #1
  %100 = insertelement <2 x half> %98, half %99, i64 1
  %101 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %100) #1
  %102 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 2
  %103 = load <4 x float>, ptr addrspace(2) %102, align 16, !alias.scope !27, !noalias !30
  %104 = shufflevector <4 x float> %103, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %105 = fmul fast <2 x float> %104, %101
  %106 = extractelement <4 x float> %3, i64 0
  %107 = extractelement <4 x float> %3, i64 1
  %108 = fsub fast float %107, %106
  %109 = fptrunc float %108 to half
  %110 = fmul fast half %109, 0xH3400
  %111 = tail call fast half @air.fract.f16(half %110) #1
  %112 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 5
  %113 = load <4 x half>, ptr addrspace(2) %112, align 16, !alias.scope !27, !noalias !30
  %114 = extractelement <4 x half> %113, i64 1
  %115 = fpext half %114 to float
  %116 = fdiv fast float %115, %20
  %117 = tail call fast float @air.fast_fmin.f32(float %116, float 1.250000e+01) #1
  %118 = fpext half %111 to float
  %119 = tail call fast float @air.fma.f32(float %118, float %117, float 2.000000e+00) #1
  %120 = fptrunc float %119 to half
  %121 = insertelement <4 x half> undef, half %120, i64 0
  %122 = insertelement <3 x float> undef, float %117, i64 0
  %123 = shufflevector <3 x float> %122, <3 x float> undef, <3 x i32> zeroinitializer
  %124 = shufflevector <2 x float> %105, <2 x float> undef, <3 x i32> <i32 0, i32 1, i32 0>
  %125 = fmul fast <3 x float> %123, %124
  %126 = tail call fast <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float> %125) #1
  %127 = shufflevector <3 x half> %126, <3 x half> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 2>
  %128 = shufflevector <4 x half> %121, <4 x half> undef, <2 x i32> zeroinitializer
  %129 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %128) #1
  %130 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %105, <2 x float> %129, <2 x float> %4) #1
  %131 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %130, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %132 = extractvalue { <4 x float>, i8 } %131, 0
  %133 = extractelement <4 x float> %132, i64 0
  %134 = fsub fast float -0.000000e+00, %133
  %135 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %134) #1
  %136 = extractelement <2 x float> %105, i64 1
  %137 = fsub fast float -0.000000e+00, %136
  %138 = fpext half %120 to float
  %139 = fmul fast float %137, %138
  %140 = fptrunc float %139 to half
  %141 = insertelement <2 x half> undef, half %140, i64 0
  %142 = extractelement <2 x float> %105, i64 0
  %143 = fmul fast float %142, %138
  %144 = fptrunc float %143 to half
  %145 = insertelement <2 x half> %141, half %144, i64 1
  %146 = fsub fast <2 x float> splat (float -0.000000e+00), %105
  %147 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %146, <2 x float> %129, <2 x float> %4) #1
  %148 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %145) #1
  %149 = fadd fast <2 x float> %148, %4
  %150 = shufflevector <2 x float> %130, <2 x float> %149, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %151 = fsub fast <2 x float> %4, %148
  %152 = shufflevector <2 x float> %147, <2 x float> %151, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %153 = shufflevector <4 x float> %33, <4 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %154 = shufflevector <4 x float> %33, <4 x float> undef, <4 x i32> <i32 2, i32 3, i32 2, i32 3>
  %155 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %150, <4 x float> %153, <4 x float> %154) #1
  %156 = shufflevector <4 x float> %155, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %157 = shufflevector <4 x float> %132, <4 x float> undef, <2 x i32> zeroinitializer
  %158 = shufflevector <4 x float> %50, <4 x float> undef, <2 x i32> <i32 3, i32 0>
  %159 = fsub fast <2 x float> splat (float -0.000000e+00), %158
  %160 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %156, <2 x float> %157, <2 x float> %159) #1
  %161 = shufflevector <2 x float> %160, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %162 = insertelement <4 x float> %161, float %135, i64 2
  %163 = shufflevector <4 x float> %162, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %164 = tail call fast float @air.dot.v3f32(<3 x float> %163, <3 x float> %89) #1
  %165 = insertelement <4 x float> undef, float %164, i64 0
  %166 = tail call fast float @air.dot.v3f32(<3 x float> %163, <3 x float> %163) #1
  %167 = insertelement <4 x float> undef, float %166, i64 0
  %168 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %149, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %169 = extractvalue { <4 x float>, i8 } %168, 0
  %170 = extractelement <4 x float> %169, i64 0
  %171 = fsub fast float -0.000000e+00, %170
  %172 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %171) #1
  %173 = shufflevector <4 x float> %155, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %174 = shufflevector <4 x float> %169, <4 x float> undef, <2 x i32> zeroinitializer
  %175 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %173, <2 x float> %174, <2 x float> %159) #1
  %176 = shufflevector <2 x float> %175, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %177 = insertelement <4 x float> %176, float %172, i64 2
  %178 = shufflevector <4 x float> %177, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %179 = tail call fast float @air.dot.v3f32(<3 x float> %178, <3 x float> %89) #1
  %180 = insertelement <4 x float> %165, float %179, i64 1
  %181 = tail call fast float @air.dot.v3f32(<3 x float> %178, <3 x float> %178) #1
  %182 = insertelement <4 x float> %167, float %181, i64 1
  %183 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %147, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %184 = extractvalue { <4 x float>, i8 } %183, 0
  %185 = extractelement <4 x float> %184, i64 0
  %186 = fsub fast float -0.000000e+00, %185
  %187 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %186) #1
  %188 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %152, <4 x float> %153, <4 x float> %154) #1
  %189 = shufflevector <4 x float> %188, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %190 = shufflevector <4 x float> %184, <4 x float> undef, <2 x i32> zeroinitializer
  %191 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %189, <2 x float> %190, <2 x float> %159) #1
  %192 = shufflevector <2 x float> %191, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %193 = insertelement <4 x float> %192, float %187, i64 2
  %194 = shufflevector <4 x float> %193, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %195 = tail call fast float @air.dot.v3f32(<3 x float> %194, <3 x float> %89) #1
  %196 = insertelement <4 x float> %180, float %195, i64 2
  %197 = tail call fast float @air.dot.v3f32(<3 x float> %194, <3 x float> %194) #1
  %198 = insertelement <4 x float> %182, float %197, i64 2
  %199 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %151, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %200 = extractvalue { <4 x float>, i8 } %199, 0
  %201 = extractelement <4 x float> %200, i64 0
  %202 = fsub fast float -0.000000e+00, %201
  %203 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %202) #1
  %204 = shufflevector <4 x float> %188, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %205 = shufflevector <4 x float> %200, <4 x float> undef, <2 x i32> zeroinitializer
  %206 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %204, <2 x float> %205, <2 x float> %159) #1
  %207 = shufflevector <2 x float> %206, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %208 = insertelement <4 x float> %207, float %203, i64 2
  %209 = shufflevector <4 x float> %208, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %210 = tail call fast float @air.dot.v3f32(<3 x float> %209, <3 x float> %89) #1
  %211 = insertelement <4 x float> %196, float %210, i64 3
  %212 = tail call fast float @air.dot.v3f32(<3 x float> %209, <3 x float> %209) #1
  %213 = insertelement <4 x float> %198, float %212, i64 3
  %214 = tail call fast <4 x float> @air.fast_rsqrt.v4f32(<4 x float> %213) #1
  %215 = shufflevector <4 x half> %113, <4 x half> undef, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %216 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %215) #1
  %217 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %213, <4 x float> %216, <4 x float> splat (float 1.000000e+00)) #1
  %218 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %217) #1
  %219 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %218, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %220 = shufflevector <4 x half> %113, <4 x half> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %221 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %220) #1
  %222 = fsub fast <4 x float> splat (float -0.000000e+00), %221
  %223 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %211, <4 x float> %214, <4 x float> %222) #1
  %224 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %223) #1
  %225 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %224, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %226 = fmul fast <4 x half> %225, %219
  %227 = tail call fast half @air.dot.v4f16(<4 x half> %226, <4 x half> splat (half 0xH3C00)) #1
  %228 = extractelement <3 x half> %126, i64 1
  %229 = fsub fast half 0xH8000, %228
  %230 = insertelement <4 x half> %127, half %229, i64 2
  %231 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %230) #1
  %232 = fadd fast <4 x float> %231, %150
  %233 = shufflevector <4 x float> %232, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %234 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %233, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %235 = extractvalue { <4 x float>, i8 } %234, 0
  %236 = extractelement <4 x float> %235, i64 0
  %237 = fsub fast float -0.000000e+00, %236
  %238 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %237) #1
  %239 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %232, <4 x float> %153, <4 x float> %154) #1
  %240 = shufflevector <4 x float> %239, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %241 = shufflevector <4 x float> %235, <4 x float> undef, <2 x i32> zeroinitializer
  %242 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %240, <2 x float> %241, <2 x float> %159) #1
  %243 = shufflevector <2 x float> %242, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %244 = insertelement <4 x float> %243, float %238, i64 2
  %245 = shufflevector <4 x float> %244, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %246 = tail call fast float @air.dot.v3f32(<3 x float> %245, <3 x float> %245) #1
  %247 = insertelement <4 x float> undef, float %246, i64 0
  %248 = tail call fast float @air.dot.v3f32(<3 x float> %245, <3 x float> %89) #1
  %249 = insertelement <4 x float> undef, float %248, i64 0
  %250 = shufflevector <4 x float> %232, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %251 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %250, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %252 = extractvalue { <4 x float>, i8 } %251, 0
  %253 = extractelement <4 x float> %252, i64 0
  %254 = fadd fast <4 x float> %232, %231
  %255 = fsub fast float -0.000000e+00, %253
  %256 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %255) #1
  %257 = shufflevector <4 x float> %239, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %258 = shufflevector <4 x float> %252, <4 x float> undef, <2 x i32> zeroinitializer
  %259 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %257, <2 x float> %258, <2 x float> %159) #1
  %260 = shufflevector <2 x float> %259, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %261 = insertelement <4 x float> %260, float %256, i64 2
  %262 = shufflevector <4 x float> %261, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %263 = tail call fast float @air.dot.v3f32(<3 x float> %262, <3 x float> %262) #1
  %264 = insertelement <4 x float> %247, float %263, i64 1
  %265 = tail call fast float @air.dot.v3f32(<3 x float> %262, <3 x float> %89) #1
  %266 = insertelement <4 x float> %249, float %265, i64 1
  %267 = shufflevector <4 x half> %230, <4 x half> undef, <4 x i32> <i32 3, i32 1, i32 2, i32 3>
  %268 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %267) #1
  %269 = fsub fast <4 x float> %152, %268
  %270 = fsub fast <4 x float> %269, %268
  %271 = shufflevector <4 x float> %269, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %272 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %271, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %273 = extractvalue { <4 x float>, i8 } %272, 0
  %274 = extractelement <4 x float> %273, i64 0
  %275 = fsub fast float -0.000000e+00, %274
  %276 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %275) #1
  %277 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %269, <4 x float> %153, <4 x float> %154) #1
  %278 = shufflevector <4 x float> %269, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %279 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %278, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %280 = extractvalue { <4 x float>, i8 } %279, 0
  %281 = extractelement <4 x float> %280, i64 0
  %282 = shufflevector <4 x float> %277, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %283 = shufflevector <4 x float> %273, <4 x float> undef, <2 x i32> zeroinitializer
  %284 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %282, <2 x float> %283, <2 x float> %159) #1
  %285 = shufflevector <2 x float> %284, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %286 = insertelement <4 x float> %285, float %276, i64 2
  %287 = shufflevector <4 x float> %277, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %288 = shufflevector <4 x float> %280, <4 x float> undef, <2 x i32> zeroinitializer
  %289 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %287, <2 x float> %288, <2 x float> %159) #1
  %290 = shufflevector <2 x float> %289, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %291 = fsub fast float -0.000000e+00, %281
  %292 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %291) #1
  %293 = insertelement <4 x float> %290, float %292, i64 2
  %294 = shufflevector <4 x float> %286, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %295 = tail call fast float @air.dot.v3f32(<3 x float> %294, <3 x float> %294) #1
  %296 = insertelement <4 x float> %264, float %295, i64 2
  %297 = tail call fast float @air.dot.v3f32(<3 x float> %294, <3 x float> %89) #1
  %298 = insertelement <4 x float> %266, float %297, i64 2
  %299 = shufflevector <4 x float> %293, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %300 = tail call fast float @air.dot.v3f32(<3 x float> %299, <3 x float> %299) #1
  %301 = insertelement <4 x float> %296, float %300, i64 3
  %302 = tail call fast float @air.dot.v3f32(<3 x float> %299, <3 x float> %89) #1
  %303 = insertelement <4 x float> %298, float %302, i64 3
  %304 = tail call fast <4 x float> @air.fast_rsqrt.v4f32(<4 x float> %301) #1
  %305 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %301, <4 x float> %216, <4 x float> splat (float 1.000000e+00)) #1
  %306 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %305) #1
  %307 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %306, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %308 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %303, <4 x float> %304, <4 x float> %222) #1
  %309 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %308) #1
  %310 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %309, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %311 = fmul fast <4 x half> %310, %307
  %312 = tail call fast half @air.dot.v4f16(<4 x half> %311, <4 x half> splat (half 0xH3C00)) #1
  %313 = fadd fast half %312, %227
  %314 = shufflevector <4 x float> %254, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %315 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %314, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %316 = extractvalue { <4 x float>, i8 } %315, 0
  %317 = extractelement <4 x float> %316, i64 0
  %318 = fsub fast float -0.000000e+00, %317
  %319 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %318) #1
  %320 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %254, <4 x float> %153, <4 x float> %154) #1
  %321 = shufflevector <4 x float> %254, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %322 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %321, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %323 = extractvalue { <4 x float>, i8 } %322, 0
  %324 = extractelement <4 x float> %323, i64 0
  %325 = shufflevector <4 x float> %320, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %326 = shufflevector <4 x float> %316, <4 x float> undef, <2 x i32> zeroinitializer
  %327 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %325, <2 x float> %326, <2 x float> %159) #1
  %328 = shufflevector <2 x float> %327, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %329 = insertelement <4 x float> %328, float %319, i64 2
  %330 = shufflevector <4 x float> %320, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %331 = shufflevector <4 x float> %323, <4 x float> undef, <2 x i32> zeroinitializer
  %332 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %330, <2 x float> %331, <2 x float> %159) #1
  %333 = shufflevector <2 x float> %332, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %334 = fsub fast float -0.000000e+00, %324
  %335 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %334) #1
  %336 = insertelement <4 x float> %333, float %335, i64 2
  %337 = shufflevector <4 x float> %329, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %338 = tail call fast float @air.dot.v3f32(<3 x float> %337, <3 x float> %337) #1
  %339 = insertelement <4 x float> undef, float %338, i64 0
  %340 = tail call fast float @air.dot.v3f32(<3 x float> %337, <3 x float> %89) #1
  %341 = insertelement <4 x float> undef, float %340, i64 0
  %342 = shufflevector <4 x float> %336, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %343 = tail call fast float @air.dot.v3f32(<3 x float> %342, <3 x float> %342) #1
  %344 = insertelement <4 x float> %339, float %343, i64 1
  %345 = tail call fast float @air.dot.v3f32(<3 x float> %342, <3 x float> %89) #1
  %346 = insertelement <4 x float> %341, float %345, i64 1
  %347 = shufflevector <4 x float> %270, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %348 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %347, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %349 = extractvalue { <4 x float>, i8 } %348, 0
  %350 = extractelement <4 x float> %349, i64 0
  %351 = fsub fast float -0.000000e+00, %350
  %352 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %351) #1
  %353 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %270, <4 x float> %153, <4 x float> %154) #1
  %354 = shufflevector <4 x float> %270, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %355 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %1, <2 x float> %354, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2, !alias.scope !30, !noalias !27
  %356 = extractvalue { <4 x float>, i8 } %355, 0
  %357 = extractelement <4 x float> %356, i64 0
  %358 = shufflevector <4 x float> %353, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %359 = shufflevector <4 x float> %349, <4 x float> undef, <2 x i32> zeroinitializer
  %360 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %358, <2 x float> %359, <2 x float> %159) #1
  %361 = shufflevector <2 x float> %360, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %362 = insertelement <4 x float> %361, float %352, i64 2
  %363 = shufflevector <4 x float> %353, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %364 = shufflevector <4 x float> %356, <4 x float> undef, <2 x i32> zeroinitializer
  %365 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %363, <2 x float> %364, <2 x float> %159) #1
  %366 = shufflevector <2 x float> %365, <2 x float> undef, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %367 = fsub fast float -0.000000e+00, %357
  %368 = tail call fast float @air.fma.f32(float 1.000000e+00, float %20, float %367) #1
  %369 = insertelement <4 x float> %366, float %368, i64 2
  %370 = fptrunc float %20 to half
  %371 = insertelement <4 x half> undef, half %370, i64 1
  %372 = shufflevector <4 x float> %362, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %373 = tail call fast float @air.dot.v3f32(<3 x float> %372, <3 x float> %372) #1
  %374 = insertelement <4 x float> %344, float %373, i64 2
  %375 = tail call fast float @air.dot.v3f32(<3 x float> %372, <3 x float> %89) #1
  %376 = insertelement <4 x float> %346, float %375, i64 2
  %377 = shufflevector <4 x float> %369, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %378 = tail call fast float @air.dot.v3f32(<3 x float> %377, <3 x float> %89) #1
  %379 = insertelement <4 x float> %376, float %378, i64 3
  %380 = tail call fast float @air.dot.v3f32(<3 x float> %377, <3 x float> %377) #1
  %381 = insertelement <4 x float> %374, float %380, i64 3
  %382 = tail call fast <4 x float> @air.fast_rsqrt.v4f32(<4 x float> %381) #1
  %383 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %381, <4 x float> %216, <4 x float> splat (float 1.000000e+00)) #1
  %384 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %383) #1
  %385 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %384, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %386 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %379, <4 x float> %382, <4 x float> %222) #1
  %387 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %386) #1
  %388 = tail call fast <4 x half> @air.clamp.v4f16(<4 x half> %387, <4 x half> zeroinitializer, <4 x half> splat (half 0xH3C00)) #1
  %389 = fmul fast <4 x half> %388, %385
  %390 = tail call fast half @air.dot.v4f16(<4 x half> %389, <4 x half> splat (half 0xH3C00)) #1
  %391 = fadd fast half %313, %390
  %392 = fsub fast half 0xH8000, %391
  %393 = getelementptr inbounds %struct.cb_SSAO_Type, ptr addrspace(2) %0, i64 0, i32 6
  %394 = load <4 x half>, ptr addrspace(2) %393, align 8, !alias.scope !27, !noalias !30
  %395 = extractelement <4 x half> %394, i64 1
  %396 = tail call fast half @air.fma.f16(half %392, half %395, half 0xH3C00) #1
  %397 = tail call fast half @air.clamp.f16(half %396, half 0xH0000, half 0xH3C00) #1
  %398 = insertelement <4 x half> %371, half %397, i64 0
  %399 = shufflevector <4 x half> %398, <4 x half> <half 0xH0000, half 0xH0000, half undef, half undef>, <4 x i32> <i32 0, i32 1, i32 4, i32 5>
  %400 = insertvalue <{ <4 x half> }> undef, <4 x half> %399, 0
  ret <{ <4 x half> }> %400
}

; Function Attrs: nounwind memory(none)
declare half @air.clamp.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fma.f16(half, half, half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.dot.v4f16(<4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.clamp.v4f16(<4 x half>, <4 x half>, <4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fast_rsqrt.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fma.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x half> @air.convert.f.v3f16.f.v3f32(<3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.fract.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.sin.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare half @air.cos.f16(half) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_fract.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <3 x float> @air.fma.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_fabs.v2f32(<2 x float>) local_unnamed_addr #1

; Function Attrs: nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i32, i32) local_unnamed_addr #3

attributes #0 = { convergent nounwind optsize memory(read) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(none) }
attributes #2 = { convergent nounwind memory(argmem: read) }
attributes #3 = { nounwind memory(argmem: read) }

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
!17 = !{!18, !20, !21, !22, !23}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 144, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 144, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"cb_SSAO_Type", !"air.arg_name", !"cb_SSAO"}
!19 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_SSAO_ViewMatrix", i32 64, i32 16, i32 0, !"float4", !"_UVToView", i32 80, i32 16, i32 0, !"float4", !"_SSAO_ResolutionParams", i32 96, i32 16, i32 0, !"float4", !"_ReconstructNormal_UVOffset", i32 112, i32 16, i32 0, !"float4", !"_ReconstructNormal_GatherOffset", i32 128, i32 8, i32 0, !"half4", !"_SSAO_SampleParams", i32 136, i32 8, i32 0, !"half4", !"_SSAO_IntensityParams"}
!20 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_QuarterLinearDepthTexture"}
!21 = !{i32 2, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_QuarterLinearDepthTexture"}
!22 = !{i32 3, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"mtl_FragCoord"}
!23 = !{i32 4, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!24 = !{!25, !25, i64 0}
!25 = !{!"omnipotent char", !26, i64 0}
!26 = !{!"Simple C++ TBAA"}
!27 = !{!28}
!28 = distinct !{!28, !29, !"air-alias-scope-arg(0)"}
!29 = distinct !{!29, !"air-alias-scopes(xlatMtlMain)"}
!30 = !{!31, !32}
!31 = distinct !{!31, !29, !"air-alias-scope-samplers"}
!32 = distinct !{!32, !29, !"air-alias-scope-textures"}
