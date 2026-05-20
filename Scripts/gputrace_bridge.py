#!/usr/bin/env python3
"""
gputrace_bridge.py — GPU Trace Replay 只读 bridge
R2.2 实现：纯 Python 3.9+ 标准库，不触发 replay。
子命令：scan-active-replay, scan-binaries, inspect-gputrace
"""

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

KNOWN_PROCESS_ROLES = {
    "Xcode": "xcode",
    "GPUToolsReplayService": "replay_service",
    "GPUToolsCompatService": "compat_service",
    "GPUToolsAgentService": "agent_service",
    "GTLLVMHelper": "llvm_helper",
}

KEY_SYMBOLS_BY_MODULE = {
    "GPUToolsReplay": [
        "GTMTLReplay_CLI",
        "GTMTLReplayController_makeDataSource",
        "GTHarvesterGetAPIStatistics",
        "g_runningInCI",
    ],
    "GPUToolsServices": [
        "DYCaptureSession",
        "DYGuestAppSession",
        "_kDYGuestAppLaunchReplayer",
    ],
    "GPUDebugger": [
        "GPUTraceShaderProfiler",
        "GTHostMTLCounterSampleBuffer",
    ],
}

PROCESS_GREP_PATTERN = "Xcode|GPUTools|Instruments|GTLLVMHelper"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _error_response(code: str, message: str, context: dict | None = None) -> dict:
    resp: dict[str, Any] = {"error": {"code": code, "message": message}}
    if context:
        resp["error"]["context"] = context
    return resp


def _detect_xcode_path(override: str | None) -> str | None:
    if override and Path(override).exists():
        return override
    result = subprocess.run(
        ["xcode-select", "-p"], capture_output=True, text=True
    )
    if result.returncode == 0:
        dev_path = result.stdout.strip()
        # /Applications/Xcode.app/Contents/Developer -> /Applications/Xcode.app
        xcode_app = Path(dev_path).parent.parent
        if xcode_app.suffix == ".app":
            return str(xcode_app)
        return dev_path
    return None


def _get_xcode_version(xcode_path: str) -> str | None:
    plist = Path(xcode_path) / "Contents" / "Info.plist"
    if not plist.exists():
        return None
    try:
        with open(plist, "rb") as f:
            data = plistlib.load(f)
        return data.get("CFBundleShortVersionString")
    except Exception:
        return None


def _classify_process_role(name: str) -> str:
    # Check more specific patterns first (longer keys first)
    for key in sorted(KNOWN_PROCESS_ROLES, key=len, reverse=True):
        if key in name:
            return KNOWN_PROCESS_ROLES[key]
    return "other"


def _classify_lsof_file(path: str) -> str:
    if "/store" in path:
        return "gputrace_store"
    if "device-resources" in path or "startup-" in path:
        return "gputrace_resource"
    if re.search(r"/functions\.|/libraries\.", path):
        return "metal_cache"
    if path.endswith(".metallib"):
        return "metallib"
    return "other"


def _classify_gputrace_file(name: str) -> str:
    if name.startswith("store"):
        return "store"
    if "device-resources" in name:
        return "resource"
    if name.startswith("startup-") and "platform" in name:
        return "platform"
    if name == "index":
        return "index"
    if name == "metadata":
        return "metadata"
    if "capture" in name:
        return "capture"
    return "other"


def _run_lsof(pid: int) -> list[dict]:
    try:
        result = subprocess.run(
            ["lsof", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []
    if result.returncode != 0:
        return []
    files = []
    for line in result.stdout.splitlines()[1:]:  # skip header
        parts = line.split()
        if len(parts) >= 9:
            fd = parts[3]
            fpath = parts[-1]
            if fpath.startswith("/"):
                files.append(
                    {"fd": fd, "path": fpath, "category": _classify_lsof_file(fpath)}
                )
    return files


def _run_nm(binary_path: str, key_symbols: list[str]) -> list[dict]:
    try:
        result = subprocess.run(
            ["nm", "-m", binary_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []
    if result.returncode != 0:
        return []
    # Deduplicate: keep the first (most informative) hit per symbol
    found_map: dict[str, dict] = {}
    for line in result.stdout.splitlines():
        for sym in key_symbols:
            if sym in line and sym not in found_map:
                visibility = "exported"
                if "undefined" in line.lower():
                    visibility = "undefined"
                elif "non-external" in line.lower() or "(was a private external)" in line.lower():
                    visibility = "local"
                sym_type = "function"
                if "_OBJC_CLASS_" in line:
                    sym_type = "class"
                elif "_OBJC_IVAR_" in line:
                    sym_type = "ivar"
                elif "(__DATA" in line and "global" in line.lower():
                    sym_type = "global"
                found_map[sym] = {"name": sym, "type": sym_type, "visibility": visibility}
                break
    return list(found_map.values())


# ---------------------------------------------------------------------------
# Subcommand: scan-active-replay
# ---------------------------------------------------------------------------


def cmd_scan_active_replay(args: argparse.Namespace) -> dict:
    if args.dry_run:
        return {
            "dry_run": True,
            "command": "scan-active-replay",
            "would_execute": ["pgrep", "lsof"],
        }

    result = subprocess.run(
        ["pgrep", "-fl", PROCESS_GREP_PATTERN],
        capture_output=True,
        text=True,
    )
    processes = []
    active_gputrace_path = None
    metal_cache_dir = None

    for line in result.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pid = int(parts[0])
        full_cmd = parts[1]
        name = Path(full_cmd.split()[0]).name if full_cmd else "unknown"
        role = _classify_process_role(full_cmd)

        open_files: list[dict] = []
        if args.include_lsof:
            if args.filter_pid is None or args.filter_pid == pid:
                open_files = _run_lsof(pid)
                if not open_files and result.returncode != 0:
                    print(
                        f"[warn] lsof failed for pid {pid}",
                        file=sys.stderr,
                    )

        for f in open_files:
            if ".gputrace/" in f["path"] and f["category"] == "gputrace_store":
                candidate = f["path"].split(".gputrace/")[0] + ".gputrace"
                if not active_gputrace_path:
                    active_gputrace_path = candidate
            if f["category"] == "metal_cache":
                candidate_dir = str(Path(f["path"]).parent)
                if not metal_cache_dir:
                    metal_cache_dir = candidate_dir

        processes.append(
            {
                "pid": pid,
                "name": name,
                "path": full_cmd.split()[0] if full_cmd else None,
                "role": role,
                "open_files": open_files,
            }
        )

    replay_active = any(
        p["role"] in ("replay_service", "compat_service") for p in processes
    )

    return {
        "replay_active": replay_active,
        "processes": processes,
        "active_gputrace_path": active_gputrace_path,
        "metal_cache_dir": metal_cache_dir,
    }


# ---------------------------------------------------------------------------
# Subcommand: scan-binaries
# ---------------------------------------------------------------------------

MODULE_SEARCH_PATHS = [
    "Contents/SharedFrameworks",
    "Contents/PlugIns/GPUDebugger.ideplugin/Contents/Frameworks",
    "Contents/PlugIns/GPUDebugger.ideplugin/Contents/Resources",
    "Contents/Frameworks",
]


def _find_module(xcode_path: str, module_name: str) -> Path | None:
    xcode = Path(xcode_path)
    for rel in MODULE_SEARCH_PATHS:
        candidate = xcode / rel / f"{module_name}.framework" / module_name
        if candidate.exists():
            return candidate
        # Also check .ideplugin variants
        candidate2 = xcode / rel / f"{module_name}.ideplugin" / "Contents" / "MacOS" / module_name
        if candidate2.exists():
            return candidate2
    # fallback: broad find
    for p in xcode.rglob(f"{module_name}.framework/{module_name}"):
        return p
    for p in xcode.rglob(f"{module_name}.ideplugin/Contents/MacOS/{module_name}"):
        return p
    return None


def cmd_scan_binaries(args: argparse.Namespace) -> dict:
    xcode_path = _detect_xcode_path(args.xcode_path)
    if not xcode_path:
        return _error_response("XCODE_NOT_FOUND", "Cannot detect Xcode installation")

    if args.dry_run:
        return {
            "dry_run": True,
            "command": "scan-binaries",
            "xcode_path": xcode_path,
            "would_scan_modules": args.modules.split(",") if args.modules else list(KEY_SYMBOLS_BY_MODULE.keys()),
        }

    xcode_version = _get_xcode_version(xcode_path)
    modules_to_scan = (
        args.modules.split(",") if args.modules else list(KEY_SYMBOLS_BY_MODULE.keys())
    )

    modules_out = []
    for mod_name in modules_to_scan:
        mod_path = _find_module(xcode_path, mod_name)
        if mod_path is None:
            modules_out.append(
                {"name": mod_name, "path": None, "exists": False}
            )
            continue

        arch_result = subprocess.run(
            ["file", str(mod_path)], capture_output=True, text=True
        )
        archs = re.findall(r"(arm64|x86_64)", arch_result.stdout)

        size_bytes = mod_path.stat().st_size if mod_path.exists() else 0

        key_syms = KEY_SYMBOLS_BY_MODULE.get(mod_name, [])
        found_symbols = _run_nm(str(mod_path), key_syms) if args.symbols else []

        matched_strings: list[str] = []
        if args.strings_pattern:
            try:
                strings_result = subprocess.run(
                    ["strings", str(mod_path)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                pat = re.compile(args.strings_pattern)
                matched_strings = [
                    s for s in strings_result.stdout.splitlines() if pat.search(s)
                ]
            except Exception:
                pass

        modules_out.append(
            {
                "name": mod_name,
                "path": str(mod_path),
                "exists": True,
                "arch": list(set(archs)),
                "size_bytes": size_bytes,
                "key_symbols": found_symbols,
                "matched_strings": matched_strings,
            }
        )

    return {
        "xcode_path": xcode_path,
        "xcode_version": xcode_version,
        "modules": modules_out,
    }


# ---------------------------------------------------------------------------
# Subcommand: inspect-gputrace
# ---------------------------------------------------------------------------


def cmd_inspect_gputrace(args: argparse.Namespace) -> dict:
    gputrace_path = Path(args.path)

    if args.dry_run:
        return {
            "dry_run": True,
            "command": "inspect-gputrace",
            "would_inspect": str(gputrace_path),
        }

    if not gputrace_path.exists():
        return _error_response(
            "GPUTRACE_NOT_FOUND",
            f"Path does not exist: {gputrace_path}",
        )
    if not gputrace_path.is_dir():
        return _error_response(
            "GPUTRACE_INVALID",
            f"Not a directory (expected .gputrace bundle): {gputrace_path}",
        )

    # Enumerate files
    total_size = 0
    files_out = []
    for item in sorted(gputrace_path.iterdir()):
        is_dir = item.is_dir()
        if is_dir:
            size = sum(f.stat().st_size for f in item.rglob("*") if f.is_file())
        else:
            size = item.stat().st_size
        total_size += size
        files_out.append(
            {
                "name": item.name,
                "type": _classify_gputrace_file(item.name),
                "size_bytes": size if args.include_sizes else None,
                "is_directory": is_dir,
            }
        )

    # Metadata
    metadata = None
    if args.include_metadata:
        metadata_file = gputrace_path / "metadata"
        if metadata_file.exists():
            try:
                with open(metadata_file, "rb") as f:
                    meta_data = plistlib.load(f)
                metadata = {
                    "uuid": str(meta_data.get("uuid", "")),
                    "captured_frames_count": meta_data.get("capturedFramesCount"),
                    "graphics_api": meta_data.get("graphicsAPI"),
                    "capture_version": meta_data.get("captureVersion"),
                    "device_id": meta_data.get("deviceIdentifier"),
                    "native_pointer_size": meta_data.get("nativePointerSize"),
                    "boundary_less": meta_data.get("boundaryLess"),
                    "interpose_feature_version": meta_data.get("interposeFeatureVersion"),
                    "library_link_time_versions": meta_data.get("libraryLinkTimeVersions"),
                    "unused_resource_counts": meta_data.get("unusedResourceCounts"),
                }
            except Exception as e:
                metadata = {"parse_error": str(e)}

    return {
        "valid": True,
        "total_size_bytes": total_size if args.include_sizes else None,
        "metadata": metadata,
        "files": files_out,
    }


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gputrace_bridge",
        description="GPU Trace Replay 只读 bridge — 纯观察，不触发 replay",
    )
    parser.add_argument("--json", action="store_true", default=True, help="JSON 输出（默认开启）")
    parser.add_argument("--pretty", action="store_true", help="缩进格式化 JSON")
    parser.add_argument("--quiet", action="store_true", help="抑制 stderr 输出")
    parser.add_argument("--xcode-path", default=None, help="覆盖 Xcode 路径")
    parser.add_argument("--dry-run", action="store_true", help="仅输出将执行的操作，不实际运行")

    sub = parser.add_subparsers(dest="command")

    # scan-active-replay
    p_scan = sub.add_parser("scan-active-replay", help="观察活动 replay 进程与文件访问")
    p_scan.add_argument("--include-lsof", action="store_true", default=True)
    p_scan.add_argument("--no-lsof", action="store_false", dest="include_lsof")
    p_scan.add_argument("--filter-pid", type=int, default=None)

    # scan-binaries
    p_bin = sub.add_parser("scan-binaries", help="扫描 Xcode 内 GPU 私有模块")
    p_bin.add_argument("--modules", default=None, help="逗号分隔模块名")
    p_bin.add_argument("--symbols", action="store_true", default=False, help="输出关键符号")
    p_bin.add_argument("--strings", dest="strings_pattern", default=None, help="正则匹配 strings 输出")

    # inspect-gputrace
    p_insp = sub.add_parser("inspect-gputrace", help="检查 .gputrace bundle 结构与 metadata")
    p_insp.add_argument("path", help=".gputrace bundle 路径")
    p_insp.add_argument("--include-sizes", action="store_true", default=True)
    p_insp.add_argument("--no-sizes", action="store_false", dest="include_sizes")
    p_insp.add_argument("--include-metadata", action="store_true", default=True)
    p_insp.add_argument("--no-metadata", action="store_false", dest="include_metadata")

    return parser


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.quiet:
        sys.stderr = open(os.devnull, "w")

    if not args.command:
        parser.print_help()
        sys.exit(1)

    dispatch = {
        "scan-active-replay": cmd_scan_active_replay,
        "scan-binaries": cmd_scan_binaries,
        "inspect-gputrace": cmd_inspect_gputrace,
    }

    handler = dispatch.get(args.command)
    if not handler:
        parser.print_help()
        sys.exit(1)

    result = handler(args)

    indent = 2 if args.pretty else None
    print(json.dumps(result, indent=indent, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
