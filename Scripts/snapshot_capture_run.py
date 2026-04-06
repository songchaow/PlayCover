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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from gputrace_attribution import build_gputrace_attribution
from gputrace_sources import inspect_gputrace_dir


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


def main() -> int:
    args = parse_args()
    container = Path(args.container).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()

    corpus_bundle_dir = container / "ShaderCorpus" / args.bundle_id
    diagnostics_bundle_dir = container / "ShaderSourceDiagnostics" / args.bundle_id
    settings_path = container / "App Settings" / f"{args.bundle_id}.plist"

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

    snapshot_meta = {
        "schemaVersion": 2,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "bundleId": args.bundle_id,
        "label": args.label,
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
        f"replacementEnabled={snapshot_meta['replacementMode']['enabled']} "
        f"gputraceMSL={snapshot_meta['gputraceSummary']['validMSLFiles'] if snapshot_meta['gputraceSummary'] else 'n/a'}"
    )
    if args.print_compare_path:
        print(snapshot_bundle_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
