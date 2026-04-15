from __future__ import annotations

import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_SCRIPT = REPO_ROOT / "Scripts" / "capture_target_compare_runner.py"


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
                "timestamp": "2026-04-15T13:00:04Z",
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
                "timestamp": "2026-04-15T13:00:00Z",
                "event": "playcover_launch_enter",
                "bundleId": bundle_id,
                "pid": 654,
                "processLaunchId": "launch-pair-1",
            },
            {
                "timestamp": "2026-04-15T13:00:01Z",
                "event": "bridge_registration_established",
                "bundleId": bundle_id,
                "pid": 654,
                "processLaunchId": "launch-pair-1",
            },
            {
                "timestamp": "2026-04-15T13:00:02Z",
                "event": "playcover_launch_complete",
                "bundleId": bundle_id,
                "pid": 654,
                "processLaunchId": "launch-pair-1",
                "metalCaptureEnabled": True,
                "injectMetalCaptureEnvironment": True,
                "shaderSourceReplacementEnabled": False,
            },
        ],
    )


def make_gputrace(trace_dir: Path, visible_hash: str, extra_missing_hash: str) -> None:
    trace_dir.mkdir(parents=True, exist_ok=True)
    (trace_dir / visible_hash).write_text(
        "#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1.0); }\n",
        encoding="utf-8",
    )
    (trace_dir / "index").write_text(f"{visible_hash} {extra_missing_hash}\n", encoding="utf-8")


class CaptureTargetCompareRunnerTests(unittest.TestCase):
    def test_finalize_pair_creates_both_snapshots_and_compare_report(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            diagnostics_root = root / "RuntimeLaunchDiagnostics"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"
            device_trace = root / "device.gputrace"
            queue_scope_trace = root / "queue_scope.gputrace"

            make_container(container_root, bundle_id)
            make_launch_events(diagnostics_root, bundle_id)
            make_gputrace(device_trace, "0123456789ABCDEF", "AAAAAAAAAAAAAAAA")
            make_gputrace(queue_scope_trace, "FEDCBA9876543210", "BBBBBBBBBBBBBBBB")

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-pair",
                    "--bundle-id",
                    bundle_id,
                    "--pair-label",
                    "fresh-round-1",
                    "--container",
                    str(container_root),
                    "--diagnostics-root",
                    str(diagnostics_root),
                    "--output-root",
                    str(output_root),
                    "--device-gputrace",
                    str(device_trace),
                    "--queue-scope-gputrace",
                    str(queue_scope_trace),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            device_snapshot = output_root / "fresh-round-1-device" / bundle_id
            queue_scope_snapshot = output_root / "fresh-round-1-queue_scope" / bundle_id
            report_path = output_root / "reports" / "fresh-round-1-device-vs-queue_scope" / f"{bundle_id}.json"

            self.assertTrue(device_snapshot.is_dir())
            self.assertTrue(queue_scope_snapshot.is_dir())
            self.assertTrue(report_path.is_file())
            self.assertIn("pair compare report", completed.stdout)

            report = json.loads(report_path.read_text(encoding="utf-8"))
            snapshot_comparison = report["comparison"]["snapshotComparison"]
            self.assertEqual(snapshot_comparison["runA"]["captureTarget"], "device")
            self.assertEqual(snapshot_comparison["runB"]["captureTarget"], "queue_scope")
            self.assertEqual(snapshot_comparison["runA"]["launchDiagnostics"]["summaryCount"], 1)
            self.assertEqual(snapshot_comparison["runB"]["launchDiagnostics"]["summaryCount"], 1)


if __name__ == "__main__":
    unittest.main()
