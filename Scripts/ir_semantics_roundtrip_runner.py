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


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_output_root(root: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return root / "build" / "semantics-validation" / "roundtrip" / timestamp


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


def make_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    if args.report_file:
        return Path(args.report_file).expanduser().resolve()
    return (output_root / "roundtrip-summary.json").resolve()


def make_replay_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    if args.replay_report_file:
        return Path(args.replay_report_file).expanduser().resolve()
    return (output_root / "replay-summary.json").resolve()


def make_compile_report_path(args: argparse.Namespace, output_root: Path) -> Path:
    if args.compile_report_file:
        return Path(args.compile_report_file).expanduser().resolve()
    return (output_root / "compile-summary.json").resolve()


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


def print_summary(report: dict[str, Any], args: argparse.Namespace) -> None:
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
    print(f"report: {report['reportPath']}")

    llvm_disassembler = report.get("llvmDisassembler") or {}
    if llvm_disassembler.get("resolvedPath"):
        print(f"llvm-dis: {llvm_disassembler['resolvedPath']}")
    else:
        print("llvm-dis: NOT FOUND")

    failures = [item for item in report.get("results") or [] if item.get("failureStage")]
    if failures:
        print("failed samples:")
        for item in failures[:5]:
            key = item.get("moduleKey") or Path(item.get("inputPath") or "job").stem
            print(f"  - {key}: stage={item['failureStage']} error={item.get('errorSummary')}")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    setattr(args, "output_file", None)

    if shutil.which("swiftc") is None:
        print("error: cannot find swiftc in PATH", file=sys.stderr)
        return 2
    if shutil.which("xcrun") is None:
        print("error: cannot find xcrun in PATH", file=sys.stderr)
        return 2

    root = repo_root()
    converter_swift = root / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
    if not converter_swift.is_file():
        print(f"error: cannot find IRToMSLConverter.swift at {converter_swift}", file=sys.stderr)
        return 2

    output_root = Path(args.output_root).expanduser().resolve() if args.output_root else default_output_root(root).resolve()
    report_path = make_report_path(args, output_root)
    replay_report_path = make_replay_report_path(args, output_root)
    compile_report_path = make_compile_report_path(args, output_root)

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

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(roundtrip_report, indent=2, ensure_ascii=False), encoding="utf-8")
    print_summary(roundtrip_report, args)

    if roundtrip_report["roundTripFailedJobs"] and not args.allow_failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
