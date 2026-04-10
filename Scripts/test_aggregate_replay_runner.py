from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
AGGREGATE_SCRIPT = SCRIPTS_DIR / "aggregate_replay_runner.py"
TEST_FRAGMENT_PACKED_RETURN_SAMPLE = (
    REPO_ROOT
    / "LocalDocs"
    / "XCodeReleaseShaderDebug"
    / "RoadE-HookMakeLibraryWithSrc"
    / "test-data"
    / "test_fragment_packed_return.ll"
)

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import aggregate_replay_runner as aggregate_runner


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


class AggregateReplayRunnerTests(unittest.TestCase):
    def test_resolve_manifest_capture_order_prefers_matching_capture_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle_root = Path(temp_dir) / "ShaderCorpus" / "com.example.demo"
            write_jsonl(
                bundle_root / "manifest.jsonl",
                [
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-b",
                    },
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-a",
                    },
                ],
            )
            warnings: list = []

            ordered, source = aggregate_runner.resolve_manifest_capture_order(
                bundle_root,
                "newLibraryWithData:error:",
                "cache-key",
                "2026-04-10T20:00:00Z",
                ["module-a", "module-b"],
                warnings,
            )

        self.assertEqual(ordered, ["module-b", "module-a"])
        self.assertEqual(source, "manifest_capture_order")
        self.assertEqual(warnings, [])

    def test_resolve_aggregate_compile_metal_args_requires_full_alignment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            enable_a = root / "enable-a.ll"
            enable_b = root / "enable-b.ll"
            disable_c = root / "disable-c.ll"
            unknown_d = root / "unknown-d.ll"
            enable_a.write_text('!1 = !{!"air.compile.fast_math_enable"}\n', encoding="utf-8")
            enable_b.write_text('!1 = !{!"air.compile.fast_math_enable"}\n', encoding="utf-8")
            disable_c.write_text('!1 = !{!"air.compile.fast_math_disable"}\n', encoding="utf-8")
            unknown_d.write_text('; no compile options\n', encoding="utf-8")

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, enable_b],
                [],
            )
            self.assertEqual(mode, "enable")
            self.assertEqual(reason, "fast_math_aligned")
            self.assertEqual(inferred_args, ["-ffast-math"])
            self.assertEqual(effective_args, ["-ffast-math"])

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, disable_c],
                [],
            )
            self.assertIsNone(mode)
            self.assertEqual(reason, "fast_math_conflict")
            self.assertEqual(inferred_args, [])
            self.assertEqual(effective_args, [])

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, unknown_d],
                [],
            )
            self.assertIsNone(mode)
            self.assertEqual(reason, "fast_math_partial")
            self.assertEqual(inferred_args, [])
            self.assertEqual(effective_args, [])

    def test_build_aggregate_source_deduplicates_duplicate_functions_and_strips_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output_dir = root / "out"
            replacement_dir = root / "replacement"
            replacement_meta = replacement_dir / "replacement.meta.json"
            replacement_meta.parent.mkdir(parents=True, exist_ok=True)
            replacement_meta.write_text("{}\n", encoding="utf-8")

            source_a = output_dir / "modules" / "module-a" / "replayed.generated.metal"
            source_b = output_dir / "modules" / "module-b" / "replayed.generated.metal"
            source_a.parent.mkdir(parents=True, exist_ok=True)
            source_b.parent.mkdir(parents=True, exist_ok=True)
            source_a.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n\nfragment float4 main0() { return float4(1.0); }\n",
                encoding="utf-8",
            )
            source_b.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n\nfragment float4 main0() { return float4(0.5); }\n",
                encoding="utf-8",
            )

            job = aggregate_runner.AggregateReplayJob(
                job_id=1,
                bundle_id="com.example.demo",
                selector="newLibraryWithData:error:",
                cache_key="cache-key",
                timestamp="2026-04-10T20:00:00Z",
                replacement_dir=replacement_dir,
                replacement_meta_path=replacement_meta,
                aggregate_baseline_path=None,
                module_keys=["module-a", "module-b"],
                modules=[
                    aggregate_runner.AggregateModuleInput(
                        module_key="module-a",
                        input_path=root / "module-a.ll",
                        metadata_path=None,
                        baseline_generated_msl_path=None,
                        function_names=[],
                        function_types=[],
                        generated_function_names=[],
                        generated_function_types=[],
                        module_summary="summary-a",
                        llvm_ir_bytes=8,
                        output_path=source_a,
                    ),
                    aggregate_runner.AggregateModuleInput(
                        module_key="module-b",
                        input_path=root / "module-b.ll",
                        metadata_path=None,
                        baseline_generated_msl_path=None,
                        function_names=[],
                        function_types=[],
                        generated_function_names=[],
                        generated_function_types=[],
                        module_summary="summary-b",
                        llvm_ir_bytes=8,
                        output_path=source_b,
                    ),
                ],
                output_dir=output_dir,
                aggregate_output_path=output_dir / "aggregate.replayed.generated.metal",
                module_order_source="replacement_meta",
            )
            job.modules[0].input_path.write_text("; a\n", encoding="utf-8")
            job.modules[1].input_path.write_text("; b\n", encoding="utf-8")
            module_results = [
                {
                    "outputPath": str(source_a),
                    "generatedFunctionNames": ["main0"],
                    "generatedFunctionTypes": ["fragment"],
                },
                {
                    "outputPath": str(source_b),
                    "generatedFunctionNames": ["main0"],
                    "generatedFunctionTypes": ["fragment"],
                },
            ]

            aggregate = aggregate_runner.build_aggregate_source(job, module_results)
            generated_text = Path(aggregate["sourcePath"]).read_text(encoding="utf-8")

        self.assertTrue(aggregate["success"])
        self.assertEqual(aggregate["dedupeSkippedModuleCount"], 1)
        self.assertEqual(aggregate["deduplicatedModuleKeys"], ["module-a"])
        self.assertEqual(aggregate["duplicateFunctionNames"], ["main0"])
        self.assertEqual(generated_text.count("fragment float4 main0()"), 1)
        self.assertIn("// ===== Module 0 summary-a =====", generated_text)
        self.assertNotIn("summary-b", generated_text)

    def test_discover_jobs_reads_replacement_directory_and_module_order(self) -> None:
        parser = aggregate_runner.build_parser()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            corpus_root = root / "ShaderCorpus"
            bundle_root = corpus_root / "com.example.demo"
            replacement_dir = bundle_root / "replacements" / "20260410_selector_cache"
            replacement_dir.mkdir(parents=True, exist_ok=True)
            for module_key in ["module-a", "module-b"]:
                module_dir = bundle_root / "modules" / module_key
                module_dir.mkdir(parents=True, exist_ok=True)
                (module_dir / "module.ll").write_text(f"; {module_key}\n", encoding="utf-8")
                write_json(
                    module_dir / "module.meta.json",
                    {
                        "bundleId": "com.example.demo",
                        "moduleKey": module_key,
                        "moduleSummary": f"summary-{module_key}",
                    },
                )
            write_json(
                replacement_dir / "replacement.meta.json",
                {
                    "bundleId": "com.example.demo",
                    "selector": "newLibraryWithData:error:",
                    "cacheKey": "cache-key",
                    "timestamp": "2026-04-10T20:00:00Z",
                    "moduleKeys": ["module-a", "module-b"],
                },
            )
            (replacement_dir / "aggregate.generated.metal").write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n",
                encoding="utf-8",
            )
            write_jsonl(
                bundle_root / "manifest.jsonl",
                [
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-b",
                    },
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-a",
                    },
                ],
            )

            args = parser.parse_args(["--corpus-root", str(corpus_root), "--bundle-id", "com.example.demo"])
            warnings: list = []
            jobs = aggregate_runner.discover_jobs(args, root / "out", warnings)

        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0].bundle_id, "com.example.demo")
        self.assertEqual(jobs[0].module_keys, ["module-b", "module-a"])
        self.assertEqual(jobs[0].module_order_source, "manifest_capture_order")
        self.assertEqual([module.module_key for module in jobs[0].modules], ["module-b", "module-a"])
        self.assertEqual(warnings, [])

    def test_compile_aggregate_source_rejects_preflight_before_invoking_xcrun(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "aggregate.replayed.generated.metal"
            source_path.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n\nptr bad_token = ptr(0);\n",
                encoding="utf-8",
            )
            args = argparse.Namespace(compile_backend="xcrun", metal_sdk="macosx", metal_args=[], skip_preflight=False)
            aggregate_result = {"success": True, "sourcePath": str(source_path)}

            with mock.patch.object(aggregate_runner.subprocess, "run") as run_mock:
                compile_result = aggregate_runner.compile_aggregate_source(
                    aggregate_result,
                    [],
                    args,
                    job_id=1,
                    bundle_id="com.example.demo",
                    replacement_key="replacement-key",
                    module_keys=["module-a"],
                )

        self.assertEqual(compile_result["status"], "preflight_rejected")
        self.assertFalse(compile_result["success"])
        self.assertGreater(compile_result["preflightIssueCount"], 0)
        run_mock.assert_not_called()

    @unittest.skipUnless(shutil.which("swiftc") and shutil.which("xcrun"), "requires swiftc and xcrun")
    def test_cli_rebuilds_duplicate_modules_and_compiles_aggregate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            corpus_root = root / "ShaderCorpus"
            bundle_root = corpus_root / "com.example.demo"
            replacement_dir = bundle_root / "replacements" / "20260410_selector_cache"
            replacement_dir.mkdir(parents=True, exist_ok=True)

            for module_key in ["module-a", "module-b"]:
                module_dir = bundle_root / "modules" / module_key
                module_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(TEST_FRAGMENT_PACKED_RETURN_SAMPLE, module_dir / "module.ll")
                write_json(
                    module_dir / "module.meta.json",
                    {
                        "bundleId": "com.example.demo",
                        "moduleKey": module_key,
                        "selector": "newLibraryWithData:error:",
                        "moduleSummary": f"summary-{module_key}",
                    },
                )

            write_json(
                replacement_dir / "replacement.meta.json",
                {
                    "bundleId": "com.example.demo",
                    "selector": "newLibraryWithData:error:",
                    "cacheKey": "cache-key",
                    "timestamp": "2026-04-10T20:00:00Z",
                    "moduleKeys": ["module-a", "module-b"],
                },
            )
            (replacement_dir / "aggregate.generated.metal").write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n// runtime baseline placeholder\n",
                encoding="utf-8",
            )
            write_jsonl(
                bundle_root / "manifest.jsonl",
                [
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-a",
                    },
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-b",
                    },
                ],
            )

            output_root = root / "out"
            completed = subprocess.run(
                [
                    "python3",
                    str(AGGREGATE_SCRIPT),
                    "--corpus-root",
                    str(corpus_root),
                    "--bundle-id",
                    "com.example.demo",
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("aggregate replay summary", completed.stdout)
            report = json.loads((output_root / "aggregate-replay-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["aggregateJobCount"], 1)
            self.assertEqual(report["failedJobs"], 0)
            result = report["results"][0]
            self.assertEqual(result["overallStatus"], "success")
            self.assertEqual(result["aggregate"]["dedupeSkippedModuleCount"], 1)
            self.assertEqual(result["compile"]["status"], "success")
            self.assertEqual(result["compile"]["compileBackend"], "xcrun")
            self.assertTrue(Path(result["aggregate"]["sourcePath"]).is_file())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Metal + swiftc")
    def test_cli_compiles_aggregate_with_mtl_device_backend(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            corpus_root = root / "ShaderCorpus"
            bundle_root = corpus_root / "com.example.demo"
            replacement_dir = bundle_root / "replacements" / "20260410_selector_cache"
            replacement_dir.mkdir(parents=True, exist_ok=True)

            for module_key in ["module-a", "module-b"]:
                module_dir = bundle_root / "modules" / module_key
                module_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(TEST_FRAGMENT_PACKED_RETURN_SAMPLE, module_dir / "module.ll")
                write_json(
                    module_dir / "module.meta.json",
                    {
                        "bundleId": "com.example.demo",
                        "moduleKey": module_key,
                        "selector": "newLibraryWithData:error:",
                        "moduleSummary": f"summary-{module_key}",
                    },
                )

            write_json(
                replacement_dir / "replacement.meta.json",
                {
                    "bundleId": "com.example.demo",
                    "selector": "newLibraryWithData:error:",
                    "cacheKey": "cache-key",
                    "timestamp": "2026-04-10T20:00:00Z",
                    "moduleKeys": ["module-a", "module-b"],
                },
            )
            (replacement_dir / "aggregate.generated.metal").write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n// runtime baseline placeholder\n",
                encoding="utf-8",
            )
            write_jsonl(
                bundle_root / "manifest.jsonl",
                [
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-a",
                    },
                    {
                        "event": "capture",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "cache-key",
                        "timestamp": "2026-04-10T20:00:00Z",
                        "moduleKey": "module-b",
                    },
                ],
            )

            output_root = root / "out"
            completed = subprocess.run(
                [
                    "python3",
                    str(AGGREGATE_SCRIPT),
                    "--corpus-root",
                    str(corpus_root),
                    "--bundle-id",
                    "com.example.demo",
                    "--compile-backend",
                    "mtl-device",
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("aggregate replay summary", completed.stdout)
            report = json.loads((output_root / "aggregate-replay-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["requestedInputs"]["compileBackend"], "mtl-device")
            self.assertEqual(report["aggregateJobCount"], 1)
            self.assertEqual(report["failedJobs"], 0)
            result = report["results"][0]
            self.assertEqual(result["overallStatus"], "success")
            self.assertEqual(result["compile"]["status"], "success")
            self.assertEqual(result["compile"]["compileBackend"], "mtl-device")
            self.assertTrue(Path(result["compile"]["backendReportPath"]).is_file())


if __name__ == "__main__":
    unittest.main()
