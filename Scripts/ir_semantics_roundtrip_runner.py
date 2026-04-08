#!/usr/bin/env python3
"""
ir_semantics_roundtrip_runner.py — 建立离线 IR -> MSL -> AIR -> IR round-trip 验证链路。

目标：
- 复用 `corpus_replay_runner.py` 的 IR -> MSL replay 能力
- 对生成的 `.metal` 继续执行 `xcrun metal -c`
- 对成功生成的 `.air` 使用 `llvm-dis` 反汇编成 `regenerated.ll`
- 输出结构化 JSON 报告，明确 replay / compile / llvm-dis 三段状态

示例：
    python3 Scripts/ir_semantics_roundtrip_runner.py \
        --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll

    python3 Scripts/ir_semantics_roundtrip_runner.py \
        --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
        --output-root build/semantics-validation/roundtrip/manual-probe

    python3 Scripts/ir_semantics_roundtrip_runner.py \
        --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus \
        --bundle-id com.miHoYo.Yuanshen \
        --limit 10 \
        --allow-failures

    python3 Scripts/ir_semantics_roundtrip_runner.py \
        --preset test-data-representatives \
        --allow-failures

    python3 Scripts/ir_semantics_roundtrip_runner.py \
        --preset daily-default \
        --allow-failures
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import corpus_replay_runner as replay_runner
import ir_canonical_compare as canonical_compare


TEST_DATA_RELATIVE_DIR = Path("LocalDocs") / "XCodeReleaseShaderDebug" / "RoadE-HookMakeLibraryWithSrc" / "test-data"
TEST_DATA_REPRESENTATIVE_FILES = [
    "test_fast_math_binary.ll",
    "test_scalar_select_vector.ll",
    "test_casts.ll",
    "test_fast_math_select.ll",
    "test_int_literal_half_suffix.ll",
    "test_intrinsic_vector_icmp_zext.ll",
    "test_vector_select_global_gep.ll",
    "test_struct_array_field.ll",
]
LOCAL_SHADERCORPUS_DEFAULT_ROOT = Path.home() / "Library/Containers/io.playcover.PlayCover/ShaderCorpus"
LOCAL_SHADERCORPUS_REPRESENTATIVES = [
    {
        "bundleId": "com.miHoYo.Yuanshen",
        "moduleKey": "db41fcfc1517b115d274f867634e00d08301415d450ca94eb04ca95638e41933",
    },
    {
        "bundleId": "com.papegames.lysk",
        "moduleKey": "6c08f93015cda305e6c675457bab3acfcf7febab294577d27cbe76317e2b1f45",
    },
    {
        "bundleId": "com.papegames.lysk",
        "moduleKey": "2646854687f12045e370b300deefca49e5c1bcd0a22b8755cd4af656bced5348",
    },
    {
        "bundleId": "com.papegames.lysk",
        "moduleKey": "ec0c6f0e72d6fc64daf4d5955cd1ea2cc5e729b0f988b1e857d13bfb54c7f6c3",
    },
    {
        "bundleId": "com.tencent.tmgp.speedmobile",
        "moduleKey": "1f5e65cd9f685b3673dd6fac9b81e3af82b5a6d436f8f1824919726483c967ad",
    },
]


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_output_root(root: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return root / "build" / "semantics-validation" / "roundtrip" / timestamp


def semantics_output_root(root: Path, name: str) -> Path:
    return root / "build" / "semantics-validation" / "roundtrip" / name


def test_data_root(root: Path) -> Path:
    return root / TEST_DATA_RELATIVE_DIR


def dedupe_preserving_order(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def make_test_data_paths(root: Path, file_names: list[str]) -> list[str]:
    directory = test_data_root(root)
    return [str((directory / file_name).resolve()) for file_name in file_names]


def build_roundtrip_presets(root: Path) -> dict[str, dict[str, Any]]:
    test_data_directory = test_data_root(root)
    test_data_batch_inputs = [str(path.resolve()) for path in sorted(test_data_directory.glob("*.ll"))]
    representative_inputs = make_test_data_paths(root, TEST_DATA_REPRESENTATIVE_FILES)
    local_bundle_ids = dedupe_preserving_order(
        [item["bundleId"] for item in LOCAL_SHADERCORPUS_REPRESENTATIVES]
    )
    local_module_keys = [item["moduleKey"] for item in LOCAL_SHADERCORPUS_REPRESENTATIVES]
    local_corpus_root = str(LOCAL_SHADERCORPUS_DEFAULT_ROOT)

    return {
        "test-data-representatives": {
            "description": "固定 8 个 test-data 代表样本（L0/L1/L2 代表 + compile blocker）。",
            "ll_inputs": representative_inputs,
            "suggested_output_root": str(semantics_output_root(root, "test-data-representatives")),
        },
        "test-data-batch": {
            "description": "对 Road E/test-data 下全部 .ll 样本执行批量 round-trip。",
            "ll_inputs": test_data_batch_inputs,
            "suggested_output_root": str(semantics_output_root(root, "test-data-batch")),
        },
        "local-corpus-representatives": {
            "description": "复用当前机器已存在的本地 ShaderCorpus 代表样本（缺样本时自动降级为 warning）。",
            "corpus_roots": [local_corpus_root],
            "bundle_ids": local_bundle_ids,
            "module_keys": local_module_keys,
            "suggested_output_root": str(semantics_output_root(root, "local-corpus-representatives")),
        },
        "daily-default": {
            "description": "默认日常 gate：test-data 代表集 + 本地 ShaderCorpus 代表集。",
            "ll_inputs": representative_inputs,
            "corpus_roots": [local_corpus_root],
            "bundle_ids": local_bundle_ids,
            "module_keys": local_module_keys,
            "suggested_output_root": str(semantics_output_root(root, "daily-default")),
        },
    }


def print_available_presets(root: Path) -> None:
    presets = build_roundtrip_presets(root)
    print("Available semantics round-trip presets:")
    for name, preset in presets.items():
        print(f"- {name}")
        print(f"  description: {preset['description']}")
        print(f"  suggested output root: {preset['suggested_output_root']}")


def apply_roundtrip_preset(args: argparse.Namespace, root: Path) -> None:
    if not args.preset:
        return

    presets = build_roundtrip_presets(root)
    preset = presets.get(args.preset)
    if preset is None:
        available = ", ".join(sorted(presets))
        raise SystemExit(f"unknown preset: {args.preset}; available presets: {available}")

    args.ll_inputs = dedupe_preserving_order(list(args.ll_inputs) + list(preset.get("ll_inputs") or []))
    args.corpus_roots = dedupe_preserving_order(list(args.corpus_roots) + list(preset.get("corpus_roots") or []))
    args.bundle_id = dedupe_preserving_order(list(args.bundle_id) + list(preset.get("bundle_ids") or []))
    args.module_key = dedupe_preserving_order(list(args.module_key) + list(preset.get("module_keys") or []))
    if not args.output_root:
        args.output_root = preset.get("suggested_output_root")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="执行离线 IR -> MSL -> AIR -> IR round-trip 验证")
    parser.add_argument(
        "--corpus-root",
        action="append",
        dest="corpus_roots",
        default=[],
        help="ShaderCorpus 根目录，或单个 bundle 目录（可重复指定）",
    )
    parser.add_argument(
        "--ll",
        action="append",
        dest="ll_inputs",
        default=[],
        help="显式指定一个 .ll 输入（可重复指定）",
    )
    parser.add_argument(
        "--preset",
        help="使用固定样本集预设：test-data-representatives / test-data-batch / local-corpus-representatives / daily-default",
    )
    parser.add_argument(
        "--list-presets",
        action="store_true",
        help="列出所有内建 preset 及其建议输出目录，然后退出",
    )
    parser.add_argument(
        "--bundle-id",
        action="append",
        default=[],
        help="仅处理指定 bundleId（可重复指定，主要用于 corpus 模式）",
    )
    parser.add_argument(
        "--module-key",
        action="append",
        default=[],
        help="仅处理指定 moduleKey（可重复指定，主要用于 corpus 模式）",
    )
    parser.add_argument("--limit", type=int, help="最多处理多少个样本")
    parser.add_argument(
        "--output-root",
        help="批量输出根目录；默认写入 build/semantics-validation/roundtrip/<timestamp>/",
    )
    parser.add_argument(
        "--report-file",
        help="round-trip JSON 报告输出路径；默认写到 output-root/roundtrip-summary.json",
    )
    parser.add_argument(
        "--replay-report-file",
        help="中间 replay 报告输出路径；默认写到 output-root/replay-summary.json",
    )
    parser.add_argument(
        "--compile-report-file",
        help="中间 compile 报告输出路径；默认写到 output-root/compile-summary.json",
    )
    parser.add_argument(
        "--compare-report-file",
        help="canonical compare 报告输出路径；默认写到 output-root/compare-summary.json",
    )
    parser.add_argument(
        "--risk-report-file",
        help="风险分级报告输出路径；默认写到 output-root/risk-report.json",
    )
    parser.add_argument(
        "--high-risk-file",
        help="高风险样本列表输出路径；默认写到 output-root/high-risk-samples.json",
    )
    parser.add_argument(
        "--allow-failures",
        action="store_true",
        help="即使存在 replay / compile / llvm-dis 失败也返回 0，便于先收集批量报告",
    )
    parser.add_argument(
        "--metal-sdk",
        default="macosx",
        help="`xcrun --sdk` 使用的 SDK 名称，默认 macosx",
    )
    parser.add_argument(
        "--metal-arg",
        action="append",
        dest="metal_args",
        default=[],
        help="额外透传给 `xcrun metal` 的参数（可重复指定）",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="即使检测到明显的 LLVM token 泄漏，也继续尝试执行 Metal 编译",
    )
    parser.add_argument(
        "--llvm-dis",
        help="显式指定 llvm-dis 路径；默认优先使用 PlayCover 容器内已安装工具，再尝试 PATH / Homebrew / 系统路径",
    )
    parser.add_argument(
        "--llvm-dis-timeout",
        type=int,
        default=30,
        help="单个 llvm-dis 任务超时时间（秒），默认 30",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="仅写文件，不打印人类可读摘要",
    )
    return parser


def _make_optional_report_path(explicit_path: str | None, output_root: Path, file_name: str) -> Path:
    if explicit_path:
        return Path(explicit_path).expanduser().resolve()
    return (output_root / file_name).resolve()


def make_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.report_file, output_root, "roundtrip-summary.json")


def make_replay_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.replay_report_file, output_root, "replay-summary.json")


def make_compile_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.compile_report_file, output_root, "compile-summary.json")


def make_compare_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.compare_report_file, output_root, "compare-summary.json")


def make_risk_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.risk_report_file, output_root, "risk-report.json")


def make_high_risk_path(args: argparse.Namespace, output_root: Path) -> Path:
    return _make_optional_report_path(args.high_risk_file, output_root, "high-risk-samples.json")


def candidate_llvm_dis_paths(explicit_path: str | None = None) -> list[Path]:
    candidates: list[Path] = []
    seen: set[str] = set()

    def append_candidate(raw_path: str | Path | None) -> None:
        if not raw_path:
            return
        path = Path(raw_path).expanduser().resolve()
        key = str(path)
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    append_candidate(explicit_path)
    append_candidate(Path.home() / "Library/Containers/io.playcover.PlayCover/llvm-tools/llvm-dis")

    which_path = shutil.which("llvm-dis")
    append_candidate(which_path)
    append_candidate("/opt/homebrew/bin/llvm-dis")
    append_candidate("/usr/local/bin/llvm-dis")
    append_candidate("/usr/bin/llvm-dis")
    return candidates


def resolve_llvm_dis_path(explicit_path: str | None = None, candidates: list[Path] | None = None) -> tuple[Path | None, list[Path]]:
    ordered_candidates = candidates or candidate_llvm_dis_paths(explicit_path)
    for candidate in ordered_candidates:
        if candidate.is_file() and os_access_executable(candidate):
            return candidate, ordered_candidates
    return None, ordered_candidates


def os_access_executable(path: Path) -> bool:
    return os.access(path, os.X_OK)


def make_manual_output_dir(output_root: Path, job_id: int, input_path: Path) -> Path:
    label = f"{job_id:03d}-{replay_runner.sanitize_path_component(input_path.stem)}"
    return (output_root / "manual" / label).resolve()


def make_corpus_output_dir(output_root: Path, bundle_id: str, module_key: str) -> Path:
    return (
        output_root
        / replay_runner.sanitize_path_component(bundle_id)
        / "modules"
        / replay_runner.sanitize_path_component(module_key)
    ).resolve()


def prepare_roundtrip_jobs(jobs: list[replay_runner.ReplayJob], output_root: Path) -> None:
    for job in jobs:
        if job.bundle_id and job.module_key:
            output_dir = make_corpus_output_dir(output_root, job.bundle_id, job.module_key)
        else:
            output_dir = make_manual_output_dir(output_root, job.job_id, job.input_path)

        output_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(job.input_path, output_dir / "original.ll")
        job.output_path = (output_dir / "generated.metal").resolve()


def original_ir_output_path(result: dict[str, Any]) -> Path:
    return Path(result["outputPath"]).resolve().with_name("original.ll")


def regenerated_ir_output_path(air_path: Path) -> Path:
    return air_path.with_name("regenerated.ll")


def summarize_failure(stage_result: dict[str, Any] | None) -> str | None:
    if not stage_result:
        return None
    error = stage_result.get("error")
    if error:
        return str(error)
    primary = stage_result.get("primaryDiagnostic")
    if isinstance(primary, dict) and primary.get("message"):
        return str(primary["message"])
    cluster_title = stage_result.get("clusterTitle")
    if cluster_title:
        return str(cluster_title)
    status = stage_result.get("status")
    if status and status != "success":
        return str(status)
    return None


def run_llvm_dis_job(
    compile_result: dict[str, Any],
    llvm_dis_path: Path | None,
    timeout_seconds: int,
) -> dict[str, Any]:
    air_path_value = compile_result.get("airPath")
    air_path = Path(air_path_value).expanduser().resolve() if air_path_value else None
    base_result = {
        "jobID": compile_result.get("jobID"),
        "bundleId": compile_result.get("bundleId"),
        "moduleKey": compile_result.get("moduleKey"),
        "inputPath": compile_result.get("inputPath"),
        "airPath": str(air_path) if air_path else None,
        "outputPath": None,
        "success": False,
        "status": "skipped_compile_failed",
        "command": None,
        "returnCode": None,
        "elapsedSeconds": None,
        "stdout": None,
        "stderr": None,
        "error": None,
        "executablePath": str(llvm_dis_path) if llvm_dis_path else None,
        "regeneratedIRBytes": None,
    }

    if compile_result.get("status") != "success":
        base_result["error"] = summarize_failure(compile_result)
        return base_result

    if llvm_dis_path is None:
        base_result["status"] = "llvm_dis_unavailable"
        base_result["error"] = "llvm-dis executable not found"
        return base_result

    if air_path is None:
        base_result["status"] = "compile_output_missing"
        base_result["error"] = "compile result did not include airPath"
        return base_result

    if not air_path.is_file():
        base_result["status"] = "compile_output_missing"
        base_result["error"] = f"generated AIR file is missing: {air_path}"
        return base_result

    output_path = regenerated_ir_output_path(air_path)
    if output_path.exists():
        output_path.unlink()
    base_result["outputPath"] = str(output_path)

    command = [str(llvm_dis_path), str(air_path), "-o", str(output_path)]
    base_result["command"] = replay_runner.shell_join(command)

    start_time = time.perf_counter()
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=max(1, timeout_seconds),
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.perf_counter() - start_time
        base_result["status"] = "timed_out"
        base_result["elapsedSeconds"] = round(elapsed, 6)
        base_result["stdout"] = replay_runner.truncate_text(exc.stdout)
        base_result["stderr"] = replay_runner.truncate_text(exc.stderr)
        base_result["error"] = f"llvm-dis timed out after {timeout_seconds}s"
        return base_result

    elapsed = time.perf_counter() - start_time
    base_result["returnCode"] = completed.returncode
    base_result["elapsedSeconds"] = round(elapsed, 6)
    base_result["stdout"] = replay_runner.truncate_text(completed.stdout)
    base_result["stderr"] = replay_runner.truncate_text(completed.stderr)

    if completed.returncode != 0:
        base_result["status"] = "failed"
        stderr_text = (completed.stderr or "").strip()
        stdout_text = (completed.stdout or "").strip()
        base_result["error"] = stderr_text or stdout_text or f"llvm-dis exited with status {completed.returncode}"
        return base_result

    if not output_path.is_file():
        base_result["status"] = "output_missing"
        base_result["error"] = f"llvm-dis did not produce output file at {output_path}"
        return base_result

    regenerated_text = output_path.read_text(encoding="utf-8", errors="replace")
    base_result["status"] = "success"
    base_result["success"] = True
    base_result["regeneratedIRBytes"] = len(regenerated_text.encode("utf-8"))
    return base_result


def run_llvm_dis_jobs(report: dict[str, Any], llvm_dis_path: Path | None, timeout_seconds: int) -> dict[str, Any]:
    results = [
        run_llvm_dis_job(item.get("compile") or {}, llvm_dis_path, timeout_seconds)
        for item in report.get("results", [])
    ]
    success_count = sum(1 for item in results if item["status"] == "success")
    failed_count = sum(
        1
        for item in results
        if item["status"] not in {"success", "skipped_compile_failed"}
    )
    skipped_count = sum(1 for item in results if item["status"] == "skipped_compile_failed")
    return {
        "schemaVersion": 1,
        "generatedAt": replay_runner.utc_now_iso(),
        "tool": "Scripts/ir_semantics_roundtrip_runner.py",
        "totalJobs": len(results),
        "successfulJobs": success_count,
        "failedJobs": failed_count,
        "skippedJobs": skipped_count,
        "results": results,
    }


def build_roundtrip_results(
    replay_report: dict[str, Any],
    llvm_dis_report: dict[str, Any],
) -> list[dict[str, Any]]:
    llvm_by_job = {item["jobID"]: item for item in llvm_dis_report.get("results", [])}
    merged_results: list[dict[str, Any]] = []

    for replay_result in replay_report.get("results", []):
        compile_result = replay_result.get("compile") or {}
        llvm_dis_result = llvm_by_job.get(replay_result["jobID"], {})
        replay_status = "success" if replay_result.get("success") else "failed"
        compile_status = compile_result.get("status") or "not_run"
        llvm_dis_status = llvm_dis_result.get("status") or "not_run"

        failure_stage: str | None = None
        error_summary: str | None = None
        if replay_status != "success":
            failure_stage = "replay"
            error_summary = summarize_failure(replay_result)
        elif compile_status != "success":
            failure_stage = "compile"
            error_summary = summarize_failure(compile_result)
        elif llvm_dis_status != "success":
            failure_stage = "llvm-dis"
            error_summary = summarize_failure(llvm_dis_result)

        round_trip_status = "success" if failure_stage is None else "failed"
        generated_msl_path = Path(replay_result["outputPath"]).resolve()
        generated_air_path = compile_result.get("airPath")
        regenerated_ir_path = llvm_dis_result.get("outputPath")
        merged_results.append(
            {
                "jobID": replay_result["jobID"],
                "comparisonKey": replay_result.get("comparisonKey"),
                "sourceKind": replay_result.get("sourceKind"),
                "bundleId": replay_result.get("bundleId"),
                "moduleKey": replay_result.get("moduleKey"),
                "inputPath": replay_result.get("inputPath"),
                "originalIRPath": str(original_ir_output_path(replay_result)),
                "generatedMSLPath": str(generated_msl_path),
                "generatedAIRPath": generated_air_path,
                "regeneratedIRPath": regenerated_ir_path,
                "functionNames": replay_result.get("functionNames") or [],
                "functionTypes": replay_result.get("functionTypes") or [],
                "generatedFunctionNames": replay_result.get("generatedFunctionNames") or [],
                "generatedFunctionTypes": replay_result.get("generatedFunctionTypes") or [],
                "replayStatus": replay_status,
                "compileStatus": compile_status,
                "llvmDisStatus": llvm_dis_status,
                "roundTripStatus": round_trip_status,
                "failureStage": failure_stage,
                "errorSummary": error_summary,
                "replay": {
                    "success": bool(replay_result.get("success")),
                    "error": replay_result.get("error"),
                    "elapsedSeconds": replay_result.get("elapsedSeconds"),
                    "conversionSummary": replay_result.get("conversionSummary"),
                    "mslBytes": replay_result.get("mslBytes"),
                    "stats": replay_result.get("stats"),
                },
                "compile": compile_result,
                "llvmDis": llvm_dis_result,
            }
        )

    return merged_results


def build_roundtrip_report(
    replay_report: dict[str, Any],
    compile_report: dict[str, Any],
    llvm_dis_report: dict[str, Any],
    report_path: Path,
    output_root: Path,
    llvm_dis_path: Path | None,
    llvm_dis_candidates: list[Path],
) -> dict[str, Any]:
    results = build_roundtrip_results(replay_report, llvm_dis_report)
    roundtrip_succeeded_jobs = sum(1 for item in results if item["roundTripStatus"] == "success")
    compile_failed_jobs = sum(1 for item in results if item["failureStage"] == "compile")
    llvm_dis_failed_jobs = sum(1 for item in results if item["failureStage"] == "llvm-dis")
    replay_failed_jobs = sum(1 for item in results if item["failureStage"] == "replay")

    warnings = list(replay_report.get("warnings") or [])
    if llvm_dis_path is None:
        warnings.append(
            {
                "message": "llvm-dis executable not found; all llvm-dis stages will fail unless --allow-failures is set",
            }
        )

    return {
        "schemaVersion": 1,
        "generatedAt": replay_runner.utc_now_iso(),
        "tool": "Scripts/ir_semantics_roundtrip_runner.py",
        "reportPath": str(report_path),
        "outputRoot": str(output_root),
        "replayReportPath": str(replay_report.get("reportPath") or (output_root / "replay-summary.json")),
        "compileReportPath": str(compile_report.get("reportPath") or (output_root / "compile-summary.json")),
        "converterSwift": replay_report.get("converterSwift"),
        "llvmDisassembler": {
            "resolvedPath": str(llvm_dis_path) if llvm_dis_path else None,
            "candidates": [str(path) for path in llvm_dis_candidates],
        },
        "jobCount": len(results),
        "replaySucceededJobs": int(replay_report.get("successfulJobs", 0)),
        "replayFailedJobs": replay_failed_jobs,
        "compileSucceededJobs": int(compile_report.get("compileSucceededJobs", 0)),
        "compileFailedJobs": compile_failed_jobs,
        "llvmDisSucceededJobs": int(llvm_dis_report.get("successfulJobs", 0)),
        "llvmDisFailedJobs": llvm_dis_failed_jobs,
        "roundTripSucceededJobs": roundtrip_succeeded_jobs,
        "roundTripFailedJobs": len(results) - roundtrip_succeeded_jobs,
        "warnings": warnings,
        "results": results,
    }


def build_compare_result(roundtrip_result: dict[str, Any]) -> dict[str, Any]:
    base_result = {
        "jobID": roundtrip_result.get("jobID"),
        "comparisonKey": roundtrip_result.get("comparisonKey"),
        "sourceKind": roundtrip_result.get("sourceKind"),
        "bundleId": roundtrip_result.get("bundleId"),
        "moduleKey": roundtrip_result.get("moduleKey"),
        "inputPath": roundtrip_result.get("inputPath"),
        "originalIRPath": roundtrip_result.get("originalIRPath"),
        "regeneratedIRPath": roundtrip_result.get("regeneratedIRPath"),
        "roundTripStatus": roundtrip_result.get("roundTripStatus"),
        "failureStage": roundtrip_result.get("failureStage"),
        "riskLevel": "L3",
        "riskReason": "round-trip failed before canonical compare",
        "recommendedAction": "先修复 round-trip 主链路失败点，再进行 L2 compare。",
        "differenceCount": 0,
        "differences": [],
        "compareAvailable": False,
        "entryComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "addressSpaceComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "builtinComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "cfgComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "instructionFamilyComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "fastMathComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "moduleMetadataComparison": {"same": False, "severity": "L3", "differenceCount": 0, "differences": []},
        "originalSummary": None,
        "regeneratedSummary": None,
        "compareError": None,
    }

    if roundtrip_result.get("roundTripStatus") != "success":
        base_result["riskReason"] = roundtrip_result.get("errorSummary") or base_result["riskReason"]
        return base_result

    original_ir_path = roundtrip_result.get("originalIRPath")
    regenerated_ir_path = roundtrip_result.get("regeneratedIRPath")
    if not original_ir_path or not regenerated_ir_path:
        base_result["riskReason"] = "missing original/regenerated IR path"
        return base_result

    try:
        original_summary = canonical_compare.extract_ir_summary(original_ir_path)
        regenerated_summary = canonical_compare.extract_ir_summary(regenerated_ir_path)
        comparison = canonical_compare.compare_ir_summaries(original_summary, regenerated_summary)
    except Exception as exc:
        base_result["riskReason"] = "canonical compare failed"
        base_result["recommendedAction"] = "先修复 L2 compare 解析失败，再继续推进批量回归。"
        base_result["compareError"] = str(exc)
        return base_result

    base_result.update(comparison)
    base_result["compareAvailable"] = True
    base_result["originalSummary"] = original_summary
    base_result["regeneratedSummary"] = regenerated_summary
    return base_result


def build_compare_report(roundtrip_report: dict[str, Any], compare_report_path: Path) -> dict[str, Any]:
    results = [build_compare_result(item) for item in roundtrip_report.get("results", [])]
    risk_counts: dict[str, int] = {level: 0 for level in ("L0", "L1", "L2", "L3")}
    for result in results:
        risk_counts[result["riskLevel"]] = risk_counts.get(result["riskLevel"], 0) + 1

    samples_for_l3 = [
        {
            "comparisonKey": item.get("comparisonKey"),
            "riskLevel": item.get("riskLevel"),
            "riskReason": item.get("riskReason"),
            "recommendedAction": item.get("recommendedAction"),
        }
        for item in results
        if item.get("riskLevel") == "L2"
    ]
    blocked_samples = [
        {
            "comparisonKey": item.get("comparisonKey"),
            "riskLevel": item.get("riskLevel"),
            "riskReason": item.get("riskReason"),
            "failureStage": item.get("failureStage"),
            "recommendedAction": item.get("recommendedAction"),
        }
        for item in results
        if item.get("riskLevel") == "L3"
    ]

    return {
        "schemaVersion": 1,
        "generatedAt": replay_runner.utc_now_iso(),
        "tool": "Scripts/ir_semantics_roundtrip_runner.py",
        "reportPath": str(compare_report_path),
        "roundtripReportPath": roundtrip_report.get("reportPath"),
        "outputRoot": roundtrip_report.get("outputRoot"),
        "jobCount": len(results),
        "compareAvailableJobs": sum(1 for item in results if item.get("compareAvailable")),
        "compareUnavailableJobs": sum(1 for item in results if not item.get("compareAvailable")),
        "riskCounts": risk_counts,
        "samplesForL3": samples_for_l3,
        "blockedSamples": blocked_samples,
        "results": results,
    }


def build_risk_report(compare_report: dict[str, Any], risk_report_path: Path) -> dict[str, Any]:
    samples = []
    for item in compare_report.get("results", []):
        top_differences = [
            {
                "category": diff.get("category"),
                "severity": diff.get("severity"),
                "reason": diff.get("reason"),
                "subject": diff.get("subject"),
            }
            for diff in (item.get("differences") or [])[:5]
        ]
        samples.append(
            {
                "comparisonKey": item.get("comparisonKey"),
                "bundleId": item.get("bundleId"),
                "moduleKey": item.get("moduleKey"),
                "inputPath": item.get("inputPath"),
                "roundTripStatus": item.get("roundTripStatus"),
                "failureStage": item.get("failureStage"),
                "riskLevel": item.get("riskLevel"),
                "riskReason": item.get("riskReason"),
                "recommendedAction": item.get("recommendedAction"),
                "compareAvailable": item.get("compareAvailable"),
                "shouldEnterL3": item.get("riskLevel") == "L2",
                "blockedBeforeLive": item.get("riskLevel") == "L3",
                "topDifferences": top_differences,
            }
        )

    return {
        "schemaVersion": 1,
        "generatedAt": replay_runner.utc_now_iso(),
        "tool": "Scripts/ir_semantics_roundtrip_runner.py",
        "reportPath": str(risk_report_path),
        "compareReportPath": compare_report.get("reportPath"),
        "outputRoot": compare_report.get("outputRoot"),
        "jobCount": len(samples),
        "riskCounts": compare_report.get("riskCounts") or {},
        "samplesForL3": [sample for sample in samples if sample["shouldEnterL3"]],
        "blockedSamples": [sample for sample in samples if sample["blockedBeforeLive"]],
        "samples": samples,
    }


def build_high_risk_samples(compare_report: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "comparisonKey": item.get("comparisonKey"),
            "bundleId": item.get("bundleId"),
            "moduleKey": item.get("moduleKey"),
            "inputPath": item.get("inputPath"),
            "riskLevel": item.get("riskLevel"),
            "riskReason": item.get("riskReason"),
            "recommendedAction": item.get("recommendedAction"),
            "failureStage": item.get("failureStage"),
        }
        for item in compare_report.get("results", [])
        if item.get("riskLevel") in {"L2", "L3"}
    ]


def print_summary(report: dict[str, Any], compare_report: dict[str, Any], args: argparse.Namespace) -> None:
    if args.quiet:
        return

    print("=== semantics round-trip summary ===")
    print(
        "jobs: "
        f"round-trip {report['roundTripSucceededJobs']} success / {report['roundTripFailedJobs']} failed / {report['jobCount']} total"
    )
    print(
        "stages: "
        f"replay failed {report['replayFailedJobs']}, "
        f"compile failed {report['compileFailedJobs']}, "
        f"llvm-dis failed {report['llvmDisFailedJobs']}"
    )
    print(f"output root: {report['outputRoot']}")
    print(f"roundtrip report: {report['reportPath']}")
    print(f"compare report: {compare_report['reportPath']}")

    llvm_disassembler = report.get("llvmDisassembler") or {}
    if llvm_disassembler.get("resolvedPath"):
        print(f"llvm-dis: {llvm_disassembler['resolvedPath']}")
    else:
        print("llvm-dis: NOT FOUND")

    risk_counts = compare_report.get("riskCounts") or {}
    print(
        "risk levels: "
        f"L0={risk_counts.get('L0', 0)}, "
        f"L1={risk_counts.get('L1', 0)}, "
        f"L2={risk_counts.get('L2', 0)}, "
        f"L3={risk_counts.get('L3', 0)}"
    )

    failures = [item for item in report.get("results") or [] if item.get("failureStage")]
    if failures:
        print("failed samples:")
        for item in failures[:5]:
            key = item.get("moduleKey") or Path(item.get("inputPath") or "job").stem
            print(f"  - {key}: stage={item['failureStage']} error={item.get('errorSummary')}")

    high_risks = [item for item in compare_report.get("results") or [] if item.get("riskLevel") in {"L2", "L3"}]
    if high_risks:
        print("high-risk samples:")
        for item in high_risks[:5]:
            key = item.get("moduleKey") or Path(item.get("inputPath") or "job").stem
            print(f"  - {key}: risk={item['riskLevel']} reason={item.get('riskReason')}")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    setattr(args, "output_file", None)

    root = repo_root()
    if args.list_presets:
        print_available_presets(root)
        return 0
    apply_roundtrip_preset(args, root)

    if shutil.which("swiftc") is None:
        print("error: cannot find swiftc in PATH", file=sys.stderr)
        return 2
    if shutil.which("xcrun") is None:
        print("error: cannot find xcrun in PATH", file=sys.stderr)
        return 2

    converter_swift = root / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
    if not converter_swift.is_file():
        print(f"error: cannot find IRToMSLConverter.swift at {converter_swift}", file=sys.stderr)
        return 2

    output_root = Path(args.output_root).expanduser().resolve() if args.output_root else default_output_root(root).resolve()
    report_path = make_report_path(args, output_root)
    replay_report_path = make_replay_report_path(args, output_root)
    compile_report_path = make_compile_report_path(args, output_root)
    compare_report_path = make_compare_report_path(args, output_root)
    risk_report_path = make_risk_report_path(args, output_root)
    high_risk_path = make_high_risk_path(args, output_root)

    warnings: list[replay_runner.DiscoveryWarning] = []
    jobs = replay_runner.discover_jobs(args, output_root, warnings)
    if not jobs:
        print("error: no replay jobs discovered", file=sys.stderr)
        return 1

    prepare_roundtrip_jobs(jobs, output_root)

    raw_replay_report = replay_runner.run_replay_jobs(jobs, converter_swift, replay_report_path)
    replay_report = replay_runner.enrich_report(raw_replay_report, jobs, warnings, output_root)
    replay_report["tool"] = "Scripts/ir_semantics_roundtrip_runner.py"
    replay_report["reportPath"] = str(replay_report_path)

    compile_report = replay_runner.run_compile_jobs(replay_report, args, compile_report_path)
    replay_report = replay_runner.attach_compile_report(replay_report, compile_report)
    replay_report_path.parent.mkdir(parents=True, exist_ok=True)
    replay_report_path.write_text(json.dumps(replay_report, indent=2, ensure_ascii=False), encoding="utf-8")

    llvm_dis_path, llvm_dis_candidates = resolve_llvm_dis_path(args.llvm_dis)
    llvm_dis_report = run_llvm_dis_jobs(replay_report, llvm_dis_path, args.llvm_dis_timeout)
    roundtrip_report = build_roundtrip_report(
        replay_report,
        compile_report,
        llvm_dis_report,
        report_path,
        output_root,
        llvm_dis_path,
        llvm_dis_candidates,
    )
    compare_report = build_compare_report(roundtrip_report, compare_report_path)
    risk_report = build_risk_report(compare_report, risk_report_path)
    high_risk_samples = build_high_risk_samples(compare_report)

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(roundtrip_report, indent=2, ensure_ascii=False), encoding="utf-8")
    compare_report_path.parent.mkdir(parents=True, exist_ok=True)
    compare_report_path.write_text(json.dumps(compare_report, indent=2, ensure_ascii=False), encoding="utf-8")
    risk_report_path.parent.mkdir(parents=True, exist_ok=True)
    risk_report_path.write_text(json.dumps(risk_report, indent=2, ensure_ascii=False), encoding="utf-8")
    high_risk_path.parent.mkdir(parents=True, exist_ok=True)
    high_risk_path.write_text(json.dumps(high_risk_samples, indent=2, ensure_ascii=False), encoding="utf-8")
    print_summary(roundtrip_report, compare_report, args)

    if roundtrip_report["roundTripFailedJobs"] and not args.allow_failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
