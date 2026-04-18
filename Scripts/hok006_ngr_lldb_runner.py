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
# HOK-012-B: watchpoint + dyld initializer log defaults.
DEFAULT_WATCH_ADDRESS = "0x10e2146f8"
DEFAULT_WATCH_SIZE = 8
DEFAULT_WATCHPOINT_REPORT = Path("build/hok-012-ngr-watchpoint-report.json")
DEFAULT_DYLD_LOG = Path("build/hok-012-ngr-dyld-initializers.log")
# HOK-012-C: default writer function used by the deferred-install
# strategy; matches the singleton accessor located by HOK-011 whose
# internal store writes `0x10e2146f8`. Callers can override via
# `--writer-address`.
DEFAULT_WRITER_ADDRESS = "0x103a29b7c"


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
    # HOK-012-B: opt-in watchpoint mode.
    parser.add_argument(
        "--watch-address",
        default=None,
        help=(
            "HOK-012-B: optional data watchpoint target (hex string like `0x10e2146f8`). "
            "When provided the MCP `launch_app_with_lldb` call installs a watchpoint "
            "before `run`, collects backtraces on every hit, and keeps the process "
            "alive until the lldb-timeout elapses. "
            f"Pass `--watch-address {DEFAULT_WATCH_ADDRESS}` to reproduce the HOK-012 "
            "default target slot."
        ),
    )
    parser.add_argument(
        "--watch-size",
        type=int,
        default=DEFAULT_WATCH_SIZE,
        help=f"HOK-012-B: watchpoint byte size (default: {DEFAULT_WATCH_SIZE}).",
    )
    parser.add_argument(
        "--pre-run-command",
        action="append",
        default=[],
        help=(
            "HOK-012-B: extra LLDB command to execute once the target is loaded but "
            "before the child process is launched; may be repeated. Typical use is "
            "`--pre-run-command \"breakpoint set --name <sym>\"`."
        ),
    )
    parser.add_argument(
        "--dyld-log",
        default=None,
        help=(
            "HOK-012-B: absolute path where the child process's stderr should be "
            "redirected (captures `DYLD_PRINT_INITIALIZERS=1` output). "
            f"Passing an empty value disables redirection. Default when watchpoint "
            f"mode is active: {DEFAULT_DYLD_LOG}."
        ),
    )
    parser.add_argument(
        "--watchpoint-report",
        default=str(DEFAULT_WATCHPOINT_REPORT),
        help=(
            "HOK-012-B: structured JSON report listing watchpoint hits, stop reasons "
            "and backtrace snippets; written only when watchpoint mode is active."
        ),
    )
    # HOK-012-C: deferred watchpoint install.
    parser.add_argument(
        "--defer-watchpoint-install",
        action="store_true",
        help=(
            "HOK-012-C: do not auto-emit `watchpoint set expression …` before `run`. "
            "Watchpoint-mode plumbing (stop→continue, hits parsing) still engages "
            "as long as `--watch-address` is non-empty, but the actual install line "
            "must be carried by `--pre-run-command` (or auto-generated via "
            "`--writer-address`). Fixes the HOK-012-C.2 0-hit timing race where the "
            "pre-run watchpoint was not armed in the child process early enough to "
            "catch the first store."
        ),
    )
    parser.add_argument(
        "--writer-address",
        default=None,
        help=(
            "HOK-012-C: when combined with `--defer-watchpoint-install`, auto-append "
            "a `breakpoint set --address <writer> -C \"watchpoint set expression -s "
            "<size> -- <addr>\" -C \"continue\" --auto-continue true --one-shot true` "
            "entry to the pre-run script. Pass an empty value to disable the "
            "auto-append (callers may still supply their own `--pre-run-command`). "
            f"Default when defer mode is active: {DEFAULT_WRITER_ADDRESS}."
        ),
    )
    # HOK-012-C.3-b.1: always let LLDB intercept SIGABRT so UE4 `abort()`
    # stops in the LLDB layer before the Apple crash dialog pins the UI
    # thread. The flag is opt-out (default on in defer mode) so legacy
    # HOK-012-B runs remain unaffected.
    parser.add_argument(
        "--intercept-sigabrt",
        dest="intercept_sigabrt",
        action="store_true",
        default=None,
        help=(
            "HOK-012-C.3-b.1: prepend `process handle -s true -n true -p false "
            "SIGABRT` to the pre-run script so UE4 `abort()` is caught inside "
            "LLDB instead of by the Apple crash dialog. Default: ON when "
            "`--defer-watchpoint-install` is active, OFF otherwise."
        ),
    )
    parser.add_argument(
        "--no-intercept-sigabrt",
        dest="intercept_sigabrt",
        action="store_false",
        help=(
            "HOK-012-C.3-b.1: disable the SIGABRT interception even in "
            "deferred-install mode (not recommended — the Apple crash "
            "dialog will then block the child on abort())."
        ),
    )
    # HOK-012-C.3-b.2: the MCP-side teardown window used to be hard coded
    # to 2.0s. Abort-intercept runs (b.1) emit a richer stop handler that
    # needs 5–10s to finish draining `thread backtrace all` / `memory
    # read` / `breakpoint list` / `watchpoint list`, so expose it.
    parser.add_argument(
        "--teardown-timeout",
        type=float,
        default=None,
        help=(
            "HOK-012-C.3-b.2: seconds the headless LLDB runner waits for "
            "the teardown script to complete after the capture window "
            "elapses. Default: 6.0s when `--defer-watchpoint-install` is "
            "active (covers the abort-intercept stop handler), 2.0s "
            "otherwise (legacy HOK-006/HOK-012-B behaviour)."
        ),
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
            "watchpointHits": [],
            "watchpointHitCount": 0,
            "dyldInitializersLogPath": None,
            "blockingDialogWindows": [],
            "blockingDialogCount": 0,
            "residualProcessesKilled": [],
            "residualProcessesKilledCount": 0,
        }

    backtrace = evidence.get("backtrace") if isinstance(evidence.get("backtrace"), list) else []
    transcript_tail = str(evidence.get("transcriptTail") or "")
    if not transcript_tail:
        transcript_tail = clip_text(str(evidence.get("transcript") or ""), limit=4000)

    raw_hits = evidence.get("watchpointHits") if isinstance(evidence.get("watchpointHits"), list) else []
    normalized_hits: list[dict[str, Any]] = []
    for hit in raw_hits:
        if not isinstance(hit, dict):
            continue
        hit_backtrace = hit.get("backtrace") if isinstance(hit.get("backtrace"), list) else []
        normalized_hits.append(
            {
                "index": hit.get("index"),
                "stopReason": hit.get("stopReason"),
                "thread": hit.get("thread"),
                "frame": hit.get("frame"),
                "oldValue": hit.get("oldValue"),
                "newValue": hit.get("newValue"),
                "backtrace": hit_backtrace,
                "backtraceDepth": len(hit_backtrace),
            }
        )

    # HOK-012-C.3-b.0: dialog detection + residual-kill from MCP evidence.
    raw_dialogs = evidence.get("blockingDialogWindows") if isinstance(evidence.get("blockingDialogWindows"), list) else []
    normalized_dialogs: list[dict[str, Any]] = []
    for dialog in raw_dialogs:
        if not isinstance(dialog, dict):
            continue
        normalized_dialogs.append(
            {
                "ownerPID": dialog.get("ownerPID"),
                "ownerName": dialog.get("ownerName"),
                "windowName": dialog.get("windowName"),
                "windowLayer": dialog.get("windowLayer"),
                "alpha": dialog.get("alpha"),
                "isOnscreen": dialog.get("isOnscreen"),
                "boundsX": dialog.get("boundsX"),
                "boundsY": dialog.get("boundsY"),
                "boundsWidth": dialog.get("boundsWidth"),
                "boundsHeight": dialog.get("boundsHeight"),
            }
        )
    raw_killed = evidence.get("residualProcessesKilled") if isinstance(evidence.get("residualProcessesKilled"), list) else []
    normalized_killed = [int(pid) for pid in raw_killed if isinstance(pid, (int, float))]

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
        "watchpointHits": normalized_hits,
        "watchpointHitCount": len(normalized_hits),
        "dyldInitializersLogPath": evidence.get("dyldInitializersLogPath"),
        "blockingDialogWindows": normalized_dialogs,
        "blockingDialogCount": len(normalized_dialogs),
        "residualProcessesKilled": normalized_killed,
        "residualProcessesKilledCount": len(normalized_killed),
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
        # HOK-012-C.3-b.0: a non-empty `blockingDialogWindows` means the
        # inferior was frozen behind an NSAlert during evidence
        # collection — every slot/bp/watchpoint reading in this run is
        # contaminated. Callers must treat this as a hard-fail, not a
        # warning.
        "blockingDialogDetected": int(summary.get("blockingDialogCount") or 0) > 0,
        "residualProcessesKilled": int(summary.get("residualProcessesKilledCount") or 0) > 0,
    }


def determine_overall_pass(checks: dict[str, Any]) -> bool:
    return bool(
        checks.get("settingsReadBackMatchRequested")
        and checks.get("requiredCompatEventsPresent")
        and checks.get("forbiddenCompatEventsAbsent")
        and checks.get("lldbEvidencePresent")
        and checks.get("lldbAutomationReady")
        # HOK-012-C.3-b.0: contamination gate — any modal dialog
        # blocking the inferior forces overallPass to False regardless
        # of the other checks, because the evidence cannot be trusted.
        and not checks.get("lldbBlockingDialogDetected")
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

    # HOK-012-B: normalize watchpoint CLI inputs. An empty `--watch-address`
    # string means "legacy mode"; a non-empty value switches the MCP call
    # into watchpoint mode and implicitly enables the default dyld log path
    # unless the caller overrode `--dyld-log` (which can also be an empty
    # string to explicitly disable the redirection).
    raw_watch_address = (args.watch_address or "").strip()
    watchpoint_mode_requested = bool(raw_watch_address)
    watch_size = max(int(args.watch_size), 1)
    pre_run_commands = [cmd for cmd in (args.pre_run_command or []) if cmd.strip()]

    if args.dyld_log is None:
        # Default: enable redirection iff the caller asked for watchpoint mode.
        dyld_log_path: Path | None = (
            Path(DEFAULT_DYLD_LOG).expanduser().resolve() if watchpoint_mode_requested else None
        )
    else:
        raw_dyld_log = args.dyld_log.strip()
        dyld_log_path = Path(raw_dyld_log).expanduser().resolve() if raw_dyld_log else None

    watchpoint_report_path = Path(args.watchpoint_report).expanduser().resolve()

    # HOK-012-C: resolve deferred install & writer-address before the
    # report gets assembled so the top-level `configuration` block can
    # surface the effective pre-run script verbatim.
    defer_watchpoint_install = bool(args.defer_watchpoint_install)
    if args.writer_address is None:
        # Default: when defer mode is active and the caller did not
        # explicitly pass `--writer-address`, auto-use the HOK-011
        # singleton-accessor address. An empty caller-supplied value
        # (below) disables the auto-append so callers can inject their
        # own pre-run breakpoint command.
        writer_address = DEFAULT_WRITER_ADDRESS if defer_watchpoint_install else ""
    else:
        writer_address = args.writer_address.strip()

    # HOK-012-C.3-b.1: resolve SIGABRT interception. Default is ON when
    # defer mode is active (because the abort-intercept path is the only
    # reliable way to observe UE4 fatal in a scripted run — the Apple
    # crash dialog otherwise blocks the UI thread indefinitely), OFF
    # when defer mode is inactive (legacy HOK-012-B semantics).
    if args.intercept_sigabrt is None:
        intercept_sigabrt = defer_watchpoint_install
    else:
        intercept_sigabrt = bool(args.intercept_sigabrt)

    # HOK-012-C.3-b.2: resolve teardown timeout. 6s covers the richer
    # abort-stop handler under defer mode; legacy runs keep the 2s
    # behaviour from before HOK-012-C.3-b.
    if args.teardown_timeout is None:
        teardown_timeout = 6.0 if defer_watchpoint_install else 2.0
    else:
        teardown_timeout = max(float(args.teardown_timeout), 0.1)

    if intercept_sigabrt:
        # Put the SIGABRT handler BEFORE any breakpoint / watchpoint
        # install line so UE4 `abort()` is always caught in LLDB even if
        # the child fires abort earlier than the first writer bp.
        pre_run_commands = [
            "process handle -s true -n true -p false SIGABRT"
        ] + list(pre_run_commands)

    if defer_watchpoint_install and watchpoint_mode_requested and writer_address:
        # Auto-append the "breakpoint -> watchpoint" install line so the
        # watchpoint is armed only once the chosen writer function is
        # actually entered. `--auto-continue true` keeps the transcript
        # free of a breakpoint stop (we only want watchpoint hits);
        # `--one-shot true` keeps later calls of the same function from
        # reinstalling the watchpoint.
        size = watch_size
        auto_command = (
            f"breakpoint set --address {writer_address} "
            f'-C "watchpoint set expression -s {size} -- {raw_watch_address}" '
            f'-C "continue" --auto-continue true --one-shot true'
        )
        pre_run_commands = list(pre_run_commands) + [auto_command]

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
            # HOK-012-B: surface the watchpoint configuration so the
            # top-level report is self-descriptive.
            "watchpointModeRequested": watchpoint_mode_requested,
            "watchAddress": raw_watch_address or None,
            "watchSize": watch_size if watchpoint_mode_requested else None,
            "preRunCommands": pre_run_commands,
            "dyldInitializersLogPath": str(dyld_log_path) if dyld_log_path else None,
            "watchpointReportPath": str(watchpoint_report_path),
            # HOK-012-C: surface the deferred-install decision so the
            # report is self-descriptive for later review.
            "deferWatchpointInstall": defer_watchpoint_install,
            "writerAddress": writer_address or None,
            # HOK-012-C.3-b: surface the SIGABRT interception decision and
            # teardown window so the report captures the exact observation
            # geometry used for the run.
            "interceptSigabrt": intercept_sigabrt,
            "teardownTimeoutSeconds": teardown_timeout,
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
                launch_arguments: dict[str, Any] = {
                    "bundleId": args.bundle_id,
                    "withTerminalWindow": False,
                    "timeoutSeconds": lldb_timeout,
                }
                # HOK-012-B: forward the watchpoint / preRunCommands /
                # dyld-log options to the MCP tool only when they are
                # actually set, so default legacy invocations keep the
                # previous argument shape (and reproduce the exact same
                # MCP tool-call recorded in HOK-006 evidence).
                if watchpoint_mode_requested:
                    launch_arguments["watchAddress"] = raw_watch_address
                    launch_arguments["watchSize"] = watch_size
                if pre_run_commands:
                    launch_arguments["preRunCommands"] = pre_run_commands
                if dyld_log_path is not None:
                    launch_arguments["dyldInitializersLogPath"] = str(dyld_log_path)
                if defer_watchpoint_install:
                    # HOK-012-C: only forward the flag when the caller
                    # opted in, so the legacy MCP schema shape is 100%
                    # preserved for HOK-012-B-style invocations.
                    launch_arguments["deferWatchpointInstall"] = True
                # HOK-012-C.3-b.2: forward the teardown window only when
                # it differs from the MCP default (2.0s) to keep legacy
                # tool-call shapes intact.
                if abs(teardown_timeout - 2.0) > 1e-6:
                    launch_arguments["teardownTimeoutSeconds"] = teardown_timeout

                outcome = client.call_tool(
                    "launch_app_with_lldb",
                    launch_arguments,
                    request_timeout=max(lldb_timeout + teardown_timeout + 15.0, 20.0),
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
            # HOK-012-C.3-b.0: dialog-detection & residual-kill surface
            # into the top-level checks dict so CI / agent downstream
            # can read them without re-opening `launch.lldb`.
            "lldbBlockingDialogDetected": lldb_capture["blockingDialogDetected"],
            "lldbResidualProcessesKilled": lldb_capture["residualProcessesKilled"],
            "newCrashReportsDetected": bool(new_crash_reports),
        }
        report["checks"]["overallPass"] = determine_overall_pass(report["checks"])
        report["checks"]["exitCode"] = determine_exit_code(report["checks"]["overallPass"])

        # HOK-012-B: write the standalone watchpoint report and attach a
        # dyld-log summary. Only emit the watchpoint report when the run
        # was actually started in watchpoint mode, otherwise we would
        # overwrite the previous HOK-012 evidence with an empty document.
        watchpoint_artifact: dict[str, Any] = {
            "written": False,
            "path": str(watchpoint_report_path),
            "hitCount": 0,
        }
        dyld_log_artifact: dict[str, Any] = {
            "path": str(dyld_log_path) if dyld_log_path else None,
            "exists": False,
            "byteCount": 0,
            "initializerLineCount": 0,
            "tail": "",
        }
        if watchpoint_mode_requested:
            watch_payload: dict[str, Any] = {
                "schemaVersion": 1,
                "generatedAt": utc_now_iso(),
                "bundleId": args.bundle_id,
                "workflow": "hok-012-ngr-watchpoint",
                "configuration": {
                    "watchAddress": raw_watch_address,
                    "watchSize": watch_size,
                    "preRunCommands": pre_run_commands,
                    "lldbTimeout": lldb_timeout,
                    "dyldInitializersLogPath": str(dyld_log_path) if dyld_log_path else None,
                    "sourceLldbReportPath": str(output_path),
                    # HOK-012-C hand-off markers.
                    "deferWatchpointInstall": defer_watchpoint_install,
                    "writerAddress": writer_address or None,
                    # HOK-012-C.3-b markers: the run's observation
                    # geometry is only interpretable when paired with
                    # these two values.
                    "interceptSigabrt": intercept_sigabrt,
                    "teardownTimeoutSeconds": teardown_timeout,
                },
                "watchpoint": {
                    "hits": lldb_summary.get("watchpointHits") or [],
                    "hitCount": int(lldb_summary.get("watchpointHitCount") or 0),
                    "didStop": bool(lldb_summary.get("didStop")),
                    "stopReason": lldb_summary.get("stopReason"),
                    "timedOut": bool(lldb_summary.get("timedOut")),
                    "processIdentifier": lldb_summary.get("processIdentifier"),
                },
            }
            write_report(watchpoint_report_path, watch_payload)
            watchpoint_artifact.update(
                {
                    "written": True,
                    "hitCount": watch_payload["watchpoint"]["hitCount"],
                }
            )
            print(f"watchpoint report written: {watchpoint_report_path}")

        if dyld_log_path is not None:
            try:
                if dyld_log_path.exists():
                    raw_bytes = dyld_log_path.read_bytes()
                    text = raw_bytes.decode("utf-8", errors="replace")
                    lines = text.splitlines()
                    # dyld uses a stable `dyld[pid]:` prefix for initializer
                    # log lines; count those explicitly so the caller can
                    # tell the difference between "child wrote some stderr"
                    # and "DYLD_PRINT_INITIALIZERS actually fired".
                    init_count = sum(
                        1 for line in lines if "dyld" in line and "initializer" in line.lower()
                    )
                    # Limit the inline tail to keep the top-level report
                    # small; the full log stays on disk for later analysis.
                    tail = "\n".join(lines[-80:])
                    dyld_log_artifact.update(
                        {
                            "exists": True,
                            "byteCount": len(raw_bytes),
                            "initializerLineCount": init_count,
                            "tail": clip_text(tail, limit=4000),
                        }
                    )
            except Exception as log_error:  # pragma: no cover - defensive
                dyld_log_artifact["error"] = {
                    "type": type(log_error).__name__,
                    "message": str(log_error),
                }

        report["artifacts"] = {
            "watchpointReport": watchpoint_artifact,
            "dyldInitializersLog": dyld_log_artifact,
        }

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
            f"watchpointMode={watchpoint_mode_requested} "
            f"deferInstall={defer_watchpoint_install} "
            f"interceptSigabrt={intercept_sigabrt} "
            f"teardownTimeout={teardown_timeout:.1f}s "
            f"watchpointHits={watchpoint_artifact['hitCount']} "
            f"dyldLogBytes={dyld_log_artifact['byteCount']} "
            f"blockingDialogs={lldb_summary.get('blockingDialogCount', 0)} "
            f"residualPIDsKilled={lldb_summary.get('residualProcessesKilledCount', 0)} "
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
