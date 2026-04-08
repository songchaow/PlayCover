#!/usr/bin/env python3
"""
ir_semantics_behavior_runner.py — 执行 SV-004 的 compute-first 最小行为测试。

目标：
- 直接消费 `gate-summary.json` 里的 `layeredDecision.l3Plan.candidateSampleKeys`
- 从当前活跃 L2 候选里只挑第一批 compute 样本进入行为测试
- 使用 `test-data/*.metal` 作为 reference MSL，和 round-trip 生成的 MSL 做真实 Metal compute 对比
- 输出结构化 `behavior-summary.json`

当前默认执行面只覆盖：
- `test_fast_math_select`

补充说明：
- `test_casts` 已退出活跃 `L2` 候选；默认不会再随 `gate-summary.json` 自动执行
- 若需要复核 `air.convert` 相关回归，可显式传 `--sample-key test_casts` 做定向验证
- 像 `test_intrinsic_vector_icmp_zext` 这类 fragment/render 样本会被结构化标记为 deferred，继续留在 render-second / L4 之前，不会被误抬进第一批 compute-only harness。
"""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import ir_canonical_compare as canonical_compare


SCHEMA_VERSION = 1
REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
TEST_DATA_ROOT = (
    REPO_ROOT
    / "LocalDocs"
    / "XCodeReleaseShaderDebug"
    / "RoadE-HookMakeLibraryWithSrc"
    / "test-data"
)
DEFAULT_GATE_SUMMARY = (
    REPO_ROOT
    / "build"
    / "semantics-validation"
    / "roundtrip"
    / "test-data-representatives"
    / "gate-summary.json"
)
DEFAULT_SWIFT_RUNNER = SCRIPTS_DIR / "metal_compute_behavior_runner.swift"


L3_BEHAVIOR_SAMPLE_SPECS: dict[str, dict[str, Any]] = {
    "test_casts": {
        "executionKind": "compute",
        "phase": "compute-first",
        "comparisonMode": "reference_msl",
        "whySelected": "覆盖 cast / vector cast lowering；当前 L2 风险主要集中在 air intrinsic 与类型转换路径。",
        "cases": [
            {
                "name": "test_scalar_casts",
                "entryPoint": "test_scalar_casts",
                "threadCount": 8,
                "buffers": [
                    {
                        "index": 0,
                        "name": "floatOut",
                        "role": "output",
                        "elementType": "float",
                        "elementCount": 8,
                    },
                    {
                        "index": 1,
                        "name": "intOut",
                        "role": "output",
                        "elementType": "int",
                        "elementCount": 8,
                    },
                    {
                        "index": 2,
                        "name": "uintIn",
                        "role": "input",
                        "elementType": "uint",
                        "elementCount": 8,
                        "values": [0, 1, 17, 255, 1023, 1024, 65535, 7],
                    },
                    {
                        "index": 3,
                        "name": "intIn",
                        "role": "input",
                        "elementType": "int",
                        "elementCount": 8,
                        "values": [-5, 0, 23, 256, -1024, 511, 127, -128],
                    },
                    {
                        "index": 4,
                        "name": "floatIn",
                        "role": "input",
                        "elementType": "float",
                        "elementCount": 8,
                        "values": [-2.25, -1.0, 0.25, 1.75, 3.5, 15.875, -9.125, 7.875],
                    },
                ],
                "comparisons": [
                    {
                        "bufferIndex": 0,
                        "mode": "approx",
                        "absTolerance": 1e-5,
                        "relTolerance": 1e-5,
                    },
                    {
                        "bufferIndex": 1,
                        "mode": "exact",
                    },
                ],
            },
            {
                "name": "test_vector_casts",
                "entryPoint": "test_vector_casts",
                "threadCount": 4,
                "buffers": [
                    {
                        "index": 0,
                        "name": "floatOut",
                        "role": "output",
                        "elementType": "float4",
                        "elementCount": 4,
                    },
                    {
                        "index": 1,
                        "name": "uintOut",
                        "role": "output",
                        "elementType": "uint4",
                        "elementCount": 4,
                    },
                    {
                        "index": 2,
                        "name": "uintIn",
                        "role": "input",
                        "elementType": "uint4",
                        "elementCount": 4,
                        "values": [
                            0, 1, 2, 3,
                            255, 511, 1023, 2047,
                            17, 31, 63, 127,
                            9, 10, 11, 12,
                        ],
                    },
                    {
                        "index": 3,
                        "name": "intIn",
                        "role": "input",
                        "elementType": "int4",
                        "elementCount": 4,
                        "values": [
                            -1, 2, -3, 4,
                            17, -31, 63, -127,
                            8, 16, 32, 64,
                            -9, -10, 11, 12,
                        ],
                    },
                    {
                        "index": 4,
                        "name": "floatIn",
                        "role": "input",
                        "elementType": "float4",
                        "elementCount": 4,
                        "values": [
                            -1.5, 0.25, 1.75, 2.5,
                            3.5, 4.25, -5.5, 6.75,
                            7.125, -8.25, 9.5, 10.75,
                            -11.0, 12.5, 13.25, -14.75,
                        ],
                    },
                ],
                "comparisons": [
                    {
                        "bufferIndex": 0,
                        "mode": "approx",
                        "absTolerance": 1e-5,
                        "relTolerance": 1e-5,
                    },
                    {
                        "bufferIndex": 1,
                        "mode": "exact",
                    },
                ],
            },
        ],
    },
    "test_fast_math_select": {
        "executionKind": "compute",
        "phase": "compute-first",
        "comparisonMode": "reference_msl",
        "whySelected": "覆盖 fast-math + select；当前 L2 风险集中在 entry/resource 摘要与 fast-math 漂移。",
        "cases": [
            {
                "name": "test_fast_math_select",
                "entryPoint": "test_fast_math_select",
                "threadCount": 8,
                "buffers": [
                    {
                        "index": 0,
                        "name": "output",
                        "role": "output",
                        "elementType": "half",
                        "elementCount": 8,
                    },
                    {
                        "index": 1,
                        "name": "input",
                        "role": "input",
                        "elementType": "half",
                        "elementCount": 8,
                        "values": [-4.0, -0.5, -0.0, 0.0, 0.25, 1.0, 7.5, -12.0],
                    },
                ],
                "comparisons": [
                    {
                        "bufferIndex": 0,
                        "mode": "approx",
                        "absTolerance": 1e-3,
                        "relTolerance": 1e-3,
                    }
                ],
            }
        ],
    },
    "test_intrinsic_vector_icmp_zext": {
        "executionKind": "fragment",
        "phase": "render-second",
        "deferredReason": "当前第一阶段只实现 compute-first harness；fragment/render 样本继续后置到 render-second。",
    },
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="执行 SV-004 compute-first 最小行为测试")
    parser.add_argument(
        "--gate-summary",
        default=str(DEFAULT_GATE_SUMMARY),
        help="gate-summary.json 路径；默认使用 test-data-representatives 的固定输出",
    )
    parser.add_argument(
        "--roundtrip-report",
        help="显式指定 roundtrip-summary.json；默认从 gate-summary 中读取 roundtripReportPath",
    )
    parser.add_argument(
        "--output-root",
        help="行为测试输出目录；默认复用 gate-summary.outputRoot",
    )
    parser.add_argument(
        "--report-file",
        help="behavior-summary.json 输出路径；默认写到 output-root/behavior-summary.json",
    )
    parser.add_argument(
        "--sample-key",
        action="append",
        dest="sample_keys",
        default=[],
        help="只执行指定 sampleKey（可重复指定）；默认直接复用 layeredDecision.l3Plan.candidateSampleKeys",
    )
    parser.add_argument(
        "--swift-runner",
        default=str(DEFAULT_SWIFT_RUNNER),
        help="Metal compute Swift harness 脚本路径",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="仅写 JSON，不打印人类可读摘要",
    )
    return parser


def resolve_output_root(args: argparse.Namespace, gate_summary: dict[str, Any]) -> Path:
    if args.output_root:
        return Path(args.output_root).expanduser().resolve()
    raw_output_root = gate_summary.get("outputRoot")
    if raw_output_root:
        return Path(str(raw_output_root)).expanduser().resolve()
    return (REPO_ROOT / "build" / "semantics-validation" / "behavior" / "manual").resolve()


def resolve_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    if args.report_file:
        return Path(args.report_file).expanduser().resolve()
    return (output_root / "behavior-summary.json").resolve()


def resolve_roundtrip_report_path(args: argparse.Namespace, gate_summary: dict[str, Any]) -> Path:
    if args.roundtrip_report:
        return Path(args.roundtrip_report).expanduser().resolve()
    report_path = gate_summary.get("roundtripReportPath")
    if not report_path:
        raise SystemExit("gate-summary.json 缺少 roundtripReportPath，无法继续执行行为测试")
    return Path(str(report_path)).expanduser().resolve()


def sample_identity(sample: dict[str, Any]) -> str:
    return canonical_compare.sample_identity(sample)


def roundtrip_result_map(roundtrip_report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    mapped: dict[str, dict[str, Any]] = {}
    for item in roundtrip_report.get("results") or []:
        mapped[sample_identity(item)] = item
    return mapped


def gate_candidate_entries(gate_summary: dict[str, Any]) -> list[dict[str, Any]]:
    layered = gate_summary.get("layeredDecision") or {}
    l3_plan = layered.get("l3Plan") or {}
    return list(l3_plan.get("candidates") or [])


def gate_candidate_keys(gate_summary: dict[str, Any], explicit_keys: list[str]) -> list[str]:
    if explicit_keys:
        return dedupe_preserving_order(explicit_keys)
    layered = gate_summary.get("layeredDecision") or {}
    l3_plan = layered.get("l3Plan") or {}
    return dedupe_preserving_order(list(l3_plan.get("candidateSampleKeys") or []))


def dedupe_preserving_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def compare_result_for_sample(gate_summary: dict[str, Any], sample_key: str) -> dict[str, Any] | None:
    for item in gate_candidate_entries(gate_summary):
        if item.get("sampleKey") == sample_key:
            return item
    return None


def infer_reference_source_path(sample: dict[str, Any]) -> Path | None:
    input_path = sample.get("inputPath")
    if not input_path:
        return None
    path = Path(str(input_path)).expanduser().resolve()
    if path.suffix != ".ll":
        return None
    return path.with_suffix(".metal")


def flatten_numeric_values(values: list[Any]) -> list[float | int]:
    flattened: list[float | int] = []
    for value in values:
        if isinstance(value, list):
            flattened.extend(flatten_numeric_values(value))
        else:
            flattened.append(value)
    return flattened


def build_case_spec(case: dict[str, Any]) -> dict[str, Any]:
    buffers: list[dict[str, Any]] = []
    for buffer in case.get("buffers") or []:
        normalized = {
            "index": int(buffer["index"]),
            "name": str(buffer["name"]),
            "role": str(buffer["role"]),
            "elementType": str(buffer["elementType"]),
            "elementCount": int(buffer["elementCount"]),
        }
        if "values" in buffer:
            normalized["values"] = flatten_numeric_values(list(buffer["values"]))
        buffers.append(normalized)

    return {
        "name": str(case["name"]),
        "entryPoint": str(case["entryPoint"]),
        "threadCount": int(case["threadCount"]),
        "buffers": buffers,
        "comparisons": list(case.get("comparisons") or []),
    }


def build_behavior_plan(
    gate_summary: dict[str, Any],
    roundtrip_report: dict[str, Any],
    *,
    sample_keys: list[str],
    output_root: Path,
) -> dict[str, Any]:
    roundtrip_by_sample = roundtrip_result_map(roundtrip_report)
    ready_samples: list[dict[str, Any]] = []
    deferred_samples: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []

    for sample_key in sample_keys:
        sample_spec = L3_BEHAVIOR_SAMPLE_SPECS.get(sample_key)
        gate_entry = compare_result_for_sample(gate_summary, sample_key) or {"sampleKey": sample_key}
        roundtrip_entry = roundtrip_by_sample.get(sample_key)

        if sample_spec is None:
            deferred_samples.append(
                {
                    "sampleKey": sample_key,
                    "status": "deferred",
                    "reason": "当前 behavior registry 还没有这条样本的执行规格，先保留在 L2/L3 交界处。",
                    "phase": "registry-missing",
                }
            )
            continue

        execution_kind = str(sample_spec.get("executionKind") or "unknown")
        if execution_kind != "compute":
            deferred_samples.append(
                {
                    "sampleKey": sample_key,
                    "status": "deferred",
                    "reason": sample_spec.get("deferredReason")
                    or "当前 compute-first 第一阶段不覆盖非 compute 样本。",
                    "executionKind": execution_kind,
                    "phase": str(sample_spec.get("phase") or "later"),
                }
            )
            continue

        if roundtrip_entry is None:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": "roundtrip-summary.json 中找不到对应样本，无法定位生成 MSL。",
                }
            )
            continue

        generated_function_names = list(roundtrip_entry.get("generatedFunctionNames") or [])
        generated_function_types = list(roundtrip_entry.get("generatedFunctionTypes") or [])
        generated_type_by_name = {
            str(name): str(function_type)
            for name, function_type in zip(generated_function_names, generated_function_types)
        }
        missing_case_entries = [
            str(case.get("entryPoint"))
            for case in sample_spec.get("cases") or []
            if str(case.get("entryPoint")) not in generated_type_by_name
        ]
        if missing_case_entries:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"generated MSL 缺少预期 entry：{', '.join(missing_case_entries)}",
                }
            )
            continue

        non_compute_entries = [
            entry_point
            for entry_point, function_type in generated_type_by_name.items()
            if entry_point in {str(case.get("entryPoint")) for case in sample_spec.get("cases") or []}
            and function_type != "kernel"
        ]
        if non_compute_entries:
            deferred_samples.append(
                {
                    "sampleKey": sample_key,
                    "status": "deferred",
                    "reason": "当前 compute-first 第一阶段只接受 kernel entry；该样本的生成产物已经不再是纯 compute 入口。",
                    "executionKind": execution_kind,
                    "phase": "shape-drift",
                    "entries": non_compute_entries,
                }
            )
            continue

        reference_source = infer_reference_source_path(gate_entry) or infer_reference_source_path(roundtrip_entry)
        candidate_source = roundtrip_entry.get("generatedMSLPath")
        if reference_source is None or not reference_source.is_file():
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"找不到 reference MSL：{reference_source}",
                }
            )
            continue
        if not candidate_source or not Path(str(candidate_source)).expanduser().resolve().is_file():
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"找不到 generated MSL：{candidate_source}",
                }
            )
            continue

        ready_samples.append(
            {
                "sampleKey": sample_key,
                "executionKind": execution_kind,
                "phase": str(sample_spec.get("phase") or "compute-first"),
                "comparisonMode": str(sample_spec.get("comparisonMode") or "reference_msl"),
                "whySelected": sample_spec.get("whySelected"),
                "inputPath": roundtrip_entry.get("inputPath"),
                "riskLevel": gate_entry.get("riskLevel"),
                "riskReason": gate_entry.get("riskReason"),
                "generatedFunctionNames": generated_function_names,
                "generatedFunctionTypes": generated_function_types,
                "referenceSourcePath": str(reference_source),
                "candidateSourcePath": str(Path(str(candidate_source)).expanduser().resolve()),
                "artifactSpecPath": str((output_root / "behavior-artifacts" / f"{sample_key}.spec.json").resolve()),
                "artifactResultPath": str((output_root / "behavior-artifacts" / f"{sample_key}.result.json").resolve()),
                "cases": [build_case_spec(case) for case in sample_spec.get("cases") or []],
            }
        )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "candidateSampleKeys": sample_keys,
        "readySamples": ready_samples,
        "deferredSamples": deferred_samples,
        "errors": errors,
    }


def build_sample_spec_payload(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "sampleKey": sample["sampleKey"],
        "referenceSourcePath": sample["referenceSourcePath"],
        "candidateSourcePath": sample["candidateSourcePath"],
        "cases": list(sample.get("cases") or []),
    }


def run_sample_behavior(
    sample: dict[str, Any],
    *,
    swift_runner: Path,
    quiet: bool,
) -> dict[str, Any]:
    artifact_spec_path = Path(str(sample["artifactSpecPath"]))
    artifact_result_path = Path(str(sample["artifactResultPath"]))
    artifact_spec_path.parent.mkdir(parents=True, exist_ok=True)
    write_json(artifact_spec_path, build_sample_spec_payload(sample))

    command = [
        "swift",
        str(swift_runner),
        "--spec",
        str(artifact_spec_path),
        "--result",
        str(artifact_result_path),
    ]
    completed = subprocess.run(command, check=False, capture_output=True, text=True)

    base_result = {
        "sampleKey": sample["sampleKey"],
        "command": " ".join(command),
        "artifactSpecPath": str(artifact_spec_path),
        "artifactResultPath": str(artifact_result_path),
        "returnCode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }

    payload: dict[str, Any] | None = None
    if artifact_result_path.is_file():
        payload = load_json(artifact_result_path)

    if completed.returncode != 0 and payload is None:
        base_result["status"] = "error"
        base_result["reason"] = completed.stderr.strip() or completed.stdout.strip() or "swift harness failed"
        return base_result

    if payload is None:
        base_result["status"] = "error"
        base_result["reason"] = "swift harness 未生成结果文件"
        return base_result

    base_result["status"] = str(payload.get("status") or "error")
    base_result["swiftResult"] = payload
    if payload.get("status") != "pass":
        base_result["reason"] = payload.get("summary") or completed.stderr.strip() or completed.stdout.strip()
    if payload.get("status") == "pass":
        if not quiet:
            print(f"behavior pass: {sample['sampleKey']}")
    elif not quiet:
        print(f"behavior {payload.get('status', 'error')}: {sample['sampleKey']}")
    return base_result


def summarize_status(executed_results: list[dict[str, Any]], deferred_samples: list[dict[str, Any]], errors: list[dict[str, Any]]) -> tuple[str, str]:
    if errors:
        return ("fail", f"有 {len(errors)} 个样本在准备阶段失败，无法完成行为测试。")

    failed = [
        item
        for item in executed_results
        if item.get("status") not in {"pass"}
    ]
    if failed:
        return ("fail", f"有 {len(failed)} 个 compute 样本未通过行为对比。")

    if deferred_samples:
        return (
            "warn",
            f"已完成 {len(executed_results)} 个 compute 样本行为测试，另有 {len(deferred_samples)} 个候选按 compute-first 边界继续后置。",
        )

    return ("pass", f"已完成 {len(executed_results)} 个 compute 样本行为测试，全部通过。")


def build_summary(
    *,
    gate_summary_path: Path,
    roundtrip_report_path: Path,
    report_path: Path,
    output_root: Path,
    plan: dict[str, Any],
    executed_results: list[dict[str, Any]],
) -> dict[str, Any]:
    deferred_samples = list(plan.get("deferredSamples") or [])
    errors = list(plan.get("errors") or [])
    overall_status, summary = summarize_status(executed_results, deferred_samples, errors)

    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": utc_now_iso(),
        "tool": "Scripts/ir_semantics_behavior_runner.py",
        "reportPath": str(report_path),
        "gateSummaryPath": str(gate_summary_path),
        "roundtripReportPath": str(roundtrip_report_path),
        "outputRoot": str(output_root),
        "status": overall_status,
        "summary": summary,
        "candidateSampleKeys": list(plan.get("candidateSampleKeys") or []),
        "readySampleCount": len(plan.get("readySamples") or []),
        "executedSampleCount": len(executed_results),
        "deferredSampleCount": len(deferred_samples),
        "errorCount": len(errors),
        "readySamples": plan.get("readySamples") or [],
        "executedSamples": executed_results,
        "deferredSamples": deferred_samples,
        "errors": errors,
    }


def print_summary(summary: dict[str, Any]) -> None:
    print(f"behavior status: {summary.get('status')}")
    print(f"behavior summary: {summary.get('summary')}")
    executed = summary.get("executedSamples") or []
    if executed:
        print("executed samples:")
        for item in executed:
            print(f"  - {item.get('sampleKey')}: {item.get('status')}")
    deferred = summary.get("deferredSamples") or []
    if deferred:
        print("deferred samples:")
        for item in deferred:
            print(f"  - {item.get('sampleKey')}: {item.get('reason')}")
    errors = summary.get("errors") or []
    if errors:
        print("behavior setup errors:")
        for item in errors:
            print(f"  - {item.get('sampleKey')}: {item.get('reason')}")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    gate_summary_path = Path(args.gate_summary).expanduser().resolve()
    swift_runner = Path(args.swift_runner).expanduser().resolve()
    if not gate_summary_path.is_file():
        raise SystemExit(f"gate-summary.json 不存在：{gate_summary_path}")
    if not swift_runner.is_file():
        raise SystemExit(f"Swift harness 不存在：{swift_runner}")

    gate_summary = load_json(gate_summary_path)
    output_root = resolve_output_root(args, gate_summary)
    report_path = resolve_report_path(args, output_root)
    roundtrip_report_path = resolve_roundtrip_report_path(args, gate_summary)
    if not roundtrip_report_path.is_file():
        raise SystemExit(f"roundtrip-summary.json 不存在：{roundtrip_report_path}")
    roundtrip_report = load_json(roundtrip_report_path)

    sample_keys = gate_candidate_keys(gate_summary, args.sample_keys)
    if not sample_keys:
        raise SystemExit("gate-summary.json 中没有可执行的 L3 candidateSampleKeys")

    plan = build_behavior_plan(
        gate_summary,
        roundtrip_report,
        sample_keys=sample_keys,
        output_root=output_root,
    )

    executed_results: list[dict[str, Any]] = []
    for sample in plan.get("readySamples") or []:
        executed_results.append(run_sample_behavior(sample, swift_runner=swift_runner, quiet=args.quiet))

    summary = build_summary(
        gate_summary_path=gate_summary_path,
        roundtrip_report_path=roundtrip_report_path,
        report_path=report_path,
        output_root=output_root,
        plan=plan,
        executed_results=executed_results,
    )
    write_json(report_path, summary)

    if not args.quiet:
        print_summary(summary)
        print(f"behavior report: {report_path}")

    return 0 if summary.get("status") in {"pass", "warn"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
