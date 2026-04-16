from __future__ import annotations

import json
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_SCRIPT = REPO_ROOT / "Scripts" / "snapshot_capture_run.py"
SNAPSHOT_SPEC = importlib.util.spec_from_file_location("snapshot_capture_run", SNAPSHOT_SCRIPT)
assert SNAPSHOT_SPEC is not None and SNAPSHOT_SPEC.loader is not None
snapshot_capture_run = importlib.util.module_from_spec(SNAPSHOT_SPEC)
SNAPSHOT_SPEC.loader.exec_module(snapshot_capture_run)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


def make_container(container_root: Path, bundle_id: str) -> None:
    corpus_dir = container_root / "ShaderCorpus" / bundle_id
    module_dir = corpus_dir / "modules" / "module-1"
    settings_dir = container_root / "App Settings"

    module_dir.mkdir(parents=True, exist_ok=True)
    settings_dir.mkdir(parents=True, exist_ok=True)

    write_jsonl(
        corpus_dir / "manifest.jsonl",
        [
            {
                "event": "capture",
                "bundleId": bundle_id,
                "selector": "newLibraryWithData:error:",
                "moduleKey": "module-1",
                "captureAction": "saved",
                "functionTypes": ["fragment"],
                "timestamp": "2026-04-15T12:00:04Z",
            }
        ],
    )
    (module_dir / "module.bc").write_bytes(b"bc")
    (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
    (module_dir / "module.generated.metal").write_text(
        "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n",
        encoding="utf-8",
    )
    (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")
    with (settings_dir / f"{bundle_id}.plist").open("wb") as handle:
        plistlib.dump({"shaderSourceReplacementEnabled": False}, handle)


def make_launch_events(diagnostics_root: Path, bundle_id: str) -> None:
    write_jsonl(
        diagnostics_root / bundle_id / "launch-events.jsonl",
        [
            {
                "timestamp": "2026-04-15T12:00:00Z",
                "event": "playcover_launch_enter",
                "bundleId": bundle_id,
                "pid": 321,
                "processLaunchId": "launch-1",
            },
            {
                "timestamp": "2026-04-15T12:00:01Z",
                "event": "playcover_library_injection_installed",
                "bundleId": bundle_id,
                "pid": 321,
                "processLaunchId": "launch-1",
            },
            {
                "timestamp": "2026-04-15T12:00:02Z",
                "event": "bridge_registration_established",
                "bundleId": bundle_id,
                "pid": 321,
                "processLaunchId": "launch-1",
            },
            {
                "timestamp": "2026-04-15T12:00:03Z",
                "event": "playcover_launch_complete",
                "bundleId": bundle_id,
                "pid": 321,
                "processLaunchId": "launch-1",
                "metalCaptureEnabled": True,
                "injectMetalCaptureEnvironment": True,
                "shaderSourceReplacementEnabled": False,
            },
        ],
    )


def make_gputrace(trace_dir: Path, visible_hash: str) -> None:
    trace_dir.mkdir(parents=True, exist_ok=True)
    (trace_dir / visible_hash).write_text(
        "#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1.0); }\n",
        encoding="utf-8",
    )
    (trace_dir / "index").write_text(f"{visible_hash}\n", encoding="utf-8")


def make_capture_status(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "available": True,
                "supports_gpu_trace": True,
                "enabled": True,
                "diagnostic_summary": "enabled=true, trackedCommandQueues=2",
                "queue_discovery_installed": True,
                "tracked_command_queue_count": 2,
                "latest_command_queue_label": "queue.discovery",
                "latest_command_queue_device_name": "Apple M4",
                "latest_command_queue_class_name": "CaptureMTLCommandQueue",
                "most_active_command_queue_label": "queue.render.main",
                "most_active_command_queue_device_name": "Apple M4",
                "most_active_command_queue_class_name": "CaptureMTLCommandQueue",
                "most_active_command_queue_summary": "class=CaptureMTLCommandQueue, commits=9",
                "queue_selection_alignment": "inconclusive_zero_activity",
                "tracked_command_queues": [
                    {
                        "label": "queue.render.main",
                        "class_name": "CaptureMTLCommandQueue",
                        "device_name": "Apple M4",
                        "source": "newCommandQueue",
                        "discovery_count": 3,
                        "ranking_score": 60,
                        "command_buffer_creation_count": 12,
                        "command_buffer_commit_count": 9,
                        "activity_score": 1210,
                    },
                    {
                        "label": "queue.upload",
                        "class_name": "CaptureMTLCommandQueue",
                        "device_name": "Apple M4",
                        "source": "newCommandQueue",
                        "discovery_count": 1,
                        "ranking_score": 25,
                        "command_buffer_creation_count": 1,
                        "command_buffer_commit_count": 1,
                        "activity_score": 125,
                    },
                ],
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


class SnapshotCaptureRunTests(unittest.TestCase):
    def test_copy_bundle_with_ditto_uses_ditto_command(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "trace.gputrace"
            destination = root / "snapshot" / "trace.gputrace"
            make_gputrace(source, "0123456789ABCDEF")

            with mock.patch.object(snapshot_capture_run.subprocess, "run") as run_mock:
                run_mock.return_value = subprocess.CompletedProcess(
                    args=["ditto", str(source), str(destination)],
                    returncode=0,
                )
                snapshot_capture_run.copy_bundle_with_ditto(source, destination)

            run_mock.assert_called_once_with(["ditto", str(source), str(destination)], check=False)

    def test_snapshot_capture_run_preserves_launch_diagnostics_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            diagnostics_root = root / "RuntimeLaunchDiagnostics"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"
            trace_dir = root / "demo.gputrace"
            capture_status_path = root / "capture-status.json"

            make_container(container_root, bundle_id)
            make_launch_events(diagnostics_root, bundle_id)
            make_gputrace(trace_dir, "0123456789ABCDEF")
            make_capture_status(capture_status_path)

            subprocess.run(
                [
                    "python3",
                    str(SNAPSHOT_SCRIPT),
                    "--bundle-id",
                    bundle_id,
                    "--label",
                    "round-1-device",
                    "--container",
                    str(container_root),
                    "--diagnostics-root",
                    str(diagnostics_root),
                    "--output-root",
                    str(output_root),
                    "--capture-target",
                    "device",
                    "--gputrace",
                    str(trace_dir),
                    "--capture-status-json",
                    str(capture_status_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            snapshot_dir = output_root / "round-1-device" / bundle_id
            meta = json.loads((snapshot_dir / "snapshot.meta.json").read_text(encoding="utf-8"))
            launch_summary = json.loads(
                (snapshot_dir / "runtime-launch-diagnostics" / "launch-summary.json").read_text(encoding="utf-8")
            )

            self.assertEqual(meta["captureTarget"], "device")
            self.assertEqual(meta["launchDiagnostics"]["eventCount"], 4)
            self.assertEqual(meta["launchDiagnostics"]["summaryCount"], 1)
            self.assertEqual(meta["launchDiagnostics"]["processLaunchIds"], ["launch-1"])
            self.assertEqual(meta["launchDiagnostics"]["latestLastEvent"], "playcover_launch_complete")
            self.assertEqual(meta["launchDiagnostics"]["latestLaunchSettings"]["metalCaptureEnabled"], True)
            self.assertEqual(meta["captureStatus"]["trackedCommandQueueCount"], 2)
            self.assertEqual(meta["captureStatus"]["mostActiveCommandQueueLabel"], "queue.render.main")
            self.assertEqual(meta["captureStatus"]["queueSelectionAlignment"], "inconclusive_zero_activity")
            self.assertEqual(len(meta["captureStatus"]["trackedCommandQueues"]), 2)
            self.assertEqual(meta["copiedArtifacts"]["launchEventsPath"], "runtime-launch-diagnostics/launch-events.jsonl")
            self.assertEqual(meta["copiedArtifacts"]["launchSummaryJsonPath"], "runtime-launch-diagnostics/launch-summary.json")
            self.assertEqual(meta["copiedArtifacts"]["captureStatusPath"], "capture-status/get_capture_status.json")
            self.assertEqual(meta["copiedArtifacts"]["captureStatusSummaryPath"], "capture-status/queue-activity-summary.txt")
            self.assertEqual(launch_summary["summaryCount"], 1)
            self.assertEqual(launch_summary["runs"][0]["processLaunchId"], "launch-1")
            self.assertTrue((snapshot_dir / "runtime-launch-diagnostics" / "launch-summary.txt").is_file())
            self.assertTrue((snapshot_dir / "capture-status" / "queue-activity-summary.txt").is_file())


if __name__ == "__main__":
    unittest.main()
