#!/usr/bin/env python3
"""
RIPC-004: PlayCover 环境同构采集
在 PlayCover 环境下采集与真机 RIPC-003 完全相同的 17 类运行时上下文数据。

方法：通过 PlayCover MCP 启动 NGR → pgrep 找到 PID → LLDB attach →
逐一 evaluate ObjC 表达式 → 结构化输出 JSON。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
BUILD_DIR = SCRIPT_DIR.parent / "build"
OUTPUT_JSON = BUILD_DIR / "ripc-004-playcover-baseline.json"
LLDB_LOG = BUILD_DIR / "ripc-004-lldb.log"

DEFAULT_MCP_URL = "http://127.0.0.1:19820/mcp"
DEFAULT_PROTOCOL_VERSION = "2025-11-25"
BUNDLE_ID = "com.tencent.ngr"
PROCESS_NAME = "NGR"

SETTLE_SECONDS = 8  # Wait after launch for app to finish init


# ---------------------------------------------------------------------------
# MCP helpers (minimal, reused from hok004 pattern)
# ---------------------------------------------------------------------------

import urllib.request
import urllib.error


def _normalize_headers(headers) -> dict[str, str]:
    return {str(k).lower(): str(v) for k, v in dict(headers).items()}


def _decode_mcp_response(raw: str, ct: str | None) -> dict:
    body = raw.strip()
    if not body:
        return {}
    if "text/event-stream" in str(ct or "").lower():
        payloads = [
            ln.removeprefix("data:").strip()
            for ln in body.splitlines()
            if ln.startswith("data:")
        ]
        return json.loads(payloads[-1]) if payloads else {}
    return json.loads(body)


class MCPClient:
    def __init__(self, url: str = DEFAULT_MCP_URL):
        self.url = url
        self.session_id: str | None = None
        self.pv: str | None = None
        self._id = 0

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _post(self, payload: dict, *, with_session: bool, timeout: float = 10.0):
        hdrs = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if with_session:
            assert self.session_id, "no session"
            hdrs["Mcp-Session-Id"] = self.session_id
            if self.pv:
                hdrs["Mcp-Protocol-Version"] = self.pv
        req = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(), headers=hdrs, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, _normalize_headers(resp.headers), resp.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, _normalize_headers(exc.headers), exc.read().decode()

    def initialize(self):
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": DEFAULT_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "ripc-004-probe", "version": "1.0"},
            },
        }
        status, hdrs, raw = self._post(payload, with_session=False)
        if status != 200:
            raise RuntimeError(f"MCP initialize failed HTTP {status}: {raw[:500]}")
        self.session_id = hdrs.get("mcp-session-id")
        rj = _decode_mcp_response(raw, hdrs.get("content-type"))
        self.pv = hdrs.get("mcp-protocol-version") or str(
            (rj.get("result") or {}).get("protocolVersion") or DEFAULT_PROTOCOL_VERSION
        )
        # send initialized notification
        note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        self._post(note, with_session=True)
        return rj

    def call_tool(self, name: str, args: dict, *, timeout: float = 10.0):
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        }
        status, hdrs, raw = self._post(payload, with_session=True, timeout=timeout)
        rj = _decode_mcp_response(raw, hdrs.get("content-type"))
        return {
            "ok": status == 200 and not rj.get("error"),
            "status": status,
            "response": rj,
        }


# ---------------------------------------------------------------------------
# Process discovery
# ---------------------------------------------------------------------------

def find_pid(name: str, timeout: float = 15.0) -> int | None:
    """Poll for a process by name, return PID when found."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["pgrep", "-x", name], capture_output=True, text=True
        )
        pids = result.stdout.strip().splitlines()
        if pids:
            return int(pids[0])
        time.sleep(0.5)
    return None


# ---------------------------------------------------------------------------
# LLDB probe
# ---------------------------------------------------------------------------

# Each probe item: (key, lldb_command_type, expression)
# command_type: "expr" for scalar/string, "po" for collections that need expansion
LLDB_EXPRESSIONS: list[tuple[str, str, str]] = [
    # 1. NSHomeDirectory
    ("NSHomeDirectory", "expr", '(NSString *)NSHomeDirectory()'),
    # 2. NSBundle.mainBundle
    ("bundlePath", "expr", '(NSString *)[[NSBundle mainBundle] bundlePath]'),
    ("bundleIdentifier", "expr", '(NSString *)[[NSBundle mainBundle] bundleIdentifier]'),
    ("resourcePath", "expr", '(NSString *)[[NSBundle mainBundle] resourcePath]'),
    ("executablePath", "expr", '(NSString *)[[NSBundle mainBundle] executablePath]'),
    ("privateFrameworksPath", "expr", '(NSString *)[[NSBundle mainBundle] privateFrameworksPath]'),
    # 3. NSSearchPath - extract first element directly as string
    ("NSSearchPath_Documents", "expr",
     '(NSString *)[NSSearchPathForDirectoriesInDomains(9, 1, 1) firstObject]'),
    ("NSSearchPath_Library", "expr",
     '(NSString *)[NSSearchPathForDirectoriesInDomains(5, 1, 1) firstObject]'),
    ("NSSearchPath_Caches", "expr",
     '(NSString *)[NSSearchPathForDirectoriesInDomains(13, 1, 1) firstObject]'),
    ("NSSearchPath_AppSupport", "expr",
     '(NSString *)[NSSearchPathForDirectoriesInDomains(14, 1, 1) firstObject]'),
    # 4. NSTemporaryDirectory
    ("NSTemporaryDirectory", "expr", '(NSString *)NSTemporaryDirectory()'),
    # 5. cwd
    ("cwd", "expr", '(char *)getcwd(0, 0)'),
    # 6. Process arguments (use po for collection expansion)
    ("args", "po", '(NSArray *)[[NSProcessInfo processInfo] arguments]'),
    # 7. Environment (use po for dict expansion)
    ("environment", "po", '(NSDictionary *)[[NSProcessInfo processInfo] environment]'),
    # 8. FileManager doc URLs
    ("FM_DocURLs", "po",
     '(NSArray *)[[NSFileManager defaultManager] URLsForDirectory:9 inDomains:1]'),
    # 9. Writable checks
    ("writable_home", "expr",
     '(BOOL)[[NSFileManager defaultManager] isWritableFileAtPath:(NSString *)NSHomeDirectory()]'),
    ("writable_Documents", "expr",
     '(BOOL)[[NSFileManager defaultManager] isWritableFileAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]]'),
    ("writable_Library", "expr",
     '(BOOL)[[NSFileManager defaultManager] isWritableFileAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Library"]]'),
    ("writable_tmp", "expr",
     '(BOOL)[[NSFileManager defaultManager] isWritableFileAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"tmp"]]'),
    ("writable_NSTemp", "expr",
     '(BOOL)[[NSFileManager defaultManager] isWritableFileAtPath:(NSString *)NSTemporaryDirectory()]'),
    # 10. Home directory listing
    ("home_contents", "po",
     '(NSArray *)[[NSFileManager defaultManager] contentsOfDirectoryAtPath:(NSString *)NSHomeDirectory() error:nil]'),
    # 11. Documents listing
    ("docs_contents", "po",
     '(NSArray *)[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] error:nil]'),
    # 12. Library listing
    ("lib_contents", "po",
     '(NSArray *)[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Library"] error:nil]'),
    # 13. Bundle listing
    ("bundle_contents", "po",
     '(NSArray *)[[NSFileManager defaultManager] contentsOfDirectoryAtPath:(NSString *)[[NSBundle mainBundle] bundlePath] error:nil]'),
    # 14. Info.plist
    ("info_CFBundleIdentifier", "expr", '(NSString *)[[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"]'),
    ("info_CFBundleExecutable", "expr", '(NSString *)[[NSBundle mainBundle] infoDictionary][@"CFBundleExecutable"]'),
    ("info_CFBundleName", "expr", '(NSString *)[[NSBundle mainBundle] infoDictionary][@"CFBundleName"]'),
    ("info_CFBundleVersion", "expr", '(NSString *)[[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"]'),
    ("info_CFBundleShortVersionString", "expr", '(NSString *)[[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]'),
    # 15. stat on key paths (use po for dict expansion)
    ("stat_home", "po",
     '(NSDictionary *)[[NSFileManager defaultManager] attributesOfItemAtPath:(NSString *)NSHomeDirectory() error:nil]'),
    ("stat_Documents", "po",
     '(NSDictionary *)[[NSFileManager defaultManager] attributesOfItemAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] error:nil]'),
    ("stat_Library", "po",
     '(NSDictionary *)[[NSFileManager defaultManager] attributesOfItemAtPath:[(NSString *)NSHomeDirectory() stringByAppendingPathComponent:@"Library"] error:nil]'),
    ("stat_tmp", "po",
     '(NSDictionary *)[[NSFileManager defaultManager] attributesOfItemAtPath:(NSString *)NSTemporaryDirectory() error:nil]'),
    ("stat_bundle", "po",
     '(NSDictionary *)[[NSFileManager defaultManager] attributesOfItemAtPath:(NSString *)[[NSBundle mainBundle] bundlePath] error:nil]'),
    # 16. ProcessInfo
    ("processName", "expr", '(NSString *)[[NSProcessInfo processInfo] processName]'),
    ("hostName", "expr", '(NSString *)[[NSProcessInfo processInfo] hostName]'),
    ("osVersion", "expr", '(NSString *)[[NSProcessInfo processInfo] operatingSystemVersionString]'),
    # 17. UIDevice (if available)
    ("UIDevice_name", "expr", '(NSString *)[[UIDevice currentDevice] name]'),
    ("UIDevice_model", "expr", '(NSString *)[[UIDevice currentDevice] model]'),
    ("UIDevice_systemName", "expr", '(NSString *)[[UIDevice currentDevice] systemName]'),
    ("UIDevice_systemVersion", "expr", '(NSString *)[[UIDevice currentDevice] systemVersion]'),
]


def run_lldb_probe(pid: int) -> dict[str, str]:
    """Attach LLDB to PID, evaluate all expressions, return raw results."""
    # Build an LLDB command script
    cmds = [f"process attach --pid {pid}"]
    for key, cmd_type, expr in LLDB_EXPRESSIONS:
        if cmd_type == "po":
            cmds.append(f"po {expr}")
        else:
            cmds.append(f"expr -l objc -- {expr}")
    cmds.append("process detach")
    cmds.append("quit")

    script = "\n".join(cmds)
    script_path = BUILD_DIR / "ripc-004-lldb-script.txt"
    script_path.write_text(script)

    print(f"[RIPC-004] Attaching LLDB to PID {pid}...")
    result = subprocess.run(
        ["lldb", "--batch", "--source", str(script_path)],
        capture_output=True,
        text=True,
        timeout=120,
    )

    full_output = result.stdout + "\n" + result.stderr
    LLDB_LOG.write_text(full_output)
    print(f"[RIPC-004] LLDB output saved to {LLDB_LOG}")

    # Parse the output: each expression result follows the command
    return parse_lldb_output(full_output)


def parse_lldb_output(output: str) -> dict[str, str]:
    """Parse LLDB batch output, extract expression results keyed by name."""
    results = {}
    lines = output.splitlines()
    expr_idx = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        # Match both "expr -l objc --" and "po" commands
        is_expr = "expr -l objc --" in line
        is_po = (line.strip().startswith("(lldb)") and " po " in line) or \
                (line.strip() == "(lldb)" and i + 1 < len(lines))
        # More robust: check if this line contains our command markers
        if not is_expr:
            # Check for po command pattern
            stripped = line.replace("(lldb)", "").strip()
            if stripped.startswith("po "):
                is_po = True

        if is_expr or is_po:
            if expr_idx < len(LLDB_EXPRESSIONS):
                key = LLDB_EXPRESSIONS[expr_idx][0]
                # Collect all result lines until next (lldb) prompt or end
                result_lines = []
                i += 1
                while i < len(lines) and not lines[i].startswith("(lldb)"):
                    result_lines.append(lines[i])
                    i += 1
                raw = "\n".join(result_lines).strip()
                results[key] = raw
                expr_idx += 1
                continue
        i += 1

    return results


# ---------------------------------------------------------------------------
# Result structuring
# ---------------------------------------------------------------------------

def extract_string(raw: str) -> str:
    """Extract string value from LLDB output like '(NSString *) $3 = 0x... @"/path/to/..."'"""
    # Pattern: @"..."
    m = re.search(r'@"(.*?)"', raw)
    if m:
        return m.group(1)
    # Pattern for C strings: "..."
    m = re.search(r'"(.*?)"', raw)
    if m:
        return m.group(1)
    # Pattern for bare values
    m = re.search(r'=\s*(.+)', raw)
    if m:
        return m.group(1).strip()
    return raw


def extract_bool(raw: str) -> bool:
    """Extract bool from LLDB output like '(BOOL) $5 = YES' or '= true'"""
    lower = raw.lower()
    return "yes" in lower or "true" in lower or "= 1" in lower


def extract_array_strings(raw: str) -> list[str]:
    """Extract array of strings from LLDB NSArray output.

    Handles both 'expr' format (@"item") and 'po' format:
      <Swift.__SwiftDeferredNSArray 0x...>(
      item1,
      item2,
      ...
      )
    """
    # First try @"item" pattern (from expr output)
    quoted = re.findall(r'@"([^"]*)"', raw)
    if quoted:
        return quoted

    # Try po format: items between ( and ), comma-separated with newlines
    m = re.search(r'\(\s*\n(.*?)\n\)', raw, re.DOTALL)
    if m:
        items = []
        for line in m.group(1).splitlines():
            item = line.strip().rstrip(",").strip()
            if item and item not in ("", ")"):
                # Remove surrounding quotes if present
                item = item.strip('"')
                items.append(item)
        return items

    return []


def extract_stat_info(raw: str) -> dict:
    """Extract file stat info from NSFileManager attributes po output."""
    info = {}
    uid_m = re.search(r'NSFileOwnerAccountID\s*=\s*(\d+)', raw)
    gid_m = re.search(r'NSFileGroupOwnerAccountID\s*=\s*(\d+)', raw)
    perm_m = re.search(r'NSFilePosixPermissions\s*=\s*(\d+)', raw)
    type_m = re.search(r'NSFileType\s*=\s*(\S+)', raw)
    owner_m = re.search(r'NSFileOwnerAccountName\s*=\s*(\S+)', raw)
    group_m = re.search(r'NSFileGroupOwnerAccountName\s*=\s*(\S+)', raw)
    if uid_m:
        info["uid"] = int(uid_m.group(1))
    if gid_m:
        info["gid"] = int(gid_m.group(1))
    if perm_m:
        info["mode"] = oct(int(perm_m.group(1)))
    if type_m:
        info["type"] = type_m.group(1).rstrip(";")
    if owner_m:
        info["owner"] = owner_m.group(1).rstrip(";")
    if group_m:
        info["group"] = group_m.group(1).rstrip(";")
    return info


def extract_env_dict(raw: str) -> dict[str, str]:
    """Extract environment dictionary from LLDB NSDictionary po output.

    Format:
    {
        "KEY" = "value";
        KEY = value;
        ...
    }
    """
    env = {}
    # Match lines like:  "KEY" = "value";  or  KEY = value;  or  KEY = "value";
    for m in re.finditer(
        r'^\s*"?([A-Za-z_][A-Za-z0-9_]*)"?\s*=\s*"?(.*?)"?\s*;?\s*$',
        raw,
        re.MULTILINE,
    ):
        key = m.group(1)
        val = m.group(2).strip().rstrip(";").rstrip('"')
        # Skip dict structure markers
        if key in ("NSObject",):
            continue
        env[key] = val
    return env


def structure_results(raw_results: dict[str, str]) -> dict:
    """Convert raw LLDB results into the same JSON structure as RIPC-003."""
    hostname = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    mac_version = subprocess.run(
        ["sw_vers", "-productVersion"], capture_output=True, text=True
    ).stdout.strip()

    baseline = {
        "metadata": {
            "source": "PlayCover-macCatalyst",
            "device": f"Mac ({hostname})",
            "os": f"macOS {mac_version}",
            "bundleId": BUNDLE_ID,
            "originalBundleId": BUNDLE_ID,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
            "collection_method": "LLDB attach + ObjC expression evaluation in PlayCover process",
        },
        "paths": {
            "NSHomeDirectory": extract_string(raw_results.get("NSHomeDirectory", "")),
            "bundlePath": extract_string(raw_results.get("bundlePath", "")),
            "bundleIdentifier": extract_string(raw_results.get("bundleIdentifier", "")),
            "resourcePath": extract_string(raw_results.get("resourcePath", "")),
            "executablePath": extract_string(raw_results.get("executablePath", "")),
            "privateFrameworksPath": extract_string(raw_results.get("privateFrameworksPath", "")),
            "NSSearchPath_Documents": extract_string(raw_results.get("NSSearchPath_Documents", "")),
            "NSSearchPath_Library": extract_string(raw_results.get("NSSearchPath_Library", "")),
            "NSSearchPath_Caches": extract_string(raw_results.get("NSSearchPath_Caches", "")),
            "NSSearchPath_AppSupport": extract_string(raw_results.get("NSSearchPath_AppSupport", "")),
            "NSTemporaryDirectory": extract_string(raw_results.get("NSTemporaryDirectory", "")),
            "cwd": extract_string(raw_results.get("cwd", "")),
            "args": extract_array_strings(raw_results.get("args", "")),
            "FM_DocURLs": extract_array_strings(raw_results.get("FM_DocURLs", "")),
        },
        "environment": extract_env_dict(raw_results.get("environment", "")),
        "writable": {
            "home": extract_bool(raw_results.get("writable_home", "")),
            "Documents": extract_bool(raw_results.get("writable_Documents", "")),
            "Library": extract_bool(raw_results.get("writable_Library", "")),
            "tmp": extract_bool(raw_results.get("writable_tmp", "")),
            "NSTemporaryDirectory": extract_bool(raw_results.get("writable_NSTemp", "")),
        },
        "stat": {
            "home": extract_stat_info(raw_results.get("stat_home", "")),
            "Documents": extract_stat_info(raw_results.get("stat_Documents", "")),
            "Library": extract_stat_info(raw_results.get("stat_Library", "")),
            "tmp": extract_stat_info(raw_results.get("stat_tmp", "")),
            "bundle": extract_stat_info(raw_results.get("stat_bundle", "")),
        },
        "directory_listings": {
            "home": extract_array_strings(raw_results.get("home_contents", "")),
            "Documents": extract_array_strings(raw_results.get("docs_contents", "")),
            "Library": extract_array_strings(raw_results.get("lib_contents", "")),
            "bundle": extract_array_strings(raw_results.get("bundle_contents", "")),
        },
        "info_plist": {
            "CFBundleIdentifier": extract_string(raw_results.get("info_CFBundleIdentifier", "")),
            "CFBundleExecutable": extract_string(raw_results.get("info_CFBundleExecutable", "")),
            "CFBundleName": extract_string(raw_results.get("info_CFBundleName", "")),
            "CFBundleVersion": extract_string(raw_results.get("info_CFBundleVersion", "")),
            "CFBundleShortVersionString": extract_string(raw_results.get("info_CFBundleShortVersionString", "")),
        },
        "device_info": {
            "processName": extract_string(raw_results.get("processName", "")),
            "hostName": extract_string(raw_results.get("hostName", "")),
            "osVersion": extract_string(raw_results.get("osVersion", "")),
            "UIDevice_name": extract_string(raw_results.get("UIDevice_name", "")),
            "UIDevice_model": extract_string(raw_results.get("UIDevice_model", "")),
            "UIDevice_systemName": extract_string(raw_results.get("UIDevice_systemName", "")),
            "UIDevice_systemVersion": extract_string(raw_results.get("UIDevice_systemVersion", "")),
        },
        "_raw_lldb": raw_results,  # Keep raw for debugging
    }
    return baseline


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # Step 1: Check if NGR is already running
    pid = find_pid(PROCESS_NAME, timeout=2)
    if pid:
        print(f"[RIPC-004] NGR already running at PID {pid}")
    else:
        # Step 2: Launch via MCP
        print("[RIPC-004] Initializing PlayCover MCP...")
        try:
            client = MCPClient()
            client.initialize()
            print("[RIPC-004] MCP initialized, launching NGR...")
            result = client.call_tool("launch_app", {"bundleId": BUNDLE_ID}, timeout=30)
            if not result["ok"]:
                print(f"[RIPC-004] WARNING: launch_app returned non-ok: {json.dumps(result, indent=2)[:500]}")
            else:
                print("[RIPC-004] launch_app succeeded")
        except Exception as e:
            print(f"[RIPC-004] MCP launch failed: {e}")
            print("[RIPC-004] Trying manual open...")
            # Fallback: try to open the app via open command
            app_path = Path.home() / "Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app"
            if app_path.exists():
                subprocess.run(["open", str(app_path)], check=False)
            else:
                print(f"[RIPC-004] ERROR: App not found at {app_path}")
                sys.exit(1)

        # Wait for process to appear
        print(f"[RIPC-004] Waiting for {PROCESS_NAME} process...")
        pid = find_pid(PROCESS_NAME, timeout=30)
        if not pid:
            print(f"[RIPC-004] ERROR: {PROCESS_NAME} process not found after 30s")
            sys.exit(1)
        print(f"[RIPC-004] Found {PROCESS_NAME} at PID {pid}")

    # Step 3: Wait for app to settle
    print(f"[RIPC-004] Waiting {SETTLE_SECONDS}s for app to settle...")
    time.sleep(SETTLE_SECONDS)

    # Verify process still alive
    alive_check = subprocess.run(["kill", "-0", str(pid)], capture_output=True)
    if alive_check.returncode != 0:
        print(f"[RIPC-004] ERROR: Process {pid} died during settle period")
        sys.exit(1)

    # Step 4: Run LLDB probe
    raw_results = run_lldb_probe(pid)
    print(f"[RIPC-004] Collected {len(raw_results)} raw results from LLDB")

    if not raw_results:
        print("[RIPC-004] ERROR: No results collected. Check LLDB log:")
        print(f"  {LLDB_LOG}")
        sys.exit(1)

    # Step 5: Structure and save
    baseline = structure_results(raw_results)
    OUTPUT_JSON.write_text(json.dumps(baseline, indent=2, ensure_ascii=False))
    print(f"[RIPC-004] Baseline saved to {OUTPUT_JSON}")

    # Print summary
    print("\n===== RIPC-004 PLAYCOVER BASELINE SUMMARY =====")
    paths = baseline["paths"]
    print(f"  NSHomeDirectory:  {paths['NSHomeDirectory']}")
    print(f"  bundlePath:       {paths['bundlePath']}")
    print(f"  bundleIdentifier: {paths['bundleIdentifier']}")
    print(f"  cwd:              {paths['cwd']}")
    print(f"  NSTemporaryDir:   {paths['NSTemporaryDirectory']}")
    print(f"  Documents:        {paths['NSSearchPath_Documents']}")
    print(f"  Library:          {paths['NSSearchPath_Library']}")
    w = baseline["writable"]
    print(f"  Writable: home={w['home']}, Documents={w['Documents']}, Library={w['Library']}, tmp={w['tmp']}")
    print(f"  Environment keys: {len(baseline['environment'])}")
    print("================================================")

    return 0


if __name__ == "__main__":
    sys.exit(main())
