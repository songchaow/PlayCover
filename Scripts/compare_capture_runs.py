#!/usr/bin/env python3
"""
compare_capture_runs.py — 对比两轮 ShaderCorpus 采集结果，辅助 E-006d 排查输入/输出是否稳定。

若 run 目录中还包含 `snapshot.meta.json`（例如由 `snapshot_capture_run.py` 生成），
脚本也会额外比较 replacement 开关与 `.gputrace` 源码覆盖摘要。

输入可为包含 `manifest.jsonl` 与 `modules/` 的 bundle 目录，或显式 `manifest.jsonl` 文件。

示例：
    python3 Scripts/compare_capture_runs.py \
        --run-a ~/captures/run-a/com.miHoYo.Yuanshen \
        --run-b ~/captures/run-b/com.miHoYo.Yuanshen

    python3 Scripts/compare_capture_runs.py \
        --run-a ~/captures/run-a/manifest.jsonl \
        --run-b ~/captures/run-b/manifest.jsonl \
        --modules-a ~/captures/run-a/modules \
        --modules-b ~/captures/run-b/modules \
        --output build/e006d-run-diff.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ARTIFACT_FILENAMES = (
    "module.bc",
    "module.ll",
    "module.generated.metal",
    "module.meta.json",
)

AGGREGATE_EVENT = "replacement"


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"failed to parse {path} line {line_number}: {exc}") from exc
            if isinstance(payload, dict):
                events.append(payload)
    return events


@dataclass(frozen=True)
class RunInput:
    label: str
    manifest_path: Path
    modules_dir: Path


def load_snapshot_meta(run_input: RunInput) -> dict[str, Any] | None:
    meta_path = run_input.manifest_path.parent / "snapshot.meta.json"
    if not meta_path.is_file():
        return None
    payload = load_json(meta_path)
    return payload if isinstance(payload, dict) else None


def resolve_run_input(raw_path: str, modules_override: str | None, label: str) -> RunInput:
    path = Path(raw_path).expanduser().resolve()
    if path.is_dir():
        manifest_path = path / "manifest.jsonl"
        modules_dir = Path(modules_override).expanduser().resolve() if modules_override else path / "modules"
    else:
        manifest_path = path
        if modules_override:
            modules_dir = Path(modules_override).expanduser().resolve()
        else:
            modules_dir = manifest_path.parent / "modules"

    if not manifest_path.is_file():
        raise SystemExit(f"{label}: manifest not found at {manifest_path}")
    if not modules_dir.is_dir():
        raise SystemExit(f"{label}: modules directory not found at {modules_dir}")

    return RunInput(label=label, manifest_path=manifest_path, modules_dir=modules_dir)


def summarize_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    capture_events = [event for event in events if event.get("event") == "capture"]
    selectors = sorted({event.get("selector") for event in capture_events if event.get("selector")})
    bundle_ids = sorted({event.get("bundleId") for event in capture_events if event.get("bundleId")})
    module_keys = [event.get("moduleKey") for event in capture_events if event.get("moduleKey")]
    timestamps = [event.get("timestamp") for event in capture_events if event.get("timestamp")]
    capture_actions = Counter(event.get("captureAction", "unknown") for event in capture_events)
    function_types = Counter()
    for event in capture_events:
        for function_type in event.get("functionTypes", []) or []:
            function_types[function_type] += 1

    return {
        "eventCount": len(events),
        "captureEventCount": len(capture_events),
        "bundleIds": bundle_ids,
        "selectors": selectors,
        "captureActions": dict(sorted(capture_actions.items())),
        "functionTypes": dict(sorted(function_types.items())),
        "firstTimestamp": min(timestamps) if timestamps else None,
        "lastTimestamp": max(timestamps) if timestamps else None,
        "moduleKeyCount": len(set(module_keys)),
    }


def summarize_replacement_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    replacement_events = [event for event in events if event.get("event") == AGGREGATE_EVENT]
    selectors = sorted({event.get("selector") for event in replacement_events if event.get("selector")})
    aggregate_sizes = [event.get("aggregateMSLBytes") for event in replacement_events if isinstance(event.get("aggregateMSLBytes"), int)]

    return {
        "replacementEventCount": len(replacement_events),
        "selectors": selectors,
        "firstTimestamp": min((event.get("timestamp") for event in replacement_events if event.get("timestamp")), default=None),
        "lastTimestamp": max((event.get("timestamp") for event in replacement_events if event.get("timestamp")), default=None),
        "aggregateMSLBytes": {
            "min": min(aggregate_sizes) if aggregate_sizes else None,
            "max": max(aggregate_sizes) if aggregate_sizes else None,
        },
    }


def build_replacement_index(run_input: RunInput) -> dict[str, Any]:
    events = load_jsonl(run_input.manifest_path)
    replacement_events = [event for event in events if event.get("event") == AGGREGATE_EVENT]
    indexed: list[dict[str, Any]] = []

    for event in replacement_events:
        aggregate_relative_path = event.get("aggregateSourcePath")
        aggregate_path = run_input.manifest_path.parent / aggregate_relative_path if aggregate_relative_path else None
        indexed.append(
            {
                "timestamp": event.get("timestamp"),
                "selector": event.get("selector"),
                "cacheKey": event.get("cacheKey"),
                "corpusRelativeDirectory": event.get("corpusRelativeDirectory"),
                "moduleKeys": sorted(event.get("moduleKeys", []) or []),
                "moduleCount": event.get("moduleCount"),
                "functionCount": event.get("functionCount"),
                "totalIRSize": event.get("totalIRSize"),
                "aggregateMSLBytes": event.get("aggregateMSLBytes"),
                "sourceFunctionNames": sorted(event.get("sourceFunctionNames", []) or []),
                "sourceFunctionTypes": sorted(event.get("sourceFunctionTypes", []) or []),
                "aggregateSourcePath": aggregate_relative_path,
                "aggregateSourceSHA256": sha256_file(aggregate_path) if aggregate_path else None,
                "aggregateSourceExists": aggregate_path.is_file() if aggregate_path else False,
            }
        )

    indexed.sort(key=lambda item: (item.get("timestamp") or "", item.get("cacheKey") or "", item.get("selector") or ""))
    latest = indexed[-1] if indexed else None
    return {
        "summary": summarize_replacement_events(events),
        "events": indexed,
        "latest": latest,
    }


def build_module_index(run_input: RunInput) -> dict[str, dict[str, Any]]:
    events = load_jsonl(run_input.manifest_path)
    modules: dict[str, dict[str, Any]] = {}

    for event in events:
        if event.get("event") != "capture":
            continue
        module_key = event.get("moduleKey")
        if not module_key:
            continue
        entry = modules.setdefault(
            module_key,
            {
                "moduleKey": module_key,
                "bundleId": event.get("bundleId"),
                "selectors": set(),
                "functionNames": set(),
                "functionTypes": set(),
                "generatedFunctionNames": set(),
                "generatedFunctionTypes": set(),
                "captureActions": set(),
                "timestamps": [],
                "eventCount": 0,
                "moduleDir": run_input.modules_dir / module_key,
            },
        )
        entry["eventCount"] += 1
        if selector := event.get("selector"):
            entry["selectors"].add(selector)
        if capture_action := event.get("captureAction"):
            entry["captureActions"].add(capture_action)
        entry["functionNames"].update(event.get("functionNames", []) or [])
        entry["functionTypes"].update(event.get("functionTypes", []) or [])
        entry["generatedFunctionNames"].update(event.get("generatedFunctionNames", []) or [])
        entry["generatedFunctionTypes"].update(event.get("generatedFunctionTypes", []) or [])
        if timestamp := event.get("timestamp"):
            entry["timestamps"].append(timestamp)

    for module_key, entry in modules.items():
        module_dir = entry["moduleDir"]
        artifact_hashes: dict[str, str | None] = {}
        artifact_sizes: dict[str, int | None] = {}
        for filename in ARTIFACT_FILENAMES:
            artifact_path = module_dir / filename
            artifact_hashes[filename] = sha256_file(artifact_path)
            artifact_sizes[filename] = artifact_path.stat().st_size if artifact_path.is_file() else None

        meta_path = module_dir / "module.meta.json"
        meta = load_json(meta_path) if meta_path.is_file() else {}
        entry.update(
            {
                "artifactHashes": artifact_hashes,
                "artifactSizes": artifact_sizes,
                "selectors": sorted(entry["selectors"]),
                "captureActions": sorted(entry["captureActions"]),
                "functionNames": sorted(entry["functionNames"]),
                "functionTypes": sorted(entry["functionTypes"]),
                "generatedFunctionNames": sorted(entry["generatedFunctionNames"]),
                "generatedFunctionTypes": sorted(entry["generatedFunctionTypes"]),
                "firstTimestamp": min(entry["timestamps"]) if entry["timestamps"] else None,
                "lastTimestamp": max(entry["timestamps"]) if entry["timestamps"] else None,
                "metaSummary": {
                    "compileStatus": meta.get("compileStatus"),
                    "converterStatus": meta.get("converterStatus"),
                    "llvmDisStatus": meta.get("llvmDisStatus"),
                    "captureCount": meta.get("captureCount"),
                    "observedSelectors": meta.get("observedSelectors", []),
                    "sourceCacheKeys": meta.get("sourceCacheKeys", []),
                    "generatedMSLBytes": meta.get("generatedMSLBytes"),
                    "llvmIRBytes": meta.get("llvmIRBytes"),
                    "bitcodeBytes": meta.get("bitcodeBytes"),
                },
            }
        )
        del entry["timestamps"]
        del entry["moduleDir"]

    return modules


def compare_values(name: str, left: Any, right: Any, differences: list[dict[str, Any]]) -> None:
    if left != right:
        differences.append({"field": name, "runA": left, "runB": right})


def compare_shared_modules(
    modules_a: dict[str, dict[str, Any]],
    modules_b: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    differences: list[dict[str, Any]] = []
    for module_key in sorted(set(modules_a) & set(modules_b)):
        left = modules_a[module_key]
        right = modules_b[module_key]
        field_differences: list[dict[str, Any]] = []

        for field in (
            "bundleId",
            "selectors",
            "captureActions",
            "functionNames",
            "functionTypes",
            "generatedFunctionNames",
            "generatedFunctionTypes",
            "artifactHashes",
            "artifactSizes",
            "metaSummary",
        ):
            compare_values(field, left.get(field), right.get(field), field_differences)

        if field_differences:
            differences.append(
                {
                    "moduleKey": module_key,
                    "eventCount": {"runA": left.get("eventCount"), "runB": right.get("eventCount")},
                    "timestamps": {"runA": [left.get("firstTimestamp"), left.get("lastTimestamp")],
                                   "runB": [right.get("firstTimestamp"), right.get("lastTimestamp")]},
                    "differences": field_differences,
                }
            )
    return differences


def compare_replacement_runs(
    replacements_a: dict[str, Any],
    replacements_b: dict[str, Any],
) -> dict[str, Any]:
    latest_a = replacements_a.get("latest")
    latest_b = replacements_b.get("latest")
    if latest_a is None or latest_b is None:
        return {
            "hasComparableReplacement": False,
            "missingRunA": latest_a is None,
            "missingRunB": latest_b is None,
            "differences": [],
        }

    differences: list[dict[str, Any]] = []
    for field in (
        "selector",
        "cacheKey",
        "moduleKeys",
        "moduleCount",
        "functionCount",
        "totalIRSize",
        "aggregateMSLBytes",
        "sourceFunctionNames",
        "sourceFunctionTypes",
        "aggregateSourcePath",
        "aggregateSourceExists",
        "aggregateSourceSHA256",
    ):
        compare_values(field, latest_a.get(field), latest_b.get(field), differences)

    return {
        "hasComparableReplacement": True,
        "missingRunA": False,
        "missingRunB": False,
        "runA": latest_a,
        "runB": latest_b,
        "differences": differences,
    }


def build_snapshot_context(meta: dict[str, Any] | None) -> dict[str, Any]:
    if meta is None:
        return {
            "hasSnapshotMeta": False,
            "label": None,
            "replacementMode": None,
            "gputraceSummary": None,
            "visibleMSLHashes": [],
        }

    gputrace_summary = meta.get("gputraceSummary")
    visible_msl_hashes: list[str] = []
    if isinstance(gputrace_summary, dict):
        files = gputrace_summary.get("files")
        if isinstance(files, dict):
            visible_msl_hashes = sorted(
                file_name
                for file_name, file_info in files.items()
                if isinstance(file_info, dict) and file_info.get("isMSL") is True
            )

    return {
        "hasSnapshotMeta": True,
        "label": meta.get("label"),
        "replacementMode": meta.get("replacementMode"),
        "gputraceSummary": gputrace_summary,
        "visibleMSLHashes": visible_msl_hashes,
    }


def compare_snapshot_context(meta_a: dict[str, Any] | None, meta_b: dict[str, Any] | None) -> dict[str, Any]:
    if meta_a is None or meta_b is None:
        return {
            "hasComparableSnapshots": False,
            "missingRunA": meta_a is None,
            "missingRunB": meta_b is None,
            "differences": [],
        }

    context_a = build_snapshot_context(meta_a)
    context_b = build_snapshot_context(meta_b)
    differences: list[dict[str, Any]] = []
    compare_values(
        "replacementMode.enabled",
        (context_a.get("replacementMode") or {}).get("enabled"),
        (context_b.get("replacementMode") or {}).get("enabled"),
        differences,
    )
    compare_values(
        "gputraceSummary.validMSLFiles",
        (context_a.get("gputraceSummary") or {}).get("validMSLFiles"),
        (context_b.get("gputraceSummary") or {}).get("validMSLFiles"),
        differences,
    )
    compare_values(
        "gputraceSummary.visibleMSLHashes",
        context_a.get("visibleMSLHashes"),
        context_b.get("visibleMSLHashes"),
        differences,
    )
    compare_values(
        "gputraceSummary.indexHashReferences",
        (context_a.get("gputraceSummary") or {}).get("indexHashReferences"),
        (context_b.get("gputraceSummary") or {}).get("indexHashReferences"),
        differences,
    )

    return {
        "hasComparableSnapshots": True,
        "missingRunA": False,
        "missingRunB": False,
        "runA": context_a,
        "runB": context_b,
        "differences": differences,
    }


def build_report(run_a: RunInput, run_b: RunInput) -> dict[str, Any]:
    events_a = load_jsonl(run_a.manifest_path)
    events_b = load_jsonl(run_b.manifest_path)
    modules_a = build_module_index(run_a)
    modules_b = build_module_index(run_b)
    replacements_a = build_replacement_index(run_a)
    replacements_b = build_replacement_index(run_b)
    snapshot_meta_a = load_snapshot_meta(run_a)
    snapshot_meta_b = load_snapshot_meta(run_b)

    keys_a = set(modules_a)
    keys_b = set(modules_b)
    only_a = sorted(keys_a - keys_b)
    only_b = sorted(keys_b - keys_a)
    shared_differences = compare_shared_modules(modules_a, modules_b)

    return {
        "schemaVersion": 1,
        "runA": {
            "label": run_a.label,
            "manifestPath": str(run_a.manifest_path),
            "modulesDir": str(run_a.modules_dir),
            "summary": summarize_events(events_a),
            "replacementSummary": replacements_a["summary"],
            "snapshotContext": build_snapshot_context(snapshot_meta_a),
        },
        "runB": {
            "label": run_b.label,
            "manifestPath": str(run_b.manifest_path),
            "modulesDir": str(run_b.modules_dir),
            "summary": summarize_events(events_b),
            "replacementSummary": replacements_b["summary"],
            "snapshotContext": build_snapshot_context(snapshot_meta_b),
        },
        "comparison": {
            "onlyInRunA": only_a,
            "onlyInRunB": only_b,
            "sharedModuleCount": len(keys_a & keys_b),
            "sharedModulesWithDifferences": shared_differences,
            "latestReplacementComparison": compare_replacement_runs(replacements_a, replacements_b),
            "snapshotComparison": compare_snapshot_context(snapshot_meta_a, snapshot_meta_b),
            "differenceSummary": {
                "onlyInRunACount": len(only_a),
                "onlyInRunBCount": len(only_b),
                "sharedModulesWithDifferencesCount": len(shared_differences),
                "replacementDifferenceCount": len(compare_replacement_runs(replacements_a, replacements_b)["differences"]),
                "snapshotDifferenceCount": len(compare_snapshot_context(snapshot_meta_a, snapshot_meta_b)["differences"]),
            },
        },
    }


def print_summary(report: dict[str, Any]) -> None:
    run_a = report["runA"]
    run_b = report["runB"]
    comparison = report["comparison"]

    print(f"runA: {run_a['manifestPath']}")
    print(f"runB: {run_b['manifestPath']}")
    print(
        "moduleKey summary: "
        f"shared={comparison['sharedModuleCount']} "
        f"onlyA={comparison['differenceSummary']['onlyInRunACount']} "
        f"onlyB={comparison['differenceSummary']['onlyInRunBCount']} "
        f"changedShared={comparison['differenceSummary']['sharedModulesWithDifferencesCount']}"
    )

    if comparison["onlyInRunA"]:
        print(f"only in runA ({len(comparison['onlyInRunA'])}): {', '.join(comparison['onlyInRunA'][:5])}")
    if comparison["onlyInRunB"]:
        print(f"only in runB ({len(comparison['onlyInRunB'])}): {', '.join(comparison['onlyInRunB'][:5])}")
    if comparison["sharedModulesWithDifferences"]:
        preview = ", ".join(item["moduleKey"] for item in comparison["sharedModulesWithDifferences"][:5])
        print(f"changed shared modules ({len(comparison['sharedModulesWithDifferences'])}): {preview}")
    replacement_comparison = comparison["latestReplacementComparison"]
    if not replacement_comparison["hasComparableReplacement"]:
        missing = []
        if replacement_comparison["missingRunA"]:
            missing.append("runA")
        if replacement_comparison["missingRunB"]:
            missing.append("runB")
        if missing:
            print(f"latest replacement aggregate unavailable for: {', '.join(missing)}")
    elif replacement_comparison["differences"]:
        preview = ", ".join(item["field"] for item in replacement_comparison["differences"][:5])
        print(f"latest replacement aggregate differs ({len(replacement_comparison['differences'])} fields): {preview}")

    snapshot_comparison = comparison["snapshotComparison"]
    if not snapshot_comparison["hasComparableSnapshots"]:
        missing = []
        if snapshot_comparison["missingRunA"]:
            missing.append("runA")
        if snapshot_comparison["missingRunB"]:
            missing.append("runB")
        if missing:
            print(f"snapshot meta unavailable for: {', '.join(missing)}")
    elif snapshot_comparison["differences"]:
        preview = ", ".join(item["field"] for item in snapshot_comparison["differences"][:5])
        print(f"snapshot context differs ({len(snapshot_comparison['differences'])} fields): {preview}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare two ShaderCorpus capture runs for E-006d")
    parser.add_argument("--run-a", required=True, help="run A bundle directory or manifest.jsonl path")
    parser.add_argument("--run-b", required=True, help="run B bundle directory or manifest.jsonl path")
    parser.add_argument("--modules-a", help="optional modules directory override for run A")
    parser.add_argument("--modules-b", help="optional modules directory override for run B")
    parser.add_argument("--output", help="optional JSON output path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_a = resolve_run_input(args.run_a, args.modules_a, "runA")
    run_b = resolve_run_input(args.run_b, args.modules_b, "runB")
    report = build_report(run_a, run_b)
    print_summary(report)

    if args.output:
        output_path = Path(args.output).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"report written to {output_path}")
    else:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        sys.stdout.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
