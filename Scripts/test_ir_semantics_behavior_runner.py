from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import ir_semantics_behavior_runner as behavior_runner


TEST_DATA_ROOT = (
    REPO_ROOT
    / "LocalDocs"
    / "XCodeReleaseShaderDebug"
    / "RoadE-HookMakeLibraryWithSrc"
    / "test-data"
)


class IRSemanticsBehaviorRunnerTests(unittest.TestCase):
    def make_gate_summary(self) -> dict:
        return {
            "outputRoot": str(REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives"),
            "layeredDecision": {
                "l3Plan": {
                    "candidateSampleKeys": [
                        "test_casts",
                        "test_fast_math_select",
                        "test_intrinsic_vector_icmp_zext",
                    ],
                    "candidates": [
                        {
                            "sampleKey": "test_casts",
                            "inputPath": str(TEST_DATA_ROOT / "test_casts.ll"),
                            "riskLevel": "L2",
                            "riskReason": "cast lowering drift",
                        },
                        {
                            "sampleKey": "test_fast_math_select",
                            "inputPath": str(TEST_DATA_ROOT / "test_fast_math_select.ll"),
                            "riskLevel": "L2",
                            "riskReason": "fast-math drift",
                        },
                        {
                            "sampleKey": "test_intrinsic_vector_icmp_zext",
                            "inputPath": str(TEST_DATA_ROOT / "test_intrinsic_vector_icmp_zext.ll"),
                            "riskLevel": "L2",
                            "riskReason": "fragment lowering drift",
                        },
                    ],
                }
            },
        }

    def make_roundtrip_report(self, temp_root: Path) -> dict:
        generated_root = temp_root / "generated"
        generated_root.mkdir(parents=True, exist_ok=True)

        samples = {
            "test_casts": (["test_scalar_casts", "test_vector_casts"], ["kernel", "kernel"]),
            "test_fast_math_select": (["test_fast_math_select"], ["kernel"]),
            "test_intrinsic_vector_icmp_zext": (["xlatMtlMain"], ["fragment"]),
        }

        results = []
        for sample_key, (function_names, function_types) in samples.items():
            generated_path = generated_root / f"{sample_key}.generated.metal"
            generated_path.write_text("#include <metal_stdlib>\nusing namespace metal;\n", encoding="utf-8")
            results.append(
                {
                    "comparisonKey": f"explicit_ll:{TEST_DATA_ROOT / (sample_key + '.ll')}",
                    "inputPath": str(TEST_DATA_ROOT / f"{sample_key}.ll"),
                    "generatedMSLPath": str(generated_path),
                    "generatedFunctionNames": function_names,
                    "generatedFunctionTypes": function_types,
                }
            )

        return {"results": results}

    def test_build_behavior_plan_selects_compute_samples_and_defers_fragment_candidate(self) -> None:
        gate_summary = self.make_gate_summary()
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            roundtrip_report = self.make_roundtrip_report(temp_root)
            plan = behavior_runner.build_behavior_plan(
                gate_summary,
                roundtrip_report,
                sample_keys=behavior_runner.gate_candidate_keys(gate_summary, []),
                output_root=temp_root,
            )

        self.assertEqual(
            [item["sampleKey"] for item in plan["readySamples"]],
            ["test_casts", "test_fast_math_select"],
        )
        self.assertEqual(len(plan["errors"]), 0)
        self.assertEqual(len(plan["deferredSamples"]), 1)
        self.assertEqual(plan["deferredSamples"][0]["sampleKey"], "test_intrinsic_vector_icmp_zext")
        self.assertIn("compute-first", plan["deferredSamples"][0]["reason"])

    def test_build_case_spec_flattens_vector_values(self) -> None:
        case = behavior_runner.L3_BEHAVIOR_SAMPLE_SPECS["test_casts"]["cases"][1]
        built = behavior_runner.build_case_spec(case)

        vector_input = next(item for item in built["buffers"] if item["name"] == "uintIn")
        self.assertEqual(vector_input["elementType"], "uint4")
        self.assertEqual(len(vector_input["values"]), 16)
        self.assertEqual(vector_input["values"][:4], [0, 1, 2, 3])

    def test_build_behavior_plan_keeps_current_default_boundary_narrowed(self) -> None:
        gate_summary = {
            "outputRoot": str(REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives"),
            "layeredDecision": {
                "l3Plan": {
                    "candidateSampleKeys": [
                        "test_fast_math_select",
                        "test_intrinsic_vector_icmp_zext",
                    ],
                    "candidates": [
                        {
                            "sampleKey": "test_fast_math_select",
                            "inputPath": str(TEST_DATA_ROOT / "test_fast_math_select.ll"),
                            "riskLevel": "L2",
                            "riskReason": "fast-math drift",
                        },
                        {
                            "sampleKey": "test_intrinsic_vector_icmp_zext",
                            "inputPath": str(TEST_DATA_ROOT / "test_intrinsic_vector_icmp_zext.ll"),
                            "riskLevel": "L2",
                            "riskReason": "fragment lowering drift",
                        },
                    ],
                }
            },
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            roundtrip_report = self.make_roundtrip_report(temp_root)
            plan = behavior_runner.build_behavior_plan(
                gate_summary,
                roundtrip_report,
                sample_keys=behavior_runner.gate_candidate_keys(gate_summary, []),
                output_root=temp_root,
            )

        self.assertEqual(
            [item["sampleKey"] for item in plan["readySamples"]],
            ["test_fast_math_select"],
        )
        self.assertEqual(len(plan["errors"]), 0)
        self.assertEqual(
            [item["sampleKey"] for item in plan["deferredSamples"]],
            ["test_intrinsic_vector_icmp_zext"],
        )

    def test_build_summary_warns_when_compute_cases_pass_but_fragment_candidate_is_deferred(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = {
                "candidateSampleKeys": [
                    "test_casts",
                    "test_fast_math_select",
                    "test_intrinsic_vector_icmp_zext",
                ],
                "readySamples": [{"sampleKey": "test_casts"}, {"sampleKey": "test_fast_math_select"}],
                "deferredSamples": [
                    {
                        "sampleKey": "test_intrinsic_vector_icmp_zext",
                        "status": "deferred",
                        "reason": "当前第一阶段只实现 compute-first harness；fragment/render 样本继续后置到 render-second。",
                    }
                ],
                "errors": [],
            }
            executed_results = [
                {"sampleKey": "test_casts", "status": "pass"},
                {"sampleKey": "test_fast_math_select", "status": "pass"},
            ]
            summary = behavior_runner.build_summary(
                gate_summary_path=root / "gate-summary.json",
                roundtrip_report_path=root / "roundtrip-summary.json",
                report_path=root / "behavior-summary.json",
                output_root=root,
                plan=plan,
                executed_results=executed_results,
            )

        self.assertEqual(summary["status"], "warn")
        self.assertEqual(summary["executedSampleCount"], 2)
        self.assertEqual(summary["deferredSampleCount"], 1)
        self.assertIn("后置", summary["summary"])


if __name__ == "__main__":
    unittest.main()
