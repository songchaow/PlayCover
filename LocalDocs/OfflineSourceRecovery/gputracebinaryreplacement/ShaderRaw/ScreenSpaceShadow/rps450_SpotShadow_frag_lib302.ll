; ModuleID = '/tmp/lysk-verify/shadow/library_302.module.bc'
source_filename = "xlatMtlMain"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v24-apple-ios15.0.0"

%struct.UnityPerCamera_Type = type { <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <3 x float>, float, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float>, float, <4 x float>, <4 x float>, <4 x float>, i32, [12 x i8] }
%struct.UnityPerPass_Type = type { [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], [4 x <4 x float>], <4 x float>, <4 x half>, <4 x half>, [6 x <4 x half>] }
%struct._LocalLightShadowBuffer_Type = type { [12 x <4 x float>], <4 x half>, [4 x <4 x float>], <4 x float>, <4 x float> }

; Function Attrs: convergent nounwind optsize
define <{ <4 x float> }> @xlatMtlMain(ptr addrspace(2) readonly captures(none) dereferenceable(320) "air-buffer-no-alias" %0, ptr addrspace(2) readonly captures(none) dereferenceable(592) "air-buffer-no-alias" %1, ptr addrspace(2) readonly captures(none) dereferenceable(304) "air-buffer-no-alias" %2, ptr addrspace(2) readonly captures(none) %3, ptr addrspace(2) readonly captures(none) %4, ptr addrspace(1) %5, ptr addrspace(1) %6, <4 x float> %7) local_unnamed_addr #0 {
  %9 = extractelement <4 x float> %7, i64 1
  %10 = getelementptr inbounds %struct.UnityPerCamera_Type, ptr addrspace(2) %0, i64 0, i32 10
  %11 = load <4 x float>, ptr addrspace(2) %10, align 16, !alias.scope !29, !noalias !32
  %12 = extractelement <4 x float> %11, i64 0
  %13 = fmul fast float %12, %9
  %14 = insertelement <4 x float> %7, float %13, i64 1
  %15 = shufflevector <4 x float> %14, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %16 = shufflevector <4 x float> %7, <4 x float> undef, <2 x i32> <i32 3, i32 3>
  %17 = fdiv fast <2 x float> %15, %16
  %18 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %17, <2 x float> splat (float 5.000000e-01), <2 x float> splat (float 5.000000e-01)) #2
  %19 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 10
  %20 = load <4 x half>, ptr addrspace(2) %19, align 8, !alias.scope !37, !noalias !38
  %21 = shufflevector <4 x half> %20, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %22 = tail call fast <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half> %21) #2
  %23 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %4, <2 x float> %18, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #5, !alias.scope !39, !noalias !40
  %24 = fmul fast <2 x float> %18, splat (float 0x3F40000000000000)
  %25 = fmul fast <2 x float> %24, %22
  %26 = fcmp fast oge <2 x float> %25, zeroinitializer
  %27 = tail call fast <2 x float> @air.fast_fabs.v2f32(<2 x float> %25) #2
  %28 = tail call fast fastcc <2 x float> @___metal_fract_v2float(<2 x float> %27, i32 0) #6
  %29 = extractelement <2 x i1> %26, i64 0
  %30 = extractelement <2 x float> %28, i64 0
  %31 = fsub fast float -0.000000e+00, %30
  %32 = select fast i1 %29, float %30, float %31
  %33 = extractelement <2 x i1> %26, i64 1
  %34 = extractelement <2 x float> %28, i64 1
  %35 = fsub fast float -0.000000e+00, %34
  %36 = select fast i1 %33, float %34, float %35
  %37 = insertelement <2 x float> undef, float %32, i64 0
  %38 = extractvalue { <4 x float>, i8 } %23, 0
  %39 = insertelement <2 x float> %37, float %36, i64 1
  %40 = tail call fast <2 x float> @air.fma.v2f32(<2 x float> %39, <2 x float> splat (float 0x3FDE573AC0000000), <2 x float> <float 2.500000e-01, float 0.000000e+00>) #2
  %41 = fmul fast <2 x float> %40, %40
  %42 = tail call fast float @air.dot.v2f32(<2 x float> %41, <2 x float> splat (float 3.571000e+03)) #2
  %43 = tail call fast float @air.fast_fract.f32(float %42) #2
  %44 = fmul fast float %43, %43
  %45 = insertelement <2 x float> undef, float %44, i64 0
  %46 = shufflevector <2 x float> %45, <2 x float> undef, <2 x i32> zeroinitializer
  %47 = tail call fast float @air.dot.v2f32(<2 x float> %46, <2 x float> splat (float 3.571000e+03)) #2
  %48 = tail call fast float @air.fast_fract.f32(float %47) #2
  %49 = fadd fast float %48, -5.000000e-01
  %50 = tail call fast float @air.fast_fract.f32(float %49) #2
  %51 = fptrunc float %50 to half
  %52 = fmul fast half %51, 0xH4648
  %53 = fpext half %52 to float
  %54 = tail call fast float @air.fast_sin.f32(float %53) #2
  %55 = insertelement <4 x float> undef, float %54, i64 0
  %56 = tail call fast float @air.fast_cos.f32(float %53) #2
  %57 = insertelement <4 x float> undef, float %56, i64 0
  %58 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 3
  %59 = load <4 x float>, ptr addrspace(2) %58, align 16, !alias.scope !41, !noalias !42
  %60 = extractelement <4 x float> %59, i64 3
  %61 = extractelement <4 x float> %59, i64 2
  %62 = fdiv fast float %60, %61
  %63 = insertelement <2 x float> undef, float %62, i64 0
  %64 = shufflevector <2 x float> %63, <2 x float> undef, <2 x i32> zeroinitializer
  %65 = fmul fast <2 x float> %64, <float 0xBF600E6B00000000, float 0x3F600E6B00000000>
  %66 = shufflevector <4 x float> %57, <4 x float> undef, <2 x i32> zeroinitializer
  %67 = fmul fast <2 x float> %65, %66
  %68 = shufflevector <4 x float> %55, <4 x float> undef, <2 x i32> zeroinitializer
  %69 = fmul fast <2 x float> %65, %68
  %70 = shufflevector <4 x float> %7, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %71 = fdiv fast <2 x float> %70, %16
  %72 = shufflevector <2 x float> %71, <2 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %73 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 1
  %74 = load <4 x float>, ptr addrspace(2) %73, align 16, !tbaa !43, !alias.scope !37, !noalias !38
  %75 = fmul fast <4 x float> %74, %72
  %76 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 0
  %77 = load <4 x float>, ptr addrspace(2) %76, align 16, !tbaa !43, !alias.scope !37, !noalias !38
  %78 = shufflevector <2 x float> %71, <2 x float> undef, <4 x i32> zeroinitializer
  %79 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %77, <4 x float> %78, <4 x float> %75) #2
  %80 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 2
  %81 = load <4 x float>, ptr addrspace(2) %80, align 16, !tbaa !43, !alias.scope !37, !noalias !38
  %82 = shufflevector <4 x float> %38, <4 x float> undef, <4 x i32> zeroinitializer
  %83 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %81, <4 x float> %82, <4 x float> %79) #2
  %84 = getelementptr inbounds %struct.UnityPerPass_Type, ptr addrspace(2) %1, i64 0, i32 5, i64 3
  %85 = load <4 x float>, ptr addrspace(2) %84, align 16, !tbaa !43, !alias.scope !37, !noalias !38
  %86 = fadd fast <4 x float> %85, %83
  %87 = extractelement <4 x float> %86, i64 3
  %88 = fdiv fast float 1.000000e+00, %87
  %89 = insertelement <3 x float> undef, float %88, i64 0
  %90 = shufflevector <3 x float> %89, <3 x float> undef, <3 x i32> zeroinitializer
  %91 = shufflevector <4 x float> %86, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %92 = fmul fast <3 x float> %90, %91
  %93 = shufflevector <3 x float> %92, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %94 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 0, i64 1
  %95 = load <4 x float>, ptr addrspace(2) %94, align 16, !tbaa !43, !alias.scope !41, !noalias !42
  %96 = fmul fast <4 x float> %93, %95
  %97 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 0, i64 0
  %98 = load <4 x float>, ptr addrspace(2) %97, align 16, !tbaa !43, !alias.scope !41, !noalias !42
  %99 = shufflevector <3 x float> %92, <3 x float> undef, <4 x i32> zeroinitializer
  %100 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %98, <4 x float> %99, <4 x float> %96) #2
  %101 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 0, i64 2
  %102 = load <4 x float>, ptr addrspace(2) %101, align 16, !tbaa !43, !alias.scope !41, !noalias !42
  %103 = shufflevector <3 x float> %92, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %104 = tail call fast <4 x float> @air.fma.v4f32(<4 x float> %102, <4 x float> %103, <4 x float> %100) #2
  %105 = getelementptr inbounds %struct._LocalLightShadowBuffer_Type, ptr addrspace(2) %2, i64 0, i32 0, i64 3
  %106 = load <4 x float>, ptr addrspace(2) %105, align 16, !tbaa !43, !alias.scope !41, !noalias !42
  %107 = fadd fast <4 x float> %106, %104
  %108 = shufflevector <4 x float> %107, <4 x float> undef, <3 x i32> <i32 0, i32 1, i32 2>
  %109 = shufflevector <4 x float> %107, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %110 = fdiv fast <3 x float> %108, %109
  %111 = shufflevector <2 x float> %67, <2 x float> %69, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  %112 = shufflevector <3 x float> %110, <3 x float> undef, <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %113 = fadd fast <4 x float> %112, %111
  %114 = shufflevector <4 x float> %113, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %115 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %3, <2 x float> %114, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #1, !alias.scope !39, !noalias !40
  %116 = extractvalue { <4 x float>, i8 } %115, 0
  %117 = shufflevector <4 x float> %113, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %118 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %3, <2 x float> %117, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #1, !alias.scope !39, !noalias !40
  %119 = extractvalue { <4 x float>, i8 } %118, 0
  %120 = shufflevector <3 x float> %110, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %121 = fcmp fast oge <4 x float> %120, %119
  %122 = select reassoc nsz arcp contract afn <4 x i1> %121, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %123 = fcmp fast oge <4 x float> %120, %116
  %124 = select reassoc nsz arcp contract afn <4 x i1> %123, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %125 = extractelement <4 x float> %124, i64 1
  %126 = extractelement <4 x float> %124, i64 0
  %127 = extractelement <4 x float> %124, i64 2
  %128 = extractelement <4 x float> %124, i64 3
  %129 = fmul fast <2 x float> %68, <float 0xBF600E6B00000000, float 0x3F600E6B00000000>
  %130 = fmul fast <2 x float> %66, <float 0x3F600E6B00000000, float 0xBF600E6B00000000>
  %131 = shufflevector <2 x float> %129, <2 x float> %130, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  %132 = fadd fast <4 x float> %112, %131
  %133 = shufflevector <4 x float> %132, <4 x float> undef, <2 x i32> <i32 0, i32 1>
  %134 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %3, <2 x float> %133, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #1, !alias.scope !39, !noalias !40
  %135 = extractvalue { <4 x float>, i8 } %134, 0
  %136 = shufflevector <4 x float> %132, <4 x float> undef, <2 x i32> <i32 2, i32 3>
  %137 = tail call { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %3, <2 x float> %136, i1 true, <2 x i32> zeroinitializer, i32 0, i32 0) #1, !alias.scope !39, !noalias !40
  %138 = extractvalue { <4 x float>, i8 } %137, 0
  %139 = fcmp fast oge <4 x float> %120, %138
  %140 = fcmp fast oge <4 x float> %120, %135
  %141 = select reassoc nsz arcp contract afn <4 x i1> %140, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %142 = select reassoc nsz arcp contract afn <4 x i1> %139, <4 x float> splat (float 1.000000e+00), <4 x float> zeroinitializer
  %143 = extractelement <4 x float> %141, i64 1
  %144 = extractelement <4 x float> %141, i64 0
  %145 = extractelement <4 x float> %141, i64 2
  %146 = extractelement <4 x float> %141, i64 3
  %147 = extractelement <4 x float> %142, i64 1
  %148 = extractelement <4 x float> %142, i64 0
  %149 = extractelement <4 x float> %142, i64 2
  %150 = extractelement <4 x float> %142, i64 3
  %151 = extractelement <4 x float> %122, i64 1
  %152 = extractelement <4 x float> %122, i64 0
  %153 = extractelement <4 x float> %122, i64 2
  %154 = extractelement <4 x float> %122, i64 3
  %155 = fadd fast float %151, %152
  %156 = fadd fast float %155, %153
  %157 = fadd fast float %156, %154
  %158 = fadd fast float %157, %144
  %159 = fadd fast float %158, %143
  %160 = fadd fast float %159, %145
  %161 = fadd fast float %160, %146
  %162 = fadd fast float %161, %126
  %163 = fadd fast float %162, %125
  %164 = fadd fast float %163, %127
  %165 = fadd fast float %164, %128
  %166 = fadd fast float %165, %148
  %167 = fadd fast float %166, %147
  %168 = fadd fast float %167, %149
  %169 = fadd fast float %168, %150
  %170 = fmul fast float %169, 6.250000e-02
  %171 = insertelement <4 x float> undef, float %170, i64 1
  %172 = shufflevector <4 x float> %171, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float undef>, <4 x i32> <i32 4, i32 1, i32 5, i32 6>
  %173 = insertvalue <{ <4 x float> }> undef, <4 x float> %172, 0
  ret <{ <4 x float> }> %173
}

; Function Attrs: nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.gather_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i32, i32) local_unnamed_addr #1

; Function Attrs: nounwind memory(none)
declare <4 x float> @air.fma.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.fast_cos.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.fast_sin.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.fast_fract.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fma.v2f32(<2 x float>, <2 x float>, <2 x float>) local_unnamed_addr #2

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
  %3 = tail call float @air.fmin.f32(float %0, float %1) #2
  ret float %3
}

; Function Attrs: nounwind memory(none)
declare float @air.fmin.f32(float, float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z13_target_floorf(float %0) unnamed_addr #4 {
  %2 = tail call float @air.floor.f32(float %0) #2
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare float @air.floor.f32(float) local_unnamed_addr #2

; Function Attrs: nounwind memory(none)
define internal fastcc float @_Z18_target_fast_fractf(float %0) unnamed_addr #4 {
  %2 = tail call float @air.fast_fract.f32(float %0) #2
  ret float %2
}

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.fast_fabs.v2f32(<2 x float>) local_unnamed_addr #2

; Function Attrs: convergent nounwind memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #5

; Function Attrs: nounwind memory(none)
declare <2 x float> @air.convert.f.v2f32.f.v2f16(<2 x half>) local_unnamed_addr #2

attributes #0 = { convergent nounwind optsize "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { nounwind memory(argmem: read) }
attributes #2 = { nounwind memory(none) }
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
!16 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"SV_Target0"}
!17 = !{!18, !20, !22, !24, !25, !26, !27, !28}
!18 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 320, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !19, !"air.arg_type_size", i32 320, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerCamera_Type", !"air.arg_name", !"UnityPerCamera"}
!19 = !{i32 0, i32 16, i32 0, !"float4", !"_Time", i32 16, i32 16, i32 0, !"float4", !"_SinTime", i32 32, i32 16, i32 0, !"float4", !"_CosTime", i32 48, i32 16, i32 0, !"float4", !"_TimeParameters", i32 64, i32 16, i32 0, !"float4", !"unity_DeltaTime", i32 80, i32 16, i32 0, !"float3", !"_WorldSpaceRelativeCameraPos", i32 96, i32 4, i32 0, !"float", !"_EyeAdaptionExposure", i32 112, i32 16, i32 0, !"float3", !"_WorldSpaceCameraPos", i32 128, i32 4, i32 0, !"float", !"_EyeAdaptionInverseExposure", i32 144, i32 16, i32 0, !"float3", !"_WorldSpaceCameraDir", i32 160, i32 16, i32 0, !"float4", !"_ProjectionParams", i32 176, i32 16, i32 0, !"float4", !"_ScreenParams", i32 192, i32 16, i32 0, !"float4", !"_ZBufferParams", i32 208, i32 16, i32 0, !"float4", !"unity_OrthoParams", i32 224, i32 16, i32 0, !"float3", !"_PrevCameraPos", i32 240, i32 4, i32 0, !"float", !"_ReflectNormalBias", i32 256, i32 16, i32 0, !"float4", !"_PrevTime", i32 272, i32 16, i32 0, !"float4", !"_SRPTime", i32 288, i32 16, i32 0, !"float4", !"_PaperUnscaledTime", i32 304, i32 4, i32 0, !"uint", !"_FrameCount8"}
!20 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 592, !"air.location_index", i32 1, i32 1, !"air.read", !"air.struct_type_info", !21, !"air.arg_type_size", i32 592, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"UnityPerPass_Type", !"air.arg_name", !"UnityPerPass"}
!21 = !{i32 0, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_PrevViewProjMatrix", i32 64, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewProjMatrix", i32 128, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_NonJitteredViewProjMatrix", i32 192, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ViewMatrix", i32 256, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_ProjMatrix", i32 320, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewProjMatrix", i32 384, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvViewMatrix", i32 448, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_InvProjMatrix", i32 512, i32 16, i32 0, !"float4", !"_InvProjParam", i32 528, i32 8, i32 0, !"half4", !"_ScreenSize", i32 536, i32 8, i32 0, !"half4", !"_HDRSize", i32 544, i32 8, i32 6, !"half4", !"_FrustumPlanes"}
!22 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 304, !"air.location_index", i32 2, i32 1, !"air.read", !"air.struct_type_info", !23, !"air.arg_type_size", i32 304, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"_LocalLightShadowBuffer_Type", !"air.arg_name", !"_LocalLightShadowBuffer"}
!23 = !{i32 0, i32 16, i32 12, !"float4", !"hlslcc_mtx4x4_LocalLightWorldToShadow", i32 192, i32 8, i32 0, !"half4", !"_LocalShadowStrength", i32 208, i32 16, i32 4, !"float4", !"hlslcc_mtx4x4_CloseUpWorldToShadow", i32 272, i32 16, i32 0, !"float4", !"_LocalLightShadowmapSize", i32 288, i32 16, i32 0, !"float4", !"_LocalLightCloseUpShadowSliceTransform"}
!24 = !{i32 3, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_LocalShadowMapAtlas"}
!25 = !{i32 4, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"sampler_CameraDepthTexture"}
!26 = !{i32 5, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_LocalShadowMapAtlas"}
!27 = !{i32 6, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_CameraDepthTexture"}
!28 = !{i32 7, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"TEXCOORD0"}
!29 = !{!30}
!30 = distinct !{!30, !31, !"air-alias-scope-arg(0)"}
!31 = distinct !{!31, !"air-alias-scopes(xlatMtlMain)"}
!32 = !{!33, !34, !35, !36}
!33 = distinct !{!33, !31, !"air-alias-scope-arg(1)"}
!34 = distinct !{!34, !31, !"air-alias-scope-arg(2)"}
!35 = distinct !{!35, !31, !"air-alias-scope-samplers"}
!36 = distinct !{!36, !31, !"air-alias-scope-textures"}
!37 = !{!33}
!38 = !{!30, !34, !35, !36}
!39 = !{!35, !36}
!40 = !{!30, !33, !34}
!41 = !{!34}
!42 = !{!30, !33, !35, !36}
!43 = !{!44, !44, i64 0}
!44 = !{!"omnipotent char", !45, i64 0}
!45 = !{!"Simple C++ TBAA"}
