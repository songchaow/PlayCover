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


if __name__ == "__main__":
    unittest.main()
