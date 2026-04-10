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


def build_shared_compile_planner_binary(output_root: Path) -> Path:
    return aggregate_runner.replay_runner.build_shared_compile_planner_harness_binary(REPO_ROOT, output_root)


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


VALID_AGGREGATE_SOURCE = (
    "#include <metal_stdlib>\n"
    "using namespace metal;\n\n"
    "kernel void main0(device float* output [[buffer(0)]]) { output[0] = 1.0f; }\n"
)


def run_aggregate_compile_harness(
    root: Path,
    harness_binary: Path,
    *,
    original_ir_texts: list[str],
    metal_args: list[str] | None = None,
    source_text: str = VALID_AGGREGATE_SOURCE,
) -> tuple[subprocess.CompletedProcess[str], dict]:
    source_path = root / "aggregate.replayed.generated.metal"
    report_path = root / "aggregate.compile.report.json"
    source_path.write_text(source_text, encoding="utf-8")

    command = [
        str(harness_binary),
        "--source",
        str(source_path.resolve()),
        "--report",
        str(report_path.resolve()),
    ]
    for index, original_ir_text in enumerate(original_ir_texts):
        original_ir_path = root / f"module-{index}.ll"
        original_ir_path.write_text(original_ir_text, encoding="utf-8")
        command.extend(["--original-ir", str(original_ir_path.resolve())])
    for metal_arg in list(metal_args or []):
        command.extend(["--metal-arg", metal_arg])

    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if completed.returncode == 2 and report.get("error") == "failed to create system default Metal device":
        raise unittest.SkipTest("requires system default Metal device")
    return completed, report


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

    @unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
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
            planner_binary = build_shared_compile_planner_binary(root / "out")

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, enable_b],
                [],
                shared_compile_planner_binary=planner_binary,
            )
            self.assertEqual(mode, "enable")
            self.assertEqual(reason, "fast_math_aligned")
            self.assertEqual(inferred_args, ["-ffast-math"])
            self.assertEqual(effective_args, ["-ffast-math"])

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, disable_c],
                [],
                shared_compile_planner_binary=planner_binary,
            )
            self.assertIsNone(mode)
            self.assertEqual(reason, "fast_math_conflict")
            self.assertEqual(inferred_args, [])
            self.assertEqual(effective_args, [])

            mode, reason, inferred_args, effective_args = aggregate_runner.resolve_aggregate_compile_metal_args(
                [enable_a, unknown_d],
                [],
                shared_compile_planner_binary=planner_binary,
            )
            self.assertIsNone(mode)
            self.assertEqual(reason, "fast_math_partial")
            self.assertEqual(inferred_args, [])
            self.assertEqual(effective_args, [])

    def test_build_aggregate_compile_harness_binary_includes_shared_planner_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir) / "out"
            expected_binary = output_root / "_internal" / "metal_aggregate_compile_harness"

            with mock.patch.object(aggregate_runner.subprocess, "run") as run_mock:
                binary_path = aggregate_runner.build_aggregate_compile_harness_binary(REPO_ROOT, output_root)

        self.assertEqual(binary_path, expected_binary.resolve())
        run_mock.assert_called_once()
        command = run_mock.call_args.args[0]
        self.assertEqual(command[0], "swiftc")
        self.assertEqual(command[1], str(aggregate_runner.replay_runner.shared_compile_decision_manifest_path().resolve()))
        self.assertEqual(command[2], str(aggregate_runner.aggregate_compile_harness_swift_path(REPO_ROOT)))
        self.assertEqual(command[3:], ["-o", str(expected_binary.resolve())])

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Metal + swiftc")
    def test_metal_aggregate_compile_harness_reports_shared_planner_reason_code_matrix(self) -> None:
        enable_ir = '!1 = !{!"air.compile.fast_math_enable"}\n'
        disable_ir = '!1 = !{!"air.compile.fast_math_disable"}\n'
        unknown_ir = '; no compile options\n'

        cases = [
            {
                "name": "aligned_disable",
                "original_ir_texts": [disable_ir],
                "metal_args": [],
                "expected_mode": "disable",
                "expected_decision": "fast_math_aligned",
                "expected_explicit": True,
                "expected_fast_math_enabled": False,
                "expected_inferred": ["-fno-fast-math"],
                "expected_effective": ["-fno-fast-math"],
                "expected_override_source": None,
            },
            {
                "name": "conflict",
                "original_ir_texts": [enable_ir, disable_ir],
                "metal_args": [],
                "expected_mode": None,
                "expected_decision": "fast_math_conflict",
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_inferred": [],
                "expected_effective": [],
                "expected_override_source": None,
            },
            {
                "name": "partial",
                "original_ir_texts": [enable_ir, unknown_ir],
                "metal_args": [],
                "expected_mode": None,
                "expected_decision": "fast_math_partial",
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_inferred": [],
                "expected_effective": [],
                "expected_override_source": None,
            },
            {
                "name": "unavailable",
                "original_ir_texts": [unknown_ir],
                "metal_args": [],
                "expected_mode": None,
                "expected_decision": "fast_math_unavailable",
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_inferred": [],
                "expected_effective": [],
                "expected_override_source": None,
            },
            {
                "name": "user_override",
                "original_ir_texts": [disable_ir],
                "metal_args": ["-ffast-math"],
                "expected_mode": "enable",
                "expected_decision": "user_override",
                "expected_explicit": True,
                "expected_fast_math_enabled": True,
                "expected_inferred": [],
                "expected_effective": ["-ffast-math"],
                "expected_override_source": "user_metal_args",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            harness_binary = aggregate_runner.build_aggregate_compile_harness_binary(REPO_ROOT, root / "out")

            for case in cases:
                with self.subTest(case=case["name"]):
                    case_root = root / case["name"]
                    case_root.mkdir(parents=True, exist_ok=True)
                    completed, report = run_aggregate_compile_harness(
                        case_root,
                        harness_binary,
                        original_ir_texts=case["original_ir_texts"],
                        metal_args=case["metal_args"],
                    )

                    self.assertEqual(completed.returncode, 0, msg=completed.stderr)
                    self.assertTrue(report["success"], msg=report.get("error"))
                    self.assertEqual(report["schemaVersion"], 1)
                    self.assertEqual(report["functionNames"], ["main0"])
                    self.assertEqual(report["functionCount"], 1)
                    self.assertEqual(report.get("fastMathMode"), case["expected_mode"])
                    self.assertEqual(report["fastMathDecision"], case["expected_decision"])
                    self.assertEqual(report["usesExplicitCompileOptions"], case["expected_explicit"])
                    self.assertEqual(report.get("fastMathEnabled"), case["expected_fast_math_enabled"])
                    self.assertEqual(report["inferredMetalArgs"], case["expected_inferred"])
                    self.assertEqual(report["effectiveMetalArgs"], case["expected_effective"])
                    self.assertEqual(report.get("explicitOverrideSource"), case["expected_override_source"])

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

    def test_compile_aggregate_source_reads_compile_decision_from_mtl_device_harness(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "aggregate.replayed.generated.metal"
            source_path.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n\nkernel void main0(device float* output [[buffer(0)]]) { output[0] = 1.0f; }\n",
                encoding="utf-8",
            )
            original_ir_path = root / "module-a.ll"
            original_ir_path.write_text('!1 = !{!"air.compile.fast_math_disable"}\n', encoding="utf-8")
            harness_binary = root / "metal_aggregate_compile_harness"
            harness_binary.write_text("#!/bin/sh\n", encoding="utf-8")
            harness_binary.chmod(0o755)
            args = argparse.Namespace(
                compile_backend="mtl-device",
                metal_sdk="macosx",
                metal_args=[],
                skip_preflight=False,
                aggregate_compile_harness_binary=str(harness_binary),
            )
            aggregate_result = {"success": True, "sourcePath": str(source_path)}

            def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                self.assertFalse(check)
                self.assertTrue(capture_output)
                self.assertTrue(text)
                self.assertNotIn("--manifest-source", command)
                self.assertIn("--original-ir", command)
                self.assertIn(str(original_ir_path.resolve()), command)
                report_path = Path(command[command.index("--report") + 1])
                report_path.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "success": True,
                            "error": None,
                            "functionNames": ["main0"],
                            "functionCount": 1,
                            "usesExplicitCompileOptions": True,
                            "fastMathEnabled": False,
                            "fastMathMode": "disable",
                            "fastMathDecision": "fast_math_aligned",
                            "inferredMetalArgs": ["-fno-fast-math"],
                            "effectiveMetalArgs": ["-fno-fast-math"],
                        },
                        indent=2,
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

            with mock.patch.object(aggregate_runner.subprocess, "run", side_effect=fake_run):
                compile_result = aggregate_runner.compile_aggregate_source(
                    aggregate_result,
                    [original_ir_path],
                    args,
                    job_id=1,
                    bundle_id="com.example.demo",
                    replacement_key="replacement-key",
                    module_keys=["module-a"],
                )

        self.assertEqual(compile_result["status"], "success")
        self.assertTrue(compile_result["success"])
        self.assertEqual(compile_result["compileBackend"], "mtl-device")
        self.assertEqual(compile_result["fastMathMode"], "disable")
        self.assertEqual(compile_result["fastMathDecision"], "fast_math_aligned")
        self.assertEqual(compile_result["inferredMetalArgs"], ["-fno-fast-math"])
        self.assertEqual(compile_result["effectiveMetalArgs"], ["-fno-fast-math"])
        self.assertEqual(compile_result["libraryFunctionNames"], ["main0"])
        self.assertEqual(compile_result["libraryFunctionCount"], 1)
        self.assertTrue(compile_result["usesExplicitCompileOptions"])
        self.assertFalse(compile_result["compileOptionsFastMathEnabled"])

    def test_compile_aggregate_source_reads_user_override_from_mtl_device_harness(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "aggregate.replayed.generated.metal"
            source_path.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n\nkernel void main0(device float* output [[buffer(0)]]) { output[0] = 1.0f; }\n",
                encoding="utf-8",
            )
            original_ir_path = root / "module-a.ll"
            original_ir_path.write_text('!1 = !{!"air.compile.fast_math_disable"}\n', encoding="utf-8")
            harness_binary = root / "metal_aggregate_compile_harness"
            harness_binary.write_text("#!/bin/sh\n", encoding="utf-8")
            harness_binary.chmod(0o755)
            args = argparse.Namespace(
                compile_backend="mtl-device",
                metal_sdk="macosx",
                metal_args=["-ffast-math"],
                skip_preflight=False,
                aggregate_compile_harness_binary=str(harness_binary),
            )
            aggregate_result = {"success": True, "sourcePath": str(source_path)}

            def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                self.assertFalse(check)
                self.assertTrue(capture_output)
                self.assertTrue(text)
                self.assertIn("--original-ir", command)
                self.assertIn(str(original_ir_path.resolve()), command)
                self.assertIn("--metal-arg", command)
                metal_arg_index = command.index("--metal-arg")
                self.assertEqual(command[metal_arg_index + 1], "-ffast-math")
                report_path = Path(command[command.index("--report") + 1])
                report_path.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "success": True,
                            "error": None,
                            "functionNames": ["main0"],
                            "functionCount": 1,
                            "usesExplicitCompileOptions": True,
                            "fastMathEnabled": True,
                            "fastMathMode": "enable",
                            "fastMathDecision": "user_override",
                            "explicitOverrideSource": "user_metal_args",
                            "inferredMetalArgs": [],
                            "effectiveMetalArgs": ["-ffast-math"],
                        },
                        indent=2,
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

            with mock.patch.object(aggregate_runner.subprocess, "run", side_effect=fake_run):
                compile_result = aggregate_runner.compile_aggregate_source(
                    aggregate_result,
                    [original_ir_path],
                    args,
                    job_id=1,
                    bundle_id="com.example.demo",
                    replacement_key="replacement-key",
                    module_keys=["module-a"],
                )

        self.assertEqual(compile_result["status"], "success")
        self.assertTrue(compile_result["success"])
        self.assertEqual(compile_result["compileBackend"], "mtl-device")
        self.assertEqual(compile_result["fastMathMode"], "enable")
        self.assertEqual(compile_result["fastMathDecision"], "user_override")
        self.assertEqual(compile_result["inferredMetalArgs"], [])
        self.assertEqual(compile_result["effectiveMetalArgs"], ["-ffast-math"])
        self.assertTrue(compile_result["usesExplicitCompileOptions"])
        self.assertTrue(compile_result["compileOptionsFastMathEnabled"])
        self.assertEqual(compile_result["explicitOverrideSource"], "user_metal_args")

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
