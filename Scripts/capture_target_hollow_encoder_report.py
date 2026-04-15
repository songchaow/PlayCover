#!/usr/bin/env python3
"""
capture_target_hollow_encoder_report.py — 为 CTF2-005 输出跨 target 的 hollow encoder 槽位对照报告。

输入是已经完成 Xcode 结构化采集的 collection 目录（包含 `collection.meta.json`、
`frame_dump/`、`cb_data.json`，通常由 `e006d_render_diff.py collect-run` 生成）。

脚本会：
- 读取每个 collection 对应的 `snapshot.meta.json`，恢复 `captureTarget`
- 把 `queue_scope` 这类 empty-capture 分支与 `device / scope / queue` 的 non-empty 分支分开
- 在 non-empty target 内比较 Render Encoder 槽位 `(Command Buffer, slotOrdinal)` 是否同构
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from e006d_render_diff import build_collection_summary, load_json


SCHEMA_VERSION = 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Report cross-target hollow encoder slot structure from collected render artifacts"
    )
    parser.add_argument(
        "--collection",
        action="append",
        default=[],
        help="collected render artifact directory; may be passed multiple times",
    )
    parser.add_argument(
        "--empty-target",
        action="append",
        default=[],
        help="capture target labels that should be recorded as empty-capture branches and excluded from slot isomorphism",
    )
    parser.add_argument("--label", help="optional label stored in the report")
    parser.add_argument("--output", help="optional JSON output path")
    return parser


def ensure_collection_dirs(raw_paths: list[str]) -> list[Path]:
    collection_dirs = [Path(raw_path).expanduser().resolve() for raw_path in raw_paths]
    if len(collection_dirs) < 2:
        raise SystemExit("at least two --collection arguments are required")
    for collection_dir in collection_dirs:
        if not collection_dir.is_dir():
            raise SystemExit(f"collection directory not found: {collection_dir}")
    return collection_dirs


def load_snapshot_meta(summary: dict[str, Any]) -> dict[str, Any]:
    snapshot_dir = Path(summary["metadata"]["snapshotDir"]).expanduser().resolve()
    snapshot_meta_path = snapshot_dir / "snapshot.meta.json"
    if not snapshot_meta_path.is_file():
        raise SystemExit(f"snapshot.meta.json not found: {snapshot_meta_path}")
    payload = load_json(snapshot_meta_path)
    if not isinstance(payload, dict):
        raise SystemExit(f"unexpected snapshot.meta.json root type at {snapshot_meta_path}")
    return payload


def extract_slots(command_buffers: dict[str, Any]) -> list[dict[str, Any]]:
    slots: list[dict[str, Any]] = []
    for command_buffer_index, command_buffer in enumerate(command_buffers.get("commandBuffers", [])):
        children = command_buffer.get("children") if isinstance(command_buffer, dict) else None
        if not isinstance(children, list):
            continue

        slot_ordinal = 0
        child_index = 0
        while child_index < len(children):
            child_text = children[child_index]
            if not isinstance(child_text, str) or not child_text.startswith("Render Encoder"):
                child_index += 1
                continue

            slot_ordinal += 1
            trailing_children: list[str] = []
            trailing_index = child_index + 1
            while trailing_index < len(children):
                trailing_text = children[trailing_index]
                if isinstance(trailing_text, str) and trailing_text.startswith("Render Encoder"):
                    break
                if isinstance(trailing_text, str):
                    trailing_children.append(trailing_text)
                trailing_index += 1

            signature_payload = {
                "renderEncoder": child_text,
                "trailingChildren": trailing_children,
            }
            slots.append(
                {
                    "commandBufferIndex": command_buffer_index,
                    "commandBuffer": command_buffer.get("commandBuffer"),
                    "slotOrdinal": slot_ordinal,
                    "childIndex": child_index,
                    "renderEncoder": child_text,
                    "trailingChildren": trailing_children,
                    "signature": json.dumps(signature_payload, ensure_ascii=False, sort_keys=True),
                }
            )
            child_index = trailing_index
    return slots


def build_collection_context(collection_dir: Path, forced_empty_targets: set[str]) -> dict[str, Any]:
    summary = build_collection_summary(collection_dir)
    snapshot_meta = load_snapshot_meta(summary)
    metadata = summary["metadata"]
    capture_target = str(snapshot_meta.get("captureTarget") or metadata.get("runLabel") or collection_dir.name)
    api_summary = summary["apiCallNavigator"]
    slots = extract_slots(summary["commandBuffers"])
    auto_empty = api_summary.get("commandBufferCount", 0) == 0 or api_summary.get("renderEncoderCount", 0) == 0
    branch_type = "empty-capture-branch" if auto_empty or capture_target in forced_empty_targets else "non-empty"
    return {
        "collectionDir": str(collection_dir),
        "runLabel": metadata.get("runLabel"),
        "snapshotDir": metadata.get("snapshotDir"),
        "captureTarget": capture_target,
        "branchType": branch_type,
        "autoDetectedEmptyCapture": auto_empty,
        "apiCallNavigator": {
            "commandBufferCount": api_summary.get("commandBufferCount", 0),
            "renderEncoderCount": api_summary.get("renderEncoderCount", 0),
            "presentDrawableCount": api_summary.get("presentDrawableCount", 0),
        },
        "slotCount": len(slots),
        "renderEncoderCounts": list(summary["commandBuffers"].get("renderEncoderCounts", [])),
        "slots": slots,
    }


def slot_key(slot: dict[str, Any]) -> tuple[int, int]:
    return (int(slot["commandBufferIndex"]), int(slot["slotOrdinal"]))


def compare_nonempty_targets(nonempty_targets: list[dict[str, Any]]) -> dict[str, Any]:
    target_names = [str(item["captureTarget"]) for item in nonempty_targets]
    slot_maps = {
        target_name: {slot_key(slot): slot for slot in target["slots"]}
        for target_name, target in zip(target_names, nonempty_targets, strict=True)
    }
    all_slot_keys = sorted({key for slot_map in slot_maps.values() for key in slot_map})

    shared_slots: list[dict[str, Any]] = []
    differing_slots: list[dict[str, Any]] = []
    missing_slots: list[dict[str, Any]] = []

    for key in all_slot_keys:
        slot_by_target = {target_name: slot_maps[target_name].get(key) for target_name in target_names}
        missing_targets = [target_name for target_name, slot in slot_by_target.items() if slot is None]
        if missing_targets:
            present_targets = [target_name for target_name, slot in slot_by_target.items() if slot is not None]
            missing_slots.append(
                {
                    "commandBufferIndex": key[0],
                    "slotOrdinal": key[1],
                    "presentTargets": present_targets,
                    "missingTargets": missing_targets,
                }
            )
            continue

        signatures = {target_name: str(slot["signature"]) for target_name, slot in slot_by_target.items() if slot is not None}
        if len(set(signatures.values())) == 1:
            exemplar = next(slot for slot in slot_by_target.values() if slot is not None)
            shared_slots.append(
                {
                    "commandBufferIndex": key[0],
                    "slotOrdinal": key[1],
                    "renderEncoder": exemplar["renderEncoder"],
                    "trailingChildren": exemplar["trailingChildren"],
                }
            )
            continue

        differing_slots.append(
            {
                "commandBufferIndex": key[0],
                "slotOrdinal": key[1],
                "perTarget": {
                    target_name: {
                        "renderEncoder": slot_by_target[target_name]["renderEncoder"],
                        "trailingChildren": slot_by_target[target_name]["trailingChildren"],
                    }
                    for target_name in target_names
                },
            }
        )

    render_encoder_count_matrix = [
        {
            "captureTarget": target["captureTarget"],
            "renderEncoderCounts": target["renderEncoderCounts"],
        }
        for target in nonempty_targets
    ]
    slot_counts = {target["captureTarget"]: target["slotCount"] for target in nonempty_targets}
    isomorphic = len(shared_slots) > 0 and not differing_slots and not missing_slots

    return {
        "comparedTargets": target_names,
        "comparedTargetCount": len(target_names),
        "slotCounts": slot_counts,
        "sharedSlotCount": len(shared_slots),
        "differingSlotCount": len(differing_slots),
        "missingSlotCount": len(missing_slots),
        "sharedSlots": shared_slots[:50],
        "differingSlots": differing_slots[:50],
        "missingSlots": missing_slots[:50],
        "renderEncoderCountMatrix": render_encoder_count_matrix,
        "isomorphicAcrossNonEmptyTargets": isomorphic,
    }


def build_conclusion(targets: list[dict[str, Any]], slot_comparison: dict[str, Any]) -> dict[str, str]:
    nonempty_targets = [target["captureTarget"] for target in targets if target["branchType"] == "non-empty"]
    empty_targets = [target["captureTarget"] for target in targets if target["branchType"] == "empty-capture-branch"]

    if len(nonempty_targets) < 2:
        return {
            "status": "needs-more-nonempty-targets",
            "summary": "At least two non-empty targets are required before hollow encoder slots can be compared structurally.",
        }

    if slot_comparison["isomorphicAcrossNonEmptyTargets"]:
        suffix = ""
        if empty_targets:
            suffix = f" Empty-capture branches kept separate: {', '.join(empty_targets)}."
        return {
            "status": "shared-slot-structure-across-nonempty-targets",
            "summary": (
                "The compared non-empty targets expose the same Render Encoder slot structure, "
                "so the current hollow-slot evidence is consistent with a cross-target isomorphic pattern."
                f"{suffix}"
            ),
        }

    return {
        "status": "slot-structure-differs-across-nonempty-targets",
        "summary": (
            "The compared non-empty targets do not share one stable Render Encoder slot structure; "
            "follow the differing or missing slots before escalating to queue-ranking evidence."
        ),
    }


def build_report(collection_dirs: list[Path], forced_empty_targets: set[str], label: str | None) -> dict[str, Any]:
    targets = [build_collection_context(collection_dir, forced_empty_targets) for collection_dir in collection_dirs]
    capture_targets = [str(target["captureTarget"]) for target in targets]
    duplicates = sorted({target for target in capture_targets if capture_targets.count(target) > 1})
    if duplicates:
        duplicated = ", ".join(duplicates)
        raise SystemExit(f"duplicate captureTarget values are not allowed: {duplicated}")

    nonempty_targets = [target for target in targets if target["branchType"] == "non-empty"]
    empty_targets = [target for target in targets if target["branchType"] == "empty-capture-branch"]
    slot_comparison = compare_nonempty_targets(nonempty_targets) if nonempty_targets else {
        "comparedTargets": [],
        "comparedTargetCount": 0,
        "slotCounts": {},
        "sharedSlotCount": 0,
        "differingSlotCount": 0,
        "missingSlotCount": 0,
        "sharedSlots": [],
        "differingSlots": [],
        "missingSlots": [],
        "renderEncoderCountMatrix": [],
        "isomorphicAcrossNonEmptyTargets": False,
    }

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "label": label,
        "targets": targets,
        "nonEmptyTargets": [target["captureTarget"] for target in nonempty_targets],
        "emptyCaptureTargets": [target["captureTarget"] for target in empty_targets],
        "slotComparison": slot_comparison,
    }
    report["conclusion"] = build_conclusion(targets, slot_comparison)
    return report


def render_summary(report: dict[str, Any]) -> str:
    lines = [
        f"Label: {report.get('label') or '<unspecified>'}",
        f"Non-empty targets: {', '.join(report['nonEmptyTargets']) or '<none>'}",
        f"Empty-capture targets: {', '.join(report['emptyCaptureTargets']) or '<none>'}",
        "",
        "Per target:",
    ]
    for target in report["targets"]:
        api_summary = target["apiCallNavigator"]
        lines.append(
            "- "
            f"{target['captureTarget']}: branch={target['branchType']} "
            f"CBs={api_summary['commandBufferCount']} REs={api_summary['renderEncoderCount']} "
            f"slots={target['slotCount']}"
        )

    slot_comparison = report["slotComparison"]
    lines.extend(
        [
            "",
            "Slot comparison:",
            f"- Compared non-empty targets: {slot_comparison['comparedTargetCount']}",
            f"- Shared slots: {slot_comparison['sharedSlotCount']}",
            f"- Differing slots: {slot_comparison['differingSlotCount']}",
            f"- Missing slots: {slot_comparison['missingSlotCount']}",
            "",
            f"Conclusion: {report['conclusion']['status']}",
            report["conclusion"]["summary"],
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = build_parser().parse_args()
    collection_dirs = ensure_collection_dirs(args.collection)
    forced_empty_targets = {item for item in args.empty_target if item}
    report = build_report(collection_dirs, forced_empty_targets, args.label)

    if args.output:
        output_path = Path(args.output).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        output_path.with_name("summary.txt").write_text(render_summary(report), encoding="utf-8")
        print(output_path)
        return 0

    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
