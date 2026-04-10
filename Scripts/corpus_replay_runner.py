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
import difflib
import functools
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
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


SHARED_COMPILE_DECISION_MANIFEST_SWIFT = (
    Path(__file__).resolve().parent.parent
    / "Carthage"
    / "Checkouts"
    / "PlayTools"
    / "PlayTools"
    / "SharedCompilePlanner.swift"
)
SHARED_COMPILE_DECISION_MANIFEST_REGEX = re.compile(
    r'private static let sharedCompileDecisionManifestJSON = #"""(?P<payload>.*?)"""#',
    re.DOTALL,
)


def shared_compile_decision_manifest_path() -> Path:
    return SHARED_COMPILE_DECISION_MANIFEST_SWIFT


@functools.lru_cache(maxsize=None)
def load_shared_compile_decision_manifest(manifest_source_path: Path | None = None) -> dict[str, Any]:
    source_path = (manifest_source_path or shared_compile_decision_manifest_path()).expanduser().resolve()
    try:
        source_text = source_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"failed to read shared compile decision manifest source: {source_path} ({exc})"
        ) from exc

    match = SHARED_COMPILE_DECISION_MANIFEST_REGEX.search(source_text)
    if match is None:
        raise RuntimeError(f"shared compile decision manifest JSON not found in {source_path}")

    try:
        manifest = json.loads(match.group("payload"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"invalid shared compile decision manifest JSON in {source_path}: {exc}"
        ) from exc

    fast_math = manifest.get("fastMath")
    validation_rules = manifest.get("replacementSourceValidationRules")
    if not isinstance(fast_math, dict):
        raise RuntimeError(f"shared compile decision manifest is missing fastMath config: {source_path}")
    if not isinstance(fast_math.get("enableOption"), str) or not isinstance(fast_math.get("disableOption"), str):
        raise RuntimeError(f"shared compile decision manifest fastMath config is invalid: {source_path}")
    if not isinstance(validation_rules, list) or not validation_rules:
        raise RuntimeError(f"shared compile decision manifest has no validation rules: {source_path}")
    for index, entry in enumerate(validation_rules):
        if not isinstance(entry, dict):
            raise RuntimeError(f"shared compile decision validation rule #{index} is not an object: {source_path}")
        if not isinstance(entry.get("reason"), str) or not isinstance(entry.get("pattern"), str):
            raise RuntimeError(
                f"shared compile decision validation rule #{index} is missing reason/pattern: {source_path}"
            )

    return manifest


def compile_replacement_source_validation_rules(
    manifest: dict[str, Any],
) -> list[tuple[str, re.Pattern[str]]]:
    return [
        (str(entry["reason"]), re.compile(str(entry["pattern"])))
        for entry in manifest["replacementSourceValidationRules"]
    ]


SHARED_COMPILE_DECISION_MANIFEST = load_shared_compile_decision_manifest()
REPLACEMENT_SOURCE_VALIDATION_RULES: list[tuple[str, re.Pattern[str]]] = compile_replacement_source_validation_rules(
    SHARED_COMPILE_DECISION_MANIFEST
)

COMPILER_DIAGNOSTIC_REGEX = re.compile(
    r"^(?P<file>.+?):(?P<line>\d+):(?P<column>\d+): (?P<severity>warning|error|note): (?P<message>.+)$",
    re.MULTILINE,
)

# 这组 failure cluster 规则只服务离线 `xcrun metal -c` 报告归类；它不属于 shared manifest，
# 也不是 runtime / `mtl-device` 必须复刻的 compile decision 逻辑。
COMPILE_FAILURE_CATEGORY_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("undeclared_identifier", re.compile(r"undeclared identifier", re.IGNORECASE)),
    ("unknown_type", re.compile(r"unknown type name|use of undeclared type", re.IGNORECASE)),
    ("missing_member", re.compile(r"no member named", re.IGNORECASE)),
    ("address_space", re.compile(r"address space", re.IGNORECASE)),
    ("overload_resolution", re.compile(r"no matching (member )?function|candidate function not viable|candidate template ignored|ambiguous", re.IGNORECASE)),
    ("invalid_conversion", re.compile(r"cannot initialize|cannot convert|assigning to|cannot assign|cannot bind", re.IGNORECASE)),
    ("syntax", re.compile(r"^expected | expected |extraneous |expected ';'|expected '\)'|expected expression", re.IGNORECASE)),
    ("redefinition", re.compile(r"redefinition of", re.IGNORECASE)),
    ("unsupported_builtin", re.compile(r"\bair\.|builtin|intrinsic", re.IGNORECASE)),
]

FAST_MATH_ENABLE_OPTION = str(SHARED_COMPILE_DECISION_MANIFEST["fastMath"]["enableOption"])
FAST_MATH_DISABLE_OPTION = str(SHARED_COMPILE_DECISION_MANIFEST["fastMath"]["disableOption"])
EXPLICIT_FAST_MATH_METAL_ARGS = {"-ffast-math", "-fno-fast-math"}


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
        "--diagnostics-root",
        action="append",
        dest="diagnostics_roots",
        default=[],
        help="ShaderSourceDiagnostics 根目录，或单个 bundle 目录（可重复指定）",
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
        help="即使存在 replay / compile 失败也返回 0，便于先收集报告",
    )
    parser.add_argument(
        "--compile",
        action="store_true",
        help="对成功 replay 的 `.metal` 继续批量执行 `xcrun metal -c`，并生成 compile-summary.json",
    )
    parser.add_argument(
        "--compile-report-file",
        help="编译报告输出路径；默认写到 output-root 下，或单文件输出旁边",
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
        "--baseline-report",
        help="历史 replay-summary.json 或 save-baseline 生成的 baseline.json；用于对当前结果做 diff / 回归比较",
    )
    parser.add_argument(
        "--save-baseline",
        help="把当前结果保存为可复用基线快照（JSON + generated sources）",
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


def make_timestamped_run_name(now: datetime | None = None, unique_suffix: str | None = None) -> str:
    active_now = now or datetime.now()
    suffix = unique_suffix or uuid.uuid4().hex[:8]
    return f"{active_now.strftime('%Y%m%d-%H%M%S')}-{suffix}"


def default_output_root(root: Path) -> Path:
    return root / "build" / "shader-corpus-replay" / make_timestamped_run_name()


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


def is_diagnostics_bundle_root(path: Path) -> bool:
    if not path.is_dir():
        return False
    try:
        return any(child.is_dir() and child.name.endswith("_modules") for child in path.iterdir())
    except OSError:
        return False


def resolve_diagnostics_bundle_roots(diagnostics_root: Path) -> list[Path]:
    if is_diagnostics_bundle_root(diagnostics_root):
        return [diagnostics_root]
    if not diagnostics_root.is_dir():
        return []
    return sorted(child for child in diagnostics_root.iterdir() if is_diagnostics_bundle_root(child))


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


def make_compile_report_path(
    args: argparse.Namespace,
    report_path: Path,
    computed_output_root: Path | None,
) -> Path:
    if args.compile_report_file:
        return Path(args.compile_report_file).expanduser().resolve()

    if computed_output_root is not None:
        return (computed_output_root / "compile-summary.json").resolve()

    if args.output_file and len(args.ll_inputs) == 1:
        output_file = Path(args.output_file).expanduser().resolve()
        if output_file.suffix:
            return output_file.with_name(f"{output_file.stem}.compile.json")
        return output_file.parent / f"{output_file.name}.compile.json"

    return report_path.with_name(f"{report_path.stem}.compile.json").resolve()


def normalize_generated_msl(text: str) -> str:
    lines = []
    for line in text.splitlines():
        if line.startswith("// Generated at:"):
            continue
        lines.append(line.rstrip())
    return "\n".join(lines).strip()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


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

    return normalize_generated_msl(left_text) == normalize_generated_msl(right_text)


def _comparison_key_source_prefix(source_kind: str | None) -> str:
    if source_kind == "shader_source_diagnostics":
        return "shaderSourceDiagnostics::"
    return ""


def make_comparison_key(source_kind: str | None, bundle_id: str | None, module_key: str | None, input_path: str | None) -> str:
    source_prefix = _comparison_key_source_prefix(source_kind)
    if bundle_id and module_key:
        return f"{source_prefix}bundle:{bundle_id}::module:{module_key}"
    if module_key:
        return f"{source_prefix}module:{module_key}"
    if input_path:
        return f"{source_kind or 'input'}:{input_path}"
    return f"{source_kind or 'unknown'}:job"


def sanitize_path_component(value: str | None) -> str:
    candidate = (value or "unknown").strip()
    candidate = re.sub(r"[^A-Za-z0-9._-]+", "_", candidate)
    return candidate or "unknown"


def resolve_baseline_snapshot_paths(target: str) -> tuple[Path, Path]:
    raw_target = Path(target).expanduser().resolve()
    if raw_target.suffix.lower() == ".json":
        return raw_target, raw_target.with_name(f"{raw_target.stem}.baseline-assets")
    return (raw_target / "baseline.json").resolve(), (raw_target / "generated-sources").resolve()


def load_text_if_exists(path: Path | None) -> str | None:
    if path is None or not path.is_file():
        return None
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def build_runner_binary(temp_dir: Path, converter_swift: Path) -> Path:
    harness_path = temp_dir / "CorpusReplayMain.swift"
    binary_path = temp_dir / "corpus_replay_runner"
    harness_path.write_text(REPLAY_HARNESS_SWIFT, encoding="utf-8")

    command = ["swiftc", str(converter_swift), str(harness_path), "-o", str(binary_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    return binary_path


def shared_compile_planner_harness_swift_path(root: Path) -> Path:
    return root / "Scripts" / "shared_compile_planner_harness.swift"


def build_shared_compile_planner_harness_binary(root: Path, output_root: Path) -> Path:
    harness_swift = shared_compile_planner_harness_swift_path(root)
    if not harness_swift.is_file():
        raise RuntimeError(f"cannot find shared compile planner harness at {harness_swift}")

    shared_compile_planner_swift = shared_compile_decision_manifest_path().expanduser().resolve()
    if not shared_compile_planner_swift.is_file():
        raise RuntimeError(f"cannot find shared compile planner Swift source at {shared_compile_planner_swift}")

    binary_path = (output_root / "_internal" / "shared_compile_planner_harness").resolve()
    binary_path.parent.mkdir(parents=True, exist_ok=True)
    command = ["swiftc", str(shared_compile_planner_swift), str(harness_swift), "-o", str(binary_path)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    return binary_path


def load_original_ir_texts(original_ir_paths: list[Path]) -> list[str]:
    original_ir_texts: list[str] = []
    for original_ir_path in original_ir_paths:
        try:
            original_ir_texts.append(original_ir_path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            original_ir_texts.append("")
    return original_ir_texts


def resolve_shared_compile_plan(
    original_ir_paths: list[Path],
    user_metal_args: list[str] | None,
    *,
    requested_backend: str,
    shared_compile_planner_binary: Path | str,
) -> dict[str, Any]:
    binary_path = Path(shared_compile_planner_binary).expanduser().resolve()
    if not binary_path.is_file():
        raise RuntimeError(f"shared compile planner binary is missing: {binary_path}")

    payload = {
        "originalIRTexts": load_original_ir_texts(original_ir_paths),
        "userMetalArgs": list(user_metal_args or []),
        "requestedBackend": requested_backend,
    }

    with tempfile.TemporaryDirectory() as temp_dir:
        input_path = Path(temp_dir) / "planner-input.json"
        input_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        completed = subprocess.run(
            [str(binary_path), str(input_path)],
            check=True,
            capture_output=True,
            text=True,
        )

    try:
        plan = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid shared compile planner output: {exc}") from exc

    if not isinstance(plan, dict):
        raise RuntimeError("shared compile planner output is not a JSON object")
    if plan.get("requestedBackend") != requested_backend:
        raise RuntimeError(
            "shared compile planner returned unexpected backend: "
            f"expected {requested_backend}, got {plan.get('requestedBackend')}"
        )
    return plan


def unpack_shared_compile_plan(plan: dict[str, Any]) -> tuple[str | None, str, list[str], list[str]]:
    decision = plan.get("decision") or {}
    fast_math_mode = decision.get("fastMathMode")
    fast_math_decision = decision.get("fastMathDecision") or decision.get("reason") or "unresolved"
    inferred_metal_args = [str(arg) for arg in (plan.get("inferredMetalArgs") or [])]
    effective_metal_args = [str(arg) for arg in (plan.get("effectiveMetalArgs") or [])]
    return (
        str(fast_math_mode) if isinstance(fast_math_mode, str) else None,
        str(fast_math_decision),
        inferred_metal_args,
        effective_metal_args,
    )


def discover_jobs(
    args: argparse.Namespace,
    computed_output_root: Path | None,
    warnings: list[DiscoveryWarning],
) -> list[ReplayJob]:
    jobs: list[ReplayJob] = []
    bundle_filters = set(args.bundle_id)
    module_filters = set(args.module_key)
    output_file = getattr(args, "output_file", None)
    diagnostics_roots = [Path(raw).expanduser().resolve() for raw in getattr(args, "diagnostics_roots", [])]
    next_job_id = 0

    def enqueue(job: ReplayJob) -> None:
        nonlocal next_job_id
        job.job_id = next_job_id
        next_job_id += 1
        jobs.append(job)

    if args.ll_inputs:
        if output_file and len(args.ll_inputs) != 1:
            raise SystemExit("--output-file 只能和单个 --ll 输入一起使用")
        if computed_output_root is None and not output_file:
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

            if output_file:
                output_path = Path(output_file).expanduser().resolve()
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
    if not corpus_roots and not diagnostics_roots and not args.ll_inputs:
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

    for diagnostics_root in diagnostics_roots:
        bundle_roots = resolve_diagnostics_bundle_roots(diagnostics_root)
        if not bundle_roots:
            warn(warnings, f"no bundle roots found under diagnostics root: {diagnostics_root}")
            continue

        for bundle_root in bundle_roots:
            discovered_keys: set[str] = set()
            event_dirs = sorted(
                (child for child in bundle_root.iterdir() if child.is_dir() and child.name.endswith("_modules")),
                reverse=True,
            )
            if not event_dirs:
                warn(warnings, f"no *_modules directories found under diagnostics bundle root: {bundle_root}")
                continue

            for event_dir in event_dirs:
                for module_dir in sorted(child for child in event_dir.iterdir() if child.is_dir()):
                    meta_path = (module_dir / "module.meta.json").resolve()
                    if not meta_path.is_file():
                        warn(warnings, f"missing diagnostics module manifest: {meta_path}")
                        continue
                    metadata = load_json(meta_path, warnings)
                    if not metadata:
                        continue

                    bundle_id = metadata.get("bundleId") or bundle_root.name
                    module_key = metadata.get("moduleKey") or module_dir.name
                    if bundle_filters and bundle_id not in bundle_filters:
                        continue
                    if module_filters and module_key not in module_filters:
                        continue
                    if module_key in discovered_keys:
                        continue

                    artifact_paths = metadata.get("artifactPaths") or {}
                    llvm_ir_rel = artifact_paths.get("llvmIRPath")
                    if llvm_ir_rel:
                        llvm_ir_candidates = [
                            (module_dir / llvm_ir_rel).resolve(),
                            (event_dir / llvm_ir_rel).resolve(),
                            (bundle_root / llvm_ir_rel).resolve(),
                        ]
                        input_path = next((path for path in llvm_ir_candidates if path.is_file()), llvm_ir_candidates[0])
                    else:
                        input_path = (module_dir / "module.ll").resolve()
                    if not input_path.is_file():
                        warn(warnings, f"missing diagnostics LLVM IR file for {module_key}: {input_path}")
                        continue

                    generated_rel = artifact_paths.get("generatedMSLPath")
                    baseline_path: Path | None = None
                    if generated_rel:
                        generated_candidates = [
                            (module_dir / generated_rel).resolve(),
                            (event_dir / generated_rel).resolve(),
                            (bundle_root / generated_rel).resolve(),
                        ]
                        baseline_path = next((path for path in generated_candidates if path.is_file()), None)
                    else:
                        fallback = module_dir / "module.generated.metal"
                        if fallback.is_file():
                            baseline_path = fallback.resolve()

                    if computed_output_root is None:
                        raise SystemExit("diagnostics 模式需要 output_root")
                    output_path = (computed_output_root / bundle_id / "modules" / module_key / "replayed.generated.metal").resolve()

                    selector = metadata.get("selector")
                    observed_selectors = list(metadata.get("observedSelectors") or ([selector] if selector else []))
                    discovered_keys.add(module_key)
                    enqueue(
                        ReplayJob(
                            job_id=-1,
                            source_kind="shader_source_diagnostics",
                            input_path=input_path,
                            output_path=output_path,
                            bundle_id=bundle_id,
                            module_key=module_key,
                            metadata_path=meta_path,
                            baseline_generated_msl_path=baseline_path,
                            function_names=list(metadata.get("functionNames") or metadata.get("generatedFunctionNames") or []),
                            function_types=list(metadata.get("functionTypes") or metadata.get("generatedFunctionTypes") or []),
                            capture_count=metadata.get("captureCount"),
                            observed_selectors=observed_selectors,
                            source_root=event_dir,
                        )
                    )

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


def truncate_text(text: str | None, limit: int = 12000) -> str | None:
    if text is None:
        return None
    stripped = text.strip()
    if len(stripped) <= limit:
        return stripped
    remaining = len(stripped) - limit
    return f"{stripped[:limit]}\n... <truncated {remaining} chars>"


def shell_join(command: list[str]) -> str:
    return shlex.join(command)


def validate_generated_msl_source(source: str) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    for index, raw_line in enumerate(source.splitlines(), start=1):
        trimmed = raw_line.strip()
        if not trimmed or trimmed.startswith("//"):
            continue
        for reason, regex in REPLACEMENT_SOURCE_VALIDATION_RULES:
            if regex.search(trimmed):
                preview = trimmed if len(trimmed) <= 160 else f"{trimmed[:160]}…"
                issues.append(
                    {
                        "lineNumber": index,
                        "reason": reason,
                        "line": raw_line,
                        "summary": f"L{index}: {reason} — {preview}",
                    }
                )
                break
        if len(issues) >= 12:
            break
    return issues


def extract_compiler_diagnostics(output: str) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []
    seen: set[tuple[str, int, int, str, str]] = set()
    for match in COMPILER_DIAGNOSTIC_REGEX.finditer(output):
        record = (
            match.group("file"),
            int(match.group("line")),
            int(match.group("column")),
            match.group("severity"),
            match.group("message"),
        )
        if record in seen:
            continue
        seen.add(record)
        diagnostics.append(
            {
                "file": record[0],
                "line": record[1],
                "column": record[2],
                "severity": record[3],
                "message": record[4],
                "summary": f"{record[0]}:{record[1]}:{record[2]}: {record[3]}: {record[4]}",
            }
        )
    return diagnostics


def select_primary_diagnostic(diagnostics: list[dict[str, Any]]) -> dict[str, Any] | None:
    for item in diagnostics:
        if item.get("severity") == "error":
            return item
    return diagnostics[0] if diagnostics else None


def read_source_context(source_path: Path, line_number: int, radius: int = 2) -> list[dict[str, Any]]:
    if line_number <= 0 or not source_path.is_file():
        return []
    try:
        lines = source_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []

    if line_number > len(lines):
        return []

    lower_bound = max(1, line_number - radius)
    upper_bound = min(len(lines), line_number + radius)
    return [
        {
            "lineNumber": current,
            "text": lines[current - 1],
            "isPrimary": current == line_number,
        }
        for current in range(lower_bound, upper_bound + 1)
    ]


def normalize_compile_message(message: str) -> str:
    normalized = message.lower().strip()
    normalized = re.sub(r"0x[0-9a-f]+", "<hex>", normalized)
    normalized = re.sub(r"'[^']+'", "'<symbol>'", normalized)
    normalized = re.sub(r'"[^"]+"', '"<symbol>"', normalized)
    normalized = re.sub(r"\b\d+\b", "<n>", normalized)
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized


def categorize_compile_message(message: str) -> str:
    for category, regex in COMPILE_FAILURE_CATEGORY_RULES:
        if regex.search(message):
            return category
    return "other"


def derive_failure_cluster(
    status: str,
    diagnostics: list[dict[str, Any]],
    preflight_issues: list[dict[str, Any]],
    fallback_message: str | None,
) -> tuple[str, str, str]:
    if status == "preflight_rejected":
        title = (preflight_issues[0]["reason"] if preflight_issues else (fallback_message or "preflight rejected")).strip()
        return (
            f"preflight_rejected:{normalize_compile_message(title)}",
            "preflight_rejected",
            title,
        )

    primary = select_primary_diagnostic(diagnostics)
    if primary is not None:
        title = primary["message"].strip()
        category = categorize_compile_message(title)
        return (f"{category}:{normalize_compile_message(title)}", category, title)

    title = (fallback_message or "metal compiler failed without diagnostics").strip()
    return (f"compiler_failed:{normalize_compile_message(title)}", "compiler_failed", title)


def compiled_air_output_path(metal_path: Path) -> Path:
    if metal_path.suffix:
        return metal_path.with_suffix(".air")
    return metal_path.with_name(f"{metal_path.name}.air")


def infer_original_ir_fast_math_mode(original_ir_path: Path | None) -> str | None:
    if original_ir_path is None or not original_ir_path.is_file():
        return None

    try:
        text = original_ir_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    has_disable = FAST_MATH_DISABLE_OPTION in text
    has_enable = FAST_MATH_ENABLE_OPTION in text
    if has_disable and not has_enable:
        return "disable"
    if has_enable and not has_disable:
        return "enable"
    return None


# 这里保留的是 CLI backend 的 arg translation contract：把 shared planner 产出的 compile plan
# 映射到 `xcrun metal` 参数；Python 不再维护独立的 fast-math posture 推导逻辑。
def resolve_compile_metal_args(
    original_ir_path: Path | None,
    user_metal_args: list[str] | None,
    *,
    shared_compile_planner_binary: Path | str,
) -> tuple[str | None, str, list[str], list[str]]:
    original_ir_paths = [original_ir_path] if original_ir_path is not None else []
    plan = resolve_shared_compile_plan(
        original_ir_paths,
        user_metal_args,
        requested_backend="xcrun",
        shared_compile_planner_binary=shared_compile_planner_binary,
    )
    return unpack_shared_compile_plan(plan)


def compile_replay_result(result: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    source_path = Path(result["outputPath"])
    base_result = {
        "jobID": result["jobID"],
        "bundleId": result.get("bundleId"),
        "moduleKey": result.get("moduleKey"),
        "inputPath": result.get("inputPath"),
        "sourcePath": str(source_path),
        "airPath": None,
        "success": False,
        "status": "skipped_replay_failed",
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
        "originalFastMathMode": None,
        "fastMathMode": None,
        "fastMathDecision": None,
        "inferredMetalArgs": [],
        "effectiveMetalArgs": [],
    }

    if not result.get("success"):
        base_result["error"] = "replay_failed"
        return base_result

    if not source_path.is_file():
        base_result["status"] = "compile_input_missing"
        base_result["error"] = f"generated MSL file is missing: {source_path}"
        cluster_key, cluster_category, cluster_title = derive_failure_cluster(
            base_result["status"], [], [], base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    source_text = source_path.read_text(encoding="utf-8", errors="replace")
    preflight_issues = validate_generated_msl_source(source_text)
    base_result["preflightIssueCount"] = len(preflight_issues)
    base_result["preflightIssues"] = preflight_issues

    original_ir_path_value = result.get("inputPath")
    original_ir_path = Path(original_ir_path_value).expanduser().resolve() if original_ir_path_value else None
    shared_compile_planner_binary = getattr(args, "shared_compile_planner_binary", None)
    if not shared_compile_planner_binary:
        base_result["status"] = "compile_failed"
        base_result["error"] = "shared compile planner binary is missing"
        cluster_key, cluster_category, cluster_title = derive_failure_cluster(
            base_result["status"], [], preflight_issues, base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    original_fast_math_mode = infer_original_ir_fast_math_mode(original_ir_path)
    try:
        fast_math_mode, fast_math_decision, inferred_metal_args, effective_metal_args = resolve_compile_metal_args(
            original_ir_path,
            list(args.metal_args),
            shared_compile_planner_binary=shared_compile_planner_binary,
        )
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        base_result["status"] = "compile_failed"
        base_result["error"] = str(exc)
        cluster_key, cluster_category, cluster_title = derive_failure_cluster(
            base_result["status"], [], preflight_issues, base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    base_result["originalFastMathMode"] = original_fast_math_mode
    base_result["fastMathMode"] = fast_math_mode
    base_result["fastMathDecision"] = fast_math_decision
    base_result["inferredMetalArgs"] = inferred_metal_args
    base_result["effectiveMetalArgs"] = effective_metal_args

    air_path = compiled_air_output_path(source_path).resolve()
    air_path.parent.mkdir(parents=True, exist_ok=True)
    if air_path.exists():
        air_path.unlink()
    base_result["airPath"] = str(air_path)

    command = ["xcrun", "--sdk", args.metal_sdk, "metal", "-c", *effective_metal_args, str(source_path), "-o", str(air_path)]
    base_result["command"] = shell_join(command)

    if preflight_issues and not args.skip_preflight:
        base_result["status"] = "preflight_rejected"
        base_result["error"] = preflight_issues[0]["summary"]
        cluster_key, cluster_category, cluster_title = derive_failure_cluster(
            base_result["status"], [], preflight_issues, base_result["error"]
        )
        base_result["clusterKey"] = cluster_key
        base_result["clusterCategory"] = cluster_category
        base_result["clusterTitle"] = cluster_title
        return base_result

    start_time = time.perf_counter()
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    elapsed = time.perf_counter() - start_time
    combined_output = "\n".join(
        part for part in [completed.stdout.strip(), completed.stderr.strip()] if part
    )
    diagnostics = extract_compiler_diagnostics(combined_output)
    primary_diagnostic = select_primary_diagnostic(diagnostics)

    base_result["returnCode"] = completed.returncode
    base_result["elapsedSeconds"] = round(elapsed, 6)
    base_result["stdout"] = truncate_text(completed.stdout)
    base_result["stderr"] = truncate_text(completed.stderr)
    base_result["compilerOutput"] = truncate_text(combined_output, limit=16000)
    base_result["diagnostics"] = diagnostics
    base_result["primaryDiagnostic"] = primary_diagnostic
    if primary_diagnostic is not None:
        base_result["sourceContext"] = read_source_context(source_path, int(primary_diagnostic["line"]))

    if completed.returncode == 0:
        base_result["status"] = "success"
        base_result["success"] = True
        return base_result

    base_result["status"] = "compile_failed"
    base_result["error"] = combined_output or f"metal exited with status {completed.returncode}"
    cluster_key, cluster_category, cluster_title = derive_failure_cluster(
        base_result["status"], diagnostics, preflight_issues, base_result["error"]
    )
    base_result["clusterKey"] = cluster_key
    base_result["clusterCategory"] = cluster_category
    base_result["clusterTitle"] = cluster_title
    return base_result


def build_failure_clusters(compile_results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    clusters: dict[str, dict[str, Any]] = {}
    for item in compile_results:
        cluster_key = item.get("clusterKey")
        if not cluster_key:
            continue
        cluster = clusters.get(cluster_key)
        if cluster is None:
            cluster = {
                "clusterKey": cluster_key,
                "category": item.get("clusterCategory"),
                "title": item.get("clusterTitle"),
                "count": 0,
                "sampleJobs": [],
            }
            clusters[cluster_key] = cluster

        cluster["count"] += 1
        if len(cluster["sampleJobs"]) < 5:
            cluster["sampleJobs"].append(
                {
                    "jobID": item.get("jobID"),
                    "bundleId": item.get("bundleId"),
                    "moduleKey": item.get("moduleKey"),
                    "inputPath": item.get("inputPath"),
                    "sourcePath": item.get("sourcePath"),
                    "status": item.get("status"),
                    "primaryDiagnostic": item.get("primaryDiagnostic"),
                    "preflightIssues": item.get("preflightIssues"),
                    "sourceContext": item.get("sourceContext"),
                }
            )

    return sorted(clusters.values(), key=lambda item: (-item["count"], item["clusterKey"]))


def run_compile_jobs(
    report: dict[str, Any],
    args: argparse.Namespace,
    compile_report_path: Path,
) -> dict[str, Any]:
    compile_results = [compile_replay_result(item, args) for item in report.get("results", [])]
    clusters = build_failure_clusters(compile_results)

    replay_failed_jobs = sum(1 for item in compile_results if item["status"] == "skipped_replay_failed")
    preflight_rejected_jobs = sum(1 for item in compile_results if item["status"] == "preflight_rejected")
    compile_failed_jobs = sum(1 for item in compile_results if item["status"] in {"compile_failed", "compile_input_missing"})
    compile_succeeded_jobs = sum(1 for item in compile_results if item["status"] == "success")
    compiled_jobs = sum(1 for item in compile_results if item["status"] in {"success", "compile_failed"})

    compile_report = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "tool": "Scripts/corpus_replay_runner.py",
        "reportPath": str(compile_report_path),
        "compiler": {
            "sdk": args.metal_sdk,
            "extraArgs": list(args.metal_args),
            "autoAlignFastMathFromOriginalIR": True,
            "sharedCompilePlanner": True,
            "skipPreflight": bool(args.skip_preflight),
        },
        "totalJobs": len(compile_results),
        "replayFailedJobs": replay_failed_jobs,
        "compileEligibleJobs": len(compile_results) - replay_failed_jobs,
        "compiledJobs": compiled_jobs,
        "compileSucceededJobs": compile_succeeded_jobs,
        "compileFailedJobs": compile_failed_jobs,
        "preflightRejectedJobs": preflight_rejected_jobs,
        "failedJobs": compile_failed_jobs + preflight_rejected_jobs,
        "skippedJobs": replay_failed_jobs,
        "failureClusterCount": len(clusters),
        "failureClusters": clusters,
        "results": compile_results,
    }

    compile_report_path.parent.mkdir(parents=True, exist_ok=True)
    compile_report_path.write_text(json.dumps(compile_report, indent=2, ensure_ascii=False), encoding="utf-8")
    return compile_report


def attach_compile_report(report: dict[str, Any], compile_report: dict[str, Any]) -> dict[str, Any]:
    compile_by_job = {item["jobID"]: item for item in compile_report.get("results", [])}
    for item in report.get("results", []):
        item["compile"] = compile_by_job.get(item["jobID"])

    report["compile"] = {
        key: value
        for key, value in compile_report.items()
        if key != "results"
    }
    return report


def normalize_comparison_message(message: str | None) -> str | None:
    if message is None:
        return None
    normalized = re.sub(r"\s+", " ", message).strip()
    return normalized or None


def extract_entry_comparison_key(entry: dict[str, Any]) -> str:
    existing = entry.get("comparisonKey")
    if existing:
        return str(existing)
    return make_comparison_key(
        entry.get("sourceKind"),
        entry.get("bundleId"),
        entry.get("moduleKey"),
        entry.get("inputPath"),
    )


def extract_entry_replay(entry: dict[str, Any]) -> dict[str, Any]:
    nested = entry.get("replay")
    if isinstance(nested, dict):
        return nested
    return {
        "success": bool(entry.get("success")),
        "error": entry.get("error"),
        "conversionSummary": entry.get("conversionSummary"),
        "mslBytes": entry.get("mslBytes"),
        "generatedFunctionNames": entry.get("generatedFunctionNames"),
        "generatedFunctionTypes": entry.get("generatedFunctionTypes"),
        "stats": entry.get("stats"),
    }


def extract_entry_compile(entry: dict[str, Any]) -> dict[str, Any] | None:
    nested = entry.get("compile")
    if isinstance(nested, dict) and "status" in nested:
        return nested
    return None


def resolve_entry_generated_source_path(entry: dict[str, Any], baseline_json_path: Path | None = None) -> Path | None:
    stored = entry.get("baselineSourcePath")
    if stored and baseline_json_path is not None:
        return (baseline_json_path.parent / stored).resolve()

    output_path = entry.get("outputPath")
    if output_path:
        return Path(output_path).expanduser().resolve()
    return None


def compute_line_change_stats(baseline_lines: list[str], current_lines: list[str]) -> dict[str, int]:
    added = 0
    removed = 0
    changed_hunks = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=baseline_lines, b=current_lines).get_opcodes():
        if tag == "equal":
            continue
        changed_hunks += 1
        if tag in {"delete", "replace"}:
            removed += i2 - i1
        if tag in {"insert", "replace"}:
            added += j2 - j1
    return {
        "addedLines": added,
        "removedLines": removed,
        "changedHunks": changed_hunks,
    }


def make_diff_artifact_relative_path(result: dict[str, Any]) -> Path:
    bundle_component = sanitize_path_component(result.get("bundleId") or "manual")
    if result.get("bundleId") and result.get("moduleKey"):
        return Path(bundle_component) / "modules" / sanitize_path_component(result.get("moduleKey")) / "replayed-vs-baseline.diff"

    stem = Path(result.get("inputPath") or f"job-{result.get('jobID', 0)}").stem
    return Path("manual") / f"{int(result.get('jobID', 0)):03d}-{sanitize_path_component(stem)}.diff"


def compare_generated_sources(
    current_result: dict[str, Any],
    baseline_entry: dict[str, Any],
    baseline_json_path: Path,
    diff_dir: Path | None,
) -> dict[str, Any]:
    current_path = resolve_entry_generated_source_path(current_result)
    baseline_path = resolve_entry_generated_source_path(baseline_entry, baseline_json_path)
    current_text = load_text_if_exists(current_path)
    baseline_text = load_text_if_exists(baseline_path)

    current_replay = extract_entry_replay(current_result)
    baseline_replay = extract_entry_replay(baseline_entry)
    current_available = bool(current_replay.get("success")) and current_text is not None
    baseline_available = bool(baseline_replay.get("success")) and baseline_text is not None
    compared = current_available and baseline_available

    comparison = {
        "currentPath": str(current_path) if current_path else None,
        "baselinePath": str(baseline_path) if baseline_path else None,
        "currentAvailable": current_available,
        "baselineAvailable": baseline_available,
        "compared": compared,
        "changed": None,
        "baselineNormalizedSHA256": None,
        "currentNormalizedSHA256": None,
        "lineChanges": None,
        "diffPreview": [],
        "diffArtifactPath": None,
    }
    if not compared:
        return comparison

    normalized_current = normalize_generated_msl(current_text)
    normalized_baseline = normalize_generated_msl(baseline_text)
    comparison["currentNormalizedSHA256"] = sha256_text(normalized_current)
    comparison["baselineNormalizedSHA256"] = sha256_text(normalized_baseline)
    comparison["changed"] = normalized_current != normalized_baseline
    if not comparison["changed"]:
        comparison["lineChanges"] = {
            "addedLines": 0,
            "removedLines": 0,
            "changedHunks": 0,
        }
        return comparison

    baseline_lines = normalized_baseline.splitlines()
    current_lines = normalized_current.splitlines()
    diff_lines = list(
        difflib.unified_diff(
            baseline_lines,
            current_lines,
            fromfile=str(baseline_path or "baseline"),
            tofile=str(current_path or "current"),
            lineterm="",
        )
    )
    comparison["lineChanges"] = compute_line_change_stats(baseline_lines, current_lines)
    comparison["diffPreview"] = diff_lines[:40]
    if diff_dir is not None:
        relative_path = make_diff_artifact_relative_path(current_result)
        absolute_path = (diff_dir / relative_path).resolve()
        absolute_path.parent.mkdir(parents=True, exist_ok=True)
        absolute_path.write_text("\n".join(diff_lines) + "\n", encoding="utf-8")
        comparison["diffArtifactPath"] = str((Path(diff_dir.name) / relative_path).as_posix())
    return comparison


def summarize_replay_change(current_result: dict[str, Any], baseline_entry: dict[str, Any]) -> dict[str, Any]:
    current_replay = extract_entry_replay(current_result)
    baseline_replay = extract_entry_replay(baseline_entry)
    current_success = bool(current_replay.get("success"))
    baseline_success = bool(baseline_replay.get("success"))
    current_error = normalize_comparison_message(current_replay.get("error"))
    baseline_error = normalize_comparison_message(baseline_replay.get("error"))
    changed = current_success != baseline_success or (not current_success and current_error != baseline_error)
    return {
        "baselineSuccess": baseline_success,
        "currentSuccess": current_success,
        "baselineError": baseline_error,
        "currentError": current_error,
        "changed": changed,
        "regression": baseline_success and not current_success,
        "improvement": (not baseline_success) and current_success,
    }


def summarize_compile_change(current_result: dict[str, Any], baseline_entry: dict[str, Any]) -> dict[str, Any] | None:
    current_compile = extract_entry_compile(current_result)
    baseline_compile = extract_entry_compile(baseline_entry)
    if current_compile is None and baseline_compile is None:
        return None

    current_status = current_compile.get("status") if current_compile else None
    baseline_status = baseline_compile.get("status") if baseline_compile else None
    current_cluster = current_compile.get("clusterKey") if current_compile else None
    baseline_cluster = baseline_compile.get("clusterKey") if baseline_compile else None
    available_on_both_sides = current_compile is not None and baseline_compile is not None
    changed = current_status != baseline_status or current_cluster != baseline_cluster
    return {
        "availableOnBothSides": available_on_both_sides,
        "baselineStatus": baseline_status,
        "currentStatus": current_status,
        "baselineClusterKey": baseline_cluster,
        "currentClusterKey": current_cluster,
        "changed": changed,
        "regression": baseline_status == "success" and current_status != "success",
        "improvement": baseline_status != "success" and current_status == "success",
    }


def compare_report_to_baseline(report: dict[str, Any], baseline_payload: dict[str, Any], baseline_path: Path) -> dict[str, Any]:
    baseline_results = baseline_payload.get("results") or []
    baseline_by_key = {extract_entry_comparison_key(item): item for item in baseline_results}
    current_keys: set[str] = set()
    report_dir = Path(report.get("outputRoot") or Path(report.get("results", [{}])[0].get("outputPath", baseline_path.parent)).parent).resolve() if report.get("results") else baseline_path.parent
    diff_dir = (report_dir / "baseline-diffs").resolve()

    matched_jobs = 0
    new_jobs = 0
    replay_changed_jobs = 0
    replay_regressions = 0
    replay_improvements = 0
    compile_compared_jobs = 0
    compile_changed_jobs = 0
    compile_regressions = 0
    compile_improvements = 0
    generated_compared_jobs = 0
    generated_changed_jobs = 0
    identical_generated_jobs = 0
    changed_samples: list[dict[str, Any]] = []

    for result in report.get("results", []):
        comparison_key = extract_entry_comparison_key(result)
        current_keys.add(comparison_key)
        baseline_entry = baseline_by_key.get(comparison_key)
        if baseline_entry is None:
            new_jobs += 1
            result["baselineComparison"] = {
                "comparisonKey": comparison_key,
                "baselineFound": False,
                "status": "new_job",
            }
            continue

        matched_jobs += 1
        replay_change = summarize_replay_change(result, baseline_entry)
        compile_change = summarize_compile_change(result, baseline_entry)
        generated_change = compare_generated_sources(result, baseline_entry, baseline_path, diff_dir)

        if replay_change["changed"]:
            replay_changed_jobs += 1
        if replay_change["regression"]:
            replay_regressions += 1
        if replay_change["improvement"]:
            replay_improvements += 1

        if compile_change is not None:
            if compile_change["availableOnBothSides"]:
                compile_compared_jobs += 1
            if compile_change["changed"]:
                compile_changed_jobs += 1
            if compile_change["regression"]:
                compile_regressions += 1
            if compile_change["improvement"]:
                compile_improvements += 1

        if generated_change["compared"]:
            generated_compared_jobs += 1
            if generated_change["changed"]:
                generated_changed_jobs += 1
            else:
                identical_generated_jobs += 1

        changed = replay_change["changed"] or bool(compile_change and compile_change["changed"]) or bool(generated_change["changed"])
        if changed and len(changed_samples) < 20:
            changed_samples.append(
                {
                    "comparisonKey": comparison_key,
                    "bundleId": result.get("bundleId"),
                    "moduleKey": result.get("moduleKey"),
                    "inputPath": result.get("inputPath"),
                    "replayChanged": replay_change["changed"],
                    "compileChanged": bool(compile_change and compile_change["changed"]),
                    "generatedMSLChanged": bool(generated_change["changed"]),
                    "regression": replay_change["regression"] or bool(compile_change and compile_change["regression"]),
                }
            )

        result["baselineComparison"] = {
            "comparisonKey": comparison_key,
            "baselineFound": True,
            "status": "changed" if changed else "unchanged",
            "replay": replay_change,
            "compile": compile_change,
            "generatedMSL": generated_change,
        }

    removed_entries = []
    for comparison_key, entry in baseline_by_key.items():
        if comparison_key in current_keys:
            continue
        if len(removed_entries) >= 20:
            break
        removed_entries.append(
            {
                "comparisonKey": comparison_key,
                "bundleId": entry.get("bundleId"),
                "moduleKey": entry.get("moduleKey"),
                "inputPath": entry.get("inputPath"),
            }
        )

    report["baselineComparison"] = {
        "baselinePath": str(baseline_path),
        "baselineGeneratedAt": baseline_payload.get("generatedAt"),
        "matchedJobs": matched_jobs,
        "newJobs": new_jobs,
        "removedJobs": max(0, len(baseline_by_key) - len(current_keys & set(baseline_by_key.keys()))),
        "replayChangedJobs": replay_changed_jobs,
        "replayRegressions": replay_regressions,
        "replayImprovements": replay_improvements,
        "compileComparedJobs": compile_compared_jobs,
        "compileChangedJobs": compile_changed_jobs,
        "compileRegressions": compile_regressions,
        "compileImprovements": compile_improvements,
        "generatedMSLComparedJobs": generated_compared_jobs,
        "generatedMSLChangedJobs": generated_changed_jobs,
        "identicalGeneratedMSLJobs": identical_generated_jobs,
        "changedSamples": changed_samples,
        "removedEntries": removed_entries,
        "diffArtifactRoot": str(diff_dir),
    }
    return report


def make_snapshot_source_relative_path(entry: dict[str, Any], asset_root_name: str) -> Path:
    if entry.get("bundleId") and entry.get("moduleKey"):
        return Path(asset_root_name) / sanitize_path_component(entry.get("bundleId")) / "modules" / sanitize_path_component(entry.get("moduleKey")) / "baseline.generated.metal"

    stem = Path(entry.get("inputPath") or f"job-{entry.get('jobID', 0)}").stem
    return Path(asset_root_name) / "manual" / f"{int(entry.get('jobID', 0)):03d}-{sanitize_path_component(stem)}.generated.metal"


def save_baseline_snapshot(
    report: dict[str, Any],
    target: str,
    report_path: Path,
    compile_report_path: Path | None,
) -> dict[str, Any]:
    baseline_json_path, asset_root = resolve_baseline_snapshot_paths(target)
    baseline_json_path.parent.mkdir(parents=True, exist_ok=True)
    if asset_root.exists():
        shutil.rmtree(asset_root)
    asset_root.mkdir(parents=True, exist_ok=True)

    baseline_results: list[dict[str, Any]] = []
    for result in report.get("results", []):
        replay = extract_entry_replay(result)
        compile_record = extract_entry_compile(result)
        source_path = resolve_entry_generated_source_path(result)
        source_text = load_text_if_exists(source_path)
        relative_source_path: str | None = None
        normalized_hash: str | None = None
        normalized_line_count: int | None = None
        if replay.get("success") and source_path is not None and source_text is not None:
            relative_path = make_snapshot_source_relative_path(result, asset_root.name)
            destination = (baseline_json_path.parent / relative_path).resolve()
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, destination)
            relative_source_path = relative_path.as_posix()
            normalized_source = normalize_generated_msl(source_text)
            normalized_hash = sha256_text(normalized_source)
            normalized_line_count = len(normalized_source.splitlines())

        baseline_results.append(
            {
                "comparisonKey": extract_entry_comparison_key(result),
                "sourceKind": result.get("sourceKind"),
                "bundleId": result.get("bundleId"),
                "moduleKey": result.get("moduleKey"),
                "inputPath": result.get("inputPath"),
                "metadataPath": result.get("metadataPath"),
                "baselineSourcePath": relative_source_path,
                "replay": {
                    "success": bool(replay.get("success")),
                    "error": replay.get("error"),
                    "conversionSummary": replay.get("conversionSummary"),
                    "mslBytes": replay.get("mslBytes"),
                    "generatedFunctionNames": replay.get("generatedFunctionNames"),
                    "generatedFunctionTypes": replay.get("generatedFunctionTypes"),
                    "stats": replay.get("stats"),
                    "normalizedMSLSHA256": normalized_hash,
                    "normalizedMSLLineCount": normalized_line_count,
                },
                "compile": {
                    "status": compile_record.get("status"),
                    "success": compile_record.get("success"),
                    "error": compile_record.get("error"),
                    "clusterKey": compile_record.get("clusterKey"),
                    "clusterCategory": compile_record.get("clusterCategory"),
                    "clusterTitle": compile_record.get("clusterTitle"),
                    "primaryDiagnostic": compile_record.get("primaryDiagnostic"),
                    "preflightIssueCount": compile_record.get("preflightIssueCount"),
                } if compile_record else None,
            }
        )

    baseline_payload = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "tool": "Scripts/corpus_replay_runner.py",
        "sourceReportPath": str(report_path),
        "sourceCompileReportPath": str(compile_report_path) if compile_report_path else None,
        "baselineAssetRoot": asset_root.name,
        "totalJobs": report.get("totalJobs"),
        "successfulJobs": report.get("successfulJobs"),
        "failedJobs": report.get("failedJobs"),
        "compile": report.get("compile"),
        "results": baseline_results,
    }
    baseline_json_path.write_text(json.dumps(baseline_payload, indent=2, ensure_ascii=False), encoding="utf-8")
    return {
        "baselinePath": str(baseline_json_path),
        "baselineAssetRoot": asset_root.name,
    }


def enrich_report(
    raw_report: dict[str, Any],
    jobs: list[ReplayJob],
    warnings: list[DiscoveryWarning],
    output_root: Path | None,
) -> dict[str, Any]:
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

        comparison_key = make_comparison_key(job.source_kind, job.bundle_id, job.module_key, str(job.input_path))
        enriched_results.append(
            {
                "jobID": job.job_id,
                "comparisonKey": comparison_key,
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

    compile_summary = report.get("compile")
    if compile_summary:
        print("=== compile summary ===")
        print(
            "compile: "
            f"{compile_summary['compileSucceededJobs']} success / "
            f"{compile_summary['compileFailedJobs']} failed / "
            f"{compile_summary['preflightRejectedJobs']} preflight rejected / "
            f"{compile_summary['skippedJobs']} skipped"
        )
        if compile_summary.get("reportPath"):
            print(f"compile report: {compile_summary['reportPath']}")

        clusters = compile_summary.get("failureClusters") or []
        if clusters:
            print("top compile failure clusters:")
            for cluster in clusters[:5]:
                print(f"  - [{cluster['category']}] x{cluster['count']}: {cluster['title']}")

    baseline_summary = report.get("baselineComparison")
    if baseline_summary:
        print("=== baseline comparison ===")
        print(f"baseline: {baseline_summary['baselinePath']}")
        print(
            "matched/new/removed: "
            f"{baseline_summary['matchedJobs']} / "
            f"{baseline_summary['newJobs']} / "
            f"{baseline_summary['removedJobs']}"
        )
        print(
            "replay changed: "
            f"{baseline_summary['replayChangedJobs']} "
            f"(regressions {baseline_summary['replayRegressions']}, improvements {baseline_summary['replayImprovements']})"
        )
        print(
            "generated MSL: "
            f"{baseline_summary['identicalGeneratedMSLJobs']} identical / "
            f"{baseline_summary['generatedMSLChangedJobs']} changed"
        )
        if baseline_summary.get("compileComparedJobs"):
            print(
                "compile changed: "
                f"{baseline_summary['compileChangedJobs']} over {baseline_summary['compileComparedJobs']} compared "
                f"(regressions {baseline_summary['compileRegressions']}, improvements {baseline_summary['compileImprovements']})"
            )
        if baseline_summary.get("changedSamples"):
            print("changed samples:")
            for item in baseline_summary["changedSamples"][:5]:
                key = item.get("moduleKey") or Path(item.get("inputPath") or item["comparisonKey"]).stem
                flags = []
                if item.get("replayChanged"):
                    flags.append("replay")
                if item.get("compileChanged"):
                    flags.append("compile")
                if item.get("generatedMSLChanged"):
                    flags.append("msl")
                print(f"  - {key}: {', '.join(flags) if flags else 'changed'}")

    saved_baseline = report.get("savedBaseline")
    if saved_baseline:
        print("=== baseline snapshot saved ===")
        print(f"baseline: {saved_baseline['baselinePath']}")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if shutil.which("swiftc") is None:
        print("error: cannot find swiftc in PATH", file=sys.stderr)
        return 2
    if args.compile and shutil.which("xcrun") is None:
        print("error: cannot find xcrun in PATH", file=sys.stderr)
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
    compile_report_path = make_compile_report_path(args, report_path, computed_output_root) if args.compile else None
    if args.compile:
        planner_output_root = computed_output_root or report_path.parent
        try:
            args.shared_compile_planner_binary = str(build_shared_compile_planner_harness_binary(root, planner_output_root))
        except subprocess.CalledProcessError as exc:
            detail = "\n".join(part for part in [exc.stdout.strip(), exc.stderr.strip()] if part) or str(exc)
            print(f"error: failed to build shared compile planner harness: {detail}", file=sys.stderr)
            return 2
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    warnings: list[DiscoveryWarning] = []

    jobs = discover_jobs(args, computed_output_root, warnings)
    if not jobs:
        print("error: no replay jobs discovered", file=sys.stderr)
        return 1

    raw_report = run_replay_jobs(jobs, converter_swift, report_path)
    enriched_report = enrich_report(raw_report, jobs, warnings, computed_output_root)
    if args.compile and compile_report_path is not None:
        compile_report = run_compile_jobs(enriched_report, args, compile_report_path)
        enriched_report = attach_compile_report(enriched_report, compile_report)

    if args.baseline_report:
        baseline_path = Path(args.baseline_report).expanduser().resolve()
        baseline_payload = load_json(baseline_path, warnings)
        if baseline_payload is None:
            print(f"error: failed to load baseline report: {baseline_path}", file=sys.stderr)
            return 1
        enriched_report = compare_report_to_baseline(enriched_report, baseline_payload, baseline_path)

    if args.save_baseline:
        enriched_report["savedBaseline"] = save_baseline_snapshot(
            enriched_report,
            args.save_baseline,
            report_path,
            compile_report_path,
        )

    report_path.write_text(json.dumps(enriched_report, indent=2, ensure_ascii=False), encoding="utf-8")
    print_summary(enriched_report, report_path, args)

    replay_failed = int(enriched_report["failedJobs"])
    compile_failed = int((enriched_report.get("compile") or {}).get("failedJobs", 0))
    replay_regressions = int((enriched_report.get("baselineComparison") or {}).get("replayRegressions", 0))
    compile_regressions = int((enriched_report.get("baselineComparison") or {}).get("compileRegressions", 0))
    if (replay_failed or compile_failed or replay_regressions or compile_regressions) and not args.allow_failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
