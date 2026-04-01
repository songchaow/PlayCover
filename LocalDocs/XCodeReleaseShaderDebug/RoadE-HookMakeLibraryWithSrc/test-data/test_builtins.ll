; ModuleID = 'test_builtins.air'
source_filename = "test_builtins.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

%"struct.metal::_atomic" = type { i32 }
%"struct.metal::_atomic.25" = type { i32 }

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_texture_ops(ptr addrspace(1) %0, ptr addrspace(1) %1, ptr addrspace(1) %2, ptr addrspace(1) %3, ptr addrspace(1) %4, ptr addrspace(1) %5, ptr addrspace(1) %6, ptr addrspace(1) %7, ptr addrspace(2) readonly captures(none) %8, <2 x i32> %9) local_unnamed_addr #0 {
  %11 = tail call fast <2 x float> @air.convert.f.v2f32.u.v2i32(<2 x i32> %9) #12
  %12 = fmul fast <2 x float> %11, splat (float 0x3F60000000000000)
  %13 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %14 = extractvalue { <4 x float>, i8 } %13, 0
  %15 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, i1 true, <2 x i32> zeroinitializer, i1 true, float 2.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %16 = extractvalue { <4 x float>, i8 } %15, 0
  %17 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, i1 true, <2 x i32> zeroinitializer, i1 false, float 1.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %18 = extractvalue { <4 x float>, i8 } %17, 0
  %19 = tail call { <4 x float>, i8 } @air.sample_texture_2d_grad.v4f32(ptr addrspace(1) readonly captures(none) %2, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, <2 x float> splat (float 0x3FB99999A0000000), <2 x float> splat (float 0x3FB99999A0000000), float 0.000000e+00, i1 true, <2 x i32> zeroinitializer, i32 0) #14, !alias.scope !70
  %20 = extractvalue { <4 x float>, i8 } %19, 0
  %21 = tail call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none) %3, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %22 = extractvalue { <4 x half>, i8 } %21, 0
  %23 = shufflevector <2 x float> %12, <2 x float> poison, <3 x i32> <i32 0, i32 1, i32 poison>
  %24 = insertelement <3 x float> %23, float 5.000000e-01, i64 2
  %25 = tail call { <4 x float>, i8 } @air.sample_texture_3d.v4f32(ptr addrspace(1) readonly captures(none) %4, ptr addrspace(2) readonly captures(none) %8, <3 x float> %24, i1 true, <3 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %26 = extractvalue { <4 x float>, i8 } %25, 0
  %27 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none) %5, ptr addrspace(2) readonly captures(none) %8, <3 x float> <float 0.000000e+00, float 1.000000e+00, float 0.000000e+00>, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %28 = extractvalue { <4 x float>, i8 } %27, 0
  %29 = tail call { <4 x float>, i8 } @air.sample_texture_2d_array.v4f32(ptr addrspace(1) readonly captures(none) %6, ptr addrspace(2) readonly captures(none) %8, <2 x float> %12, i32 0, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %30 = extractvalue { <4 x float>, i8 } %29, 0
  %31 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none) %7, ptr addrspace(2) readonly captures(none) %8, i32 1, <2 x float> %12, float 5.000000e-01, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #13, !alias.scope !70
  %32 = extractvalue { float, i8 } %31, 0
  %33 = tail call { <4 x float>, i8 } @air.read_texture_2d.v4f32(ptr addrspace(1) readonly captures(none) %0, <2 x i32> %9, i32 0, i32 1) #14, !alias.scope !74, !noalias !75
  %34 = extractvalue { <4 x float>, i8 } %33, 0
  %35 = fadd fast <4 x float> %16, %14
  %36 = fadd fast <4 x float> %35, %18
  %37 = fadd fast <4 x float> %36, %20
  %38 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %22) #12
  %39 = insertelement <4 x float> poison, float %32, i64 0
  %40 = shufflevector <4 x float> %39, <4 x float> poison, <4 x i32> zeroinitializer
  %41 = fadd fast <4 x float> %37, %26
  %42 = fadd fast <4 x float> %41, %28
  %43 = fadd fast <4 x float> %42, %30
  %44 = fadd fast <4 x float> %43, %38
  %45 = fadd fast <4 x float> %44, %34
  %46 = fadd fast <4 x float> %45, %40
  tail call void @air.write_texture_2d.v4f32(ptr addrspace(1) captures(none) %1, <2 x i32> %9, <4 x float> %46, i32 0, i32 2) #15, !alias.scope !74, !noalias !75
  %47 = tail call i32 @air.get_width_texture_2d(ptr addrspace(1) readonly captures(none) %0, i32 0) #14, !alias.scope !74, !noalias !75
  %48 = tail call i32 @air.get_height_texture_2d(ptr addrspace(1) readonly captures(none) %0, i32 0) #14, !alias.scope !74, !noalias !75
  %49 = icmp ne i32 %47, 0
  %50 = icmp ne i32 %48, 0
  %51 = select i1 %49, i1 %50, i1 false
  br i1 %51, label %52, label %57

52:                                               ; preds = %10
  %53 = tail call fast float @air.convert.f.f32.u.i32(i32 %47) #12
  %54 = tail call fast float @air.convert.f.f32.u.i32(i32 %48) #12
  %55 = insertelement <4 x float> <float poison, float poison, float 0.000000e+00, float 1.000000e+00>, float %53, i64 0
  %56 = insertelement <4 x float> %55, float %54, i64 1
  tail call void @air.write_texture_2d.v4f32(ptr addrspace(1) captures(none) %1, <2 x i32> zeroinitializer, <4 x float> %56, i32 0, i32 2) #15, !alias.scope !74, !noalias !75
  br label %57

57:                                               ; preds = %52, %10
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.convert.f.v2f32.u.v2i32(<2 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #1

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_barriers(ptr addrspace(1) captures(none) "air-buffer-no-alias" %0, ptr addrspace(3) captures(none) "air-buffer-no-alias" %1, i32 %2, i32 %3) local_unnamed_addr #2 {
  %5 = zext i32 %2 to i64
  %6 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %5
  %7 = load <4 x float>, ptr addrspace(1) %6, align 16, !tbaa !76, !alias.scope !79, !noalias !82
  %8 = zext i32 %3 to i64
  %9 = getelementptr inbounds <4 x float>, ptr addrspace(3) %1, i64 %8
  store <4 x float> %7, ptr addrspace(3) %9, align 16, !tbaa !76, !alias.scope !82, !noalias !79
  tail call void @air.wg.barrier(i32 2, i32 1) #16
  %10 = load <4 x float>, ptr addrspace(3) %9, align 16, !tbaa !76, !alias.scope !82, !noalias !79
  store <4 x float> %10, ptr addrspace(1) %6, align 16, !tbaa !76, !alias.scope !79, !noalias !82
  tail call void @air.wg.barrier(i32 1, i32 1) #16
  tail call void @air.wg.barrier(i32 3, i32 1) #16
  tail call void @air.simdgroup.barrier(i32 0, i32 1) #16
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_math(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #3 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %4
  %6 = load <4 x float>, ptr addrspace(1) %5, align 16, !tbaa !76, !alias.scope !84, !noalias !87
  %7 = tail call fast <4 x float> @air.fast_sin.v4f32(<4 x float> %6) #12
  %8 = tail call fast <4 x float> @air.fast_cos.v4f32(<4 x float> %6) #12
  %9 = tail call fast <4 x float> @air.fast_tan.v4f32(<4 x float> %6) #12
  %10 = tail call fast <4 x float> @air.fast_exp.v4f32(<4 x float> %6) #12
  %11 = tail call fast <4 x float> @air.fast_exp2.v4f32(<4 x float> %6) #12
  %12 = tail call fast <4 x float> @air.fast_log.v4f32(<4 x float> %6) #12
  %13 = tail call fast <4 x float> @air.fast_log2.v4f32(<4 x float> %6) #12
  %14 = tail call fast <4 x float> @air.fast_sqrt.v4f32(<4 x float> %6) #12
  %15 = tail call fast <4 x float> @air.fast_rsqrt.v4f32(<4 x float> %6) #12
  %16 = tail call fast <4 x float> @air.fast_fabs.v4f32(<4 x float> %6) #12
  %17 = tail call fast <4 x float> @air.fast_floor.v4f32(<4 x float> %6) #12
  %18 = tail call fast <4 x float> @air.fast_ceil.v4f32(<4 x float> %6) #12
  %19 = tail call fast <4 x float> @air.fast_round.v4f32(<4 x float> %6) #12
  %20 = tail call fast <4 x float> @air.fast_trunc.v4f32(<4 x float> %6) #12
  %21 = tail call fast <4 x float> @air.fast_fract.v4f32(<4 x float> %6) #12
  %22 = tail call fast <4 x float> @air.sign.v4f32(<4 x float> %6) #12
  %23 = tail call fast <4 x float> @air.fast_saturate.v4f32(<4 x float> %6) #12
  %24 = tail call fast <4 x float> @air.fast_fmin.v4f32(<4 x float> %6, <4 x float> splat (float 2.000000e+00)) #12
  %25 = tail call fast <4 x float> @air.fast_fmax.v4f32(<4 x float> %6, <4 x float> splat (float 2.000000e+00)) #12
  %26 = tail call fast <4 x float> @air.fast_pow.v4f32(<4 x float> %6, <4 x float> splat (float 2.000000e+00)) #12
  %27 = tail call fast <4 x float> @air.fast_fmod.v4f32(<4 x float> %6, <4 x float> splat (float 2.000000e+00)) #12
  %28 = fcmp fast ole <4 x float> %6, splat (float 2.000000e+00)
  %29 = tail call fast <4 x float> @air.convert.f.v4f32.u.v4i1(<4 x i1> %28) #12
  %30 = tail call fast <4 x float> @air.fast_clamp.v4f32(<4 x float> %6, <4 x float> zeroinitializer, <4 x float> splat (float 1.000000e+00)) #12
  %31 = fmul fast <4 x float> %30, %30
  %32 = fmul fast <4 x float> %30, splat (float 2.000000e+00)
  %33 = fsub fast <4 x float> splat (float 3.000000e+00), %32
  %34 = fmul fast <4 x float> %31, %33
  %35 = tail call fast <4 x float> @air.mix.v4f32(<4 x float> %6, <4 x float> splat (float 2.000000e+00), <4 x float> splat (float 5.000000e-01)) #12
  %36 = shufflevector <4 x float> %6, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %37 = tail call fast float @air.dot.v3f32(<3 x float> %36, <3 x float> <float 1.000000e+00, float 0.000000e+00, float 0.000000e+00>) #12
  %38 = extractelement <4 x float> %6, i64 2
  %39 = fneg fast float %38
  %40 = insertelement <4 x float> <float poison, float 0.000000e+00, float poison, float poison>, float %39, i64 0
  %41 = tail call fast float @air.dot.v3f32(<3 x float> %36, <3 x float> %36) #12
  %42 = tail call fast float @air.fast_sqrt.f32(float %41) #12
  %43 = tail call fast float @air.fast_rsqrt.f32(float %41) #12
  %44 = insertelement <3 x float> poison, float %43, i64 0
  %45 = shufflevector <3 x float> %44, <3 x float> poison, <3 x i32> zeroinitializer
  %46 = fmul fast <3 x float> %45, %36
  %47 = insertelement <4 x float> <float poison, float poison, float poison, float 0.000000e+00>, float %37, i64 0
  %48 = insertelement <4 x float> %47, float %42, i64 1
  %49 = insertelement <4 x float> %48, float %42, i64 2
  %50 = shufflevector <4 x float> %40, <4 x float> %6, <4 x i32> <i32 0, i32 1, i32 4, i32 poison>
  %51 = insertelement <4 x float> %50, float 0.000000e+00, i64 3
  %52 = shufflevector <3 x float> %46, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 poison>
  %53 = insertelement <4 x float> %52, float 0.000000e+00, i64 3
  %54 = fadd fast <4 x float> %8, %7
  %55 = fadd fast <4 x float> %54, %9
  %56 = fadd fast <4 x float> %55, %10
  %57 = fadd fast <4 x float> %56, %51
  %58 = fadd fast <4 x float> %57, %11
  %59 = fadd fast <4 x float> %58, %12
  %60 = fadd fast <4 x float> %59, %13
  %61 = fadd fast <4 x float> %60, %14
  %62 = fadd fast <4 x float> %61, %15
  %63 = fadd fast <4 x float> %62, %16
  %64 = fadd fast <4 x float> %63, %17
  %65 = fadd fast <4 x float> %64, %18
  %66 = fadd fast <4 x float> %65, %19
  %67 = fadd fast <4 x float> %66, %20
  %68 = fadd fast <4 x float> %67, %21
  %69 = fadd fast <4 x float> %68, %22
  %70 = fadd fast <4 x float> %69, %23
  %71 = fadd fast <4 x float> %70, %24
  %72 = fadd fast <4 x float> %71, %25
  %73 = fadd fast <4 x float> %72, %26
  %74 = fadd fast <4 x float> %73, %27
  %75 = fadd fast <4 x float> %74, %29
  %76 = fadd fast <4 x float> %75, %30
  %77 = fadd fast <4 x float> %76, %35
  %78 = fadd fast <4 x float> %77, %34
  %79 = fadd fast <4 x float> %78, %49
  %80 = fadd fast <4 x float> %79, %53
  %81 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %4
  store <4 x float> %80, ptr addrspace(1) %81, align 16, !tbaa !76, !alias.scope !87, !noalias !84
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_integer_math(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #3 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %1, i64 %4
  %6 = load <4 x i32>, ptr addrspace(1) %5, align 16, !tbaa !76, !alias.scope !89, !noalias !92
  %7 = tail call <4 x i32> @air.abs.s.v4i32(<4 x i32> %6) #12
  %8 = tail call <4 x i32> @air.min.s.v4i32(<4 x i32> %6, <4 x i32> splat (i32 100)) #12
  %9 = add <4 x i32> %8, %7
  %10 = tail call <4 x i32> @air.max.s.v4i32(<4 x i32> %6, <4 x i32> splat (i32 -100)) #12
  %11 = add <4 x i32> %9, %10
  %12 = tail call <4 x i32> @air.clamp.s.v4i32(<4 x i32> %6, <4 x i32> splat (i32 -50), <4 x i32> splat (i32 50)) #12
  %13 = add <4 x i32> %11, %12
  %14 = extractelement <4 x i32> %6, i64 0
  %15 = tail call i32 @air.popcount.i32(i32 %14) #12
  %16 = extractelement <4 x i32> %13, i64 0
  %17 = add nsw i32 %16, %15
  %18 = extractelement <4 x i32> %6, i64 1
  %19 = tail call i32 @air.clz.i32(i32 %18, i1 false) #12
  %20 = extractelement <4 x i32> %13, i64 1
  %21 = add nsw i32 %20, %19
  %22 = extractelement <4 x i32> %6, i64 2
  %23 = tail call i32 @air.ctz.i32(i32 %22, i1 false) #12
  %24 = extractelement <4 x i32> %13, i64 2
  %25 = add nsw i32 %23, %24
  %26 = insertelement <4 x i32> poison, i32 %25, i64 2
  %27 = extractelement <4 x i32> %6, i64 3
  %28 = tail call i32 @air.extract_bits.s.i32(i32 %27, i32 4, i32 8) #12
  %29 = extractelement <4 x i32> %13, i64 3
  %30 = add nsw i32 %28, %29
  %31 = insertelement <4 x i32> %26, i32 %30, i64 3
  %32 = tail call i32 @air.insert_bits.s.i32(i32 %14, i32 %18, i32 4, i32 8) #12
  %33 = add nsw i32 %17, %32
  %34 = insertelement <4 x i32> %31, i32 %33, i64 0
  %35 = tail call i32 @air.reverse_bits.i32(i32 %18) #12
  %36 = add nsw i32 %21, %35
  %37 = insertelement <4 x i32> %34, i32 %36, i64 1
  %38 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %0, i64 %4
  store <4 x i32> %37, ptr addrspace(1) %38, align 16, !tbaa !76, !alias.scope !92, !noalias !89
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_conversions(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) captures(none) "air-buffer-no-alias" %1, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %2, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %3, i32 %4) local_unnamed_addr #4 {
  %6 = zext i32 %4 to i64
  %7 = getelementptr inbounds <4 x float>, ptr addrspace(1) %2, i64 %6
  %8 = load <4 x float>, ptr addrspace(1) %7, align 16, !tbaa !76, !alias.scope !94, !noalias !97
  %9 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %3, i64 %6
  %10 = load <4 x i32>, ptr addrspace(1) %9, align 16, !tbaa !76, !alias.scope !101, !noalias !102
  %11 = tail call <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float> %8) #12
  %12 = getelementptr inbounds <4 x i32>, ptr addrspace(1) %1, i64 %6
  %13 = tail call fast <4 x float> @air.convert.f.v4f32.s.v4i32(<4 x i32> %10) #12
  %14 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %6
  %15 = tail call fast <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float> %8) #12
  %16 = tail call fast <4 x float> @air.convert.f.v4f32.f.v4f16(<4 x half> %15) #12
  %17 = fadd fast <4 x float> %16, %13
  store <4 x float> %17, ptr addrspace(1) %14, align 16, !tbaa !76, !alias.scope !103, !noalias !104
  %18 = bitcast <4 x float> %8 to <4 x i32>
  %19 = add <4 x i32> %11, %18
  store <4 x i32> %19, ptr addrspace(1) %12, align 16, !tbaa !76, !alias.scope !105, !noalias !106
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.s.v4i32(<4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x half> @air.convert.f.v4f16.f.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: convergent mustprogress nounwind willreturn
define void @test_simd(ptr addrspace(1) writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %1, i32 %2, i32 %3, i32 %4) local_unnamed_addr #0 {
  %6 = zext i32 %2 to i64
  %7 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %6
  %8 = load <4 x float>, ptr addrspace(1) %7, align 16, !tbaa !76, !alias.scope !107, !noalias !110
  %9 = freeze <4 x float> %8
  %10 = tail call fast <4 x float> @air.simd_shuffle.v4f32(<4 x float> %9, i16 0) #16
  %11 = tail call fast <4 x float> @air.simd_shuffle_xor.v4f32(<4 x float> %9, i16 1) #16
  %12 = tail call fast <4 x float> @air.simd_shuffle_up.v4f32(<4 x float> %9, i16 1) #16
  %13 = tail call fast <4 x float> @air.simd_shuffle_down.v4f32(<4 x float> %9, i16 1) #16
  %14 = tail call fast <4 x float> @air.simd_sum.v4f32(<4 x float> %9) #16
  %15 = tail call fast <4 x float> @air.simd_product.v4f32(<4 x float> %9) #16
  %16 = tail call fast <4 x float> @air.simd_min.v4f32(<4 x float> %9) #16
  %17 = tail call fast <4 x float> @air.simd_max.v4f32(<4 x float> %9) #16
  %18 = tail call fast <4 x float> @air.simd_broadcast_first.v4f32(<4 x float> %9) #16
  %19 = tail call fast <4 x float> @air.simd_prefix_exclusive_sum.v4f32(<4 x float> %9) #16
  %20 = fadd fast <4 x float> %11, %10
  %21 = fadd fast <4 x float> %20, %12
  %22 = fadd fast <4 x float> %21, %13
  %23 = fadd fast <4 x float> %22, %14
  %24 = fadd fast <4 x float> %23, %15
  %25 = fadd fast <4 x float> %24, %16
  %26 = fadd fast <4 x float> %25, %17
  %27 = fadd fast <4 x float> %26, %18
  %28 = fadd fast <4 x float> %27, %19
  %29 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %6
  store <4 x float> %28, ptr addrspace(1) %29, align 16, !tbaa !76, !alias.scope !110, !noalias !107
  ret void
}

; Function Attrs: mustprogress nounwind willreturn
define void @test_atomics(ptr addrspace(1) captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) captures(none) "air-buffer-no-alias" %1, i32 %2) local_unnamed_addr #5 {
  %4 = alloca i32, align 4
  %5 = getelementptr inbounds %"struct.metal::_atomic", ptr addrspace(1) %0, i64 0, i32 0
  %6 = tail call i32 @air.atomic.global.add.u.i32(ptr addrspace(1) captures(none) %5, i32 1, i32 0, i32 2, i1 true) #17
  %7 = getelementptr inbounds %"struct.metal::_atomic.25", ptr addrspace(1) %1, i64 0, i32 0
  %8 = tail call i32 @air.atomic.global.sub.s.i32(ptr addrspace(1) captures(none) %7, i32 %2, i32 0, i32 2, i1 true) #17
  %9 = tail call i32 @air.atomic.global.min.s.i32(ptr addrspace(1) captures(none) %7, i32 %2, i32 0, i32 2, i1 true) #17
  %10 = tail call i32 @air.atomic.global.max.s.i32(ptr addrspace(1) captures(none) %7, i32 %2, i32 0, i32 2, i1 true) #17
  %11 = tail call i32 @air.atomic.global.and.u.i32(ptr addrspace(1) captures(none) %5, i32 255, i32 0, i32 2, i1 true) #17
  %12 = tail call i32 @air.atomic.global.or.u.i32(ptr addrspace(1) captures(none) %5, i32 1, i32 0, i32 2, i1 true) #17
  %13 = tail call i32 @air.atomic.global.xor.u.i32(ptr addrspace(1) captures(none) %5, i32 3, i32 0, i32 2, i1 true) #17
  %14 = tail call i32 @air.atomic.global.xchg.i32(ptr addrspace(1) captures(none) %5, i32 %2, i32 0, i32 2, i1 true) #17
  %15 = add i32 %2, 1
  %16 = bitcast ptr %4 to ptr
  call void @llvm.lifetime.start.p0(ptr %4)
  store i32 %14, ptr %4, align 4, !tbaa !112
  %17 = call i32 @air.atomic.global.cmpxchg.weak.i32(ptr addrspace(1) captures(none) %5, ptr nonnull captures(none) %4, i32 %15, i32 0, i32 0, i32 2, i1 true) #17
  call void @llvm.lifetime.end.p0(ptr %4)
  %18 = tail call i32 @air.atomic.global.load.i32(ptr addrspace(1) captures(none) %5, i32 0, i32 2, i1 true) #17
  %19 = add i32 %18, 1
  tail call void @air.atomic.global.store.i32(ptr addrspace(1) captures(none) %5, i32 %19, i32 0, i32 2, i1 true) #17
  ret void
}

; Function Attrs: convergent mustprogress nounwind willreturn
define <4 x float> @test_fragment_builtins(<4 x float> %0) local_unnamed_addr #0 {
  %2 = extractelement <4 x float> %0, i64 0
  %3 = tail call fast float @air.dfdx.f32(float %2) #16
  %4 = extractelement <4 x float> %0, i64 1
  %5 = tail call fast float @air.dfdy.f32(float %4) #16
  %6 = tail call fast float @air.fwidth.f32(float %2) #16
  %7 = insertelement <4 x float> <float poison, float poison, float poison, float 1.000000e+00>, float %3, i64 0
  %8 = insertelement <4 x float> %7, float %5, i64 1
  %9 = insertelement <4 x float> %8, float %6, i64 2
  ret <4 x float> %9
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_pack_unpack(ptr addrspace(1) captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) captures(none) "air-buffer-no-alias" %1, ptr addrspace(1) readonly captures(none) "air-buffer-no-alias" %2, i32 %3) local_unnamed_addr #3 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds <4 x float>, ptr addrspace(1) %2, i64 %5
  %7 = load <4 x float>, ptr addrspace(1) %6, align 16, !tbaa !76, !alias.scope !114, !noalias !117
  %8 = tail call i32 @air.pack.snorm4x8.v4f32(<4 x float> %7) #12
  %9 = getelementptr inbounds i32, ptr addrspace(1) %0, i64 %5
  %10 = tail call fast <4 x float> @air.unpack.snorm4x8.v4f32(i32 %8) #12
  %11 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %5
  %12 = tail call i32 @air.pack.unorm4x8.v4f32(<4 x float> %7) #12
  %13 = add i32 %12, %8
  store i32 %13, ptr addrspace(1) %9, align 4, !tbaa !112, !alias.scope !120, !noalias !121
  %14 = tail call fast <4 x float> @air.unpack.unorm4x8.v4f32(i32 %12) #12
  %15 = fadd fast <4 x float> %14, %10
  store <4 x float> %15, ptr addrspace(1) %11, align 16, !tbaa !76, !alias.scope !122, !noalias !123
  ret void
}

; Function Attrs: convergent mustprogress nounwind willreturn
declare void @air.wg.barrier(i32, i32) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare void @air.simdgroup.barrier(i32, i32) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_sin.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_cos.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_tan.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_exp.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_exp2.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_log.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_log2.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_sqrt.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_rsqrt.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fabs.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_floor.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_ceil.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_round.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_trunc.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fract.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.sign.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_saturate.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fmin.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fmax.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_pow.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_fmod.v4f32(<4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.convert.f.v4f32.u.v4i1(<4 x i1>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.mix.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.fast_clamp.v4f32(<4 x float>, <4 x float>, <4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_sqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.abs.s.v4i32(<4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.min.s.v4i32(<4 x i32>, <4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.max.s.v4i32(<4 x i32>, <4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x i32> @air.clamp.s.v4i32(<4 x i32>, <4 x i32>, <4 x i32>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.popcount.i32(i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.clz.i32(i32, i1) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.ctz.i32(i32, i1) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.extract_bits.s.i32(i32, i32, i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.insert_bits.s.i32(i32, i32, i32, i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.reverse_bits.i32(i32) local_unnamed_addr #1

; Function Attrs: convergent mustprogress nounwind willreturn
declare float @air.dfdx.f32(float) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare float @air.dfdy.f32(float) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare float @air.fwidth.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.pack.snorm4x8.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.unpack.snorm4x8.v4f32(i32) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i32 @air.pack.unorm4x8.v4f32(<4 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.unpack.unorm4x8.v4f32(i32) local_unnamed_addr #1

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d_grad.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, <2 x float>, <2 x float>, float, i1, <2 x i32>, i32) local_unnamed_addr #8

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_3d.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <3 x float>, i1, <3 x i32>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_cube.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <3 x float>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.sample_texture_2d_array.v4f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), <2 x float>, i32, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: convergent mustprogress nofree nounwind willreturn memory(argmem: read)
declare { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) readonly captures(none), ptr addrspace(2) readonly captures(none), i32, <2 x float>, float, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #7

; Function Attrs: mustprogress nofree nounwind willreturn memory(argmem: read)
declare { <4 x float>, i8 } @air.read_texture_2d.v4f32(ptr addrspace(1) readonly captures(none), <2 x i32>, i32, i32) local_unnamed_addr #8

; Function Attrs: mustprogress nounwind willreturn memory(argmem: readwrite)
declare void @air.write_texture_2d.v4f32(ptr addrspace(1) captures(none), <2 x i32>, <4 x float>, i32, i32) local_unnamed_addr #9

; Function Attrs: mustprogress nofree nounwind willreturn memory(argmem: read)
declare i32 @air.get_width_texture_2d(ptr addrspace(1) readonly captures(none), i32) local_unnamed_addr #8

; Function Attrs: mustprogress nofree nounwind willreturn memory(argmem: read)
declare i32 @air.get_height_texture_2d(ptr addrspace(1) readonly captures(none), i32) local_unnamed_addr #8

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_shuffle.v4f32(<4 x float>, i16) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_shuffle_xor.v4f32(<4 x float>, i16) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_shuffle_up.v4f32(<4 x float>, i16) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_shuffle_down.v4f32(<4 x float>, i16) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_sum.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_product.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_min.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_max.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_broadcast_first.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <4 x float> @air.simd_prefix_exclusive_sum.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.add.u.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.sub.s.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.min.s.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.max.s.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.and.u.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.or.u.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.xor.u.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.xchg.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.cmpxchg.weak.i32(ptr addrspace(1) captures(none), ptr captures(none), i32, i32, i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare i32 @air.atomic.global.load.i32(ptr addrspace(1) captures(none), i32, i32, i1) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn
declare void @air.atomic.global.store.i32(ptr addrspace(1) captures(none), i32, i32, i32, i1) local_unnamed_addr #10

declare void @llvm.lifetime.start.i64(i64)

declare void @llvm.lifetime.end.i64(i64)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #11

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #11

attributes #0 = { convergent mustprogress nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { convergent mustprogress nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #3 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #4 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #5 = { mustprogress nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #6 = { convergent mustprogress nounwind willreturn }
attributes #7 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #8 = { mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #9 = { mustprogress nounwind willreturn memory(argmem: readwrite) }
attributes #10 = { mustprogress nounwind willreturn }
attributes #11 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #12 = { nounwind willreturn memory(none) }
attributes #13 = { convergent nounwind willreturn memory(argmem: read) }
attributes #14 = { nounwind willreturn memory(argmem: read) }
attributes #15 = { nounwind willreturn memory(argmem: readwrite) }
attributes #16 = { convergent nounwind willreturn }
attributes #17 = { nounwind willreturn }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9, !22, !28, !32, !36, !43, !47, !53}
!air.fragment = !{!58}
!air.compile_options = !{!63, !64, !65}
!llvm.ident = !{!66}
!air.version = !{!67}
!air.language_version = !{!68}
!air.source_file_name = !{!69}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_texture_ops, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14, !15, !16, !17, !18, !19, !20, !21}
!12 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.read", !"air.arg_type_name", !"texture2d<float, read>", !"air.arg_name", !"texR"}
!13 = !{i32 1, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.write", !"air.arg_type_name", !"texture2d<float, write>", !"air.arg_name", !"texW"}
!14 = !{i32 2, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"texS"}
!15 = !{i32 3, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"texH"}
!16 = !{i32 4, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture3d<float, sample>", !"air.arg_name", !"tex3D"}
!17 = !{i32 5, !"air.texture", !"air.location_index", i32 5, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<float, sample>", !"air.arg_name", !"texCube"}
!18 = !{i32 6, !"air.texture", !"air.location_index", i32 6, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d_array<float, sample>", !"air.arg_name", !"texArr"}
!19 = !{i32 7, !"air.texture", !"air.location_index", i32 7, i32 1, !"air.sample", !"air.arg_type_name", !"depth2d<float, sample>", !"air.arg_name", !"depthTex"}
!20 = !{i32 8, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"smp"}
!21 = !{i32 9, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"gid"}
!22 = !{ptr @test_barriers, !10, !23}
!23 = !{!24, !25, !26, !27}
!24 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"buf"}
!25 = !{i32 1, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 3, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"shared"}
!26 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!27 = !{i32 3, !"air.thread_position_in_threadgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"lid"}
!28 = !{ptr @test_math, !10, !29}
!29 = !{!30, !31, !26}
!30 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"out"}
!31 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"in_"}
!32 = !{ptr @test_integer_math, !10, !33}
!33 = !{!34, !35, !26}
!34 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"int4", !"air.arg_name", !"out"}
!35 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"int4", !"air.arg_name", !"in_"}
!36 = !{ptr @test_conversions, !10, !37}
!37 = !{!38, !39, !40, !41, !42}
!38 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"outF"}
!39 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"int4", !"air.arg_name", !"outI"}
!40 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"inF"}
!41 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"int4", !"air.arg_name", !"inI"}
!42 = !{i32 4, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!43 = !{ptr @test_simd, !10, !44}
!44 = !{!30, !31, !26, !45, !46}
!45 = !{i32 3, !"air.thread_index_in_simdgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"simd_lane", !"air.arg_unused"}
!46 = !{i32 4, !"air.simdgroup_index_in_threadgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"simd_gid", !"air.arg_unused"}
!47 = !{ptr @test_atomics, !10, !48}
!48 = !{!49, !51, !26}
!49 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.struct_type_info", !50, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"metal::_atomic", !"air.arg_name", !"counter"}
!50 = !{i32 0, i32 4, i32 0, !"uint", !"__s"}
!51 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.struct_type_info", !52, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"metal::_atomic", !"air.arg_name", !"acc"}
!52 = !{i32 0, i32 4, i32 0, !"int", !"__s"}
!53 = !{ptr @test_pack_unpack, !10, !54}
!54 = !{!55, !56, !40, !57}
!55 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"outU"}
!56 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"outF"}
!57 = !{i32 3, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!58 = !{ptr @test_fragment_builtins, !59, !61}
!59 = !{!60}
!60 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!61 = !{!62}
!62 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!63 = !{!"air.compile.denorms_disable"}
!64 = !{!"air.compile.fast_math_enable"}
!65 = !{!"air.compile.framebuffer_fetch_enable"}
!66 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!67 = !{i32 2, i32 7, i32 0}
!68 = !{!"Metal", i32 2, i32 4, i32 0}
!69 = !{!"/private/tmp/playtools-air-builtins/test_builtins.metal"}
!70 = !{!71, !73}
!71 = distinct !{!71, !72, !"air-alias-scope-textures"}
!72 = distinct !{!72, !"air-alias-scopes(test_texture_ops)"}
!73 = distinct !{!73, !72, !"air-alias-scope-samplers"}
!74 = !{!71}
!75 = !{!73}
!76 = !{!77, !77, i64 0}
!77 = !{!"omnipotent char", !78, i64 0}
!78 = !{!"Simple C++ TBAA"}
!79 = !{!80}
!80 = distinct !{!80, !81, !"air-alias-scope-arg(0)"}
!81 = distinct !{!81, !"air-alias-scopes(test_barriers)"}
!82 = !{!83}
!83 = distinct !{!83, !81, !"air-alias-scope-arg(1)"}
!84 = !{!85}
!85 = distinct !{!85, !86, !"air-alias-scope-arg(1)"}
!86 = distinct !{!86, !"air-alias-scopes(test_math)"}
!87 = !{!88}
!88 = distinct !{!88, !86, !"air-alias-scope-arg(0)"}
!89 = !{!90}
!90 = distinct !{!90, !91, !"air-alias-scope-arg(1)"}
!91 = distinct !{!91, !"air-alias-scopes(test_integer_math)"}
!92 = !{!93}
!93 = distinct !{!93, !91, !"air-alias-scope-arg(0)"}
!94 = !{!95}
!95 = distinct !{!95, !96, !"air-alias-scope-arg(2)"}
!96 = distinct !{!96, !"air-alias-scopes(test_conversions)"}
!97 = !{!98, !99, !100}
!98 = distinct !{!98, !96, !"air-alias-scope-arg(0)"}
!99 = distinct !{!99, !96, !"air-alias-scope-arg(1)"}
!100 = distinct !{!100, !96, !"air-alias-scope-arg(3)"}
!101 = !{!100}
!102 = !{!98, !99, !95}
!103 = !{!98}
!104 = !{!99, !95, !100}
!105 = !{!99}
!106 = !{!98, !95, !100}
!107 = !{!108}
!108 = distinct !{!108, !109, !"air-alias-scope-arg(1)"}
!109 = distinct !{!109, !"air-alias-scopes(test_simd)"}
!110 = !{!111}
!111 = distinct !{!111, !109, !"air-alias-scope-arg(0)"}
!112 = !{!113, !113, i64 0}
!113 = !{!"int", !77, i64 0}
!114 = !{!115}
!115 = distinct !{!115, !116, !"air-alias-scope-arg(2)"}
!116 = distinct !{!116, !"air-alias-scopes(test_pack_unpack)"}
!117 = !{!118, !119}
!118 = distinct !{!118, !116, !"air-alias-scope-arg(0)"}
!119 = distinct !{!119, !116, !"air-alias-scope-arg(1)"}
!120 = !{!118}
!121 = !{!119, !115}
!122 = !{!119}
!123 = !{!118, !115}
