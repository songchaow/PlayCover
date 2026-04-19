"""HOK-016-C.2.7 LLDB helper: trace the ``mainChunk -> \"1\"`` path.

This probe narrows the C.2.6 result set to the exact second-level
lookup and any attempted population of ``mainChunk+0x60``:

1. At ``0x10017f1dc`` (right after ``rootB[\"main\"]`` lookup returns),
   capture the returned ``mainChunk`` object and arm a dynamic 8-byte
   watchpoint on ``mainChunk+0x60``.
2. At ``0x1001bd448`` entry, log the incoming ``mainChunk`` / key / out
   args so we can see which caller asks for the ``\"1\"`` child.
3. At ``0x1001ba82c`` entry, log the second-level lookup directly,
   including caller LR/backtrace and the current subtree root.
4. On any write to ``mainChunk+0x60``, dump the writer PC/registers and a
   short backtrace.

All callbacks are read-only; they only read process memory and print
structured transcript lines prefixed with ``[hok016c27-*]``.
"""

from __future__ import annotations

_NGR_TEXT_BASE_UNSLID = 0x100000000
_ROOTB_UNSLID = 0x10E184B18

_tracked_mainchunk_addr = 0
_subtree_watch_installed = False
_subtree_watch_addr = 0
_slot1_watch_installed = False
_slot1_watch_addr = 0
_entry_slot_watch_installed = False
_entry_slot0_addr = 0
_entry_slot1_addr = 0


def _resolve_ngr_slide(target):
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
                    return int(slid) - _NGR_TEXT_BASE_UNSLID
    return None


def _read_bytes(process, address, size):
    try:
        import lldb  # type: ignore
    except ImportError:
        return None

    err = lldb.SBError()
    raw = process.ReadMemory(int(address), int(size), err)
    if err.Fail() or raw is None:
        return None
    if not isinstance(raw, (bytes, bytearray)):
        raw = raw.encode("latin-1")
    return bytes(raw)


def _read_u64(process, address):
    raw = _read_bytes(process, address, 8)
    if raw is None or len(raw) != 8:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _read_u32(process, address):
    raw = _read_bytes(process, address, 4)
    if raw is None or len(raw) != 4:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _normalize_ngr_ptr(raw):
    if raw is None:
        return None
    low32 = raw & 0xFFFFFFFF
    if low32:
        return _NGR_TEXT_BASE_UNSLID + low32
    return raw


def _run_lldb_command(debugger, command):
    try:
        import lldb  # type: ignore
    except ImportError:
        return False, "lldb import failed"

    result = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(command, result)
    output = result.GetOutput() or ""
    error = result.GetError() or ""
    return result.Succeeded(), (output or error).strip()


def _hex_dump(data):
    if data is None:
        return "<read fail>"
    return " ".join(f"{byte:02x}" for byte in data)


def _reg_u64(frame, name):
    reg = frame.FindRegister(name)
    if not reg or not reg.IsValid():
        return 0
    try:
        return int(reg.GetValue(), 0)
    except (TypeError, ValueError):
        return 0


def _decode_pascal_string(process, address):
    if address <= 0x100000000:
        return {"text": None, "summary": f"ptr=0x{address:x}"}

    raw = _read_bytes(process, address, 16)
    if raw is None or len(raw) != 16:
        return {"text": None, "summary": f"ptr=0x{address:x} read-fail"}

    length = int.from_bytes(raw[0:4], "little", signed=False)
    w9_flag = int.from_bytes(raw[4:8], "little", signed=False)
    inline = raw[8:16]
    external_ptr = None
    payload = b""
    truncated = False

    if length > 0:
        if w9_flag < 2:
            payload = inline[: min(length, len(inline))]
            truncated = length > len(inline)
        else:
            external_ptr = int.from_bytes(inline, "little", signed=False)
            if 0x100000000 < external_ptr < 0x200000000000:
                read_len = min(length, 64)
                payload = _read_bytes(process, external_ptr, read_len) or b""
                truncated = length > read_len

    try:
        text = payload.split(b"\x00", 1)[0].decode("ascii", errors="replace")
    except Exception:
        text = None

    summary = (
        f"ptr=0x{address:x} len={length} w9={w9_flag} "
        f"text={text!r} raw={raw.hex()}"
    )
    if external_ptr is not None:
        summary += f" ext=0x{external_ptr:x}"
    if truncated:
        summary += " truncated=true"
    return {"text": text, "summary": summary}


def _short_backtrace(thread, limit=8):
    frames = []
    for index in range(min(limit, thread.GetNumFrames())):
        frame = thread.GetFrameAtIndex(index)
        frames.append(f"#{index} 0x{frame.GetPC():x}")
    return " ".join(frames)


def _runtime_rootb_addr(target):
    slide = _resolve_ngr_slide(target)
    if slide is None:
        return None
    return _ROOTB_UNSLID + slide


def _tracked_chunk_extra(process, chunk_addr):
    if chunk_addr <= 0x100000000:
        return ""
    subtree = _read_u64(process, chunk_addr + 0x60)
    tail = _read_bytes(process, chunk_addr + 0xE0, 16)
    return (
        f" mainChunk+0x60=0x{(subtree or 0):x}"
        f" mainChunk+0xe0[16]={_hex_dump(tail)}"
    )


def _object_contract_extra(process, obj_addr, label):
    if obj_addr <= 0x100000000:
        return ""
    field40 = _read_u32(process, obj_addr + 0x40)
    field44 = _read_u32(process, obj_addr + 0x44)
    field48 = _read_u32(process, obj_addr + 0x48)
    field50 = _read_u32(process, obj_addr + 0x50)
    field60 = _read_u64(process, obj_addr + 0x60)
    return (
        f" {label}+0x40=0x{(field40 or 0):x}"
        f" {label}+0x44=0x{(field44 or 0):x}"
        f" {label}+0x48=0x{(field48 or 0):x}"
        f" {label}+0x50=0x{(field50 or 0):x}"
        f" {label}+0x60=0x{(field60 or 0):x}"
    )


def snapshot_rootb_lookup_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    rootb_addr = _runtime_rootb_addr(target)
    x0 = _reg_u64(frame, "x0")
    if rootb_addr is None or x0 != rootb_addr:
        return False

    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x1)
    header = _read_bytes(process, rootb_addr, 32)

    print(
        f"[hok016c27-rootb] pc=0x{frame.GetPC():x} x0(root)=0x{x0:x} "
        f"x1(key)=0x{x1:x} x2=0x{x2:x} x30(lr)=0x{x30:x} "
        f"key=[{key['summary']}] rootB_header32={_hex_dump(header)} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_mainchunk_on_hit(frame, bp_loc, internal_dict):
    global _tracked_mainchunk_addr
    global _subtree_watch_installed
    global _subtree_watch_addr

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    mainchunk = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    sp = _reg_u64(frame, "sp")
    stack_preview = _hex_dump(_read_bytes(process, sp, 0x40)) if sp else "<no-sp>"

    extra = ""
    if mainchunk > 0x100000000:
        _tracked_mainchunk_addr = mainchunk
        extra += _tracked_chunk_extra(process, mainchunk)
        subtree_addr = mainchunk + 0x60
        if not _subtree_watch_installed:
            try:
                import lldb  # type: ignore

                err = lldb.SBError()
                wp = target.WatchAddress(subtree_addr, 8, False, True, err)
                if not err.Fail() and wp and wp.IsValid():
                    _subtree_watch_installed = True
                    _subtree_watch_addr = subtree_addr
                    extra += f" subtree-wp=id{wp.GetID()}@0x{subtree_addr:x}"
                else:
                    extra += f" subtree-wp-install-failed={err.GetCString()!r}"
            except Exception as exc:
                extra += f" subtree-wp-exc={exc!r}"

    print(
        f"[hok016c27-mainchunk] pc=0x{frame.GetPC():x} x0(mainChunk)=0x{mainchunk:x} "
        f"x19=0x{x19:x} sp=0x{sp:x} stack40={stack_preview}{extra} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_mainchunk_no_watch_on_hit(frame, bp_loc, internal_dict):
    global _tracked_mainchunk_addr

    thread = frame.GetThread()
    process = thread.GetProcess()

    mainchunk = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    sp = _reg_u64(frame, "sp")
    stack_preview = _hex_dump(_read_bytes(process, sp, 0x40)) if sp else "<no-sp>"

    extra = ""
    if mainchunk > 0x100000000:
        _tracked_mainchunk_addr = mainchunk
        extra += _tracked_chunk_extra(process, mainchunk)
        extra += " subtree-wp=skipped"

    print(
        f"[hok016c27-mainchunk-nowp] pc=0x{frame.GetPC():x} x0(mainChunk)=0x{mainchunk:x} "
        f"x19=0x{x19:x} sp=0x{sp:x} stack40={stack_preview}{extra} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bd448_entry_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    if _tracked_mainchunk_addr and x0 != _tracked_mainchunk_addr:
        return False

    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x1)

    print(
        f"[hok016c27-bd448] pc=0x{frame.GetPC():x} x0(mainChunk)=0x{x0:x} "
        f"x1(key)=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} x30(lr)=0x{x30:x} "
        f"key=[{key['summary']}]"
        f"{_tracked_chunk_extra(process, x0)} bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_lookup2_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x1)
    tracked = _tracked_mainchunk_addr != 0 and x0 == _tracked_mainchunk_addr

    print(
        f"[hok016c27-lookup2] pc=0x{frame.GetPC():x} x0(mainChunk)=0x{x0:x} "
        f"x1(key)=0x{x1:x} x30(lr)=0x{x30:x} tracked={str(tracked).lower()} key=[{key['summary']}]"
        f"{_tracked_chunk_extra(process, x0)} bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_subtree_watch_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    frame0 = thread.GetFrameAtIndex(0)

    x0 = _reg_u64(frame0, "x0")
    x1 = _reg_u64(frame0, "x1")
    x2 = _reg_u64(frame0, "x2")
    x3 = _reg_u64(frame0, "x3")
    x30 = _reg_u64(frame0, "x30")
    new_value = _read_u64(process, _subtree_watch_addr) if _subtree_watch_addr else None

    print(
        f"[hok016c27-subtree-write] pc=0x{frame0.GetPC():x} x0=0x{x0:x} "
        f"x1=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} x30(lr)=0x{x30:x} "
        f"watched=0x{_subtree_watch_addr:x} value=0x{(new_value or 0):x} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_postcall_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x30 = _reg_u64(frame, "x30")
    sp = _reg_u64(frame, "sp")
    stack_preview = _hex_dump(_read_bytes(process, sp, 0x40)) if sp else "<no-sp>"

    print(
        f"[hok016c27-post] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} "
        f"x20=0x{x20:x} x30(lr)=0x{x30:x} sp=0x{sp:x} stack40={stack_preview}"
        + (
            _tracked_chunk_extra(process, _tracked_mainchunk_addr)
            if _tracked_mainchunk_addr
            else ""
        )
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba50c_entry_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x4 = _reg_u64(frame, "x4")
    x30 = _reg_u64(frame, "x30")
    key1 = _decode_pascal_string(process, x1)
    key2 = _decode_pascal_string(process, x2)
    tracked = _tracked_mainchunk_addr != 0 and x0 == _tracked_mainchunk_addr

    print(
        f"[hok016c27-ba50c-entry] pc=0x{frame.GetPC():x} x0=0x{x0:x} "
        f"x1=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} x4=0x{x4:x} x30(lr)=0x{x30:x} "
        f"tracked={str(tracked).lower()} key1=[{key1['summary']}] key2=[{key2['summary']}]"
        f"{_tracked_chunk_extra(process, x0)} bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba50c_return_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x27 = _reg_u64(frame, "x27")
    x30 = _reg_u64(frame, "x30")
    extra = ""
    if x0 > 0x100000000:
        field_dump = _read_bytes(process, x0 + 0x40, 0x60)
        extra = (
            f" ret+0x40[96]={_hex_dump(field_dump)}"
            f" ret+0x60=0x{(_read_u64(process, x0 + 0x60) or 0):x}"
        )
        extra += _object_contract_extra(process, x0, "ret")

    print(
        f"[hok016c27-ba50c-return] pc=0x{frame.GetPC():x} x0(ret)=0x{x0:x} "
        f"x27=0x{x27:x} x30(lr)=0x{x30:x}{extra} bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bd464_after_a5014_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x24 = _reg_u64(frame, "x24")
    x27 = _reg_u64(frame, "x27")
    x30 = _reg_u64(frame, "x30")
    extra = ""
    if x24 > 0x100000000:
        extra += _object_contract_extra(process, x24, "x24")
    if x27 > 0x100000000:
        extra += _object_contract_extra(process, x27, "x27")

    print(
        f"[hok016c27-a5014-post] pc=0x{frame.GetPC():x} x0=0x{x0:x} "
        f"x24=0x{x24:x} x27=0x{x27:x} x30(lr)=0x{x30:x}{extra} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_a5014_precheck_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x26 = _reg_u64(frame, "x26")
    x30 = _reg_u64(frame, "x30")
    path = _decode_pascal_string(process, x26)
    key = _decode_pascal_string(process, x19)
    extra = ""
    if x21 > 0x100000000:
        extra += f" newObj+0xa8=0x{(_read_u64(process, x21 + 0xA8) or 0):x}"
        extra += f" newObj+0xb0=0x{(_read_u64(process, x21 + 0xB0) or 0):x}"
        extra += _object_contract_extra(process, x21, "newObj")

    print(
        f"[hok016c27-a5014-precheck] pc=0x{frame.GetPC():x} w0=0x{x0:x} "
        f"x21(newObj)=0x{x21:x} x22(builder+0x60)=0x{x22:x} x23=0x{x23:x} "
        f"x20=0x{x20:x} x30(lr)=0x{x30:x} path=[{path['summary']}] key=[{key['summary']}]"
        f"{extra} bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_a5014_db_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x21 = _reg_u64(frame, "x21")
    x24 = _reg_u64(frame, "x24")
    x25 = _reg_u64(frame, "x25")
    x30 = _reg_u64(frame, "x30")
    error_code = _read_u32(process, x24) if x24 > 0x100000000 else None

    print(
        f"[hok016c27-a5014-db] pc=0x{frame.GetPC():x} x0(db)=0x{x0:x} "
        f"x21(newObj)=0x{x21:x} x24(dbErr)=0x{x24:x} err=0x{(error_code or 0):x} "
        f"x25(existing)=0x{x25:x} x30(lr)=0x{x30:x}"
        f" newObj+0xa8=0x{(_read_u64(process, x21 + 0xA8) or 0):x}"
        f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_a5014_storage_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")
    extra = ""
    if x21 > 0x100000000:
        extra += f" newObj+0xa8=0x{(_read_u64(process, x21 + 0xA8) or 0):x}"
        extra += f" newObj+0xb0=0x{(_read_u64(process, x21 + 0xB0) or 0):x}"
        extra += _object_contract_extra(process, x21, "newObj")
    if x24 > 0x100000000:
        vtable = _read_u64(process, x24)
        slot18 = _read_u64(process, (vtable or 0) + 0x18) if vtable else None
        extra += f" storage+0x0=0x{(vtable or 0):x}"
        extra += f" storage.slot18=0x{(slot18 or 0):x}"
        normalized = _normalize_ngr_ptr(slot18)
        if normalized is not None:
            extra += f" storage.slot18.norm=0x{normalized:x}"

    print(
        f"[hok016c27-a5014-storage] pc=0x{frame.GetPC():x} w0=0x{x0:x} "
        f"x21(newObj)=0x{x21:x} x24(storage)=0x{x24:x} x22(builder+0x60)=0x{x22:x} "
        f"x23=0x{x23:x} x20=0x{x20:x} x30(lr)=0x{x30:x}{extra} "
        f"bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_storage_after_create_table_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x20)
    error_code = _read_u32(process, x19 + 0x30) if x19 > 0x100000000 else None
    state_flags = _read_u32(process, x19 + 0x3C) if x19 > 0x100000000 else None

    print(
        f"[hok016c27-storage-table] pc=0x{frame.GetPC():x} x0(table)=0x{x0:x} "
        f"x19(storage)=0x{x19:x} x21(limit)=0x{x21:x} x30(lr)=0x{x30:x} "
        f"storage+0x30(err)=0x{(error_code or 0):x} storage+0x3c(flags)=0x{(state_flags or 0):x} "
        f"key=[{key['summary']}] bt={_short_backtrace(thread)}"
    )
    return False


def force_storage_success_on_hit(frame, bp_loc, internal_dict):
    import lldb  # type: ignore

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    debugger = target.GetDebugger()

    old_x0 = _reg_u64(frame, "x0")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")

    extra = ""
    if x21 > 0x100000000:
        extra += _object_contract_extra(process, x21, "newObj")
        extra += f" newObj+0xa8=0x{(_read_u64(process, x21 + 0xA8) or 0):x}"
        extra += f" newObj+0xb0=0x{(_read_u64(process, x21 + 0xB0) or 0):x}"
    if x24 > 0x100000000:
        vtable = _read_u64(process, x24)
        slot18 = _read_u64(process, (vtable or 0) + 0x18) if vtable else None
        normalized = _normalize_ngr_ptr(slot18)
        extra += f" storage=0x{x24:x} storage.err=0x{(_read_u32(process, x24 + 0x30) or 0):x}"
        extra += f" storage.vtable=0x{(vtable or 0):x}"
        extra += f" storage.slot18=0x{(slot18 or 0):x}"
        if normalized is not None:
            extra += f" storage.slot18.norm=0x{normalized:x}"

    reg_x0 = frame.FindRegister("x0")
    error = lldb.SBError()
    ok = bool(reg_x0 and reg_x0.IsValid() and reg_x0.SetValueFromCString("0x1", error))
    if not ok:
        fallback_ok, fallback_message = _run_lldb_command(debugger, "register write x0 0x1")
        ok = fallback_ok
        message = fallback_message
    else:
        message = error.GetCString() or ""

    forced_x0 = _reg_u64(frame, "x0")
    status = "ok" if ok else "failed"
    if message:
        message = message.replace("\n", " ")

    print(
        f"[hok016c4-force-storage] pc=0x{frame.GetPC():x} oldX0=0x{old_x0:x} "
        f"forcedX0=0x{forced_x0:x} status={status} x21=0x{x21:x} x22=0x{x22:x} "
        f"x24=0x{x24:x} x30(lr)=0x{x30:x}{extra}"
        + (f" cmd={message}" if message else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def force_ready_to_use_success_on_hit(frame, bp_loc, internal_dict):
    import lldb  # type: ignore

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    debugger = target.GetDebugger()

    old_x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x30 = _reg_u64(frame, "x30")
    extra = _object_contract_extra(process, x20, "pkg") if x20 > 0x100000000 else ""

    reg_x0 = frame.FindRegister("x0")
    error = lldb.SBError()
    ok = bool(reg_x0 and reg_x0.IsValid() and reg_x0.SetValueFromCString("0x1", error))
    if not ok:
        fallback_ok, fallback_message = _run_lldb_command(debugger, "register write x0 0x1")
        ok = fallback_ok
        message = fallback_message
    else:
        message = error.GetCString() or ""

    forced_x0 = _reg_u64(frame, "x0")
    status = "ok" if ok else "failed"
    if message:
        message = message.replace("\n", " ")

    print(
        f"[hok016c4-force-ready] pc=0x{frame.GetPC():x} oldX0=0x{old_x0:x} "
        f"forcedX0=0x{forced_x0:x} status={status} x19=0x{x19:x} x20(pkg)=0x{x20:x} "
        f"x30(lr)=0x{x30:x}{extra}"
        + (f" cmd={message}" if message else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bd464_after_ready_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x24 = _reg_u64(frame, "x24")
    x26 = _reg_u64(frame, "x26")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c4-ready-post] pc=0x{frame.GetPC():x} x0=0x{x0:x} x24(pkg)=0x{x24:x} "
        f"x26=0x{x26:x} x30(lr)=0x{x30:x}"
        + (_object_contract_extra(process, x24, "pkg") if x24 > 0x100000000 else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_dormant_branch_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-dormant-branch] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} "
        f"x20=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_f3c8_post_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-f3c8-post] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} "
        f"x20=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} x23=0x{x23:x} x24=0x{x24:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bc220_stage_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-bc220] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} x20=0x{x20:x} "
        f"x21=0x{x21:x} x22=0x{x22:x} x23=0x{x23:x} x24=0x{x24:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bc220_slot1_source_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    entry_slot0 = _read_u64(process, x21) if x21 > 0x100000000 else None
    entry_slot1 = _read_u64(process, x21 + 0x8) if x21 > 0x100000000 else None

    print(
        f"[hok016c27-bc220-slot1-src] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x21(entry)=0x{x21:x} "
        f"x22=0x{x22:x} x24(src)=0x{x24:x} x30(lr)=0x{x30:x} "
        f"ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"entry.slot0=0x{(entry_slot0 or 0):x} entry.slot1=0x{(entry_slot1 or 0):x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_override_alloc_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    ctx40_dump = _hex_dump(_read_bytes(process, ctx40, 0x20)) if ctx40 and ctx40 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-ba940-override-alloc] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x21=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"ctx40raw={ctx40_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_override_alloc_post_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x30 = _reg_u64(frame, "x30")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    ctx40_dump = _hex_dump(_read_bytes(process, ctx40, 0x20)) if ctx40 and ctx40 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-ba940-override-alloc-post] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x21(new)=0x{x21:x} "
        f"x30(lr)=0x{x30:x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"ctx40==x21={str(bool(ctx40 and x21 and ctx40 == x21)).lower()} ctx40raw={ctx40_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_override_result_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    sp = _reg_u64(frame, "sp")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctx40_dump = _hex_dump(_read_bytes(process, ctx40, 0x20)) if ctx40 and ctx40 > 0x100000000 else "<nil>"
    sp3c = _read_u32(process, sp + 0x3C) if sp else None

    print(
        f"[hok016c27-ba940-override-ret] pc=0x{frame.GetPC():x} x0=0x{x0:x} w0=0x{(x0 & 0xffffffff):x} "
        f"x19(ctx)=0x{x19:x} x20=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x} "
        f"ctx+0x40=0x{(ctx40 or 0):x} sp+0x3c=0x{(sp3c or 0):x} ctx40raw={ctx40_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_a53dc_gate_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    pc = frame.GetPC()
    label = "step1" if pc == 0x1001A55B8 else "step2"
    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    input_w3 = _read_u32(process, x20) if x20 > 0x100000000 else None
    input_w4 = _read_u32(process, x20 + 0x4) if x20 > 0x100000000 else None
    input_x5 = _read_u64(process, x20 + 0x8) if x20 > 0x100000000 else None
    pkg_a8 = _read_u64(process, x19 + 0xA8) if x19 > 0x100000000 else None
    pkg_b0 = _read_u64(process, x19 + 0xB0) if x19 > 0x100000000 else None
    pkg_110 = _read_u32(process, x19 + 0x110) if x19 > 0x100000000 else None

    print(
        f"[hok016c27-a53dc-{label}] pc=0x{pc:x} x0=0x{x0:x} w0=0x{(x0 & 0xffffffff):x} "
        f"x19(pkg)=0x{x19:x} x20(args)=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x} "
        f"in.w3=0x{(input_w3 or 0):x} in.w4=0x{(input_w4 or 0):x} in.x5=0x{(input_x5 or 0):x} "
        f"pkg+0xa8=0x{(pkg_a8 or 0):x} pkg+0xb0=0x{(pkg_b0 or 0):x} pkg+0x110=0x{(pkg_110 or 0):x}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_second_override_call_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x5 = _reg_u64(frame, "x5")
    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx38 = _read_u64(process, x19 + 0x38) if x19 > 0x100000000 else None
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    key = _decode_pascal_string(process, x2)

    print(
        f"[hok016c27-ba940-second-call] pc=0x{frame.GetPC():x} x0=0x{x0:x} x1=0x{x1:x} x2=0x{x2:x} "
        f"x3=0x{x3:x} x5=0x{x5:x} x19(ctx)=0x{x19:x} x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x} "
        f"ctx+0x38=0x{(ctx38 or 0):x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"key=[{key['summary']}]"
        + (_object_contract_extra(process, x0, "x0") if x0 > 0x100000000 else "")
        + (_object_contract_extra(process, x5, "x5") if x5 > 0x100000000 else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_second_override_result_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx38 = _read_u64(process, x19 + 0x38) if x19 > 0x100000000 else None
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    key = _decode_pascal_string(process, x20)

    print(
        f"[hok016c27-ba940-second-ret] pc=0x{frame.GetPC():x} x0=0x{x0:x} w0=0x{(x0 & 0xffffffff):x} "
        f"x19(ctx)=0x{x19:x} x20=0x{x20:x} x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x} "
        f"ctx+0x38=0x{(ctx38 or 0):x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"key=[{key['summary']}]"
        + (_object_contract_extra(process, x21, "x21") if x21 > 0x100000000 else "")
        + (_object_contract_extra(process, x22, "x22") if x22 > 0x100000000 else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_ctx38_check_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx38 = _read_u64(process, x19 + 0x38) if x19 > 0x100000000 else None
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    key = _decode_pascal_string(process, x20)

    print(
        f"[hok016c27-ba940-ctx38] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x20=0x{x20:x} x21=0x{x21:x} "
        f"x22(ctx+0x38)=0x{x22:x} x30(lr)=0x{x30:x} ctx+0x38=0x{(ctx38 or 0):x} ctx+0x40=0x{(ctx40 or 0):x} "
        f"key=[{key['summary']}]"
        + (_object_contract_extra(process, x21, "x21") if x21 > 0x100000000 else "")
        + (_object_contract_extra(process, x22, "x22") if x22 > 0x100000000 else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_second_fail_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    sp = _reg_u64(frame, "sp")
    local_2c = _read_u32(process, sp + 0x2C) if sp else None
    local_30 = _read_u64(process, sp + 0x30) if sp else None
    ctx38 = _read_u64(process, x19 + 0x38) if x19 > 0x100000000 else None
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    key = _decode_pascal_string(process, x20)

    print(
        f"[hok016c27-ba940-second-fail] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x20=0x{x20:x} x21=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x} sp+0x2c=0x{(local_2c or 0):x} sp+0x30=0x{(local_30 or 0):x} "
        f"ctx+0x38=0x{(ctx38 or 0):x} ctx+0x40=0x{(ctx40 or 0):x} key=[{key['summary']}]"
        + (_object_contract_extra(process, x21, "x21") if x21 > 0x100000000 else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bb73c_entry_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x1)
    arg0_dump = _hex_dump(_read_bytes(process, x0, 0x20)) if x0 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-bb73c-entry] pc=0x{frame.GetPC():x} x0=0x{x0:x} x1=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} "
        f"w3=0x{(x3 & 0xffffffff):x} x30(lr)=0x{x30:x} x1Decoded=[{key['summary']}] arg0raw={arg0_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_wrapper_return_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ret_dump = _hex_dump(_read_bytes(process, x0, 0x40)) if x0 > 0x100000000 else "<nil>"
    ret_plus28 = _hex_dump(_read_bytes(process, x0 + 0x28, 0x20)) if x0 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-ba940-wrapper-ret] pc=0x{frame.GetPC():x} x0(ret)=0x{x0:x} x19(ctx)=0x{x19:x} x20=0x{x20:x} "
        f"x21=0x{x21:x} x22=0x{x22:x} x30(lr)=0x{x30:x}{_object_contract_extra(process, x0, 'ret') if x0 > 0x100000000 else ''} "
        f"retRaw40={ret_dump} ret+0x28[32]={ret_plus28}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_c5a38_pair_write_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x30 = _reg_u64(frame, "x30")
    if x30 != 0x1001BAFF8:
        return False

    pair0 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    pair1 = _read_u64(process, x19 + 0x48) if x19 > 0x100000000 else None
    pair_dump = _hex_dump(_read_bytes(process, x19 + 0x40, 0x20)) if x19 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-c5a38-pair] pc=0x{frame.GetPC():x} x19(obj)=0x{x19:x} x20(src)=0x{x20:x} x30(lr)=0x{x30:x} "
        f"pair0=0x{(pair0 or 0):x} pair1=0x{(pair1 or 0):x} pairRaw={pair_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bb844_entry_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x30 = _reg_u64(frame, "x30")
    wrapper_dump = _hex_dump(_read_bytes(process, x0, 0x40)) if x0 > 0x100000000 else "<nil>"
    entry_slot0 = _read_u64(process, x1) if x1 > 0x100000000 else None
    entry_slot1 = _read_u64(process, x1 + 0x8) if x1 > 0x100000000 else None

    print(
        f"[hok016c27-bb844-entry] pc=0x{frame.GetPC():x} x0(wrapper)=0x{x0:x} x1(entry)=0x{x1:x} x30(lr)=0x{x30:x} "
        f"entry.slot0=0x{(entry_slot0 or 0):x} entry.slot1=0x{(entry_slot1 or 0):x} wrapperRaw40={wrapper_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_override_slot_write_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    slot0 = _read_u64(process, ctxA0) if ctxA0 and ctxA0 > 0x100000000 else None
    slot1 = _read_u64(process, ctxA0 + 0x8) if ctxA0 and ctxA0 > 0x100000000 else None
    ctx40_dump = _hex_dump(_read_bytes(process, ctx40, 0x20)) if ctx40 and ctx40 > 0x100000000 else "<nil>"
    x22_dump = _hex_dump(_read_bytes(process, x22, 0x20)) if x22 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-ba940-override-slot] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x21=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"ctx40==x22={str(bool(ctx40 and x22 and ctx40 == x22)).lower()} "
        f"target.slot0=0x{(slot0 or 0):x} target.slot1=0x{(slot1 or 0):x} "
        f"ctx40raw={ctx40_dump} x22raw={x22_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba940_override_slot_post_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None
    slot0 = _read_u64(process, ctxA0) if ctxA0 and ctxA0 > 0x100000000 else None
    slot1 = _read_u64(process, ctxA0 + 0x8) if ctxA0 and ctxA0 > 0x100000000 else None
    ctx40_dump = _hex_dump(_read_bytes(process, ctx40, 0x20)) if ctx40 and ctx40 > 0x100000000 else "<nil>"
    x22_dump = _hex_dump(_read_bytes(process, x22, 0x20)) if x22 > 0x100000000 else "<nil>"
    slot1_dump = _hex_dump(_read_bytes(process, slot1, 0x20)) if slot1 and slot1 > 0x100000000 else "<nil>"

    print(
        f"[hok016c27-ba940-override-slot-post] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x21=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x} ctx+0x40=0x{(ctx40 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"ctx40==x22={str(bool(ctx40 and x22 and ctx40 == x22)).lower()} "
        f"slot1==x22={str(bool(slot1 and x22 and slot1 == x22)).lower()} "
        f"target.slot0=0x{(slot0 or 0):x} target.slot1=0x{(slot1 or 0):x} "
        f"ctx40raw={ctx40_dump} x22raw={x22_dump} slot1raw={slot1_dump}"
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_bc970_stage_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-bc970] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} x20=0x{x20:x} "
        f"x21=0x{x21:x} x22=0x{x22:x} x23=0x{x23:x} x24=0x{x24:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba720_lookup_ret_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x21 = _reg_u64(frame, "x21")
    x30 = _reg_u64(frame, "x30")
    key = _decode_pascal_string(process, x21)
    ctx0 = _read_u64(process, x19) if x19 > 0x100000000 else None
    ctx18 = _read_u64(process, x19 + 0x18) if x19 > 0x100000000 else None

    print(
        f"[hok016c27-ba720-lookup] pc=0x{frame.GetPC():x} x0(lookupRet)=0x{x0:x} x19(ctx)=0x{x19:x} "
        f"x21(key)=0x{x21:x} x30(lr)=0x{x30:x} ctx[0]=0x{(ctx0 or 0):x} ctx+0x18=0x{(ctx18 or 0):x} "
        f"key=[{key['summary']}] bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_ba720_ctx_ready_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x19 = _reg_u64(frame, "x19")
    x30 = _reg_u64(frame, "x30")
    ctx0 = _read_u64(process, x19) if x19 > 0x100000000 else None
    ctx18 = _read_u64(process, x19 + 0x18) if x19 > 0x100000000 else None
    ctx20 = _decode_pascal_string(process, x19 + 0x20) if x19 > 0x100000000 else {"summary": "<nil>"}
    ctx28 = _decode_pascal_string(process, x19 + 0x28) if x19 > 0x100000000 else {"summary": "<nil>"}
    ctx38 = _read_u64(process, x19 + 0x38) if x19 > 0x100000000 else None
    ctx40 = _read_u64(process, x19 + 0x40) if x19 > 0x100000000 else None
    ctx98 = _read_u64(process, x19 + 0x98) if x19 > 0x100000000 else None
    ctxA0 = _read_u64(process, x19 + 0xA0) if x19 > 0x100000000 else None

    print(
        f"[hok016c27-ba720-ctx] pc=0x{frame.GetPC():x} x19(ctx)=0x{x19:x} x30(lr)=0x{x30:x} "
        f"ctx[0]=0x{(ctx0 or 0):x} ctx+0x18=0x{(ctx18 or 0):x} ctx+0x38=0x{(ctx38 or 0):x} "
        f"ctx+0x40=0x{(ctx40 or 0):x} ctx+0x98=0x{(ctx98 or 0):x} ctx+0xa0=0x{(ctxA0 or 0):x} "
        f"ctx+0x20=[{ctx20['summary']}] ctx+0x28=[{ctx28['summary']}] bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_writer_store_on_hit(frame, bp_loc, internal_dict):
    global _entry_slot_watch_installed
    global _entry_slot0_addr
    global _entry_slot1_addr

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x23 = _reg_u64(frame, "x23")
    x24 = _reg_u64(frame, "x24")
    x30 = _reg_u64(frame, "x30")
    target_matches = (
        _tracked_mainchunk_addr != 0 and x23 == (_tracked_mainchunk_addr + 0x60)
    )
    src_dump = _hex_dump(_read_bytes(process, x22, 0x40)) if x22 > 0x100000000 else "<no-src>"
    dest_before = _read_u64(process, x23) if x23 > 0x100000000 else None
    extra = ""
    if x22 > 0x100000000:
        entry_addr = _read_u64(process, x22 + 0x30)
        extra += f" src+0x30(entry)=0x{(entry_addr or 0):x}"
        if entry_addr:
            extra += f" entry.slot0=0x{(_read_u64(process, entry_addr) or 0):x}"
            extra += f" entry.slot1=0x{(_read_u64(process, entry_addr + 0x8) or 0):x}"
        if entry_addr and not _entry_slot_watch_installed:
            try:
                import lldb  # type: ignore

                debugger = target.GetDebugger()
                ci = debugger.GetCommandInterpreter()
                watch_ids = []
                for addr, label in ((entry_addr, "slot0"), (entry_addr + 0x8, "slot1")):
                    err = lldb.SBError()
                    wp = target.WatchAddress(addr, 8, False, True, err)
                    if err.Fail() or not wp or not wp.IsValid():
                        extra += f" entry-{label}-wp-failed={err.GetCString()!r}"
                        break
                    res = lldb.SBCommandReturnObject()
                    cmd = (
                        "watchpoint command add -s python -F "
                        "hok016c27_lldb_mainchunk_watch.snapshot_entry_slot_write_on_hit "
                        f"{wp.GetID()}"
                    )
                    ci.HandleCommand(cmd, res)
                    if not res.Succeeded():
                        extra += f" entry-{label}-attach-failed={res.GetError()!r}"
                        break
                    watch_ids.append(wp.GetID())
                else:
                    _entry_slot_watch_installed = True
                    _entry_slot0_addr = entry_addr
                    _entry_slot1_addr = entry_addr + 0x8
                    extra += (
                        f" entry-wp=slot0:id{watch_ids[0]}@0x{_entry_slot0_addr:x}"
                        f",slot1:id{watch_ids[1]}@0x{_entry_slot1_addr:x}"
                    )
            except Exception as exc:
                extra += f" entry-wp-exc={exc!r}"

    print(
        f"[hok016c27-writer-store] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} x20=0x{x20:x} "
        f"x21=0x{x21:x} x22(src)=0x{x22:x} x23(dst)=0x{x23:x} x24=0x{x24:x} x30(lr)=0x{x30:x} "
        f"trackedDst={str(target_matches).lower()} dstBefore=0x{(dest_before or 0):x} src40={src_dump}{extra}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_second_gate_return_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-second-gate] pc=0x{frame.GetPC():x} preX0=0x{x0:x} retX19=0x{x19:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_second_f3c8_return_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x0 = _reg_u64(frame, "x0")
    x19 = _reg_u64(frame, "x19")
    x20 = _reg_u64(frame, "x20")
    x30 = _reg_u64(frame, "x30")

    print(
        f"[hok016c27-second-f3c8] pc=0x{frame.GetPC():x} x0=0x{x0:x} x19=0x{x19:x} x20=0x{x20:x} x30(lr)=0x{x30:x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_be550_post_lookup_on_hit(frame, bp_loc, internal_dict):
    global _slot1_watch_installed
    global _slot1_watch_addr

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    x0 = _reg_u64(frame, "x0")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    extra = _object_contract_extra(process, x0, "node") if x0 > 0x100000000 else ""
    if x0 > 0x100000000:
        extra += f" node40={_hex_dump(_read_bytes(process, x0, 0x40))}"
        if x21 == 1 and not _slot1_watch_installed:
            try:
                import lldb  # type: ignore

                slot1_addr = x0 + 0x8
                err = lldb.SBError()
                wp = target.WatchAddress(slot1_addr, 8, False, True, err)
                if not err.Fail() and wp and wp.IsValid():
                    debugger = target.GetDebugger()
                    ci = debugger.GetCommandInterpreter()
                    res = lldb.SBCommandReturnObject()
                    cmd = (
                        "watchpoint command add -s python -F "
                        "hok016c27_lldb_mainchunk_watch.snapshot_slot1_write_on_hit "
                        f"{wp.GetID()}"
                    )
                    ci.HandleCommand(cmd, res)
                    if res.Succeeded():
                        _slot1_watch_installed = True
                        _slot1_watch_addr = slot1_addr
                        extra += f" slot1-wp=id{wp.GetID()}@0x{slot1_addr:x}"
                    else:
                        extra += f" slot1-wp-attach-failed={res.GetError()!r}"
                else:
                    extra += f" slot1-wp-install-failed={err.GetCString()!r}"
            except Exception as exc:
                extra += f" slot1-wp-exc={exc!r}"

    print(
        f"[hok016c27-be550-lookup] pc=0x{frame.GetPC():x} x0(node)=0x{x0:x} x21(flag)=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x}{extra}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_be550_child_pick_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()

    x20 = _reg_u64(frame, "x20")
    x21 = _reg_u64(frame, "x21")
    x22 = _reg_u64(frame, "x22")
    x30 = _reg_u64(frame, "x30")
    child0 = _read_u64(process, x20) if x20 > 0x100000000 else None
    child1 = _read_u64(process, x20 + 0x8) if x20 > 0x100000000 else None
    raw40 = _hex_dump(_read_bytes(process, x20, 0x40)) if x20 > 0x100000000 else "<no-node>"

    print(
        f"[hok016c27-be550-child] pc=0x{frame.GetPC():x} x20=0x{x20:x} x21(flag)=0x{x21:x} "
        f"x22=0x{x22:x} x30(lr)=0x{x30:x} child0=0x{(child0 or 0):x} child1=0x{(child1 or 0):x} raw40={raw40}"
        + (_object_contract_extra(process, x20, "node") if x20 > 0x100000000 else "")
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_slot1_write_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    frame0 = thread.GetFrameAtIndex(0)

    x0 = _reg_u64(frame0, "x0")
    x1 = _reg_u64(frame0, "x1")
    x2 = _reg_u64(frame0, "x2")
    x3 = _reg_u64(frame0, "x3")
    x30 = _reg_u64(frame0, "x30")
    new_value = _read_u64(process, _slot1_watch_addr) if _slot1_watch_addr else None

    print(
        f"[hok016c27-slot1-write] pc=0x{frame0.GetPC():x} x0=0x{x0:x} x1=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} "
        f"x30(lr)=0x{x30:x} watched=0x{_slot1_watch_addr:x} value=0x{(new_value or 0):x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def snapshot_entry_slot_write_on_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    frame0 = thread.GetFrameAtIndex(0)

    x0 = _reg_u64(frame0, "x0")
    x1 = _reg_u64(frame0, "x1")
    x2 = _reg_u64(frame0, "x2")
    x3 = _reg_u64(frame0, "x3")
    x30 = _reg_u64(frame0, "x30")
    slot0 = _read_u64(process, _entry_slot0_addr) if _entry_slot0_addr else None
    slot1 = _read_u64(process, _entry_slot1_addr) if _entry_slot1_addr else None

    print(
        f"[hok016c27-entry-slot-write] pc=0x{frame0.GetPC():x} x0=0x{x0:x} x1=0x{x1:x} x2=0x{x2:x} x3=0x{x3:x} "
        f"x30(lr)=0x{x30:x} slot0@0x{_entry_slot0_addr:x}=0x{(slot0 or 0):x} "
        f"slot1@0x{_entry_slot1_addr:x}=0x{(slot1 or 0):x}"
        + (_tracked_chunk_extra(process, _tracked_mainchunk_addr) if _tracked_mainchunk_addr else "")
        + f" bt={_short_backtrace(thread)}"
    )
    return False


def __lldb_init_module(debugger, internal_dict):
    print(
        "[hok016c27] loaded; use snapshot_mainchunk_on_hit / "
        "snapshot_lookup2_on_hit / snapshot_subtree_watch_on_hit callbacks."
    )
