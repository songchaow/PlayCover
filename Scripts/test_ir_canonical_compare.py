from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
TEST_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_vertex_draw_builtins.ll"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import ir_canonical_compare as canonical_compare


def make_kernel_ir(*, ssa_name: str = "%tmp", buffer_addrspace: int = 1, metadata_addrspace: int = 1) -> str:
    return f'''source_filename = "synthetic.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_kernel(ptr addrspace({buffer_addrspace}) nocapture writeonly %0, i32 %1) #0 {{
entry:
  {ssa_name} = zext i32 %1 to i64
  ret void
}}

attributes #0 = {{ nounwind memory(argmem: write) "no-builtins" }}

!air.kernel = !{{!0}}
!air.compile_options = !{{!1}}
!0 = !{{ptr @test_kernel, !2, !3}}
!1 = !{{!4}}
!2 = !{{}}
!3 = !{{!5, !6}}
!4 = !{{!"air.compile.fast_math_enable"}}
!5 = !{{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 {metadata_addrspace}, !"air.arg_type_name", !"float4", !"air.arg_name", !"out"}}
!6 = !{{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"tid"}}
'''


class IRCanonicalCompareTests(unittest.TestCase):
    def test_extract_ir_summary_from_real_sample(self) -> None:
        summary = canonical_compare.extract_ir_summary(TEST_SAMPLE)

        self.assertEqual(summary["entryCount"], 2)
        self.assertIn("vertex:test_base_vertex_builtin", summary["entryKeys"])
        self.assertIn("vertex:test_base_instance_builtin", summary["entryKeys"])
        vertex_entry = next(item for item in summary["entries"] if item["functionName"] == "test_base_vertex_builtin")
        self.assertEqual(vertex_entry["shaderType"], "vertex")
        self.assertTrue(any("kind=air.base_vertex" in item for item in vertex_entry["builtinSemantics"]))
        self.assertEqual(summary["module"]["targetTriple"], "air64_v24-apple-ios15.0.0")

    def test_compare_ignores_ssa_renames(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_kernel_ir(ssa_name="%tmp"))
        regenerated = canonical_compare.extract_ir_summary_text(make_kernel_ir(ssa_name="%renamed"))

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)
        self.assertEqual(comparison["riskLevel"], "L0")
        self.assertTrue(comparison["same"])

    def test_compare_flags_addrspace_change_as_high_risk(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_kernel_ir(buffer_addrspace=1, metadata_addrspace=1))
        regenerated = canonical_compare.extract_ir_summary_text(make_kernel_ir(buffer_addrspace=2, metadata_addrspace=2))

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)
        self.assertEqual(comparison["riskLevel"], "L3")
        self.assertFalse(comparison["same"])
        self.assertTrue(any(item["category"] in {"entry", "address-space"} for item in comparison["differences"]))


if __name__ == "__main__":
    unittest.main()
