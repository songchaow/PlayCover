#!/usr/bin/env python3
"""
snapshot_capture_run.py — 固化当前 ShaderCorpus/diagnostics/app settings 为单次 run 快照，辅助 E-006d 对照。

示例：
    python3 Scripts/snapshot_capture_run.py \
        --bundle-id com.miHoYo.Yuanshen \
        --label replacement-off-run1

    python3 Scripts/snapshot_capture_run.py \
        --bundle-id com.miHoYo.Yuanshen \
        --label replacement-on-run1 \
        --gputrace ~/captures/replacement-on-run1.gputrace \
        --output-root build/e006d-run-snapshots \
        --print-compare-path
"""

from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from gputrace_attribution import build_gputrace_attribution
from gputrace_sources import inspect_gputrace_dir
from runtime_launch_diagnostics_summary import (
    DEFAULT_ROOT as DEFAULT_RUNTIME_LAUNCH_DIAGNOSTICS_ROOT,
    KEY_STAGE_ORDER,
    aggregate_replacement_hotspots,
    build_summary,
    read_events,
    read_manifest_entries,
)


DEFAULT_CONTAINER = Path.home() / "Library/Containers/io.playcover.PlayCover"
DEFAULT_OUTPUT_ROOT = Path("build/e006d-run-snapshots")
SETTINGS_KEY = "shaderSourceReplacementEnabled"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Snapshot one PlayCover ShaderCorpus run for later E-006d comparison"
    )
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument(
        "--label",
        required=True,
        help="snapshot label; output will be <output-root>/<label>/<bundle-id>",
    )
    parser.add_argument(
        "--container",
        default=str(DEFAULT_CONTAINER),
        help="PlayCover container root (default: ~/Library/Containers/io.playcover.PlayCover)",
    )
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="snapshot root directory (default: build/e006d-run-snapshots)",
    )
    parser.add_argument(
        "--skip-diagnostics",
        action="store_true",
        help="do not copy ShaderSourceDiagnostics/<bundle-id> into the snapshot",
    )
    parser.add_argument(
        "--print-compare-path",
        action="store_true",
        help="print the bundle snapshot path suitable for compare_capture_runs.py",
    )
    parser.add_argument(
        "--gputrace",
        help="optional .gputrace directory to preserve alongside the run snapshot",
    )
    parser.add_argument(
        "--capture-target",
        choices=("device", "scope", "queue", "queue_scope"),
        help="optional capture target metadata for this run snapshot",
    )
    parser.add_argument(
        "--diagnostics-root",
        default=str(DEFAULT_RUNTIME_LAUNCH_DIAGNOSTICS_ROOT),
        help="RuntimeLaunchDiagnostics root (default: ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics)",
    )
    parser.add_argument(
        "--launch-summary-limit",
        type=int,
        default=5,
        help="how many recent processLaunchId groups to preserve in the snapshot (default: 5)",
    )
    parser.add_argument(
        "--skip-launch-diagnostics",
        action="store_true",
        help="do not copy launch-events.jsonl or compute runtime launch diagnostics summaries",
    )
    return parser.parse_args()


def count_nonempty_lines(path: Path) -> int:
    count = 0
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            if raw_line.strip():
                count += 1
    return count


def count_child_directories(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(1 for child in path.iterdir() if child.is_dir())


def count_child_entries(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for _ in path.iterdir())


def load_settings_payload(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit(f"unexpected plist root type at {path}")
    return payload


def copy_required_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"required file not found: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_optional_directory(source: Path, destination: Path) -> bool:
    if not source.is_dir():
        return False
    shutil.copytree(source, destination)
    return True


def build_launch_summary_lines(bundle_id: str, summaries: list[dict[str, Any]]) -> list[str]:
    lines = [f"bundleId: {bundle_id}"]
    if not summaries:
        lines.append("no launch diagnostics events found")
        return lines

    for index, summary in enumerate(summaries, start=1):
        lines.append("")
        lines.append(f"[{index}] processLaunchId={summary.get('processLaunchId')}")
        lines.append(
            f"  lastEvent={summary.get('lastEvent')} eventCount={summary.get('eventCount')} pid={summary.get('pid')}"
        )
        lines.append(f"  first={summary.get('firstTimestamp')}")
        lines.append(f"  last ={summary.get('lastTimestamp')}")
        reached = [name for name in KEY_STAGE_ORDER if summary.get("stages", {}).get(name)]
        missing = [name for name in KEY_STAGE_ORDER if not summary.get("stages", {}).get(name)]
        lines.append(f"  reachedStages={', '.join(reached) if reached else '(none)'}")
        if missing:
            lines.append(f"  missingStages={', '.join(missing)}")

        launch_settings = summary.get("launchSettings") or {}
        if launch_settings:
            rendered_settings = ", ".join(
                f"{key}={value}" for key, value in sorted(launch_settings.items())
            )
            lines.append(f"  launchSettings={rendered_settings}")

        replacement_counts = (summary.get("replacement") or {}).get("counts") or {}
        if replacement_counts:
            rendered_counts = ", ".join(
                f"{key}={value}" for key, value in sorted(replacement_counts.items())
            )
            lines.append(f"  replacementCounts={rendered_counts}")

    return lines


def main() -> int:
    args = parse_args()
    container = Path(args.container).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    diagnostics_root = Path(args.diagnostics_root).expanduser().resolve()

    corpus_bundle_dir = container / "ShaderCorpus" / args.bundle_id
    diagnostics_bundle_dir = container / "ShaderSourceDiagnostics" / args.bundle_id
    settings_path = container / "App Settings" / f"{args.bundle_id}.plist"
    launch_events_path = diagnostics_root / args.bundle_id / "launch-events.jsonl"

    manifest_path = corpus_bundle_dir / "manifest.jsonl"
    modules_dir = corpus_bundle_dir / "modules"
    replacements_dir = corpus_bundle_dir / "replacements"

    if not corpus_bundle_dir.is_dir():
        raise SystemExit(f"ShaderCorpus bundle directory not found: {corpus_bundle_dir}")
    if not manifest_path.is_file():
        raise SystemExit(f"manifest not found: {manifest_path}")
    if not modules_dir.is_dir():
        raise SystemExit(f"modules directory not found: {modules_dir}")

    snapshot_bundle_dir = output_root / args.label / args.bundle_id
    if snapshot_bundle_dir.exists():
        raise SystemExit(f"snapshot destination already exists: {snapshot_bundle_dir}")

    settings_payload = load_settings_payload(settings_path)
    gputrace_path = Path(args.gputrace).expanduser().resolve() if args.gputrace else None
    gputrace_summary = inspect_gputrace_dir(gputrace_path) if gputrace_path is not None else None

    copy_required_file(manifest_path, snapshot_bundle_dir / "manifest.jsonl")
    shutil.copytree(modules_dir, snapshot_bundle_dir / "modules")
    replacements_copied = copy_optional_directory(replacements_dir, snapshot_bundle_dir / "replacements")
    diagnostics_copied = False
    if not args.skip_diagnostics:
        diagnostics_copied = copy_optional_directory(diagnostics_bundle_dir, snapshot_bundle_dir / "diagnostics")
    if settings_payload is not None:
        copy_required_file(settings_path, snapshot_bundle_dir / "app-settings" / settings_path.name)

    launch_events_copied = False
    launch_events: list[dict[str, Any]] = []
    launch_summaries: list[dict[str, Any]] = []
    launch_summary_text_path = None
    launch_summary_json_path = None
    replacement_hotspots: dict[str, Any] = {
        "failureClusterCount": 0,
        "failureClusters": [],
        "failureSurfaceCount": 0,
        "failureSurfaces": [],
    }
    if not args.skip_launch_diagnostics:
        launch_events = read_events(launch_events_path)
        manifest_entries = read_manifest_entries(manifest_path)
        launch_summaries = build_summary(launch_events, max(args.launch_summary_limit, 1), manifest_entries)
        replacement_hotspots = aggregate_replacement_hotspots(launch_summaries)
        if launch_events_path.is_file():
            launch_events_relative_path = Path("runtime-launch-diagnostics") / "launch-events.jsonl"
            copy_required_file(launch_events_path, snapshot_bundle_dir / launch_events_relative_path)
            launch_events_copied = True
        launch_summary_json_path = Path("runtime-launch-diagnostics") / "launch-summary.json"
        (snapshot_bundle_dir / launch_summary_json_path).parent.mkdir(parents=True, exist_ok=True)
        (snapshot_bundle_dir / launch_summary_json_path).write_text(
            json.dumps(
                {
                    "bundleId": args.bundle_id,
                    "summaryCount": len(launch_summaries),
                    "runs": launch_summaries,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        launch_summary_text_path = Path("runtime-launch-diagnostics") / "launch-summary.txt"
        (snapshot_bundle_dir / launch_summary_text_path).write_text(
            "\n".join(build_launch_summary_lines(args.bundle_id, launch_summaries)) + "\n",
            encoding="utf-8",
        )

    gputrace_relative_path = None
    gputrace_attribution = None
    if gputrace_path is not None:
        gputrace_relative_path = f"gputrace/{gputrace_path.name}"
        shutil.copytree(gputrace_path, snapshot_bundle_dir / gputrace_relative_path)
        gputrace_summary_path = snapshot_bundle_dir / "gputrace-source-summary.json"
        gputrace_summary_path.write_text(
            json.dumps(gputrace_summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        gputrace_attribution = build_gputrace_attribution(snapshot_bundle_dir, gputrace_relative_path, gputrace_summary)
        if gputrace_attribution is not None:
            attribution_path = snapshot_bundle_dir / "gputrace-attribution-index.json"
            attribution_path.write_text(
                json.dumps(gputrace_attribution, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    latest_launch_summary = launch_summaries[0] if launch_summaries else None
    snapshot_meta = {
        "schemaVersion": 3,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "bundleId": args.bundle_id,
        "label": args.label,
        "captureTarget": args.capture_target,
        "containerRoot": str(container),
        "snapshotBundleDir": str(snapshot_bundle_dir),
        "replacementMode": {
            "settingsPath": str(settings_path),
            "settingsFound": settings_payload is not None,
            "settingsKey": SETTINGS_KEY,
            "enabled": settings_payload.get(SETTINGS_KEY) if settings_payload is not None else None,
        },
        "copiedArtifacts": {
            "manifestPath": "manifest.jsonl",
            "modulesPath": "modules",
            "replacementsPath": "replacements" if replacements_copied else None,
            "diagnosticsPath": "diagnostics" if diagnostics_copied else None,
            "settingsPath": f"app-settings/{settings_path.name}" if settings_payload is not None else None,
            "launchEventsPath": "runtime-launch-diagnostics/launch-events.jsonl" if launch_events_copied else None,
            "launchSummaryJsonPath": str(launch_summary_json_path) if launch_summary_json_path is not None else None,
            "launchSummaryTextPath": str(launch_summary_text_path) if launch_summary_text_path is not None else None,
            "gputracePath": gputrace_relative_path,
            "gputraceSourceSummaryPath": "gputrace-source-summary.json" if gputrace_summary is not None else None,
            "gputraceAttributionIndexPath": "gputrace-attribution-index.json" if gputrace_attribution is not None else None,
        },
        "sourceSummary": {
            "manifestLineCount": count_nonempty_lines(manifest_path),
            "moduleDirectoryCount": count_child_directories(modules_dir),
            "replacementDirectoryCount": count_child_directories(replacements_dir),
            "diagnosticEntryCount": count_child_entries(diagnostics_bundle_dir),
        },
        "launchDiagnostics": {
            "eventCount": len(launch_events),
            "summaryCount": len(launch_summaries),
            "processLaunchIds": [
                summary.get("processLaunchId") for summary in launch_summaries if summary.get("processLaunchId")
            ],
            "latestLastEvent": latest_launch_summary.get("lastEvent") if latest_launch_summary else None,
            "latestLaunchSettings": latest_launch_summary.get("launchSettings") if latest_launch_summary else {},
            "latestReachedStages": [
                stage for stage in KEY_STAGE_ORDER if latest_launch_summary and latest_launch_summary.get("stages", {}).get(stage)
            ],
            "latestMissingStages": [
                stage for stage in KEY_STAGE_ORDER if not latest_launch_summary or not latest_launch_summary.get("stages", {}).get(stage)
            ],
            "latestFailureCount": len(latest_launch_summary.get("noteworthyFailures") or []) if latest_launch_summary else 0,
            "latestReplacementCounts": (latest_launch_summary.get("replacement") or {}).get("counts", {}) if latest_launch_summary else {},
            "aggregatedReplacementFailureClusterCount": replacement_hotspots.get("failureClusterCount", 0),
            "aggregatedReplacementFailureSurfaceCount": replacement_hotspots.get("failureSurfaceCount", 0),
        },
        "gputraceSummary": gputrace_summary,
        "gputraceAttribution": {
            "visibleMSLFileCount": gputrace_attribution.get("visibleMSLFileCount") if gputrace_attribution is not None else None,
            "referencedVisibleMSLFileCount": gputrace_attribution.get("referencedVisibleMSLFileCount") if gputrace_attribution is not None else None,
            "attributedVisibleMSLHashes": gputrace_attribution.get("attributedVisibleMSLHashes") if gputrace_attribution is not None else [],
            "unattributedVisibleMSLHashes": gputrace_attribution.get("unattributedVisibleMSLHashes") if gputrace_attribution is not None else [],
            "attributedReferencedMSLHashes": gputrace_attribution.get("attributedReferencedMSLHashes") if gputrace_attribution is not None else [],
            "unattributedReferencedMSLHashes": gputrace_attribution.get("unattributedReferencedMSLHashes") if gputrace_attribution is not None else [],
            "attributedModuleKeys": gputrace_attribution.get("attributedModuleKeys") if gputrace_attribution is not None else [],
            "attributedReplacementDirectories": gputrace_attribution.get("attributedReplacementDirectories") if gputrace_attribution is not None else [],
        },
    }
    meta_path = snapshot_bundle_dir / "snapshot.meta.json"
    meta_path.write_text(json.dumps(snapshot_meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"snapshot created: {snapshot_bundle_dir}")
    print(
        "summary: "
        f"manifestLines={snapshot_meta['sourceSummary']['manifestLineCount']} "
        f"modules={snapshot_meta['sourceSummary']['moduleDirectoryCount']} "
        f"replacements={snapshot_meta['sourceSummary']['replacementDirectoryCount']} "
        f"diagnostics={snapshot_meta['sourceSummary']['diagnosticEntryCount']} "
        f"launchSummaries={snapshot_meta['launchDiagnostics']['summaryCount']} "
        f"replacementEnabled={snapshot_meta['replacementMode']['enabled']} "
        f"captureTarget={snapshot_meta['captureTarget'] or 'unspecified'} "
        f"gputraceMSL={snapshot_meta['gputraceSummary']['validMSLFiles'] if snapshot_meta['gputraceSummary'] else 'n/a'}"
    )
    if args.print_compare_path:
        print(snapshot_bundle_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
