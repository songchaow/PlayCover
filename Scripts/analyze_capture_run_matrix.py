#!/usr/bin/env python3
"""
analyze_capture_run_matrix.py — 汇总多轮 E-006d run 快照，回答“同模式是否稳定 / 开关切换是否稳定不同”。

示例：
    python3 Scripts/analyze_capture_run_matrix.py \
        --runs-root build/e006d-run-snapshots \
        --bundle-id com.miHoYo.Yuanshen

    python3 Scripts/analyze_capture_run_matrix.py \
        --run build/e006d-run-snapshots/replacement-off-run1/com.miHoYo.Yuanshen \
        --run build/e006d-run-snapshots/replacement-off-run2/com.miHoYo.Yuanshen \
        --run build/e006d-run-snapshots/replacement-on-run1/com.miHoYo.Yuanshen \
        --run build/e006d-run-snapshots/replacement-on-run2/com.miHoYo.Yuanshen \
        --output build/e006d-run-matrix.json
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from pathlib import Path
from typing import Any

from compare_capture_runs import build_report, load_snapshot_meta, resolve_run_input


BENIGN_META_SUMMARY_FIELDS = {"captureCount", "sourceCacheKeys"}
BENIGN_REPLACEMENT_FIELDS = {"cacheKey", "aggregateSourcePath"}
BENIGN_SNAPSHOT_FIELDS = {"replacementMode.enabled"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze multiple E-006d run snapshots across replacement on/off modes"
    )
    parser.add_argument(
        "--run",
        action="append",
        default=[],
        help="bundle snapshot directory or manifest.jsonl path; may be passed multiple times",
    )
    parser.add_argument(
        "--runs-root",
        help="snapshot root containing <label>/<bundle-id> directories (for example build/e006d-run-snapshots)",
    )
    parser.add_argument(
        "--bundle-id",
        help="required with --runs-root; selects <runs-root>/*/<bundle-id> snapshots",
    )
    parser.add_argument("--output", help="optional JSON output path")
    return parser.parse_args()


def resolve_runs(args: argparse.Namespace) -> list[Path]:
    run_paths = [Path(raw_path).expanduser().resolve() for raw_path in args.run]

    if args.runs_root:
        runs_root = Path(args.runs_root).expanduser().resolve()
        if not runs_root.is_dir():
            raise SystemExit(f"runs root not found: {runs_root}")
        if not args.bundle_id:
            raise SystemExit("--bundle-id is required when using --runs-root")
        discovered = sorted(
            candidate for candidate in runs_root.glob(f"*/{args.bundle_id}") if candidate.is_dir()
        )
        run_paths.extend(discovered)

    deduped: list[Path] = []
    seen: set[Path] = set()
    for run_path in run_paths:
        if run_path in seen:
            continue
        seen.add(run_path)
        deduped.append(run_path)

    if len(deduped) < 2:
        raise SystemExit("at least two runs are required")

    return deduped


def normalize_mode(meta: dict[str, Any] | None) -> str:
    enabled = ((meta or {}).get("replacementMode") or {}).get("enabled")
    if enabled is True:
        return "on"
    if enabled is False:
        return "off"
    return "unknown"


def classify_pair(report: dict[str, Any]) -> dict[str, Any]:
    comparison = report["comparison"]
    diff_summary = comparison["differenceSummary"]
    replacement_comparison = comparison["latestReplacementComparison"]
    snapshot_comparison = comparison["snapshotComparison"]

    semantic_shared_differences: list[dict[str, Any]] = []
    for item in comparison["sharedModulesWithDifferences"]:
        semantic_differences: list[dict[str, Any]] = []
        for diff in item.get("differences", []):
            field = diff.get("field")
            if field != "metaSummary":
                semantic_differences.append(diff)
                continue
            left_meta = diff.get("runA") if isinstance(diff.get("runA"), dict) else {}
            right_meta = diff.get("runB") if isinstance(diff.get("runB"), dict) else {}
            for meta_field in sorted(set(left_meta) | set(right_meta)):
                if meta_field in BENIGN_META_SUMMARY_FIELDS:
                    continue
                if left_meta.get(meta_field) != right_meta.get(meta_field):
                    semantic_differences.append(
                        {
                            "field": f"metaSummary.{meta_field}",
                            "runA": left_meta.get(meta_field),
                            "runB": right_meta.get(meta_field),
                        }
                    )
        if semantic_differences:
            semantic_shared_differences.append(
                {
                    "moduleKey": item.get("moduleKey"),
                    "eventCount": item.get("eventCount"),
                    "timestamps": item.get("timestamps"),
                    "differences": semantic_differences,
                }
            )

    semantic_replacement_differences = [
        item
        for item in replacement_comparison["differences"]
        if item.get("field") not in BENIGN_REPLACEMENT_FIELDS
    ]
    semantic_snapshot_differences = [
        item
        for item in snapshot_comparison["differences"]
        if item.get("field") not in BENIGN_SNAPSHOT_FIELDS
    ]

    input_stable = (
        diff_summary["onlyInRunACount"] == 0
        and diff_summary["onlyInRunBCount"] == 0
        and len(semantic_shared_differences) == 0
    )
    replacement_stable = (
        replacement_comparison["hasComparableReplacement"]
        and len(semantic_replacement_differences) == 0
    )
    snapshot_stable = (
        snapshot_comparison["hasComparableSnapshots"]
        and len(semantic_snapshot_differences) == 0
    )
    any_difference = (
        diff_summary["onlyInRunACount"] > 0
        or diff_summary["onlyInRunBCount"] > 0
        or len(semantic_shared_differences) > 0
        or len(semantic_replacement_differences) > 0
        or len(semantic_snapshot_differences) > 0
    )

    return {
        "inputStable": input_stable,
        "replacementStable": replacement_stable,
        "snapshotStable": snapshot_stable,
        "anyDifference": any_difference,
        "semanticSharedModuleDifferenceCount": len(semantic_shared_differences),
        "semanticReplacementDifferenceCount": len(semantic_replacement_differences),
        "semanticSnapshotDifferenceCount": len(semantic_snapshot_differences),
    }


def summarize_pairs(pair_reports: list[dict[str, Any]]) -> dict[str, Any]:
    if not pair_reports:
        return {
            "pairCount": 0,
            "allPairsInputStable": None,
            "allPairsReplacementStable": None,
            "allPairsSnapshotStable": None,
            "allPairsDifferent": None,
            "stablePairCount": 0,
            "differentPairCount": 0,
        }

    classifications = [classify_pair(pair_report["report"]) for pair_report in pair_reports]
    return {
        "pairCount": len(pair_reports),
        "allPairsInputStable": all(item["inputStable"] for item in classifications),
        "allPairsReplacementStable": all(item["replacementStable"] for item in classifications),
        "allPairsSnapshotStable": all(item["snapshotStable"] for item in classifications),
        "allPairsDifferent": all(item["anyDifference"] for item in classifications),
        "stablePairCount": sum(1 for item in classifications if item["inputStable"]),
        "differentPairCount": sum(1 for item in classifications if item["anyDifference"]),
    }


def build_pair_entry(run_a: Path, run_b: Path) -> dict[str, Any]:
    resolved_a = resolve_run_input(str(run_a), None, "runA")
    resolved_b = resolve_run_input(str(run_b), None, "runB")
    report = build_report(resolved_a, resolved_b)
    return {
        "runA": str(run_a),
        "runB": str(run_b),
        "report": report,
        "classification": classify_pair(report),
    }


def build_report_matrix(run_paths: list[Path]) -> dict[str, Any]:
    run_entries: list[dict[str, Any]] = []
    grouped_runs: dict[str, list[Path]] = {"on": [], "off": [], "unknown": []}

    for run_path in run_paths:
        resolved = resolve_run_input(str(run_path), None, run_path.name)
        meta = load_snapshot_meta(resolved)
        mode = normalize_mode(meta)
        grouped_runs[mode].append(run_path)
        run_entries.append(
            {
                "path": str(run_path),
                "label": (meta or {}).get("label") if isinstance(meta, dict) else None,
                "mode": mode,
                "hasSnapshotMeta": meta is not None,
            }
        )

    within_mode_pairs: dict[str, list[dict[str, Any]]] = {}
    for mode, grouped in grouped_runs.items():
        within_mode_pairs[mode] = [
            build_pair_entry(run_a, run_b) for run_a, run_b in itertools.combinations(grouped, 2)
        ]

    cross_mode_pairs = [
        build_pair_entry(run_a, run_b)
        for run_a in grouped_runs["off"]
        for run_b in grouped_runs["on"]
    ]

    return {
        "schemaVersion": 1,
        "runCount": len(run_entries),
        "runs": run_entries,
        "groups": {
            mode: {
                "runCount": len(grouped_runs[mode]),
                "runs": [str(path) for path in grouped_runs[mode]],
                "pairSummary": summarize_pairs(within_mode_pairs[mode]),
                "pairs": within_mode_pairs[mode],
            }
            for mode in ("off", "on", "unknown")
        },
        "crossMode": {
            "offVsOnPairSummary": summarize_pairs(cross_mode_pairs),
            "pairs": cross_mode_pairs,
        },
    }


def print_summary(report: dict[str, Any]) -> None:
    print(f"runs: {report['runCount']}")
    for mode in ("off", "on", "unknown"):
        group = report["groups"][mode]
        summary = group["pairSummary"]
        print(
            f"mode={mode}: runs={group['runCount']} pairs={summary['pairCount']} "
            f"allInputStable={summary['allPairsInputStable']} "
            f"allReplacementStable={summary['allPairsReplacementStable']} "
            f"allSnapshotStable={summary['allPairsSnapshotStable']}"
        )

    cross_summary = report["crossMode"]["offVsOnPairSummary"]
    print(
        "off-vs-on: "
        f"pairs={cross_summary['pairCount']} "
        f"allPairsDifferent={cross_summary['allPairsDifferent']} "
        f"differentPairCount={cross_summary['differentPairCount']}"
    )


def main() -> int:
    args = parse_args()
    run_paths = resolve_runs(args)
    report = build_report_matrix(run_paths)
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
