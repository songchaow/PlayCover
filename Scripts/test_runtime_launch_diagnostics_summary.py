from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from runtime_launch_diagnostics_summary import aggregate_replacement_hotspots, build_summary


class RuntimeLaunchDiagnosticsSummaryTests(unittest.TestCase):
    def test_build_summary_groups_replacement_failures_by_selector_cache_key_and_message(self) -> None:
        events = [
            {
                "timestamp": "2026-04-07T01:00:00Z",
                "event": "playcover_launch_enter",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:02Z",
                "event": "replacement_compile_failed",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-A",
                "compilerMessage": "expected expression",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:03Z",
                "event": "replacement_compile_failed",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-A",
                "compilerMessage": "expected expression",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:04Z",
                "event": "replacement_exception",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-B",
                "error": "fallback hit",
                "isMainThread": True,
            },
        ]

        summary = build_summary(events, limit=1)[0]

        self.assertEqual(summary["replacement"]["counts"]["replacement_compile_failed"], 2)
        self.assertEqual(summary["replacement"]["counts"]["replacement_exception"], 1)
        self.assertEqual(summary["replacement"]["failureCount"], 3)
        self.assertEqual(summary["replacement"]["failureClusterCount"], 2)
        self.assertEqual(summary["replacement"]["failureClusters"][0]["cacheKey"], "CACHE-A")
        self.assertEqual(summary["replacement"]["failureClusters"][0]["count"], 2)
        self.assertEqual(
            summary["replacement"]["failureClusters"][0]["compilerMessage"],
            "expected expression",
        )

    def test_build_summary_correlates_failure_surfaces_with_manifest_module_keys(self) -> None:
        events = [
            {
                "timestamp": "2026-04-07T01:00:00Z",
                "event": "playcover_launch_enter",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:04Z",
                "event": "replacement_compile_failed",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-A",
                "compilerMessage": "expected expression",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:05Z",
                "event": "playcover_launch_complete",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "isMainThread": True,
            },
        ]
        manifest_entries = [
            {
                "event": "replacement_attempt",
                "timestamp": "2026-04-07T01:00:04Z",
                "bundleId": "com.example.lysk",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-A",
                "outcome": "failed",
                "reasonCode": "compile_failed",
                "detail": "expected expression",
                "moduleKeys": ["module-b", "module-a"],
            },
            {
                "event": "replacement_attempt",
                "timestamp": "2026-04-07T01:05:04Z",
                "bundleId": "com.example.lysk",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-Z",
                "outcome": "failed",
                "reasonCode": "compile_failed",
                "detail": "out-of-window",
                "moduleKeys": ["module-z"],
            },
        ]

        summary = build_summary(events, limit=1, manifest_entries=manifest_entries)[0]

        surfaces = summary["replacementFailureSurfaces"]
        self.assertEqual(surfaces["matchedAttemptCount"], 1)
        self.assertEqual(surfaces["failureSurfaceCount"], 1)
        self.assertEqual(surfaces["failureSurfaces"][0]["cacheKey"], "CACHE-A")
        self.assertEqual(surfaces["failureSurfaces"][0]["reasonCode"], "compile_failed")
        self.assertEqual(surfaces["failureSurfaces"][0]["moduleKeys"], ["module-a", "module-b"])

    def test_build_summary_falls_back_to_runtime_module_keys_when_manifest_entry_is_missing(self) -> None:
        events = [
            {
                "timestamp": "2026-04-07T01:00:00Z",
                "event": "playcover_launch_enter",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:03Z",
                "event": "playcover_launch_complete",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "metalCaptureEnabled": "true",
                "injectMetalCaptureEnvironment": "true",
                "shaderSourceReplacementEnabled": "true",
                "isMainThread": True,
            },
            {
                "timestamp": "2026-04-07T01:00:04Z",
                "event": "replacement_compile_failed",
                "bundleId": "com.example.lysk",
                "pid": 101,
                "processLaunchId": "launch-1",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "CACHE-A",
                "compilerMessage": "expected expression",
                "moduleKeys": "module-b,module-a",
                "isMainThread": True,
            },
        ]

        summary = build_summary(events, limit=1)[0]

        self.assertEqual(
            summary["launchSettings"],
            {
                "metalCaptureEnabled": True,
                "injectMetalCaptureEnvironment": True,
                "shaderSourceReplacementEnabled": True,
            },
        )
        surfaces = summary["replacementFailureSurfaces"]
        self.assertEqual(surfaces["matchedAttemptCount"], 0)
        self.assertEqual(surfaces["manifestMatchedAttemptCount"], 0)
        self.assertEqual(surfaces["runtimeFallbackSurfaceCount"], 1)
        self.assertEqual(surfaces["failureSurfaceCount"], 1)
        self.assertEqual(surfaces["failureSurfaces"][0]["cacheKey"], "CACHE-A")
        self.assertEqual(surfaces["failureSurfaces"][0]["reasonCode"], "compile_failed")
        self.assertEqual(surfaces["failureSurfaces"][0]["moduleKeys"], ["module-a", "module-b"])
        self.assertEqual(surfaces["failureSurfaces"][0]["evidenceSources"], ["runtime_event"])

    def test_aggregate_replacement_hotspots_merges_repeated_failures_across_runs(self) -> None:
        summaries = [
            {
                "processLaunchId": "launch-1",
                "replacement": {
                    "failureClusters": [
                        {
                            "event": "replacement_compile_failed",
                            "selector": "newLibraryWithData:error:",
                            "cacheKey": "CACHE-A",
                            "compilerMessage": "expected expression",
                            "count": 2,
                            "firstTimestamp": "2026-04-07T01:00:01Z",
                            "lastTimestamp": "2026-04-07T01:00:02Z",
                        }
                    ]
                },
                "replacementFailureSurfaces": {
                    "failureSurfaces": [
                        {
                            "selector": "newLibraryWithData:error:",
                            "cacheKey": "CACHE-A",
                            "reasonCode": "compile_failed",
                            "detail": "expected expression",
                            "moduleKeys": ["module-a"],
                            "count": 1,
                            "firstTimestamp": "2026-04-07T01:00:02Z",
                            "lastTimestamp": "2026-04-07T01:00:02Z",
                        }
                    ]
                },
            },
            {
                "processLaunchId": "launch-2",
                "replacement": {
                    "failureClusters": [
                        {
                            "event": "replacement_compile_failed",
                            "selector": "newLibraryWithData:error:",
                            "cacheKey": "CACHE-A",
                            "compilerMessage": "expected expression",
                            "count": 1,
                            "firstTimestamp": "2026-04-07T01:05:01Z",
                            "lastTimestamp": "2026-04-07T01:05:01Z",
                        }
                    ]
                },
                "replacementFailureSurfaces": {
                    "failureSurfaces": [
                        {
                            "selector": "newLibraryWithData:error:",
                            "cacheKey": "CACHE-A",
                            "reasonCode": "compile_failed",
                            "detail": "expected expression",
                            "moduleKeys": ["module-a"],
                            "count": 2,
                            "firstTimestamp": "2026-04-07T01:05:01Z",
                            "lastTimestamp": "2026-04-07T01:05:02Z",
                        }
                    ]
                },
            },
        ]

        hotspots = aggregate_replacement_hotspots(summaries)

        self.assertEqual(hotspots["failureClusterCount"], 1)
        self.assertEqual(hotspots["failureClusters"][0]["cacheKey"], "CACHE-A")
        self.assertEqual(hotspots["failureClusters"][0]["runCount"], 2)
        self.assertEqual(hotspots["failureClusters"][0]["occurrenceCount"], 3)
        self.assertEqual(hotspots["failureSurfaceCount"], 1)
        self.assertEqual(hotspots["failureSurfaces"][0]["cacheKey"], "CACHE-A")
        self.assertEqual(hotspots["failureSurfaces"][0]["runCount"], 2)
        self.assertEqual(hotspots["failureSurfaces"][0]["occurrenceCount"], 3)


if __name__ == "__main__":
    unittest.main()
