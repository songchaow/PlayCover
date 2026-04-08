from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
            generated_path.write_text((TEST_DATA_ROOT / f"{sample_key}.metal").read_text(encoding="utf-8"), encoding="utf-8")
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

    def test_build_behavior_plan_readies_compute_and_fragment_candidates(self) -> None:
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
            ["test_casts", "test_fast_math_select", "test_intrinsic_vector_icmp_zext"],
        )
        self.assertEqual(len(plan["errors"]), 0)
        self.assertEqual(len(plan["deferredSamples"]), 0)
        fragment_sample = next(item for item in plan["readySamples"] if item["sampleKey"] == "test_intrinsic_vector_icmp_zext")
        self.assertEqual(fragment_sample["executionKind"], "fragment")
        self.assertEqual(fragment_sample["cases"][0]["renderTarget"]["width"], 4)

    def test_build_case_spec_flattens_vector_values(self) -> None:
        case = behavior_runner.L3_BEHAVIOR_SAMPLE_SPECS["test_casts"]["cases"][1]
        built = behavior_runner.build_case_spec(case, "compute")

        vector_input = next(item for item in built["buffers"] if item["name"] == "uintIn")
        self.assertEqual(vector_input["elementType"], "uint4")
        self.assertEqual(len(vector_input["values"]), 16)
        self.assertEqual(vector_input["values"][:4], [0, 1, 2, 3])

    def test_build_case_spec_preserves_fragment_render_target(self) -> None:
        case = behavior_runner.L3_BEHAVIOR_SAMPLE_SPECS["test_intrinsic_vector_icmp_zext"]["cases"][0]
        built = behavior_runner.build_case_spec(case, "fragment")

        self.assertEqual(built["entryPoint"], "xlatMtlMain")
        self.assertEqual(built["renderTarget"]["pixelFormat"], "rgba16Float")
        self.assertEqual(built["comparisons"][0]["attachmentIndex"], 0)

    def test_extract_msl_entry_signatures_reads_multi_entry_compute_source(self) -> None:
        source = (TEST_DATA_ROOT / "test_casts.metal").read_text(encoding="utf-8")
        entries = behavior_runner.extract_msl_entry_signatures(source)

        self.assertEqual(
            [(item["shaderType"], item["functionName"]) for item in entries],
            [("kernel", "test_scalar_casts"), ("kernel", "test_vector_casts")],
        )
        scalar_entry = entries[0]
        self.assertEqual(scalar_entry["parameters"][0]["kind"], "air.buffer")
        self.assertEqual(scalar_entry["parameters"][0]["type"], "float")
        self.assertEqual(scalar_entry["parameters"][0]["argName"], "floatOut")
        self.assertEqual(scalar_entry["parameters"][-1]["kind"], "air.thread_position_in_grid")
        self.assertEqual(scalar_entry["parameters"][-1]["type"], "uint")

    def test_validate_reference_oracle_sync_accepts_current_reference_samples(self) -> None:
        sample_inputs = [
            (
                TEST_DATA_ROOT / "test_fast_math_select.ll",
                TEST_DATA_ROOT / "test_fast_math_select.metal",
                "compute",
                behavior_runner.L3_BEHAVIOR_SAMPLE_SPECS["test_fast_math_select"]["cases"],
            ),
            (
                TEST_DATA_ROOT / "test_intrinsic_vector_icmp_zext.ll",
                TEST_DATA_ROOT / "test_intrinsic_vector_icmp_zext.metal",
                "fragment",
                behavior_runner.L3_BEHAVIOR_SAMPLE_SPECS["test_intrinsic_vector_icmp_zext"]["cases"],
            ),
        ]

        for input_path, reference_path, execution_kind, cases in sample_inputs:
            with self.subTest(sample=input_path.name):
                issues = behavior_runner.validate_reference_oracle_sync(
                    input_path,
                    reference_path,
                    execution_kind=execution_kind,
                    cases=[behavior_runner.build_case_spec(case, execution_kind) for case in cases],
                )
                self.assertEqual(issues, [])

    def test_build_behavior_plan_reports_reference_oracle_drift(self) -> None:
        gate_summary = {
            "outputRoot": str(REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives"),
            "layeredDecision": {
                "l3Plan": {
                    "candidateSampleKeys": ["test_fast_math_select"],
                    "candidates": [
                        {
                            "sampleKey": "test_fast_math_select",
                            "inputPath": "<temp>",
                            "riskLevel": "L2",
                            "riskReason": "fast-math drift",
                        }
                    ],
                }
            },
        }
        original_ll = (TEST_DATA_ROOT / "test_fast_math_select.ll").read_text(encoding="utf-8")
        original_metal = (TEST_DATA_ROOT / "test_fast_math_select.metal").read_text(encoding="utf-8")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            input_path = temp_root / "test_fast_math_select.ll"
            reference_path = temp_root / "test_fast_math_select.metal"
            generated_path = temp_root / "generated" / "test_fast_math_select.generated.metal"
            input_path.write_text(original_ll, encoding="utf-8")
            reference_path.write_text(
                original_metal.replace(
                    "kernel void test_fast_math_select(",
                    "kernel void test_fast_math_select_drifted(",
                    1,
                ),
                encoding="utf-8",
            )
            generated_path.parent.mkdir(parents=True, exist_ok=True)
            generated_path.write_text(original_metal, encoding="utf-8")
            gate_summary["layeredDecision"]["l3Plan"]["candidates"][0]["inputPath"] = str(input_path)
            roundtrip_report = {
                "results": [
                    {
                        "comparisonKey": f"explicit_ll:{input_path}",
                        "inputPath": str(input_path),
                        "generatedMSLPath": str(generated_path),
                        "generatedFunctionNames": ["test_fast_math_select"],
                        "generatedFunctionTypes": ["kernel"],
                    }
                ]
            }
            plan = behavior_runner.build_behavior_plan(
                gate_summary,
                roundtrip_report,
                sample_keys=["test_fast_math_select"],
                output_root=temp_root,
            )

        self.assertEqual(plan["readySamples"], [])
        self.assertEqual(len(plan["errors"]), 1)
        self.assertIn("reference MSL 与 .ll 契约不一致", plan["errors"][0]["reason"])
        self.assertIn("reference MSL 缺少 entry", plan["errors"][0]["reason"])

    def test_build_behavior_plan_reports_generated_msl_contract_drift(self) -> None:
        gate_summary = {
            "outputRoot": str(REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives"),
            "layeredDecision": {
                "l3Plan": {
                    "candidateSampleKeys": ["test_fast_math_select"],
                    "candidates": [
                        {
                            "sampleKey": "test_fast_math_select",
                            "inputPath": "<temp>",
                            "riskLevel": "L2",
                            "riskReason": "fast-math drift",
                        }
                    ],
                }
            },
        }
        original_ll = (TEST_DATA_ROOT / "test_fast_math_select.ll").read_text(encoding="utf-8")
        original_metal = (TEST_DATA_ROOT / "test_fast_math_select.metal").read_text(encoding="utf-8")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            input_path = temp_root / "test_fast_math_select.ll"
            reference_path = temp_root / "test_fast_math_select.metal"
            generated_path = temp_root / "generated" / "test_fast_math_select.generated.metal"
            input_path.write_text(original_ll, encoding="utf-8")
            reference_path.write_text(original_metal, encoding="utf-8")
            generated_path.parent.mkdir(parents=True, exist_ok=True)
            generated_path.write_text(
                original_metal.replace("[[buffer(1)]]", "[[buffer(9)]]", 1),
                encoding="utf-8",
            )
            gate_summary["layeredDecision"]["l3Plan"]["candidates"][0]["inputPath"] = str(input_path)
            roundtrip_report = {
                "results": [
                    {
                        "comparisonKey": f"explicit_ll:{input_path}",
                        "inputPath": str(input_path),
                        "generatedMSLPath": str(generated_path),
                        "generatedFunctionNames": ["test_fast_math_select"],
                        "generatedFunctionTypes": ["kernel"],
                    }
                ]
            }
            plan = behavior_runner.build_behavior_plan(
                gate_summary,
                roundtrip_report,
                sample_keys=["test_fast_math_select"],
                output_root=temp_root,
            )

        self.assertEqual(plan["readySamples"], [])
        self.assertEqual(len(plan["errors"]), 1)
        self.assertIn("generated MSL 与 .ll 契约不一致", plan["errors"][0]["reason"])
        self.assertIn("参数绑定索引", plan["errors"][0]["reason"])

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
            ["test_fast_math_select", "test_intrinsic_vector_icmp_zext"],
        )
        self.assertEqual(len(plan["errors"]), 0)
        self.assertEqual(len(plan["deferredSamples"]), 0)

    def test_build_summary_passes_when_compute_and_fragment_cases_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            plan = {
                "candidateSampleKeys": [
                    "test_casts",
                    "test_fast_math_select",
                    "test_intrinsic_vector_icmp_zext",
                ],
                "readySamples": [
                    {"sampleKey": "test_casts"},
                    {"sampleKey": "test_fast_math_select"},
                    {"sampleKey": "test_intrinsic_vector_icmp_zext"},
                ],
                "deferredSamples": [],
                "errors": [],
            }
            executed_results = [
                {"sampleKey": "test_casts", "status": "pass"},
                {"sampleKey": "test_fast_math_select", "status": "pass"},
                {"sampleKey": "test_intrinsic_vector_icmp_zext", "status": "pass"},
            ]
            summary = behavior_runner.build_summary(
                gate_summary_path=root / "gate-summary.json",
                roundtrip_report_path=root / "roundtrip-summary.json",
                report_path=root / "behavior-summary.json",
                output_root=root,
                plan=plan,
                executed_results=executed_results,
            )

        self.assertEqual(summary["status"], "pass")
        self.assertEqual(summary["executedSampleCount"], 3)
        self.assertEqual(summary["deferredSampleCount"], 0)
        self.assertIn("全部通过", summary["summary"])

    def test_build_behavior_plan_defers_registry_missing_sample_without_breaking_ready_samples(self) -> None:
        gate_summary = self.make_gate_summary()
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            roundtrip_report = self.make_roundtrip_report(temp_root)
            plan = behavior_runner.build_behavior_plan(
                gate_summary,
                roundtrip_report,
                sample_keys=["unknown_sample", "test_fast_math_select"],
                output_root=temp_root,
            )

        self.assertEqual(
            [item["sampleKey"] for item in plan["readySamples"]],
            ["test_fast_math_select"],
        )
        self.assertEqual(len(plan["errors"]), 0)
        self.assertEqual(len(plan["deferredSamples"]), 1)
        self.assertEqual(plan["deferredSamples"][0]["sampleKey"], "unknown_sample")
        self.assertEqual(plan["deferredSamples"][0]["phase"], "registry-missing")

    def test_summarize_status_returns_fail_when_setup_errors_exist(self) -> None:
        status, summary = behavior_runner.summarize_status(
            executed_results=[{"sampleKey": "test_fast_math_select", "status": "pass"}],
            deferred_samples=[],
            errors=[{"sampleKey": "broken_sample", "status": "error"}],
        )

        self.assertEqual(status, "fail")
        self.assertIn("准备阶段失败", summary)

    def test_summarize_status_returns_fail_when_executed_sample_does_not_pass(self) -> None:
        status, summary = behavior_runner.summarize_status(
            executed_results=[{"sampleKey": "test_intrinsic_vector_icmp_zext", "status": "fail"}],
            deferred_samples=[],
            errors=[],
        )

        self.assertEqual(status, "fail")
        self.assertIn("reference-vs-generated", summary)

    def test_summarize_status_returns_pass_when_all_samples_pass_without_deferred(self) -> None:
        status, summary = behavior_runner.summarize_status(
            executed_results=[{"sampleKey": "test_fast_math_select", "status": "pass"}],
            deferred_samples=[],
            errors=[],
        )

        self.assertEqual(status, "pass")
        self.assertIn("全部通过", summary)

    def test_run_sample_behavior_writes_spec_and_reads_swift_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sample = {
                "sampleKey": "test_fast_math_select",
                "referenceSourcePath": str(root / "reference.metal"),
                "candidateSourcePath": str(root / "candidate.metal"),
                "artifactSpecPath": str(root / "artifacts" / "test_fast_math_select.spec.json"),
                "artifactResultPath": str(root / "artifacts" / "test_fast_math_select.result.json"),
                "cases": [{"name": "case", "entryPoint": "main0", "threadCount": 1, "buffers": [], "comparisons": []}],
            }
            swift_result = {
                "schemaVersion": 1,
                "sampleKey": "test_fast_math_select",
                "status": "pass",
                "summary": "passed 1 / 1 compute cases",
                "deviceName": "Mock Metal",
                "cases": [],
            }

            def fake_run(command, check, capture_output, text):
                self.assertFalse(check)
                self.assertTrue(capture_output)
                self.assertTrue(text)
                spec_path = Path(command[3])
                result_path = Path(command[5])
                self.assertTrue(spec_path.is_file())
                spec_payload = json.loads(spec_path.read_text(encoding="utf-8"))
                self.assertEqual(spec_payload["sampleKey"], "test_fast_math_select")
                self.assertEqual(spec_payload["referenceSourcePath"], sample["referenceSourcePath"])
                self.assertEqual(spec_payload["candidateSourcePath"], sample["candidateSourcePath"])
                result_path.write_text(json.dumps(swift_result), encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, stdout="swift ok\n", stderr="behavior harness pass")

            with mock.patch.object(behavior_runner.subprocess, "run", side_effect=fake_run) as mocked_run:
                result = behavior_runner.run_sample_behavior(
                    sample,
                    swift_runner=root / "metal_compute_behavior_runner.swift",
                    quiet=True,
                )

        self.assertEqual(mocked_run.call_count, 1)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["returnCode"], 0)
        self.assertEqual(result["swiftResult"]["status"], "pass")
        self.assertEqual(result["swiftResult"]["deviceName"], "Mock Metal")

    def test_run_sample_behavior_returns_error_when_swift_fails_without_result_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sample = {
                "sampleKey": "test_fast_math_select",
                "referenceSourcePath": str(root / "reference.metal"),
                "candidateSourcePath": str(root / "candidate.metal"),
                "artifactSpecPath": str(root / "artifacts" / "test_fast_math_select.spec.json"),
                "artifactResultPath": str(root / "artifacts" / "test_fast_math_select.result.json"),
                "cases": [],
            }

            with mock.patch.object(
                behavior_runner.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["swift", "runner.swift"],
                    1,
                    stdout="",
                    stderr="swift harness failed hard",
                ),
            ):
                result = behavior_runner.run_sample_behavior(
                    sample,
                    swift_runner=root / "metal_compute_behavior_runner.swift",
                    quiet=True,
                )

            self.assertTrue(Path(sample["artifactSpecPath"]).is_file())
            self.assertFalse(Path(sample["artifactResultPath"]).exists())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["returnCode"], 1)
        self.assertIn("swift harness failed hard", result["reason"])


if __name__ == "__main__":
    unittest.main()
