from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok004_ngr_startup_runner import (  # noqa: E402
    decode_mcp_response_json,
    determine_exit_code,
    determine_overall_pass,
    diff_new_crash_reports,
    evaluate_compat_events,
    extract_installed_playcover_app_path,
    select_current_run_summary,
    summarize_session_polls,
)


class HOK004NGRStartupRunnerTests(unittest.TestCase):
    def test_select_current_run_prefers_process_launch_ids_not_seen_in_baseline(self) -> None:
        summaries = [
            {
                "processLaunchId": "launch-old",
                "firstTimestamp": "2026-04-18T09:59:59Z",
                "lastTimestamp": "2026-04-18T10:00:02Z",
            },
            {
                "processLaunchId": "launch-new",
                "firstTimestamp": "2026-04-18T10:00:03Z",
                "lastTimestamp": "2026-04-18T10:00:08Z",
            },
        ]

        selected = select_current_run_summary(
            summaries,
            baseline_process_launch_ids={"launch-old"},
            launch_requested_at="2026-04-18T10:00:01Z",
        )

        self.assertIsNotNone(selected)
        self.assertEqual(selected["processLaunchId"], "launch-new")

    def test_select_current_run_falls_back_to_launch_time_when_baseline_is_unavailable(self) -> None:
        summaries = [
            {
                "processLaunchId": "launch-before",
                "firstTimestamp": "2026-04-18T09:59:00Z",
                "lastTimestamp": "2026-04-18T09:59:30Z",
            },
            {
                "processLaunchId": "launch-after",
                "firstTimestamp": "2026-04-18T10:00:03Z",
                "lastTimestamp": "2026-04-18T10:00:07Z",
            },
        ]

        selected = select_current_run_summary(
            summaries,
            baseline_process_launch_ids={"launch-before", "launch-after"},
            launch_requested_at="2026-04-18T10:00:00Z",
        )

        self.assertIsNotNone(selected)
        self.assertEqual(selected["processLaunchId"], "launch-after")

    def test_evaluate_compat_events_reports_missing_and_forbidden_events(self) -> None:
        events = [
            {"event": "playcover_startup_compat_profile_applied"},
            {"event": "playcover_metal_capture_skipped"},
            {"event": "playcover_library_injection_installed"},
        ]

        evaluation = evaluate_compat_events(events)

        self.assertEqual(
            evaluation["missingRequired"],
            [
                "playcover_library_injection_skipped",
                "playcover_working_directory_preserved",
                "playcover_launch_complete",
            ],
        )
        self.assertEqual(evaluation["forbiddenPresent"], ["playcover_library_injection_installed"])
        self.assertFalse(evaluation["allRequiredPresent"])
        self.assertFalse(evaluation["allForbiddenAbsent"])

    def test_summarize_session_polls_tracks_ready_and_disconnected_states(self) -> None:
        polls = [
            {"sessions": [{"sessionId": "stale-session", "status": "disconnected"}]},
            {
                "sessions": [
                    {"sessionId": "stale-session", "status": "disconnected"},
                    {"sessionId": "session-1", "status": "starting"},
                ]
            },
            {"sessions": [{"sessionId": "session-1", "status": "ready"}]},
            {"sessions": [{"sessionId": "session-1", "status": "disconnected"}]},
        ]

        summary = summarize_session_polls(
            polls,
            target_session_id="session-1",
            baseline_session_ids={"stale-session"},
        )

        self.assertEqual(summary["observedStatuses"], ["disconnected", "ready", "starting"])
        self.assertTrue(summary["readyObserved"])
        self.assertTrue(summary["disconnectedObserved"])
        self.assertFalse(summary["closedObserved"])
        self.assertEqual(summary["pollCount"], 4)

    def test_diff_new_crash_reports_ignores_historical_ips_files(self) -> None:
        baseline = [
            {"name": "NGR-2026-04-18-001136.ips", "path": "/tmp/NGR-2026-04-18-001136.ips"},
        ]
        current = [
            {"name": "NGR-2026-04-18-001136.ips", "path": "/tmp/NGR-2026-04-18-001136.ips"},
            {"name": "NGR-2026-04-18-002000.ips", "path": "/tmp/NGR-2026-04-18-002000.ips"},
        ]

        diff = diff_new_crash_reports(baseline, current)

        self.assertEqual(diff, [{"name": "NGR-2026-04-18-002000.ips", "path": "/tmp/NGR-2026-04-18-002000.ips"}])

    def test_extract_installed_playcover_app_path_reads_build_script_footer(self) -> None:
        stdout = """
        === [3/3] ad-hoc 重签名 ===

        ===========================================
         🎉 PlayCover 已安装到 /Users/songdogwang/Applications/PlayCover.app
        ===========================================
        """

        path = extract_installed_playcover_app_path(stdout)

        self.assertEqual(str(path), "/Users/songdogwang/Applications/PlayCover.app")

    def test_decode_mcp_response_json_accepts_event_stream_wrapped_results(self) -> None:
        body = (
            'id: post-final\n'
            'data: {"id":2,"result":{"content":[{"type":"text","text":"[]"}]},"jsonrpc":"2.0"}\n\n'
        )

        payload = decode_mcp_response_json(body, "text/event-stream")

        self.assertEqual(payload["id"], 2)
        self.assertEqual(payload["result"]["content"][0]["text"], "[]")

    def test_determine_exit_code_returns_nonzero_when_verification_fails(self) -> None:
        checks = {
            "settingsReadBackMatchRequested": True,
            "requiredCompatEventsPresent": True,
            "forbiddenCompatEventsAbsent": True,
            "createSessionSucceeded": False,
            "readyObservedDuringSettleWindow": False,
            "disconnectedObservedDuringSettleWindow": True,
            "closedObservedDuringSettleWindow": False,
            "newCrashReportsDetected": True,
        }

        overall_pass = determine_overall_pass(checks)

        self.assertFalse(overall_pass)
        self.assertEqual(determine_exit_code(overall_pass), 1)


if __name__ == "__main__":
    unittest.main()
