from __future__ import annotations

import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_SCRIPT = REPO_ROOT / "Scripts" / "e006e_launch_matrix_runner.py"


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


class E006ELaunchMatrixRunnerTests(unittest.TestCase):
    def test_prepare_case_updates_both_runtime_switches(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            settings_path = container_root / "App Settings" / "com.example.qqspeed.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "metalCaptureEnabled": False,
                        "shaderSourceReplacementEnabled": True,
                    },
                    handle,
                )

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "prepare-case",
                    "--bundle-id",
                    "com.example.qqspeed",
                    "--case",
                    "B",
                    "--container",
                    str(container_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            with settings_path.open("rb") as handle:
                payload = plistlib.load(handle)

            self.assertEqual(payload["metalCaptureEnabled"], True)
            self.assertEqual(payload["shaderSourceReplacementEnabled"], False)
            self.assertIn("prepared case-b-capture-on-replacement-off", completed.stdout)
            self.assertIn("runtime_launch_diagnostics_summary.py --bundle-id com.example.qqspeed --limit 5", completed.stdout)
            self.assertIn("finalize-case --bundle-id com.example.qqspeed --case B", completed.stdout)

    def test_finalize_case_copies_launch_diagnostics_and_manifest_tail(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            diagnostics_root = root / "RuntimeLaunchDiagnostics"
            output_root = root / "output"
            bundle_id = "com.example.qqspeed"

            settings_path = container_root / "App Settings" / f"{bundle_id}.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "metalCaptureEnabled": True,
                        "shaderSourceReplacementEnabled": True,
                    },
                    handle,
                )

            write_jsonl(
                diagnostics_root / bundle_id / "launch-events.jsonl",
                [
                    {
                        "timestamp": "2026-04-07T01:00:00Z",
                        "event": "playcover_launch_enter",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:00:01Z",
                        "event": "playcover_capture_library_preload_checked",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "loaded": "true",
                        "needed": "true",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:00:02Z",
                        "event": "playcover_library_injection_installed",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:00:03Z",
                        "event": "bridge_listener_command_listener_ready",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "sessionId": "runtime-1",
                        "isMainThread": True,
                    },
                ],
            )

            write_jsonl(
                container_root / "ShaderCorpus" / bundle_id / "manifest.jsonl",
                [
                    {"event": "capture", "timestamp": "2026-04-07T01:00:04Z", "moduleKey": "module-a"},
                    {
                        "event": "replacement_attempt",
                        "timestamp": "2026-04-07T01:00:05Z",
                        "moduleKeys": ["module-a"],
                        "outcome": "failed",
                    },
                    {
                        "event": "replacement",
                        "timestamp": "2026-04-07T01:00:06Z",
                        "moduleKeys": ["module-a"],
                    },
                ],
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-case",
                    "--bundle-id",
                    bundle_id,
                    "--case",
                    "D",
                    "--container",
                    str(container_root),
                    "--diagnostics-root",
                    str(diagnostics_root),
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            case_dir = output_root / "case-d-capture-on-replacement-on" / bundle_id
            self.assertTrue((case_dir / f"{bundle_id}.plist").is_file())
            self.assertTrue((case_dir / "launch-events.jsonl").is_file())
            self.assertTrue((case_dir / "launch-summary.json").is_file())
            self.assertTrue((case_dir / "launch-summary.txt").is_file())
            self.assertTrue((case_dir / "manifest-tail.json").is_file())
            self.assertTrue((case_dir / "case.meta.json").is_file())

            case_meta = json.loads((case_dir / "case.meta.json").read_text(encoding="utf-8"))
            self.assertEqual(case_meta["launchDiagnostics"]["latestLastEvent"], "bridge_listener_command_listener_ready")
            self.assertEqual(case_meta["settingsMatchedExpectation"], True)

            manifest_tail = json.loads((case_dir / "manifest-tail.json").read_text(encoding="utf-8"))
            self.assertEqual(len(manifest_tail), 3)
            self.assertIn("case snapshot created", completed.stdout)

    def test_analyze_reports_present_and_missing_cases(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output_root = root / "output"
            bundle_id = "com.example.qqspeed"
            case_dir = output_root / "case-b-capture-on-replacement-off" / bundle_id
            case_dir.mkdir(parents=True, exist_ok=True)
            (case_dir / "case.meta.json").write_text(
                json.dumps(
                    {
                        "settingsMatchedExpectation": True,
                        "launchDiagnostics": {
                            "latestLastEvent": "playcover_library_injection_installed",
                            "latestReachedStages": [
                                "playcover_launch_enter",
                                "playcover_capture_library_preload_checked",
                                "playcover_library_injection_installed",
                            ],
                            "latestMissingStages": ["bridge_listener_command_listener_ready"],
                            "latestFailureCount": 0,
                        },
                        "recentManifestEventCount": 0,
                    },
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "analyze",
                    "--bundle-id",
                    bundle_id,
                    "--output-root",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("case=A: missing", completed.stdout)
            self.assertIn("case=B: matched=True lastEvent=playcover_library_injection_installed", completed.stdout)
            self.assertIn("case=D: missing", completed.stdout)


if __name__ == "__main__":
    unittest.main()
