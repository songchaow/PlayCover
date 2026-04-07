#!/usr/bin/env python3
"""
e006g_launch_matrix_runner.py — 固化 恋与深空 E-006g1 五象限启动矩阵。

示例：
    python3 Scripts/e006g_launch_matrix_runner.py prepare-case \
        --bundle-id com.papegames.lysk \
        --case C

    python3 Scripts/e006g_launch_matrix_runner.py finalize-case \
        --bundle-id com.papegames.lysk \
        --case E

    python3 Scripts/e006g_launch_matrix_runner.py analyze \
        --bundle-id com.papegames.lysk
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

from runtime_launch_diagnostics_summary import (  # noqa: E402
    DEFAULT_ROOT as DEFAULT_DIAGNOSTICS_ROOT,
    aggregate_replacement_hotspots,
    build_summary,
    read_events,
    read_manifest_entries,
)


DEFAULT_CONTAINER = Path.home() / "Library/Containers/io.playcover.PlayCover"
DEFAULT_OUTPUT_ROOT = Path("build/e006g-launch-matrix")
DEFAULT_MANIFEST_EVENT_LIMIT = 12
METAL_CAPTURE_KEY = "metalCaptureEnabled"
INJECT_CAPTURE_ENVIRONMENT_KEY = "injectMetalCaptureEnvironment"
SHADER_REPLACEMENT_KEY = "shaderSourceReplacementEnabled"
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

CASE_DEFINITIONS = {
    "A": {
        "label": "case-a-capture-off-startup-injection-off-replacement-off",
        METAL_CAPTURE_KEY: False,
        INJECT_CAPTURE_ENVIRONMENT_KEY: False,
        SHADER_REPLACEMENT_KEY: False,
        "purpose": "baseline",
    },
    "B": {
        "label": "case-b-capture-on-startup-injection-off-replacement-off",
        METAL_CAPTURE_KEY: True,
        INJECT_CAPTURE_ENVIRONMENT_KEY: False,
        SHADER_REPLACEMENT_KEY: False,
        "purpose": "delayed-capture-only",
    },
    "C": {
        "label": "case-c-capture-on-startup-injection-on-replacement-off",
        METAL_CAPTURE_KEY: True,
        INJECT_CAPTURE_ENVIRONMENT_KEY: True,
        SHADER_REPLACEMENT_KEY: False,
        "purpose": "startup-injection-only",
    },
    "D": {
        "label": "case-d-capture-on-startup-injection-off-replacement-on",
        METAL_CAPTURE_KEY: True,
        INJECT_CAPTURE_ENVIRONMENT_KEY: False,
        SHADER_REPLACEMENT_KEY: True,
        "purpose": "replacement-with-delayed-capture",
    },
    "E": {
        "label": "case-e-capture-on-startup-injection-on-replacement-on",
        METAL_CAPTURE_KEY: True,
        INJECT_CAPTURE_ENVIRONMENT_KEY: True,
        SHADER_REPLACEMENT_KEY: True,
        "purpose": "problem-state",
    },
}

INTERESTING_MANIFEST_EVENTS = {"replacement_attempt", "replacement", "capture"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Orchestrate the standard E-006g1 launch matrix workflow"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser(
        "prepare-case",
        help="toggle the target app to one matrix case and print next steps",
    )
    add_common_args(prepare_parser)
    prepare_parser.add_argument(
        "--print-path",
        action="store_true",
        help="print the resolved app settings plist path",
    )

    finalize_parser = subparsers.add_parser(
        "finalize-case",
        help="snapshot app settings, launch diagnostics, and recent manifest events for one case",
    )
    add_common_args(finalize_parser)
    finalize_parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="snapshot root directory (default: build/e006g-launch-matrix)",
    )
    finalize_parser.add_argument(
        "--diagnostics-root",
        default=str(DEFAULT_DIAGNOSTICS_ROOT),
        help="RuntimeLaunchDiagnostics root (default: ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics)",
    )
    finalize_parser.add_argument(
        "--summary-limit",
        type=int,
        default=5,
        help="how many recent processLaunchId groups to preserve in the case snapshot",
    )
    finalize_parser.add_argument(
        "--manifest-event-limit",
        type=int,
        default=DEFAULT_MANIFEST_EVENT_LIMIT,
        help="how many recent interesting manifest events to preserve",
    )

    analyze_parser = subparsers.add_parser(
        "analyze",
        help="summarize all finalized matrix cases under the output root",
    )
    analyze_parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    analyze_parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="root containing <case-label>/<bundle-id>/case.meta.json",
    )
    analyze_parser.add_argument("--output", help="optional JSON report output path")

    return parser


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument(
        "--case",
        required=True,
        choices=tuple(CASE_DEFINITIONS.keys()),
        help="matrix case: A/B/C/D/E",
    )
    parser.add_argument(
        "--container",
        default=str(DEFAULT_CONTAINER),
        help="PlayCover container root (default: ~/Library/Containers/io.playcover.PlayCover)",
    )


def resolve_settings_path(container_root: Path, bundle_id: str) -> Path:
    return container_root / "App Settings" / f"{bundle_id}.plist"


def load_settings_payload(settings_path: Path) -> dict[str, Any]:
    if not settings_path.is_file():
        raise SystemExit(f"settings plist not found: {settings_path}")
    with settings_path.open("rb") as handle:
        payload = plistlib.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit(f"unexpected plist root type at {settings_path}")
    return payload


def write_settings_payload(settings_path: Path, payload: dict[str, Any]) -> None:
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    with settings_path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)


def apply_case_settings(payload: dict[str, Any], case_key: str) -> dict[str, Any]:
    definition = CASE_DEFINITIONS[case_key]
    previous = {
        METAL_CAPTURE_KEY: payload.get(METAL_CAPTURE_KEY),
        INJECT_CAPTURE_ENVIRONMENT_KEY: payload.get(INJECT_CAPTURE_ENVIRONMENT_KEY),
        SHADER_REPLACEMENT_KEY: payload.get(SHADER_REPLACEMENT_KEY),
    }
    payload[METAL_CAPTURE_KEY] = definition[METAL_CAPTURE_KEY]
    payload[INJECT_CAPTURE_ENVIRONMENT_KEY] = definition[INJECT_CAPTURE_ENVIRONMENT_KEY]
    payload[SHADER_REPLACEMENT_KEY] = definition[SHADER_REPLACEMENT_KEY]
    return previous


def format_case_settings(case_key: str) -> str:
    definition = CASE_DEFINITIONS[case_key]
    return (
        f"{METAL_CAPTURE_KEY}={definition[METAL_CAPTURE_KEY]} "
        f"{INJECT_CAPTURE_ENVIRONMENT_KEY}={definition[INJECT_CAPTURE_ENVIRONMENT_KEY]} "
        f"{SHADER_REPLACEMENT_KEY}={definition[SHADER_REPLACEMENT_KEY]}"
    )


def load_recent_manifest_events(container_root: Path, bundle_id: str, limit: int) -> list[dict[str, Any]]:
    manifest_path = container_root / "ShaderCorpus" / bundle_id / "manifest.jsonl"
    if not manifest_path.is_file():
        return []

    rows: list[dict[str, Any]] = []
    for raw_line in manifest_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("event") in INTERESTING_MANIFEST_EVENTS:
            rows.append(payload)
    return rows[-max(limit, 1) :]


def write_text_summary(path: Path, *, bundle_id: str, case_key: str, summaries: list[dict[str, Any]]) -> None:
    lines = [
        f"bundleId: {bundle_id}",
        f"case: {case_key} ({CASE_DEFINITIONS[case_key]['label']})",
    ]
    if not summaries:
        lines.append("no launch diagnostics events found")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

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
        last_details = summary.get("lastDetails") or {}
        if last_details:
            rendered = ", ".join(f"{key}={value}" for key, value in sorted(last_details.items()))
            lines.append(f"  lastDetails={rendered}")
        failures = summary.get("noteworthyFailures") or []
        if failures:
            lines.append("  recentFailures:")
            for failure in failures:
                rendered = ", ".join(
                    f"{key}={value}" for key, value in failure.items() if value not in (None, "")
                )
                lines.append(f"    - {rendered}")

        replacement = summary.get("replacement") or {}
        replacement_counts = replacement.get("counts") or {}
        if replacement_counts:
            rendered_counts = ", ".join(
                f"{key}={value}" for key, value in sorted(replacement_counts.items())
            )
            lines.append(f"  replacementCounts={rendered_counts}")

        failure_clusters = replacement.get("failureClusters") or []
        if failure_clusters:
            lines.append("  replacementFailureClusters:")
            for cluster in failure_clusters[:5]:
                rendered = ", ".join(
                    f"{key}={value}" for key, value in cluster.items() if value not in (None, "", 0)
                )
                lines.append(f"    - {rendered}")

        failure_surfaces = (summary.get("replacementFailureSurfaces") or {}).get("failureSurfaces") or []
        if failure_surfaces:
            lines.append("  replacementFailureSurfaces:")
            for surface in failure_surfaces[:5]:
                rendered = ", ".join(
                    f"{key}={value}" for key, value in surface.items() if value not in (None, "", 0, [])
                )
                lines.append(f"    - {rendered}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def prepare_case(args: argparse.Namespace) -> int:
    container_root = Path(args.container).expanduser().resolve()
    settings_path = resolve_settings_path(container_root, args.bundle_id)
    payload = load_settings_payload(settings_path)
    previous = apply_case_settings(payload, args.case)
    write_settings_payload(settings_path, payload)

    label = CASE_DEFINITIONS[args.case]["label"]
    print(f"prepared {label}")
    print(
        f"{args.bundle_id}: {METAL_CAPTURE_KEY} {previous[METAL_CAPTURE_KEY]!r} -> {payload[METAL_CAPTURE_KEY]!r}, "
        f"{INJECT_CAPTURE_ENVIRONMENT_KEY} {previous[INJECT_CAPTURE_ENVIRONMENT_KEY]!r} -> {payload[INJECT_CAPTURE_ENVIRONMENT_KEY]!r}, "
        f"{SHADER_REPLACEMENT_KEY} {previous[SHADER_REPLACEMENT_KEY]!r} -> {payload[SHADER_REPLACEMENT_KEY]!r}"
    )
    if args.print_path:
        print(settings_path)

    print("next:")
    print("1. Fresh deploy if runtime code changed: ./BuildScripts/build_and_install.sh")
    print("2. Launch the app once and attempt create_session.")
    print(
        f"3. Summarize launch diagnostics: python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id {args.bundle_id} --limit 5"
    )
    print(
        f"4. Finalize this case: python3 Scripts/e006g_launch_matrix_runner.py finalize-case --bundle-id {args.bundle_id} --case {args.case}"
    )
    return 0


def finalize_case(args: argparse.Namespace) -> int:
    container_root = Path(args.container).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    diagnostics_root = Path(args.diagnostics_root).expanduser().resolve()

    settings_path = resolve_settings_path(container_root, args.bundle_id)
    settings_payload = load_settings_payload(settings_path)
    expected = CASE_DEFINITIONS[args.case]
    actual_settings = {
        METAL_CAPTURE_KEY: settings_payload.get(METAL_CAPTURE_KEY),
        INJECT_CAPTURE_ENVIRONMENT_KEY: settings_payload.get(INJECT_CAPTURE_ENVIRONMENT_KEY),
        SHADER_REPLACEMENT_KEY: settings_payload.get(SHADER_REPLACEMENT_KEY),
    }

    label = expected["label"]
    case_bundle_dir = output_root / label / args.bundle_id
    if case_bundle_dir.exists():
        raise SystemExit(f"case snapshot destination already exists: {case_bundle_dir}")
    case_bundle_dir.mkdir(parents=True, exist_ok=False)

    shutil.copy2(settings_path, case_bundle_dir / settings_path.name)

    launch_events_path = diagnostics_root / args.bundle_id / "launch-events.jsonl"
    manifest_path = container_root / "ShaderCorpus" / args.bundle_id / "manifest.jsonl"
    events = read_events(launch_events_path)
    manifest_entries = read_manifest_entries(manifest_path)
    summaries = build_summary(events, args.summary_limit, manifest_entries)
    replacement_hotspots = aggregate_replacement_hotspots(summaries)
    if launch_events_path.is_file():
        shutil.copy2(launch_events_path, case_bundle_dir / "launch-events.jsonl")

    manifest_events = load_recent_manifest_events(container_root, args.bundle_id, args.manifest_event_limit)
    (case_bundle_dir / "launch-summary.json").write_text(
        json.dumps(
            {
                "bundleId": args.bundle_id,
                "case": args.case,
                "label": label,
                "summaryCount": len(summaries),
                "runs": summaries,
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    write_text_summary(
        case_bundle_dir / "launch-summary.txt",
        bundle_id=args.bundle_id,
        case_key=args.case,
        summaries=summaries,
    )
    (case_bundle_dir / "manifest-tail.json").write_text(
        json.dumps(manifest_events, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    latest_summary = summaries[0] if summaries else None
    expected_settings = {
        METAL_CAPTURE_KEY: expected[METAL_CAPTURE_KEY],
        INJECT_CAPTURE_ENVIRONMENT_KEY: expected[INJECT_CAPTURE_ENVIRONMENT_KEY],
        SHADER_REPLACEMENT_KEY: expected[SHADER_REPLACEMENT_KEY],
    }
    case_meta = {
        "schemaVersion": 1,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "bundleId": args.bundle_id,
        "case": args.case,
        "label": label,
        "purpose": expected["purpose"],
        "expectedSettings": expected_settings,
        "actualSettings": actual_settings,
        "settingsMatchedExpectation": actual_settings == expected_settings,
        "artifacts": {
            "settingsPath": settings_path.name,
            "launchEventsPath": "launch-events.jsonl" if launch_events_path.is_file() else None,
            "launchSummaryJsonPath": "launch-summary.json",
            "launchSummaryTextPath": "launch-summary.txt",
            "manifestTailPath": "manifest-tail.json",
        },
        "launchDiagnostics": {
            "eventCount": len(events),
            "summaryCount": len(summaries),
            "latestLastEvent": latest_summary.get("lastEvent") if latest_summary else None,
            "latestReachedStages": [
                stage for stage in KEY_STAGE_ORDER if latest_summary and latest_summary.get("stages", {}).get(stage)
            ],
            "latestMissingStages": [
                stage for stage in KEY_STAGE_ORDER if not latest_summary or not latest_summary.get("stages", {}).get(stage)
            ],
            "latestFailureCount": len(latest_summary.get("noteworthyFailures") or []) if latest_summary else 0,
            "latestReplacementCounts": (latest_summary.get("replacement") or {}).get("counts", {}) if latest_summary else {},
            "latestReplacementFailureClusters": (
                (latest_summary.get("replacement") or {}).get("failureClusters", []) if latest_summary else []
            ),
            "latestReplacementFailureSurfaceCount": (
                (latest_summary.get("replacementFailureSurfaces") or {}).get("failureSurfaceCount", 0)
                if latest_summary else 0
            ),
            "latestReplacementFailureSurfaces": (
                (latest_summary.get("replacementFailureSurfaces") or {}).get("failureSurfaces", [])
                if latest_summary else []
            ),
            "aggregatedReplacementFailureClusterCount": replacement_hotspots.get("failureClusterCount", 0),
            "aggregatedReplacementFailureClusters": replacement_hotspots.get("failureClusters", []),
            "aggregatedReplacementFailureSurfaceCount": replacement_hotspots.get("failureSurfaceCount", 0),
            "aggregatedReplacementFailureSurfaces": replacement_hotspots.get("failureSurfaces", []),
        },
        "recentManifestEventCount": len(manifest_events),
    }
    (case_bundle_dir / "case.meta.json").write_text(
        json.dumps(case_meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(f"case snapshot created: {case_bundle_dir}")
    print(
        f"summary: case={args.case} expected=({format_case_settings(args.case)}) "
        f"matched={case_meta['settingsMatchedExpectation']} lastEvent={case_meta['launchDiagnostics']['latestLastEvent'] or 'n/a'} "
        f"missingStages={len(case_meta['launchDiagnostics']['latestMissingStages'])} manifestEvents={len(manifest_events)}"
    )
    return 0


def analyze_cases(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root).expanduser().resolve()
    report_cases: dict[str, dict[str, Any]] = {}

    for case_key, definition in CASE_DEFINITIONS.items():
        case_meta_path = output_root / definition["label"] / args.bundle_id / "case.meta.json"
        if not case_meta_path.is_file():
            report_cases[case_key] = {
                "label": definition["label"],
                "present": False,
            }
            continue

        payload = json.loads(case_meta_path.read_text(encoding="utf-8"))
        report_cases[case_key] = {
            "label": definition["label"],
            "present": True,
            "settingsMatchedExpectation": payload.get("settingsMatchedExpectation"),
            "latestLastEvent": payload.get("launchDiagnostics", {}).get("latestLastEvent"),
            "latestReachedStages": payload.get("launchDiagnostics", {}).get("latestReachedStages", []),
            "latestMissingStages": payload.get("launchDiagnostics", {}).get("latestMissingStages", []),
            "latestFailureCount": payload.get("launchDiagnostics", {}).get("latestFailureCount"),
            "latestReplacementCounts": payload.get("launchDiagnostics", {}).get("latestReplacementCounts", {}),
            "latestReplacementFailureClusters": payload.get("launchDiagnostics", {}).get(
                "latestReplacementFailureClusters", []
            ),
            "latestReplacementFailureSurfaceCount": payload.get("launchDiagnostics", {}).get(
                "latestReplacementFailureSurfaceCount", 0
            ),
            "latestReplacementFailureSurfaces": payload.get("launchDiagnostics", {}).get(
                "latestReplacementFailureSurfaces", []
            ),
            "aggregatedReplacementFailureClusterCount": payload.get("launchDiagnostics", {}).get(
                "aggregatedReplacementFailureClusterCount", 0
            ),
            "aggregatedReplacementFailureClusters": payload.get("launchDiagnostics", {}).get(
                "aggregatedReplacementFailureClusters", []
            ),
            "aggregatedReplacementFailureSurfaceCount": payload.get("launchDiagnostics", {}).get(
                "aggregatedReplacementFailureSurfaceCount", 0
            ),
            "aggregatedReplacementFailureSurfaces": payload.get("launchDiagnostics", {}).get(
                "aggregatedReplacementFailureSurfaces", []
            ),
            "recentManifestEventCount": payload.get("recentManifestEventCount"),
        }

    report = {
        "bundleId": args.bundle_id,
        "outputRoot": str(output_root),
        "cases": report_cases,
    }

    for case_key in CASE_DEFINITIONS:
        case_report = report_cases[case_key]
        if not case_report["present"]:
            print(f"case={case_key}: missing")
            continue
        print(
            f"case={case_key}: matched={case_report['settingsMatchedExpectation']} "
            f"lastEvent={case_report['latestLastEvent'] or 'n/a'} "
            f"missingStages={len(case_report['latestMissingStages'])} "
            f"failures={case_report['latestFailureCount']} "
            f"replacementCompileFailed={case_report['latestReplacementCounts'].get('replacement_compile_failed', 0)} "
            f"failureSurfaces={case_report['latestReplacementFailureSurfaceCount']} "
            f"aggregateFailureSurfaces={case_report['aggregatedReplacementFailureSurfaceCount']} "
            f"manifestEvents={case_report['recentManifestEventCount']}"
        )

        top_surface = (case_report.get("aggregatedReplacementFailureSurfaces") or [None])[0]
        if top_surface:
            print(
                f"  hotspotSurface: cacheKey={top_surface.get('cacheKey') or 'n/a'} "
                f"reasonCode={top_surface.get('reasonCode') or 'n/a'} "
                f"runs={top_surface.get('runCount', 0)} "
                f"occurrences={top_surface.get('occurrenceCount', 0)}"
            )

        top_cluster = (case_report.get("aggregatedReplacementFailureClusters") or [None])[0]
        if top_cluster:
            print(
                f"  hotspotCluster: event={top_cluster.get('event') or 'n/a'} "
                f"cacheKey={top_cluster.get('cacheKey') or 'n/a'} "
                f"runs={top_cluster.get('runCount', 0)} "
                f"occurrences={top_cluster.get('occurrenceCount', 0)}"
            )

    if args.output:
        output_path = Path(args.output).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "prepare-case":
        return prepare_case(args)
    if args.command == "finalize-case":
        return finalize_case(args)
    if args.command == "analyze":
        return analyze_cases(args)
    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
