#!/usr/bin/env python3
"""
ir_semantics_behavior_runner.py — 执行 SV-004 的最小行为测试（compute-first + render-second）。

目标：
- 直接消费 `gate-summary.json` 里的 `layeredDecision.l3Plan.candidateSampleKeys`
- 从当前活跃 L2 候选里挑最小、最稳定的本地行为样本进入验证
- 使用 `test-data/*.metal` 作为 reference MSL，和 round-trip 生成的 MSL 做 reference-vs-generated 对跑
- 输出结构化 `behavior-summary.json`

当前默认执行面覆盖：
- `test_fast_math_select`（compute-first）
- `test_intrinsic_vector_icmp_zext`（offscreen render-second）

补充说明：
- `test_casts` 已退出活跃 `L2` 候选；默认不会再随 `gate-summary.json` 自动执行
- 若需要复核 `air.convert` 相关回归，可显式传 `--sample-key test_casts` 做定向验证
- render-second 仍保持单命令、本地、无 UI、无工作区外修改；若后续样本做不到这点，仍应继续 deferred，而不是回退到 live/人工流程
"""

from __future__ import annotations

import argparse
import json
import re
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
DEFAULT_COMPUTE_SWIFT_RUNNER = SCRIPTS_DIR / "metal_compute_behavior_runner.swift"
DEFAULT_FRAGMENT_SWIFT_RUNNER = SCRIPTS_DIR / "metal_fragment_behavior_runner.swift"
DEFAULT_L3_BEHAVIOR_SAMPLE_KEYS = (
    "test_fast_math_select",
    "test_intrinsic_vector_icmp_zext",
)
EXPECTED_FUNCTION_TYPE_BY_EXECUTION_KIND = {
    "compute": "kernel",
    "fragment": "fragment",
    "vertex": "vertex",
}
MSL_ENTRY_FUNCTION_RE = re.compile(
    r'(?P<shader_type>\b(?:kernel|fragment|vertex)\b)\s+'
    r'(?P<return_type>[^(){};]+?)\s+'
    r'(?P<function_name>[A-Za-z_][A-Za-z0-9_]*)\s*'
    r'\((?P<params>.*?)\)\s*\{',
    re.DOTALL,
)
MSL_ATTRIBUTE_RE = re.compile(r'\[\[\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?:\((?P<index>\d+)\))?\s*\]\]')
MSL_LINE_COMMENT_RE = re.compile(r'//.*?(?=\n|$)')
MSL_BLOCK_COMMENT_RE = re.compile(r'/\*.*?\*/', re.DOTALL)
IR_VECTOR_RETURN_TYPE_RE = re.compile(r'^<(?P<width>\d+)\s+x\s+(?P<element>half|float|i1|i8|i16|i32|i64)>$')
MSL_ATTRIBUTE_KIND_MAP = {
    "buffer": "air.buffer",
    "texture": "air.texture",
    "sampler": "air.sampler",
    "position": "air.position",
    "thread_position_in_grid": "air.thread_position_in_grid",
}
IR_SCALAR_TYPE_TO_MSL = {
    "void": "void",
    "half": "half",
    "float": "float",
    "i1": "bool",
    "i8": "char",
    "i16": "short",
    "i32": "int",
    "i64": "long",
}


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
        "comparisonMode": "reference_msl",
        "whySelected": "覆盖 fragment lowering 里的 clamp / vector icmp / zext <2 x i1> → uchar2 组合路径。",
        "cases": [
            {
                "name": "test_intrinsic_vector_icmp_zext",
                "entryPoint": "xlatMtlMain",
                "renderTarget": {
                    "width": 4,
                    "height": 4,
                    "pixelFormat": "rgba16Float",
                },
                "comparisons": [
                    {
                        "attachmentIndex": 0,
                        "mode": "approx",
                        "absTolerance": 1e-3,
                        "relTolerance": 1e-3,
                    }
                ],
            }
        ],
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
    parser = argparse.ArgumentParser(description="执行 SV-004 最小行为测试（compute-first + render-second）")
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
        help="只执行指定 sampleKey（可重复指定）；默认只运行当前 SV-004F 白名单执行面里仍在 layeredDecision.l3Plan.candidateSampleKeys 中的样本",
    )
    parser.add_argument(
        "--swift-runner",
        default=str(DEFAULT_COMPUTE_SWIFT_RUNNER),
        help="Metal compute Swift harness 脚本路径（兼容旧参数名）",
    )
    parser.add_argument(
        "--fragment-swift-runner",
        default=str(DEFAULT_FRAGMENT_SWIFT_RUNNER),
        help="Metal fragment/render Swift harness 脚本路径",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="仅写 JSON，不打印人类可读摘要",
    )
    return parser


def gate_output_root(gate_summary: dict[str, Any]) -> Path | None:
    raw_output_root = gate_summary.get("outputRoot")
    if not raw_output_root:
        return None
    return Path(str(raw_output_root)).expanduser().resolve()


def resolve_output_root(args: argparse.Namespace, gate_summary: dict[str, Any]) -> Path:
    if args.output_root:
        return Path(args.output_root).expanduser().resolve()
    resolved_gate_output_root = gate_output_root(gate_summary)
    if resolved_gate_output_root is not None:
        return resolved_gate_output_root
    return (REPO_ROOT / "build" / "semantics-validation" / "behavior" / "manual").resolve()


def resolve_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    if args.report_file:
        return Path(args.report_file).expanduser().resolve()
    return (output_root / "behavior-summary.json").resolve()


def validate_default_output_contract(
    args: argparse.Namespace,
    gate_summary: dict[str, Any],
    *,
    output_root: Path,
    report_path: Path,
) -> None:
    resolved_gate_output_root = gate_output_root(gate_summary)
    if resolved_gate_output_root is None or args.sample_keys:
        return

    expected_report_path = (resolved_gate_output_root / "behavior-summary.json").resolve()
    if output_root != resolved_gate_output_root:
        raise SystemExit(
            "默认 L3 行为 gate 必须写回 gate-summary.outputRoot；如需改写输出目录，请改用 --sample-key 定向复核。"
        )
    if report_path != expected_report_path:
        raise SystemExit(
            "默认 L3 行为 gate 必须写回固定 behavior-summary.json；如需另存报告，请改用 --sample-key 定向复核。"
        )


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
    gate_candidate_keys = set(dedupe_preserving_order(list(l3_plan.get("candidateSampleKeys") or [])))
    return [sample_key for sample_key in DEFAULT_L3_BEHAVIOR_SAMPLE_KEYS if sample_key in gate_candidate_keys]


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


def strip_msl_comments(source_text: str) -> str:
    without_block_comments = MSL_BLOCK_COMMENT_RE.sub("", source_text)
    return MSL_LINE_COMMENT_RE.sub("", without_block_comments)


def normalize_msl_type(type_text: str) -> str:
    value = canonical_compare._normalize_whitespace(type_text)
    value = re.sub(r'\b(?:const|device|constant|threadgroup|thread|volatile|restrict)\b', '', value)
    value = value.replace('*', ' ').replace('&', ' ')
    return canonical_compare._normalize_whitespace(value)


def parse_semantic_signature(signature: str) -> dict[str, Any]:
    parsed: dict[str, Any] = {}
    for part in signature.split("|"):
        if "=" not in part:
            parsed[part] = True
            continue
        key, value = part.split("=", 1)
        if key in {"index", "location", "addrspace", "typeSize", "align"}:
            try:
                parsed[key] = int(value)
                continue
            except ValueError:
                pass
        parsed[key] = value
    return parsed


def parse_msl_parameter(parameter_text: str) -> dict[str, Any]:
    cleaned = canonical_compare._normalize_whitespace(parameter_text)
    attribute_match = MSL_ATTRIBUTE_RE.search(cleaned)
    attribute_name = attribute_match.group("name") if attribute_match else None
    attribute_index = int(attribute_match.group("index")) if attribute_match and attribute_match.group("index") else None
    parameter_without_attribute = canonical_compare._normalize_whitespace(MSL_ATTRIBUTE_RE.sub("", cleaned))
    name_match = re.match(r'(?P<type>.+?)\s+(?P<arg_name>[A-Za-z_][A-Za-z0-9_]*)$', parameter_without_attribute)
    if name_match:
        parameter_type = normalize_msl_type(name_match.group("type"))
        arg_name = name_match.group("arg_name")
    else:
        parameter_type = normalize_msl_type(parameter_without_attribute)
        arg_name = None
    semantic_kind = MSL_ATTRIBUTE_KIND_MAP.get(attribute_name or "", f"air.{attribute_name}" if attribute_name else None)
    return {
        "kind": semantic_kind,
        "index": attribute_index,
        "type": parameter_type,
        "argName": arg_name,
        "raw": cleaned,
    }


def extract_msl_entry_signatures(source_text: str) -> list[dict[str, Any]]:
    cleaned_source = strip_msl_comments(source_text)
    entries: list[dict[str, Any]] = []
    for match in MSL_ENTRY_FUNCTION_RE.finditer(cleaned_source):
        raw_params = canonical_compare._split_top_level(match.group("params"))
        parameters = [
            parse_msl_parameter(parameter)
            for parameter in raw_params
            if canonical_compare._normalize_whitespace(parameter) not in {"", "void"}
        ]
        entries.append(
            {
                "shaderType": match.group("shader_type"),
                "returnType": normalize_msl_type(match.group("return_type")),
                "functionName": match.group("function_name"),
                "parameters": parameters,
            }
        )
    return entries


def normalize_ir_return_type_to_msl(return_type: str | None) -> str | None:
    if not return_type:
        return None
    normalized = canonical_compare._normalize_whitespace(return_type)
    if normalized in IR_SCALAR_TYPE_TO_MSL:
        return IR_SCALAR_TYPE_TO_MSL[normalized]
    match = IR_VECTOR_RETURN_TYPE_RE.match(normalized)
    if not match:
        return None
    element = IR_SCALAR_TYPE_TO_MSL.get(match.group("element"))
    if not element:
        return None
    return f"{element}{match.group('width')}"


def expected_return_type_for_ir_entry(entry: dict[str, Any]) -> str | None:
    shader_type = str(entry.get("shaderType") or "")
    if shader_type == "kernel":
        return "void"
    for signature in entry.get("outputSemantics") or []:
        parsed_signature = parse_semantic_signature(str(signature))
        if parsed_signature.get("kind") == "air.render_target" and parsed_signature.get("type"):
            return str(parsed_signature["type"])
    return normalize_ir_return_type_to_msl(entry.get("returnSignature"))


def validate_msl_contract_sync(
    input_path: Path,
    msl_source_path: Path,
    *,
    execution_kind: str,
    cases: list[dict[str, Any]],
    source_label: str,
    enforce_source_filename: bool,
) -> list[str]:
    ir_summary = canonical_compare.extract_ir_summary(input_path)
    parsed_entries = {
        item["functionName"]: item
        for item in extract_msl_entry_signatures(msl_source_path.read_text(encoding="utf-8"))
    }
    expected_shader_type = EXPECTED_FUNCTION_TYPE_BY_EXECUTION_KIND.get(execution_kind)
    if expected_shader_type is None:
        return [f"当前 behavior runner 不支持 executionKind={execution_kind} 的 {source_label} 契约同步校验。"]

    issues: list[str] = []
    source_filename = ir_summary.get("module", {}).get("sourceFilename")
    if enforce_source_filename and source_filename:
        source_basename = Path(str(source_filename)).name
        if source_basename != msl_source_path.name:
            issues.append(
                f".ll 的 source_filename 指向 `{source_basename}`，但 {source_label} 是 `{msl_source_path.name}`。"
            )

    ir_entries_by_key = {
        (str(item.get("shaderType") or ""), str(item.get("functionName") or "")): item
        for item in ir_summary.get("entries") or []
    }
    for case in cases:
        entry_point = str(case.get("entryPoint") or "")
        entry_label = str(case.get("name") or entry_point)
        expected_entry = ir_entries_by_key.get((expected_shader_type, entry_point))
        if expected_entry is None:
            issues.append(f"case `{entry_label}` 在 .ll 中缺少 `{expected_shader_type}` entry `{entry_point}`。")
            continue

        parsed_entry = parsed_entries.get(entry_point)
        if parsed_entry is None:
            issues.append(f"case `{entry_label}` 的 {source_label} 缺少 entry `{entry_point}`。")
            continue

        actual_shader_type = str(parsed_entry.get("shaderType") or "")
        if actual_shader_type != expected_shader_type:
            issues.append(
                f"case `{entry_label}` 的 {source_label} entry `{entry_point}` shader 类型为 `{actual_shader_type}`，预期 `{expected_shader_type}`。"
            )

        expected_return_type = expected_return_type_for_ir_entry(expected_entry)
        actual_return_type = str(parsed_entry.get("returnType") or "")
        if expected_return_type and actual_return_type != expected_return_type:
            issues.append(
                f"case `{entry_label}` 的 {source_label} 返回类型为 `{actual_return_type}`，但 .ll 契约预期 `{expected_return_type}`。"
            )

        expected_params = [parse_semantic_signature(str(signature)) for signature in expected_entry.get("argSemantics") or []]
        actual_params = list(parsed_entry.get("parameters") or [])
        if len(actual_params) != len(expected_params):
            issues.append(
                f"case `{entry_label}` 的 {source_label} 参数个数为 {len(actual_params)}，但 .ll 契约预期 {len(expected_params)}。"
            )
            continue

        for index, (expected_param, actual_param) in enumerate(zip(expected_params, actual_params), start=1):
            expected_kind = expected_param.get("kind")
            actual_kind = actual_param.get("kind")
            if expected_kind != actual_kind:
                issues.append(
                    f"case `{entry_label}` 第 {index} 个参数语义为 `{actual_kind}`，但 {source_label} 的 .ll 契约预期 `{expected_kind}`。"
                )
            expected_binding_index = expected_param.get("location")
            actual_index = actual_param.get("index")
            if expected_binding_index is not None and expected_binding_index != actual_index:
                issues.append(
                    f"case `{entry_label}` 第 {index} 个参数绑定索引为 `{actual_index}`，但 {source_label} 的 .ll 契约预期 `{expected_binding_index}`。"
                )
            expected_type = expected_param.get("type")
            actual_type = actual_param.get("type")
            if expected_type and expected_type != actual_type:
                issues.append(
                    f"case `{entry_label}` 第 {index} 个参数类型为 `{actual_type}`，但 {source_label} 的 .ll 契约预期 `{expected_type}`。"
                )
            expected_name = expected_param.get("argName")
            actual_name = actual_param.get("argName")
            if expected_name and actual_name and expected_name != actual_name:
                issues.append(
                    f"case `{entry_label}` 第 {index} 个参数名为 `{actual_name}`，但 {source_label} 的 .ll 契约预期 `{expected_name}`。"
                )

    return issues


def validate_reference_oracle_sync(
    input_path: Path,
    reference_source_path: Path,
    *,
    execution_kind: str,
    cases: list[dict[str, Any]],
) -> list[str]:
    return validate_msl_contract_sync(
        input_path,
        reference_source_path,
        execution_kind=execution_kind,
        cases=cases,
        source_label="reference MSL",
        enforce_source_filename=True,
    )


def validate_generated_msl_sync(
    input_path: Path,
    generated_source_path: Path,
    *,
    execution_kind: str,
    cases: list[dict[str, Any]],
) -> list[str]:
    return validate_msl_contract_sync(
        input_path,
        generated_source_path,
        execution_kind=execution_kind,
        cases=cases,
        source_label="generated MSL",
        enforce_source_filename=False,
    )


def flatten_numeric_values(values: list[Any]) -> list[float | int]:
    flattened: list[float | int] = []
    for value in values:
        if isinstance(value, list):
            flattened.extend(flatten_numeric_values(value))
        else:
            flattened.append(value)
    return flattened


def build_compute_case_spec(case: dict[str, Any]) -> dict[str, Any]:
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


def build_fragment_case_spec(case: dict[str, Any]) -> dict[str, Any]:
    render_target = dict(case.get("renderTarget") or {})
    return {
        "name": str(case["name"]),
        "entryPoint": str(case["entryPoint"]),
        "renderTarget": {
            "width": int(render_target.get("width") or 1),
            "height": int(render_target.get("height") or 1),
            "pixelFormat": str(render_target.get("pixelFormat") or "rgba16Float"),
        },
        "comparisons": list(case.get("comparisons") or []),
    }


def build_case_spec(case: dict[str, Any], execution_kind: str) -> dict[str, Any]:
    if execution_kind == "compute":
        return build_compute_case_spec(case)
    if execution_kind == "fragment":
        return build_fragment_case_spec(case)
    raise ValueError(f"unsupported execution kind for case spec: {execution_kind}")


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
        expected_function_type = EXPECTED_FUNCTION_TYPE_BY_EXECUTION_KIND.get(execution_kind)
        if expected_function_type is None:
            deferred_samples.append(
                {
                    "sampleKey": sample_key,
                    "status": "deferred",
                    "reason": sample_spec.get("deferredReason")
                    or f"当前 behavior runner 还不支持 executionKind={execution_kind} 的自动化路径。",
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
        case_entry_points = {str(case.get("entryPoint")) for case in sample_spec.get("cases") or []}
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

        mismatched_entries = [
            entry_point
            for entry_point, function_type in generated_type_by_name.items()
            if entry_point in case_entry_points and function_type != expected_function_type
        ]
        if mismatched_entries:
            deferred_samples.append(
                {
                    "sampleKey": sample_key,
                    "status": "deferred",
                    "reason": (
                        f"当前行为规格期望 {expected_function_type} entry；"
                        f"但生成产物里这些入口的 shader 类型不匹配：{', '.join(mismatched_entries)}"
                    ),
                    "executionKind": execution_kind,
                    "phase": "shape-drift",
                    "entries": mismatched_entries,
                    "expectedFunctionType": expected_function_type,
                }
            )
            continue

        reference_source = infer_reference_source_path(gate_entry) or infer_reference_source_path(roundtrip_entry)
        candidate_source = roundtrip_entry.get("generatedMSLPath")
        resolved_candidate_source = Path(str(candidate_source)).expanduser().resolve() if candidate_source else None
        if reference_source is None or not reference_source.is_file():
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"找不到 reference MSL：{reference_source}",
                }
            )
            continue
        if resolved_candidate_source is None or not resolved_candidate_source.is_file():
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"找不到 generated MSL：{candidate_source}",
                }
            )
            continue

        input_path = roundtrip_entry.get("inputPath") or gate_entry.get("inputPath")
        resolved_input_path = Path(str(input_path)).expanduser().resolve() if input_path else None
        if resolved_input_path is None or not resolved_input_path.is_file():
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"找不到 sample LLVM IR：{input_path}",
                }
            )
            continue

        built_cases = [build_case_spec(case, execution_kind) for case in sample_spec.get("cases") or []]

        try:
            reference_sync_issues = validate_reference_oracle_sync(
                resolved_input_path,
                reference_source,
                execution_kind=execution_kind,
                cases=built_cases,
            )
        except Exception as exc:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"校验 reference MSL 与 .ll 契约时失败：{exc}",
                }
            )
            continue
        if reference_sync_issues:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": "reference MSL 与 .ll 契约不一致：" + "；".join(reference_sync_issues),
                }
            )
            continue

        try:
            generated_sync_issues = validate_generated_msl_sync(
                resolved_input_path,
                resolved_candidate_source,
                execution_kind=execution_kind,
                cases=built_cases,
            )
        except Exception as exc:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": f"校验 generated MSL 与 .ll 契约时失败：{exc}",
                }
            )
            continue
        if generated_sync_issues:
            errors.append(
                {
                    "sampleKey": sample_key,
                    "status": "error",
                    "reason": "generated MSL 与 .ll 契约不一致：" + "；".join(generated_sync_issues),
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
                "candidateSourcePath": str(resolved_candidate_source),
                "artifactSpecPath": str((output_root / "behavior-artifacts" / f"{sample_key}.spec.json").resolve()),
                "artifactResultPath": str((output_root / "behavior-artifacts" / f"{sample_key}.result.json").resolve()),
                "cases": built_cases,
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


def select_swift_runner_for_sample(
    sample: dict[str, Any],
    *,
    compute_swift_runner: Path,
    fragment_swift_runner: Path,
) -> Path:
    execution_kind = str(sample.get("executionKind") or "compute")
    if execution_kind == "compute":
        return compute_swift_runner
    if execution_kind == "fragment":
        return fragment_swift_runner
    raise ValueError(f"unsupported execution kind for swift runner selection: {execution_kind}")


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
        return ("fail", f"有 {len(failed)} 个行为样本未通过 reference-vs-generated 对比。")

    if deferred_samples:
        return (
            "warn",
            f"已完成 {len(executed_results)} 个行为样本测试，另有 {len(deferred_samples)} 个候选继续后置。",
        )

    return ("pass", f"已完成 {len(executed_results)} 个行为样本测试，全部通过。")


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


def refresh_gate_summary_layered_decision(gate_summary_path: Path) -> dict[str, Any] | None:
    if not gate_summary_path.is_file():
        return None

    gate_summary = load_json(gate_summary_path)
    risk_report_path_value = gate_summary.get("riskReportPath")
    if not risk_report_path_value:
        return None

    risk_report_path = Path(str(risk_report_path_value)).expanduser().resolve()
    if not risk_report_path.is_file():
        return None

    risk_report = load_json(risk_report_path)
    layered_decision = canonical_compare.assess_layered_validation_decision(gate_summary, risk_report)
    gate_summary["layeredDecision"] = layered_decision
    write_json(gate_summary_path, gate_summary)
    return layered_decision


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
    compute_swift_runner = Path(args.swift_runner).expanduser().resolve()
    fragment_swift_runner = Path(args.fragment_swift_runner).expanduser().resolve()
    if not gate_summary_path.is_file():
        raise SystemExit(f"gate-summary.json 不存在：{gate_summary_path}")
    if not compute_swift_runner.is_file():
        raise SystemExit(f"compute Swift harness 不存在：{compute_swift_runner}")
    if not fragment_swift_runner.is_file():
        raise SystemExit(f"fragment Swift harness 不存在：{fragment_swift_runner}")

    gate_summary = load_json(gate_summary_path)
    output_root = resolve_output_root(args, gate_summary)
    report_path = resolve_report_path(args, output_root)
    validate_default_output_contract(
        args,
        gate_summary,
        output_root=output_root,
        report_path=report_path,
    )
    roundtrip_report_path = resolve_roundtrip_report_path(args, gate_summary)
    if not roundtrip_report_path.is_file():
        raise SystemExit(f"roundtrip-summary.json 不存在：{roundtrip_report_path}")
    roundtrip_report = load_json(roundtrip_report_path)

    sample_keys = gate_candidate_keys(gate_summary, args.sample_keys)
    if not sample_keys:
        if args.sample_keys:
            raise SystemExit("指定的 --sample-key 在当前 gate-summary / roundtrip 报告里没有可执行样本")
        raise SystemExit(
            "默认 L3 行为 gate 在当前 SV-004F 白名单执行面内没有可执行样本；如需定向复核，请显式传 --sample-key。"
        )

    plan = build_behavior_plan(
        gate_summary,
        roundtrip_report,
        sample_keys=sample_keys,
        output_root=output_root,
    )

    executed_results: list[dict[str, Any]] = []
    for sample in plan.get("readySamples") or []:
        swift_runner = select_swift_runner_for_sample(
            sample,
            compute_swift_runner=compute_swift_runner,
            fragment_swift_runner=fragment_swift_runner,
        )
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
    refresh_gate_summary_layered_decision(gate_summary_path)

    if not args.quiet:
        print_summary(summary)
        print(f"behavior report: {report_path}")

    return 0 if summary.get("status") in {"pass", "warn"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
