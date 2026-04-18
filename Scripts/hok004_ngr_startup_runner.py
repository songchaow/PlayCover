#!/usr/bin/env python3
"""
HOK-004: 自动化验证 `com.tencent.ngr` 启动表现，并输出结构化 JSON 报告。

默认工作流：
1. `BuildScripts/build_and_install.sh`
2. 确保 GUI HTTP MCP 可达并完成 initialize/initialized
3. reset/update/get `com.tencent.ngr` 的最小兼容 raw settings
4. `launch_app`
5. 并发执行 `create_session` 与 settle window 内的 `list_sessions`
6. 读取 runtime launch diagnostics，锁定本轮 `processLaunchId`
7. 对比新增 `NGR-*.ips`
8. 将结构化报告写入 `build/`
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from runtime_launch_diagnostics_summary import (  # noqa: E402
    build_summary,
    parse_timestamp,
    read_events,
    read_manifest_entries,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_MCP_URL = "http://127.0.0.1:19820/mcp"
DEFAULT_PROTOCOL_VERSION = "2025-11-25"
DEFAULT_SETTLE_SECONDS = 10.0
DEFAULT_CREATE_SESSION_TIMEOUT = 10.0
DEFAULT_WAIT_TIMEOUT = 20.0
DEFAULT_POLL_INTERVAL = 0.5
DEFAULT_OUTPUT = Path("build/hok-004-ngr-startup-report.json")
DEFAULT_CONTAINER_ROOT = Path.home() / "Library/Containers/io.playcover.PlayCover"
DEFAULT_DIAGNOSTICS_ROOT = DEFAULT_CONTAINER_ROOT / "RuntimeLaunchDiagnostics"
DEFAULT_CRASH_REPORTS_ROOT = Path.home() / "Library/Logs/DiagnosticReports"
DEFAULT_PLAYCOVER_APP_CANDIDATES = (
    Path.home() / "Applications/PlayCover.app",
    Path("/Applications/PlayCover.app"),
)

MINIMAL_COMPAT_SETTINGS = {
    "metalCaptureEnabled": False,
    "injectMetalCaptureEnvironment": False,
    "shaderSourceReplacementEnabled": False,
    # HOK-010: `rootWorkDir=True` 让 PlayTools 把 cwd 改到 `/`，否则 UE4
    # 相对路径会继承 PlayCover 宿主 cwd，触发 `QtsFileSystem Create Failed!!`
    # 等 UE4 fallback。PlayApp.launch() 里对 minimalStartupCompat bundle
    # 做 self-healing 保证这里固化的值真正落到 plist + runtime。
    "rootWorkDir": True,
    "playChain": False,
}

REQUIRED_COMPAT_EVENTS = [
    "playcover_startup_compat_profile_applied",
    "playcover_screen_skipped",
    "playcover_input_skipped",
    "playcover_discord_skipped",
    "playcover_metal_capture_skipped",
    "playcover_library_injection_skipped",
    # HOK-010 后 runtime 走 `rootWorkDir=true` 分支，事件名是 `_changed`。
    "playcover_working_directory_changed",
    "playcover_launch_complete",
]

FORBIDDEN_COMPAT_EVENTS = [
    "playcover_screen_initialized",
    "playcover_input_initialized",
    "playcover_discord_initialized",
    "playcover_library_injection_installed",
]

AKINTERFACE_SCHEDULE_EVENT = "playcover_akinterface_delayed"
AKINTERFACE_START_EVENT = "playcover_akinterface_initialize_started"
AKINTERFACE_COMPLETE_EVENT = "playcover_akinterface_initialized"


class MCPError(RuntimeError):
    pass


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def clip_text(value: str, limit: int = 4000) -> str:
    if len(value) <= limit:
        return value
    return f"...<truncated {len(value) - limit} chars>...\n{value[-limit:]}"


def normalize_headers(headers: Any) -> dict[str, str]:
    return {str(key).lower(): str(value) for key, value in dict(headers).items()}


def decode_mcp_response_json(raw_body: str, content_type: str | None) -> dict[str, Any]:
    body = raw_body.strip()
    if not body:
        return {}
    normalized_content_type = str(content_type or "").lower()
    if "text/event-stream" not in normalized_content_type:
        return json.loads(body)

    data_payloads: list[str] = []
    for raw_line in body.splitlines():
        if not raw_line.startswith("data:"):
            continue
        payload = raw_line.removeprefix("data:").strip()
        if payload:
            data_payloads.append(payload)
    if not data_payloads:
        raise json.JSONDecodeError("No JSON payload found in event stream", raw_body, 0)
    return json.loads(data_payloads[-1])


def parse_tool_texts(response_json: dict[str, Any]) -> list[str]:
    result = response_json.get("result") or {}
    texts: list[str] = []
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
            texts.append(item["text"])
    return texts


def parse_tool_payload(response_json: dict[str, Any]) -> Any:
    texts = parse_tool_texts(response_json)
    parsed_payloads: list[Any] = []
    for text in texts:
        try:
            parsed_payloads.append(json.loads(text))
        except json.JSONDecodeError:
            continue
    if not parsed_payloads:
        return None
    if len(parsed_payloads) == 1:
        return parsed_payloads[0]
    return parsed_payloads


def snapshot_tool_outcome(outcome: dict[str, Any]) -> dict[str, Any]:
    return {
        "ok": bool(outcome.get("ok")),
        "httpStatus": outcome.get("httpStatus"),
        "isToolError": bool(outcome.get("isToolError")),
        "error": outcome.get("error"),
        "parsed": outcome.get("parsed"),
        "rawText": clip_text(str(outcome.get("rawText") or ""), limit=2000),
    }


def require_tool_success(outcome: dict[str, Any], description: str) -> dict[str, Any]:
    if outcome.get("ok"):
        return outcome
    error = outcome.get("error") or {}
    raise MCPError(
        f"{description} failed: httpStatus={outcome.get('httpStatus')} "
        f"error={json.dumps(error, ensure_ascii=False, sort_keys=True)}"
    )


def list_crash_reports(root: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    if not root.is_dir():
        return reports
    for path in sorted(root.glob("NGR-*.ips")):
        stat = path.stat()
        reports.append(
            {
                "name": path.name,
                "path": str(path),
                "size": stat.st_size,
                "modifiedAt": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
            }
        )
    return reports


def diff_new_crash_reports(
    baseline_reports: list[dict[str, Any]],
    current_reports: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    baseline_names = {str(item.get("name") or "") for item in baseline_reports}
    return [item for item in current_reports if str(item.get("name") or "") not in baseline_names]


def collect_process_launch_ids(events: list[dict[str, Any]]) -> set[str]:
    return {str(event.get("processLaunchId") or "") for event in events if event.get("processLaunchId")}


def sort_summaries_by_latest(summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        summaries,
        key=lambda item: parse_timestamp(item.get("lastTimestamp")) or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )


def select_current_run_summary(
    summaries: list[dict[str, Any]],
    baseline_process_launch_ids: set[str],
    launch_requested_at: str | None,
) -> dict[str, Any] | None:
    ordered = sort_summaries_by_latest(summaries)
    fresh = [
        summary
        for summary in ordered
        if str(summary.get("processLaunchId") or "")
        and str(summary.get("processLaunchId") or "") not in baseline_process_launch_ids
    ]
    if fresh:
        return fresh[0]

    launch_time = parse_timestamp(launch_requested_at)
    if launch_time is not None:
        time_matched = []
        for summary in ordered:
            first_timestamp = parse_timestamp(summary.get("firstTimestamp"))
            last_timestamp = parse_timestamp(summary.get("lastTimestamp"))
            if (first_timestamp and first_timestamp >= launch_time) or (last_timestamp and last_timestamp >= launch_time):
                time_matched.append(summary)
        if time_matched:
            return time_matched[0]

    return ordered[0] if ordered else None


def events_for_process_launch_id(
    events: list[dict[str, Any]],
    process_launch_id: str | None,
) -> list[dict[str, Any]]:
    if not process_launch_id:
        return []
    selected = [
        event
        for event in events
        if str(event.get("processLaunchId") or "") == process_launch_id
    ]
    return sorted(selected, key=lambda item: (str(item.get("timestamp") or ""), int(item.get("lineNumber") or 0)))


def evaluate_compat_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    event_names = [str(event.get("event") or "") for event in events]
    present_events = sorted({name for name in event_names if name})
    missing_required = [name for name in REQUIRED_COMPAT_EVENTS if name not in present_events]
    forbidden_present = [name for name in FORBIDDEN_COMPAT_EVENTS if name in present_events]
    return {
        "requiredEvents": list(REQUIRED_COMPAT_EVENTS),
        "requiredPresent": [name for name in REQUIRED_COMPAT_EVENTS if name in present_events],
        "missingRequired": missing_required,
        "forbiddenEvents": list(FORBIDDEN_COMPAT_EVENTS),
        "forbiddenPresent": forbidden_present,
        "allRequiredPresent": not missing_required,
        "allForbiddenAbsent": not forbidden_present,
        "observedEventCount": len(event_names),
        "observedEvents": present_events,
    }


def summarize_akinterface_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    schedule_events = [event for event in events if str(event.get("event") or "") == AKINTERFACE_SCHEDULE_EVENT]
    start_events = [event for event in events if str(event.get("event") or "") == AKINTERFACE_START_EVENT]
    completed_events = [event for event in events if str(event.get("event") or "") == AKINTERFACE_COMPLETE_EVENT]

    schedule_event = schedule_events[-1] if schedule_events else None
    start_event = start_events[-1] if start_events else None
    completed_event = completed_events[-1] if completed_events else None

    def extract_detail(event: dict[str, Any] | None, key: str) -> str | None:
        if not isinstance(event, dict):
            return None
        value = event.get(key)
        if value is not None:
            return str(value)
        details = event.get("details")
        if not isinstance(details, dict):
            return None
        value = details.get(key)
        return str(value) if value is not None else None

    return {
        "delayed": bool(schedule_event),
        "scheduled": {
            "present": bool(schedule_event),
            "timestamp": schedule_event.get("timestamp") if isinstance(schedule_event, dict) else None,
            "delaySeconds": extract_detail(schedule_event, "delaySeconds"),
            "mode": extract_detail(schedule_event, "mode"),
        },
        "initializeStarted": {
            "present": bool(start_event),
            "timestamp": start_event.get("timestamp") if isinstance(start_event, dict) else None,
            "delaySeconds": extract_detail(start_event, "delaySeconds"),
            "mode": extract_detail(start_event, "mode"),
        },
        "initialized": {
            "present": bool(completed_event),
            "timestamp": completed_event.get("timestamp") if isinstance(completed_event, dict) else None,
            "delaySeconds": extract_detail(completed_event, "delaySeconds"),
            "mode": extract_detail(completed_event, "mode"),
        },
    }


def summarize_session_polls(
    polls: list[dict[str, Any]],
    target_session_id: str | None,
    baseline_session_ids: set[str] | None = None,
) -> dict[str, Any]:
    observed_statuses: set[str] = set()
    matching_session_snapshots: list[dict[str, Any]] = []
    baseline_session_ids = baseline_session_ids or set()
    for poll in polls:
        sessions = poll.get("sessions") or []
        matching = [
            session
            for session in sessions
            if str(session.get("sessionId") or "") not in baseline_session_ids
        ]
        if target_session_id:
            matching = [session for session in sessions if session.get("sessionId") == target_session_id]
            if matching:
                matching_session_snapshots.extend(matching)
        for session in matching:
            status = str(session.get("status") or "")
            if status:
                observed_statuses.add(status)

    final_sessions = polls[-1].get("sessions") if polls else []
    return {
        "pollCount": len(polls),
        "observedStatuses": sorted(observed_statuses),
        "readyObserved": "ready" in observed_statuses,
        "disconnectedObserved": "disconnected" in observed_statuses,
        "closedObserved": "closed" in observed_statuses,
        "startingObserved": "starting" in observed_statuses,
        "matchingSessionSnapshots": matching_session_snapshots,
        "finalSessions": final_sessions,
    }


def resolve_playcover_app_path(explicit_path: str | None) -> Path:
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_dir():
            raise SystemExit(f"PlayCover app not found: {path}")
        return path
    for candidate in DEFAULT_PLAYCOVER_APP_CANDIDATES:
        if candidate.is_dir():
            return candidate.resolve()
    raise SystemExit(
        "PlayCover.app not found under ~/Applications or /Applications; "
        "run BuildScripts/build_and_install.sh first or pass --playcover-app-path"
    )


def extract_installed_playcover_app_path(build_stdout: str) -> Path | None:
    marker = "🎉 PlayCover 已安装到 "
    for line in build_stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(marker):
            return Path(stripped.removeprefix(marker)).expanduser().resolve()
    return None


def run_command(command: list[str], *, cwd: Path) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    return {
        "command": command,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


class MCPHTTPClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url
        self.session_id: str | None = None
        self.protocol_version: str | None = None
        self._next_id = 1
        self._id_lock = threading.Lock()

    def _take_request_id(self) -> int:
        with self._id_lock:
            request_id = self._next_id
            self._next_id += 1
        return request_id

    def _post(
        self,
        payload: dict[str, Any],
        *,
        include_session: bool,
        request_timeout: float = 5.0,
    ) -> tuple[int, dict[str, str], str]:
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if include_session:
            if not self.session_id:
                raise MCPError("MCP session is not initialized")
            headers["Mcp-Session-Id"] = self.session_id
            if self.protocol_version:
                headers["Mcp-Protocol-Version"] = self.protocol_version

        request = urllib.request.Request(self.base_url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=request_timeout) as response:
                return response.status, normalize_headers(response.headers), response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            return exc.code, normalize_headers(exc.headers), exc.read().decode("utf-8")

    def initialize(self) -> dict[str, Any]:
        payload = {
            "jsonrpc": "2.0",
            "id": self._take_request_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": DEFAULT_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "hok-004-runner", "version": "1.0"},
            },
        }
        status, headers, raw_body = self._post(payload, include_session=False)
        if status != 200:
            raise MCPError(f"initialize failed with HTTP {status}: {clip_text(raw_body, limit=800)}")
        response_json = decode_mcp_response_json(raw_body, headers.get("content-type"))
        session_id = headers.get("mcp-session-id")
        protocol_version = headers.get("mcp-protocol-version") or str(
            (response_json.get("result") or {}).get("protocolVersion") or DEFAULT_PROTOCOL_VERSION
        )
        if not session_id:
            raise MCPError("initialize succeeded but Mcp-Session-Id header is missing")
        self.session_id = session_id
        self.protocol_version = protocol_version
        return {
            "httpStatus": status,
            "sessionId": session_id,
            "protocolVersion": protocol_version,
            "response": response_json,
        }

    def send_initialized(self) -> dict[str, Any]:
        payload = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        status, _, raw_body = self._post(payload, include_session=True)
        if status != 202:
            raise MCPError(f"notifications/initialized failed with HTTP {status}: {clip_text(raw_body, limit=800)}")
        return {"httpStatus": status}

    def call_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        *,
        request_timeout: float = 5.0,
    ) -> dict[str, Any]:
        payload = {
            "jsonrpc": "2.0",
            "id": self._take_request_id(),
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        status, headers, raw_body = self._post(
            payload,
            include_session=True,
            request_timeout=request_timeout,
        )
        response_json: dict[str, Any] = {}
        if raw_body.strip():
            response_json = decode_mcp_response_json(raw_body, headers.get("content-type"))
        error = response_json.get("error")
        result = response_json.get("result") or {}
        tool_is_error = bool(result.get("isError"))
        texts = parse_tool_texts(response_json)
        raw_text = "\n".join(texts)
        return {
            "tool": name,
            "arguments": arguments,
            "httpStatus": status,
            "response": response_json,
            "error": error,
            "isToolError": tool_is_error,
            "rawText": raw_text,
            "parsed": parse_tool_payload(response_json),
            "ok": status == 200 and error is None and not tool_is_error,
        }


def wait_for_mcp_ready(client: MCPHTTPClient, *, timeout_seconds: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_error = ""
    while time.monotonic() < deadline:
        try:
            initialize_result = client.initialize()
            initialized_result = client.send_initialized()
            return {
                "ready": True,
                "initialize": initialize_result,
                "initialized": initialized_result,
                "attemptError": None,
            }
        except (MCPError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = str(exc)
            time.sleep(0.5)
    raise MCPError(f"MCP endpoint did not become ready within {timeout_seconds:g}s: {last_error}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the HOK-004 com.tencent.ngr startup verification workflow")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="target bundle identifier")
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL, help="GUI HTTP MCP endpoint")
    parser.add_argument(
        "--settle-seconds",
        type=float,
        default=DEFAULT_SETTLE_SECONDS,
        help="list_sessions polling window after launch (default: 10)",
    )
    parser.add_argument(
        "--create-session-timeout",
        type=float,
        default=DEFAULT_CREATE_SESSION_TIMEOUT,
        help="create_session timeout in seconds (default: 10)",
    )
    parser.add_argument(
        "--wait-timeout",
        type=float,
        default=DEFAULT_WAIT_TIMEOUT,
        help="how long to wait for GUI HTTP MCP readiness (default: 20)",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help="list_sessions polling interval during settle window",
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


def write_report(output_path: Path, report: dict[str, Any]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def determine_overall_pass(checks: dict[str, Any]) -> bool:
    return bool(
        checks.get("settingsReadBackMatchRequested")
        and checks.get("requiredCompatEventsPresent")
        and checks.get("forbiddenCompatEventsAbsent")
        and checks.get("createSessionSucceeded")
        and checks.get("readyObservedDuringSettleWindow")
        and not checks.get("disconnectedObservedDuringSettleWindow")
        and not checks.get("closedObservedDuringSettleWindow")
        and not checks.get("newCrashReportsDetected")
    )


def determine_exit_code(overall_pass: bool) -> int:
    return 0 if overall_pass else 1


def main() -> int:
    args = build_parser().parse_args()
    repo_root = SCRIPT_DIR.parent
    output_path = Path(args.output).expanduser().resolve()
    container_root = Path(args.container_root).expanduser().resolve()
    diagnostics_root = Path(args.diagnostics_root).expanduser().resolve()
    crash_reports_root = Path(args.crash_reports_root).expanduser().resolve()
    launch_events_path = diagnostics_root / args.bundle_id / "launch-events.jsonl"
    manifest_path = container_root / "ShaderCorpus" / args.bundle_id / "manifest.jsonl"
    settle_seconds = max(float(args.settle_seconds), 0.0)
    poll_interval = max(float(args.poll_interval), 0.1)
    create_session_timeout = max(float(args.create_session_timeout), 0.1)

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "workflow": "hok-004-ngr-startup-runner",
        "configuration": {
            "mcpUrl": args.mcp_url,
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

        installed_app_path = extract_installed_playcover_app_path(build_result["stdout"]) if not args.skip_build_install else None
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
        launch_outcome = require_tool_success(
            client.call_tool("launch_app", {"bundleId": args.bundle_id}),
            "launch_app",
        )
        report["launch"]["launchRequestedAt"] = launch_requested_at
        report["launch"]["launchApp"] = snapshot_tool_outcome(launch_outcome)

        create_session_box: dict[str, Any] = {}

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

        create_session_thread = threading.Thread(target=run_create_session, daemon=True)
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
        report["launch"]["createSession"] = create_session_box.get("outcome")
        report["launch"]["listSessionsPolls"] = session_polls
        report["launch"]["sessionSummary"] = session_summary

        current_events = read_events(launch_events_path)
        current_reports = list_crash_reports(crash_reports_root)
        manifest_entries = read_manifest_entries(manifest_path)
        all_summaries = build_summary(current_events, max(len(current_events), 1), manifest_entries)
        selected_summary = select_current_run_summary(all_summaries, baseline_process_launch_ids, launch_requested_at)
        selected_process_launch_id = (
            str(selected_summary.get("processLaunchId") or "") if isinstance(selected_summary, dict) else ""
        )
        selected_events = events_for_process_launch_id(current_events, selected_process_launch_id)
        compat_evaluation = evaluate_compat_events(selected_events)
        akinterface_summary = summarize_akinterface_events(selected_events)
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
            "akInterface": akinterface_summary,
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
            f"createSessionOk={report['checks']['createSessionSucceeded']} "
            f"readyObserved={report['checks']['readyObservedDuringSettleWindow']} "
            f"disconnectedObserved={report['checks']['disconnectedObservedDuringSettleWindow']} "
            f"newCrashReports={report['crashReports']['newReportCount']} "
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
