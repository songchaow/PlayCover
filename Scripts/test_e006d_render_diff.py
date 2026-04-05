from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "Scripts" / "e006d_render_diff.py"


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def make_collection(
    root: Path,
    name: str,
    *,
    pipeline_rows: list[str],
    cb_children: list[list[str]],
    api_rows: list[str] | None = None,
    key_pass_details: list[dict] | None = None,
) -> Path:
    collection_dir = root / name
    write_json(
        collection_dir / "collection.meta.json",
        {
            "schemaVersion": 1,
            "runLabel": name,
            "bundleId": "com.miHoYo.Yuanshen",
            "snapshotDir": f"/tmp/{name}",
            "gputracePath": f"/tmp/{name}.gputrace",
            "gputraceName": f"{name}.gputrace",
            "includeReDetails": key_pass_details is not None,
        },
    )
    write_json(
        collection_dir / "frame_dump" / "navigator_api_call.json",
        [
            {"index": index, "text": row, "selected": False, "has_disclosure": row.startswith("Command Buffer"), "expanded": False}
            for index, row in enumerate(
                api_rows
                or [
                    "Command Buffer 0 0x111",
                    "Render Encoder 0 0x222",
                    "1 [presentDrawable:0x333]",
                ]
            )
        ],
    )
    write_json(
        collection_dir / "frame_dump" / "navigator_pipeline_state.json",
        [
            {"index": index, "text": row, "selected": False, "has_disclosure": False, "expanded": False}
            for index, row in enumerate(pipeline_rows)
        ],
    )
    write_json(
        collection_dir / "cb_data.json",
        {
            f"Command Buffer {index} 0x{index + 1:03X}": children
            for index, children in enumerate(cb_children)
        },
    )
    if key_pass_details is not None:
        write_json(collection_dir / "key_pass_details.json", key_pass_details)
    return collection_dir


class E006DRenderDiffTests(unittest.TestCase):
    def test_compare_detects_pre_key_pass_structure_difference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            collection_a = make_collection(
                root,
                "replacement-off-run1",
                pipeline_rows=["Login Base", "Bloom"],
                cb_children=[["Render Encoder 0 0xAAA", "1 [presentDrawable:0xBBB]"]],
            )
            collection_b = make_collection(
                root,
                "replacement-on-run5",
                pipeline_rows=["Login Base", "Bloom", "TAA Resolve"],
                cb_children=[["Render Encoder 0 0xAAA", "Render Encoder 1 0xCCC", "1 [presentDrawable:0xBBB]"]],
            )
            output_path = root / "comparison.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "compare",
                    "--collection-a",
                    str(collection_a),
                    "--collection-b",
                    str(collection_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["firstPassConclusion"]["status"], "different-before-key-pass")
            self.assertGreater(report["commandBuffers"]["differentCount"], 0)
            self.assertTrue((output_path.parent / "summary.txt").is_file())

    def test_compare_requests_key_pass_details_when_structure_matches(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            collection_a = make_collection(
                root,
                "replacement-off-run1",
                pipeline_rows=["Login Base", "Bloom"],
                cb_children=[["Render Encoder 0 0xAAA", "1 [presentDrawable:0xBBB]"]],
            )
            collection_b = make_collection(
                root,
                "replacement-on-run5",
                pipeline_rows=["Login Base", "Bloom"],
                cb_children=[["Render Encoder 0 0xDDD", "1 [presentDrawable:0xEEE]"]],
            )
            output_path = root / "comparison.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "compare",
                    "--collection-a",
                    str(collection_a),
                    "--collection-b",
                    str(collection_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["firstPassConclusion"]["status"], "needs-key-pass-details")
            self.assertIsNone(report["renderEncoderDetails"])

    def test_compare_detects_key_pass_difference_when_details_exist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            shared_kwargs = {
                "pipeline_rows": ["Login Base", "Bloom"],
                "cb_children": [["Render Encoder 0 0xAAA", "1 [presentDrawable:0xBBB]"]],
            }
            collection_a = make_collection(
                root,
                "replacement-off-run1",
                key_pass_details=[
                    {
                        "command_buffer": "Command Buffer 0 0x111",
                        "render_encoder": "Render Encoder 0 0xAAA",
                        "draw_call": "1 drawIndexedPrimitives",
                        "summary": {
                            "pipeline_state": "Login Base",
                            "vertex_function": "vert_login",
                            "fragment_function": "frag_login",
                            "attachments": [{"slot": "Color 0", "name": "HDR", "type": "Texture 2D"}],
                        },
                    }
                ],
                **shared_kwargs,
            )
            collection_b = make_collection(
                root,
                "replacement-on-run5",
                key_pass_details=[
                    {
                        "command_buffer": "Command Buffer 0 0x222",
                        "render_encoder": "Render Encoder 0 0xBBB",
                        "draw_call": "1 drawIndexedPrimitives",
                        "summary": {
                            "pipeline_state": "Login Base Altered",
                            "vertex_function": "vert_login",
                            "fragment_function": "frag_login_alt",
                            "attachments": [{"slot": "Color 0", "name": "HDR", "type": "Texture 2D"}],
                        },
                    }
                ],
                **shared_kwargs,
            )
            output_path = root / "comparison.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "compare",
                    "--collection-a",
                    str(collection_a),
                    "--collection-b",
                    str(collection_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["firstPassConclusion"]["status"], "different-at-key-pass")
            self.assertEqual(report["renderEncoderDetails"]["differentEntryCount"], 1)

    def test_compare_detects_api_call_row_difference_in_conclusion(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            collection_a = make_collection(
                root,
                "replacement-off-run1",
                pipeline_rows=["Login Base", "Bloom"],
                cb_children=[["Render Encoder 0 0xAAA", "1 [presentDrawable:0xBBB]"]],
            )
            collection_b = make_collection(
                root,
                "replacement-on-run5",
                pipeline_rows=["Login Base", "Bloom"],
                cb_children=[["Render Encoder 0 0xAAA", "2 [presentDrawable:0xBBB]", "Memory 512 MiB"]],
                api_rows=[
                    "Command Buffer 0 0x111",
                    "Render Encoder 0 0x222",
                    "Blit Encoder 0 0x444",
                    "1 [presentDrawable:0x333]",
                ],
            )
            output_path = root / "comparison.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "compare",
                    "--collection-a",
                    str(collection_a),
                    "--collection-b",
                    str(collection_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertGreater(report["apiCallNavigator"]["topRowDiff"]["differentCount"], 0)
            self.assertEqual(report["firstPassConclusion"]["status"], "different-before-key-pass")

    def test_compare_detects_mismatched_key_pass_entry_counts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            shared_kwargs = {
                "pipeline_rows": ["Login Base", "Bloom"],
                "cb_children": [["Render Encoder 0 0xAAA", "1 [presentDrawable:0xBBB]"]],
            }
            collection_a = make_collection(
                root,
                "replacement-off-run1",
                key_pass_details=[
                    {
                        "command_buffer": "Command Buffer 0 0x111",
                        "render_encoder": "Render Encoder 0 0xAAA",
                        "draw_call": "1 drawIndexedPrimitives",
                        "summary": {
                            "pipeline_state": "Login Base",
                            "vertex_function": "vert_login",
                            "fragment_function": "frag_login",
                            "attachments": [],
                        },
                    }
                ],
                **shared_kwargs,
            )
            collection_b = make_collection(
                root,
                "replacement-on-run5",
                key_pass_details=[
                    {
                        "command_buffer": "Command Buffer 0 0x111",
                        "render_encoder": "Render Encoder 0 0xAAA",
                        "draw_call": "1 drawIndexedPrimitives",
                        "summary": {
                            "pipeline_state": "Login Base",
                            "vertex_function": "vert_login",
                            "fragment_function": "frag_login",
                            "attachments": [],
                        },
                    },
                    {
                        "command_buffer": "Command Buffer 0 0x111",
                        "render_encoder": "Render Encoder 1 0xBBB",
                        "draw_call": "2 drawIndexedPrimitives",
                        "summary": {
                            "pipeline_state": "Bloom",
                            "vertex_function": "vert_bloom",
                            "fragment_function": "frag_bloom",
                            "attachments": [],
                        },
                    },
                ],
                **shared_kwargs,
            )
            output_path = root / "comparison.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "compare",
                    "--collection-a",
                    str(collection_a),
                    "--collection-b",
                    str(collection_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertTrue(report["renderEncoderDetails"]["entryCountDiff"])
            self.assertEqual(report["firstPassConclusion"]["status"], "different-at-key-pass")


if __name__ == "__main__":
    unittest.main()
