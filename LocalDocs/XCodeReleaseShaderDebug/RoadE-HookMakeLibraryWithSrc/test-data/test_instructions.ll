; ModuleID = 'test_instructions.air'
source_filename = "test_instructions.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_int_arith(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #0 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds i32, ptr addrspace(1) %1, i64 %5
  %7 = load i32, ptr addrspace(1) %6, align 4, !tbaa !36, !alias.scope !40, !noalias !43
  %8 = getelementptr inbounds i32, ptr addrspace(1) %2, i64 %5
  %9 = load i32, ptr addrspace(1) %8, align 4, !tbaa !36, !alias.scope !46, !noalias !47
  %10 = sdiv i32 %7, 3
  %11 = srem i32 %7, 5
  %12 = udiv i32 %9, 7
  %13 = urem i32 %9, 11
  %14 = add nsw i32 %10, %11
  %15 = add nsw i32 %14, %12
  %16 = add nsw i32 %15, %13
  %17 = getelementptr inbounds i32, ptr addrspace(1) %0, i64 %5
  store i32 %16, ptr addrspace(1) %17, align 4, !tbaa !36, !alias.scope !48, !noalias !49
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_bitops(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #0 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds i32, ptr addrspace(1) %1, i64 %5
  %7 = load i32, ptr addrspace(1) %6, align 4, !tbaa !36, !alias.scope !50, !noalias !53
  %8 = getelementptr inbounds i32, ptr addrspace(1) %2, i64 %5
  %9 = load i32, ptr addrspace(1) %8, align 4, !tbaa !36, !alias.scope !56, !noalias !57
  %10 = shl i32 %7, 2
  %11 = lshr i32 %7, 3
  %12 = ashr i32 %9, 1
  %13 = and i32 %7, -16711936
  %14 = or i32 %7, 255
  %15 = xor i32 %7, -1431655766
  %16 = add i32 %10, %11
  %17 = add i32 %16, %13
  %18 = add i32 %17, %14
  %19 = add i32 %18, %15
  %20 = add i32 %19, %12
  %21 = getelementptr inbounds i32, ptr addrspace(1) %0, i64 %5
  store i32 %20, ptr addrspace(1) %21, align 4, !tbaa !36, !alias.scope !58, !noalias !59
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite)
define void @test_conversions(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %2, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %3, ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %4, i32 noundef %5) local_unnamed_addr #1 {
  %7 = zext i32 %5 to i64
  %8 = getelementptr inbounds i16, ptr addrspace(1) %2, i64 %7
  %9 = load i16, ptr addrspace(1) %8, align 2, !tbaa !60, !alias.scope !62, !noalias !65
  %10 = sext i16 %9 to i32
  %11 = getelementptr inbounds i32, ptr addrspace(1) %1, i64 %7
  store i32 %10, ptr addrspace(1) %11, align 4, !tbaa !36, !alias.scope !70, !noalias !71
  %12 = mul i16 %9, 1000
  %13 = and i16 %12, 32760
  %14 = getelementptr inbounds float, ptr addrspace(1) %3, i64 %7
  %15 = load float, ptr addrspace(1) %14, align 4, !tbaa !72, !alias.scope !74, !noalias !75
  %16 = fptrunc float %15 to half
  %17 = getelementptr inbounds half, ptr addrspace(1) %4, i64 %7
  store half %16, ptr addrspace(1) %17, align 2, !tbaa !76, !alias.scope !78, !noalias !79
  %18 = fmul fast float %15, 0x3FD461D580000000
  %19 = tail call fast float @air.fast_fmod.f32(float %15, float 2.500000e+00) #3
  %20 = fadd fast float %19, %18
  %21 = tail call fast float @air.convert.f.f32.s.i16(i16 %13) #3
  %22 = fadd fast float %20, %21
  %23 = getelementptr inbounds float, ptr addrspace(1) %0, i64 %7
  store float %22, ptr addrspace(1) %23, align 4, !tbaa !72, !alias.scope !80, !noalias !81
  ret void
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.s.i16(i16) local_unnamed_addr #2

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_fmod.f32(float, float) local_unnamed_addr #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #2 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #3 = { nounwind willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9, !16, !21}
!air.compile_options = !{!29, !30, !31}
!llvm.ident = !{!32}
!air.version = !{!33}
!air.language_version = !{!34}
!air.source_file_name = !{!35}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_int_arith, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14, !15}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"output"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"inputA"}
!14 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"inputB"}
!15 = !{i32 3, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!16 = !{ptr @test_bitops, !10, !17}
!17 = !{!18, !19, !20, !15}
!18 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"output"}
!19 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"inputA"}
!20 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"inputB"}
!21 = !{ptr @test_conversions, !10, !22}
!22 = !{!23, !24, !25, !26, !27, !28}
!23 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"floatOut"}
!24 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"intOut"}
!25 = !{i32 2, !"air.buffer", !"air.location_index", i32 2, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 2, !"air.arg_type_align_size", i32 2, !"air.arg_type_name", !"short", !"air.arg_name", !"shortIn"}
!26 = !{i32 3, !"air.buffer", !"air.location_index", i32 3, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"floatIn"}
!27 = !{i32 4, !"air.buffer", !"air.location_index", i32 4, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 2, !"air.arg_type_align_size", i32 2, !"air.arg_type_name", !"half", !"air.arg_name", !"halfOut"}
!28 = !{i32 5, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!29 = !{!"air.compile.denorms_disable"}
!30 = !{!"air.compile.fast_math_enable"}
!31 = !{!"air.compile.framebuffer_fetch_enable"}
!32 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!33 = !{i32 2, i32 7, i32 0}
!34 = !{!"Metal", i32 3, i32 2, i32 0}
!35 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_instructions.metal"}
!36 = !{!37, !37, i64 0}
!37 = !{!"int", !38, i64 0}
!38 = !{!"omnipotent char", !39, i64 0}
!39 = !{!"Simple C++ TBAA"}
!40 = !{!41}
!41 = distinct !{!41, !42, !"air-alias-scope-arg(1)"}
!42 = distinct !{!42, !"air-alias-scopes(test_int_arith)"}
!43 = !{!44, !45}
!44 = distinct !{!44, !42, !"air-alias-scope-arg(0)"}
!45 = distinct !{!45, !42, !"air-alias-scope-arg(2)"}
!46 = !{!45}
!47 = !{!44, !41}
!48 = !{!44}
!49 = !{!41, !45}
!50 = !{!51}
!51 = distinct !{!51, !52, !"air-alias-scope-arg(1)"}
!52 = distinct !{!52, !"air-alias-scopes(test_bitops)"}
!53 = !{!54, !55}
!54 = distinct !{!54, !52, !"air-alias-scope-arg(0)"}
!55 = distinct !{!55, !52, !"air-alias-scope-arg(2)"}
!56 = !{!55}
!57 = !{!54, !51}
!58 = !{!54}
!59 = !{!51, !55}
!60 = !{!61, !61, i64 0}
!61 = !{!"short", !38, i64 0}
!62 = !{!63}
!63 = distinct !{!63, !64, !"air-alias-scope-arg(2)"}
!64 = distinct !{!64, !"air-alias-scopes(test_conversions)"}
!65 = !{!66, !67, !68, !69}
!66 = distinct !{!66, !64, !"air-alias-scope-arg(0)"}
!67 = distinct !{!67, !64, !"air-alias-scope-arg(1)"}
!68 = distinct !{!68, !64, !"air-alias-scope-arg(3)"}
!69 = distinct !{!69, !64, !"air-alias-scope-arg(4)"}
!70 = !{!67}
!71 = !{!66, !63, !68, !69}
!72 = !{!73, !73, i64 0}
!73 = !{!"float", !38, i64 0}
!74 = !{!68}
!75 = !{!66, !67, !63, !69}
!76 = !{!77, !77, i64 0}
!77 = !{!"half", !38, i64 0}
!78 = !{!69}
!79 = !{!66, !67, !63, !68}
!80 = !{!66}
!81 = !{!67, !63, !68, !69}
