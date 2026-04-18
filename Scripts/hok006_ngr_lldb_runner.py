#!/usr/bin/env python3
"""
HOK-006: 在保留 HOK-004/HOK-005 最小兼容 baseline 的前提下，
用 headless LLDB 自动化抓取 `com.tencent.ngr` 的 faulting instruction / backtrace 证据。
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok004_ngr_startup_runner import (  # noqa: E402
    DEFAULT_BUNDLE_ID,
    DEFAULT_CONTAINER_ROOT,
    DEFAULT_CREATE_SESSION_TIMEOUT,
    DEFAULT_CRASH_REPORTS_ROOT,
    DEFAULT_DIAGNOSTICS_ROOT,
    DEFAULT_MCP_URL,
    DEFAULT_POLL_INTERVAL,
    DEFAULT_SETTLE_SECONDS,
    MINIMAL_COMPAT_SETTINGS,
    MCPHTTPClient,
    clip_text,
    collect_process_launch_ids,
    determine_exit_code,
    diff_new_crash_reports,
    evaluate_compat_events,
    extract_installed_playcover_app_path,
    list_crash_reports,
    read_events,
    read_manifest_entries,
    require_tool_success,
    resolve_playcover_app_path,
    run_command,
    select_current_run_summary,
    summarize_session_polls,
    snapshot_tool_outcome,
    utc_now_iso,
    wait_for_mcp_ready,
    write_report,
)
from runtime_launch_diagnostics_summary import build_summary  # noqa: E402


DEFAULT_WAIT_TIMEOUT = 20.0
DEFAULT_LLDB_TIMEOUT = 5.0
DEFAULT_OUTPUT = Path("build/hok-006-ngr-lldb-report.json")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the HOK-006 com.tencent.ngr LLDB attribution workflow")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="target bundle identifier")
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL, help="GUI HTTP MCP endpoint")
    parser.add_argument(
        "--lldb-timeout",
        type=float,
        default=DEFAULT_LLDB_TIMEOUT,
        help="headless LLDB timeout in seconds before interrupting and summarizing the run",
    )
    parser.add_argument(
        "--settle-seconds",
        type=float,
        default=DEFAULT_SETTLE_SECONDS,
        help="list_sessions polling window after LLDB launch request (default: 10)",
    )
    parser.add_argument(
        "--create-session-timeout",
        type=float,
        default=DEFAULT_CREATE_SESSION_TIMEOUT,
        help="create_session timeout in seconds (default: 10)",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help="list_sessions polling interval during settle window",
    )
    parser.add_argument(
        "--wait-timeout",
        type=float,
        default=DEFAULT_WAIT_TIMEOUT,
        help="how long to wait for GUI HTTP MCP readiness (default: 20)",
    )
    parser.add_argument(
        "--configuration",
        default="Release",
        help="configuration passed to BuildScripts/build_and_install.sh",
    )
    parser.add_argument(
        "--playcover-app-path",
        help="optional explicit PlayCover.app path; defaults to ~/Applications/PlayCover.app or /Applications/PlayCover.app",
    )
    parser.add_argument(
        "--skip-build-install",
        action="store_true",
        help="skip BuildScripts/build_and_install.sh and only reuse an already-installed PlayCover.app",
    )
    parser.add_argument(
        "--container-root",
        default=str(DEFAULT_CONTAINER_ROOT),
        help="PlayCover container root",
    )
    parser.add_argument(
        "--diagnostics-root",
        default=str(DEFAULT_DIAGNOSTICS_ROOT),
        help="RuntimeLaunchDiagnostics root",
    )
    parser.add_argument(
        "--crash-reports-root",
        default=str(DEFAULT_CRASH_REPORTS_ROOT),
        help="macOS crash report root",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="structured JSON report output path under build/",
    )
    return parser


def extract_lldb_evidence(launch_outcome: dict[str, Any]) -> dict[str, Any] | None:
    parsed = launch_outcome.get("parsed")
    if not isinstance(parsed, dict):
        return None
    evidence = parsed.get("lldb")
    return evidence if isinstance(evidence, dict) else None


def summarize_lldb_evidence(evidence: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(evidence, dict):
        return {
            "present": False,
            "timedOut": False,
            "didStop": False,
            "processIdentifier": None,
            "stopReason": None,
            "signal": None,
            "faultAddress": None,
            "faultingThread": None,
            "faultingFrame": None,
            "faultingInstruction": None,
            "backtraceDepth": 0,
            "backtraceHead": [],
            "transcriptTail": "",
        }

    backtrace = evidence.get("backtrace") if isinstance(evidence.get("backtrace"), list) else []
    transcript_tail = str(evidence.get("transcriptTail") or "")
    if not transcript_tail:
        transcript_tail = clip_text(str(evidence.get("transcript") or ""), limit=4000)

    return {
        "present": True,
        "timedOut": bool(evidence.get("timedOut")),
        "didStop": bool(evidence.get("didStop")),
        "processIdentifier": evidence.get("processIdentifier"),
        "stopReason": evidence.get("stopReason"),
        "signal": evidence.get("signal"),
        "faultAddress": evidence.get("faultAddress"),
        "faultingThread": evidence.get("faultingThread"),
        "faultingFrame": evidence.get("faultingFrame"),
        "faultingInstruction": evidence.get("faultingInstruction"),
        "backtraceDepth": len(backtrace),
        "backtraceHead": backtrace[:8],
        "transcriptTail": transcript_tail,
    }


def evaluate_lldb_capture(summary: dict[str, Any]) -> dict[str, Any]:
    return {
        "evidencePresent": bool(summary.get("present")),
        "timedOut": bool(summary.get("timedOut")),
        "stopObserved": bool(summary.get("didStop")),
        "faultingThreadCaptured": bool(summary.get("faultingThread")),
        "faultingFrameCaptured": bool(summary.get("faultingFrame")),
        "faultingInstructionCaptured": bool(summary.get("faultingInstruction")),
        "backtraceCaptured": int(summary.get("backtraceDepth") or 0) > 0,
        "automationReady": bool(summary.get("didStop"))
        and bool(summary.get("faultingFrame"))
        and bool(summary.get("faultingInstruction"))
        and int(summary.get("backtraceDepth") or 0) > 0,
    }


def determine_overall_pass(checks: dict[str, Any]) -> bool:
    return bool(
        checks.get("settingsReadBackMatchRequested")
        and checks.get("requiredCompatEventsPresent")
        and checks.get("forbiddenCompatEventsAbsent")
        and checks.get("lldbEvidencePresent")
        and checks.get("lldbAutomationReady")
    )


def main() -> int:
    args = build_parser().parse_args()
    repo_root = SCRIPT_DIR.parent
    output_path = Path(args.output).expanduser().resolve()
    container_root = Path(args.container_root).expanduser().resolve()
    diagnostics_root = Path(args.diagnostics_root).expanduser().resolve()
    crash_reports_root = Path(args.crash_reports_root).expanduser().resolve()
    launch_events_path = diagnostics_root / args.bundle_id / "launch-events.jsonl"
    manifest_path = container_root / "ShaderCorpus" / args.bundle_id / "manifest.jsonl"
    lldb_timeout = max(float(args.lldb_timeout), 0.1)
    settle_seconds = max(float(args.settle_seconds), 0.0)
    poll_interval = max(float(args.poll_interval), 0.1)
    create_session_timeout = max(float(args.create_session_timeout), 0.1)

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "workflow": "hok-006-ngr-lldb-runner",
        "configuration": {
            "mcpUrl": args.mcp_url,
            "lldbTimeout": lldb_timeout,
            "settleSeconds": settle_seconds,
            "createSessionTimeout": create_session_timeout,
            "waitTimeout": float(args.wait_timeout),
            "pollInterval": poll_interval,
            "buildConfiguration": args.configuration,
            "skipBuildInstall": bool(args.skip_build_install),
            "outputPath": str(output_path),
        },
        "paths": {
            "containerRoot": str(container_root),
            "diagnosticsRoot": str(diagnostics_root),
            "launchEventsPath": str(launch_events_path),
            "manifestPath": str(manifest_path),
            "crashReportsRoot": str(crash_reports_root),
        },
        "settings": {
            "requestedMinimalCompatSettings": dict(MINIMAL_COMPAT_SETTINGS),
        },
        "buildInstall": {
            "ran": not args.skip_build_install,
        },
        "mcp": {},
        "baselines": {},
        "launch": {},
        "diagnostics": {},
        "crashReports": {},
        "checks": {},
    }

    try:
        build_result: dict[str, Any] | None = None
        if not args.skip_build_install:
            build_result = run_command(
                ["bash", "BuildScripts/build_and_install.sh", args.configuration],
                cwd=repo_root,
            )
            report["buildInstall"] = {
                "ran": True,
                "returncode": build_result["returncode"],
                "command": build_result["command"],
                "stdoutTail": clip_text(build_result["stdout"], limit=4000),
                "stderrTail": clip_text(build_result["stderr"], limit=4000),
            }
            if build_result["returncode"] != 0:
                raise RuntimeError("BuildScripts/build_and_install.sh failed")

        installed_app_path = extract_installed_playcover_app_path(build_result["stdout"]) if build_result else None
        playcover_app_path = installed_app_path or resolve_playcover_app_path(args.playcover_app_path)
        report["buildInstall"]["playcoverAppPath"] = str(playcover_app_path)

        open_result = run_command(["open", str(playcover_app_path)], cwd=repo_root)
        report["mcp"]["openPlayCoverApp"] = {
            "returncode": open_result["returncode"],
            "command": open_result["command"],
            "stdoutTail": clip_text(open_result["stdout"], limit=1000),
            "stderrTail": clip_text(open_result["stderr"], limit=1000),
        }

        client = MCPHTTPClient(args.mcp_url)
        mcp_ready = wait_for_mcp_ready(client, timeout_seconds=float(args.wait_timeout))
        report["mcp"].update(
            {
                "ready": True,
                "sessionId": client.session_id,
                "protocolVersion": client.protocol_version,
                "initialize": mcp_ready["initialize"],
                "initialized": mcp_ready["initialized"],
            }
        )

        baseline_events = read_events(launch_events_path)
        baseline_reports = list_crash_reports(crash_reports_root)
        baseline_process_launch_ids = collect_process_launch_ids(baseline_events)
        report["baselines"] = {
            "capturedAt": utc_now_iso(),
            "processLaunchIds": sorted(baseline_process_launch_ids),
            "processLaunchIdCount": len(baseline_process_launch_ids),
            "crashReports": baseline_reports,
            "crashReportCount": len(baseline_reports),
        }

        baseline_sessions_outcome = require_tool_success(
            client.call_tool("list_sessions", {"bundleId": args.bundle_id}),
            "baseline list_sessions",
        )
        baseline_sessions = (
            baseline_sessions_outcome.get("parsed")
            if isinstance(baseline_sessions_outcome.get("parsed"), list)
            else []
        )
        baseline_session_ids = {
            str(session.get("sessionId") or "")
            for session in baseline_sessions
            if session.get("sessionId")
        }
        report["baselines"]["sessions"] = baseline_sessions
        report["baselines"]["sessionIds"] = sorted(baseline_session_ids)
        report["baselines"]["sessionCount"] = len(baseline_sessions)

        reset_outcome = require_tool_success(
            client.call_tool("reset_app_settings", {"bundleId": args.bundle_id}),
            "reset_app_settings",
        )
        update_outcome = require_tool_success(
            client.call_tool(
                "update_app_settings",
                {"bundleId": args.bundle_id, "changes": MINIMAL_COMPAT_SETTINGS},
            ),
            "update_app_settings",
        )
        get_settings_outcome = require_tool_success(
            client.call_tool("get_app_settings", {"bundleId": args.bundle_id}),
            "get_app_settings",
        )
        read_back_settings = get_settings_outcome.get("parsed") or {}
        report["settings"].update(
            {
                "reset": snapshot_tool_outcome(reset_outcome),
                "update": snapshot_tool_outcome(update_outcome),
                "readBack": snapshot_tool_outcome(get_settings_outcome),
            }
        )

        launch_requested_at = utc_now_iso()
        launch_box: dict[str, Any] = {}
        create_session_box: dict[str, Any] = {}

        def run_launch() -> None:
            try:
                outcome = client.call_tool(
                    "launch_app_with_lldb",
                    {
                        "bundleId": args.bundle_id,
                        "withTerminalWindow": False,
                        "timeoutSeconds": lldb_timeout,
                    },
                    request_timeout=max(lldb_timeout + 15.0, 20.0),
                )
                launch_box["rawOutcome"] = outcome
                launch_box["outcome"] = snapshot_tool_outcome(outcome)
            except Exception as exc:  # pragma: no cover - defensive only
                launch_box["rawOutcome"] = None
                launch_box["outcome"] = {
                    "ok": False,
                    "httpStatus": None,
                    "isToolError": True,
                    "error": {"message": str(exc)},
                    "parsed": None,
                    "rawText": "",
                }

        def run_create_session() -> None:
            try:
                outcome = client.call_tool(
                    "create_session",
                    {"bundleId": args.bundle_id, "timeout": create_session_timeout},
                    request_timeout=max(create_session_timeout + 5.0, 15.0),
                )
                create_session_box["outcome"] = snapshot_tool_outcome(outcome)
                parsed = outcome.get("parsed") if isinstance(outcome.get("parsed"), dict) else {}
                create_session_box["sessionId"] = parsed.get("sessionId")
            except Exception as exc:  # pragma: no cover - defensive only
                create_session_box["outcome"] = {
                    "ok": False,
                    "httpStatus": None,
                    "isToolError": True,
                    "error": {"message": str(exc)},
                    "parsed": None,
                    "rawText": "",
                }
                create_session_box["sessionId"] = None

        launch_thread = threading.Thread(target=run_launch, daemon=True)
        create_session_thread = threading.Thread(target=run_create_session, daemon=True)
        launch_thread.start()
        create_session_thread.start()

        session_polls: list[dict[str, Any]] = []
        settle_deadline = time.monotonic() + settle_seconds
        while time.monotonic() < settle_deadline:
            poll_timestamp = utc_now_iso()
            poll_outcome = client.call_tool("list_sessions", {"bundleId": args.bundle_id})
            parsed_sessions = poll_outcome.get("parsed") if isinstance(poll_outcome.get("parsed"), list) else []
            session_polls.append(
                {
                    "timestamp": poll_timestamp,
                    "ok": bool(poll_outcome.get("ok")),
                    "error": poll_outcome.get("error"),
                    "sessions": parsed_sessions,
                }
            )
            time.sleep(poll_interval)

        create_session_thread.join(timeout=create_session_timeout + 1.0)
        if create_session_thread.is_alive():
            create_session_box.setdefault(
                "outcome",
                {
                    "ok": False,
                    "httpStatus": None,
                    "isToolError": True,
                    "error": {
                        "message": (
                            "create_session did not finish within the expected timeout window "
                            "while LLDB launch was running"
                        )
                    },
                    "parsed": None,
                    "rawText": "",
                },
            )
            create_session_box.setdefault("sessionId", None)
        launch_thread.join(timeout=lldb_timeout + 3.0)
        if launch_thread.is_alive():
            raise RuntimeError("launch_app_with_lldb did not finish within the expected timeout window")

        final_list_outcome = client.call_tool("list_sessions", {"bundleId": args.bundle_id})
        final_sessions = final_list_outcome.get("parsed") if isinstance(final_list_outcome.get("parsed"), list) else []
        session_polls.append(
            {
                "timestamp": utc_now_iso(),
                "ok": bool(final_list_outcome.get("ok")),
                "error": final_list_outcome.get("error"),
                "sessions": final_sessions,
            }
        )

        target_session_id = create_session_box.get("sessionId")
        session_summary = summarize_session_polls(session_polls, target_session_id, baseline_session_ids)
        report["launch"]["launchRequestedAt"] = launch_requested_at
        report["launch"]["launchAppWithLLDB"] = launch_box.get("outcome")
        report["launch"]["createSession"] = create_session_box.get("outcome")
        report["launch"]["listSessionsPolls"] = session_polls
        report["launch"]["sessionSummary"] = session_summary

        raw_launch_outcome = launch_box.get("rawOutcome")
        launch_outcome = None
        if isinstance(raw_launch_outcome, dict) and raw_launch_outcome.get("ok"):
            launch_outcome = raw_launch_outcome
        lldb_evidence = extract_lldb_evidence(launch_outcome or {})
        lldb_summary = summarize_lldb_evidence(lldb_evidence)
        lldb_capture = evaluate_lldb_capture(lldb_summary)
        report["launch"]["lldb"] = lldb_summary

        current_events = read_events(launch_events_path)
        current_reports = list_crash_reports(crash_reports_root)
        manifest_entries = read_manifest_entries(manifest_path)
        all_summaries = build_summary(current_events, max(len(current_events), 1), manifest_entries)
        selected_summary = select_current_run_summary(all_summaries, baseline_process_launch_ids, launch_requested_at)
        selected_process_launch_id = (
            str(selected_summary.get("processLaunchId") or "") if isinstance(selected_summary, dict) else ""
        )
        selected_events = [
            event for event in current_events if str(event.get("processLaunchId") or "") == selected_process_launch_id
        ]
        compat_evaluation = evaluate_compat_events(selected_events)
        new_process_launch_ids = sorted(collect_process_launch_ids(current_events) - baseline_process_launch_ids)
        new_crash_reports = diff_new_crash_reports(baseline_reports, current_reports)

        report["diagnostics"] = {
            "eventCount": len(current_events),
            "summaryCount": len(all_summaries),
            "newProcessLaunchIds": new_process_launch_ids,
            "selectedProcessLaunchId": selected_process_launch_id or None,
            "selectedRunSummary": selected_summary,
            "selectedRunEventCount": len(selected_events),
            "compatEvaluation": compat_evaluation,
        }
        report["crashReports"] = {
            "baselineCount": len(baseline_reports),
            "currentCount": len(current_reports),
            "newReports": new_crash_reports,
            "newReportCount": len(new_crash_reports),
        }
        report["checks"] = {
            "settingsReadBackMatchRequested": all(
                read_back_settings.get(key) == value for key, value in MINIMAL_COMPAT_SETTINGS.items()
            ),
            "requiredCompatEventsPresent": compat_evaluation["allRequiredPresent"],
            "forbiddenCompatEventsAbsent": compat_evaluation["allForbiddenAbsent"],
            "createSessionSucceeded": bool((create_session_box.get("outcome") or {}).get("ok")),
            "readyObservedDuringSettleWindow": session_summary["readyObserved"],
            "disconnectedObservedDuringSettleWindow": session_summary["disconnectedObserved"],
            "closedObservedDuringSettleWindow": session_summary["closedObserved"],
            "lldbEvidencePresent": lldb_capture["evidencePresent"],
            "lldbTimedOut": lldb_capture["timedOut"],
            "lldbStopObserved": lldb_capture["stopObserved"],
            "lldbFaultingThreadCaptured": lldb_capture["faultingThreadCaptured"],
            "lldbFaultingFrameCaptured": lldb_capture["faultingFrameCaptured"],
            "lldbFaultingInstructionCaptured": lldb_capture["faultingInstructionCaptured"],
            "lldbBacktraceCaptured": lldb_capture["backtraceCaptured"],
            "lldbAutomationReady": lldb_capture["automationReady"],
            "newCrashReportsDetected": bool(new_crash_reports),
        }
        report["checks"]["overallPass"] = determine_overall_pass(report["checks"])
        report["checks"]["exitCode"] = determine_exit_code(report["checks"]["overallPass"])

        write_report(output_path, report)
        print(f"report written: {output_path}")
        print(
            "summary: "
            f"bundleId={args.bundle_id} "
            f"processLaunchId={report['diagnostics']['selectedProcessLaunchId'] or 'n/a'} "
            f"lldbTimedOut={report['checks']['lldbTimedOut']} "
            f"lldbStopObserved={report['checks']['lldbStopObserved']} "
            f"faultingInstructionCaptured={report['checks']['lldbFaultingInstructionCaptured']} "
            f"backtraceCaptured={report['checks']['lldbBacktraceCaptured']} "
            f"requiredCompatEventsPresent={report['checks']['requiredCompatEventsPresent']} "
            f"forbiddenCompatEventsAbsent={report['checks']['forbiddenCompatEventsAbsent']} "
            f"overallPass={report['checks']['overallPass']}"
        )
        return determine_exit_code(report["checks"]["overallPass"])
    except Exception as exc:
        report["fatalError"] = {
            "message": str(exc),
            "type": type(exc).__name__,
            "raisedAt": utc_now_iso(),
        }
        write_report(output_path, report)
        print(f"report written with failure details: {output_path}")
        print(f"fatal: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
