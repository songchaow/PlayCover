; ModuleID = 'test_sample_compare_live.air'
source_filename = "test_sample_compare_live.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios18.5.0"

define <4 x float> @xlatMtlMain(ptr addrspace(1) nocapture readonly %0, ptr addrspace(2) nocapture readonly %1, <2 x float> noundef %2) local_unnamed_addr #0 {
  %4 = tail call { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) nocapture readonly %0, ptr addrspace(2) nocapture readonly %1, i32 1, <2 x float> %2, float 5.000000e-01, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #2
  %5 = extractvalue { float, i8 } %4, 0
  %10 = insertelement <4 x float> <float poison, float poison, float poison, float 1.000000e+00>, float %5, i64 0
  %11 = insertelement <4 x float> %10, float %5, i64 1
  %12 = insertelement <4 x float> %11, float %5, i64 2
  ret <4 x float> %12
}

declare { float, i8 } @air.sample_compare_depth_2d.f32(ptr addrspace(1) nocapture readonly, ptr addrspace(2) nocapture readonly, i32, <2 x float>, float, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #1

attributes #0 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #1 = { convergent mustprogress nofree nounwind willreturn memory(argmem: read) }
attributes #2 = { convergent nounwind willreturn memory(argmem: read) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.fragment = !{!9}
!air.version = !{!15}
!air.language_version = !{!16}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 18, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{ptr @xlatMtlMain, !10, !12}
!10 = !{!11}
!11 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!12 = !{!13, !14}
!13 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.compare_sample", !"air.arg_type_name", !"depth2d<float>", !"air.arg_name", !"shadowMap"}
!14 = !{i32 1, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"shadowSampler"}
!15 = !{i32 2, i32 7, i32 0}
!16 = !{!"Metal", i32 3, i32 2, i32 0}
