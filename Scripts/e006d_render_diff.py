#!/usr/bin/env python3
"""
e006d_render_diff.py — 标准化 E-006d8b 的 `.gputrace` 结构化采集与首轮 diff。

将 `build/e006d-run-snapshots/<label>/<bundle-id>` 下的标准 run 快照，接到
`LocalDocs/XCodeOperation/` 现有 GUI 自动化脚本，统一导出：

- `frame_dump/`
- `cb_data.json`
- `key_pass_details.json`（可选，较慢）
- `comparison.json`
- `summary.txt`

示例：
    python3 Scripts/e006d_render_diff.py collect-pair \
        --bundle-id com.miHoYo.Yuanshen \
        --run-a replacement-off-run1 \
        --run-b replacement-on-run5 \
        --include-re-details
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_RUNS_ROOT = REPO_ROOT / "build/e006d-run-snapshots"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "build/e006d-render-diff"
XCODE_OPS_DIR = REPO_ROOT / "LocalDocs/XCodeOperation"
XCODE_GPU_OPS = XCODE_OPS_DIR / "xcode_gpu_ops.py"
COLLECT_CBS = XCODE_OPS_DIR / "collect_cbs.py"
COLLECT_RE_DETAILS = XCODE_OPS_DIR / "collect_re_details.py"
HEX_ADDRESS = re.compile(r"0x[0-9a-fA-F]+")
PRESENT_DRAWABLE = re.compile(r"\d+ \[presentDrawable:[^\]]+\]")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Collect and compare E-006d render-path artifacts from standard run snapshots"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    collect_run = subparsers.add_parser(
        "collect-run",
        help="collect frame_dump / cb_data / optional key_pass_details for one run snapshot",
    )
    add_run_selector_args(collect_run)
    add_collection_args(collect_run)

    compare = subparsers.add_parser(
        "compare",
        help="compare two already-collected render-diff directories",
    )
    compare.add_argument("--collection-a", required=True, help="first collected run directory")
    compare.add_argument("--collection-b", required=True, help="second collected run directory")
    compare.add_argument(
        "--output",
        help="optional comparison.json output path (default: <collection-a>/../<a>-vs-<b>/comparison.json if under same parent)",
    )

    collect_pair = subparsers.add_parser(
        "collect-pair",
        help="collect both run snapshots and immediately write a comparison summary",
    )
    collect_pair.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    collect_pair.add_argument("--run-a", required=True, help="first run label, e.g. replacement-off-run1")
    collect_pair.add_argument("--run-b", required=True, help="second run label, e.g. replacement-on-run5")
    collect_pair.add_argument(
        "--runs-root",
        default=str(DEFAULT_RUNS_ROOT),
        help="root containing <label>/<bundle-id>/snapshot.meta.json",
    )
    add_collection_args(collect_pair)

    return parser


def add_run_selector_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument("--run-label", help="run label under build/e006d-run-snapshots")
    parser.add_argument("--run-path", help="explicit snapshot bundle directory path")
    parser.add_argument(
        "--runs-root",
        default=str(DEFAULT_RUNS_ROOT),
        help="root containing <label>/<bundle-id>/snapshot.meta.json",
    )


def add_collection_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="root directory for collected artifacts",
    )
    parser.add_argument(
        "--include-re-details",
        action="store_true",
        help="also collect key_pass_details.json (slow, usually 15-20 minutes)",
    )
    parser.add_argument(
        "--re-count",
        type=int,
        default=26,
        help="target Render Encoder count when --include-re-details is enabled",
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=500,
        help="max draw-call steps for collect_re_details.py",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing collected output directory",
    )


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_command(command: list[str]) -> None:
    completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def resolve_snapshot_dir(
    *,
    bundle_id: str,
    run_label: str | None,
    run_path: str | None,
    runs_root: str,
) -> Path:
    if bool(run_label) == bool(run_path):
        raise SystemExit("provide exactly one of --run-label or --run-path")

    if run_path:
        snapshot_dir = Path(run_path).expanduser().resolve()
    else:
        snapshot_dir = Path(runs_root).expanduser().resolve() / run_label / bundle_id

    meta_path = snapshot_dir / "snapshot.meta.json"
    if not meta_path.is_file():
        raise SystemExit(f"snapshot.meta.json not found: {meta_path}")
    return snapshot_dir


def resolve_snapshot_meta(snapshot_dir: Path) -> dict[str, Any]:
    payload = load_json(snapshot_dir / "snapshot.meta.json")
    if not isinstance(payload, dict):
        raise SystemExit(f"unexpected snapshot.meta.json root type in {snapshot_dir}")
    return payload


def resolve_gputrace_path(snapshot_dir: Path, meta: dict[str, Any]) -> Path:
    relative_path = ((meta.get("copiedArtifacts") or {}).get("gputracePath"))
    if not relative_path:
        raise SystemExit(f"snapshot has no gputracePath: {snapshot_dir}")
    gputrace_path = snapshot_dir / relative_path
    if not gputrace_path.is_dir():
        raise SystemExit(f"gputrace directory not found: {gputrace_path}")
    return gputrace_path


def normalize_row_text(text: str) -> str:
    collapsed = PRESENT_DRAWABLE.sub("presentDrawable", text)
    collapsed = HEX_ADDRESS.sub("0xADDR", collapsed)
    collapsed = re.sub(r"\s+", " ", collapsed).strip()
    return collapsed


def load_rows(path: Path) -> list[dict[str, Any]]:
    payload = load_json(path)
    if not isinstance(payload, list):
        raise SystemExit(f"expected list at {path}")
    return [row for row in payload if isinstance(row, dict)]


def load_cb_map(path: Path) -> dict[str, list[str]]:
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise SystemExit(f"expected object at {path}")
    result: dict[str, list[str]] = {}
    for key, value in payload.items():
        if isinstance(key, str) and isinstance(value, list):
            result[key] = [item for item in value if isinstance(item, str)]
    return result


def load_re_details(path: Path) -> list[dict[str, Any]]:
    payload = load_json(path)
    if not isinstance(payload, list):
        raise SystemExit(f"expected list at {path}")
    return [item for item in payload if isinstance(item, dict)]


def summarize_api_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    texts = [normalize_row_text(str(row.get("text", ""))) for row in rows]
    nonempty = [text for text in texts if text]
    return {
        "rowCount": len(rows),
        "nonEmptyRowCount": len(nonempty),
        "commandBufferCount": sum(1 for text in nonempty if text.startswith("Command Buffer")),
        "renderEncoderCount": sum(1 for text in nonempty if text.startswith("Render Encoder")),
        "presentDrawableCount": sum(1 for text in nonempty if "presentDrawable" in text),
        "topRows": [{"text": text, "count": count} for text, count in Counter(nonempty).most_common(12)],
    }


def summarize_pipeline_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    texts = [normalize_row_text(str(row.get("text", ""))) for row in rows]
    nonempty = [text for text in texts if text]
    filtered = [text for text in nonempty if not text.startswith("Command Buffer")]
    counts = Counter(filtered)
    return {
        "rowCount": len(rows),
        "nonEmptyRowCount": len(nonempty),
        "uniqueRowCount": len(counts),
        "topRows": [{"text": text, "count": count} for text, count in counts.most_common(20)],
    }


def summarize_cb_data(cb_map: dict[str, list[str]]) -> dict[str, Any]:
    ordered_keys = sorted(cb_map.keys(), key=command_buffer_sort_key)
    render_encoder_counts: list[int] = []
    present_drawable_counts: list[int] = []
    normalized_children_by_cb: list[dict[str, Any]] = []

    for key in ordered_keys:
        children = [normalize_row_text(item) for item in cb_map[key]]
        render_encoder_count = sum(1 for item in children if item.startswith("Render Encoder"))
        present_drawable_count = sum(1 for item in children if "presentDrawable" in item)
        render_encoder_counts.append(render_encoder_count)
        present_drawable_counts.append(present_drawable_count)
        normalized_children_by_cb.append(
            {
                "commandBuffer": normalize_row_text(key),
                "childCount": len(children),
                "renderEncoderCount": render_encoder_count,
                "presentDrawableCount": present_drawable_count,
                "children": children,
            }
        )

    return {
        "commandBufferCount": len(ordered_keys),
        "renderEncoderCounts": render_encoder_counts,
        "presentDrawableCounts": present_drawable_counts,
        "commandBuffers": normalized_children_by_cb,
    }


def summarize_re_details(entries: list[dict[str, Any]]) -> dict[str, Any]:
    normalized: list[dict[str, Any]] = []
    pipeline_counter: Counter[str] = Counter()
    vertex_counter: Counter[str] = Counter()
    fragment_counter: Counter[str] = Counter()

    for index, entry in enumerate(entries):
        summary = entry.get("summary") if isinstance(entry.get("summary"), dict) else {}
        pipeline_state = normalize_optional_text(summary.get("pipeline_state"))
        vertex_function = normalize_optional_text(summary.get("vertex_function"))
        fragment_function = normalize_optional_text(summary.get("fragment_function"))
        attachments = [attachment_signature(item) for item in summary.get("attachments", []) if isinstance(item, dict)]
        normalized.append(
            {
                "index": index,
                "commandBuffer": normalize_optional_text(entry.get("command_buffer")),
                "renderEncoder": normalize_optional_text(entry.get("render_encoder")),
                "drawCall": normalize_optional_text(entry.get("draw_call")),
                "pipelineState": pipeline_state,
                "vertexFunction": vertex_function,
                "fragmentFunction": fragment_function,
                "attachmentSignatures": attachments,
                "attachmentCount": len(attachments),
            }
        )
        pipeline_counter[pipeline_state or "<none>"] += 1
        vertex_counter[vertex_function or "<none>"] += 1
        fragment_counter[fragment_function or "<none>"] += 1

    return {
        "entryCount": len(normalized),
        "entries": normalized,
        "topPipelineStates": counter_to_rows(pipeline_counter, 12),
        "topVertexFunctions": counter_to_rows(vertex_counter, 12),
        "topFragmentFunctions": counter_to_rows(fragment_counter, 12),
    }


def counter_to_rows(counter: Counter[str], limit: int) -> list[dict[str, Any]]:
    return [{"text": text, "count": count} for text, count in counter.most_common(limit)]


def normalize_optional_text(value: Any) -> str | None:
    if value is None:
        return None
    return normalize_row_text(str(value))


def attachment_signature(attachment: dict[str, Any]) -> str:
    slot = normalize_optional_text(attachment.get("slot")) or "<none>"
    name = normalize_optional_text(attachment.get("name")) or "<none>"
    attachment_type = normalize_optional_text(attachment.get("type")) or "<none>"
    return f"{slot}|{name}|{attachment_type}"


def command_buffer_sort_key(name: str) -> tuple[int, str]:
    match = re.match(r"Command Buffer (\d+)", name)
    if not match:
        return (sys.maxsize, name)
    return (int(match.group(1)), name)


def compare_top_rows(rows_a: list[dict[str, Any]], rows_b: list[dict[str, Any]]) -> dict[str, Any]:
    counter_a = Counter({row["text"]: row["count"] for row in rows_a if isinstance(row, dict) and "text" in row and "count" in row})
    counter_b = Counter({row["text"]: row["count"] for row in rows_b if isinstance(row, dict) and "text" in row and "count" in row})
    differing: list[dict[str, Any]] = []
    for text in sorted(set(counter_a) | set(counter_b)):
        if counter_a[text] != counter_b[text]:
            differing.append({"text": text, "countA": counter_a[text], "countB": counter_b[text]})
    return {
        "differentCount": len(differing),
        "differences": differing[:20],
    }


def compare_cb_summaries(summary_a: dict[str, Any], summary_b: dict[str, Any]) -> dict[str, Any]:
    cbs_a = summary_a["commandBuffers"]
    cbs_b = summary_b["commandBuffers"]
    paired = min(len(cbs_a), len(cbs_b))
    differing_children: list[dict[str, Any]] = []
    for index in range(paired):
        cb_a = cbs_a[index]
        cb_b = cbs_b[index]
        if cb_a["children"] != cb_b["children"]:
            differing_children.append(
                {
                    "index": index,
                    "commandBufferA": cb_a["commandBuffer"],
                    "commandBufferB": cb_b["commandBuffer"],
                    "renderEncoderCountA": cb_a["renderEncoderCount"],
                    "renderEncoderCountB": cb_b["renderEncoderCount"],
                    "presentDrawableCountA": cb_a["presentDrawableCount"],
                    "presentDrawableCountB": cb_b["presentDrawableCount"],
                }
            )
    return {
        "commandBufferCountA": summary_a["commandBufferCount"],
        "commandBufferCountB": summary_b["commandBufferCount"],
        "pairedCommandBufferCount": paired,
        "renderEncoderCountsA": summary_a["renderEncoderCounts"],
        "renderEncoderCountsB": summary_b["renderEncoderCounts"],
        "presentDrawableCountsA": summary_a["presentDrawableCounts"],
        "presentDrawableCountsB": summary_b["presentDrawableCounts"],
        "differingCommandBuffers": differing_children[:20],
        "differentCount": len(differing_children),
    }


def compare_re_summaries(summary_a: dict[str, Any] | None, summary_b: dict[str, Any] | None) -> dict[str, Any] | None:
    if summary_a is None or summary_b is None:
        return None

    entries_a = summary_a["entries"]
    entries_b = summary_b["entries"]
    paired = min(len(entries_a), len(entries_b))
    differing_entries: list[dict[str, Any]] = []
    for index in range(paired):
        entry_a = entries_a[index]
        entry_b = entries_b[index]
        if (
            entry_a["pipelineState"] != entry_b["pipelineState"]
            or entry_a["vertexFunction"] != entry_b["vertexFunction"]
            or entry_a["fragmentFunction"] != entry_b["fragmentFunction"]
            or entry_a["attachmentSignatures"] != entry_b["attachmentSignatures"]
        ):
            differing_entries.append(
                {
                    "index": index,
                    "renderEncoderA": entry_a["renderEncoder"],
                    "renderEncoderB": entry_b["renderEncoder"],
                    "pipelineStateA": entry_a["pipelineState"],
                    "pipelineStateB": entry_b["pipelineState"],
                    "vertexFunctionA": entry_a["vertexFunction"],
                    "vertexFunctionB": entry_b["vertexFunction"],
                    "fragmentFunctionA": entry_a["fragmentFunction"],
                    "fragmentFunctionB": entry_b["fragmentFunction"],
                    "attachmentSignaturesA": entry_a["attachmentSignatures"],
                    "attachmentSignaturesB": entry_b["attachmentSignatures"],
                }
            )

    return {
        "entryCountA": summary_a["entryCount"],
        "entryCountB": summary_b["entryCount"],
        "pairedEntryCount": paired,
        "topPipelineStateDiff": compare_top_rows(summary_a["topPipelineStates"], summary_b["topPipelineStates"]),
        "entryCountDiff": summary_a["entryCount"] != summary_b["entryCount"],
        "differentEntryCount": len(differing_entries),
        "differentEntries": differing_entries[:20],
    }


def build_collection_summary(collection_dir: Path) -> dict[str, Any]:
    metadata = load_json(collection_dir / "collection.meta.json")
    api_rows = load_rows(collection_dir / "frame_dump" / "navigator_api_call.json")
    pipeline_rows = load_rows(collection_dir / "frame_dump" / "navigator_pipeline_state.json")
    cb_map = load_cb_map(collection_dir / "cb_data.json")

    re_details_path = collection_dir / "key_pass_details.json"
    re_summary = summarize_re_details(load_re_details(re_details_path)) if re_details_path.is_file() else None

    return {
        "metadata": metadata,
        "apiCallNavigator": summarize_api_rows(api_rows),
        "pipelineNavigator": summarize_pipeline_rows(pipeline_rows),
        "commandBuffers": summarize_cb_data(cb_map),
        "renderEncoderDetails": re_summary,
    }


def compare_collections(collection_a: Path, collection_b: Path) -> dict[str, Any]:
    summary_a = build_collection_summary(collection_a)
    summary_b = build_collection_summary(collection_b)
    metadata_a = summary_a["metadata"]
    metadata_b = summary_b["metadata"]
    label_a = metadata_a["runLabel"]
    label_b = metadata_b["runLabel"]

    api_summary_a = summary_a["apiCallNavigator"]
    api_summary_b = summary_b["apiCallNavigator"]
    pipeline_summary_a = summary_a["pipelineNavigator"]
    pipeline_summary_b = summary_b["pipelineNavigator"]
    cb_summary_a = summary_a["commandBuffers"]
    cb_summary_b = summary_b["commandBuffers"]
    re_summary = compare_re_summaries(summary_a["renderEncoderDetails"], summary_b["renderEncoderDetails"])

    result = {
        "schemaVersion": 1,
        "pairLabel": f"{label_a}-vs-{label_b}",
        "runA": {
            "collectionDir": str(collection_a),
            "runLabel": label_a,
            "gputraceName": metadata_a["gputraceName"],
            "snapshotDir": metadata_a["snapshotDir"],
        },
        "runB": {
            "collectionDir": str(collection_b),
            "runLabel": label_b,
            "gputraceName": metadata_b["gputraceName"],
            "snapshotDir": metadata_b["snapshotDir"],
        },
        "apiCallNavigator": {
            "commandBufferCountA": api_summary_a["commandBufferCount"],
            "commandBufferCountB": api_summary_b["commandBufferCount"],
            "renderEncoderCountA": api_summary_a["renderEncoderCount"],
            "renderEncoderCountB": api_summary_b["renderEncoderCount"],
            "presentDrawableCountA": api_summary_a["presentDrawableCount"],
            "presentDrawableCountB": api_summary_b["presentDrawableCount"],
            "topRowDiff": compare_top_rows(api_summary_a["topRows"], api_summary_b["topRows"]),
        },
        "pipelineNavigator": {
            "uniqueRowCountA": pipeline_summary_a["uniqueRowCount"],
            "uniqueRowCountB": pipeline_summary_b["uniqueRowCount"],
            "topRowDiff": compare_top_rows(pipeline_summary_a["topRows"], pipeline_summary_b["topRows"]),
        },
        "commandBuffers": compare_cb_summaries(cb_summary_a, cb_summary_b),
        "renderEncoderDetails": re_summary,
    }
    result["firstPassConclusion"] = first_pass_conclusion(result)
    return result


def first_pass_conclusion(result: dict[str, Any]) -> dict[str, Any]:
    command_buffers = result["commandBuffers"]
    api = result["apiCallNavigator"]
    pipeline = result["pipelineNavigator"]
    re_details = result.get("renderEncoderDetails")

    structure_diff = (
        api["commandBufferCountA"] != api["commandBufferCountB"]
        or api["renderEncoderCountA"] != api["renderEncoderCountB"]
        or api["topRowDiff"]["differentCount"] > 0
        or command_buffers["differentCount"] > 0
        or pipeline["topRowDiff"]["differentCount"] > 0
    )
    if structure_diff:
        return {
            "status": "different-before-key-pass",
            "summary": "Command Buffer / Render Encoder / Pipeline State structure already differs between the two runs.",
        }

    if re_details is None:
        return {
            "status": "needs-key-pass-details",
            "summary": "High-level structure looks aligned so far; collect key_pass_details.json next to compare key render-pass summaries.",
        }

    if re_details["entryCountDiff"] or re_details["differentEntryCount"] > 0:
        return {
            "status": "different-at-key-pass",
            "summary": "High-level structure is similar, but key Render Encoder summaries differ.",
        }

    return {
        "status": "no-structural-diff-detected",
        "summary": "No structural diff was detected in the collected artifacts; continue with replacement-usage or shader-semantics checks.",
    }


def render_summary_text(result: dict[str, Any]) -> str:
    lines = [
        f"Pair: {result['pairLabel']}",
        f"Run A: {result['runA']['runLabel']} ({result['runA']['gputraceName']})",
        f"Run B: {result['runB']['runLabel']} ({result['runB']['gputraceName']})",
        "",
        "API call navigator:",
        f"- Command Buffers: {result['apiCallNavigator']['commandBufferCountA']} vs {result['apiCallNavigator']['commandBufferCountB']}",
        f"- Render Encoders: {result['apiCallNavigator']['renderEncoderCountA']} vs {result['apiCallNavigator']['renderEncoderCountB']}",
        f"- presentDrawable: {result['apiCallNavigator']['presentDrawableCountA']} vs {result['apiCallNavigator']['presentDrawableCountB']}",
        "",
        "Command Buffer structure:",
        f"- Paired CBs: {result['commandBuffers']['pairedCommandBufferCount']}",
        f"- Different CB nodes: {result['commandBuffers']['differentCount']}",
        "",
        "Pipeline navigator:",
        f"- Unique rows: {result['pipelineNavigator']['uniqueRowCountA']} vs {result['pipelineNavigator']['uniqueRowCountB']}",
        f"- Top-row differences: {result['pipelineNavigator']['topRowDiff']['differentCount']}",
        "",
    ]

    re_details = result.get("renderEncoderDetails")
    if re_details is None:
        lines.append("Render Encoder details: not collected")
    else:
        lines.extend(
            [
                "Render Encoder details:",
                f"- Entries: {re_details['entryCountA']} vs {re_details['entryCountB']}",
                f"- Different entries: {re_details['differentEntryCount']}",
            ]
        )

    lines.extend(
        [
            "",
            f"Conclusion: {result['firstPassConclusion']['status']}",
            result['firstPassConclusion']['summary'],
        ]
    )
    return "\n".join(lines) + "\n"


def collect_run_artifacts(
    *,
    snapshot_dir: Path,
    output_root: Path,
    include_re_details: bool,
    re_count: int,
    max_steps: int,
    force: bool,
) -> Path:
    meta = resolve_snapshot_meta(snapshot_dir)
    run_label = str(meta.get("label") or snapshot_dir.parent.name)
    bundle_id = str(meta.get("bundleId") or snapshot_dir.name)
    gputrace_path = resolve_gputrace_path(snapshot_dir, meta)

    collection_dir = output_root / bundle_id / run_label
    if collection_dir.exists():
        if not force:
            raise SystemExit(f"collection directory already exists: {collection_dir}")
        shutil.rmtree(collection_dir)

    collection_dir.mkdir(parents=True, exist_ok=False)
    frame_dump_dir = collection_dir / "frame_dump"

    run_command([sys.executable, str(XCODE_GPU_OPS), "open", str(gputrace_path), "--no-analysis"])
    run_command([sys.executable, str(XCODE_GPU_OPS), "dump", "-o", str(frame_dump_dir)])

    run_command([sys.executable, str(XCODE_GPU_OPS), "open", str(gputrace_path), "--no-analysis"])
    run_command([sys.executable, str(COLLECT_CBS), "-o", str(collection_dir / "cb_data.json")])

    if include_re_details:
        run_command([sys.executable, str(XCODE_GPU_OPS), "open", str(gputrace_path)])
        run_command(
            [
                sys.executable,
                str(COLLECT_RE_DETAILS),
                str(max_steps),
                "-o",
                str(collection_dir / "key_pass_details.json"),
                "--re-count",
                str(re_count),
            ]
        )

    collection_meta = {
        "schemaVersion": 1,
        "runLabel": run_label,
        "bundleId": bundle_id,
        "snapshotDir": str(snapshot_dir),
        "gputracePath": str(gputrace_path),
        "gputraceName": gputrace_path.name,
        "includeReDetails": include_re_details,
    }
    write_json(collection_dir / "collection.meta.json", collection_meta)
    return collection_dir


def compare_command(args: argparse.Namespace) -> int:
    collection_a = Path(args.collection_a).expanduser().resolve()
    collection_b = Path(args.collection_b).expanduser().resolve()
    result = compare_collections(collection_a, collection_b)

    output_path = Path(args.output).expanduser().resolve() if args.output else default_comparison_path(collection_a, collection_b)
    output_dir = output_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    write_json(output_path, result)
    (output_dir / "summary.txt").write_text(render_summary_text(result), encoding="utf-8")
    print(output_path)
    return 0


def default_comparison_path(collection_a: Path, collection_b: Path) -> Path:
    parent = collection_a.parent if collection_a.parent == collection_b.parent else DEFAULT_OUTPUT_ROOT
    label = f"{collection_a.name}-vs-{collection_b.name}"
    return parent / label / "comparison.json"


def collect_run_command(args: argparse.Namespace) -> int:
    snapshot_dir = resolve_snapshot_dir(
        bundle_id=args.bundle_id,
        run_label=args.run_label,
        run_path=args.run_path,
        runs_root=args.runs_root,
    )
    collection_dir = collect_run_artifacts(
        snapshot_dir=snapshot_dir,
        output_root=Path(args.output_root).expanduser().resolve(),
        include_re_details=args.include_re_details,
        re_count=args.re_count,
        max_steps=args.max_steps,
        force=args.force,
    )
    print(collection_dir)
    return 0


def collect_pair_command(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root).expanduser().resolve()
    snapshot_a = resolve_snapshot_dir(
        bundle_id=args.bundle_id,
        run_label=args.run_a,
        run_path=None,
        runs_root=args.runs_root,
    )
    snapshot_b = resolve_snapshot_dir(
        bundle_id=args.bundle_id,
        run_label=args.run_b,
        run_path=None,
        runs_root=args.runs_root,
    )
    collection_a = collect_run_artifacts(
        snapshot_dir=snapshot_a,
        output_root=output_root,
        include_re_details=args.include_re_details,
        re_count=args.re_count,
        max_steps=args.max_steps,
        force=args.force,
    )
    collection_b = collect_run_artifacts(
        snapshot_dir=snapshot_b,
        output_root=output_root,
        include_re_details=args.include_re_details,
        re_count=args.re_count,
        max_steps=args.max_steps,
        force=args.force,
    )
    comparison_path = default_comparison_path(collection_a, collection_b)
    compare_args = argparse.Namespace(
        collection_a=str(collection_a),
        collection_b=str(collection_b),
        output=str(comparison_path),
    )
    return compare_command(compare_args)


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "collect-run":
        return collect_run_command(args)
    if args.command == "compare":
        return compare_command(args)
    if args.command == "collect-pair":
        return collect_pair_command(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
