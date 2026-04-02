; ModuleID = 'test_phi.air'
source_filename = "test_phi.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_phi_simple(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(4) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #0 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds <4 x float>, ptr addrspace(1) %1, i64 %5
  %7 = load <4 x float>, ptr addrspace(1) %6, align 16, !tbaa !31, !alias.scope !34, !noalias !37
  %8 = extractelement <4 x float> %7, i64 0
  %9 = load float, ptr addrspace(2) %2, align 4, !tbaa !40, !alias.scope !42, !noalias !43
  %10 = fcmp fast ogt float %8, %9
  %11 = select i1 %10, <4 x float> splat (float 2.000000e+00), <4 x float> splat (float 5.000000e-01)
  %12 = fmul fast <4 x float> %11, %7
  %13 = getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %5
  store <4 x float> %12, ptr addrspace(1) %13, align 16, !tbaa !31, !alias.scope !44, !noalias !45
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite)
define void @test_phi_nested(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(2) noundef readonly align 8 captures(none) dereferenceable(8) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #0 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds float, ptr addrspace(1) %1, i64 %5
  %7 = load float, ptr addrspace(1) %6, align 4, !tbaa !40, !alias.scope !46, !noalias !49
  %8 = load <2 x float>, ptr addrspace(2) %2, align 8, !alias.scope !52, !noalias !53
  %9 = extractelement <2 x float> %8, i64 0
  %10 = fcmp fast ogt float %7, %9
  %11 = extractelement <2 x float> %8, i64 1
  %12 = fcmp fast ogt float %7, %11
  %13 = select i1 %12, float 1.000000e+00, float 5.000000e-01
  %14 = select i1 %10, float %13, float 0.000000e+00
  %15 = getelementptr inbounds float, ptr addrspace(1) %0, i64 %5
  store float %14, ptr addrspace(1) %15, align 4, !tbaa !40, !alias.scope !54, !noalias !55
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind memory(argmem: readwrite)
define void @test_phi_loop(ptr addrspace(1) noundef writeonly captures(none) "air-buffer-no-alias" %0, ptr addrspace(1) noundef readonly captures(none) "air-buffer-no-alias" %1, ptr addrspace(2) noundef readonly align 4 captures(none) dereferenceable(4) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #1 {
  %5 = load i32, ptr addrspace(2) %2, align 4, !tbaa !56, !alias.scope !58, !noalias !61
  %6 = icmp eq i32 %5, 0
  br i1 %6, label %7, label %11

7:                                                ; preds = %11, %4
  %8 = phi float [ 0.000000e+00, %4 ], [ %18, %11 ]
  %9 = zext i32 %3 to i64
  %10 = getelementptr inbounds float, ptr addrspace(1) %0, i64 %9
  store float %8, ptr addrspace(1) %10, align 4, !tbaa !40, !alias.scope !64, !noalias !65
  ret void

11:                                               ; preds = %11, %4
  %12 = phi i32 [ %19, %11 ], [ 0, %4 ]
  %13 = phi float [ %18, %11 ], [ 0.000000e+00, %4 ]
  %14 = add i32 %12, %3
  %15 = zext i32 %14 to i64
  %16 = getelementptr inbounds float, ptr addrspace(1) %1, i64 %15
  %17 = load float, ptr addrspace(1) %16, align 4, !tbaa !40, !alias.scope !66, !noalias !67
  %18 = fadd fast float %17, %13
  %19 = add nuw i32 %12, 1
  %20 = icmp eq i32 %19, %5
  br i1 %20, label %7, label %11, !llvm.loop !68
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind memory(argmem: readwrite) "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9, !16, !21}
!air.compile_options = !{!24, !25, !26}
!llvm.ident = !{!27}
!air.version = !{!28}
!air.language_version = !{!29}
!air.source_file_name = !{!30}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @test_phi_simple, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14, !15}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"output"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"input"}
!14 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"threshold"}
!15 = !{i32 3, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}
!16 = !{ptr @test_phi_nested, !10, !17}
!17 = !{!18, !19, !20, !15}
!18 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"output"}
!19 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"input"}
!20 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 8, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"bounds"}
!21 = !{ptr @test_phi_loop, !10, !22}
!22 = !{!18, !19, !23, !15}
!23 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"iterations"}
!24 = !{!"air.compile.denorms_disable"}
!25 = !{!"air.compile.fast_math_enable"}
!26 = !{!"air.compile.framebuffer_fetch_enable"}
!27 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!28 = !{i32 2, i32 7, i32 0}
!29 = !{!"Metal", i32 3, i32 2, i32 0}
!30 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_phi.metal"}
!31 = !{!32, !32, i64 0}
!32 = !{!"omnipotent char", !33, i64 0}
!33 = !{!"Simple C++ TBAA"}
!34 = !{!35}
!35 = distinct !{!35, !36, !"air-alias-scope-arg(1)"}
!36 = distinct !{!36, !"air-alias-scopes(test_phi_simple)"}
!37 = !{!38, !39}
!38 = distinct !{!38, !36, !"air-alias-scope-arg(0)"}
!39 = distinct !{!39, !36, !"air-alias-scope-arg(2)"}
!40 = !{!41, !41, i64 0}
!41 = !{!"float", !32, i64 0}
!42 = !{!39}
!43 = !{!38, !35}
!44 = !{!38}
!45 = !{!35, !39}
!46 = !{!47}
!47 = distinct !{!47, !48, !"air-alias-scope-arg(1)"}
!48 = distinct !{!48, !"air-alias-scopes(test_phi_nested)"}
!49 = !{!50, !51}
!50 = distinct !{!50, !48, !"air-alias-scope-arg(0)"}
!51 = distinct !{!51, !48, !"air-alias-scope-arg(2)"}
!52 = !{!51}
!53 = !{!50, !47}
!54 = !{!50}
!55 = !{!47, !51}
!56 = !{!57, !57, i64 0}
!57 = !{!"int", !32, i64 0}
!58 = !{!59}
!59 = distinct !{!59, !60, !"air-alias-scope-arg(2)"}
!60 = distinct !{!60, !"air-alias-scopes(test_phi_loop)"}
!61 = !{!62, !63}
!62 = distinct !{!62, !60, !"air-alias-scope-arg(0)"}
!63 = distinct !{!63, !60, !"air-alias-scope-arg(1)"}
!64 = !{!62}
!65 = !{!63, !59}
!66 = !{!63}
!67 = !{!62, !59}
!68 = distinct !{!68, !69}
!69 = !{!"llvm.loop.mustprogress"}
