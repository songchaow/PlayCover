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
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path.home() / "Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics"
DEFAULT_CONTAINER_ROOT = Path.home() / "Library/Containers/io.playcover.PlayCover"
MANIFEST_CORRELATION_GRACE = timedelta(seconds=5)

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
    parser.add_argument(
        "--container-root",
        type=Path,
        default=DEFAULT_CONTAINER_ROOT,
        help="PlayCover container 根目录（用于读取 ShaderCorpus manifest）",
    )
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


def read_manifest_entries(file_path: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    if not file_path.is_file():
        return entries

    for raw_line in file_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            entries.append(payload)
    return entries


def parse_timestamp(value: Any) -> datetime | None:
    if not value:
        return None
    text = str(value)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


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


def summarize_replacement_failure_surfaces(
    *,
    bundle_id: str | None,
    first_timestamp: Any,
    last_timestamp: Any,
    manifest_entries: list[dict[str, Any]],
) -> dict[str, Any]:
    start = parse_timestamp(first_timestamp)
    end = parse_timestamp(last_timestamp)
    if start is None or end is None:
        return {
            "matchedAttemptCount": 0,
            "failureSurfaces": [],
            "failureSurfaceCount": 0,
        }

    failure_surfaces: dict[tuple[str, str, str, str, tuple[str, ...]], dict[str, Any]] = {}
    matched_attempt_count = 0

    for entry in manifest_entries:
        if entry.get("event") != "replacement_attempt":
            continue
        if bundle_id and entry.get("bundleId") not in (None, bundle_id):
            continue
        if str(entry.get("outcome") or "") not in {"failed", "skipped"}:
            continue

        timestamp = parse_timestamp(entry.get("timestamp"))
        if timestamp is None or timestamp < (start - MANIFEST_CORRELATION_GRACE) or timestamp > (end + MANIFEST_CORRELATION_GRACE):
            continue

        module_keys = sorted(str(value) for value in (entry.get("moduleKeys") or []) if value)
        cluster_key = (
            str(entry.get("selector") or ""),
            str(entry.get("cacheKey") or ""),
            str(entry.get("reasonCode") or ""),
            str(entry.get("detail") or ""),
            tuple(module_keys),
        )

        cluster = failure_surfaces.get(cluster_key)
        matched_attempt_count += 1
        timestamp_text = str(entry.get("timestamp") or "")
        if cluster is None:
            failure_surfaces[cluster_key] = {
                "selector": cluster_key[0],
                "cacheKey": cluster_key[1],
                "reasonCode": cluster_key[2],
                "detail": cluster_key[3],
                "moduleKeys": module_keys,
                "moduleKeyCount": len(module_keys),
                "count": 1,
                "firstTimestamp": timestamp_text,
                "lastTimestamp": timestamp_text,
            }
            continue

        cluster["count"] += 1
        cluster["lastTimestamp"] = timestamp_text

    ordered_surfaces = sorted(
        failure_surfaces.values(),
        key=lambda item: (
            -int(item.get("count", 0)),
            str(item.get("lastTimestamp", "")),
            str(item.get("selector", "")),
            str(item.get("cacheKey", "")),
            ",".join(item.get("moduleKeys") or []),
        ),
    )
    return {
        "matchedAttemptCount": matched_attempt_count,
        "failureSurfaces": ordered_surfaces[:10],
        "failureSurfaceCount": len(ordered_surfaces),
    }


def summarize_group(
    process_launch_id: str,
    events: list[dict[str, Any]],
    manifest_entries: list[dict[str, Any]],
) -> dict[str, Any]:
    ordered = sorted(events, key=lambda item: (str(item.get("timestamp", "")), int(item.get("lineNumber", 0))))
    event_names = [str(item.get("event", "")) for item in ordered]
    stages = {stage: stage in event_names for stage in KEY_STAGE_ORDER}
    last_event = ordered[-1] if ordered else {}
    first_event = ordered[0] if ordered else {}
    bundle_id = first_event.get("bundleId") or last_event.get("bundleId")

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
    replacement_surfaces = summarize_replacement_failure_surfaces(
        bundle_id=bundle_id if isinstance(bundle_id, str) else None,
        first_timestamp=first_event.get("timestamp"),
        last_timestamp=last_event.get("timestamp"),
        manifest_entries=manifest_entries,
    )

    return {
        "processLaunchId": process_launch_id,
        "bundleId": bundle_id,
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
        "replacementFailureSurfaces": replacement_surfaces,
    }


def aggregate_replacement_hotspots(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    cluster_aggregates: dict[tuple[str, str, str, str, str], dict[str, Any]] = {}
    surface_aggregates: dict[tuple[str, str, str, str, tuple[str, ...]], dict[str, Any]] = {}

    for summary in summaries:
        process_launch_id = str(summary.get("processLaunchId") or "")

        for cluster in (summary.get("replacement") or {}).get("failureClusters") or []:
            key = (
                str(cluster.get("event") or ""),
                str(cluster.get("selector") or ""),
                str(cluster.get("cacheKey") or ""),
                str(cluster.get("reason") or ""),
                str(cluster.get("compilerMessage") or ""),
            )
            aggregate = cluster_aggregates.get(key)
            if aggregate is None:
                aggregate = {
                    "event": key[0],
                    "selector": key[1],
                    "cacheKey": key[2],
                    "reason": key[3],
                    "compilerMessage": key[4],
                    "occurrenceCount": 0,
                    "runCount": 0,
                    "processLaunchIds": [],
                    "firstTimestamp": cluster.get("firstTimestamp"),
                    "lastTimestamp": cluster.get("lastTimestamp"),
                }
                cluster_aggregates[key] = aggregate
            aggregate["occurrenceCount"] += int(cluster.get("count") or 0)
            aggregate["runCount"] += 1
            if process_launch_id:
                aggregate["processLaunchIds"].append(process_launch_id)
            first_timestamp = str(cluster.get("firstTimestamp") or "")
            last_timestamp = str(cluster.get("lastTimestamp") or "")
            existing_first = str(aggregate.get("firstTimestamp") or "")
            existing_last = str(aggregate.get("lastTimestamp") or "")
            if first_timestamp and (not existing_first or first_timestamp < existing_first):
                aggregate["firstTimestamp"] = first_timestamp
            if last_timestamp and (not existing_last or last_timestamp > existing_last):
                aggregate["lastTimestamp"] = last_timestamp

        for surface in (summary.get("replacementFailureSurfaces") or {}).get("failureSurfaces") or []:
            module_keys = tuple(str(value) for value in (surface.get("moduleKeys") or []) if value)
            key = (
                str(surface.get("selector") or ""),
                str(surface.get("cacheKey") or ""),
                str(surface.get("reasonCode") or ""),
                str(surface.get("detail") or ""),
                module_keys,
            )
            aggregate = surface_aggregates.get(key)
            if aggregate is None:
                aggregate = {
                    "selector": key[0],
                    "cacheKey": key[1],
                    "reasonCode": key[2],
                    "detail": key[3],
                    "moduleKeys": list(module_keys),
                    "moduleKeyCount": len(module_keys),
                    "occurrenceCount": 0,
                    "runCount": 0,
                    "processLaunchIds": [],
                    "firstTimestamp": surface.get("firstTimestamp"),
                    "lastTimestamp": surface.get("lastTimestamp"),
                }
                surface_aggregates[key] = aggregate
            aggregate["occurrenceCount"] += int(surface.get("count") or 0)
            aggregate["runCount"] += 1
            if process_launch_id:
                aggregate["processLaunchIds"].append(process_launch_id)
            first_timestamp = str(surface.get("firstTimestamp") or "")
            last_timestamp = str(surface.get("lastTimestamp") or "")
            existing_first = str(aggregate.get("firstTimestamp") or "")
            existing_last = str(aggregate.get("lastTimestamp") or "")
            if first_timestamp and (not existing_first or first_timestamp < existing_first):
                aggregate["firstTimestamp"] = first_timestamp
            if last_timestamp and (not existing_last or last_timestamp > existing_last):
                aggregate["lastTimestamp"] = last_timestamp

    ordered_clusters = sorted(
        cluster_aggregates.values(),
        key=lambda item: (
            -int(item.get("runCount", 0)),
            -int(item.get("occurrenceCount", 0)),
            str(item.get("lastTimestamp", "")),
            str(item.get("cacheKey", "")),
        ),
    )
    ordered_surfaces = sorted(
        surface_aggregates.values(),
        key=lambda item: (
            -int(item.get("runCount", 0)),
            -int(item.get("occurrenceCount", 0)),
            str(item.get("lastTimestamp", "")),
            str(item.get("cacheKey", "")),
            ",".join(item.get("moduleKeys") or []),
        ),
    )
    return {
        "failureClusters": ordered_clusters[:10],
        "failureClusterCount": len(ordered_clusters),
        "failureSurfaces": ordered_surfaces[:10],
        "failureSurfaceCount": len(ordered_surfaces),
    }


def build_summary(
    events: list[dict[str, Any]],
    limit: int,
    manifest_entries: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        process_launch_id = str(event.get("processLaunchId") or "unknown-process-launch")
        grouped[process_launch_id].append(event)

    summaries = [
        summarize_group(process_launch_id, grouped_events, manifest_entries or [])
        for process_launch_id, grouped_events in grouped.items()
    ]
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

        failure_surfaces = (summary.get("replacementFailureSurfaces") or {}).get("failureSurfaces") or []
        if failure_surfaces:
            print("  replacementFailureSurfaces:")
            for surface in failure_surfaces[:5]:
                rendered = ", ".join(
                    f"{key}={value}"
                    for key, value in surface.items()
                    if value not in (None, "", 0, [])
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

    hotspots = aggregate_replacement_hotspots(summaries)
    cluster_hotspots = hotspots.get("failureClusters") or []
    if cluster_hotspots:
        print("")
        print("crossRunReplacementFailureClusters:")
        for hotspot in cluster_hotspots[:5]:
            rendered = ", ".join(
                f"{key}={value}"
                for key, value in hotspot.items()
                if key != "processLaunchIds" and value not in (None, "", 0, [])
            )
            print(f"  - {rendered}")

    surface_hotspots = hotspots.get("failureSurfaces") or []
    if surface_hotspots:
        print("crossRunReplacementFailureSurfaces:")
        for hotspot in surface_hotspots[:5]:
            rendered = ", ".join(
                f"{key}={value}"
                for key, value in hotspot.items()
                if key != "processLaunchIds" and value not in (None, "", 0, [])
            )
            print(f"  - {rendered}")


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
    manifest_path = args.container_root / "ShaderCorpus" / args.bundle_id / "manifest.jsonl"
    events = read_events(file_path)
    manifest_entries = read_manifest_entries(manifest_path)
    summaries = build_summary(events, args.limit, manifest_entries)

    payload = {
        "root": str(args.root),
        "containerRoot": str(args.container_root),
        "bundleId": args.bundle_id,
        "file": str(file_path),
        "manifestFile": str(manifest_path),
        "summaryCount": len(summaries),
        "replacementHotspots": aggregate_replacement_hotspots(summaries),
        "runs": summaries,
    }

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_human_summary(args.bundle_id, summaries)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
