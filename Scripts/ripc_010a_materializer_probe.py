#!/usr/bin/env python3
"""
RIPC-010-A: 真机 materializer 断点采集脚本

在真机 iPad 的 LLDB 调试会话中加载此脚本，自动在 materializer
(0x10432a068) 的 entry 和 return (0x10432a31c) 处设置断点，
采集每次调用的 entryX1（x1 寄存器）、returnX0（x0 寄存器）和 LR（x30）。

用法（在 LLDB 中）:
    command script import /path/to/ripc_010a_materializer_probe.py
    # 脚本自动设置断点并开始采集；debugger 会在断点命中时自动继续

产物:
    /tmp/ripc-010a-materializer-log.jsonl       # 增量日志（每 hit 一行 JSON）
    build/ripc-010a-ipad-materializer-args.json # 最终结构化结果
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BUILD_DIR = Path(__file__).resolve().parent.parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)

_LOG_PATH = Path("/tmp/ripc-010a-materializer-log.jsonl")
_JSON_PATH = BUILD_DIR / "ripc-010a-ipad-materializer-args.json"

_MATERIALIZE_ENTRY_UNSLID = 0x10432A068
_MATERIALIZE_RETURN_UNSLID = 0x10432A31C
_NGR_TEXT_BASE = 0x100000000

# Thread-local trace storage: thread_id -> list of hit records
_results: list[dict] = []
_thread_call_map: dict[int, dict] = {}  # thread_id -> current entry record

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _log(msg: str) -> None:
    print(msg)
    try:
        with open(_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def _reg_u64(frame, name: str) -> int:
    try:
        reg = frame.FindRegister(name)
        if reg and reg.IsValid():
            return int(reg.GetValue(), 0)
    except Exception:
        pass
    return 0


def _resolve_ngr_slide(target) -> int | None:
    try:
        import lldb  # type: ignore
    except ImportError:
        return None
    for module in target.modules:
        filespec = module.GetFileSpec()
        if filespec.GetFilename() == "NGR":
            text = module.FindSection("__TEXT")
            if text and text.IsValid():
                slid = text.GetLoadAddress(target)
                if slid != lldb.LLDB_INVALID_ADDRESS:
                    return int(slid) - _NGR_TEXT_BASE
    return None


def _decode_pascal_string(process, address: int) -> dict:
    """Decode UE4-style Pascal string at address."""
    if address <= 0x100000000:
        return {"text": None, "summary": f"ptr=0x{address:x}"}

    try:
        err = None
        try:
            import lldb
            err = lldb.SBError()
        except ImportError:
            pass
        raw = process.ReadMemory(int(address), 16, err) if err is not None else None
        if raw is None or (err is not None and err.Fail()):
            return {"text": None, "summary": f"ptr=0x{address:x} read-fail"}
        if not isinstance(raw, (bytes, bytearray)):
            raw = raw.encode("latin-1")
        raw = bytes(raw)
    except Exception as exc:
        return {"text": None, "summary": f"ptr=0x{address:x} exc={exc}"}

    length = int.from_bytes(raw[0:4], "little", signed=False)
    w9_flag = int.from_bytes(raw[4:8], "little", signed=False)
    inline = raw[8:16]
    payload = b""
    truncated = False
    external_ptr = None

    if length > 0:
        if w9_flag < 2:
            payload = inline[: min(length, len(inline))]
            truncated = length > len(inline)
        else:
            external_ptr = int.from_bytes(inline, "little", signed=False)
            if 0x100000000 < external_ptr < 0x200000000000:
                try:
                    read_len = min(length, 128)
                    ext_raw = process.ReadMemory(external_ptr, read_len, err)
                    if ext_raw is not None and not (err is not None and err.Fail()):
                        if not isinstance(ext_raw, (bytes, bytearray)):
                            ext_raw = ext_raw.encode("latin-1")
                        payload = bytes(ext_raw)
                    truncated = length > read_len
                except Exception:
                    pass

    try:
        text = payload.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    except Exception:
        text = None

    summary = f"ptr=0x{address:x} len={length} w9={w9_flag} text={text!r} raw={raw.hex()}"
    if external_ptr is not None:
        summary += f" ext=0x{external_ptr:x}"
    if truncated:
        summary += " truncated=true"
    return {"text": text, "summary": summary}


def _short_backtrace(thread, limit: int = 6) -> str:
    frames = []
    for index in range(min(limit, thread.GetNumFrames())):
        frame = thread.GetFrameAtIndex(index)
        frames.append(f"#{index} 0x{frame.GetPC():x}")
    return " ".join(frames)


# ---------------------------------------------------------------------------
# Breakpoint callbacks
# ---------------------------------------------------------------------------


def materializer_entry_hit(frame, bp_loc, internal_dict):
    """Called when materializer entry breakpoint is hit."""
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    thread_id = int(thread.GetThreadID())

    slide = _resolve_ngr_slide(target)
    entry_addr = _MATERIALIZE_ENTRY_UNSLID + (slide or 0)

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x30 = _reg_u64(frame, "x30")

    x1_decoded = _decode_pascal_string(process, x1)

    record = {
        "call_id": len(_results) + 1,
        "thread_id": thread_id,
        "phase": "entry",
        "pc": frame.GetPC(),
        "materializer_addr": entry_addr,
        "entry_x0": x0,
        "entry_x1": x1,
        "entry_x1_text": x1_decoded.get("text"),
        "entry_x1_summary": x1_decoded.get("summary"),
        "entry_x2": x2,
        "entry_x3": x3,
        "entry_lr": x30,
        "backtrace": _short_backtrace(thread),
    }
    _results.append(record)
    _thread_call_map[thread_id] = record

    _log(
        f"[ripc-010a-entry] call={record['call_id']} "
        f"pc=0x{frame.GetPC():x} x1=0x{x1:x} "
        f"text={x1_decoded.get('text')!r} lr=0x{x30:x} "
        f"bt={record['backtrace']}"
    )

    # Incremental save
    _save_results()
    return False  # auto-continue


def materializer_return_hit(frame, bp_loc, internal_dict):
    """Called when materializer return breakpoint is hit."""
    thread = frame.GetThread()
    process = thread.GetProcess()
    thread_id = int(thread.GetThreadID())

    x0 = _reg_u64(frame, "x0")
    x30 = _reg_u64(frame, "x30")

    record = _thread_call_map.pop(thread_id, None)
    if record is None:
        # orphaned return (we missed the entry)
        record = {
            "call_id": len(_results) + 1,
            "thread_id": thread_id,
            "phase": "return_orphaned",
            "pc": frame.GetPC(),
            "return_x0": x0,
            "return_lr": x30,
        }
        _results.append(record)
    else:
        record["return_x0"] = x0
        record["return_lr"] = x30
        record["phase"] = "complete"

    _log(
        f"[ripc-010a-return] call={record.get('call_id', '?')} "
        f"pc=0x{frame.GetPC():x} x0=0x{x0:x} lr=0x{x30:x}"
    )

    _save_results()
    return False  # auto-continue


def _save_results():
    """Write current results to JSON file."""
    try:
        with open(_JSON_PATH, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "metadata": {
                        "script": "ripc_010a_materializer_probe.py",
                        "target": "materializer",
                        "entry_unslid": f"0x{_MATERIALIZE_ENTRY_UNSLID:x}",
                        "return_unslid": f"0x{_MATERIALIZE_RETURN_UNSLID:x}",
                        "record_count": len(_results),
                    },
                    "records": _results,
                },
                f,
                indent=2,
                ensure_ascii=False,
            )
    except Exception as exc:
        _log(f"[ripc-010a] save error: {exc}")


# ---------------------------------------------------------------------------
# LLDB module init
# ---------------------------------------------------------------------------


def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        _log("[ripc-010a] ERROR: No valid target selected")
        return

    slide = _resolve_ngr_slide(target)
    if slide is None:
        _log("[ripc-010a] WARNING: Could not resolve NGR slide; using 0")
        slide = 0

    entry_addr = _MATERIALIZE_ENTRY_UNSLID + slide
    return_addr = _MATERIALIZE_RETURN_UNSLID + slide

    # Clear previous log
    try:
        _LOG_PATH.unlink(missing_ok=True)
    except Exception:
        pass

    # Set entry breakpoint
    entry_bp = target.BreakpointCreateByAddress(entry_addr)
    entry_bp.SetScriptCallbackFunction(
        "ripc_010a_materializer_probe.materializer_entry_hit"
    )

    # Set return breakpoint
    return_bp = target.BreakpointCreateByAddress(return_addr)
    return_bp.SetScriptCallbackFunction(
        "ripc_010a_materializer_probe.materializer_return_hit"
    )

    _log("[ripc-010a] Materializer probe installed:")
    _log(f"  Entry breakpoint: 0x{entry_addr:x} (slide=0x{slide:x})")
    _log(f"  Return breakpoint: 0x{return_addr:x}")
    _log(f"  Log: {_LOG_PATH}")
    _log(f"  JSON: {_JSON_PATH}")
    print(f"[ripc-010a] Installed {entry_bp.GetNumLocations()} entry + {return_bp.GetNumLocations()} return breakpoints")
