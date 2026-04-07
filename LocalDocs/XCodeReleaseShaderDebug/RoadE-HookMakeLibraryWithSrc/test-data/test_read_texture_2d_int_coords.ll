; Test case for E-006g3: air.read_texture_2d on sampled textures must cast int coords to uint before emitting Metal read().
; Covers fragment stage input -> signed int coord conversion plus trailing zero control args.
; ModuleID = 'test_read_texture_2d_int_coords.air'
source_filename = "test_read_texture_2d_int_coords.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define <4 x half> @test_read_texture_2d_int_coords(ptr addrspace(1) %0, <2 x float> %1) local_unnamed_addr #0 {
  %3 = tail call <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float> %1) #1
  %4 = tail call { <4 x half>, i8 } @air.read_texture_2d.v4f16(ptr addrspace(1) nocapture readonly %0, <2 x i32> %3, i32 0, i32 0) #2
  %5 = extractvalue { <4 x half>, i8 } %4, 0
  ret <4 x half> %5
}

declare <2 x i32> @air.convert.s.v2i32.f.v2f32(<2 x float>) local_unnamed_addr #1
declare { <4 x half>, i8 } @air.read_texture_2d.v4f16(ptr addrspace(1) nocapture readonly, <2 x i32>, i32, i32) local_unnamed_addr #2

attributes #0 = { convergent nounwind optsize }
attributes #1 = { nounwind memory(none) }
attributes #2 = { nounwind memory(argmem: read) }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!air.fragment = !{!8}
!llvm.ident = !{!14}
!air.version = !{!15}
!air.language_version = !{!16}
!air.source_file_name = !{!17}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"air.max_device_buffers", i32 31}
!3 = !{i32 7, !"air.max_constant_buffers", i32 31}
!4 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!5 = !{i32 7, !"air.max_textures", i32 128}
!6 = !{i32 7, !"air.max_read_write_textures", i32 8}
!7 = !{i32 7, !"air.max_samplers", i32 16}
!8 = !{ptr @test_read_texture_2d_int_coords, !9, !11}
!9 = !{!10}
!10 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"half4", !"air.arg_name", !"SV_Target0"}
!11 = !{!12, !13}
!12 = !{i32 0, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"inputTexture"}
!13 = !{i32 1, !"air.fragment_input", !"user(TEXCOORD0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"TEXCOORD0"}
!14 = !{!"Apple metal version 32023.620 (metalfe-32023.620)"}
!15 = !{i32 2, i32 7, i32 0}
!16 = !{!"Metal", i32 3, i32 2, i32 0}
!17 = !{!"/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_read_texture_2d_int_coords.metal"}
