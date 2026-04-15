from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "Scripts" / "capture_target_hollow_encoder_report.py"


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def make_collection(
    root: Path,
    run_label: str,
    capture_target: str,
    *,
    api_rows: list[str],
    cb_children: list[list[str]],
) -> Path:
    snapshot_dir = root / "snapshots" / run_label / "com.example.demo"
    write_json(
        snapshot_dir / "snapshot.meta.json",
        {
            "bundleId": "com.example.demo",
            "captureTarget": capture_target,
            "label": run_label,
            "snapshotBundleDir": str(snapshot_dir),
        },
    )

    collection_dir = root / "collections" / run_label
    write_json(
        collection_dir / "collection.meta.json",
        {
            "schemaVersion": 1,
            "runLabel": run_label,
            "bundleId": "com.example.demo",
            "snapshotDir": str(snapshot_dir),
            "gputracePath": f"/tmp/{run_label}.gputrace",
            "gputraceName": f"{run_label}.gputrace",
            "includeReDetails": False,
        },
    )
    write_json(
        collection_dir / "frame_dump" / "navigator_api_call.json",
        [
            {
                "index": index,
                "text": row,
                "selected": False,
                "has_disclosure": row.startswith("Command Buffer"),
                "expanded": False,
            }
            for index, row in enumerate(api_rows)
        ],
    )
    write_json(
        collection_dir / "frame_dump" / "navigator_pipeline_state.json",
        [{"index": 0, "text": "Login Base", "selected": False, "has_disclosure": False, "expanded": False}],
    )
    write_json(
        collection_dir / "cb_data.json",
        {
            f"Command Buffer {index} 0x{index + 1:03X}": children
            for index, children in enumerate(cb_children)
        },
    )
    return collection_dir


class CaptureTargetHollowEncoderReportTests(unittest.TestCase):
    def test_report_separates_empty_branch_and_detects_isomorphic_nonempty_slots(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            device = make_collection(
                root,
                "ctf011-device",
                "device",
                api_rows=["Command Buffer 0 0x111", "Render Encoder 0 0xAAA", "Render Encoder 1 0xBBB", "1 [presentDrawable:0xCCC]"],
                cb_children=[["Render Encoder 0 0xAAA", "Render Encoder 1 0xBBB", "1 [presentDrawable:0xCCC]"]],
            )
            scope = make_collection(
                root,
                "ctf011-scope",
                "scope",
                api_rows=["Command Buffer 0 0x222", "Render Encoder 0 0xDDD", "Render Encoder 1 0xEEE", "1 [presentDrawable:0xFFF]"],
                cb_children=[["Render Encoder 0 0xDDD", "Render Encoder 1 0xEEE", "1 [presentDrawable:0xFFF]"]],
            )
            queue_scope = make_collection(
                root,
                "ctf011-queue-scope",
                "queue_scope",
                api_rows=[],
                cb_children=[],
            )
            output_path = root / "report.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--collection",
                    str(device),
                    "--collection",
                    str(scope),
                    "--collection",
                    str(queue_scope),
                    "--empty-target",
                    "queue_scope",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["emptyCaptureTargets"], ["queue_scope"])
            self.assertEqual(report["nonEmptyTargets"], ["device", "scope"])
            self.assertTrue(report["slotComparison"]["isomorphicAcrossNonEmptyTargets"])
            self.assertEqual(report["conclusion"]["status"], "shared-slot-structure-across-nonempty-targets")
            self.assertTrue(output_path.with_name("summary.txt").is_file())

    def test_report_detects_slot_difference_across_nonempty_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            device = make_collection(
                root,
                "ctf011-device",
                "device",
                api_rows=["Command Buffer 0 0x111", "Render Encoder 0 0xAAA", "1 [presentDrawable:0xCCC]"],
                cb_children=[["Render Encoder 0 0xAAA", "1 [presentDrawable:0xCCC]"]],
            )
            queue = make_collection(
                root,
                "ctf011-queue",
                "queue",
                api_rows=["Command Buffer 0 0x222", "Render Encoder 0 0xDDD", "Memory 512 MiB", "1 [presentDrawable:0xFFF]"],
                cb_children=[["Render Encoder 0 0xDDD", "Memory 512 MiB", "1 [presentDrawable:0xFFF]"]],
            )
            output_path = root / "report.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--collection",
                    str(device),
                    "--collection",
                    str(queue),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertFalse(report["slotComparison"]["isomorphicAcrossNonEmptyTargets"])
            self.assertEqual(report["slotComparison"]["differingSlotCount"], 1)
            self.assertEqual(report["conclusion"]["status"], "slot-structure-differs-across-nonempty-targets")

    def test_report_requires_two_nonempty_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            device = make_collection(
                root,
                "ctf011-device",
                "device",
                api_rows=["Command Buffer 0 0x111", "Render Encoder 0 0xAAA"],
                cb_children=[["Render Encoder 0 0xAAA"]],
            )
            queue_scope = make_collection(
                root,
                "ctf011-queue-scope",
                "queue_scope",
                api_rows=[],
                cb_children=[],
            )
            output_path = root / "report.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--collection",
                    str(device),
                    "--collection",
                    str(queue_scope),
                    "--empty-target",
                    "queue_scope",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["conclusion"]["status"], "needs-more-nonempty-targets")


if __name__ == "__main__":
    unittest.main()
