from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
ROUNDTRIP_SCRIPT = SCRIPTS_DIR / "ir_semantics_roundtrip_runner.py"
TEST_SAMPLE = REPO_ROOT / "LocalDocs" / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data" / "test_addrspace.ll"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import ir_semantics_roundtrip_runner as roundtrip_runner


class IRSemanticsRoundtripRunnerTests(unittest.TestCase):
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

    def test_local_corpus_gate_profile_allows_missing_local_samples(self) -> None:
        parser = roundtrip_runner.build_parser()
        args = parser.parse_args(["--preset", "local-corpus-representatives"])

        roundtrip_runner.apply_roundtrip_preset(args, REPO_ROOT)

        gate_profile_name, gate_profile = roundtrip_runner.resolve_gate_profile(args)
        self.assertEqual(gate_profile_name, "local-corpus-representatives")
        self.assertEqual(gate_profile["minimumExpectedJobCount"], 0)
        self.assertEqual(gate_profile["expectedJobCount"], len(roundtrip_runner.LOCAL_SHADERCORPUS_REPRESENTATIVES))

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
            self.assertEqual(Path(manifest["reportPath"]).resolve(), manifest_path.resolve())
            self.assertEqual(manifest["discovery"]["jobCount"], 1)
            self.assertEqual(manifest["baseline"]["reportPath"], str(baseline_path.resolve()))

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


if __name__ == "__main__":
    unittest.main()
