#!/usr/bin/env python3
"""HOK-015-C: live 验证 ``com.tencent.ngr`` 的 UE4 cmdline preseed 修复。

工作流：
  1. 复用 HOK-004 的 MCP client：确保 PlayCover GUI 在运行，reset/update
     `com.tencent.ngr` 的最小兼容 settings，`launch_app`。
  2. 轮询 60s，周期性采样进程 %CPU / RSS / 线程数，记录峰值。
  3. 60s 后读取 `launch-events.jsonl`、对本次 processLaunchId 取子集，核
     验 HOK-015 事件（`hok015_ngr_cmdline_preseed status=primed`）、HOK-014
     alert 次数 = 0、并对比新增 `NGR-*.ips`。
  4. 用 `CGWindowListCopyWindowInfo` 读主窗口 bounds + memoryUsage。
  5. 结构化报告写到 `build/hok-015-live-report.json`；pass 条件全部满足
     时退出码 0。

该脚本不执行构建步骤（构建请走 `BuildScripts/build_and_install.sh` +
`FORCE_PLAYTOOLS_REBUILD=1 BuildScripts/sync_playtools_xcframework.sh`）。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok004_ngr_startup_runner import (  # noqa: E402
    DEFAULT_CRASH_REPORTS_ROOT,
    DEFAULT_DIAGNOSTICS_ROOT,
    DEFAULT_MCP_URL,
    DEFAULT_PLAYCOVER_APP_CANDIDATES,
    MCPError,
    MCPHTTPClient,
    clip_text,
    list_crash_reports,
    diff_new_crash_reports,
    require_tool_success,
    resolve_playcover_app_path,
    snapshot_tool_outcome,
    wait_for_mcp_ready,
)
from runtime_launch_diagnostics_summary import (  # noqa: E402
    build_summary,
    parse_timestamp,
    read_events,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_OUTPUT = Path("build/hok-015-live-report.json")
DEFAULT_OBSERVE_SECONDS = 60.0
DEFAULT_POLL_INTERVAL = 2.0

# HOK-015-C 判据阈值（子文档"第一轮"口径）
CPU_THRESHOLD_PERCENT = 5.0
RSS_THRESHOLD_BYTES = 800 * 1024 * 1024   # 800 MB
THREAD_COUNT_THRESHOLD = 20
WINDOW_MEMORY_THRESHOLD_BYTES = 1_000_000  # "合法渲染窗口 >1MB"

MINIMAL_COMPAT_SETTINGS = {
    "metalCaptureEnabled": False,
    "injectMetalCaptureEnvironment": False,
    "shaderSourceReplacementEnabled": False,
    "rootWorkDir": True,
    "playChain": False,
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def launch_playcover_if_needed(app_path: Path) -> dict[str, Any]:
    """Spawn PlayCover.app if it's not already running. Wait 5s for MCP to come up."""
    proc = subprocess.run(
        ["pgrep", "-x", "PlayCover"],
        capture_output=True, text=True,
    )
    if proc.stdout.strip():
        return {"alreadyRunning": True, "pids": proc.stdout.strip().split()}
    # Open the app
    launched = subprocess.run(
        ["open", "-a", str(app_path)],
        capture_output=True, text=True,
    )
    time.sleep(5.0)
    return {
        "alreadyRunning": False,
        "openReturncode": launched.returncode,
        "openStderr": clip_text(launched.stderr, limit=2000),
    }


def get_ngr_pid(bundle_id: str) -> int | None:
    """Resolve the NGR process pid via pgrep on the injected binary name."""
    # NGR binary is literally named "NGR".
    # But to match the NGR app launched via PlayCover, use `pgrep -f` against the
    # specific bundle application path.
    binary_name = "NGR"
    proc = subprocess.run(
        ["pgrep", "-x", binary_name],
        capture_output=True, text=True,
    )
    raw = proc.stdout.strip()
    if not raw:
        return None
    # Multiple pids might be returned; take the most recent (max pid).
    pids = [int(p) for p in raw.split() if p.strip().isdigit()]
    return max(pids) if pids else None


def sample_process_stats(pid: int) -> dict[str, Any] | None:
    """Sample %CPU / RSS / state of a pid via ps; thread count via `ps -M`.
    macOS `ps` does not support nlwp, so we count lines from `ps -M`.
    """
    ps_proc = subprocess.run(
        ["ps", "-p", str(pid), "-o", "pid=,pcpu=,rss=,state="],
        capture_output=True, text=True,
    )
    line = ps_proc.stdout.strip()
    if not line:
        return None
    parts = line.split(None, 3)
    if len(parts) < 4:
        return None
    try:
        pcpu = float(parts[1])
        rss_kb = int(parts[2])
    except ValueError:
        return None
    state = parts[3]
    # Thread count via `ps -M -p <pid>`: first line is header, remaining lines
    # each represent one thread.
    thr_proc = subprocess.run(
        ["ps", "-M", "-p", str(pid)],
        capture_output=True, text=True,
    )
    thr_lines = [ln for ln in thr_proc.stdout.splitlines() if ln.strip()]
    threads = max(len(thr_lines) - 1, 0)
    return {
        "pid": pid,
        "percentCPU": pcpu,
        "rssBytes": rss_kb * 1024,
        "state": state,
        "threadCount": threads,
        "timestamp": utc_now_iso(),
    }


def snapshot_window_info(target_name_substr: str = "NGR") -> list[dict[str, Any]]:
    """Use CGWindowListCopyWindowInfo via a small Swift one-liner to list
    windows whose owner contains NGR. Returns a list of dicts.
    """
    script = r"""
import Foundation
import AppKit
let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("[]"); exit(0)
}
let filtered = list.filter { info in
    let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
    return owner.contains("NGR")
}
let payload = filtered.map { info -> [String: Any] in
    var out: [String: Any] = [:]
    if let o = info[kCGWindowOwnerName as String] as? String { out["ownerName"] = o }
    if let p = info[kCGWindowOwnerPID as String] { out["ownerPID"] = p }
    if let layer = info[kCGWindowLayer as String] { out["layer"] = layer }
    if let m = info[kCGWindowMemoryUsage as String] { out["memoryUsage"] = m }
    if let b = info[kCGWindowBounds as String] as? [String: Any] { out["bounds"] = b }
    if let n = info[kCGWindowName as String] { out["name"] = n }
    if let num = info[kCGWindowNumber as String] { out["windowNumber"] = num }
    return out
}
let data = try JSONSerialization.data(withJSONObject: payload, options: [])
print(String(data: data, encoding: .utf8) ?? "[]")
"""
    proc = subprocess.run(
        ["xcrun", "swift", "-"],
        input=script,
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return []
    try:
        return json.loads(proc.stdout.strip() or "[]")
    except json.JSONDecodeError:
        return []


def snapshot_main_screen_frame() -> dict[str, Any] | None:
    """Return main screen frame (x, y, w, h) via Swift one-liner."""
    script = r"""
import Foundation
import AppKit
if let s = NSScreen.main {
    let f = s.frame
    let payload: [String: Any] = ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    print(String(data: data, encoding: .utf8) ?? "")
} else {
    print("")
}
"""
    proc = subprocess.run(
        ["xcrun", "swift", "-"],
        input=script,
        capture_output=True, text=True,
    )
    txt = proc.stdout.strip()
    if not txt:
        return None
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        return None


def window_intersects_screen(w: dict[str, Any], screen: dict[str, Any]) -> bool:
    bounds = w.get("bounds") or {}
    if not isinstance(bounds, dict):
        return False
    try:
        x = float(bounds.get("X", 0))
        y = float(bounds.get("Y", 0))
        width = float(bounds.get("Width", 0))
        height = float(bounds.get("Height", 0))
    except (TypeError, ValueError):
        return False
    sx = float(screen.get("x", 0))
    sy = float(screen.get("y", 0))
    sw = float(screen.get("w", 0))
    sh = float(screen.get("h", 0))
    # Rect intersection, non-empty.
    return (
        x + width > sx and x < sx + sw and
        y + height > sy and y < sy + sh and
        width > 0 and height > 0
    )


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="HOK-015-C live verification of com.tencent.ngr cmdline preseed"
    )
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    ap.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    ap.add_argument("--observe-seconds", type=float, default=DEFAULT_OBSERVE_SECONDS)
    ap.add_argument("--poll-interval", type=float, default=DEFAULT_POLL_INTERVAL)
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    ap.add_argument("--playcover-app-path", default=None)
    return ap


def main() -> int:
    args = build_parser().parse_args()
    bundle_id = args.bundle_id
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    crash_root = DEFAULT_CRASH_REPORTS_ROOT
    diag_root = DEFAULT_DIAGNOSTICS_ROOT / bundle_id
    baseline_crashes = list_crash_reports(crash_root)
    baseline_event_count = 0
    events_path = diag_root / "launch-events.jsonl"
    if events_path.exists():
        baseline_event_count = sum(1 for _ in events_path.read_text(encoding="utf-8").splitlines())

    app_path = resolve_playcover_app_path(args.playcover_app_path)

    # 0. Terminate any pre-existing NGR process so launch_app will inject the
    #    freshly built PlayTools. Without this, PlayCover's launch_app is a
    #    no-op when NGR is already running, and we end up observing the old
    #    runtime's events.
    kill_proc = subprocess.run(["pkill", "-x", "NGR"], capture_output=True, text=True)
    # Wait for it to actually exit (up to 5s)
    for _ in range(50):
        time.sleep(0.1)
        if not subprocess.run(["pgrep", "-x", "NGR"], capture_output=True, text=True).stdout.strip():
            break

    # 1. Ensure PlayCover is running (for MCP)
    pc_state = launch_playcover_if_needed(app_path)

    # 2. Connect to MCP
    client = MCPHTTPClient(args.mcp_url)
    mcp_ready = wait_for_mcp_ready(client, timeout_seconds=20.0)

    # 3. Reset + update settings to minimal-compat profile
    reset_outcome = client.call_tool(
        "reset_app_settings",
        {"bundleId": bundle_id},
    )
    require_tool_success(reset_outcome, "reset_app_settings")

    update_outcome = client.call_tool(
        "update_app_settings",
        {"bundleId": bundle_id, "changes": MINIMAL_COMPAT_SETTINGS},
    )
    require_tool_success(update_outcome, "update_app_settings")

    # 4. Launch app
    launch_requested_at = utc_now_iso()
    launch_outcome = client.call_tool(
        "launch_app",
        {"bundleId": bundle_id},
    )
    require_tool_success(launch_outcome, "launch_app")

    # 5. Observe for N seconds; sample process stats periodically
    samples: list[dict[str, Any]] = []
    t0 = time.monotonic()
    last_pid: int | None = None
    while time.monotonic() - t0 < args.observe_seconds:
        pid = get_ngr_pid(bundle_id)
        if pid is not None:
            last_pid = pid
            sample = sample_process_stats(pid)
            if sample:
                samples.append(sample)
        time.sleep(args.poll_interval)

    # 6. Snapshot windows
    window_info = snapshot_window_info("NGR")
    screen_frame = snapshot_main_screen_frame()

    # 7. Re-read events, diff against baseline
    events = read_events(events_path)
    new_events = events[baseline_event_count:] if len(events) > baseline_event_count else events
    summaries = build_summary(new_events, 50)

    # Prefer processLaunchId whose first timestamp is >= launch_requested_at
    launch_time = parse_timestamp(launch_requested_at)
    selected_summary: dict[str, Any] | None = None
    for s in sorted(summaries, key=lambda x: x.get("firstTimestamp") or ""):
        ft = parse_timestamp(s.get("firstTimestamp"))
        if launch_time is not None and ft is not None and ft >= launch_time:
            selected_summary = s
            break
    if selected_summary is None and summaries:
        selected_summary = summaries[-1]

    process_launch_id = (selected_summary or {}).get("processLaunchId")
    run_events = [
        e for e in new_events
        if str(e.get("processLaunchId") or "") == str(process_launch_id or "")
    ]

    hok015_events = [e for e in run_events if e.get("event") == "hok015_ngr_cmdline_preseed"]
    hok013_events = [e for e in run_events if e.get("event") == "hok013_ngr_slot_preheat"]
    hok014_alert_suppressed_events = [e for e in run_events if e.get("event") == "hok014_ngr_alert_suppressed"]
    hok014_installed_events = [e for e in run_events if e.get("event") == "hok014_ngr_alert_suppressor_installed"]

    # RuntimeLaunchDiagnostics.record spreads details onto the event dict
    # itself (no nested "details" key); so the status field is at the top level.
    hok015_primed = any(e.get("status") == "primed" for e in hok015_events)

    # Final process stats
    peak_cpu = max((s["percentCPU"] for s in samples), default=0.0)
    peak_rss = max((s["rssBytes"] for s in samples), default=0)
    peak_threads = max((s["threadCount"] for s in samples), default=0)
    last_state = samples[-1]["state"] if samples else None

    new_crashes = diff_new_crash_reports(baseline_crashes, list_crash_reports(crash_root))
    onscreen_windows = [w for w in window_info if int(w.get("layer", 0) or 0) == 0]
    intersecting = (
        [w for w in onscreen_windows if screen_frame and window_intersects_screen(w, screen_frame)]
        if screen_frame else []
    )

    # Pass criteria (from HOK-015 子文档 第一轮判据)
    checks = {
        "hok015PrimedObserved": hok015_primed,
        "hok014AlertSuppressedZero": len(hok014_alert_suppressed_events) == 0,
        "cpuAboveThreshold": peak_cpu >= CPU_THRESHOLD_PERCENT,
        "rssAboveThreshold": peak_rss >= RSS_THRESHOLD_BYTES,
        "threadCountAboveThreshold": peak_threads >= THREAD_COUNT_THRESHOLD,
        "windowIntersectsScreen": bool(intersecting),
        "windowMemoryUsageHealthy": any(
            int(w.get("memoryUsage", 0) or 0) > WINDOW_MEMORY_THRESHOLD_BYTES
            for w in intersecting
        ),
        "noNewCrashReports": len(new_crashes) == 0,
    }
    overall_pass = all(checks.values())

    report = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": bundle_id,
        "mcpUrl": args.mcp_url,
        "playcoverAppPath": str(app_path),
        "playcoverState": pc_state,
        "mcpReady": {
            "protocolVersion": mcp_ready.get("initialize", {}).get("protocolVersion"),
            "sessionId": mcp_ready.get("initialize", {}).get("sessionId"),
        },
        "launchRequestedAt": launch_requested_at,
        "observeSeconds": args.observe_seconds,
        "pollIntervalSeconds": args.poll_interval,
        "resetAppSettings": snapshot_tool_outcome(reset_outcome),
        "updateAppSettings": snapshot_tool_outcome(update_outcome),
        "launchApp": snapshot_tool_outcome(launch_outcome),
        "processSampleCount": len(samples),
        "processSamplesHead": samples[:3],
        "processSamplesTail": samples[-3:],
        "peakCPU": peak_cpu,
        "peakRSS": peak_rss,
        "peakThreads": peak_threads,
        "lastState": last_state,
        "lastPid": last_pid,
        "screenFrame": screen_frame,
        "ngrOnScreenWindows": onscreen_windows,
        "ngrWindowsIntersectingScreen": intersecting,
        "selectedProcessLaunchId": process_launch_id,
        "runEventCount": len(run_events),
        "hok015CmdlinePreseedEvents": [
            {k: v for k, v in e.items() if k not in {"lineNumber", "schemaVersion"}}
            for e in hok015_events
        ],
        "hok013PreheatEvents": [
            {k: v for k, v in e.items() if k not in {"lineNumber", "schemaVersion"}}
            for e in hok013_events
        ],
        "hok014InstallEvents": [
            {k: v for k, v in e.items() if k not in {"lineNumber", "schemaVersion"}}
            for e in hok014_installed_events
        ],
        "hok014AlertSuppressedEvents": [
            {k: v for k, v in e.items() if k not in {"lineNumber", "schemaVersion"}}
            for e in hok014_alert_suppressed_events
        ],
        "baselineCrashCount": len(baseline_crashes),
        "newCrashReports": new_crashes,
        "checks": checks,
        "overallPass": overall_pass,
    }
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"\nHOK-015-C report written to {output_path}")
    print(f"  overallPass = {overall_pass}")
    for k, v in checks.items():
        print(f"  {k}: {v}")
    print(f"  peakCPU = {peak_cpu:.1f}%, peakRSS = {peak_rss / (1024*1024):.1f} MB, "
          f"peakThreads = {peak_threads}, lastState = {last_state}")
    print(f"  hok015 preseed events = {len(hok015_events)}, "
          f"hok014 alert_suppressed = {len(hok014_alert_suppressed_events)}")
    print(f"  new crashes = {len(new_crashes)}")

    return 0 if overall_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
