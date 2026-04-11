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

ENABLE_FAST_MATH_MARKER = "air.compile.fast_math_enable"
DISABLE_FAST_MATH_MARKER = "air.compile.fast_math_disable"
UNKNOWN_FAST_MATH_MARKER = "air.compile.fast_math_unknown"


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


def make_shared_compile_plan(
    *,
    reason: str,
    fast_math_mode: str | None,
    inferred_metal_args: list[str],
    effective_metal_args: list[str],
    uses_explicit_compile_options: bool,
    compile_options_fast_math_enabled: bool | None,
    explicit_override_source: str | None = None,
    requested_backend: str = "xcrun",
) -> dict:
    decision = {
        "fastMathDecision": reason,
        "reason": reason,
        "usesExplicitCompileOptions": uses_explicit_compile_options,
    }
    if fast_math_mode is not None:
        decision["fastMathMode"] = fast_math_mode
    if compile_options_fast_math_enabled is not None:
        decision["compileOptionsFastMathEnabled"] = compile_options_fast_math_enabled
    if explicit_override_source is not None:
        decision["explicitOverrideSource"] = explicit_override_source

    return {
        "requestedBackend": requested_backend,
        "decision": decision,
        "inferredMetalArgs": list(inferred_metal_args),
        "effectiveMetalArgs": list(effective_metal_args),
        "mtlCompileOptionsPayload": (
            {"fastMathEnabled": compile_options_fast_math_enabled}
            if compile_options_fast_math_enabled is not None
            else None
        ),
    }


def aggregate_compile_summary_cases(*, include_non_fast_math_user_args: bool = False) -> list[dict]:
    unavailable_metal_args = ["-std=metal3.1"] if include_non_fast_math_user_args else []
    return [
        {
            "name": "aligned_enable",
            "original_ir_texts": [
                f'!1 = !{{!"{ENABLE_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{ENABLE_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [ENABLE_FAST_MATH_MARKER, ENABLE_FAST_MATH_MARKER],
            "metal_args": [],
            "expected_mode": "enable",
            "expected_decision": "fast_math_aligned",
            "expected_explicit": True,
            "expected_fast_math_enabled": True,
            "expected_inferred": ["-ffast-math"],
            "expected_effective": ["-ffast-math"],
            "expected_override_source": None,
        },
        {
            "name": "aligned_disable",
            "original_ir_texts": [
                f'!1 = !{{!"{DISABLE_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{DISABLE_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [DISABLE_FAST_MATH_MARKER, DISABLE_FAST_MATH_MARKER],
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
            "original_ir_texts": [
                f'!1 = !{{!"{ENABLE_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{DISABLE_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [ENABLE_FAST_MATH_MARKER, DISABLE_FAST_MATH_MARKER],
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
            "original_ir_texts": [
                f'!1 = !{{!"{ENABLE_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{UNKNOWN_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [ENABLE_FAST_MATH_MARKER, UNKNOWN_FAST_MATH_MARKER],
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
            "original_ir_texts": [
                f'!1 = !{{!"{UNKNOWN_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{UNKNOWN_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [UNKNOWN_FAST_MATH_MARKER, UNKNOWN_FAST_MATH_MARKER],
            "metal_args": unavailable_metal_args,
            "expected_mode": None,
            "expected_decision": "fast_math_unavailable",
            "expected_explicit": False,
            "expected_fast_math_enabled": None,
            "expected_inferred": [],
            "expected_effective": unavailable_metal_args,
            "expected_override_source": None,
        },
        {
            "name": "user_override",
            "original_ir_texts": [
                f'!1 = !{{!"{DISABLE_FAST_MATH_MARKER}"}}\n',
                f'!1 = !{{!"{DISABLE_FAST_MATH_MARKER}"}}\n',
            ],
            "module_fast_math_markers": [DISABLE_FAST_MATH_MARKER, DISABLE_FAST_MATH_MARKER],
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


def write_test_fragment_sample(path: Path, *, fast_math_marker: str | None = None) -> None:
    source_text = TEST_FRAGMENT_PACKED_RETURN_SAMPLE.read_text(encoding="utf-8")
    if fast_math_marker is not None:
        source_text = source_text.replace(ENABLE_FAST_MATH_MARKER, fast_math_marker)
        source_text = source_text.replace(DISABLE_FAST_MATH_MARKER, fast_math_marker)
    path.write_text(source_text, encoding="utf-8")


def create_aggregate_cli_fixture(
    root: Path,
    *,
    fast_math_marker: str | None = None,
    module_fast_math_markers: list[str | None] | None = None,
) -> Path:
    corpus_root = root / "ShaderCorpus"
    bundle_root = corpus_root / "com.example.demo"
    replacement_dir = bundle_root / "replacements" / "20260410_selector_cache"
    replacement_dir.mkdir(parents=True, exist_ok=True)

    module_keys = ["module-a", "module-b"]
    marker_values = (
        list(module_fast_math_markers)
        if module_fast_math_markers is not None
        else [fast_math_marker] * len(module_keys)
    )
    if len(marker_values) != len(module_keys):
        raise ValueError("module_fast_math_markers must match fixture module count")

    for module_key, module_fast_math_marker in zip(module_keys, marker_values):
        module_dir = bundle_root / "modules" / module_key
        module_dir.mkdir(parents=True, exist_ok=True)
        write_test_fragment_sample(module_dir / "module.ll", fast_math_marker=module_fast_math_marker)
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
    return corpus_root


class AggregateReplayRunnerTests(unittest.TestCase):
    def assert_compile_summary(
        self,
        compile_result: dict,
        *,
        expected_mode: str | None,
        expected_decision: str,
        expected_explicit: bool,
        expected_fast_math_enabled: bool | None,
        expected_inferred: list[str],
        expected_effective: list[str],
        expected_override_source: str | None,
    ) -> None:
        self.assertEqual(compile_result.get("fastMathMode"), expected_mode)
        self.assertEqual(compile_result["fastMathDecision"], expected_decision)
        self.assertEqual(compile_result["usesExplicitCompileOptions"], expected_explicit)
        self.assertEqual(compile_result.get("compileOptionsFastMathEnabled"), expected_fast_math_enabled)
        self.assertEqual(compile_result["inferredMetalArgs"], expected_inferred)
        self.assertEqual(compile_result["effectiveMetalArgs"], expected_effective)
        self.assertEqual(compile_result.get("explicitOverrideSource"), expected_override_source)

    def assert_case_compile_summary(self, compile_result: dict, case: dict) -> None:
        self.assert_compile_summary(
            compile_result,
            expected_mode=case["expected_mode"],
            expected_decision=case["expected_decision"],
            expected_explicit=case["expected_explicit"],
            expected_fast_math_enabled=case["expected_fast_math_enabled"],
            expected_inferred=case["expected_inferred"],
            expected_effective=case["expected_effective"],
            expected_override_source=case["expected_override_source"],
        )

    @staticmethod
    def compile_summary_snapshot(compile_result: dict) -> dict:
        return {
            "fastMathMode": compile_result.get("fastMathMode"),
            "fastMathDecision": compile_result.get("fastMathDecision"),
            "usesExplicitCompileOptions": compile_result.get("usesExplicitCompileOptions"),
            "compileOptionsFastMathEnabled": compile_result.get("compileOptionsFastMathEnabled"),
            "inferredMetalArgs": compile_result.get("inferredMetalArgs"),
            "effectiveMetalArgs": compile_result.get("effectiveMetalArgs"),
            "explicitOverrideSource": compile_result.get("explicitOverrideSource"),
        }

    def run_aggregate_cli(
        self,
        root: Path,
        *,
        compile_backend: str,
        metal_args: list[str] | None = None,
        module_fast_math_markers: list[str | None] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict, dict]:
        corpus_root = create_aggregate_cli_fixture(
            root,
            fast_math_marker=DISABLE_FAST_MATH_MARKER,
            module_fast_math_markers=module_fast_math_markers,
        )
        output_root = root / f"out-{compile_backend}"
        command = [
            "python3",
            str(AGGREGATE_SCRIPT),
            "--corpus-root",
            str(corpus_root),
            "--bundle-id",
            "com.example.demo",
            "--compile-backend",
            compile_backend,
            "--output-root",
            str(output_root),
        ]
        for metal_arg in list(metal_args or []):
            command.append(f"--metal-arg={metal_arg}")

        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        report_path = output_root / "aggregate-replay-summary.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        result = report["results"][0]

        if (
            compile_backend == "mtl-device"
            and result["compile"].get("error") == "failed to create system default Metal device"
        ):
            raise unittest.SkipTest("requires system default Metal device")

        detail = "\n".join(part for part in [completed.stdout.strip(), completed.stderr.strip()] if part)
        self.assertEqual(completed.returncode, 0, msg=detail)
        self.assertIn("aggregate replay summary", completed.stdout)
        return completed, report, result

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
                "name": "aligned_enable",
                "original_ir_texts": [enable_ir],
                "metal_args": [],
                "expected_mode": "enable",
                "expected_decision": "fast_math_aligned",
                "expected_explicit": True,
                "expected_fast_math_enabled": True,
                "expected_inferred": ["-ffast-math"],
                "expected_effective": ["-ffast-math"],
                "expected_override_source": None,
            },
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

    def test_compile_aggregate_source_reads_shared_planner_summary_from_xcrun_backend(self) -> None:
        cases = aggregate_compile_summary_cases(include_non_fast_math_user_args=True)

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "aggregate.replayed.generated.metal"
            source_path.write_text(VALID_AGGREGATE_SOURCE, encoding="utf-8")

            for case in cases:
                with self.subTest(case=case["name"]):
                    original_ir_paths: list[Path] = []
                    for index, original_ir_text in enumerate(case["original_ir_texts"]):
                        original_ir_path = root / f"{case['name']}-module-{index}.ll"
                        original_ir_path.write_text(original_ir_text, encoding="utf-8")
                        original_ir_paths.append(original_ir_path)

                    args = argparse.Namespace(
                        compile_backend="xcrun",
                        metal_sdk="macosx",
                        metal_args=list(case["metal_args"]),
                        skip_preflight=False,
                        shared_compile_planner_binary=str(root / "shared_compile_planner_harness"),
                    )
                    aggregate_result = {"success": True, "sourcePath": str(source_path)}

                    def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                        self.assertFalse(check)
                        self.assertTrue(capture_output)
                        self.assertTrue(text)
                        self.assertEqual(command[:5], ["xcrun", "--sdk", "macosx", "metal", "-c"])
                        compile_arg_start = 5
                        compile_arg_end = compile_arg_start + len(case["expected_effective"])
                        self.assertEqual(command[compile_arg_start:compile_arg_end], case["expected_effective"])
                        self.assertEqual(command[compile_arg_end], str(source_path.resolve()))
                        self.assertEqual(command[-2], "-o")
                        return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

                    compile_plan = make_shared_compile_plan(
                        reason=case["expected_decision"],
                        fast_math_mode=case["expected_mode"],
                        inferred_metal_args=case["expected_inferred"],
                        effective_metal_args=case["expected_effective"],
                        uses_explicit_compile_options=case["expected_explicit"],
                        compile_options_fast_math_enabled=case["expected_fast_math_enabled"],
                        explicit_override_source=case["expected_override_source"],
                    )

                    with mock.patch.object(
                        aggregate_runner.replay_runner,
                        "resolve_shared_compile_plan",
                        return_value=compile_plan,
                    ) as resolve_plan_mock:
                        with mock.patch.object(aggregate_runner.subprocess, "run", side_effect=fake_run):
                            compile_result = aggregate_runner.compile_aggregate_source(
                                aggregate_result,
                                original_ir_paths,
                                args,
                                job_id=1,
                                bundle_id="com.example.demo",
                                replacement_key="replacement-key",
                                module_keys=[path.stem for path in original_ir_paths],
                            )

                    resolve_plan_mock.assert_called_once_with(
                        original_ir_paths,
                        list(case["metal_args"]),
                        requested_backend="xcrun",
                        shared_compile_planner_binary=args.shared_compile_planner_binary,
                    )
                    self.assertEqual(compile_result["status"], "success")
                    self.assertTrue(compile_result["success"])
                    self.assertEqual(compile_result["compileBackend"], "xcrun")
                    self.assert_case_compile_summary(compile_result, case)

    def test_compile_aggregate_source_reads_compile_summary_from_mtl_device_harness_reason_code_matrix(self) -> None:
        cases = aggregate_compile_summary_cases()

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "aggregate.replayed.generated.metal"
            source_path.write_text(VALID_AGGREGATE_SOURCE, encoding="utf-8")
            harness_binary = root / "metal_aggregate_compile_harness"
            harness_binary.write_text("#!/bin/sh\n", encoding="utf-8")
            harness_binary.chmod(0o755)

            for case in cases:
                with self.subTest(case=case["name"]):
                    original_ir_paths: list[Path] = []
                    for index, original_ir_text in enumerate(case["original_ir_texts"]):
                        original_ir_path = root / f"{case['name']}-module-{index}.ll"
                        original_ir_path.write_text(original_ir_text, encoding="utf-8")
                        original_ir_paths.append(original_ir_path)

                    args = argparse.Namespace(
                        compile_backend="mtl-device",
                        metal_sdk="macosx",
                        metal_args=list(case["metal_args"]),
                        skip_preflight=False,
                        aggregate_compile_harness_binary=str(harness_binary),
                    )
                    aggregate_result = {"success": True, "sourcePath": str(source_path)}

                    def fake_run(command: list[str], check: bool, capture_output: bool, text: bool) -> subprocess.CompletedProcess[str]:
                        self.assertFalse(check)
                        self.assertTrue(capture_output)
                        self.assertTrue(text)
                        self.assertEqual(Path(command[0]).resolve(), harness_binary.resolve())
                        self.assertNotIn("--manifest-source", command)
                        self.assertEqual(
                            [command[index + 1] for index, value in enumerate(command[:-1]) if value == "--original-ir"],
                            [str(path.resolve()) for path in original_ir_paths],
                        )
                        self.assertEqual(
                            [command[index + 1] for index, value in enumerate(command[:-1]) if value == "--metal-arg"],
                            list(case["metal_args"]),
                        )
                        report_path = Path(command[command.index("--report") + 1])
                        report_payload = {
                            "schemaVersion": 1,
                            "success": True,
                            "error": None,
                            "functionNames": ["main0"],
                            "functionCount": 1,
                            "usesExplicitCompileOptions": case["expected_explicit"],
                            "fastMathDecision": case["expected_decision"],
                            "inferredMetalArgs": list(case["expected_inferred"]),
                            "effectiveMetalArgs": list(case["expected_effective"]),
                        }
                        if case["expected_mode"] is not None:
                            report_payload["fastMathMode"] = case["expected_mode"]
                        if case["expected_fast_math_enabled"] is not None:
                            report_payload["fastMathEnabled"] = case["expected_fast_math_enabled"]
                        if case["expected_override_source"] is not None:
                            report_payload["explicitOverrideSource"] = case["expected_override_source"]
                        report_path.write_text(json.dumps(report_payload, indent=2), encoding="utf-8")
                        return subprocess.CompletedProcess(args=command, returncode=0, stdout="", stderr="")

                    with mock.patch.object(aggregate_runner.subprocess, "run", side_effect=fake_run):
                        compile_result = aggregate_runner.compile_aggregate_source(
                            aggregate_result,
                            original_ir_paths,
                            args,
                            job_id=1,
                            bundle_id="com.example.demo",
                            replacement_key="replacement-key",
                            module_keys=[path.stem for path in original_ir_paths],
                        )

                    self.assertEqual(compile_result["status"], "success")
                    self.assertTrue(compile_result["success"])
                    self.assertEqual(compile_result["compileBackend"], "mtl-device")
                    self.assertEqual(compile_result["libraryFunctionNames"], ["main0"])
                    self.assertEqual(compile_result["libraryFunctionCount"], 1)
                    self.assert_case_compile_summary(compile_result, case)

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("swiftc") and shutil.which("xcrun"),
        "requires macOS Metal + swiftc + xcrun",
    )
    def test_cli_compile_summary_reason_code_matrix_matches_across_backends(self) -> None:
        cases = aggregate_compile_summary_cases()

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)

            for case in cases:
                with self.subTest(case=case["name"]):
                    _, xcrun_report, xcrun_result = self.run_aggregate_cli(
                        root / "xcrun" / case["name"],
                        compile_backend="xcrun",
                        metal_args=case["metal_args"],
                        module_fast_math_markers=case["module_fast_math_markers"],
                    )
                    _, mtl_report, mtl_result = self.run_aggregate_cli(
                        root / "mtl-device" / case["name"],
                        compile_backend="mtl-device",
                        metal_args=case["metal_args"],
                        module_fast_math_markers=case["module_fast_math_markers"],
                    )

                    self.assertEqual(xcrun_report["requestedInputs"]["compileBackend"], "xcrun")
                    self.assertEqual(mtl_report["requestedInputs"]["compileBackend"], "mtl-device")
                    self.assertEqual(xcrun_report["aggregateJobCount"], 1)
                    self.assertEqual(mtl_report["aggregateJobCount"], 1)
                    self.assertEqual(xcrun_report["failedJobs"], 0)
                    self.assertEqual(mtl_report["failedJobs"], 0)
                    self.assertEqual(xcrun_result["overallStatus"], "success")
                    self.assertEqual(mtl_result["overallStatus"], "success")
                    self.assertEqual(xcrun_result["aggregate"]["dedupeSkippedModuleCount"], 1)
                    self.assertEqual(mtl_result["aggregate"]["dedupeSkippedModuleCount"], 1)
                    self.assertEqual(xcrun_result["compile"]["status"], "success")
                    self.assertEqual(mtl_result["compile"]["status"], "success")
                    self.assertEqual(xcrun_result["compile"]["compileBackend"], "xcrun")
                    self.assertEqual(mtl_result["compile"]["compileBackend"], "mtl-device")
                    self.assertTrue(Path(xcrun_result["aggregate"]["sourcePath"]).is_file())
                    self.assertTrue(Path(mtl_result["compile"]["backendReportPath"]).is_file())
                    self.assert_case_compile_summary(xcrun_result["compile"], case)
                    self.assert_case_compile_summary(mtl_result["compile"], case)
                    self.assertEqual(
                        self.compile_summary_snapshot(xcrun_result["compile"]),
                        self.compile_summary_snapshot(mtl_result["compile"]),
                    )


if __name__ == "__main__":
    unittest.main()
