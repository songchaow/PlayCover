from __future__ import annotations

import json
import tempfile
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


def make_intrinsic_alias_ir(*, intrinsic_name: str) -> str:
    return f'''source_filename = "synthetic.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_kernel() #0 {{
entry:
  %tmp = call <2 x half> @{intrinsic_name}(<2 x half> zeroinitializer, <2 x half> zeroinitializer)
  ret void
}}

attributes #0 = {{ nounwind memory(none) "no-builtins" }}

!air.kernel = !{{!0}}
!air.compile_options = !{{!1}}
!0 = !{{ptr @test_kernel, !2, !3}}
!1 = !{{!4}}
!2 = !{{}}
!3 = !{{}}
!4 = !{{!"air.compile.fast_math_enable"}}
'''


def make_fast_math_flag_ir(*, instruction_flags: str) -> str:
    flag_prefix = f"{instruction_flags} " if instruction_flags else ""
    return f'''source_filename = "synthetic.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @test_kernel() #0 {{
entry:
  %tmp = fadd {flag_prefix}float 1.0, 2.0
  ret void
}}

attributes #0 = {{ nounwind memory(none) "no-builtins" }}

!air.kernel = !{{!0}}
!air.compile_options = !{{!1}}
!0 = !{{ptr @test_kernel, !2, !3}}
!1 = !{{!4}}
!2 = !{{}}
!3 = !{{}}
!4 = !{{!"air.compile.fast_math_enable"}}
'''


def make_direct_vertex_metadata_ir() -> str:
    return '''source_filename = "synthetic_vertex.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-n8:16:32"
target triple = "air64-apple-ios15.0.0"

define <4 x float> @test_vertex(ptr addrspace(2) %0, <2 x float> %1) {
entry:
  ret <4 x float> zeroinitializer
}

!air.vertex = !{!0}
!0 = !{ptr @test_vertex, !1, !2, !4}
!1 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!2 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !3, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
!3 = !{i32 0, i32 16, i32 0, !"float4", !"baseColor"}
!4 = !{i32 1, !"air.vertex_input", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv", !"air.location_index", i32 0, i32 1}
'''


def make_roundtrip_report(*, job_count: int, roundtrip_failed_jobs: int = 0, compile_failed_jobs: int = 0) -> dict:
    return {
        "jobCount": job_count,
        "roundTripSucceededJobs": job_count - roundtrip_failed_jobs,
        "roundTripFailedJobs": roundtrip_failed_jobs,
        "replayFailedJobs": 0,
        "compileFailedJobs": compile_failed_jobs,
        "llvmDisFailedJobs": 0,
    }


def make_risk_report(*, samples: list[dict], blocked_samples: list[dict] | None = None, l2_samples: list[dict] | None = None) -> dict:
    risk_counts = {"L0": 0, "L1": 0, "L2": 0, "L3": 0}
    for sample in samples:
        risk_counts[sample["riskLevel"]] += 1
    return {
        "jobCount": len(samples),
        "riskCounts": risk_counts,
        "samples": samples,
        "blockedSamples": blocked_samples or [],
        "samplesForL3": l2_samples or [],
    }


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


class IRCanonicalCompareTests(unittest.TestCase):
    @staticmethod
    def _make_optimizer_drift_summary(
        module_intrinsics: dict[str, int],
        entry_intrinsics: dict[str, int],
        cfg: dict[str, object],
        instruction_families: dict[str, int],
    ) -> dict[str, object]:
        entry = {
            "shaderType": "vertex",
            "functionName": "xlatMtlMain",
            "returnSignature": "void",
            "parameterCount": 1,
            "parameterSignatures": ["ptr addrspace(2)"],
            "parameterAddrspaces": [2],
            "argSemantics": ["kind=air.buffer|index=0|location=0|access=read|type=Uniforms|typeSize=16|align=16|qualifiers=air.read"],
            "resourceSemantics": ["kind=air.buffer|index=0|location=0|access=read|type=Uniforms|typeSize=16|align=16|qualifiers=air.read"],
            "builtinSemantics": ["kind=air.vertex_input|index=0|location=0|type=float4"],
            "outputSemantics": ["kind=air.position|type=float4"],
            "functionAttrs": [],
            "fastMathAttrKeys": [],
            "cfg": cfg,
            "instructionFamilies": instruction_families,
            "airIntrinsicCalls": entry_intrinsics,
            "addrspaceCounts": {"2": 12},
            "fastMathInstructionFlags": {},
        }
        return {
            "schemaVersion": canonical_compare.SCHEMA_VERSION,
            "module": {
                "sourceFilename": None,
                "targetTriple": "air64-apple-ios11.0.0",
                "dataLayout": None,
                "compileOptions": ["air.compile.fast_math_enable"],
            },
            "entryCount": 1,
            "functionCount": 1,
            "entries": [entry],
            "functions": [],
            "entryKeys": ["vertex:xlatMtlMain"],
            "moduleAddressSpaces": {"2": 32},
            "moduleAirIntrinsics": module_intrinsics,
            "moduleInstructionFamilies": instruction_families,
            "fastMath": {
                "compileOptions": ["air.compile.fast_math_enable"],
                "functionAttrKeys": [],
                "instructionFlags": {"fast": 5},
            },
        }

    def test_extract_ir_summary_from_real_sample(self) -> None:
        summary = canonical_compare.extract_ir_summary(TEST_SAMPLE)

        self.assertEqual(summary["entryCount"], 2)
        self.assertIn("vertex:test_base_vertex_builtin", summary["entryKeys"])
        self.assertIn("vertex:test_base_instance_builtin", summary["entryKeys"])
        vertex_entry = next(item for item in summary["entries"] if item["functionName"] == "test_base_vertex_builtin")
        self.assertEqual(vertex_entry["shaderType"], "vertex")
        self.assertTrue(any("kind=air.base_vertex" in item for item in vertex_entry["builtinSemantics"]))
        self.assertEqual(summary["module"]["targetTriple"], "air64_v24-apple-ios15.0.0")

    def test_extract_ir_summary_supports_direct_entry_metadata_refs(self) -> None:
        summary = canonical_compare.extract_ir_summary_text(make_direct_vertex_metadata_ir())

        self.assertEqual(summary["entryCount"], 1)
        entry = summary["entries"][0]
        self.assertEqual(entry["functionName"], "test_vertex")
        self.assertEqual(len(entry["argSemantics"]), 2)
        self.assertEqual(entry["outputSemantics"], ["kind=air.position|type=float4"])
        self.assertIn(
            "kind=air.buffer|index=0|location=0|access=read|type=Uniforms|typeSize=16|align=16|qualifiers=air.read",
            entry["resourceSemantics"],
        )
        self.assertIn(
            "kind=air.vertex_input|index=1|location=0|type=float2",
            entry["builtinSemantics"],
        )
        self.assertFalse(any("kind=<none>" in item for item in entry["argSemantics"]))

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

    def test_compare_ignores_resource_metadata_addrspace_when_parameter_addrspace_matches(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_kernel_ir(buffer_addrspace=2, metadata_addrspace=1))
        regenerated = canonical_compare.extract_ir_summary_text(make_kernel_ir(buffer_addrspace=2, metadata_addrspace=2))

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)
        self.assertEqual(comparison["riskLevel"], "L0")
        self.assertTrue(comparison["same"])

        original_entry = original["entries"][0]
        regenerated_entry = regenerated["entries"][0]
        self.assertEqual(original_entry["parameterAddrspaces"], regenerated_entry["parameterAddrspaces"])
        self.assertEqual(original_entry["argSemantics"], regenerated_entry["argSemantics"])
        self.assertEqual(original_entry["resourceSemantics"], regenerated_entry["resourceSemantics"])

    def test_compare_ignores_fast_intrinsic_alias_names(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_intrinsic_alias_ir(intrinsic_name="air.fast_fmax.v2f16"))
        regenerated = canonical_compare.extract_ir_summary_text(make_intrinsic_alias_ir(intrinsic_name="air.fmax.v2f16"))

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)
        self.assertEqual(comparison["riskLevel"], "L0")
        self.assertTrue(comparison["same"])

    def test_compare_treats_instruction_level_fast_math_flag_drift_as_low_risk(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_fast_math_flag_ir(instruction_flags="fast"))
        regenerated = canonical_compare.extract_ir_summary_text(
            make_fast_math_flag_ir(instruction_flags="reassoc nnan ninf nsz arcp contract afn")
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)
        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertFalse(comparison["same"])
        self.assertEqual(comparison["fastMathComparison"]["severity"], "L1")

    def test_compare_downgrades_small_arithmetic_vector_tradeoff_to_l1(self) -> None:
        original = canonical_compare.extract_ir_summary_text(make_kernel_ir())
        regenerated = canonical_compare.extract_ir_summary_text(make_kernel_ir())

        original["entries"][0]["shaderType"] = "vertex"
        regenerated["entries"][0]["shaderType"] = "vertex"
        original["entries"][0]["instructionFamilies"] = {
            "aggregate": 3,
            "arithmetic": 9,
            "call": 10,
            "intrinsic": 10,
            "memory": 28,
            "vector": 26,
        }
        regenerated["entries"][0]["instructionFamilies"] = {
            "aggregate": 3,
            "arithmetic": 8,
            "call": 10,
            "intrinsic": 10,
            "memory": 28,
            "vector": 27,
        }

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["differenceCount"], 1)

    def test_compare_downgrades_wider_scalar_vector_materialization_tradeoff_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 12, "air.sample_texture_2d.v4f16": 8},
            entry_intrinsics={"air.fma.v3f32": 12, "air.sample_texture_2d.v4f16": 8},
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 115,
                "call": 105,
                "cast": 25,
                "compare": 2,
                "intrinsic": 105,
                "memory": 90,
                "vector": 111,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 12, "air.sample_texture_2d.v4f16": 8},
            entry_intrinsics={"air.fma.v3f32": 12, "air.sample_texture_2d.v4f16": 8},
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 99,
                "call": 105,
                "cast": 25,
                "compare": 2,
                "intrinsic": 105,
                "memory": 90,
                "vector": 105,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_wider_aggregate_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v2f32": 9, "air.sample_texture_2d.v4f16": 10},
            entry_intrinsics={"air.fma.v2f32": 9, "air.sample_texture_2d.v4f16": 10},
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 2,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 2,
                "arithmetic": 55,
                "call": 77,
                "cast": 2,
                "compare": 3,
                "intrinsic": 77,
                "memory": 26,
                "vector": 141,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v2f32": 9, "air.sample_texture_2d.v4f16": 10},
            entry_intrinsics={"air.fma.v2f32": 9, "air.sample_texture_2d.v4f16": 10},
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 2,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 21,
                "arithmetic": 52,
                "call": 77,
                "cast": 2,
                "compare": 3,
                "intrinsic": 77,
                "memory": 26,
                "vector": 146,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_optimizer_only_intrinsic_family_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 2,
                "air.dot.v3f32": 5,
                "air.fast_fract.f32": 1,
                "air.fast_rsqrt.f32": 2,
                "air.floor.f32": 1,
                "air.fma.f32": 4,
                "air.fma.v2f32": 6,
                "air.fma.v3f32": 3,
                "air.fma.v4f32": 5,
                "air.fmin.f32": 1,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 2,
                "air.dot.v3f32": 5,
                "air.fast_rsqrt.f32": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 6,
                "air.fma.v3f32": 3,
                "air.fma.v4f32": 5,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 2,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 18,
                "call": 29,
                "cast": 1,
                "compare": 1,
                "intrinsic": 27,
                "memory": 69,
                "vector": 76,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 2,
                "air.dot.v3f32": 5,
                "air.fast_floor.f32": 5,
                "air.fast_fmin.f32": 5,
                "air.fast_fract.f32": 1,
                "air.fast_fract.v2f32": 2,
                "air.fast_rsqrt.f32": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 5,
                "air.fma.v3f32": 3,
                "air.fma.v4f32": 5,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 2,
                "air.dot.v3f32": 5,
                "air.fast_fract.v2f32": 2,
                "air.fast_rsqrt.f32": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 5,
                "air.fma.v3f32": 3,
                "air.fma.v4f32": 5,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 16,
                "call": 28,
                "cast": 1,
                "intrinsic": 28,
                "memory": 60,
                "vector": 68,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["builtinComparison"]["severity"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_when_intrinsic_family_set_really_changes(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={"air.floor.f32": 1, "air.fmin.f32": 1, "air.fast_sin.f32": 1},
            entry_intrinsics={"air.floor.f32": 1, "air.fast_sin.f32": 1},
            cfg={
                "basicBlockCount": 3,
                "terminatorCounts": {"br": 1, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 0,
            },
            instruction_families={"call": 4, "intrinsic": 4, "memory": 8},
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fast_floor.f32": 2, "air.fast_fmin.f32": 2},
            entry_intrinsics={"air.fast_floor.f32": 2},
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={"call": 2, "intrinsic": 2, "memory": 4},
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["builtinComparison"]["severity"], "L2")

    def test_compare_downgrades_small_vector_aggregate_shape_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 38,
                "call": 95,
                "cast": 14,
                "compare": 6,
                "intrinsic": 95,
                "memory": 68,
                "vector": 72,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 8,
            },
            instruction_families={
                "aggregate": 6,
                "arithmetic": 36,
                "call": 95,
                "cast": 14,
                "compare": 6,
                "intrinsic": 95,
                "memory": 68,
                "vector": 84,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["builtinComparison"]["severity"], "L0")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_large_vector_aggregate_shape_drift(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 2,
                "arithmetic": 62,
                "call": 95,
                "cast": 14,
                "compare": 6,
                "intrinsic": 95,
                "memory": 68,
                "vector": 104,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.fast_clamp.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 9,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 8,
            },
            instruction_families={
                "aggregate": 14,
                "arithmetic": 50,
                "call": 95,
                "cast": 14,
                "compare": 6,
                "intrinsic": 95,
                "memory": 68,
                "vector": 122,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_downgrades_shared_cfg_vector_aggregate_shape_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.dot.v3f32": 1,
                "air.fast_clamp.v2f32": 2,
                "air.fast_cos.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 2,
                "air.fma.f16": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 2,
                "air.sample_texture_2d.v4f16": 4,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.dot.v3f32": 1,
                "air.fast_clamp.v2f32": 2,
                "air.fast_cos.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 2,
                "air.fma.f16": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 2,
                "air.sample_texture_2d.v4f16": 4,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 60,
                "call": 130,
                "cast": 17,
                "compare": 6,
                "intrinsic": 130,
                "memory": 84,
                "vector": 108,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.dot.v3f32": 1,
                "air.fast_clamp.v2f32": 2,
                "air.fast_cos.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 2,
                "air.fma.f16": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 2,
                "air.sample_texture_2d.v4f16": 4,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 14,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.dot.v3f32": 1,
                "air.fast_clamp.v2f32": 2,
                "air.fast_cos.f32": 2,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 2,
                "air.fma.f16": 2,
                "air.fma.f32": 4,
                "air.fma.v2f32": 11,
                "air.fma.v3f32": 2,
                "air.sample_texture_2d.v4f16": 4,
            },
            cfg={
                "basicBlockCount": 4,
                "terminatorCounts": {"br": 2, "condbr": 1, "ret": 1},
                "phiCount": 1,
                "selectCount": 8,
            },
            instruction_families={
                "aggregate": 6,
                "arithmetic": 55,
                "call": 130,
                "cast": 17,
                "compare": 6,
                "intrinsic": 130,
                "memory": 84,
                "vector": 119,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_shared_cfg_split_merge_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.v4f32": 1,
                "air.convert.f.v2f32.f.v2f16": 6,
                "air.convert.f.v4f32.f.v4f16": 2,
                "air.dot.v4f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_rsqrt.f32": 1,
                "air.fast_sqrt.f32": 2,
                "air.fma.f32": 9,
                "air.fma.v2f32": 5,
                "air.fma.v4f32": 3,
                "air.sample_texture_2d.v4f16": 2,
            },
            entry_intrinsics={
                "air.clamp.v4f32": 1,
                "air.convert.f.v2f32.f.v2f16": 6,
                "air.convert.f.v4f32.f.v4f16": 2,
                "air.dot.v4f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_rsqrt.f32": 1,
                "air.fast_sqrt.f32": 2,
                "air.fma.f32": 9,
                "air.fma.v2f32": 5,
                "air.fma.v4f32": 3,
                "air.sample_texture_2d.v4f16": 2,
            },
            cfg={
                "basicBlockCount": 20,
                "terminatorCounts": {"br": 10, "condbr": 9, "ret": 1},
                "phiCount": 7,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 35,
                "call": 98,
                "cast": 3,
                "compare": 8,
                "intrinsic": 98,
                "memory": 44,
                "vector": 86,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.v4f32": 1,
                "air.convert.f.v2f32.f.v2f16": 6,
                "air.convert.f.v4f32.f.v4f16": 2,
                "air.dot.v4f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_rsqrt.f32": 1,
                "air.fast_sqrt.f32": 2,
                "air.fma.f32": 9,
                "air.fma.v2f32": 5,
                "air.fma.v4f32": 3,
                "air.sample_texture_2d.v4f16": 2,
            },
            entry_intrinsics={
                "air.clamp.v4f32": 1,
                "air.convert.f.v2f32.f.v2f16": 6,
                "air.convert.f.v4f32.f.v4f16": 2,
                "air.dot.v4f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_rsqrt.f32": 1,
                "air.fast_sqrt.f32": 2,
                "air.fma.f32": 9,
                "air.fma.v2f32": 5,
                "air.fma.v4f32": 3,
                "air.sample_texture_2d.v4f16": 2,
            },
            cfg={
                "basicBlockCount": 21,
                "terminatorCounts": {"br": 11, "condbr": 9, "ret": 1},
                "phiCount": 7,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 34,
                "call": 98,
                "cast": 3,
                "compare": 8,
                "intrinsic": 98,
                "memory": 44,
                "vector": 93,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_shared_cfg_split_merge_shape_drift_with_select_growth_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 10,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fast_cos.f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.fma.f16": 2,
                "air.fma.f32": 5,
                "air.fma.v2f32": 7,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 10,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fast_cos.f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.fma.f16": 2,
                "air.fma.f32": 5,
                "air.fma.v2f32": 7,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 8,
                "terminatorCounts": {"br": 3, "condbr": 4, "ret": 1},
                "phiCount": 2,
                "selectCount": 4,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 44,
                "call": 112,
                "cast": 5,
                "compare": 5,
                "intrinsic": 112,
                "memory": 52,
                "vector": 86,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 10,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fast_cos.f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.fma.f16": 2,
                "air.fma.f32": 5,
                "air.fma.v2f32": 7,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 10,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fast_cos.f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.f32": 1,
                "air.fast_fmin.f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.fma.f16": 2,
                "air.fma.f32": 5,
                "air.fma.v2f32": 7,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 9,
                "terminatorCounts": {"br": 4, "condbr": 4, "ret": 1},
                "phiCount": 2,
                "selectCount": 6,
            },
            instruction_families={
                "aggregate": 13,
                "arithmetic": 41,
                "call": 112,
                "cast": 5,
                "compare": 5,
                "intrinsic": 112,
                "memory": 52,
                "vector": 92,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_shared_cfg_split_merge_shape_drift_with_small_cast_reshaping_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 3,
                "air.convert.f.v3f32.f.v3f16": 5,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.exp2.v3f16": 2,
                "air.fast_clamp.v3f32": 1,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            entry_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 3,
                "air.convert.f.v3f32.f.v3f16": 5,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.exp2.v3f16": 2,
                "air.fast_clamp.v3f32": 1,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            cfg={
                "basicBlockCount": 8,
                "terminatorCounts": {"br": 4, "condbr": 3, "ret": 1},
                "phiCount": 3,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 31,
                "call": 62,
                "cast": 5,
                "compare": 4,
                "intrinsic": 62,
                "memory": 34,
                "vector": 64,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 3,
                "air.convert.f.v3f32.f.v3f16": 5,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.exp2.v3f16": 2,
                "air.fast_clamp.v3f32": 1,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            entry_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 3,
                "air.convert.f.v3f32.f.v3f16": 5,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.exp2.v3f16": 2,
                "air.fast_clamp.v3f32": 1,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            cfg={
                "basicBlockCount": 9,
                "terminatorCounts": {"br": 5, "condbr": 3, "ret": 1},
                "phiCount": 3,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 7,
                "arithmetic": 30,
                "call": 62,
                "cast": 3,
                "compare": 4,
                "intrinsic": 62,
                "memory": 34,
                "vector": 65,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_select_heavy_vector_memory_materialization_with_small_addrspace_bump_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.dot.v2f16": 3,
                "air.dot.v3f16": 4,
                "air.fma.f16": 2,
                "air.fma.f32": 1,
                "air.fma.v2f16": 2,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.f16": 1,
                "air.fmin.f16": 3,
                "air.rsqrt.f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.dot.v2f16": 3,
                "air.dot.v3f16": 4,
                "air.fma.f16": 2,
                "air.fma.f32": 1,
                "air.fma.v2f16": 2,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.f16": 1,
                "air.fmin.f16": 3,
                "air.rsqrt.f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 11,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 205,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 124,
                "vector": 299,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.dot.v2f16": 3,
                "air.dot.v3f16": 4,
                "air.fma.f16": 2,
                "air.fma.f32": 1,
                "air.fma.v2f16": 2,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.f16": 1,
                "air.fmin.f16": 3,
                "air.rsqrt.f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            entry_intrinsics={
                "air.clamp.f16": 1,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 6,
                "air.convert.f.v3f32.f.v3f16": 8,
                "air.dot.v2f16": 3,
                "air.dot.v3f16": 4,
                "air.fma.f16": 2,
                "air.fma.f32": 1,
                "air.fma.v2f16": 2,
                "air.fma.v3f16": 8,
                "air.fma.v3f32": 6,
                "air.fmax.f16": 1,
                "air.fmin.f16": 3,
                "air.rsqrt.f16": 2,
                "air.sample_texture_2d.v4f16": 6,
            },
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 17,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 188,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 128,
                "vector": 342,
            },
        )
        original["moduleAddressSpaces"] = {"1": 22, "2": 153}
        regenerated["moduleAddressSpaces"] = {"1": 22, "2": 157}

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["addressSpaceComparison"]["severity"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_select_heavy_vector_memory_materialization_when_addrspace_key_changes(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            entry_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 11,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 205,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 124,
                "vector": 299,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            entry_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 17,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 188,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 128,
                "vector": 342,
            },
        )
        original["moduleAddressSpaces"] = {"1": 22, "2": 153}
        regenerated["moduleAddressSpaces"] = {"1": 22, "2": 157, "3": 1}

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["addressSpaceComparison"]["severity"], "L2")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_downgrades_same_cfg_vector_memory_materialization_with_small_addrspace_bump_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            entry_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 11,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 205,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 124,
                "vector": 299,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            entry_intrinsics={"air.fma.v3f32": 6, "air.sample_texture_2d.v4f16": 6},
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 20, "condbr": 18, "ret": 1},
                "phiCount": 19,
                "selectCount": 11,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 188,
                "call": 351,
                "cast": 81,
                "compare": 19,
                "intrinsic": 351,
                "memory": 128,
                "vector": 324,
            },
        )
        original["moduleAddressSpaces"] = {"1": 22, "2": 153}
        regenerated["moduleAddressSpaces"] = {"1": 22, "2": 157}

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_small_scalar_vector_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 2,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 2,
                "air.convert.f.v3f32.f.v3f16": 4,
                "air.convert.f.v4f32.f.v4f16": 1,
                "air.dot.v3f32": 4,
                "air.fabs.f16": 1,
                "air.fast_fabs.f32": 3,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_fract.f32": 1,
                "air.fast_rsqrt.f32": 2,
                "air.fast_sqrt.f32": 2,
                "air.fma.f16": 3,
                "air.fma.f32": 6,
                "air.fma.v2f32": 4,
                "air.fma.v3f16": 3,
                "air.fma.v3f32": 6,
                "air.fma.v4f32": 3,
                "air.fmax.f16": 2,
                "air.fmax.v2f16": 1,
                "air.sample_texture_2d.v4f16": 2,
            },
            entry_intrinsics={
                "air.clamp.f16": 2,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 2,
                "air.convert.f.v3f32.f.v3f16": 4,
                "air.convert.f.v4f32.f.v4f16": 1,
                "air.dot.v3f32": 4,
                "air.fabs.f16": 1,
                "air.fast_fabs.f32": 3,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_fract.f32": 1,
                "air.fast_rsqrt.f32": 2,
                "air.fast_sqrt.f32": 2,
                "air.fma.f16": 3,
                "air.fma.f32": 6,
                "air.fma.v2f32": 4,
                "air.fma.v3f16": 3,
                "air.fma.v3f32": 6,
                "air.fma.v4f32": 3,
                "air.fmax.f16": 2,
                "air.fmax.v2f16": 1,
                "air.sample_texture_2d.v4f16": 2,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 48,
                "call": 65,
                "cast": 15,
                "compare": 2,
                "intrinsic": 65,
                "memory": 56,
                "vector": 83,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 2,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 2,
                "air.convert.f.v3f32.f.v3f16": 4,
                "air.convert.f.v4f32.f.v4f16": 1,
                "air.dot.v3f32": 4,
                "air.fabs.f16": 1,
                "air.fast_fabs.f32": 3,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_fract.f32": 1,
                "air.fast_rsqrt.f32": 2,
                "air.fast_sqrt.f32": 2,
                "air.fma.f16": 3,
                "air.fma.f32": 6,
                "air.fma.v2f32": 4,
                "air.fma.v3f16": 3,
                "air.fma.v3f32": 6,
                "air.fma.v4f32": 3,
                "air.fmax.f16": 2,
                "air.fmax.v2f16": 1,
                "air.sample_texture_2d.v4f16": 2,
            },
            entry_intrinsics={
                "air.clamp.f16": 2,
                "air.convert.f.v2f32.f.v2f16": 4,
                "air.convert.f.v3f16.f.v3f32": 2,
                "air.convert.f.v3f32.f.v3f16": 4,
                "air.convert.f.v4f32.f.v4f16": 1,
                "air.dot.v3f32": 4,
                "air.fabs.f16": 1,
                "air.fast_fabs.f32": 3,
                "air.fast_fmax.f32": 2,
                "air.fast_fmin.f32": 2,
                "air.fast_fract.f32": 1,
                "air.fast_rsqrt.f32": 2,
                "air.fast_sqrt.f32": 2,
                "air.fma.f16": 3,
                "air.fma.f32": 6,
                "air.fma.v2f32": 4,
                "air.fma.v3f16": 3,
                "air.fma.v3f32": 6,
                "air.fma.v4f32": 3,
                "air.fmax.f16": 2,
                "air.fmax.v2f16": 1,
                "air.sample_texture_2d.v4f16": 2,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 42,
                "call": 65,
                "cast": 15,
                "compare": 2,
                "intrinsic": 65,
                "memory": 56,
                "vector": 81,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_small_scalar_vector_materialization_drift_with_cast_reshaping_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 1,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.dot.v3f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 6,
                "air.fma.v3f32": 1,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 1,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.dot.v3f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 6,
                "air.fma.v3f32": 1,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 9,
                "terminatorCounts": {"br": 5, "condbr": 3, "ret": 1},
                "phiCount": 2,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 26,
                "call": 47,
                "cast": 5,
                "compare": 4,
                "intrinsic": 47,
                "memory": 24,
                "vector": 53,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 1,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.dot.v3f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 6,
                "air.fma.v3f32": 1,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 6,
                "air.clamp.v2f16": 1,
                "air.convert.f.v2f32.f.v2f16": 1,
                "air.convert.f.v3f16.f.v3f32": 1,
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.convert.u.v2i32.f.v2f32": 1,
                "air.dot.v3f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_floor.v2f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_sin.f32": 1,
                "air.floor.v2f16": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 1,
                "air.fma.v2f16": 3,
                "air.fma.v3f16": 6,
                "air.fma.v3f32": 1,
                "air.fmax.v2f16": 1,
                "air.fmax.v3f16": 2,
                "air.fmin.f16": 3,
                "air.fmin.v2f16": 1,
                "air.log2.v3f16": 2,
                "air.sample_texture_2d.v4f16": 3,
            },
            cfg={
                "basicBlockCount": 9,
                "terminatorCounts": {"br": 5, "condbr": 3, "ret": 1},
                "phiCount": 2,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 4,
                "arithmetic": 25,
                "call": 47,
                "cast": 3,
                "compare": 4,
                "intrinsic": 47,
                "memory": 24,
                "vector": 52,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_wider_scalar_vector_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 2,
                "air.clamp.v2f16": 2,
                "air.convert.f.v2f16.f.v2f32": 1,
                "air.convert.f.v2f32.f.v2f16": 5,
                "air.convert.f.v3f16.f.v3f32": 11,
                "air.convert.f.v3f32.f.v3f16": 23,
                "air.discard_fragment": 1,
                "air.dot.v3f16": 6,
                "air.dot.v3f32": 2,
                "air.exp2.f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_cos.v3f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.v2f32": 1,
                "air.fast_fmax.v3f32": 1,
                "air.fast_fmin.v3f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_log2.v3f32": 2,
                "air.fast_sin.v3f32": 1,
                "air.fast_sqrt.f32": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 2,
                "air.fma.v2f16": 3,
                "air.fma.v2f32": 2,
                "air.fma.v3f16": 15,
                "air.fma.v3f32": 11,
                "air.fmax.f16": 3,
                "air.fmax.v3f16": 2,
                "air.fmin.v3f16": 1,
                "air.log2.f16": 1,
                "air.rsqrt.f16": 4,
                "air.sample_texture_2d.v4f16": 11,
                "air.sqrt.v3f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 2,
                "air.clamp.v2f16": 2,
                "air.convert.f.v2f16.f.v2f32": 1,
                "air.convert.f.v2f32.f.v2f16": 5,
                "air.convert.f.v3f16.f.v3f32": 11,
                "air.convert.f.v3f32.f.v3f16": 23,
                "air.discard_fragment": 1,
                "air.dot.v3f16": 6,
                "air.dot.v3f32": 2,
                "air.exp2.f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_cos.v3f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.v2f32": 1,
                "air.fast_fmax.v3f32": 1,
                "air.fast_fmin.v3f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_log2.v3f32": 2,
                "air.fast_sin.v3f32": 1,
                "air.fast_sqrt.f32": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 2,
                "air.fma.v2f16": 3,
                "air.fma.v2f32": 2,
                "air.fma.v3f16": 15,
                "air.fma.v3f32": 11,
                "air.fmax.f16": 3,
                "air.fmax.v3f16": 2,
                "air.fmin.v3f16": 1,
                "air.log2.f16": 1,
                "air.rsqrt.f16": 4,
                "air.sample_texture_2d.v4f16": 11,
                "air.sqrt.v3f16": 3,
            },
            cfg={
                "basicBlockCount": 17,
                "terminatorCounts": {"br": 9, "condbr": 7, "ret": 1},
                "phiCount": 6,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 53,
                "call": 129,
                "cast": 8,
                "compare": 8,
                "intrinsic": 129,
                "memory": 78,
                "vector": 127,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.clamp.f16": 2,
                "air.clamp.v2f16": 2,
                "air.convert.f.v2f16.f.v2f32": 1,
                "air.convert.f.v2f32.f.v2f16": 5,
                "air.convert.f.v3f16.f.v3f32": 11,
                "air.convert.f.v3f32.f.v3f16": 23,
                "air.discard_fragment": 1,
                "air.dot.v3f16": 6,
                "air.dot.v3f32": 2,
                "air.exp2.f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_cos.v3f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.v2f32": 1,
                "air.fast_fmax.v3f32": 1,
                "air.fast_fmin.v3f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_log2.v3f32": 2,
                "air.fast_sin.v3f32": 1,
                "air.fast_sqrt.f32": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 2,
                "air.fma.v2f16": 3,
                "air.fma.v2f32": 2,
                "air.fma.v3f16": 15,
                "air.fma.v3f32": 11,
                "air.fmax.f16": 3,
                "air.fmax.v3f16": 2,
                "air.fmin.v3f16": 1,
                "air.log2.f16": 1,
                "air.rsqrt.f16": 4,
                "air.sample_texture_2d.v4f16": 11,
                "air.sqrt.v3f16": 3,
            },
            entry_intrinsics={
                "air.clamp.f16": 2,
                "air.clamp.v2f16": 2,
                "air.convert.f.v2f16.f.v2f32": 1,
                "air.convert.f.v2f32.f.v2f16": 5,
                "air.convert.f.v3f16.f.v3f32": 11,
                "air.convert.f.v3f32.f.v3f16": 23,
                "air.discard_fragment": 1,
                "air.dot.v3f16": 6,
                "air.dot.v3f32": 2,
                "air.exp2.f16": 1,
                "air.exp2.v3f16": 2,
                "air.fast_cos.v3f32": 1,
                "air.fast_fabs.f32": 1,
                "air.fast_fmax.v2f32": 1,
                "air.fast_fmax.v3f32": 1,
                "air.fast_fmin.v3f32": 1,
                "air.fast_fract.f32": 1,
                "air.fast_log2.v3f32": 2,
                "air.fast_sin.v3f32": 1,
                "air.fast_sqrt.f32": 1,
                "air.fma.f16": 5,
                "air.fma.f32": 2,
                "air.fma.v2f16": 3,
                "air.fma.v2f32": 2,
                "air.fma.v3f16": 15,
                "air.fma.v3f32": 11,
                "air.fmax.f16": 3,
                "air.fmax.v3f16": 2,
                "air.fmin.v3f16": 1,
                "air.log2.f16": 1,
                "air.rsqrt.f16": 4,
                "air.sample_texture_2d.v4f16": 11,
                "air.sqrt.v3f16": 3,
            },
            cfg={
                "basicBlockCount": 17,
                "terminatorCounts": {"br": 9, "condbr": 7, "ret": 1},
                "phiCount": 6,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 47,
                "call": 129,
                "cast": 8,
                "compare": 8,
                "intrinsic": 129,
                "memory": 78,
                "vector": 132,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_scalar_vector_materialization_drift_with_high_arithmetic_tradeoff_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 85,
                "call": 93,
                "cast": 29,
                "compare": 2,
                "intrinsic": 93,
                "memory": 88,
                "vector": 143,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 76,
                "call": 93,
                "cast": 29,
                "compare": 2,
                "intrinsic": 93,
                "memory": 88,
                "vector": 141,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_same_cfg_arithmetic_heavy_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 186,
                "call": 316,
                "cast": 57,
                "compare": 4,
                "intrinsic": 316,
                "memory": 176,
                "vector": 364,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 160,
                "call": 316,
                "cast": 57,
                "compare": 4,
                "intrinsic": 316,
                "memory": 176,
                "vector": 368,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_same_cfg_arithmetic_heavy_materialization_with_cast_drift(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 1,
                "arithmetic": 186,
                "call": 316,
                "cast": 57,
                "compare": 4,
                "intrinsic": 316,
                "memory": 176,
                "vector": 364,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 12,
                "arithmetic": 160,
                "call": 316,
                "cast": 58,
                "compare": 4,
                "intrinsic": 316,
                "memory": 176,
                "vector": 368,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_downgrades_same_cfg_vector_heavy_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 222,
                "call": 411,
                "cast": 82,
                "compare": 10,
                "intrinsic": 411,
                "memory": 168,
                "vector": 363,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 202,
                "call": 411,
                "cast": 82,
                "compare": 10,
                "intrinsic": 411,
                "memory": 168,
                "vector": 381,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_same_cfg_vector_heavy_materialization_outside_window(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 222,
                "call": 411,
                "cast": 82,
                "compare": 10,
                "intrinsic": 411,
                "memory": 168,
                "vector": 363,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 10,
                "arithmetic": 202,
                "call": 411,
                "cast": 82,
                "compare": 10,
                "intrinsic": 411,
                "memory": 168,
                "vector": 394,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_downgrades_select_heavy_vector_materialization_drift_with_shared_cfg_skeleton_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 12,
                "terminatorCounts": {"br": 2, "condbr": 5, "ret": 5},
                "phiCount": 4,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 4,
                "arithmetic": 62,
                "call": 154,
                "cast": 26,
                "compare": 17,
                "intrinsic": 154,
                "memory": 121,
                "vector": 119,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 12,
                "terminatorCounts": {"br": 2, "condbr": 5, "ret": 5},
                "phiCount": 4,
                "selectCount": 14,
            },
            instruction_families={
                "aggregate": 4,
                "arithmetic": 55,
                "call": 154,
                "cast": 26,
                "compare": 17,
                "intrinsic": 154,
                "memory": 121,
                "vector": 153,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_single_block_select_heavy_vector_materialization_drift_to_l1(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 16,
                "arithmetic": 51,
                "call": 125,
                "cast": 9,
                "compare": 1,
                "intrinsic": 125,
                "memory": 12,
                "vector": 179,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 6,
            },
            instruction_families={
                "aggregate": 16,
                "arithmetic": 28,
                "call": 125,
                "cast": 9,
                "compare": 1,
                "intrinsic": 125,
                "memory": 12,
                "vector": 215,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_single_block_select_heavy_vector_materialization_drift_outside_arithmetic_window(
        self,
    ) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 2,
            },
            instruction_families={
                "aggregate": 16,
                "arithmetic": 51,
                "call": 125,
                "cast": 9,
                "compare": 1,
                "intrinsic": 125,
                "memory": 12,
                "vector": 179,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.gather_texture_2d.v4f32": 2,
                "air.sample_texture_2d.v4f32": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 6,
            },
            instruction_families={
                "aggregate": 16,
                "arithmetic": 26,
                "call": 125,
                "cast": 9,
                "compare": 1,
                "intrinsic": 125,
                "memory": 12,
                "vector": 215,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_keeps_l2_for_select_heavy_vector_materialization_drift_outside_select_window(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 12,
                "terminatorCounts": {"br": 2, "condbr": 5, "ret": 5},
                "phiCount": 4,
                "selectCount": 7,
            },
            instruction_families={
                "aggregate": 4,
                "arithmetic": 62,
                "call": 154,
                "cast": 26,
                "compare": 17,
                "intrinsic": 154,
                "memory": 121,
                "vector": 119,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 2,
                "air.fma.v3f32": 5,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 12,
                "terminatorCounts": {"br": 2, "condbr": 5, "ret": 5},
                "phiCount": 4,
                "selectCount": 16,
            },
            instruction_families={
                "aggregate": 4,
                "arithmetic": 55,
                "call": 154,
                "cast": 26,
                "compare": 17,
                "intrinsic": 154,
                "memory": 121,
                "vector": 153,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_downgrades_outer_merge_self_loop_materialization_drift_to_l1(self) -> None:
        module_intrinsics = {
            "air.convert.f.v3f32.f.v3f16": 14,
            "air.dot.v2f32": 4,
            "air.fast_clamp.v2f32": 2,
            "air.fast_exp2.v2f32": 2,
            "air.fast_exp2.v3f32": 2,
            "air.fast_fabs.f32": 4,
            "air.fast_fmax.f32": 8,
            "air.fast_fmax.v2f32": 2,
            "air.fast_fmin.f32": 4,
            "air.fast_sqrt.f32": 6,
            "air.fast_sqrt.v2f32": 2,
            "air.fma.f32": 18,
            "air.fma.v2f32": 8,
            "air.fma.v3f32": 12,
            "air.sample_texture_2d.v4f16": 4,
        }
        original = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 14,
                "terminatorCounts": {"br": 4, "condbr": 9, "ret": 1},
                "phiCount": 22,
                "selectCount": 52,
            },
            instruction_families={
                "aggregate": 5,
                "arithmetic": 126,
                "call": 129,
                "compare": 29,
                "intrinsic": 129,
                "memory": 72,
                "vector": 175,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 17, "condbr": 21, "ret": 1},
                "phiCount": 54,
                "selectCount": 42,
            },
            instruction_families={
                "aggregate": 5,
                "arithmetic": 115,
                "call": 129,
                "compare": 29,
                "intrinsic": 129,
                "memory": 72,
                "vector": 177,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_downgrades_moderate_cfg_vector_materialization_drift_to_l1(self) -> None:
        module_intrinsics = {
            "air.clamp.f16": 1,
            "air.convert.f.v2f32.f.v2f16": 3,
            "air.convert.f.v3f16.f.v3f32": 11,
            "air.convert.f.v3f32.f.v3f16": 19,
            "air.convert.f.v4f32.f.v4f16": 1,
            "air.convert.s.i32.f.f32": 4,
            "air.convert.u.i32.f.f32": 4,
            "air.dot.v2f16": 1,
            "air.dot.v3f16": 4,
            "air.dot.v3f32": 28,
            "air.dot.v4f16": 10,
            "air.exp2.f16": 1,
            "air.fast_clamp.f32": 9,
            "air.fast_floor.v4f32": 1,
            "air.fast_fmax.f32": 17,
            "air.fast_fmax.v2f32": 1,
            "air.fast_fmin.f32": 12,
            "air.fast_rsqrt.f32": 10,
            "air.fma.f16": 12,
            "air.fma.f32": 25,
            "air.fma.v2f16": 1,
            "air.fma.v2f32": 1,
            "air.fma.v3f16": 9,
            "air.fma.v3f32": 12,
            "air.fma.v4f16": 1,
            "air.fma.v4f32": 1,
            "air.fmax.f16": 8,
            "air.fmax.v2f16": 1,
            "air.fmax.v3f16": 1,
            "air.fmin.f16": 3,
            "air.log2.f16": 1,
            "air.rsqrt.f16": 2,
            "air.sample_texture_2d.v4f16": 5,
            "air.sample_texture_cube.v4f16": 1,
            "air.sqrt.f16": 1,
        }
        original = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 28,
                "terminatorCounts": {"br": 14, "condbr": 13, "ret": 1},
                "phiCount": 15,
                "selectCount": 5,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 140,
                "call": 222,
                "cast": 69,
                "compare": 15,
                "intrinsic": 222,
                "memory": 92,
                "vector": 202,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 36,
                "terminatorCounts": {"br": 18, "condbr": 17, "ret": 1},
                "phiCount": 19,
                "selectCount": 1,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 129,
                "call": 222,
                "cast": 69,
                "compare": 15,
                "intrinsic": 222,
                "memory": 92,
                "vector": 215,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L1")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L1")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L1")

    def test_compare_keeps_l2_for_moderate_cfg_vector_materialization_drift_outside_cfg_window(self) -> None:
        module_intrinsics = {
            "air.clamp.f16": 1,
            "air.convert.f.v2f32.f.v2f16": 3,
            "air.convert.f.v3f16.f.v3f32": 11,
            "air.convert.f.v3f32.f.v3f16": 19,
            "air.convert.f.v4f32.f.v4f16": 1,
            "air.convert.s.i32.f.f32": 4,
            "air.convert.u.i32.f.f32": 4,
            "air.dot.v2f16": 1,
            "air.dot.v3f16": 4,
            "air.dot.v3f32": 28,
            "air.dot.v4f16": 10,
            "air.exp2.f16": 1,
            "air.fast_clamp.f32": 9,
            "air.fast_floor.v4f32": 1,
            "air.fast_fmax.f32": 17,
            "air.fast_fmax.v2f32": 1,
            "air.fast_fmin.f32": 12,
            "air.fast_rsqrt.f32": 10,
            "air.fma.f16": 12,
            "air.fma.f32": 25,
            "air.fma.v2f16": 1,
            "air.fma.v2f32": 1,
            "air.fma.v3f16": 9,
            "air.fma.v3f32": 12,
            "air.fma.v4f16": 1,
            "air.fma.v4f32": 1,
            "air.fmax.f16": 8,
            "air.fmax.v2f16": 1,
            "air.fmax.v3f16": 1,
            "air.fmin.f16": 3,
            "air.log2.f16": 1,
            "air.rsqrt.f16": 2,
            "air.sample_texture_2d.v4f16": 5,
            "air.sample_texture_cube.v4f16": 1,
            "air.sqrt.f16": 1,
        }
        original = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 28,
                "terminatorCounts": {"br": 14, "condbr": 13, "ret": 1},
                "phiCount": 15,
                "selectCount": 5,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 140,
                "call": 222,
                "cast": 69,
                "compare": 15,
                "intrinsic": 222,
                "memory": 92,
                "vector": 202,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 41,
                "terminatorCounts": {"br": 20, "condbr": 19, "ret": 1},
                "phiCount": 21,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 8,
                "arithmetic": 129,
                "call": 222,
                "cast": 69,
                "compare": 15,
                "intrinsic": 222,
                "memory": 92,
                "vector": 215,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L2")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_keeps_l2_for_outer_merge_self_loop_materialization_drift_when_phi_growth_is_too_small(self) -> None:
        module_intrinsics = {
            "air.convert.f.v3f32.f.v3f16": 14,
            "air.dot.v2f32": 4,
            "air.fast_clamp.v2f32": 2,
            "air.fast_exp2.v2f32": 2,
            "air.fast_exp2.v3f32": 2,
            "air.fast_fabs.f32": 4,
            "air.fast_fmax.f32": 8,
            "air.fast_fmax.v2f32": 2,
            "air.fast_fmin.f32": 4,
            "air.fast_sqrt.f32": 6,
            "air.fast_sqrt.v2f32": 2,
            "air.fma.f32": 18,
            "air.fma.v2f32": 8,
            "air.fma.v3f32": 12,
            "air.sample_texture_2d.v4f16": 4,
        }
        original = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 14,
                "terminatorCounts": {"br": 4, "condbr": 9, "ret": 1},
                "phiCount": 22,
                "selectCount": 52,
            },
            instruction_families={
                "aggregate": 5,
                "arithmetic": 126,
                "call": 129,
                "compare": 29,
                "intrinsic": 129,
                "memory": 72,
                "vector": 175,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics=module_intrinsics,
            entry_intrinsics=module_intrinsics,
            cfg={
                "basicBlockCount": 39,
                "terminatorCounts": {"br": 17, "condbr": 21, "ret": 1},
                "phiCount": 38,
                "selectCount": 42,
            },
            instruction_families={
                "aggregate": 5,
                "arithmetic": 115,
                "call": 129,
                "compare": 29,
                "intrinsic": 129,
                "memory": 72,
                "vector": 177,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L2")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_compare_keeps_l2_for_large_scalar_vector_materialization_drift(self) -> None:
        original = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 3,
                "arithmetic": 57,
                "call": 73,
                "cast": 6,
                "compare": 7,
                "intrinsic": 73,
                "memory": 52,
                "vector": 102,
            },
        )
        regenerated = self._make_optimizer_drift_summary(
            module_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            entry_intrinsics={
                "air.convert.f.v3f32.f.v3f16": 3,
                "air.fma.v3f32": 4,
                "air.sample_texture_2d.v4f16": 1,
            },
            cfg={
                "basicBlockCount": 1,
                "terminatorCounts": {"ret": 1},
                "phiCount": 0,
                "selectCount": 0,
            },
            instruction_families={
                "aggregate": 24,
                "arithmetic": 40,
                "call": 73,
                "cast": 6,
                "compare": 7,
                "intrinsic": 73,
                "memory": 52,
                "vector": 110,
            },
        )

        comparison = canonical_compare.compare_ir_summaries(original, regenerated)

        self.assertEqual(comparison["riskLevel"], "L2")
        self.assertEqual(comparison["cfgComparison"]["severity"], "L0")
        self.assertEqual(comparison["instructionFamilyComparison"]["severity"], "L2")

    def test_assess_gate_result_warns_for_known_debt(self) -> None:
        samples = [
            {
                "comparisonKey": "explicit_ll:/tmp/test_struct_array_field.ll",
                "inputPath": "/tmp/test_struct_array_field.ll",
                "roundTripStatus": "failed",
                "failureStage": "compile",
                "riskLevel": "L3",
            },
            {
                "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
                "inputPath": "/tmp/test_casts.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L2",
            },
        ]
        roundtrip_report = make_roundtrip_report(job_count=2, roundtrip_failed_jobs=1, compile_failed_jobs=1)
        risk_report = make_risk_report(
            samples=samples,
            blocked_samples=[],
            l2_samples=[samples[1]],
        )

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 2,
                "allowedFailureSamples": {"test_struct_array_field": "compile"},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": ["test_casts"],
            },
            profile_name="test-data-representatives",
        )

        self.assertEqual(summary["status"], "warn")
        self.assertFalse(summary["shouldBlock"])
        self.assertIn("test_struct_array_field", summary["activeKnownDebt"]["failureSampleKeys"])
        self.assertIn("test_casts", summary["activeKnownDebt"]["l2SampleKeys"])

    def test_assess_gate_result_warns_when_job_count_is_below_preferred_but_within_allowed_range(self) -> None:
        samples = [
            {
                "comparisonKey": f"explicit_ll:/tmp/sample_{index}.ll",
                "inputPath": f"/tmp/sample_{index}.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L0",
            }
            for index in range(8)
        ]
        roundtrip_report = make_roundtrip_report(job_count=8)
        risk_report = make_risk_report(samples=samples, blocked_samples=[], l2_samples=[])

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "minimumExpectedJobCount": 8,
                "expectedJobCount": 13,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
            profile_name="daily-default",
        )

        self.assertEqual(summary["status"], "warn")
        self.assertFalse(summary["shouldBlock"])
        self.assertEqual(summary["jobCountStatus"], "below_preferred")
        self.assertIsNone(summary["regressions"]["jobCountMismatch"])
        self.assertEqual(summary["jobCountWarning"]["actualJobCount"], 8)

    def test_assess_gate_result_fails_when_job_count_drops_below_minimum_boundary(self) -> None:
        samples = [
            {
                "comparisonKey": f"explicit_ll:/tmp/sample_{index}.ll",
                "inputPath": f"/tmp/sample_{index}.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L0",
            }
            for index in range(7)
        ]
        roundtrip_report = make_roundtrip_report(job_count=7)
        risk_report = make_risk_report(samples=samples, blocked_samples=[], l2_samples=[])

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "minimumExpectedJobCount": 8,
                "expectedJobCount": 13,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
            profile_name="daily-default",
        )

        self.assertEqual(summary["status"], "fail")
        self.assertTrue(summary["shouldBlock"])
        self.assertEqual(summary["jobCountStatus"], "out_of_range")
        self.assertEqual(summary["regressions"]["jobCountMismatch"]["reason"], "below_minimum")

    def test_assess_gate_result_fails_for_unexpected_blocked_sample(self) -> None:
        blocked_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_new_regression.ll",
            "inputPath": "/tmp/test_new_regression.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L3",
        }
        roundtrip_report = make_roundtrip_report(job_count=1)
        risk_report = make_risk_report(
            samples=[blocked_sample],
            blocked_samples=[blocked_sample],
            l2_samples=[],
        )

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 1,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
        )

        self.assertEqual(summary["status"], "fail")
        self.assertTrue(summary["shouldBlock"])
        self.assertIn("test_new_regression", summary["regressions"]["unexpectedBlockedSampleKeys"])

    def test_sample_identity_prefers_bundle_and_module_then_input_stem(self) -> None:
        self.assertEqual(
            canonical_compare.sample_identity(
                {
                    "bundleId": "com.example.game",
                    "moduleKey": "abc123",
                }
            ),
            "bundle:com.example.game::module:abc123",
        )
        self.assertEqual(
            canonical_compare.sample_identity(
                {
                    "moduleKey": "module-only",
                }
            ),
            "module:module-only",
        )
        self.assertEqual(
            canonical_compare.sample_identity(
                {
                    "inputPath": "/tmp/test_sample.ll",
                }
            ),
            "test_sample",
        )

    def test_sample_identity_qualifies_shader_source_diagnostics_samples(self) -> None:
        self.assertEqual(
            canonical_compare.sample_identity(
                {
                    "sourceKind": "shader_source_diagnostics",
                    "bundleId": "com.example.game",
                    "moduleKey": "abc123",
                }
            ),
            "shaderSourceDiagnostics::bundle:com.example.game::module:abc123",
        )
        self.assertEqual(
            canonical_compare.sample_identity(
                {
                    "sourceKind": "shader_source_diagnostics",
                    "inputPath": "/tmp/test_sample.ll",
                }
            ),
            "shaderSourceDiagnostics::test_sample",
        )

    def test_assess_gate_result_keeps_shader_corpus_and_diagnostics_samples_distinct(self) -> None:
        corpus_sample = {
            "sourceKind": "shader_corpus",
            "comparisonKey": "bundle:com.example.game::module:abc123",
            "bundleId": "com.example.game",
            "moduleKey": "abc123",
            "inputPath": "/tmp/corpus-module.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L0",
        }
        diagnostics_sample = {
            "sourceKind": "shader_source_diagnostics",
            "comparisonKey": "shaderSourceDiagnostics::bundle:com.example.game::module:abc123",
            "bundleId": "com.example.game",
            "moduleKey": "abc123",
            "inputPath": "/tmp/diagnostics-module.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L3",
        }
        roundtrip_report = make_roundtrip_report(job_count=2)
        risk_report = make_risk_report(
            samples=[corpus_sample, diagnostics_sample],
            blocked_samples=[diagnostics_sample],
            l2_samples=[],
        )

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 2,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
        )

        self.assertEqual(
            summary["observed"]["sampleKeys"],
            [
                "bundle:com.example.game::module:abc123",
                "shaderSourceDiagnostics::bundle:com.example.game::module:abc123",
            ],
        )
        self.assertEqual(
            summary["regressions"]["unexpectedBlockedSampleKeys"],
            ["shaderSourceDiagnostics::bundle:com.example.game::module:abc123"],
        )

    def test_assess_gate_result_passes_when_all_samples_stay_within_boundary(self) -> None:
        sample = {
            "comparisonKey": "explicit_ll:/tmp/test_ok.ll",
            "inputPath": "/tmp/test_ok.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L0",
        }
        roundtrip_report = make_roundtrip_report(job_count=1)
        risk_report = make_risk_report(samples=[sample], blocked_samples=[], l2_samples=[])

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 1,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
            profile_name="test-data-representatives",
        )

        self.assertEqual(summary["status"], "pass")
        self.assertFalse(summary["shouldBlock"])
        self.assertEqual(summary["jobCountStatus"], "match")
        self.assertEqual(summary["observed"]["sampleKeys"], ["test_ok"])

    def test_assess_gate_result_reports_resolved_known_debt(self) -> None:
        samples = [
            {
                "comparisonKey": "explicit_ll:/tmp/test_struct_array_field.ll",
                "inputPath": "/tmp/test_struct_array_field.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L0",
            },
            {
                "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
                "inputPath": "/tmp/test_casts.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L0",
            },
        ]
        roundtrip_report = make_roundtrip_report(job_count=2)
        risk_report = make_risk_report(samples=samples, blocked_samples=[], l2_samples=[])

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 2,
                "allowedFailureSamples": {"test_struct_array_field": "compile"},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": ["test_casts"],
            },
            profile_name="test-data-representatives",
        )

        self.assertEqual(summary["status"], "pass")
        self.assertIn("test_struct_array_field", summary["improvements"]["resolvedFailureSampleKeys"])
        self.assertIn("test_casts", summary["improvements"]["resolvedL2SampleKeys"])
        self.assertTrue(any("known failure resolved" in note for note in summary["notes"]))
        self.assertTrue(any("known L2 sample improved" in note for note in summary["notes"]))

    def test_assess_gate_result_fails_when_job_count_exceeds_expected_boundary(self) -> None:
        samples = [
            {
                "comparisonKey": f"explicit_ll:/tmp/sample_{index}.ll",
                "inputPath": f"/tmp/sample_{index}.ll",
                "roundTripStatus": "success",
                "failureStage": None,
                "riskLevel": "L0",
            }
            for index in range(2)
        ]
        roundtrip_report = make_roundtrip_report(job_count=2)
        risk_report = make_risk_report(samples=samples, blocked_samples=[], l2_samples=[])

        summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "minimumExpectedJobCount": 1,
                "expectedJobCount": 1,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
        )

        self.assertEqual(summary["status"], "fail")
        self.assertTrue(summary["shouldBlock"])
        self.assertEqual(summary["jobCountStatus"], "out_of_range")
        self.assertEqual(summary["regressions"]["jobCountMismatch"]["reason"], "above_expected")

    def test_assess_layered_validation_decision_promotes_known_l2_candidates(self) -> None:
        blocked_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_struct_array_field.ll",
            "inputPath": "/tmp/test_struct_array_field.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L3",
            "riskReason": "entry signature changed",
        }
        l2_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
            "inputPath": "/tmp/test_casts.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L2",
            "riskReason": "intrinsic usage changed",
            "recommendedAction": "优先进入 L3 最小行为测试，不建议直接跳到 live 验证。",
        }
        roundtrip_report = make_roundtrip_report(job_count=2)
        risk_report = make_risk_report(
            samples=[blocked_sample, l2_sample],
            blocked_samples=[blocked_sample],
            l2_samples=[l2_sample],
        )
        gate_summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 2,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": ["test_struct_array_field"],
                "allowedL2SampleKeys": ["test_casts"],
            },
            profile_name="test-data-representatives",
        )

        layered = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)

        self.assertEqual(layered["overallDecision"], "promote_l2_candidates_to_l3")
        self.assertEqual(layered["l3Plan"]["decision"], "promote_selected_samples")
        self.assertEqual(layered["l3Plan"]["candidateSampleKeys"], ["test_casts"])
        self.assertEqual(layered["blockedSampleKeys"], ["test_struct_array_field"])
        self.assertEqual(layered["l4Plan"]["decision"], "defer")

    def test_assess_layered_validation_decision_uses_matching_behavior_summary_as_l3_evidence(self) -> None:
        l2_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
            "inputPath": "/tmp/test_casts.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L2",
            "riskReason": "intrinsic usage changed",
            "recommendedAction": "优先进入 L3 最小行为测试，不建议直接跳到 live 验证。",
        }
        risk_report = make_risk_report(samples=[l2_sample], blocked_samples=[], l2_samples=[l2_sample])

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "roundtrip" / "test-data-representatives"
            roundtrip_report_path = output_root / "roundtrip-summary.json"
            candidate_source_path = output_root / "generated-sources" / "test_casts.generated.metal"
            write_json(
                roundtrip_report_path,
                {
                    "results": [
                        {
                            "comparisonKey": l2_sample["comparisonKey"],
                            "inputPath": l2_sample["inputPath"],
                            "generatedMSLPath": str(candidate_source_path),
                        }
                    ]
                },
            )
            write_json(
                output_root / "behavior-summary.json",
                {
                    "outputRoot": str(output_root),
                    "roundtripReportPath": str(roundtrip_report_path),
                    "readySamples": [
                        {
                            "sampleKey": "test_casts",
                            "candidateSourcePath": str(candidate_source_path),
                        }
                    ],
                    "executedSamples": [
                        {
                            "sampleKey": "test_casts",
                            "status": "pass",
                        }
                    ],
                },
            )
            gate_summary = canonical_compare.assess_gate_result(
                make_roundtrip_report(job_count=1),
                risk_report,
                gate_profile={
                    "expectedJobCount": 1,
                    "allowedFailureSamples": {},
                    "allowedBlockedSampleKeys": [],
                    "allowedL2SampleKeys": ["test_casts"],
                },
                profile_name="test-data-representatives",
            )
            gate_summary.update(
                {
                    "outputRoot": str(output_root),
                    "roundtripReportPath": str(roundtrip_report_path),
                }
            )

            layered = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)

        self.assertEqual(layered["l4Plan"]["behaviorEvidenceSampleKeys"], ["test_casts"])
        self.assertEqual(layered["l4Plan"]["missingBehaviorEvidenceSampleKeys"], [])
        self.assertEqual(layered["l4Plan"]["blockingReasons"], ["no runtime-only trigger is present in the current offline reports"])

    def test_assess_layered_validation_decision_ignores_mismatched_behavior_summary(self) -> None:
        l2_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
            "inputPath": "/tmp/test_casts.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L2",
            "riskReason": "intrinsic usage changed",
        }
        risk_report = make_risk_report(samples=[l2_sample], blocked_samples=[], l2_samples=[l2_sample])

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "roundtrip" / "test-data-representatives"
            roundtrip_report_path = output_root / "roundtrip-summary.json"
            candidate_source_path = output_root / "generated-sources" / "test_casts.generated.metal"
            write_json(
                roundtrip_report_path,
                {
                    "results": [
                        {
                            "comparisonKey": l2_sample["comparisonKey"],
                            "inputPath": l2_sample["inputPath"],
                            "generatedMSLPath": str(candidate_source_path),
                        }
                    ]
                },
            )
            write_json(
                output_root / "behavior-summary.json",
                {
                    "outputRoot": str(output_root),
                    "roundtripReportPath": str(output_root / "stale-roundtrip-summary.json"),
                    "readySamples": [
                        {
                            "sampleKey": "test_casts",
                            "candidateSourcePath": str(candidate_source_path),
                        }
                    ],
                    "executedSamples": [
                        {
                            "sampleKey": "test_casts",
                            "status": "pass",
                        }
                    ],
                },
            )
            gate_summary = canonical_compare.assess_gate_result(
                make_roundtrip_report(job_count=1),
                risk_report,
                gate_profile={
                    "expectedJobCount": 1,
                    "allowedFailureSamples": {},
                    "allowedBlockedSampleKeys": [],
                    "allowedL2SampleKeys": ["test_casts"],
                },
                profile_name="test-data-representatives",
            )
            gate_summary.update(
                {
                    "outputRoot": str(output_root),
                    "roundtripReportPath": str(roundtrip_report_path),
                }
            )

            layered = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)

        self.assertEqual(layered["l4Plan"]["behaviorEvidenceSampleKeys"], [])
        self.assertEqual(layered["l4Plan"]["missingBehaviorEvidenceSampleKeys"], ["test_casts"])
        self.assertIn("L3 behavior evidence is still missing for active L2 candidates: test_casts", layered["l4Plan"]["blockingReasons"])

    def test_assess_layered_validation_decision_defers_new_l2_samples_for_review(self) -> None:
        l2_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_new_l2.ll",
            "inputPath": "/tmp/test_new_l2.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L2",
            "riskReason": "new semantic drift",
        }
        roundtrip_report = make_roundtrip_report(job_count=1)
        risk_report = make_risk_report(samples=[l2_sample], blocked_samples=[], l2_samples=[l2_sample])
        gate_summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 1,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": [],
            },
            profile_name="test-data-representatives",
        )

        layered = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)

        self.assertEqual(layered["overallDecision"], "stay_at_l2")
        self.assertEqual(layered["stopAtL2"]["decision"], "review_new_l2")
        self.assertEqual(layered["l3Plan"]["decision"], "defer")
        self.assertEqual(layered["l3Plan"]["deferredCandidateSampleKeys"], ["test_new_l2"])
        self.assertEqual(layered["stopAtL2"]["unexpectedL2SampleKeys"], ["test_new_l2"])

    def test_assess_layered_validation_decision_blocks_l3_and_l4_when_gate_fails(self) -> None:
        blocked_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_new_regression.ll",
            "inputPath": "/tmp/test_new_regression.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L3",
            "riskReason": "entry set changed",
        }
        l2_sample = {
            "comparisonKey": "explicit_ll:/tmp/test_casts.ll",
            "inputPath": "/tmp/test_casts.ll",
            "roundTripStatus": "success",
            "failureStage": None,
            "riskLevel": "L2",
            "riskReason": "intrinsic usage changed",
        }
        roundtrip_report = make_roundtrip_report(job_count=2)
        risk_report = make_risk_report(
            samples=[blocked_sample, l2_sample],
            blocked_samples=[blocked_sample],
            l2_samples=[l2_sample],
        )
        gate_summary = canonical_compare.assess_gate_result(
            roundtrip_report,
            risk_report,
            gate_profile={
                "expectedJobCount": 2,
                "allowedFailureSamples": {},
                "allowedBlockedSampleKeys": [],
                "allowedL2SampleKeys": ["test_casts"],
            },
        )

        layered = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)

        self.assertEqual(layered["overallDecision"], "stop_at_l2")
        self.assertEqual(layered["l3Plan"]["decision"], "blocked")
        self.assertEqual(layered["l3Plan"]["deferredCandidateSampleKeys"], ["test_casts"])
        self.assertEqual(layered["l4Plan"]["decision"], "blocked")
        self.assertIn("test_new_regression", layered["stopAtL2"]["unexpectedBlockedSampleKeys"])


if __name__ == "__main__":
    unittest.main()
