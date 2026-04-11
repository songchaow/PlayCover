from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
ROUNDTRIP_SCRIPT = SCRIPTS_DIR / "ir_semantics_roundtrip_runner.py"
TEST_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_addrspace.ll"
TEST_FRAGMENT_PACKED_RETURN_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_fragment_packed_return.ll"
TEST_FRAGMENT_NO_ENTRY_INPUT_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_fragment_no_entry_input.ll"
TEST_UNDERSCORE_STRUCT_REFERENCE_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_underscore_struct_reference.ll"
TEST_VERTEX_POSITION_INVARIANT_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_vertex_position_invariant.ll"
TEST_PHI_BRANCH_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_phi_branch.ll"
TEST_PARTIAL_STRUCTURED_CFG_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_partial_structured_cfg.ll"
TEST_ENTRY_PARTIAL_STRUCTURED_CFG_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_entry_partial_structured_cfg.ll"
TEST_LATE_MERGE_FALLBACK_ORDER_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_late_merge_fallback_order.ll"
TEST_UNCONDITIONAL_SUCCESSOR_GATING_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_unconditional_successor_gating.ll"
TEST_STRUCTURED_MERGE_LATE_PREDECESSOR_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_structured_merge_late_predecessor.ll"
TEST_NESTED_COMMON_MERGE_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_nested_common_merge.ll"
TEST_NESTED_COMMON_MERGE_WITH_UNSTRUCTURED_TAIL_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_nested_common_merge_with_unstructured_tail.ll"
TEST_SAMPLER_STATE_GLOBALS_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_sampler_state_globals.ll"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import ir_semantics_roundtrip_runner as roundtrip_runner


def build_shared_compile_planner_binary(output_root: Path) -> Path:
    return roundtrip_runner.replay_runner.build_shared_compile_planner_harness_binary(REPO_ROOT, output_root)


def make_roundtrip_result(
    *,
    roundtrip_status: str = "success",
    failure_stage: str | None = None,
    error_summary: str | None = None,
    original_ir_path: str | None = None,
    regenerated_ir_path: str | None = None,
) -> dict:
    return {
        "jobID": 1,
        "comparisonKey": f"explicit_ll:{TEST_SAMPLE}",
        "sourceKind": "explicit_ll",
        "bundleId": None,
        "moduleKey": None,
        "inputPath": str(TEST_SAMPLE),
        "originalIRPath": original_ir_path,
        "regeneratedIRPath": regenerated_ir_path,
        "roundTripStatus": roundtrip_status,
        "failureStage": failure_stage,
        "errorSummary": error_summary,
    }


class IRSemanticsRoundtripRunnerTests(unittest.TestCase):
    def test_make_timestamped_run_name_adds_unique_suffix(self) -> None:
        fixed_now = datetime(2026, 4, 9, 10, 41, 2)

        first = roundtrip_runner.replay_runner.make_timestamped_run_name(
            now=fixed_now,
            unique_suffix="corpus",
        )
        second = roundtrip_runner.replay_runner.make_timestamped_run_name(
            now=fixed_now,
            unique_suffix="diagnostics",
        )

        self.assertEqual(first, "20260409-104102-corpus")
        self.assertEqual(second, "20260409-104102-diagnostics")
        self.assertNotEqual(first, second)

    def test_default_output_root_uses_unique_timestamped_run_name(self) -> None:
        output_root = roundtrip_runner.default_output_root(REPO_ROOT)

        self.assertEqual(
            output_root.parent,
            REPO_ROOT / "build" / "semantics-validation" / "roundtrip",
        )
        self.assertRegex(output_root.name, r"^\d{8}-\d{6}-[0-9a-f]{8}$")

    def test_load_shared_compile_decision_manifest_from_swift_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            swift_path = Path(temp_dir) / "LibrarySourceInjectionSwizzles.swift"
            swift_path.write_text(
                'private final class Dummy {\n'
                '    private static let sharedCompileDecisionManifestJSON = #"""\n'
                '{\n'
                '  "schemaVersion": 1,\n'
                '  "fastMath": {\n'
                '    "enableOption": "custom.fast_math_enable",\n'
                '    "disableOption": "custom.fast_math_disable"\n'
                '  },\n'
                '  "replacementSourceValidationRules": [\n'
                '    {\n'
                '      "reason": "synthetic rule",\n'
                '      "pattern": "foo+"\n'
                '    }\n'
                '  ]\n'
                '}\n'
                '"""#\n'
                '}\n',
                encoding="utf-8",
            )

            manifest = roundtrip_runner.replay_runner.load_shared_compile_decision_manifest(swift_path)

        self.assertEqual(manifest["fastMath"]["enableOption"], "custom.fast_math_enable")
        self.assertEqual(manifest["fastMath"]["disableOption"], "custom.fast_math_disable")
        self.assertEqual(manifest["replacementSourceValidationRules"][0]["reason"], "synthetic rule")
        self.assertEqual(manifest["replacementSourceValidationRules"][0]["pattern"], "foo+")

    def test_replay_runner_uses_shared_compile_decision_manifest(self) -> None:
        manifest = roundtrip_runner.replay_runner.load_shared_compile_decision_manifest()

        self.assertEqual(
            roundtrip_runner.replay_runner.FAST_MATH_ENABLE_OPTION,
            manifest["fastMath"]["enableOption"],
        )
        self.assertEqual(
            roundtrip_runner.replay_runner.FAST_MATH_DISABLE_OPTION,
            manifest["fastMath"]["disableOption"],
        )
        self.assertEqual(
            [reason for reason, _ in roundtrip_runner.replay_runner.REPLACEMENT_SOURCE_VALIDATION_RULES],
            [entry["reason"] for entry in manifest["replacementSourceValidationRules"]],
        )

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_resolve_compile_metal_args_infers_fast_math_disable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            original_ir_path = temp_root / "original.ll"
            original_ir_path.write_text(
                '!llvm.module.flags = !{!0}\n!air.compile_options = !{!1}\n!1 = !{!"air.compile.fast_math_disable"}\n',
                encoding="utf-8",
            )
            planner_binary = build_shared_compile_planner_binary(temp_root / "out")

            original_mode, fast_math_decision, inferred_args, effective_args = roundtrip_runner.replay_runner.resolve_compile_metal_args(
                original_ir_path,
                [],
                shared_compile_planner_binary=planner_binary,
            )

        self.assertEqual(original_mode, "disable")
        self.assertEqual(fast_math_decision, "fast_math_aligned")
        self.assertEqual(inferred_args, ["-fno-fast-math"])
        self.assertEqual(effective_args, ["-fno-fast-math"])

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_compile_replay_result_auto_aligns_fast_math_disable_from_original_ir(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            original_ir_path = temp_root / "original.ll"
            generated_msl_path = temp_root / "generated.metal"
            original_ir_path.write_text(
                '!llvm.module.flags = !{!0}\n!air.compile_options = !{!1}\n!1 = !{!"air.compile.fast_math_disable"}\n',
                encoding="utf-8",
            )
            generated_msl_path.write_text(
                '#include <metal_stdlib>\nusing namespace metal;\nkernel void test_kernel(device float* output [[buffer(0)]]) { output[0] = 1.0f; }\n',
                encoding="utf-8",
            )
            planner_binary = build_shared_compile_planner_binary(temp_root / "out")
            args = argparse.Namespace(
                metal_sdk="macosx",
                metal_args=[],
                skip_preflight=False,
                shared_compile_planner_binary=str(planner_binary),
            )
            replay_result = {
                "jobID": 1,
                "success": True,
                "inputPath": str(original_ir_path),
                "outputPath": str(generated_msl_path),
            }

            original_run = subprocess.run

            def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                if command and Path(command[0]).name == "shared_compile_planner_harness":
                    return original_run(command, check=check, capture_output=capture_output, text=text)
                return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

            with mock.patch.object(
                roundtrip_runner.replay_runner.subprocess,
                "run",
                side_effect=fake_run,
            ) as run_mock:
                compile_result = roundtrip_runner.replay_runner.compile_replay_result(replay_result, args)

        command = run_mock.call_args.args[0]
        self.assertIn("-fno-fast-math", command)
        self.assertEqual(compile_result["status"], "success")
        self.assertEqual(compile_result["compileBackend"], "xcrun")
        self.assertEqual(compile_result["originalFastMathMode"], "disable")
        self.assertEqual(compile_result["fastMathMode"], "disable")
        self.assertEqual(compile_result["fastMathDecision"], "fast_math_aligned")
        self.assertTrue(compile_result["usesExplicitCompileOptions"])
        self.assertFalse(compile_result["compileOptionsFastMathEnabled"])
        self.assertIsNone(compile_result["explicitOverrideSource"])
        self.assertEqual(compile_result["inferredMetalArgs"], ["-fno-fast-math"])
        self.assertEqual(compile_result["effectiveMetalArgs"], ["-fno-fast-math"])

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_compile_replay_result_preserves_explicit_fast_math_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            original_ir_path = temp_root / "original.ll"
            generated_msl_path = temp_root / "generated.metal"
            original_ir_path.write_text(
                '!llvm.module.flags = !{!0}\n!air.compile_options = !{!1}\n!1 = !{!"air.compile.fast_math_disable"}\n',
                encoding="utf-8",
            )
            generated_msl_path.write_text(
                '#include <metal_stdlib>\nusing namespace metal;\nkernel void test_kernel(device float* output [[buffer(0)]]) { output[0] = 1.0f; }\n',
                encoding="utf-8",
            )
            planner_binary = build_shared_compile_planner_binary(temp_root / "out")
            args = argparse.Namespace(
                metal_sdk="macosx",
                metal_args=["-ffast-math"],
                skip_preflight=False,
                shared_compile_planner_binary=str(planner_binary),
            )
            replay_result = {
                "jobID": 1,
                "success": True,
                "inputPath": str(original_ir_path),
                "outputPath": str(generated_msl_path),
            }

            original_run = subprocess.run

            def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                if command and Path(command[0]).name == "shared_compile_planner_harness":
                    return original_run(command, check=check, capture_output=capture_output, text=text)
                return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

            with mock.patch.object(
                roundtrip_runner.replay_runner.subprocess,
                "run",
                side_effect=fake_run,
            ) as run_mock:
                compile_result = roundtrip_runner.replay_runner.compile_replay_result(replay_result, args)

        command = run_mock.call_args.args[0]
        self.assertIn("-ffast-math", command)
        self.assertNotIn("-fno-fast-math", command)
        self.assertEqual(compile_result["status"], "success")
        self.assertEqual(compile_result["compileBackend"], "xcrun")
        self.assertEqual(compile_result["originalFastMathMode"], "disable")
        self.assertEqual(compile_result["fastMathMode"], "enable")
        self.assertEqual(compile_result["fastMathDecision"], "user_override")
        self.assertTrue(compile_result["usesExplicitCompileOptions"])
        self.assertTrue(compile_result["compileOptionsFastMathEnabled"])
        self.assertEqual(compile_result["explicitOverrideSource"], "user_metal_args")
        self.assertEqual(compile_result["inferredMetalArgs"], [])
        self.assertEqual(compile_result["effectiveMetalArgs"], ["-ffast-math"])

    def test_apply_test_data_representatives_preset(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "test-data-representatives"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        self.assertEqual(
            Path(args.output_root),
            REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives",
        )
        self.assertEqual(len(args.ll_inputs), len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))
        self.assertTrue(all(path.endswith(".ll") for path in args.ll_inputs))
        self.assertTrue(any(path.endswith("test_struct_array_field.ll") for path in args.ll_inputs))
        self.assertEqual(args.corpus_roots, [])
        self.assertEqual(args.bundle_id, [])
        self.assertEqual(args.module_key, [])

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertEqual(gate_profile_name, "test-data-representatives")
        self.assertEqual(gate_profile["expectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))

    def test_apply_daily_default_preset_adds_local_corpus_representatives(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "daily-default"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        self.assertEqual(
            Path(args.output_root),
            REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "daily-default",
        )
        self.assertEqual(args.corpus_roots, [str(roundtrip_runner.LOCAL_SHADERCORPUS_DEFAULT_ROOT)])
        self.assertEqual(args.diagnostics_roots, [])
        self.assertEqual(
            args.bundle_id,
            ["com.miHoYo.Yuanshen", "com.papegames.lysk", "com.tencent.tmgp.speedmobile"],
        )
        self.assertEqual(
            args.module_key,
            [item["moduleKey"] for item in roundtrip_runner.LOCAL_SHADERCORPUS_REPRESENTATIVES],
        )
        self.assertEqual(len(args.ll_inputs), len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertEqual(gate_profile_name, "daily-default")
        self.assertEqual(gate_profile["minimumExpectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))
        self.assertEqual(
            gate_profile["expectedJobCount"],
            len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES) + len(roundtrip_runner.LOCAL_SHADERCORPUS_REPRESENTATIVES),
        )
        self.assertEqual(
            gate_profile["allowedBlockedSampleKeys"],
            roundtrip_runner.dedupe_preserving_order(
                roundtrip_runner.TEST_DATA_REPRESENTATIVE_ALLOWED_BLOCKED_KEYS
                + roundtrip_runner.LOCAL_SHADERCORPUS_ALLOWED_BLOCKED_KEYS
            ),
        )
        self.assertEqual(
            gate_profile["allowedL2SampleKeys"],
            roundtrip_runner.dedupe_preserving_order(
                roundtrip_runner.TEST_DATA_REPRESENTATIVE_L2_KEYS + roundtrip_runner.LOCAL_SHADERCORPUS_ALLOWED_L2_KEYS
            ),
        )

    def test_apply_local_diagnostics_batch_preset_adds_default_root(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "local-diagnostics-batch"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        self.assertEqual(
            Path(args.output_root),
            REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "local-diagnostics-batch",
        )
        self.assertEqual(args.ll_inputs, [])
        self.assertEqual(args.corpus_roots, [])
        self.assertEqual(args.diagnostics_roots, [str(roundtrip_runner.LOCAL_SHADERDIAGNOSTICS_DEFAULT_ROOT)])
        self.assertEqual(args.bundle_id, [])
        self.assertEqual(args.module_key, [])

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertIsNone(gate_profile_name)
        self.assertIsNone(gate_profile)

    def test_apply_local_diagnostics_batch_preset_dedupes_explicit_diagnostics_root(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(
            [
                "--preset",
                "local-diagnostics-batch",
                "--diagnostics-root",
                str(roundtrip_runner.LOCAL_SHADERDIAGNOSTICS_DEFAULT_ROOT),
            ]
        )

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        self.assertEqual(args.diagnostics_roots, [str(roundtrip_runner.LOCAL_SHADERDIAGNOSTICS_DEFAULT_ROOT)])

    def test_local_corpus_gate_profile_allows_missing_local_samples(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "local-corpus-representatives"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertEqual(gate_profile_name, "local-corpus-representatives")
        self.assertEqual(gate_profile["minimumExpectedJobCount"], 0)
        self.assertEqual(gate_profile["expectedJobCount"], len(roundtrip_runner.LOCAL_SHADERCORPUS_REPRESENTATIVES))

    def test_test_data_representative_contract_keeps_preset_gate_and_manifest_in_sync(self) -> None:
        preset = roundtrip_runner.build_roundtrip_presets(REPO_ROOT)["test-data-representatives"]
        gate_profile = roundtrip_runner.build_gate_profiles()["test-data-representatives"]
        contract_jobs = roundtrip_runner.build_expected_preset_contract_jobs(
            "test-data-representatives",
            REPO_ROOT,
        )

        contract_files = [
            str(item["fileName"])
            for item in roundtrip_runner.TEST_DATA_REPRESENTATIVE_CONTRACT
        ]
        expected_paths = roundtrip_runner.make_test_data_paths(REPO_ROOT, contract_files)
        expected_sample_keys = [roundtrip_runner.ll_sample_key(file_name) for file_name in contract_files]
        expected_l2_keys = [
            roundtrip_runner.ll_sample_key(str(item["fileName"]))
            for item in roundtrip_runner.TEST_DATA_REPRESENTATIVE_CONTRACT
            if item.get("allowedL2")
        ]
        expected_blocked_keys = [
            roundtrip_runner.ll_sample_key(str(item["fileName"]))
            for item in roundtrip_runner.TEST_DATA_REPRESENTATIVE_CONTRACT
            if item.get("allowedBlocked")
        ]
        expected_failures = {
            roundtrip_runner.ll_sample_key(str(item["fileName"])): str(item["allowedFailureStage"])
            for item in roundtrip_runner.TEST_DATA_REPRESENTATIVE_CONTRACT
            if item.get("allowedFailureStage")
        }

        self.assertEqual(expected_l2_keys, ["test_fast_math_select", "test_intrinsic_vector_icmp_zext"])
        self.assertEqual(preset["ll_inputs"], expected_paths)
        self.assertEqual(gate_profile["expectedJobCount"], len(contract_files))
        self.assertEqual(gate_profile["allowedL2SampleKeys"], expected_l2_keys)
        self.assertNotIn("test_casts", gate_profile["allowedL2SampleKeys"])
        self.assertIn(f"跟踪 {len(expected_l2_keys)} 个已知 L2 样本", gate_profile["description"])
        self.assertEqual(gate_profile["allowedBlockedSampleKeys"], expected_blocked_keys)
        self.assertEqual(gate_profile["allowedFailureSamples"], expected_failures)
        self.assertEqual([entry["sampleKey"] for entry in contract_jobs], expected_sample_keys)

    def test_local_shader_corpus_contract_keeps_preset_gate_and_manifest_in_sync(self) -> None:
        preset = roundtrip_runner.build_roundtrip_presets(REPO_ROOT)["local-corpus-representatives"]
        gate_profile = roundtrip_runner.build_gate_profiles()["local-corpus-representatives"]
        contract_jobs = roundtrip_runner.build_expected_preset_contract_jobs(
            "local-corpus-representatives",
            REPO_ROOT,
        )

        contract_entries = roundtrip_runner.LOCAL_SHADERCORPUS_REPRESENTATIVE_CONTRACT
        expected_bundle_ids = roundtrip_runner.dedupe_preserving_order(
            [str(item["bundleId"]) for item in contract_entries]
        )
        expected_module_keys = [str(item["moduleKey"]) for item in contract_entries]
        expected_sample_identities = [
            roundtrip_runner.shader_corpus_identity(str(item["bundleId"]), str(item["moduleKey"]))
            for item in contract_entries
        ]
        expected_blocked_keys = [
            roundtrip_runner.shader_corpus_identity(str(item["bundleId"]), str(item["moduleKey"]))
            for item in contract_entries
            if item.get("allowedBlocked")
        ]
        expected_l2_keys = [
            roundtrip_runner.shader_corpus_identity(str(item["bundleId"]), str(item["moduleKey"]))
            for item in contract_entries
            if item.get("allowedL2")
        ]

        self.assertEqual(preset["corpus_roots"], [str(roundtrip_runner.LOCAL_SHADERCORPUS_DEFAULT_ROOT)])
        self.assertEqual(preset["bundle_ids"], expected_bundle_ids)
        self.assertEqual(preset["module_keys"], expected_module_keys)
        self.assertEqual(gate_profile["expectedJobCount"], len(contract_entries))
        self.assertEqual(gate_profile["allowedBlockedSampleKeys"], expected_blocked_keys)
        self.assertEqual(gate_profile["allowedL2SampleKeys"], expected_l2_keys)
        self.assertEqual([entry["sampleIdentity"] for entry in contract_jobs], expected_sample_identities)

    def test_discover_jobs_from_shader_source_diagnostics_root_prefers_latest_event(self) -> None:
        parser = roundtrip_runner.build_parser()
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            diagnostics_root = temp_root / "ShaderSourceDiagnostics"
            bundle_root = diagnostics_root / "com.example.demo"
            older_module_dir = bundle_root / "2026-04-01T00_00_00Z_newLibraryWithData_error__compile_failed_modules" / "abc123"
            newer_module_dir = bundle_root / "2026-04-02T00_00_00Z_newLibraryWithData_error__preflight_rejected_modules" / "abc123"
            older_module_dir.mkdir(parents=True, exist_ok=True)
            newer_module_dir.mkdir(parents=True, exist_ok=True)
            (older_module_dir / "module.ll").write_text("define void @older() { ret void }\n", encoding="utf-8")
            (newer_module_dir / "module.ll").write_text("define void @newer() { ret void }\n", encoding="utf-8")
            (older_module_dir / "module.generated.metal").write_text("// older\n", encoding="utf-8")
            (newer_module_dir / "module.generated.metal").write_text("// newer\n", encoding="utf-8")
            (older_module_dir / "module.meta.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 2,
                        "bundleId": "com.example.demo",
                        "moduleKey": "abc123",
                        "selector": "newLibraryWithData:error:",
                        "compileStatus": "compile_failed",
                        "functionNames": ["older"],
                        "functionTypes": ["kernel"],
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )
            (newer_module_dir / "module.meta.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 2,
                        "bundleId": "com.example.demo",
                        "moduleKey": "abc123",
                        "selector": "newLibraryWithData:error:",
                        "compileStatus": "preflight_rejected",
                        "functionNames": ["newer"],
                        "functionTypes": ["vertex"],
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )

            args = parser.parse_args([
                "--diagnostics-root",
                str(diagnostics_root),
                "--bundle-id",
                "com.example.demo",
            ])
            warnings: list[roundtrip_runner.replay_runner.DiscoveryWarning] = []
            jobs = roundtrip_runner.replay_runner.discover_jobs(args, temp_root / "out", warnings)

            self.assertEqual([warning.message for warning in warnings], [])
            self.assertEqual(len(jobs), 1)
            self.assertEqual(jobs[0].source_kind, "shader_source_diagnostics")
            self.assertEqual(jobs[0].bundle_id, "com.example.demo")
            self.assertEqual(jobs[0].module_key, "abc123")
            self.assertEqual(jobs[0].function_names, ["newer"])
            self.assertEqual(jobs[0].function_types, ["vertex"])
            self.assertEqual(jobs[0].observed_selectors, ["newLibraryWithData:error:"])
            self.assertEqual(jobs[0].input_path, (newer_module_dir / "module.ll").resolve())
            self.assertEqual(
                jobs[0].baseline_generated_msl_path,
                (newer_module_dir / "module.generated.metal").resolve(),
            )

    def test_build_preset_manifest_records_diagnostics_inputs_and_source_kind(self) -> None:
        parser = roundtrip_runner.build_parser()
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            diagnostics_root = temp_root / "ShaderSourceDiagnostics"
            module_dir = diagnostics_root / "com.example.demo" / "2026-04-02T00_00_00Z_newLibraryWithData_error__compile_failed_modules" / "abc123"
            module_dir.mkdir(parents=True, exist_ok=True)
            input_path = (module_dir / "module.ll").resolve()
            input_path.write_text("define void @demo() { ret void }\n", encoding="utf-8")
            metadata_path = (module_dir / "module.meta.json").resolve()
            metadata_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 2,
                        "bundleId": "com.example.demo",
                        "moduleKey": "abc123",
                        "functionNames": ["demo"],
                        "functionTypes": ["kernel"],
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )

            args = parser.parse_args([
                "--diagnostics-root",
                str(diagnostics_root),
                "--allow-failures",
            ])
            output_root = temp_root / "roundtrip"
            manifest_path = output_root / "preset-manifest.json"
            job = roundtrip_runner.replay_runner.ReplayJob(
                job_id=7,
                source_kind="shader_source_diagnostics",
                input_path=input_path,
                output_path=output_root / "com.example.demo" / "modules" / "abc123" / "generated.metal",
                bundle_id="com.example.demo",
                module_key="abc123",
                metadata_path=metadata_path,
                function_names=["demo"],
                function_types=["kernel"],
            )

            manifest = roundtrip_runner.build_preset_manifest(
                args,
                output_root,
                manifest_path,
                [job],
                REPO_ROOT,
                {
                    "roundtripReportPath": str(output_root / "roundtrip-summary.json"),
                    "gateSummaryPath": str(output_root / "gate-summary.json"),
                },
                None,
                None,
                None,
            )

            self.assertEqual(manifest["requestedInputs"]["diagnosticsRoots"], [str(diagnostics_root)])
            self.assertEqual(manifest["discovery"]["sourceKinds"]["shaderSourceDiagnostics"], 1)
            self.assertEqual(manifest["discovery"]["sourceKinds"]["explicitLL"], 0)
            self.assertEqual(manifest["discovery"]["sourceKinds"]["shaderCorpus"], 0)
            self.assertEqual(manifest["discovery"]["jobs"][0]["sourceKind"], "shader_source_diagnostics")
            self.assertEqual(manifest["discovery"]["jobs"][0]["metadataPath"], str(metadata_path))
            self.assertEqual(
                manifest["discovery"]["jobs"][0]["sampleIdentity"],
                "shaderSourceDiagnostics::bundle:com.example.demo::module:abc123",
            )
            self.assertEqual(
                manifest["discovery"]["jobs"][0]["comparisonKey"],
                "shaderSourceDiagnostics::bundle:com.example.demo::module:abc123",
            )

    def test_make_comparison_key_distinguishes_shader_source_diagnostics_from_shader_corpus(self) -> None:
        self.assertEqual(
            roundtrip_runner.replay_runner.make_comparison_key(
                "shader_corpus",
                "com.example.demo",
                "abc123",
                None,
            ),
            "bundle:com.example.demo::module:abc123",
        )
        self.assertEqual(
            roundtrip_runner.replay_runner.make_comparison_key(
                "shader_source_diagnostics",
                "com.example.demo",
                "abc123",
                None,
            ),
            "shaderSourceDiagnostics::bundle:com.example.demo::module:abc123",
        )

    def test_resolve_llvm_dis_path_prefers_explicit_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            explicit = root / "explicit-llvm-dis"
            fallback = root / "fallback-llvm-dis"
            explicit.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fallback.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            explicit.chmod(0o755)
            fallback.chmod(0o755)

            resolved, candidates = roundtrip_runner.resolve_llvm_dis_path(
                candidates=[explicit, fallback]
            )

            self.assertEqual(resolved.resolve(), explicit.resolve())
            self.assertEqual([path.resolve() for path in candidates], [explicit.resolve(), fallback.resolve()])

    def test_resolve_replay_baseline_report_path_uses_default_baseline_json(self) -> None:
        parser = roundtrip_runner.build_parser()
        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "roundtrip"
            output_root.mkdir(parents=True, exist_ok=True)
            default_baseline = output_root / "baseline.json"
            default_baseline.write_text("{}", encoding="utf-8")

            args = parser.parse_args(["--output-root", str(output_root)])

            self.assertEqual(
                roundtrip_runner.resolve_replay_baseline_report_path(args, output_root),
                default_baseline.resolve(),
            )

    def test_test_data_batch_has_no_default_gate_profile(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "test-data-batch"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertIsNone(gate_profile_name)
        self.assertIsNone(gate_profile)

    def test_local_diagnostics_batch_preset_skips_fixed_contract_summary(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "local-diagnostics-batch"])
        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        contract = roundtrip_runner.build_preset_contract_summary(
            "local-diagnostics-batch",
            REPO_ROOT,
            [
                {
                    "jobID": 1,
                    "comparisonKey": "shaderSourceDiagnostics::bundle:com.example.demo::module:abc123",
                    "sourceKind": "shader_source_diagnostics",
                    "inputPath": "/tmp/module.ll",
                    "bundleId": "com.example.demo",
                    "moduleKey": "abc123",
                    "sampleKey": "abc123",
                    "sampleIdentity": "shaderSourceDiagnostics::bundle:com.example.demo::module:abc123",
                    "metadataPath": "/tmp/module.meta.json",
                    "functionNames": ["demo"],
                    "functionTypes": ["kernel"],
                }
            ],
        )

        self.assertIsNone(contract)

    def test_build_compare_result_returns_l3_for_roundtrip_failure(self) -> None:
        result = roundtrip_runner.build_compare_result(
            make_roundtrip_result(
                roundtrip_status="failed",
                failure_stage="compile",
                error_summary="metal compile failed",
            )
        )

        self.assertEqual(result["riskLevel"], "L3")
        self.assertEqual(result["riskReason"], "metal compile failed")
        self.assertFalse(result["compareAvailable"])
        self.assertEqual(result["differenceCount"], 0)

    def test_build_compare_result_returns_l3_for_missing_ir_paths(self) -> None:
        result = roundtrip_runner.build_compare_result(
            make_roundtrip_result(
                original_ir_path=str(TEST_SAMPLE),
                regenerated_ir_path=None,
            )
        )

        self.assertEqual(result["riskLevel"], "L3")
        self.assertEqual(result["riskReason"], "missing original/regenerated IR path")
        self.assertFalse(result["compareAvailable"])

    def test_build_compare_result_handles_canonical_compare_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            original_ir_path = Path(temp_dir) / "original.ll"
            original_ir_path.write_text(TEST_SAMPLE.read_text(encoding="utf-8"), encoding="utf-8")
            regenerated_ir_path = Path(temp_dir) / "missing-regenerated.ll"

            result = roundtrip_runner.build_compare_result(
                make_roundtrip_result(
                    original_ir_path=str(original_ir_path),
                    regenerated_ir_path=str(regenerated_ir_path),
                )
            )

        self.assertEqual(result["riskLevel"], "L3")
        self.assertEqual(result["riskReason"], "canonical compare failed")
        self.assertFalse(result["compareAvailable"])
        self.assertTrue(result["compareError"])

    def test_build_compare_result_performs_canonical_compare_on_success(self) -> None:
        result = roundtrip_runner.build_compare_result(
            make_roundtrip_result(
                original_ir_path=str(TEST_SAMPLE),
                regenerated_ir_path=str(TEST_SAMPLE),
            )
        )

        self.assertTrue(result["compareAvailable"])
        self.assertEqual(result["riskLevel"], "L0")
        self.assertTrue(result["same"])
        self.assertEqual(result["differenceCount"], 0)
        self.assertIsNotNone(result["originalSummary"])
        self.assertIsNotNone(result["regeneratedSummary"])

    def test_build_preset_manifest_records_gate_profile_and_baseline(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(
            [
                "--preset",
                "test-data-representatives",
                "--allow-failures",
                "--enforce-gate",
            ]
        )
        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        output_root = REPO_ROOT / "build" / "semantics-validation" / "roundtrip" / "test-data-representatives"
        manifest_path = output_root / "preset-manifest.json"
        baseline_path = output_root / "baseline.json"
        representative_sample = Path(
            roundtrip_runner.make_test_data_paths(
                REPO_ROOT,
                [roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES[0]],
            )[0]
        )
        job = roundtrip_runner.replay_runner.ReplayJob(
            job_id=1,
            source_kind="explicit_ll",
            input_path=representative_sample,
            output_path=output_root / "manual" / f"001-{representative_sample.stem}" / "generated.metal",
            function_names=[representative_sample.stem],
            function_types=["kernel"],
        )
        baseline_snapshot = {
            "baselinePath": str(baseline_path),
            "totalJobs": len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES),
        }
        saved_baseline = {
            "baselinePath": str(baseline_path),
            "baselineAssetRoot": "generated-sources",
        }

        manifest = roundtrip_runner.build_preset_manifest(
            args,
            output_root,
            manifest_path,
            [job],
            REPO_ROOT,
            {
                "roundtripReportPath": str(output_root / "roundtrip-summary.json"),
                "gateSummaryPath": str(output_root / "gate-summary.json"),
            },
            baseline_path,
            baseline_snapshot,
            saved_baseline,
        )

        self.assertEqual(manifest["presetName"], "test-data-representatives")
        self.assertEqual(manifest["gateProfileName"], "test-data-representatives")
        self.assertEqual(
            manifest["gateProfile"]["expectedJobCount"],
            len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES),
        )
        self.assertEqual(manifest["requestedInputs"]["llInputs"], args.ll_inputs)
        self.assertEqual(manifest["baseline"]["reportPath"], str(baseline_path))
        self.assertEqual(manifest["baseline"]["activeSnapshot"], baseline_snapshot)
        self.assertEqual(manifest["baseline"]["savedBaseline"], saved_baseline)
        self.assertEqual(manifest["discovery"]["jobCount"], 1)
        self.assertEqual(manifest["discovery"]["sourceKinds"]["explicitLL"], 1)
        self.assertEqual(manifest["discovery"]["sourceKinds"]["shaderCorpus"], 0)
        self.assertEqual(manifest["discovery"]["sourceKinds"]["shaderSourceDiagnostics"], 0)
        self.assertEqual(manifest["discovery"]["jobs"][0]["functionNames"], [representative_sample.stem])
        self.assertEqual(
            manifest["discovery"]["jobs"][0]["comparisonKey"],
            roundtrip_runner.replay_runner.make_comparison_key(
                "explicit_ll",
                None,
                None,
                str(representative_sample),
            ),
        )
        contract = manifest["presetContract"]
        self.assertEqual(contract["status"], "missing_expected_jobs")
        self.assertEqual(contract["expectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))
        self.assertEqual(contract["matchedExpectedJobCount"], 1)
        self.assertEqual(contract["missingExpectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES) - 1)
        self.assertEqual(contract["unexpectedDiscoveredJobCount"], 0)
        self.assertEqual(contract["matchedSourceKinds"]["explicitLL"], 1)
        self.assertEqual(contract["missingSourceKinds"]["explicitLL"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES) - 1)

    def test_build_preset_contract_summary_flags_unexpected_discovered_jobs(self) -> None:
        expected_jobs = roundtrip_runner.build_expected_preset_contract_jobs(
            "test-data-representatives",
            REPO_ROOT,
        )
        discovered_jobs = [
            {
                **entry,
                "jobID": index,
                "metadataPath": None,
                "functionNames": [],
                "functionTypes": [],
            }
            for index, entry in enumerate(expected_jobs)
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            unexpected_path = Path(temp_dir) / "unexpected.ll"
            unexpected_path.write_text("define void @unexpected() { ret void }\n", encoding="utf-8")
            unexpected_entry = {
                **roundtrip_runner.build_expected_ll_contract_entry(unexpected_path),
                "jobID": len(discovered_jobs),
                "metadataPath": None,
                "functionNames": [],
                "functionTypes": [],
            }
            discovered_jobs.append(unexpected_entry)

            contract = roundtrip_runner.build_preset_contract_summary(
                "test-data-representatives",
                REPO_ROOT,
                discovered_jobs,
            )

        self.assertIsNotNone(contract)
        assert contract is not None
        self.assertEqual(contract["status"], "unexpected_discovered_jobs")
        self.assertEqual(contract["expectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))
        self.assertEqual(contract["matchedExpectedJobCount"], len(roundtrip_runner.TEST_DATA_REPRESENTATIVE_FILES))
        self.assertEqual(contract["missingExpectedJobCount"], 0)
        self.assertEqual(contract["unexpectedDiscoveredJobCount"], 1)
        self.assertEqual(contract["unexpectedSourceKinds"]["explicitLL"], 1)
        self.assertEqual(contract["unexpectedDiscoveredJobs"][0]["sampleKey"], "unexpected")

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_generates_roundtrip_summary_for_sample(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "roundtrip"
            first_completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_SAMPLE),
                    "--output-root",
                    str(output_root),
                    "--save-baseline",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("semantics round-trip summary", first_completed.stdout)
            self.assertIn("saved replay baseline:", first_completed.stdout)

            second_completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_SAMPLE),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("replay baseline:", second_completed.stdout)

            report_path = output_root / "roundtrip-summary.json"
            replay_report_path = output_root / "replay-summary.json"
            compile_report_path = output_root / "compile-summary.json"
            compare_report_path = output_root / "compare-summary.json"
            risk_report_path = output_root / "risk-report.json"
            high_risk_path = output_root / "high-risk-samples.json"
            gate_summary_path = output_root / "gate-summary.json"
            manifest_path = output_root / "preset-manifest.json"
            baseline_path = output_root / "baseline.json"
            self.assertTrue(report_path.is_file())
            self.assertTrue(replay_report_path.is_file())
            self.assertTrue(compile_report_path.is_file())
            self.assertTrue(compare_report_path.is_file())
            self.assertTrue(risk_report_path.is_file())
            self.assertTrue(high_risk_path.is_file())
            self.assertTrue(gate_summary_path.is_file())
            self.assertTrue(manifest_path.is_file())
            self.assertTrue(baseline_path.is_file())

            report = json.loads(report_path.read_text(encoding="utf-8"))
            replay_report = json.loads(replay_report_path.read_text(encoding="utf-8"))
            compare_report = json.loads(compare_report_path.read_text(encoding="utf-8"))
            risk_report = json.loads(risk_report_path.read_text(encoding="utf-8"))
            high_risk_samples = json.loads(high_risk_path.read_text(encoding="utf-8"))
            gate_summary = json.loads(gate_summary_path.read_text(encoding="utf-8"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(report["jobCount"], 1)
            self.assertEqual(report["roundTripSucceededJobs"], 1)
            self.assertEqual(report["roundTripFailedJobs"], 0)
            self.assertEqual(report["compileFailedJobs"], 0)
            self.assertEqual(report["llvmDisFailedJobs"], 0)
            self.assertEqual(report["llvmDisassembler"]["resolvedPath"], str(default_llvm_dis))
            self.assertEqual(len(report["results"]), 1)
            self.assertEqual(compare_report["jobCount"], 1)
            self.assertEqual(compare_report["compareAvailableJobs"], 1)
            self.assertEqual(risk_report["jobCount"], 1)
            self.assertIsInstance(high_risk_samples, list)
            self.assertEqual(gate_summary["jobCount"], 1)
            self.assertIn(gate_summary["status"], {"pass", "warn", "fail"})
            self.assertEqual(Path(gate_summary["reportPath"]).resolve(), gate_summary_path.resolve())
            layered_decision = gate_summary.get("layeredDecision") or {}
            self.assertEqual(layered_decision.get("currentLayer"), "L2")
            self.assertIn(layered_decision.get("overallDecision"), {"stay_at_l2", "stop_at_l2", "promote_l2_candidates_to_l3"})
            self.assertIn("l3Plan", layered_decision)
            self.assertIn("l4Plan", layered_decision)
            self.assertEqual(Path(manifest["reportPath"]).resolve(), manifest_path.resolve())
            self.assertEqual(manifest["discovery"]["jobCount"], 1)
            self.assertEqual(manifest["baseline"]["reportPath"], str(baseline_path.resolve()))
            self.assertEqual(manifest["baseline"]["activeSnapshot"]["baselinePath"], str(baseline_path.resolve()))
            self.assertEqual(manifest["baseline"]["activeSnapshot"]["baselineAssetRoot"], "generated-sources")
            self.assertIsNone(manifest["baseline"]["savedBaseline"])

            replay_baseline = replay_report.get("baselineComparison") or {}
            self.assertEqual(replay_baseline.get("matchedJobs"), 1)
            self.assertEqual(replay_baseline.get("newJobs"), 0)
            self.assertEqual(replay_baseline.get("replayRegressions"), 0)
            self.assertEqual(replay_baseline.get("compileRegressions"), 0)
            self.assertEqual(Path(replay_baseline["baselinePath"]).resolve(), baseline_path.resolve())

            result = report["results"][0]
            self.assertEqual(result["replayStatus"], "success")
            self.assertEqual(result["compileStatus"], "success")
            self.assertEqual(result["llvmDisStatus"], "success")
            self.assertEqual(result["roundTripStatus"], "success")
            self.assertIsNone(result["failureStage"])
            self.assertEqual(result["replayBaselineComparison"]["status"], "unchanged")

            compare_result = compare_report["results"][0]
            self.assertTrue(compare_result["compareAvailable"])
            self.assertIn(compare_result["riskLevel"], {"L0", "L1", "L2", "L3"})
            self.assertIn("recommendedAction", compare_result)
            self.assertIn("entryComparison", compare_result)
            self.assertEqual(risk_report["samples"][0]["comparisonKey"], compare_result["comparisonKey"])

            original_ir_path = Path(result["originalIRPath"])
            generated_msl_path = Path(result["generatedMSLPath"])
            generated_air_path = Path(result["generatedAIRPath"])
            regenerated_ir_path = Path(result["regeneratedIRPath"])
            self.assertTrue(original_ir_path.is_file())
            self.assertTrue(generated_msl_path.is_file())
            self.assertTrue(generated_air_path.is_file())
            self.assertTrue(regenerated_ir_path.is_file())

            self.assertEqual(original_ir_path.read_text(encoding="utf-8"), TEST_SAMPLE.read_text(encoding="utf-8"))
            self.assertGreater(regenerated_ir_path.stat().st_size, 0)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_preserves_single_field_fragment_output_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "fragment-packed-return.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_FRAGMENT_PACKED_RETURN_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("struct Test_fragment_packed_Out {", generated_text)
            self.assertIn("float4 color [[color(0)]];", generated_text)
            self.assertIn("fragment Test_fragment_packed_Out test_fragment_packed", generated_text)
            self.assertIn("return Test_fragment_packed_Out{ float4(position) };", generated_text)

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_preserves_single_field_fragment_output_wrapper(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "fragment-packed-return"
            completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_FRAGMENT_PACKED_RETURN_SAMPLE),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("semantics round-trip summary", completed.stdout)
            compare_report = json.loads((output_root / "compare-summary.json").read_text(encoding="utf-8"))
            risk_report = json.loads((output_root / "risk-report.json").read_text(encoding="utf-8"))
            compare_result = compare_report["results"][0]

            self.assertEqual(compare_result["riskLevel"], "L0")
            self.assertTrue(compare_result["same"])
            self.assertEqual(compare_result["entryComparison"]["severity"], "L0")
            self.assertFalse(any(item["reason"] == "entry 返回类型摘要变化" for item in compare_result["differences"]))
            self.assertEqual(risk_report["blockedSamples"], [])

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_does_not_invent_fragment_position_input(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "fragment-no-entry-input.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_FRAGMENT_NO_ENTRY_INPUT_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("fragment Test_fragment_no_entry_input_Out test_fragment_no_entry_input()", generated_text)
            self.assertNotIn("[[position]]", generated_text)

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_preserves_zero_input_fragment_signature(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "fragment-no-entry-input"
            completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_FRAGMENT_NO_ENTRY_INPUT_SAMPLE),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("semantics round-trip summary", completed.stdout)
            compare_report = json.loads((output_root / "compare-summary.json").read_text(encoding="utf-8"))
            risk_report = json.loads((output_root / "risk-report.json").read_text(encoding="utf-8"))
            roundtrip_report = json.loads((output_root / "roundtrip-summary.json").read_text(encoding="utf-8"))
            compare_result = compare_report["results"][0]
            generated_msl = Path(roundtrip_report["results"][0]["generatedMSLPath"]).read_text(encoding="utf-8")
            regenerated_ir = Path(roundtrip_report["results"][0]["regeneratedIRPath"]).read_text(encoding="utf-8")

            self.assertEqual(compare_result["entryComparison"]["severity"], "L0")
            self.assertFalse(any(item["reason"] == "entry 参数个数变化" for item in compare_result["differences"]))
            self.assertFalse(any(item["reason"] == "entry 参数类型摘要变化" for item in compare_result["differences"]))
            self.assertFalse(any(item["reason"] == "entry 参数语义摘要变化" for item in compare_result["differences"]))
            self.assertEqual(risk_report["blockedSamples"], [])
            self.assertIn("fragment Test_fragment_no_entry_input_Out test_fragment_no_entry_input()", generated_msl)
            self.assertNotIn("[[position]]", generated_msl)
            self.assertIn("define <{ <4 x float>, <4 x float> }> @test_fragment_no_entry_input()", regenerated_ir)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_keeps_underscore_prefixed_constant_struct_as_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "underscore-struct-reference.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_UNDERSCORE_STRUCT_REFERENCE_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn(
                "const constant _ShadowParams_Type& shadowParams [[buffer(0)]]",
                generated_text,
            )
            self.assertNotIn(
                "const constant _ShadowParams_Type* shadowParams [[buffer(0)]]",
                generated_text,
            )

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_preserves_dereferenceable_for_underscore_prefixed_constant_struct(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "underscore-struct-reference"
            completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_UNDERSCORE_STRUCT_REFERENCE_SAMPLE),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("semantics round-trip summary", completed.stdout)
            compare_report = json.loads((output_root / "compare-summary.json").read_text(encoding="utf-8"))
            risk_report = json.loads((output_root / "risk-report.json").read_text(encoding="utf-8"))
            compare_result = compare_report["results"][0]
            roundtrip_report = json.loads((output_root / "roundtrip-summary.json").read_text(encoding="utf-8"))
            regenerated_ir_path = Path(roundtrip_report["results"][0]["regeneratedIRPath"])
            regenerated_ir = regenerated_ir_path.read_text(encoding="utf-8")

            self.assertEqual(compare_result["entryComparison"]["severity"], "L0")
            self.assertFalse(any(item["reason"] == "entry 参数类型摘要变化" for item in compare_result["differences"]))
            self.assertEqual(risk_report["blockedSamples"], [])
            self.assertIn("dereferenceable(4)", regenerated_ir)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_preserves_invariant_position_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "vertex-position-invariant.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_VERTEX_POSITION_INVARIANT_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("struct Test_vertex_position_invariant_Out {", generated_text)
            self.assertIn("float4 position [[position, invariant]];", generated_text)
            self.assertIn("float2 texcoord;", generated_text)

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_preserves_invariant_position_output_semantics(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "vertex-position-invariant"
            completed = subprocess.run(
                [
                    "python3",
                    str(ROUNDTRIP_SCRIPT),
                    "--ll",
                    str(TEST_VERTEX_POSITION_INVARIANT_SAMPLE),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("semantics round-trip summary", completed.stdout)
            compare_report = json.loads((output_root / "compare-summary.json").read_text(encoding="utf-8"))
            risk_report = json.loads((output_root / "risk-report.json").read_text(encoding="utf-8"))
            compare_result = compare_report["results"][0]
            roundtrip_report = json.loads((output_root / "roundtrip-summary.json").read_text(encoding="utf-8"))
            regenerated_ir_path = Path(roundtrip_report["results"][0]["regeneratedIRPath"])
            generated_msl_path = Path(roundtrip_report["results"][0]["generatedMSLPath"])
            regenerated_ir = regenerated_ir_path.read_text(encoding="utf-8")
            generated_msl = generated_msl_path.read_text(encoding="utf-8")

            self.assertNotEqual(compare_result["riskLevel"], "L3")
            self.assertEqual(compare_result["entryComparison"]["severity"], "L0")
            self.assertFalse(any(item["reason"] == "entry 输出语义摘要变化" for item in compare_result["differences"]))
            self.assertEqual(risk_report["blockedSamples"], [])
            self.assertIn("air.invariant", regenerated_ir)
            self.assertIn("float4 position [[position, invariant]];", generated_msl)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_preserves_internal_sampler_state_globals(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "sampler-state-globals.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_SAMPLER_STATE_GLOBALS_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("constexpr sampler __air_sampler_state(", generated_text)
            self.assertIn("constexpr sampler __air_sampler_state_1(", generated_text)
            self.assertIn("historyTexture.sample(__air_sampler_state, stageIn.TEXCOORD0)", generated_text)
            self.assertIn("shadowTexture.sample_compare(__air_sampler_state_1, stageIn.TEXCOORD0,", generated_text)
            self.assertNotIn("historyTexture.sample(shadowTexture", generated_text)
            self.assertNotIn("sample_compare(historyTexture", generated_text)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_preserves_phi_branch_structure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "phi.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_PHI_BRANCH_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("if (", generated_text)
            self.assertIn("phi_0 = 1", generated_text)
            self.assertIn("phi_0 = 2", generated_text)
            self.assertIn("} else {", generated_text)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_keeps_simple_diamond_when_later_cfg_is_not_structured(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "partial-structured.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_PARTIAL_STRUCTURED_CFG_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("if (", generated_text)
            self.assertIn("phi_0 = 1", generated_text)
            self.assertIn("phi_0 = 2", generated_text)
            self.assertIn("} else {", generated_text)
            self.assertNotIn("// → BB3", generated_text)
            self.assertNotIn("// → BB4", generated_text)
            self.assertIn("// → BB11", generated_text)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_keeps_emitting_blocks_after_entry_fallback_condbr(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "entry-partial-structured.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_ENTRY_PARTIAL_STRUCTURED_CFG_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("phi_0 = 1", generated_text)
            self.assertIn("phi_0 = 2", generated_text)
            self.assertGreaterEqual(generated_text.count("if ("), 2)
            self.assertIn("*(output) = phi_0", generated_text)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_defers_final_merge_until_late_predecessors_are_emitted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "late-merge-fallback.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_LATE_MERGE_FALLBACK_ORDER_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("// phi from BB15", generated_text)
            self.assertIn("// phi from BB17", generated_text)
            return_index = generated_text.index("return;")
            self.assertGreater(return_index, generated_text.index("// phi from BB15"))
            self.assertGreater(return_index, generated_text.index("// phi from BB17"))
            self.assertEqual(generated_text.count("return;"), 1)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_blocks_unconditional_successor_until_nested_predecessors_are_emitted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "unconditional-successor-gating.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_UNCONDITIONAL_SUCCESSOR_GATING_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("if (", generated_text)
            self.assertIn("phi_0 = 1", generated_text)
            self.assertIn("phi_0 = 2", generated_text)
            self.assertIn("phi_0 = 3", generated_text)
            store_index = generated_text.index("*(output) = phi_0")
            self.assertGreater(store_index, generated_text.index("phi_0 = 2"))
            self.assertGreater(store_index, generated_text.index("phi_0 = 3"))
            return_index = generated_text.index("return;")
            self.assertGreater(return_index, generated_text.index("phi_0 = 2"))
            self.assertGreater(return_index, generated_text.index("phi_0 = 3"))
            self.assertEqual(generated_text.count("return;"), 1)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_defers_structured_merge_until_external_predecessors_are_emitted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "structured-merge-late-predecessor.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_STRUCTURED_MERGE_LATE_PREDECESSOR_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertIn("phi_0 = 1.0", generated_text)
            self.assertIn("phi_0 = 2.0", generated_text)
            self.assertIn("phi_0 = 3.0", generated_text)
            self.assertIn("phi_0 = 4", generated_text)
            store_index = generated_text.index("*(output) = phi_0")
            self.assertGreater(store_index, generated_text.index("phi_0 = 4"))
            return_index = generated_text.index("return;")
            self.assertGreater(return_index, generated_text.index("phi_0 = 4"))
            self.assertEqual(generated_text.count("return;"), 1)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_keeps_nested_common_merge_inside_branch_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "nested-common-merge.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_NESTED_COMMON_MERGE_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertGreaterEqual(generated_text.count("if ("), 3)
            self.assertIn("phi_0 = 1.0", generated_text)
            self.assertIn("phi_0 = 2.0", generated_text)
            self.assertIn("phi_0 = 3.0", generated_text)
            self.assertIn("phi_1 = 4", generated_text)
            self.assertIn("phi_1 = phi_0", generated_text)
            store_index = generated_text.index("*(output) = phi_1")
            self.assertGreater(store_index, generated_text.index("phi_1 = 4"))
            self.assertGreater(store_index, generated_text.index("phi_1 = phi_0"))
            self.assertEqual(generated_text.count("return;"), 1)

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
    def test_corpus_replay_runner_keeps_nested_common_merge_when_later_cfg_is_unstructured(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            generated_path = Path(temp_dir) / "nested-common-merge-unstructured-tail.generated.metal"
            completed = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "Scripts" / "corpus_replay_runner.py"),
                    "--ll",
                    str(TEST_NESTED_COMMON_MERGE_WITH_UNSTRUCTURED_TAIL_SAMPLE),
                    "--output-file",
                    str(generated_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("replay summary", completed.stdout)
            generated_text = generated_path.read_text(encoding="utf-8")
            self.assertGreaterEqual(generated_text.count("if ("), 2)
            self.assertIn("phi_0 = 1", generated_text)
            self.assertIn("phi_0 = 2", generated_text)
            self.assertIn("phi_1 = phi_0", generated_text)
            self.assertIn("phi_1 = 4", generated_text)
            self.assertNotIn("// → BB20", generated_text)
            self.assertNotIn("// → BB30", generated_text)
            store_index = generated_text.index("*(output) = phi_1")
            self.assertGreater(store_index, generated_text.index("phi_1 = 4"))
            self.assertGreater(store_index, generated_text.index("phi_1 = phi_0"))
            self.assertEqual(generated_text.count("return;"), 1)


if __name__ == "__main__":
    unittest.main()
