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

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_roundtrip_runner_generates_roundtrip_summary_for_sample(self) -> None:
        default_llvm_dis, _ = roundtrip_runner.resolve_llvm_dis_path()
        if default_llvm_dis is None:
            self.skipTest("requires llvm-dis")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "roundtrip"
            completed = subprocess.run(
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

            self.assertIn("semantics round-trip summary", completed.stdout)

            report_path = output_root / "roundtrip-summary.json"
            replay_report_path = output_root / "replay-summary.json"
            compile_report_path = output_root / "compile-summary.json"
            self.assertTrue(report_path.is_file())
            self.assertTrue(replay_report_path.is_file())
            self.assertTrue(compile_report_path.is_file())

            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["jobCount"], 1)
            self.assertEqual(report["roundTripSucceededJobs"], 1)
            self.assertEqual(report["roundTripFailedJobs"], 0)
            self.assertEqual(report["compileFailedJobs"], 0)
            self.assertEqual(report["llvmDisFailedJobs"], 0)
            self.assertEqual(report["llvmDisassembler"]["resolvedPath"], str(default_llvm_dis))
            self.assertEqual(len(report["results"]), 1)

            result = report["results"][0]
            self.assertEqual(result["replayStatus"], "success")
            self.assertEqual(result["compileStatus"], "success")
            self.assertEqual(result["llvmDisStatus"], "success")
            self.assertEqual(result["roundTripStatus"], "success")
            self.assertIsNone(result["failureStage"])

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
