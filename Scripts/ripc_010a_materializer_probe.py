#!/usr/bin/env python3
"""
RIPC-010-A: real iPad materializer / vcall trace probe for LLDB.

Load this script inside an LLDB session attached to the real iPad NGR process.
It installs module-relative breakpoints in the `NGR` image so the breakpoints
survive ASLR slide changes and early loader remaps.

Captured data:
    - create-table materialize vcall precall / return (`0x100122f54` / `0x100122f58`)
    - materializer entry / return (`0x10432a068` / `0x10432a31c`)

Artifacts:
    - `/tmp/ripc-010a-materializer-log.jsonl`
    - `build/ripc-010a-ipad-materializer-args.json`
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path

BUILD_DIR = Path(__file__).resolve().parent.parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULT_LOG_PATH = Path("/tmp/ripc-010a-materializer-log.jsonl")
_DEFAULT_JSON_PATH = BUILD_DIR / "ripc-010a-ipad-materializer-args.json"


def _artifact_path_from_env(env_name: str, default: Path) -> Path:
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return default
    try:
        return Path(raw).expanduser().resolve()
    except Exception:
        return default


_LOG_PATH = _artifact_path_from_env("RIPC_010A_PROBE_LOG_PATH", _DEFAULT_LOG_PATH)
_JSON_PATH = _artifact_path_from_env("RIPC_010A_PROBE_JSON_PATH", _DEFAULT_JSON_PATH)
_SESSION_STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%S%z")

_NGR_TEXT_BASE = 0x100000000
_NGR_MODULE_NAME = "NGR"

_MATERIALIZE_ENTRY_UNSLID = 0x10432A068
_MATERIALIZE_RETURN_UNSLID = 0x10432A31C
_VCALL_PRECALL_UNSLID = 0x100122F54
_VCALL_RETURN_UNSLID = 0x100122F58

_records: list[dict] = []
_thread_materializer_map: dict[int, dict] = {}
_thread_vcall_map: dict[int, dict] = {}


def _log(msg: str) -> None:
    print(msg)
    try:
        _LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def _save_results() -> None:
    try:
        _JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(_JSON_PATH, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "recordCount": len(_records),
                    "metadata": {
                        "script": "ripc_010a_materializer_probe.py",
                        "target": "real-ipad-materializer-and-vcall",
                        "sessionStartedAt": _SESSION_STARTED_AT,
                        "ngrModule": _NGR_MODULE_NAME,
                        "materializerEntryUnslid": f"0x{_MATERIALIZE_ENTRY_UNSLID:x}",
                        "materializerReturnUnslid": f"0x{_MATERIALIZE_RETURN_UNSLID:x}",
                        "vcallPrecallUnslid": f"0x{_VCALL_PRECALL_UNSLID:x}",
                        "vcallReturnUnslid": f"0x{_VCALL_RETURN_UNSLID:x}",
                        "recordCount": len(_records),
                    },
                    "records": _records,
                },
                f,
                indent=2,
                ensure_ascii=False,
            )
    except Exception as exc:
        _log(f"[ripc-010a] save error: {exc}")


def _reg_u64(frame, name: str) -> int:
    reg = frame.FindRegister(name)
    if not reg or not reg.IsValid():
        return 0
    try:
        return int(reg.GetValue(), 0)
    except (TypeError, ValueError):
        return 0


def _read_bytes(process, address: int, size: int) -> bytes | None:
    if address <= 0x100000000 or size <= 0:
        return None
    try:
        import lldb  # type: ignore

        err = lldb.SBError()
        data = process.ReadMemory(int(address), int(size), err)
        if err.Fail() or data is None:
            return None
        if isinstance(data, (bytes, bytearray)):
            return bytes(data)
        return data.encode("latin-1")
    except Exception:
        return None


def _read_u64(process, address: int) -> int | None:
    raw = _read_bytes(process, address, 8)
    if raw is None or len(raw) != 8:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _resolve_ngr_module(target):
    for module in target.modules:
        filespec = module.GetFileSpec()
        if filespec.GetFilename() == _NGR_MODULE_NAME:
            return module
    return None


def _resolve_ngr_slide(target) -> int | None:
    try:
        import lldb  # type: ignore
    except ImportError:
        return None
    module = _resolve_ngr_module(target)
    if module is None:
        return None
    text = module.FindSection("__TEXT")
    if text and text.IsValid():
        slid = text.GetLoadAddress(target)
        if slid != lldb.LLDB_INVALID_ADDRESS:
            return int(slid) - _NGR_TEXT_BASE
    return None


def _resolve_module_address(target, unslid_address: int):
    module = _resolve_ngr_module(target)
    if module is None:
        return None
    try:
        return module.ResolveFileAddress(int(unslid_address))
    except Exception:
        return None


def _run_lldb_command(debugger, command: str) -> tuple[bool, str]:
    try:
        import lldb  # type: ignore
    except ImportError:
        return False, "lldb import failed"

    ci = debugger.GetCommandInterpreter()
    result = lldb.SBCommandReturnObject()
    ci.HandleCommand(command, result)
    output = (result.GetOutput() or "") + (result.GetError() or "")
    return bool(result.Succeeded()), output


def _extract_breakpoint_id(text: str) -> int | None:
    match = re.search(r"Breakpoint\s+(\d+):", text)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def _install_module_breakpoint(debugger, target, unslid_address: int, callback_name: str, label: str):
    safe_label = label.replace("-", "_")
    command = (
        f"breakpoint set --shlib {_NGR_MODULE_NAME} --address 0x{unslid_address:x} "
        f"-N {safe_label}"
    )
    ok, output = _run_lldb_command(debugger, command)
    if output.strip():
        _log(f"[ripc-010a] {label} command output: {output.strip()}")
    if not ok:
        _log(
            f"[ripc-010a] ERROR: failed to create module breakpoint for {label} 0x{unslid_address:x}"
        )
        return None

    bp_id = _extract_breakpoint_id(output)
    if bp_id is None:
        _log(f"[ripc-010a] ERROR: could not parse breakpoint id for {label}")
        return None

    bp = target.FindBreakpointByID(bp_id)
    if not bp or not bp.IsValid():
        _log(f"[ripc-010a] ERROR: breakpoint id {bp_id} for {label} is invalid")
        return None

    bp.SetScriptCallbackFunction(callback_name)
    try:
        bp.SetAutoContinue(True)
    except Exception:
        pass

    _log(
        f"[ripc-010a] breakpoint {label}: file=0x{unslid_address:x} id={bp_id} locations={bp.GetNumLocations()}"
    )
    return bp


def _read_c_string_bytes(process, address: int, max_size: int = 512) -> tuple[bytes | None, bool]:
    raw = _read_bytes(process, address, max_size)
    if raw is None or len(raw) == 0:
        return None, False
    terminator = raw.find(b"\x00")
    if terminator >= 0:
        return raw[:terminator], False
    return raw, True


def _read_utf16_c_string_bytes(process, address: int, max_size: int = 512) -> tuple[bytes | None, bool]:
    raw = _read_bytes(process, address, max_size)
    if raw is None or len(raw) < 2:
        return None, False

    end = None
    for idx in range(0, len(raw) - 1, 2):
        if raw[idx : idx + 2] == b"\x00\x00":
            end = idx
            break

    if end is None:
        size = len(raw) - (len(raw) % 2)
        return raw[:size], True
    return raw[:end], False


def _looks_like_path_text(text: str) -> bool:
    if len(text) < 4:
        return False
    if "/" not in text and "\\" not in text:
        return False
    printable = sum(1 for ch in text if ch.isprintable() and ch not in "\r\n\t")
    return printable / max(1, len(text)) >= 0.9


def _decode_direct_utf8_string(process, address: int) -> dict | None:
    payload, truncated = _read_c_string_bytes(process, address)
    if not payload:
        return None
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not _looks_like_path_text(text):
        return None

    summary = f"ptr=0x{address:x} mode=direct-utf8 len={len(payload)} text={text!r} raw16={payload[:16].hex()}"
    if truncated:
        summary += " truncated=true"
    return {
        "text": text,
        "summary": summary,
        "mode": "direct-utf8",
        "encoding": "utf-8",
    }


def _decode_direct_utf16_string(process, address: int) -> dict | None:
    payload, truncated = _read_utf16_c_string_bytes(process, address)
    if not payload:
        return None
    try:
        text = payload.decode("utf-16-le")
    except UnicodeDecodeError:
        return None
    if not _looks_like_path_text(text):
        return None

    summary = f"ptr=0x{address:x} mode=direct-utf16 len={len(payload) // 2} text={text!r} raw16={payload[:16].hex()}"
    if truncated:
        summary += " truncated=true"
    return {
        "text": text,
        "summary": summary,
        "mode": "direct-utf16",
        "encoding": "utf-16-le",
    }


def _decode_inline_payload(payload: bytes) -> tuple[str | None, str | None]:
    utf8_payload = payload.split(b"\x00", 1)[0]
    if utf8_payload:
        try:
            text = utf8_payload.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        if text:
            return text, "utf-8"

    utf16_end = None
    for idx in range(0, len(payload) - 1, 2):
        if payload[idx : idx + 2] == b"\x00\x00":
            utf16_end = idx
            break
    if utf16_end is None:
        utf16_payload = payload[: len(payload) - (len(payload) % 2)]
    else:
        utf16_payload = payload[:utf16_end]

    if utf16_payload:
        try:
            text = utf16_payload.decode("utf-16-le")
        except UnicodeDecodeError:
            text = None
        if text:
            return text, "utf-16-le"

    return None, None


def _decode_pascal_string(process, address: int) -> dict:
    if address <= 0x100000000:
        return {
            "text": None,
            "summary": f"ptr=0x{address:x}",
            "mode": "invalid",
            "encoding": None,
        }

    direct_utf8 = _decode_direct_utf8_string(process, address)
    if direct_utf8 is not None:
        return direct_utf8

    direct_utf16 = _decode_direct_utf16_string(process, address)
    if direct_utf16 is not None:
        return direct_utf16

    raw = _read_bytes(process, address, 16)
    if raw is None or len(raw) != 16:
        return {
            "text": None,
            "summary": f"ptr=0x{address:x} read-fail",
            "mode": "read-fail",
            "encoding": None,
        }

    length = int.from_bytes(raw[0:4], "little", signed=False)
    w9_flag = int.from_bytes(raw[4:8], "little", signed=False)
    inline = raw[8:16]
    external_ptr = None
    payload = b""
    truncated = False
    mode = "pascal-inline"

    if 0 < length <= 0x10000:
        if w9_flag < 2:
            payload = inline[: min(length, len(inline))]
            truncated = length > len(inline)
        else:
            external_ptr = int.from_bytes(inline, "little", signed=False)
            if 0x100000000 < external_ptr < 0x200000000000:
                read_len = min(length, 512)
                payload = _read_bytes(process, external_ptr, read_len) or b""
                truncated = length > read_len
                mode = "pascal-external"

    text, encoding = _decode_inline_payload(payload)
    summary = f"ptr=0x{address:x} mode={mode} len={length} w9={w9_flag} text={text!r} raw={raw.hex()}"
    if external_ptr is not None:
        summary += f" ext=0x{external_ptr:x}"
    if truncated:
        summary += " truncated=true"
    return {
        "text": text,
        "summary": summary,
        "mode": mode,
        "encoding": encoding,
    }


def _short_backtrace(thread, limit: int = 6) -> str:
    frames = []
    for index in range(min(limit, thread.GetNumFrames())):
        frame = thread.GetFrameAtIndex(index)
        frames.append(f"#{index} 0x{frame.GetPC():x}")
    return " ".join(frames)


def materializer_entry_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    thread_id = int(thread.GetThreadID())
    slide = _resolve_ngr_slide(target)

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x30 = _reg_u64(frame, "x30")
    x1_decoded = _decode_pascal_string(process, x1)

    record = {
        "kind": "materializer",
        "call_id": len(_records) + 1,
        "thread_id": thread_id,
        "phase": "entry",
        "pc": frame.GetPC(),
        "slide": slide,
        "materializer_unslid": _MATERIALIZE_ENTRY_UNSLID,
        "entry_x0": x0,
        "entry_x1": x1,
        "entry_x1_text": x1_decoded.get("text"),
        "entry_x1_summary": x1_decoded.get("summary"),
        "entry_x1_mode": x1_decoded.get("mode"),
        "entry_x1_encoding": x1_decoded.get("encoding"),
        "entry_x2": x2,
        "entry_x3": x3,
        "entry_lr": x30,
        "backtrace": _short_backtrace(thread),
    }
    _records.append(record)
    _thread_materializer_map[thread_id] = record

    _log(
        f"[ripc-010a-materializer-entry] call={record['call_id']} pc=0x{frame.GetPC():x} x1=0x{x1:x} text={x1_decoded.get('text')!r} mode={x1_decoded.get('mode')} lr=0x{x30:x} bt={record['backtrace']}"
    )
    _save_results()
    return False


def materializer_return_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    thread_id = int(thread.GetThreadID())
    x0 = _reg_u64(frame, "x0")
    x30 = _reg_u64(frame, "x30")

    record = _thread_materializer_map.pop(thread_id, None)
    if record is None:
        record = {
            "kind": "materializer",
            "call_id": len(_records) + 1,
            "thread_id": thread_id,
            "phase": "return_orphaned",
            "pc": frame.GetPC(),
            "return_x0": x0,
            "return_lr": x30,
        }
        _records.append(record)
    else:
        record["phase"] = "complete"
        record["return_x0"] = x0
        record["return_lr"] = x30

    _log(
        f"[ripc-010a-materializer-return] call={record.get('call_id', '?')} pc=0x{frame.GetPC():x} x0=0x{x0:x} lr=0x{x30:x}"
    )
    _save_results()
    return False


def vcall_precall_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    thread_id = int(thread.GetThreadID())

    sp = _reg_u64(frame, "sp")
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x8 = _reg_u64(frame, "x8")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")

    helper_vtable = _read_u64(process, x19) if x19 > 0x100000000 else None
    helper_slot10 = _read_u64(process, x19 + 0x10) if x19 > 0x100000000 else None
    helper_slot18 = _read_u64(process, x19 + 0x18) if x19 > 0x100000000 else None
    helper_slot28 = _read_u64(process, x19 + 0x28) if x19 > 0x100000000 else None
    x1_decoded = _decode_pascal_string(process, x1)

    record = {
        "kind": "vcall",
        "call_id": len(_records) + 1,
        "thread_id": thread_id,
        "phase": "precall",
        "pc": frame.GetPC(),
        "vcall_precall_unslid": _VCALL_PRECALL_UNSLID,
        "sp": sp,
        "x0": x0,
        "x1": x1,
        "x1_text": x1_decoded.get("text"),
        "x1_summary": x1_decoded.get("summary"),
        "x1_mode": x1_decoded.get("mode"),
        "x1_encoding": x1_decoded.get("encoding"),
        "x8_target": x8,
        "x19_helper": x19,
        "x20_err_slot": x20,
        "x21_saved_arg": x21,
        "x22_saved_obj": x22,
        "lr": x30,
        "helper_vtable": helper_vtable,
        "helper_slot10": helper_slot10,
        "helper_slot18": helper_slot18,
        "helper_slot28": helper_slot28,
        "backtrace": _short_backtrace(thread),
    }
    _records.append(record)
    _thread_vcall_map[thread_id] = record

    _log(
        f"[ripc-010a-vcall-precall] call={record['call_id']} pc=0x{frame.GetPC():x} x8(target)=0x{x8:x} x1=0x{x1:x} text={x1_decoded.get('text')!r} mode={x1_decoded.get('mode')} x19=0x{x19:x} x20=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} lr=0x{x30:x} bt={record['backtrace']}"
    )
    _save_results()
    return False


def vcall_return_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    thread_id = int(thread.GetThreadID())
    x0 = _reg_u64(frame, "x0")
    x21 = _reg_u64(frame, "x21")
    x30 = _reg_u64(frame, "x30")

    record = _thread_vcall_map.pop(thread_id, None)
    if record is None:
        record = {
            "kind": "vcall",
            "call_id": len(_records) + 1,
            "thread_id": thread_id,
            "phase": "return_orphaned",
            "pc": frame.GetPC(),
            "return_x0": x0,
            "return_x21": x21,
            "return_lr": x30,
        }
        _records.append(record)
    else:
        record["phase"] = "complete"
        record["return_x0"] = x0
        record["return_x21"] = x21
        record["return_lr"] = x30

    _log(
        f"[ripc-010a-vcall-return] call={record.get('call_id', '?')} pc=0x{frame.GetPC():x} x0=0x{x0:x} x21=0x{x21:x} lr=0x{x30:x}"
    )
    _save_results()
    return False


def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        _log("[ripc-010a] ERROR: no valid target selected")
        return

    slide = _resolve_ngr_slide(target)
    if slide is None:
        _log("[ripc-010a] WARNING: could not resolve NGR slide yet")
    else:
        _log(f"[ripc-010a] resolved NGR slide=0x{slide:x}")

    try:
        _LOG_PATH.unlink(missing_ok=True)
    except Exception:
        pass

    bps = []
    for unslid, callback_name, label in [
        (_VCALL_PRECALL_UNSLID, "ripc_010a_materializer_probe.vcall_precall_hit", "vcall-precall"),
        (_VCALL_RETURN_UNSLID, "ripc_010a_materializer_probe.vcall_return_hit", "vcall-return"),
        (_MATERIALIZE_ENTRY_UNSLID, "ripc_010a_materializer_probe.materializer_entry_hit", "materializer-entry"),
        (_MATERIALIZE_RETURN_UNSLID, "ripc_010a_materializer_probe.materializer_return_hit", "materializer-return"),
    ]:
        bp = _install_module_breakpoint(debugger, target, unslid, callback_name, label)
        if bp is not None:
            bps.append((label, bp))

    _log("[ripc-010a] probe installed")
    _log(f"  log: {_LOG_PATH}")
    _log(f"  json: {_JSON_PATH}")
    for label, bp in bps:
        print(f"[ripc-010a] {label} locations={bp.GetNumLocations()}")
