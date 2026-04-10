#!/usr/bin/env python3
"""
aggregate_replay_runner.py — 为 ShaderCorpus replacement 样本补一条贴近 runtime 的
多模块 aggregate + compile 离线验证入口。

目标：
- 发现 `ShaderCorpus/<bundleId>/replacements/<replacementDir>/aggregate.generated.metal`
- 读取 replacement 对应的 `moduleKeys`，回放各模块 `.ll -> .metal`
- 复现 runtime 的 aggregate / dedupe / preflight / fast-math compile decision
- 对重建后的 aggregate 源码执行 `xcrun metal -c`
- 输出结构化 JSON 报告，补齐单模块 round-trip 之外的 aggregate 真值入口

示例：
    python3 Scripts/aggregate_replay_runner.py \
        --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus \
        --bundle-id com.miHoYo.Yuanshen

    python3 Scripts/aggregate_replay_runner.py \
        --replacement-dir ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus/com.example.demo/replacements/20260405_selector_cache
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import corpus_replay_runner as replay_runner


@dataclasses.dataclass
class AggregateModuleInput:
    module_key: str
    input_path: Path
    metadata_path: Path | None
    baseline_generated_msl_path: Path | None
    function_names: list[str]
    function_types: list[str]
    generated_function_names: list[str]
    generated_function_types: list[str]
    module_summary: str | None
    llvm_ir_bytes: int | None
    output_path: Path | None = None
    order_source: str = "replacement_meta"


@dataclasses.dataclass
class AggregateReplayJob:
    job_id: int
    bundle_id: str
    selector: str | None
    cache_key: str | None
    timestamp: str | None
    replacement_dir: Path
    replacement_meta_path: Path
    aggregate_baseline_path: Path | None
    module_keys: list[str]
    modules: list[AggregateModuleInput]
    output_dir: Path
    aggregate_output_path: Path
    module_order_source: str


def repo_root() -> Path:
    return replay_runner.repo_root()


def default_output_root(root: Path) -> Path:
    return root / "build" / "shader-aggregate-replay" / replay_runner.make_timestamped_run_name()


def default_report_path(output_root: Path) -> Path:
    return (output_root / "aggregate-replay-summary.json").resolve()


def aggregate_compile_harness_swift_path(root: Path) -> Path:
    return root / "Scripts" / "metal_aggregate_compile_harness.swift"


def build_aggregate_compile_harness_binary(root: Path, output_root: Path) -> Path:
    harness_swift = aggregate_compile_harness_swift_path(root)
    if not harness_swift.is_file():
        raise RuntimeError(f"cannot find aggregate compile harness at {harness_swift}")

    binary_path = (output_root / "_internal" / "metal_aggregate_compile_harness").resolve()
    binary_path.parent.mkdir(parents=True, exist_ok=True)
    command = ["swiftc", str(harness_swift), "-o", str(binary_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    return binary_path


def fast_math_mode_to_enabled(fast_math_mode: str | None) -> bool | None:
    if fast_math_mode == "enable":
        return True
    if fast_math_mode == "disable":
        return False
    return None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="执行 ShaderCorpus replacement aggregate 离线 replay + compile 验证")
    parser.add_argument(
        "--corpus-root",
        action="append",
        dest="corpus_roots",
        default=[],
        help="ShaderCorpus 根目录，或单个 bundle 目录（可重复指定）",
    )
    parser.add_argument(
        "--replacement-dir",
        action="append",
        dest="replacement_dirs",
        default=[],
        help="显式指定一个 replacement 目录（可重复指定）",
    )
    parser.add_argument(
        "--bundle-id",
        action="append",
        default=[],
        help="仅处理指定 bundleId（可重复指定）",
    )
    parser.add_argument("--limit", type=int, help="最多处理多少个 aggregate 样本")
    parser.add_argument(
        "--output-root",
        help="批量输出根目录；默认写入 build/shader-aggregate-replay/<timestamp>/",
    )
    parser.add_argument(
        "--report-file",
        help="JSON 报告输出路径；默认写到 output-root/aggregate-replay-summary.json",
    )
    parser.add_argument(
        "--allow-failures",
        action="store_true",
        help="即使存在 replay / aggregate / compile 失败也返回 0，便于先收集报告",
    )
    parser.add_argument(
        "--compile-backend",
        choices=["xcrun", "mtl-device"],
        default="xcrun",
        help="aggregate compile backend：`xcrun metal -c` 或 `MTLDevice.newLibraryWithSource(...)`，默认 xcrun",
    )
    parser.add_argument(
        "--metal-sdk",
        default="macosx",
        help="`xcrun --sdk` 使用的 SDK 名称，默认 macosx（仅 `--compile-backend xcrun` 生效）",
    )
    parser.add_argument(
        "--metal-arg",
        action="append",
        dest="metal_args",
        default=[],
        help="额外透传给 compile backend 的参数；`mtl-device` 仅支持显式 fast-math override（可重复指定）",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="即使 aggregate 源码命中 shared preflight 规则，也继续尝试执行 Metal 编译",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="仅写文件，不打印人类可读摘要",
    )
    return parser


def load_jsonl(path: Path, warnings: list[replay_runner.DiscoveryWarning]) -> list[dict[str, Any]]:
    if not path.is_file():
        return []

    rows: list[dict[str, Any]] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            replay_runner.warn(warnings, f"invalid JSONL line {line_number} in {path}: {exc}")
            continue
        if isinstance(payload, dict):
            rows.append(payload)
    return rows


def dedupe_preserving_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def sanitize_msl_identifier(name: str) -> str:
    parts: list[str] = []
    for char in name:
        if char.isalnum() or char == "_":
            parts.append(char)
        else:
            parts.append("_")
    result = "".join(parts) or "_unnamed"
    if result[0].isdigit():
        result = f"_{result}"
    return result


def strip_generated_msl_header(source: str) -> str:
    lines = source.splitlines()
    try:
        header_index = lines.index("using namespace metal;")
    except ValueError:
        return source.strip()

    body_start = header_index + 1
    while body_start < len(lines) and not lines[body_start].strip():
        body_start += 1
    return "\n".join(lines[body_start:]).strip()


def resolve_manifest_capture_order(
    bundle_root: Path,
    selector: str | None,
    cache_key: str | None,
    timestamp: str | None,
    fallback_module_keys: list[str],
    warnings: list[replay_runner.DiscoveryWarning],
) -> tuple[list[str], str]:
    manifest_path = bundle_root / "manifest.jsonl"
    events = load_jsonl(manifest_path, warnings)
    if not events:
        return list(fallback_module_keys), "replacement_meta"

    ordered: list[str] = []
    for event in events:
        if event.get("event") != "capture":
            continue
        if selector and event.get("selector") != selector:
            continue
        if cache_key and event.get("cacheKey") != cache_key:
            continue
        if timestamp and event.get("timestamp") != timestamp:
            continue
        module_key = event.get("moduleKey")
        if isinstance(module_key, str) and module_key:
            ordered.append(module_key)

    if not ordered and cache_key:
        for event in events:
            if event.get("event") != "capture":
                continue
            if selector and event.get("selector") != selector:
                continue
            if event.get("cacheKey") != cache_key:
                continue
            module_key = event.get("moduleKey")
            if isinstance(module_key, str) and module_key:
                ordered.append(module_key)

    if not ordered:
        return list(fallback_module_keys), "replacement_meta"

    resolved = dedupe_preserving_order(ordered + list(fallback_module_keys))
    return resolved, "manifest_capture_order"


def resolve_module_input(
    bundle_root: Path,
    module_key: str,
    order_source: str,
    warnings: list[replay_runner.DiscoveryWarning],
) -> AggregateModuleInput | None:
    module_dir = bundle_root / "modules" / module_key
    meta_path = (module_dir / "module.meta.json").resolve()
    metadata = replay_runner.load_json(meta_path, warnings) if meta_path.is_file() else None
    if meta_path.is_file() and metadata is None:
        return None

    artifact_paths = (metadata or {}).get("artifactPaths") or {}
    llvm_ir_rel = artifact_paths.get("llvmIRPath") or f"modules/{module_key}/module.ll"
    input_path = (bundle_root / llvm_ir_rel).resolve()
    if not input_path.is_file():
        replay_runner.warn(warnings, f"missing LLVM IR file for aggregate module {module_key}: {input_path}")
        return None

    generated_rel = artifact_paths.get("generatedMSLPath")
    baseline_generated_msl_path: Path | None = None
    if isinstance(generated_rel, str) and generated_rel:
        candidate = (bundle_root / generated_rel).resolve()
        if candidate.is_file():
            baseline_generated_msl_path = candidate
    else:
        fallback_generated = module_dir / "module.generated.metal"
        if fallback_generated.is_file():
            baseline_generated_msl_path = fallback_generated.resolve()

    return AggregateModuleInput(
        module_key=module_key,
        input_path=input_path,
        metadata_path=meta_path if meta_path.is_file() else None,
        baseline_generated_msl_path=baseline_generated_msl_path,
        function_names=list((metadata or {}).get("functionNames") or []),
        function_types=list((metadata or {}).get("functionTypes") or []),
        generated_function_names=list((metadata or {}).get("generatedFunctionNames") or []),
        generated_function_types=list((metadata or {}).get("generatedFunctionTypes") or []),
        module_summary=(metadata or {}).get("moduleSummary"),
        llvm_ir_bytes=(metadata or {}).get("llvmIRBytes"),
        order_source=order_source,
    )


def make_job_output_paths(output_root: Path, bundle_id: str, replacement_dir: Path) -> tuple[Path, Path]:
    relative = Path(replay_runner.sanitize_path_component(bundle_id)) / "replacements" / replay_runner.sanitize_path_component(replacement_dir.name)
    output_dir = (output_root / relative).resolve()
    aggregate_output_path = (output_dir / "aggregate.replayed.generated.metal").resolve()
    return output_dir, aggregate_output_path


def resolve_replacement_job(
    replacement_dir: Path,
    explicit_bundle_root: Path | None,
    args: argparse.Namespace,
    output_root: Path,
    warnings: list[replay_runner.DiscoveryWarning],
    next_job_id: int,
) -> AggregateReplayJob | None:
    replacement_dir = replacement_dir.expanduser().resolve()
    if not replacement_dir.is_dir():
        replay_runner.warn(warnings, f"replacement directory does not exist: {replacement_dir}")
        return None

    replacement_meta_path = (replacement_dir / "replacement.meta.json").resolve()
    if not replacement_meta_path.is_file():
        replay_runner.warn(warnings, f"missing replacement.meta.json: {replacement_meta_path}")
        return None

    bundle_root = explicit_bundle_root.resolve() if explicit_bundle_root else replacement_dir.parent.parent.resolve()
    if replacement_dir.parent.name != "replacements":
        replay_runner.warn(warnings, f"replacement directory is not under a replacements/ directory: {replacement_dir}")
        return None

    metadata = replay_runner.load_json(replacement_meta_path, warnings)
    if metadata is None:
        return None

    bundle_id = str(metadata.get("bundleId") or bundle_root.name)
    bundle_filters = set(args.bundle_id)
    if bundle_filters and bundle_id not in bundle_filters:
        return None

    raw_module_keys = [str(item) for item in (metadata.get("moduleKeys") or []) if str(item)]
    if not raw_module_keys:
        replay_runner.warn(warnings, f"replacement manifest has no moduleKeys: {replacement_meta_path}")
        return None

    selector = metadata.get("selector")
    cache_key = metadata.get("cacheKey")
    timestamp = metadata.get("timestamp")
    ordered_module_keys, module_order_source = resolve_manifest_capture_order(
        bundle_root,
        str(selector) if selector else None,
        str(cache_key) if cache_key else None,
        str(timestamp) if timestamp else None,
        raw_module_keys,
        warnings,
    )

    modules: list[AggregateModuleInput] = []
    for module_key in ordered_module_keys:
        module_input = resolve_module_input(bundle_root, module_key, module_order_source, warnings)
        if module_input is None:
            replay_runner.warn(
                warnings,
                f"skip aggregate replacement because module {module_key} is incomplete: {replacement_dir}",
            )
            return None
        modules.append(module_input)

    aggregate_baseline_path = (replacement_dir / "aggregate.generated.metal").resolve()
    if not aggregate_baseline_path.is_file():
        replay_runner.warn(warnings, f"missing aggregate.generated.metal: {aggregate_baseline_path}")
        aggregate_baseline_path = None

    output_dir, aggregate_output_path = make_job_output_paths(output_root, bundle_id, replacement_dir)
    return AggregateReplayJob(
        job_id=next_job_id,
        bundle_id=bundle_id,
        selector=str(selector) if selector else None,
        cache_key=str(cache_key) if cache_key else None,
        timestamp=str(timestamp) if timestamp else None,
        replacement_dir=replacement_dir,
        replacement_meta_path=replacement_meta_path,
        aggregate_baseline_path=aggregate_baseline_path,
        module_keys=ordered_module_keys,
        modules=modules,
        output_dir=output_dir,
        aggregate_output_path=aggregate_output_path,
        module_order_source=module_order_source,
    )


def discover_jobs(
    args: argparse.Namespace,
    output_root: Path,
    warnings: list[replay_runner.DiscoveryWarning],
) -> list[AggregateReplayJob]:
    jobs: list[AggregateReplayJob] = []
    next_job_id = 0

    if args.replacement_dirs:
        for raw_dir in args.replacement_dirs:
            job = resolve_replacement_job(Path(raw_dir), None, args, output_root, warnings, next_job_id)
            if job is not None:
                jobs.append(job)
                next_job_id += 1
        if args.limit is not None:
            return jobs[: args.limit]
        return jobs

    corpus_roots = [Path(raw).expanduser().resolve() for raw in args.corpus_roots]
    if not corpus_roots:
        default_root = replay_runner.default_corpus_root()
        if default_root is not None:
            corpus_roots = [default_root.resolve()]

    for corpus_root in corpus_roots:
        bundle_roots = replay_runner.resolve_bundle_roots(corpus_root)
        if not bundle_roots:
            replay_runner.warn(warnings, f"no bundle roots found under corpus root: {corpus_root}")
            continue

        for bundle_root in bundle_roots:
            bundle_filters = set(args.bundle_id)
            if bundle_filters and bundle_root.name not in bundle_filters:
                continue
            replacements_root = bundle_root / "replacements"
            if not replacements_root.is_dir():
                replay_runner.warn(warnings, f"no replacements directory found under bundle root: {bundle_root}")
                continue

            replacement_dirs = sorted(child for child in replacements_root.iterdir() if child.is_dir())
            for replacement_dir in replacement_dirs:
                job = resolve_replacement_job(replacement_dir, bundle_root, args, output_root, warnings, next_job_id)
                if job is None:
                    continue
                jobs.append(job)
                next_job_id += 1
                if args.limit is not None and len(jobs) >= args.limit:
                    return jobs

    return jobs


def prepare_module_replay_jobs(jobs: list[AggregateReplayJob]) -> list[replay_runner.ReplayJob]:
    replay_jobs: list[replay_runner.ReplayJob] = []
    next_job_id = 0
    for aggregate_job in jobs:
        for module in aggregate_job.modules:
            output_path = (
                aggregate_job.output_dir
                / "modules"
                / replay_runner.sanitize_path_component(module.module_key)
                / "replayed.generated.metal"
            ).resolve()
            module.output_path = output_path
            replay_jobs.append(
                replay_runner.ReplayJob(
                    job_id=next_job_id,
                    source_kind="shader_corpus_aggregate_module",
                    input_path=module.input_path,
                    output_path=output_path,
                    bundle_id=aggregate_job.bundle_id,
                    module_key=module.module_key,
                    metadata_path=module.metadata_path,
                    baseline_generated_msl_path=module.baseline_generated_msl_path,
                    function_names=list(module.function_names),
                    function_types=list(module.function_types),
                    source_root=aggregate_job.replacement_dir,
                )
            )
            next_job_id += 1
    return replay_jobs


def run_module_replays(
    jobs: list[AggregateReplayJob],
    converter_swift: Path,
    output_root: Path,
    warnings: list[replay_runner.DiscoveryWarning],
) -> tuple[dict[int, dict[str, Any]], dict[str, Any]]:
    replay_jobs = prepare_module_replay_jobs(jobs)
    if not replay_jobs:
        return {}, replay_runner.enrich_report({"results": []}, [], warnings, output_root)

    internal_report_path = (output_root / "_internal" / "aggregate-module-replay.json").resolve()
    raw_report = replay_runner.run_replay_jobs(replay_jobs, converter_swift, internal_report_path)
    enriched_report = replay_runner.enrich_report(raw_report, replay_jobs, warnings, output_root)
    by_job_id = {item["jobID"]: item for item in enriched_report.get("results", [])}
    return by_job_id, enriched_report


def build_aggregate_source(job: AggregateReplayJob, module_results: list[dict[str, Any]]) -> dict[str, Any]:
    duplicate_function_names: set[str] = set()
    seen_function_names: set[str] = set()
    per_module_sanitized_names: list[list[str]] = []

    for result in module_results:
        sanitized_names = [
            sanitize_msl_identifier(name)
            for name in (result.get("generatedFunctionNames") or [])
            if isinstance(name, str) and name
        ]
        per_module_sanitized_names.append(sanitized_names)
        for name in sanitized_names:
            if name in seen_function_names:
                duplicate_function_names.add(name)
            else:
                seen_function_names.add(name)

    deduplicated_modules: list[tuple[AggregateModuleInput, dict[str, Any], list[str]]] = []
    dedup_seen_names: set[str] = set()
    skipped_module_count = 0

    for module, result, sanitized_names in zip(job.modules, module_results, per_module_sanitized_names):
        has_new_function = any(name not in dedup_seen_names for name in sanitized_names)
        if has_new_function:
            deduplicated_modules.append((module, result, sanitized_names))
            dedup_seen_names.update(sanitized_names)
        else:
            skipped_module_count += 1

    if not deduplicated_modules:
        raise RuntimeError("Aggregated MSL module body is empty: all modules deduplicated away")

    lines: list[str] = [
        "//",
        "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection",
        "// E-005b: multi-module source aggregation",
        f"// Generated at: {replay_runner.utc_now_iso()}",
        f"// Modules: {len(deduplicated_modules)}/{len(job.modules)}",
        f"// Functions: {sum(len(result.get('generatedFunctionNames') or []) for _, result, _ in deduplicated_modules)}",
        "//",
        "",
        "#include <metal_stdlib>",
        "using namespace metal;",
        "",
    ]

    deduplicated_module_keys: list[str] = []
    module_summaries: list[str] = []
    source_function_names: list[str] = []
    source_function_types: list[str] = []
    total_ir_size = 0

    for index, (module, result, _) in enumerate(deduplicated_modules):
        source_path = Path(result["outputPath"]).resolve()
        source_text = source_path.read_text(encoding="utf-8", errors="replace")
        body = strip_generated_msl_header(source_text)
        if not body:
            summary = module.module_summary or module.module_key
            raise RuntimeError(f"Aggregated MSL module body is empty: {summary}")

        module_summary = module.module_summary or module.module_key
        lines.append(f"// ===== Module {index} {module_summary} =====")
        lines.append(body)
        lines.append("")

        deduplicated_module_keys.append(module.module_key)
        module_summaries.append(module_summary)
        source_function_names.extend([str(name) for name in (result.get("generatedFunctionNames") or [])])
        source_function_types.extend([str(name) for name in (result.get("generatedFunctionTypes") or [])])
        total_ir_size += int(module.llvm_ir_bytes or module.input_path.stat().st_size)

    source = "\n".join(lines)
    job.aggregate_output_path.parent.mkdir(parents=True, exist_ok=True)
    job.aggregate_output_path.write_text(source, encoding="utf-8")

    return {
        "success": True,
        "sourcePath": str(job.aggregate_output_path),
        "sourceBytes": len(source.encode("utf-8")),
        "moduleCount": len(deduplicated_modules),
        "inputModuleCount": len(job.modules),
        "functionCount": sum(len(result.get("generatedFunctionNames") or []) for _, result, _ in deduplicated_modules),
        "totalIRBytes": total_ir_size,
        "duplicateFunctionNames": sorted(duplicate_function_names),
        "dedupeSkippedModuleCount": skipped_module_count,
        "deduplicatedModuleKeys": deduplicated_module_keys,
        "moduleSummaries": module_summaries,
        "sourceFunctionNames": sorted(set(source_function_names)),
        "sourceFunctionTypes": sorted(set(source_function_types)),
    }


def compare_aggregate_sources(current_path: Path, baseline_path: Path | None) -> dict[str, Any]:
    comparison = {
        "currentPath": str(current_path),
        "baselinePath": str(baseline_path) if baseline_path else None,
        "baselineAvailable": bool(baseline_path and baseline_path.is_file()),
        "compared": False,
        "changed": None,
        "currentNormalizedSHA256": None,
        "baselineNormalizedSHA256": None,
        "lineChanges": None,
        "diffPreview": [],
    }
    if baseline_path is None or not baseline_path.is_file():
        return comparison

    current_text = current_path.read_text(encoding="utf-8", errors="replace")
    baseline_text = baseline_path.read_text(encoding="utf-8", errors="replace")
    normalized_current = replay_runner.normalize_generated_msl(current_text)
    normalized_baseline = replay_runner.normalize_generated_msl(baseline_text)
    comparison["compared"] = True
    comparison["currentNormalizedSHA256"] = replay_runner.sha256_text(normalized_current)
    comparison["baselineNormalizedSHA256"] = replay_runner.sha256_text(normalized_baseline)
    changed = normalized_current != normalized_baseline
    comparison["changed"] = changed
    baseline_lines = normalized_baseline.splitlines()
    current_lines = normalized_current.splitlines()
    comparison["lineChanges"] = replay_runner.compute_line_change_stats(baseline_lines, current_lines)
    if changed:
        import difflib

        comparison["diffPreview"] = list(
            difflib.unified_diff(
                baseline_lines,
                current_lines,
                fromfile=str(baseline_path),
                tofile=str(current_path),
                lineterm="",
            )
        )[:40]
    return comparison


def resolve_user_fast_math_override(user_metal_args: list[str] | None) -> str | None:
    override_mode: str | None = None
    for arg in user_metal_args or []:
        if arg == "-ffast-math":
            override_mode = "enable"
        elif arg == "-fno-fast-math":
            override_mode = "disable"
    return override_mode


# 这里是 `xcrun metal -c` 专用的 compile posture -> CLI args 映射层。
# 共享的是 token / 决策语义，不共享执行宿主；`mtl-device` 路径应继续让 Swift runtime-like harness 自己决策。
def resolve_aggregate_compile_metal_args(
    original_ir_paths: list[Path],
    user_metal_args: list[str] | None,
) -> tuple[str | None, str, list[str], list[str]]:
    effective_args = list(user_metal_args or [])
    explicit_override_mode = resolve_user_fast_math_override(effective_args)
    if explicit_override_mode is not None:
        return explicit_override_mode, "user_override", [], effective_args

    inferred_modes = [replay_runner.infer_original_ir_fast_math_mode(path) for path in original_ir_paths]
    known_modes = [mode for mode in inferred_modes if mode is not None]
    if not known_modes:
        return None, "fast_math_unavailable", [], effective_args

    first_mode = known_modes[0]
    if any(mode != first_mode for mode in known_modes):
        return None, "fast_math_conflict", [], effective_args

    if len(known_modes) != len(inferred_modes):
        return None, "fast_math_partial", [], effective_args

    inferred_args = ["-ffast-math"] if first_mode == "enable" else ["-fno-fast-math"]
    return first_mode, "fast_math_aligned", inferred_args, [*inferred_args, *effective_args]


def compile_aggregate_source(
    aggregate_result: dict[str, Any],
    original_ir_paths: list[Path],
    args: argparse.Namespace,
    *,
    job_id: int,
    bundle_id: str,
    replacement_key: str,
    module_keys: list[str],
) -> dict[str, Any]:
    source_path = Path(aggregate_result["sourcePath"]).resolve()
    base_result = {
        "jobID": job_id,
        "bundleId": bundle_id,
        "moduleKey": replacement_key,
        "moduleKeys": list(module_keys),
        "sourcePath": str(source_path),
        "airPath": None,
        "success": False,
        "status": "skipped_aggregate_failed",
        "compileBackend": args.compile_backend,
        "backendReportPath": None,
        "libraryFunctionNames": [],
        "libraryFunctionCount": 0,
        "usesExplicitCompileOptions": False,
        "compileOptionsFastMathEnabled": None,
        "command": None,
        "returnCode": None,
        "elapsedSeconds": None,
        "stdout": None,
        "stderr": None,
        "compilerOutput": None,
        "preflightIssueCount": 0,
        "preflightIssues": [],
        "diagnostics": [],
        "primaryDiagnostic": None,
        "sourceContext": [],
        "clusterKey": None,
        "clusterCategory": None,
        "clusterTitle": None,
        "error": None,
        "fastMathMode": None,
        "fastMathDecision": None,
        "inferredMetalArgs": [],
        "effectiveMetalArgs": [],
    }

    if not aggregate_result.get("success"):
        base_result["error"] = aggregate_result.get("error") or "aggregate_failed"
        return base_result

    source_text = source_path.read_text(encoding="utf-8", errors="replace")
    preflight_issues = replay_runner.validate_generated_msl_source(source_text)
    base_result["preflightIssueCount"] = len(preflight_issues)
    base_result["preflightIssues"] = preflight_issues

    if preflight_issues and not args.skip_preflight:
        base_result["status"] = "preflight_rejected"
        base_result["error"] = preflight_issues[0]["summary"]
        cluster_key, cluster_category, cluster_title = replay_runner.derive_failure_cluster(
            base_result["status"], [], preflight_issues, base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    if args.compile_backend == "mtl-device":
        # runtime-like 路径：Python 只组装 request / 消费 report，真正的 compile posture 与 `MTLCompileOptions`
        # 决策留在 Swift harness，保持与 runtime 主路径一致。
        harness_binary_value = getattr(args, "aggregate_compile_harness_binary", None)
        harness_binary = Path(harness_binary_value).expanduser().resolve() if harness_binary_value else None
        if harness_binary is None or not harness_binary.is_file():
            base_result["status"] = "compile_failed"
            base_result["error"] = f"aggregate compile harness binary is missing: {harness_binary_value or 'unset'}"
            cluster_key, cluster_category, cluster_title = replay_runner.derive_failure_cluster(
                base_result["status"], [], preflight_issues, base_result["error"]
            )
            base_result["clusterKey"] = cluster_key
            base_result["clusterCategory"] = cluster_category
            base_result["clusterTitle"] = cluster_title
            return base_result

        manifest_source = replay_runner.shared_compile_decision_manifest_path().expanduser().resolve()
        if not manifest_source.is_file():
            base_result["status"] = "compile_failed"
            base_result["error"] = f"shared compile decision manifest source is missing: {manifest_source}"
            cluster_key, cluster_category, cluster_title = replay_runner.derive_failure_cluster(
                base_result["status"], [], preflight_issues, base_result["error"]
            )
            base_result["clusterKey"] = cluster_key
            base_result["clusterCategory"] = cluster_category
            base_result["clusterTitle"] = cluster_title
            return base_result

        report_path = source_path.with_name(f"{source_path.stem}.mtl-device.compile.json").resolve()
        base_result["backendReportPath"] = str(report_path)
        command = [
            str(harness_binary),
            "--source",
            str(source_path),
            "--report",
            str(report_path),
            "--manifest-source",
            str(manifest_source),
        ]
        for original_ir_path in original_ir_paths:
            command.extend(["--original-ir", str(original_ir_path.expanduser().resolve())])
        for metal_arg in list(args.metal_args):
            command.extend(["--metal-arg", metal_arg])
        base_result["command"] = replay_runner.shell_join(command)

        start_time = time.perf_counter()
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
        elapsed = time.perf_counter() - start_time
        combined_output = "\n".join(part for part in [completed.stdout.strip(), completed.stderr.strip()] if part)

        harness_payload: dict[str, Any] = {}
        if report_path.is_file():
            try:
                harness_payload = json.loads(report_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                combined_output = "\n".join(
                    part
                    for part in [combined_output, f"invalid compile harness report {report_path}: {exc}"]
                    if part
                )

        compiler_message = str(harness_payload.get("error") or "").strip()
        diagnostics_input = compiler_message or combined_output
        diagnostics = replay_runner.extract_compiler_diagnostics(diagnostics_input)
        primary_diagnostic = replay_runner.select_primary_diagnostic(diagnostics)

        base_result["returnCode"] = completed.returncode
        base_result["elapsedSeconds"] = round(elapsed, 6)
        base_result["stdout"] = replay_runner.truncate_text(completed.stdout)
        base_result["stderr"] = replay_runner.truncate_text(completed.stderr)
        base_result["compilerOutput"] = replay_runner.truncate_text(compiler_message or combined_output, limit=16000)
        base_result["diagnostics"] = diagnostics
        base_result["primaryDiagnostic"] = primary_diagnostic
        base_result["libraryFunctionNames"] = [str(name) for name in (harness_payload.get("functionNames") or [])]
        base_result["libraryFunctionCount"] = int(harness_payload.get("functionCount") or 0)
        if isinstance(harness_payload.get("fastMathMode"), str):
            base_result["fastMathMode"] = harness_payload["fastMathMode"]
        if isinstance(harness_payload.get("fastMathDecision"), str):
            base_result["fastMathDecision"] = harness_payload["fastMathDecision"]
        base_result["inferredMetalArgs"] = [str(arg) for arg in (harness_payload.get("inferredMetalArgs") or [])]
        base_result["effectiveMetalArgs"] = [str(arg) for arg in (harness_payload.get("effectiveMetalArgs") or [])]
        if isinstance(harness_payload.get("usesExplicitCompileOptions"), bool):
            base_result["usesExplicitCompileOptions"] = harness_payload["usesExplicitCompileOptions"]
        if "fastMathEnabled" in harness_payload:
            base_result["compileOptionsFastMathEnabled"] = harness_payload.get("fastMathEnabled")
        if primary_diagnostic is not None:
            base_result["sourceContext"] = replay_runner.read_source_context(source_path, int(primary_diagnostic["line"]))

        if harness_payload.get("success") is True and completed.returncode == 0:
            base_result["status"] = "success"
            base_result["success"] = True
            return base_result

        base_result["status"] = "compile_failed"
        base_result["error"] = compiler_message or combined_output or f"mtl-device compile harness exited with status {completed.returncode}"
        cluster_key, cluster_category, cluster_title = replay_runner.derive_failure_cluster(
            base_result["status"], diagnostics, preflight_issues, base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    # CLI backend 保留边界：这里只服务 `xcrun metal -c`，负责把共享 fast-math posture 映射为 CLI metal args。
    fast_math_mode, fast_math_decision, inferred_args, effective_args = resolve_aggregate_compile_metal_args(
        original_ir_paths,
        list(args.metal_args),
    )
    base_result["fastMathMode"] = fast_math_mode
    base_result["fastMathDecision"] = fast_math_decision
    base_result["inferredMetalArgs"] = inferred_args
    base_result["effectiveMetalArgs"] = effective_args
    base_result["usesExplicitCompileOptions"] = fast_math_mode is not None
    base_result["compileOptionsFastMathEnabled"] = fast_math_mode_to_enabled(fast_math_mode)

    air_path = replay_runner.compiled_air_output_path(source_path).resolve()
    air_path.parent.mkdir(parents=True, exist_ok=True)
    if air_path.exists():
        air_path.unlink()
    base_result["airPath"] = str(air_path)

    command = ["xcrun", "--sdk", args.metal_sdk, "metal", "-c", *effective_args, str(source_path), "-o", str(air_path)]
    base_result["command"] = replay_runner.shell_join(command)

    start_time = time.perf_counter()
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    elapsed = time.perf_counter() - start_time
    combined_output = "\n".join(part for part in [completed.stdout.strip(), completed.stderr.strip()] if part)
    diagnostics = replay_runner.extract_compiler_diagnostics(combined_output)
    primary_diagnostic = replay_runner.select_primary_diagnostic(diagnostics)

    base_result["returnCode"] = completed.returncode
    base_result["elapsedSeconds"] = round(elapsed, 6)
    base_result["stdout"] = replay_runner.truncate_text(completed.stdout)
    base_result["stderr"] = replay_runner.truncate_text(completed.stderr)
    base_result["compilerOutput"] = replay_runner.truncate_text(combined_output, limit=16000)
    base_result["diagnostics"] = diagnostics
    base_result["primaryDiagnostic"] = primary_diagnostic
    if primary_diagnostic is not None:
        base_result["sourceContext"] = replay_runner.read_source_context(source_path, int(primary_diagnostic["line"]))

    if completed.returncode == 0:
        base_result["status"] = "success"
        base_result["success"] = True
        return base_result

    base_result["status"] = "compile_failed"
    base_result["error"] = combined_output or f"metal exited with status {completed.returncode}"
    cluster_key, cluster_category, cluster_title = replay_runner.derive_failure_cluster(
        base_result["status"], diagnostics, preflight_issues, base_result["error"]
    )
    base_result["clusterKey"] = cluster_key
    base_result["clusterCategory"] = cluster_category
    base_result["clusterTitle"] = cluster_title
    return base_result


def build_job_result(
    job: AggregateReplayJob,
    module_results: list[dict[str, Any]],
    args: argparse.Namespace,
) -> dict[str, Any]:
    replay_failed_modules = [item for item in module_results if not item.get("success")]
    module_payload = [
        {
            "moduleKey": module.module_key,
            "inputPath": str(module.input_path),
            "metadataPath": str(module.metadata_path) if module.metadata_path else None,
            "orderSource": module.order_source,
            "replay": result,
        }
        for module, result in zip(job.modules, module_results)
    ]

    aggregate_result: dict[str, Any] = {
        "success": False,
        "sourcePath": str(job.aggregate_output_path),
        "sourceBytes": 0,
        "moduleCount": 0,
        "inputModuleCount": len(job.modules),
        "functionCount": 0,
        "totalIRBytes": 0,
        "duplicateFunctionNames": [],
        "dedupeSkippedModuleCount": 0,
        "deduplicatedModuleKeys": [],
        "moduleSummaries": [],
        "sourceFunctionNames": [],
        "sourceFunctionTypes": [],
        "baselineComparison": compare_aggregate_sources(job.aggregate_output_path, job.aggregate_baseline_path)
        if job.aggregate_output_path.exists()
        else {
            "currentPath": str(job.aggregate_output_path),
            "baselinePath": str(job.aggregate_baseline_path) if job.aggregate_baseline_path else None,
            "baselineAvailable": bool(job.aggregate_baseline_path and job.aggregate_baseline_path.is_file()),
            "compared": False,
            "changed": None,
            "currentNormalizedSHA256": None,
            "baselineNormalizedSHA256": None,
            "lineChanges": None,
            "diffPreview": [],
        },
        "error": None,
    }

    if replay_failed_modules:
        error_summary = "; ".join(
            f"{item.get('moduleKey') or Path(item.get('inputPath', 'module')).stem}: {item.get('error') or 'replay_failed'}"
            for item in replay_failed_modules[:5]
        )
        aggregate_result["error"] = error_summary
        compile_result = compile_aggregate_source(
            aggregate_result,
            [module.input_path for module in job.modules],
            args,
            job_id=job.job_id,
            bundle_id=job.bundle_id,
            replacement_key=job.replacement_dir.name,
            module_keys=job.module_keys,
        )
        return {
            "jobID": job.job_id,
            "sourceKind": "shader_corpus_aggregate",
            "bundleId": job.bundle_id,
            "selector": job.selector,
            "cacheKey": job.cache_key,
            "timestamp": job.timestamp,
            "replacementDir": str(job.replacement_dir),
            "replacementMetaPath": str(job.replacement_meta_path),
            "moduleOrderSource": job.module_order_source,
            "moduleKeys": list(job.module_keys),
            "moduleCount": len(job.modules),
            "aggregateBaselinePath": str(job.aggregate_baseline_path) if job.aggregate_baseline_path else None,
            "modules": module_payload,
            "aggregate": aggregate_result,
            "compile": compile_result,
            "overallStatus": "replay_failed",
            "failureStage": "replay",
            "errorSummary": error_summary,
        }

    try:
        aggregate_result = build_aggregate_source(job, module_results)
        aggregate_result["baselineComparison"] = compare_aggregate_sources(job.aggregate_output_path, job.aggregate_baseline_path)
        aggregate_result["error"] = None
    except Exception as exc:
        aggregate_result["success"] = False
        aggregate_result["error"] = str(exc)
        aggregate_result["baselineComparison"] = compare_aggregate_sources(job.aggregate_output_path, job.aggregate_baseline_path)

    compile_result = compile_aggregate_source(
        aggregate_result,
        [module.input_path for module in job.modules],
        args,
        job_id=job.job_id,
        bundle_id=job.bundle_id,
        replacement_key=job.replacement_dir.name,
        module_keys=job.module_keys,
    )

    failure_stage: str | None = None
    error_summary: str | None = None
    overall_status = "success"
    if not aggregate_result.get("success"):
        overall_status = "aggregate_failed"
        failure_stage = "aggregate"
        error_summary = aggregate_result.get("error")
    elif compile_result.get("status") != "success":
        overall_status = "compile_failed"
        failure_stage = "compile"
        error_summary = compile_result.get("error") or compile_result.get("clusterTitle")

    return {
        "jobID": job.job_id,
        "sourceKind": "shader_corpus_aggregate",
        "bundleId": job.bundle_id,
        "selector": job.selector,
        "cacheKey": job.cache_key,
        "timestamp": job.timestamp,
        "replacementDir": str(job.replacement_dir),
        "replacementMetaPath": str(job.replacement_meta_path),
        "moduleOrderSource": job.module_order_source,
        "moduleKeys": list(job.module_keys),
        "moduleCount": len(job.modules),
        "aggregateBaselinePath": str(job.aggregate_baseline_path) if job.aggregate_baseline_path else None,
        "modules": module_payload,
        "aggregate": aggregate_result,
        "compile": compile_result,
        "overallStatus": overall_status,
        "failureStage": failure_stage,
        "errorSummary": error_summary,
    }


def build_report(
    jobs: list[AggregateReplayJob],
    module_replay_report: dict[str, Any],
    job_results: list[dict[str, Any]],
    output_root: Path,
    report_path: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    compile_results = [item["compile"] for item in job_results]
    compile_clusters = replay_runner.build_failure_clusters(compile_results)
    module_replay_failed_jobs = sum(1 for item in job_results if item.get("failureStage") == "replay")
    aggregate_failed_jobs = sum(1 for item in job_results if item.get("failureStage") == "aggregate")
    preflight_rejected_jobs = sum(1 for item in compile_results if item.get("status") == "preflight_rejected")
    compile_failed_jobs = sum(1 for item in compile_results if item.get("status") == "compile_failed")
    compile_succeeded_jobs = sum(1 for item in compile_results if item.get("status") == "success")
    baseline_compared_jobs = sum(1 for item in job_results if (item.get("aggregate") or {}).get("baselineComparison", {}).get("compared"))
    baseline_changed_jobs = sum(
        1
        for item in job_results
        if (item.get("aggregate") or {}).get("baselineComparison", {}).get("changed") is True
    )

    return {
        "schemaVersion": 1,
        "generatedAt": replay_runner.utc_now_iso(),
        "tool": "Scripts/aggregate_replay_runner.py",
        "reportPath": str(report_path),
        "outputRoot": str(output_root),
        "requestedInputs": {
            "corpusRoots": list(args.corpus_roots),
            "replacementDirs": list(args.replacement_dirs),
            "bundleIds": list(args.bundle_id),
            "limit": args.limit,
            "allowFailures": bool(args.allow_failures),
            "compileBackend": args.compile_backend,
            "metalSDK": args.metal_sdk,
            "metalArgs": list(args.metal_args),
            "skipPreflight": bool(args.skip_preflight),
        },
        "aggregateJobCount": len(jobs),
        "successfulJobs": sum(1 for item in job_results if item.get("overallStatus") == "success"),
        "failedJobs": sum(1 for item in job_results if item.get("overallStatus") != "success"),
        "moduleReplayFailedJobs": module_replay_failed_jobs,
        "aggregateBuildFailedJobs": aggregate_failed_jobs,
        "compileSucceededJobs": compile_succeeded_jobs,
        "compileFailedJobs": compile_failed_jobs,
        "preflightRejectedJobs": preflight_rejected_jobs,
        "baselineComparedJobs": baseline_compared_jobs,
        "baselineChangedJobs": baseline_changed_jobs,
        "failureClusterCount": len(compile_clusters),
        "failureClusters": compile_clusters,
        "moduleReplay": {
            key: value
            for key, value in module_replay_report.items()
            if key != "results"
        },
        "warnings": list(module_replay_report.get("warnings") or []),
        "results": job_results,
    }


def print_summary(report: dict[str, Any], args: argparse.Namespace) -> None:
    if args.quiet:
        return

    print("=== aggregate replay summary ===")
    print(
        "jobs: "
        f"{report['successfulJobs']} success / {report['failedJobs']} failed / {report['aggregateJobCount']} total"
    )
    print(
        "stages: "
        f"module replay failed {report['moduleReplayFailedJobs']}, "
        f"aggregate build failed {report['aggregateBuildFailedJobs']}, "
        f"compile failed {report['compileFailedJobs']}, "
        f"preflight rejected {report['preflightRejectedJobs']}"
    )
    print(f"output root: {report['outputRoot']}")
    print(f"report: {report['reportPath']}")
    print(
        "baseline compare: "
        f"{report['baselineComparedJobs']} compared / {report['baselineChangedJobs']} changed"
    )

    warnings = report.get("warnings") or []
    if warnings:
        print(f"warnings: {len(warnings)}")
        for item in warnings[:5]:
            print(f"  - {item['message']}")

    failures = [item for item in report.get("results") or [] if item.get("overallStatus") != "success"]
    if failures:
        print("failed aggregates:")
        for item in failures[:5]:
            print(
                "  - "
                f"{Path(item['replacementDir']).name}: stage={item.get('failureStage')} error={item.get('errorSummary')}"
            )

    changed_baselines = [
        item for item in report.get("results") or []
        if (item.get("aggregate") or {}).get("baselineComparison", {}).get("changed") is True
    ]
    if changed_baselines:
        print("changed aggregate sources:")
        for item in changed_baselines[:5]:
            comparison = (item.get("aggregate") or {}).get("baselineComparison") or {}
            print(
                "  - "
                f"{Path(item['replacementDir']).name}: lineChanges={comparison.get('lineChanges')}"
            )


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if shutil.which("swiftc") is None:
        print("error: cannot find swiftc in PATH", file=sys.stderr)
        return 2
    if args.compile_backend == "xcrun" and shutil.which("xcrun") is None:
        print("error: cannot find xcrun in PATH", file=sys.stderr)
        return 2
    if args.compile_backend == "mtl-device":
        unsupported_metal_args = [
            arg for arg in args.metal_args
            if arg not in replay_runner.EXPLICIT_FAST_MATH_METAL_ARGS
        ]
        if unsupported_metal_args:
            joined = ", ".join(unsupported_metal_args)
            print(
                "error: `--compile-backend mtl-device` only supports explicit fast-math overrides in `--metal-arg`: "
                f"{joined}",
                file=sys.stderr,
            )
            return 2

    root = repo_root()
    converter_swift = root / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
    if not converter_swift.is_file():
        print(f"error: cannot find IRToMSLConverter.swift at {converter_swift}", file=sys.stderr)
        return 2

    output_root = Path(args.output_root).expanduser().resolve() if args.output_root else default_output_root(root).resolve()
    report_path = Path(args.report_file).expanduser().resolve() if args.report_file else default_report_path(output_root)
    if args.compile_backend == "mtl-device":
        try:
            args.aggregate_compile_harness_binary = str(build_aggregate_compile_harness_binary(root, output_root))
        except subprocess.CalledProcessError as exc:
            detail = "\n".join(part for part in [exc.stdout.strip(), exc.stderr.strip()] if part) or str(exc)
            print(f"error: failed to build aggregate compile harness: {detail}", file=sys.stderr)
            return 2
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    warnings: list[replay_runner.DiscoveryWarning] = []

    jobs = discover_jobs(args, output_root, warnings)
    if not jobs:
        print("error: no aggregate replacement jobs discovered", file=sys.stderr)
        return 1

    module_results_by_job_id, module_replay_report = run_module_replays(jobs, converter_swift, output_root, warnings)

    ordered_module_replay_results = list(module_replay_report.get("results") or [])
    replay_result_index = 0
    job_results: list[dict[str, Any]] = []
    for job in jobs:
        module_results = ordered_module_replay_results[replay_result_index: replay_result_index + len(job.modules)]
        replay_result_index += len(job.modules)
        if len(module_results) != len(job.modules):
            print(
                f"error: aggregate module replay result count mismatch for {job.replacement_dir}",
                file=sys.stderr,
            )
            return 1
        job_results.append(build_job_result(job, module_results, args))

    report = build_report(jobs, module_replay_report, job_results, output_root, report_path, args)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print_summary(report, args)

    if report["failedJobs"] and not args.allow_failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
