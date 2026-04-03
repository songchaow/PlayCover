#!/usr/bin/env python3
"""
corpus_replay_runner.py — 对 `ShaderCorpus/` 或显式 `.ll` 样本执行离线 IR -> MSL 回放。

目标：
- 面向 `ShaderCorpus/<bundleId>/modules/<moduleKey>/module.ll` 做批量 replay
- 从 `module.meta.json` 读取 `functionNames` / `functionTypes`，尽量贴近 runtime 主路径
- 稳定输出新的 `.metal` 文件与结构化 JSON 报告，作为 E-005a 的日常回归入口

示例：
    python3 Scripts/corpus_replay_runner.py \
        --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus \
        --bundle-id com.miHoYo.Yuanshen \
        --limit 5

    python3 Scripts/corpus_replay_runner.py \
        --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
        --output-file build/test_addrspace.generated.metal
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPLAY_HARNESS_SWIFT = r'''import Foundation

private struct ReplayBatchManifest: Decodable {
    let jobs: [ReplayJob]
}

private struct ReplayJob: Decodable {
    let jobID: Int
    let inputPath: String
    let outputPath: String
    let moduleKey: String?
    let bundleId: String?
    let functionNames: [String]
    let functionTypes: [String]
}

private struct ReplayStats: Encodable {
    let totalIRFunctions: Int
    let shaderFunctions: Int
    let fullyParsedFunctions: Int
    let stubFunctions: Int
    let airBuiltinCalls: Int
    let mappedAirCalls: Int
    let unmappedAirCalls: Int
}

private struct ReplayResult: Encodable {
    let jobID: Int
    let inputPath: String
    let outputPath: String
    let moduleKey: String?
    let bundleId: String?
    let success: Bool
    let error: String?
    let elapsedSeconds: Double?
    let conversionSummary: String?
    let mslBytes: Int?
    let generatedFunctionNames: [String]?
    let generatedFunctionTypes: [String]?
    let stats: ReplayStats?
}

private struct ReplayBatchReport: Encodable {
    let schemaVersion: Int
    let generatedAt: String
    let jobCount: Int
    let successCount: Int
    let failureCount: Int
    let results: [ReplayResult]
}

private enum RunnerError: LocalizedError {
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "missing required argument: \(name)"
        }
    }
}

private extension JSONEncoder {
    static func prettySorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@main
private struct CorpusReplayMain {
    static func main() {
        do {
            try run()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let (manifestPath, reportPath) = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let reportURL = URL(fileURLWithPath: reportPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ReplayBatchManifest.self, from: manifestData)

        var results: [ReplayResult] = []
        results.reserveCapacity(manifest.jobs.count)

        for job in manifest.jobs {
            do {
                let irText = try String(contentsOfFile: job.inputPath, encoding: .utf8)
                let conversion = try IRToMSLConverter.convert(
                    irText: irText,
                    functionNames: job.functionNames,
                    functionTypes: job.functionTypes
                )
                let outputURL = URL(fileURLWithPath: job.outputPath)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try conversion.mslSource.write(to: outputURL, atomically: true, encoding: .utf8)

                let stats = ReplayStats(
                    totalIRFunctions: conversion.stats.totalIRFunctions,
                    shaderFunctions: conversion.stats.shaderFunctions,
                    fullyParsedFunctions: conversion.stats.fullyParsedFunctions,
                    stubFunctions: conversion.stats.stubFunctions,
                    airBuiltinCalls: conversion.stats.airBuiltinCalls,
                    mappedAirCalls: conversion.stats.mappedAirCalls,
                    unmappedAirCalls: conversion.stats.unmappedAirCalls
                )
                let generatedTypes = conversion.functions.map { $0.shaderType.rawValue }
                let result = ReplayResult(
                    jobID: job.jobID,
                    inputPath: job.inputPath,
                    outputPath: job.outputPath,
                    moduleKey: job.moduleKey,
                    bundleId: job.bundleId,
                    success: true,
                    error: nil,
                    elapsedSeconds: conversion.elapsedSeconds,
                    conversionSummary: conversion.summary,
                    mslBytes: conversion.mslSource.utf8.count,
                    generatedFunctionNames: conversion.functions.map(\.name),
                    generatedFunctionTypes: generatedTypes,
                    stats: stats
                )
                results.append(result)
            } catch {
                results.append(
                    ReplayResult(
                        jobID: job.jobID,
                        inputPath: job.inputPath,
                        outputPath: job.outputPath,
                        moduleKey: job.moduleKey,
                        bundleId: job.bundleId,
                        success: false,
                        error: error.localizedDescription,
                        elapsedSeconds: nil,
                        conversionSummary: nil,
                        mslBytes: nil,
                        generatedFunctionNames: nil,
                        generatedFunctionTypes: nil,
                        stats: nil
                    )
                )
            }
        }

        let successCount = results.filter(\.success).count
        let report = ReplayBatchReport(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            jobCount: manifest.jobs.count,
            successCount: successCount,
            failureCount: manifest.jobs.count - successCount,
            results: results
        )
        let reportData = try JSONEncoder.prettySorted().encode(report)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try reportData.write(to: reportURL, options: .atomic)
    }

    private static func parseArguments(_ arguments: [String]) throws -> (String, String) {
        var manifestPath: String?
        var reportPath: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--manifest":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingArgument("--manifest") }
                manifestPath = arguments[index]
            case "--report":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingArgument("--report") }
                reportPath = arguments[index]
            default:
                break
            }
            index += 1
        }

        guard let manifestPath else { throw RunnerError.missingArgument("--manifest") }
        guard let reportPath else { throw RunnerError.missingArgument("--report") }
        return (manifestPath, reportPath)
    }
}
'''


@dataclasses.dataclass
class ReplayJob:
    job_id: int
    source_kind: str
    input_path: Path
    output_path: Path
    bundle_id: str | None = None
    module_key: str | None = None
    metadata_path: Path | None = None
    baseline_generated_msl_path: Path | None = None
    function_names: list[str] = dataclasses.field(default_factory=list)
    function_types: list[str] = dataclasses.field(default_factory=list)
    capture_count: int | None = None
    manifest_event_count: int | None = None
    observed_selectors: list[str] = dataclasses.field(default_factory=list)
    source_root: Path | None = None


@dataclasses.dataclass
class DiscoveryWarning:
    message: str


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="对 ShaderCorpus 或显式 .ll 样本执行 IR -> MSL 离线 replay")
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
        help="仅回放指定 bundleId（可重复指定，主要用于 corpus 模式）",
    )
    parser.add_argument(
        "--module-key",
        action="append",
        default=[],
        help="仅回放指定 moduleKey（可重复指定，主要用于 corpus 模式）",
    )
    parser.add_argument("--limit", type=int, help="最多处理多少个样本")
    parser.add_argument(
        "--output-root",
        help="批量输出根目录；默认写入 build/shader-corpus-replay/<timestamp>/",
    )
    parser.add_argument(
        "--output-file",
        help="仅在单个 --ll 输入时生效，直接把生成的 .metal 写到这个路径",
    )
    parser.add_argument(
        "--report-file",
        help="JSON 报告输出路径；默认写到 output-root 下，或单文件输出旁边",
    )
    parser.add_argument(
        "--allow-failures",
        action="store_true",
        help="即使存在 replay 失败也返回 0，便于先收集报告",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="仅写文件，不打印人类可读摘要",
    )
    return parser


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_corpus_root() -> Path | None:
    candidate = Path.home() / "Library/Containers/io.playcover.PlayCover/ShaderCorpus"
    return candidate if candidate.is_dir() else None


def default_output_root(root: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return root / "build" / "shader-corpus-replay" / timestamp


def warn(warnings: list[DiscoveryWarning], message: str) -> None:
    warnings.append(DiscoveryWarning(message=message))


def load_json(path: Path, warnings: list[DiscoveryWarning]) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        warn(warnings, f"missing JSON file: {path}")
    except json.JSONDecodeError as exc:
        warn(warnings, f"invalid JSON in {path}: {exc}")
    return None


def is_bundle_root(path: Path) -> bool:
    return path.is_dir() and (path / "modules").is_dir()


def resolve_bundle_roots(corpus_root: Path) -> list[Path]:
    if is_bundle_root(corpus_root):
        return [corpus_root]
    if not corpus_root.is_dir():
        return []
    return sorted(child for child in corpus_root.iterdir() if is_bundle_root(child))


def load_manifest_index(bundle_root: Path, warnings: list[DiscoveryWarning]) -> tuple[list[str], dict[str, dict[str, Any]]]:
    manifest_path = bundle_root / "manifest.jsonl"
    if not manifest_path.is_file():
        return [], {}

    order: list[str] = []
    by_module: dict[str, dict[str, Any]] = {}
    for line_number, raw_line in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as exc:
            warn(warnings, f"invalid JSONL line {line_number} in {manifest_path}: {exc}")
            continue

        module_key = entry.get("moduleKey")
        if not module_key:
            continue
        if module_key not in by_module:
            order.append(module_key)
            by_module[module_key] = {
                "bundleId": entry.get("bundleId"),
                "eventCount": 0,
                "metadataPath": entry.get("metadataPath"),
                "selectors": [],
            }

        info = by_module[module_key]
        info["eventCount"] += 1
        if not info.get("metadataPath") and entry.get("metadataPath"):
            info["metadataPath"] = entry.get("metadataPath")
        selector = entry.get("selector")
        if selector and selector not in info["selectors"]:
            info["selectors"].append(selector)
    return order, by_module


def make_report_path(args: argparse.Namespace, computed_output_root: Path | None) -> Path:
    if args.report_file:
        return Path(args.report_file).expanduser().resolve()

    if args.output_file and len(args.ll_inputs) == 1:
        output_file = Path(args.output_file).expanduser().resolve()
        if output_file.suffix:
            return output_file.with_name(f"{output_file.stem}.replay.json")
        return output_file.parent / f"{output_file.name}.replay.json"

    if computed_output_root is None:
        raise ValueError("computed_output_root must not be None when report file is not explicitly set")
    return (computed_output_root / "replay-summary.json").resolve()


def same_file_contents(left: Path, right: Path) -> bool | None:
    if not left.is_file() or not right.is_file():
        return None

    left_bytes = left.read_bytes()
    right_bytes = right.read_bytes()
    if left_bytes == right_bytes:
        return True

    try:
        left_text = left_bytes.decode("utf-8")
        right_text = right_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return False

    def normalize_generated_msl(text: str) -> str:
        lines = []
        for line in text.splitlines():
            if line.startswith("// Generated at:"):
                continue
            lines.append(line.rstrip())
        return "\n".join(lines).strip()

    return normalize_generated_msl(left_text) == normalize_generated_msl(right_text)


def build_runner_binary(temp_dir: Path, converter_swift: Path) -> Path:
    harness_path = temp_dir / "CorpusReplayMain.swift"
    binary_path = temp_dir / "corpus_replay_runner"
    harness_path.write_text(REPLAY_HARNESS_SWIFT, encoding="utf-8")

    command = ["swiftc", str(converter_swift), str(harness_path), "-o", str(binary_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    return binary_path


def discover_jobs(
    args: argparse.Namespace,
    computed_output_root: Path | None,
    warnings: list[DiscoveryWarning],
) -> list[ReplayJob]:
    jobs: list[ReplayJob] = []
    bundle_filters = set(args.bundle_id)
    module_filters = set(args.module_key)
    next_job_id = 0

    def enqueue(job: ReplayJob) -> None:
        nonlocal next_job_id
        job.job_id = next_job_id
        next_job_id += 1
        jobs.append(job)

    if args.ll_inputs:
        if args.output_file and len(args.ll_inputs) != 1:
            raise SystemExit("--output-file 只能和单个 --ll 输入一起使用")
        if computed_output_root is None and not args.output_file:
            raise SystemExit("显式 .ll 模式在未指定 --output-file 时需要 output_root")

        for index, ll_input in enumerate(args.ll_inputs):
            input_path = Path(ll_input).expanduser().resolve()
            if not input_path.is_file():
                raise SystemExit(f"IR 文件不存在: {input_path}")

            sibling_meta_path = input_path.parent / "module.meta.json"
            metadata: dict[str, Any] | None = None
            baseline_path: Path | None = None
            if sibling_meta_path.is_file():
                metadata = load_json(sibling_meta_path, warnings)
                if metadata:
                    artifact_paths = metadata.get("artifactPaths") or {}
                    generated_rel = artifact_paths.get("generatedMSLPath")
                    if generated_rel:
                        candidates = []
                        if sibling_meta_path.parent.parent.name == "modules":
                            candidates.append((sibling_meta_path.parent.parent.parent / generated_rel).resolve())
                        candidates.append((sibling_meta_path.parent / generated_rel).resolve())
                        baseline_path = next((path for path in candidates if path.is_file()), None)
                    else:
                        fallback = sibling_meta_path.parent / "module.generated.metal"
                        baseline_path = fallback.resolve() if fallback.exists() else None

            if args.output_file:
                output_path = Path(args.output_file).expanduser().resolve()
            else:
                assert computed_output_root is not None
                output_path = (computed_output_root / "manual" / f"{index:03d}-{input_path.stem}.generated.metal").resolve()

            enqueue(
                ReplayJob(
                    job_id=-1,
                    source_kind="explicit_ll",
                    input_path=input_path,
                    output_path=output_path,
                    bundle_id=(metadata or {}).get("bundleId"),
                    module_key=(metadata or {}).get("moduleKey") or (input_path.parent.name if input_path.name == "module.ll" else None),
                    metadata_path=sibling_meta_path.resolve() if sibling_meta_path.is_file() else None,
                    baseline_generated_msl_path=baseline_path,
                    function_names=list((metadata or {}).get("functionNames") or []),
                    function_types=list((metadata or {}).get("functionTypes") or []),
                    capture_count=(metadata or {}).get("captureCount"),
                    observed_selectors=list((metadata or {}).get("observedSelectors") or []),
                    source_root=input_path.parent,
                )
            )

    corpus_roots = [Path(raw).expanduser().resolve() for raw in args.corpus_roots]
    if not corpus_roots and not args.ll_inputs:
        default_root = default_corpus_root()
        if default_root is not None:
            corpus_roots = [default_root.resolve()]

    for corpus_root in corpus_roots:
        bundle_roots = resolve_bundle_roots(corpus_root)
        if not bundle_roots:
            warn(warnings, f"no bundle roots found under corpus root: {corpus_root}")
            continue

        for bundle_root in bundle_roots:
            manifest_order, manifest_info = load_manifest_index(bundle_root, warnings)
            discovered_keys: set[str] = set()

            def maybe_enqueue_from_meta(meta_path: Path, manifest_record: dict[str, Any] | None = None) -> None:
                if not meta_path.is_file():
                    warn(warnings, f"missing module manifest: {meta_path}")
                    return
                metadata = load_json(meta_path, warnings)
                if not metadata:
                    return

                bundle_id = metadata.get("bundleId") or (manifest_record or {}).get("bundleId") or bundle_root.name
                module_key = metadata.get("moduleKey") or meta_path.parent.name
                if bundle_filters and bundle_id not in bundle_filters:
                    return
                if module_filters and module_key not in module_filters:
                    return
                if module_key in discovered_keys:
                    return

                artifact_paths = metadata.get("artifactPaths") or {}
                llvm_ir_rel = artifact_paths.get("llvmIRPath") or f"modules/{module_key}/module.ll"
                input_path = (bundle_root / llvm_ir_rel).resolve()
                if not input_path.is_file():
                    warn(warnings, f"missing LLVM IR file for {module_key}: {input_path}")
                    return

                generated_rel = artifact_paths.get("generatedMSLPath")
                baseline_path: Path | None = None
                if generated_rel:
                    candidate = (bundle_root / generated_rel).resolve()
                    if candidate.is_file():
                        baseline_path = candidate
                else:
                    fallback = meta_path.parent / "module.generated.metal"
                    if fallback.is_file():
                        baseline_path = fallback.resolve()

                if computed_output_root is None:
                    raise SystemExit("corpus 模式需要 output_root")
                output_path = (computed_output_root / bundle_id / "modules" / module_key / "replayed.generated.metal").resolve()

                discovered_keys.add(module_key)
                enqueue(
                    ReplayJob(
                        job_id=-1,
                        source_kind="shader_corpus",
                        input_path=input_path,
                        output_path=output_path,
                        bundle_id=bundle_id,
                        module_key=module_key,
                        metadata_path=meta_path.resolve(),
                        baseline_generated_msl_path=baseline_path,
                        function_names=list(metadata.get("functionNames") or []),
                        function_types=list(metadata.get("functionTypes") or []),
                        capture_count=metadata.get("captureCount"),
                        manifest_event_count=(manifest_record or {}).get("eventCount"),
                        observed_selectors=list(metadata.get("observedSelectors") or (manifest_record or {}).get("selectors") or []),
                        source_root=bundle_root,
                    )
                )

            for module_key in manifest_order:
                record = manifest_info.get(module_key) or {}
                relative_meta = record.get("metadataPath") or f"modules/{module_key}/module.meta.json"
                maybe_enqueue_from_meta((bundle_root / relative_meta).resolve(), record)

            modules_dir = bundle_root / "modules"
            if modules_dir.is_dir():
                for module_dir in sorted(child for child in modules_dir.iterdir() if child.is_dir()):
                    module_key = module_dir.name
                    if module_key in discovered_keys:
                        continue
                    if module_filters and module_key not in module_filters:
                        continue
                    maybe_enqueue_from_meta((module_dir / "module.meta.json").resolve(), manifest_info.get(module_key))

    if args.limit is not None:
        jobs = jobs[: args.limit]
    return jobs


def run_replay_jobs(
    jobs: list[ReplayJob],
    converter_swift: Path,
    report_path: Path,
) -> dict[str, Any]:
    report_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="playcover-corpus-replay.") as temp_dir_raw:
        temp_dir = Path(temp_dir_raw)
        runner_binary = build_runner_binary(temp_dir, converter_swift)
        raw_manifest_path = temp_dir / "replay-input.json"
        raw_report_path = temp_dir / "replay-output.json"

        raw_manifest = {
            "jobs": [
                {
                    "jobID": job.job_id,
                    "inputPath": str(job.input_path),
                    "outputPath": str(job.output_path),
                    "moduleKey": job.module_key,
                    "bundleId": job.bundle_id,
                    "functionNames": job.function_names,
                    "functionTypes": job.function_types,
                }
                for job in jobs
            ]
        }
        raw_manifest_path.write_text(json.dumps(raw_manifest, indent=2, ensure_ascii=False), encoding="utf-8")

        subprocess.run(
            [str(runner_binary), "--manifest", str(raw_manifest_path), "--report", str(raw_report_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(raw_report_path.read_text(encoding="utf-8"))


def enrich_report(
    raw_report: dict[str, Any],
    jobs: list[ReplayJob],
    warnings: list[DiscoveryWarning],
    output_root: Path | None,
) -> dict[str, Any]:
    by_job_id = {job.job_id: job for job in jobs}
    raw_results = {result["jobID"]: result for result in raw_report.get("results", [])}

    enriched_results: list[dict[str, Any]] = []
    success_count = 0
    failure_count = 0
    for job in jobs:
        result = dict(raw_results.get(job.job_id, {}))
        success = bool(result.get("success"))
        if success:
            success_count += 1
        else:
            failure_count += 1

        baseline_match: bool | None = None
        if success and job.baseline_generated_msl_path:
            baseline_match = same_file_contents(job.output_path, job.baseline_generated_msl_path)

        enriched_results.append(
            {
                "jobID": job.job_id,
                "sourceKind": job.source_kind,
                "bundleId": job.bundle_id,
                "moduleKey": job.module_key,
                "inputPath": str(job.input_path),
                "outputPath": str(job.output_path),
                "metadataPath": str(job.metadata_path) if job.metadata_path else None,
                "baselineGeneratedMSLPath": str(job.baseline_generated_msl_path) if job.baseline_generated_msl_path else None,
                "baselineMatchesGeneratedMSL": baseline_match,
                "functionNames": job.function_names,
                "functionTypes": job.function_types,
                "captureCount": job.capture_count,
                "manifestEventCount": job.manifest_event_count,
                "observedSelectors": job.observed_selectors,
                "success": success,
                "error": result.get("error"),
                "elapsedSeconds": result.get("elapsedSeconds"),
                "conversionSummary": result.get("conversionSummary"),
                "mslBytes": result.get("mslBytes"),
                "generatedFunctionNames": result.get("generatedFunctionNames"),
                "generatedFunctionTypes": result.get("generatedFunctionTypes"),
                "stats": result.get("stats"),
            }
        )

    return {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "tool": "Scripts/corpus_replay_runner.py",
        "converterSwift": str(repo_root() / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"),
        "outputRoot": str(output_root) if output_root else None,
        "totalJobs": len(jobs),
        "successfulJobs": success_count,
        "failedJobs": failure_count,
        "warnings": [dataclasses.asdict(item) for item in warnings],
        "results": enriched_results,
    }


def print_summary(report: dict[str, Any], report_path: Path, args: argparse.Namespace) -> None:
    if args.quiet:
        return

    print("=== corpus replay summary ===")
    print(f"jobs: {report['successfulJobs']} success / {report['failedJobs']} failed / {report['totalJobs']} total")
    if report.get("outputRoot"):
        print(f"output root: {report['outputRoot']}")
    print(f"report: {report_path}")

    warning_count = len(report.get("warnings") or [])
    if warning_count:
        print(f"warnings: {warning_count}")
        for item in (report.get("warnings") or [])[:5]:
            print(f"  - {item['message']}")

    failures = [item for item in report.get("results") or [] if not item.get("success")]
    if failures:
        print("failed samples:")
        for item in failures[:5]:
            key = item.get("moduleKey") or Path(item["inputPath"]).stem
            print(f"  - {key}: {item.get('error')}")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if shutil.which("swiftc") is None:
        print("error: cannot find swiftc in PATH", file=sys.stderr)
        return 2

    root = repo_root()
    converter_swift = root / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
    if not converter_swift.is_file():
        print(f"error: cannot find IRToMSLConverter.swift at {converter_swift}", file=sys.stderr)
        return 2

    computed_output_root: Path | None = None
    if not args.output_file or len(args.ll_inputs) != 1 or args.corpus_roots:
        computed_output_root = Path(args.output_root).expanduser().resolve() if args.output_root else default_output_root(root).resolve()

    report_path = make_report_path(args, computed_output_root)
    warnings: list[DiscoveryWarning] = []

    jobs = discover_jobs(args, computed_output_root, warnings)
    if not jobs:
        print("error: no replay jobs discovered", file=sys.stderr)
        return 1

    raw_report = run_replay_jobs(jobs, converter_swift, report_path)
    enriched_report = enrich_report(raw_report, jobs, warnings, computed_output_root)
    report_path.write_text(json.dumps(enriched_report, indent=2, ensure_ascii=False), encoding="utf-8")
    print_summary(enriched_report, report_path, args)

    if enriched_report["failedJobs"] and not args.allow_failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
