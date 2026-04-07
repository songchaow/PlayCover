from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from runtime_launch_diagnostics_summary import build_summary


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


if __name__ == "__main__":
    unittest.main()
