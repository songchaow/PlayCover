from __future__ import annotations

import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_SCRIPT = REPO_ROOT / "Scripts" / "e006g_launch_matrix_runner.py"


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


class E006GLaunchMatrixRunnerTests(unittest.TestCase):
    def test_prepare_case_updates_three_runtime_switches(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            settings_path = container_root / "App Settings" / "com.example.lysk.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "metalCaptureEnabled": False,
                        "injectMetalCaptureEnvironment": False,
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
                    "com.example.lysk",
                    "--case",
                    "C",
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
            self.assertEqual(payload["injectMetalCaptureEnvironment"], True)
            self.assertEqual(payload["shaderSourceReplacementEnabled"], False)
            self.assertIn("prepared case-c-capture-on-startup-injection-on-replacement-off", completed.stdout)
            self.assertIn(
                "runtime_launch_diagnostics_summary.py --bundle-id com.example.lysk --limit 5",
                completed.stdout,
            )
            self.assertIn(
                "Keep the app alive for at least 10 seconds after ready",
                completed.stdout,
            )
            self.assertIn(
                "finalize-case --bundle-id com.example.lysk --case C",
                completed.stdout,
            )

    def test_finalize_case_copies_launch_diagnostics_and_manifest_tail(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            diagnostics_root = root / "RuntimeLaunchDiagnostics"
            output_root = root / "output"
            bundle_id = "com.example.lysk"

            settings_path = container_root / "App Settings" / f"{bundle_id}.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "metalCaptureEnabled": True,
                        "injectMetalCaptureEnvironment": True,
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
                    {
                        "timestamp": "2026-04-07T01:00:04Z",
                        "event": "playcover_launch_complete",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "metalCaptureEnabled": True,
                        "injectMetalCaptureEnvironment": True,
                        "shaderSourceReplacementEnabled": True,
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:00:05Z",
                        "event": "replacement_compile_failed",
                        "bundleId": bundle_id,
                        "pid": 101,
                        "processLaunchId": "launch-1",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "CACHE-A",
                        "compilerMessage": "expected expression",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:10:00Z",
                        "event": "playcover_launch_enter",
                        "bundleId": bundle_id,
                        "pid": 202,
                        "processLaunchId": "launch-2",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T01:10:01Z",
                        "event": "playcover_launch_complete",
                        "bundleId": bundle_id,
                        "pid": 202,
                        "processLaunchId": "launch-2",
                        "metalCaptureEnabled": True,
                        "injectMetalCaptureEnvironment": False,
                        "shaderSourceReplacementEnabled": False,
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
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "CACHE-A",
                        "moduleKeys": ["module-a"],
                        "outcome": "failed",
                        "reasonCode": "compile_failed",
                        "detail": "expected expression",
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
                    "E",
                    "--settle-seconds",
                    "0",
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

            case_dir = output_root / "case-e-capture-on-startup-injection-on-replacement-on" / bundle_id
            self.assertTrue((case_dir / f"{bundle_id}.plist").is_file())
            self.assertTrue((case_dir / "launch-events.jsonl").is_file())
            self.assertTrue((case_dir / "launch-summary.json").is_file())
            self.assertTrue((case_dir / "launch-summary.txt").is_file())
            self.assertTrue((case_dir / "manifest-tail.json").is_file())
            self.assertTrue((case_dir / "case.meta.json").is_file())

            case_meta = json.loads((case_dir / "case.meta.json").read_text(encoding="utf-8"))
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestLastEvent"],
                "replacement_compile_failed",
            )
            self.assertEqual(case_meta["launchDiagnostics"]["matchedSummaryCount"], 1)
            self.assertEqual(case_meta["launchDiagnostics"]["ignoredSummaryCount"], 1)
            self.assertEqual(case_meta["settingsMatchedExpectation"], True)
            self.assertEqual(case_meta["actualSettings"]["injectMetalCaptureEnvironment"], True)
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestLaunchSettings"],
                {
                    "metalCaptureEnabled": True,
                    "injectMetalCaptureEnvironment": True,
                    "shaderSourceReplacementEnabled": True,
                },
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementCounts"]["replacement_compile_failed"],
                1,
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["settleSeconds"],
                0.0,
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureClusters"][0]["cacheKey"],
                "CACHE-A",
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureSurfaceCount"],
                1,
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureSurfaces"][0]["moduleKeys"],
                ["module-a"],
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["aggregatedReplacementFailureClusterCount"],
                1,
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["aggregatedReplacementFailureClusters"][0]["cacheKey"],
                "CACHE-A",
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["aggregatedReplacementFailureSurfaceCount"],
                1,
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["aggregatedReplacementFailureSurfaces"][0]["cacheKey"],
                "CACHE-A",
            )
            launch_summary_json = json.loads((case_dir / "launch-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(launch_summary_json["summaryCount"], 1)
            self.assertEqual(launch_summary_json["runs"][0]["processLaunchId"], "launch-1")

            manifest_tail = json.loads((case_dir / "manifest-tail.json").read_text(encoding="utf-8"))
            self.assertEqual(len(manifest_tail), 3)
            launch_summary_text = (case_dir / "launch-summary.txt").read_text(encoding="utf-8")
            self.assertIn("replacementCounts=replacement_compile_failed=1", launch_summary_text)
            self.assertIn("replacementFailureClusters:", launch_summary_text)
            self.assertIn("replacementFailureSurfaces:", launch_summary_text)
            self.assertIn("launchSettings=injectMetalCaptureEnvironment=True", launch_summary_text)
            self.assertIn("case snapshot created", completed.stdout)
            self.assertIn("matchedRuns=1 ignoredRuns=1", completed.stdout)

    def test_finalize_case_uses_runtime_module_keys_when_manifest_failure_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            diagnostics_root = root / "RuntimeLaunchDiagnostics"
            output_root = root / "output"
            bundle_id = "com.example.lysk"

            settings_path = container_root / "App Settings" / f"{bundle_id}.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "metalCaptureEnabled": True,
                        "injectMetalCaptureEnvironment": True,
                        "shaderSourceReplacementEnabled": True,
                    },
                    handle,
                )

            write_jsonl(
                diagnostics_root / bundle_id / "launch-events.jsonl",
                [
                    {
                        "timestamp": "2026-04-07T02:00:00Z",
                        "event": "playcover_launch_enter",
                        "bundleId": bundle_id,
                        "pid": 303,
                        "processLaunchId": "launch-runtime-fallback",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T02:00:01Z",
                        "event": "playcover_capture_library_preload_checked",
                        "bundleId": bundle_id,
                        "pid": 303,
                        "processLaunchId": "launch-runtime-fallback",
                        "loaded": "true",
                        "needed": "true",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T02:00:02Z",
                        "event": "playcover_library_injection_installed",
                        "bundleId": bundle_id,
                        "pid": 303,
                        "processLaunchId": "launch-runtime-fallback",
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T02:00:03Z",
                        "event": "playcover_launch_complete",
                        "bundleId": bundle_id,
                        "pid": 303,
                        "processLaunchId": "launch-runtime-fallback",
                        "metalCaptureEnabled": True,
                        "injectMetalCaptureEnvironment": True,
                        "shaderSourceReplacementEnabled": True,
                        "isMainThread": True,
                    },
                    {
                        "timestamp": "2026-04-07T02:00:04Z",
                        "event": "replacement_compile_failed",
                        "bundleId": bundle_id,
                        "pid": 303,
                        "processLaunchId": "launch-runtime-fallback",
                        "selector": "newLibraryWithData:error:",
                        "cacheKey": "CACHE-RUNTIME",
                        "compilerMessage": "use of undeclared identifier 'mtl_BaseVertex'",
                        "moduleKeys": "module-b,module-a",
                        "isMainThread": True,
                    },
                ],
            )

            write_jsonl(
                container_root / "ShaderCorpus" / bundle_id / "manifest.jsonl",
                [
                    {"event": "capture", "timestamp": "2026-04-07T02:00:04Z", "moduleKey": "module-a"},
                    {"event": "replacement", "timestamp": "2026-04-07T02:00:05Z", "moduleKeys": ["module-a", "module-b"]},
                ],
            )

            subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-case",
                    "--bundle-id",
                    bundle_id,
                    "--case",
                    "E",
                    "--settle-seconds",
                    "0",
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

            case_dir = output_root / "case-e-capture-on-startup-injection-on-replacement-on" / bundle_id
            case_meta = json.loads((case_dir / "case.meta.json").read_text(encoding="utf-8"))
            self.assertEqual(case_meta["launchDiagnostics"]["latestReplacementFailureSurfaceCount"], 1)
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureSurfaces"][0]["cacheKey"],
                "CACHE-RUNTIME",
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureSurfaces"][0]["moduleKeys"],
                ["module-a", "module-b"],
            )
            self.assertEqual(
                case_meta["launchDiagnostics"]["latestReplacementFailureSurfaces"][0]["evidenceSources"],
                ["runtime_event"],
            )

    def test_analyze_reports_present_and_missing_cases(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output_root = root / "output"
            bundle_id = "com.example.lysk"
            case_dir = output_root / "case-c-capture-on-startup-injection-on-replacement-off" / bundle_id
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
                            "latestReplacementCounts": {
                                "replacement_compile_failed": 2,
                            },
                            "latestReplacementFailureClusters": [
                                {
                                    "event": "replacement_compile_failed",
                                    "selector": "newLibraryWithData:error:",
                                    "cacheKey": "CACHE-A",
                                    "compilerMessage": "expected expression",
                                    "count": 2,
                                }
                            ],
                            "latestReplacementFailureSurfaceCount": 1,
                            "latestReplacementFailureSurfaces": [
                                {
                                    "selector": "newLibraryWithData:error:",
                                    "cacheKey": "CACHE-A",
                                    "reasonCode": "compile_failed",
                                    "detail": "expected expression",
                                    "moduleKeys": ["module-a"],
                                    "moduleKeyCount": 1,
                                    "count": 2,
                                }
                            ],
                            "aggregatedReplacementFailureClusterCount": 1,
                            "aggregatedReplacementFailureClusters": [
                                {
                                    "event": "replacement_compile_failed",
                                    "selector": "newLibraryWithData:error:",
                                    "cacheKey": "CACHE-A",
                                    "compilerMessage": "expected expression",
                                    "runCount": 2,
                                    "occurrenceCount": 3,
                                }
                            ],
                            "aggregatedReplacementFailureSurfaceCount": 1,
                            "aggregatedReplacementFailureSurfaces": [
                                {
                                    "selector": "newLibraryWithData:error:",
                                    "cacheKey": "CACHE-A",
                                    "reasonCode": "compile_failed",
                                    "detail": "expected expression",
                                    "moduleKeys": ["module-a"],
                                    "moduleKeyCount": 1,
                                    "runCount": 2,
                                    "occurrenceCount": 3,
                                }
                            ],
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
            self.assertIn("case=C: matched=True lastEvent=playcover_library_injection_installed", completed.stdout)
            self.assertIn("matchedRuns=0", completed.stdout)
            self.assertIn("replacementCompileFailed=2", completed.stdout)
            self.assertIn("failureSurfaces=1", completed.stdout)
            self.assertIn("aggregateFailureSurfaces=1", completed.stdout)
            self.assertIn("hotspotSurface: cacheKey=CACHE-A reasonCode=compile_failed runs=2 occurrences=3", completed.stdout)
            self.assertIn("hotspotCluster: event=replacement_compile_failed cacheKey=CACHE-A runs=2 occurrences=3", completed.stdout)
            self.assertIn("case=E: missing", completed.stdout)

    def test_analyze_prefers_compile_failed_hotspots_over_bypass_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output_root = root / "output"
            bundle_id = "com.example.lysk"
            case_dir = output_root / "case-e-capture-on-startup-injection-on-replacement-on" / bundle_id
            case_dir.mkdir(parents=True, exist_ok=True)
            (case_dir / "case.meta.json").write_text(
                json.dumps(
                    {
                        "settingsMatchedExpectation": True,
                        "launchDiagnostics": {
                            "latestLastEvent": "replacement_compile_failed",
                            "latestReachedStages": [],
                            "latestMissingStages": [],
                            "latestFailureCount": 1,
                            "latestReplacementCounts": {
                                "replacement_attempt_skipped": 1,
                                "replacement_compile_failed": 1,
                            },
                            "latestReplacementFailureClusters": [],
                            "latestReplacementFailureSurfaceCount": 2,
                            "latestReplacementFailureSurfaces": [],
                            "aggregatedReplacementFailureClusterCount": 2,
                            "aggregatedReplacementFailureClusters": [
                                {
                                    "event": "replacement_compile_failed",
                                    "cacheKey": "CACHE-COMPILE",
                                    "runCount": 2,
                                    "occurrenceCount": 2,
                                },
                                {
                                    "event": "replacement_attempt_skipped",
                                    "cacheKey": "CACHE-BYPASS",
                                    "reason": "bundle_cachekey_bypass",
                                    "runCount": 2,
                                    "occurrenceCount": 2,
                                },
                            ],
                            "aggregatedReplacementFailureSurfaceCount": 2,
                            "aggregatedReplacementFailureSurfaces": [
                                {
                                    "cacheKey": "CACHE-COMPILE",
                                    "reasonCode": "compile_failed",
                                    "runCount": 2,
                                    "occurrenceCount": 2,
                                },
                                {
                                    "cacheKey": "CACHE-BYPASS",
                                    "reasonCode": "bundle_cachekey_bypass",
                                    "runCount": 2,
                                    "occurrenceCount": 2,
                                },
                            ],
                        },
                        "recentManifestEventCount": 2,
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

            self.assertIn("case=E: matched=True lastEvent=replacement_compile_failed", completed.stdout)
            self.assertIn("hotspotSurface: cacheKey=CACHE-COMPILE reasonCode=compile_failed runs=2 occurrences=2", completed.stdout)
            self.assertIn("hotspotCluster: event=replacement_compile_failed cacheKey=CACHE-COMPILE runs=2 occurrences=2", completed.stdout)


if __name__ == "__main__":
    unittest.main()
