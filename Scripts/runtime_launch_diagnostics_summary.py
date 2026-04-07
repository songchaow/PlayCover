#!/usr/bin/env python3
"""
汇总 PlayTools runtime 启动期 breadcrumb，帮助判断 fresh 注入后是否进入
`PlayCover.launch()` / `BridgeListener.start()` / registration retry 路径。

默认读取:
  ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics

示例:
  python3 Scripts/runtime_launch_diagnostics_summary.py --list-bundles
  python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.miHoYo.Yuanshen
  python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.miHoYo.Yuanshen --limit 5 --json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path.home() / "Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics"

KEY_STAGE_ORDER = [
    "playcover_launch_enter",
    "playcover_capture_library_preload_checked",
    "playcover_library_injection_installed",
    "playcover_bridge_listener_start_requested",
    "bridge_listener_starting",
    "bridge_listener_command_listener_ready",
    "bridge_registration_attempt_started",
    "bridge_registration_established",
]

REPLACEMENT_EVENT_NAMES = {
    "replacement_attempt_started",
    "replacement_attempt_skipped",
    "replacement_modules_prepared",
    "replacement_preflight_rejected",
    "replacement_compile_started",
    "replacement_compile_failed",
    "replacement_succeeded",
    "replacement_exception",
}

REPLACEMENT_FAILURE_EVENT_NAMES = {
    "replacement_attempt_skipped",
    "replacement_preflight_rejected",
    "replacement_compile_failed",
    "replacement_exception",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="汇总 runtime launch diagnostics JSONL")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="diagnostics 根目录")
    parser.add_argument("--bundle-id", help="目标 bundleId；省略时需配合 --list-bundles")
    parser.add_argument("--limit", type=int, default=3, help="输出最近多少个 processLaunchId")
    parser.add_argument("--json", action="store_true", help="输出 JSON 摘要")
    parser.add_argument("--list-bundles", action="store_true", help="列出已有 bundleId")
    return parser.parse_args()


def list_bundles(root: Path) -> list[str]:
    if not root.is_dir():
        return []
    return sorted(child.name for child in root.iterdir() if child.is_dir())


def read_events(file_path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    if not file_path.is_file():
        return events

    for line_number, raw_line in enumerate(file_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            events.append(
                {
                    "event": "__decode_error__",
                    "timestamp": "",
                    "lineNumber": line_number,
                    "message": str(exc),
                }
            )
            continue
        if isinstance(payload, dict):
            payload.setdefault("lineNumber", line_number)
            events.append(payload)
    return events


def summarize_replacement_activity(events: list[dict[str, Any]]) -> dict[str, Any]:
    counts: dict[str, int] = defaultdict(int)
    failure_clusters: dict[tuple[str, str, str, str], dict[str, Any]] = {}

    for event in events:
        event_name = str(event.get("event", ""))
        if event_name not in REPLACEMENT_EVENT_NAMES:
            continue
        counts[event_name] += 1

        if event_name not in REPLACEMENT_FAILURE_EVENT_NAMES:
            continue

        selector = str(event.get("selector") or "")
        cache_key = str(event.get("cacheKey") or "")
        reason = str(event.get("reason") or "")
        compiler_message = str(event.get("compilerMessage") or event.get("error") or event.get("issueSummary") or "")
        cluster_key = (event_name, selector, cache_key, compiler_message)
        timestamp = str(event.get("timestamp") or "")

        cluster = failure_clusters.get(cluster_key)
        if cluster is None:
            failure_clusters[cluster_key] = {
                "event": event_name,
                "selector": selector,
                "cacheKey": cache_key,
                "reason": reason,
                "compilerMessage": compiler_message,
                "count": 1,
                "firstTimestamp": timestamp,
                "lastTimestamp": timestamp,
            }
            continue

        cluster["count"] += 1
        cluster["lastTimestamp"] = timestamp

    ordered_failures = sorted(
        failure_clusters.values(),
        key=lambda item: (
            -int(item.get("count", 0)),
            str(item.get("lastTimestamp", "")),
            str(item.get("selector", "")),
            str(item.get("cacheKey", "")),
        ),
    )

    return {
        "counts": dict(sorted(counts.items())),
        "failureCount": sum(counts.get(name, 0) for name in REPLACEMENT_FAILURE_EVENT_NAMES),
        "failureClusters": ordered_failures[:10],
        "failureClusterCount": len(ordered_failures),
    }


def summarize_group(process_launch_id: str, events: list[dict[str, Any]]) -> dict[str, Any]:
    ordered = sorted(events, key=lambda item: (str(item.get("timestamp", "")), int(item.get("lineNumber", 0))))
    event_names = [str(item.get("event", "")) for item in ordered]
    stages = {stage: stage in event_names for stage in KEY_STAGE_ORDER}
    last_event = ordered[-1] if ordered else {}
    first_event = ordered[0] if ordered else {}

    noteworthy_failures = [
        {
            "timestamp": event.get("timestamp"),
            "event": event.get("event"),
            "error": event.get("error"),
            "reason": event.get("reason"),
            "trigger": event.get("trigger"),
        }
        for event in ordered
        if any(
            marker in str(event.get("event", ""))
            for marker in ("failed", "lost", "incomplete")
        )
    ]
    replacement_activity = summarize_replacement_activity(ordered)

    return {
        "processLaunchId": process_launch_id,
        "bundleId": first_event.get("bundleId") or last_event.get("bundleId"),
        "pid": first_event.get("pid") or last_event.get("pid"),
        "eventCount": len(ordered),
        "firstTimestamp": first_event.get("timestamp"),
        "lastTimestamp": last_event.get("timestamp"),
        "lastEvent": last_event.get("event"),
        "lastDetails": {
            key: value
            for key, value in last_event.items()
            if key not in {"schemaVersion", "timestamp", "event", "bundleId", "pid", "processLaunchId", "lineNumber", "isMainThread"}
        },
        "stages": stages,
        "noteworthyFailures": noteworthy_failures[-5:],
        "replacement": replacement_activity,
    }


def build_summary(events: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        process_launch_id = str(event.get("processLaunchId") or "unknown-process-launch")
        grouped[process_launch_id].append(event)

    summaries = [summarize_group(process_launch_id, grouped_events) for process_launch_id, grouped_events in grouped.items()]
    summaries.sort(key=lambda item: str(item.get("lastTimestamp", "")), reverse=True)
    return summaries[: max(limit, 1)]


def print_human_summary(bundle_id: str, summaries: list[dict[str, Any]]) -> None:
    print(f"bundleId: {bundle_id}")
    if not summaries:
        print("未找到任何 launch diagnostics 事件。")
        return

    for index, summary in enumerate(summaries, start=1):
        print("")
        print(f"[{index}] processLaunchId={summary['processLaunchId']}")
        print(f"  pid={summary.get('pid')}  events={summary.get('eventCount')}")
        print(f"  first={summary.get('firstTimestamp')}")
        print(f"  last ={summary.get('lastTimestamp')}  ({summary.get('lastEvent')})")

        stages = summary.get("stages", {})
        reached = [name for name in KEY_STAGE_ORDER if stages.get(name)]
        missing = [name for name in KEY_STAGE_ORDER if not stages.get(name)]
        print(f"  reachedStages={', '.join(reached) if reached else '(none)'}")
        if missing:
            print(f"  missingStages={', '.join(missing)}")

        last_details = summary.get("lastDetails") or {}
        if last_details:
            rendered = ", ".join(f"{key}={value}" for key, value in sorted(last_details.items()))
            print(f"  lastDetails={rendered}")

        replacement = summary.get("replacement") or {}
        replacement_counts = replacement.get("counts") or {}
        if replacement_counts:
            rendered_counts = ", ".join(
                f"{key}={value}" for key, value in sorted(replacement_counts.items())
            )
            print(f"  replacementCounts={rendered_counts}")

        failure_clusters = replacement.get("failureClusters") or []
        if failure_clusters:
            print("  replacementFailureClusters:")
            for cluster in failure_clusters[:5]:
                rendered = ", ".join(
                    f"{key}={value}"
                    for key, value in cluster.items()
                    if value not in (None, "", 0)
                )
                print(f"    - {rendered}")

        failures = summary.get("noteworthyFailures") or []
        if failures:
            print("  recentFailures:")
            for failure in failures:
                rendered = ", ".join(
                    f"{key}={value}"
                    for key, value in failure.items()
                    if value not in (None, "")
                )
                print(f"    - {rendered}")


def main() -> int:
    args = parse_args()

    if args.list_bundles:
        bundles = list_bundles(args.root)
        if args.json:
            print(json.dumps({"root": str(args.root), "bundles": bundles}, ensure_ascii=False, indent=2))
        else:
            print(f"root: {args.root}")
            if bundles:
                for bundle in bundles:
                    print(bundle)
            else:
                print("(no bundles found)")
        return 0

    if not args.bundle_id:
        print("缺少 --bundle-id；或使用 --list-bundles 查看可用 bundle。", file=sys.stderr)
        return 2

    file_path = args.root / args.bundle_id / "launch-events.jsonl"
    events = read_events(file_path)
    summaries = build_summary(events, args.limit)

    payload = {
        "root": str(args.root),
        "bundleId": args.bundle_id,
        "file": str(file_path),
        "summaryCount": len(summaries),
        "runs": summaries,
    }

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_human_summary(args.bundle_id, summaries)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
