"""HOK-016-C.2.4 LLDB helper: probe the two inner lookup bl's inside
``0x10017f3c8`` to understand what NGR's Qtsk::STGlobalMemData subsystem is
looking up on macOS right before it returns failure.

Loaded into LLDB via::

    command script import Scripts/hok016c24_lldb_inner_probes.py

Context (see ``LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md``
HOK-016-C.2.3 section):

* ``0x10017f3c8`` is the inner helper whose w0 return value decides
  ``0x10432dd98``'s w0, which in turn decides ``0x108878534 +360 tbz`` ->
  readiness B failure -> reporter Create Failed branch.
* Its body does a typical **lookup + acquire** pattern against two
  ``__common`` globals:

  1. ``adrp x8, 0x10e184000 ; ldr x0, [x8, #0x9f0]`` loads a root
     container pointer (let's call it ``root_A``).
  2. ``add x8, sp, #0x60 ; bl 0x1001ac168`` does an
     integer-keyed lookup (looks like TMap<int, shared_ptr<Foo>> find);
     the found entry is written to ``[sp+0x60]``.
  3. If ``[sp+0x60] == 0``, the function returns 0 immediately
     (``cbz x8, <fail_slot_1>`` at ``0x10017f414``).
  4. Otherwise it loads ``[sp+0x60]+0x10`` as x1 and calls
     ``bl 0x1001cd114`` with ``x0 = 0x10e184b18`` (``root_B``) and
     ``w2 = 1``. This second call returns w0; ``cbz x0, <fail_slot_2>``
     at ``0x10017f430`` again returns 0.

The helpers below let a BP callback:

* Read the NGR runtime slide (for unslid -> slid address translation).
* Dump the raw ``__common`` global values at fixed unslid addresses
  ``0x10e1849f0`` and ``0x10e184b18``.
* Read a candidate UE4 ``FString`` struct at a given address and try to
  decode its UTF-16-LE data buffer into Python str (bounded).
* Read a pointer chain ``[sp+0x60] -> [+0x0]`` / ``[+0x10]`` so we can
  see what ``bl 0x1001ac168`` actually returned.

The probes never mutate target state — they only do memory reads and
print structured ``[hok016c24] ...`` lines to the transcript that the
driver can harvest with regex.
"""

from __future__ import annotations

_NGR_TEXT_BASE_UNSLID = 0x100000000

# Well-known __common globals referenced inside 0x10017f3c8.
# Values come from the disassembly above and are stable across runs.
_ROOT_A_UNSLID = 0x10E1849F0  # ldr x0, [x8, #0x9f0] after adrp x8, 0x10e184000
_ROOT_B_UNSLID = 0x10E184B18  # adrp x0, 0x10e184000 ; add x0, x0, #0xb18


# ---------------------------------------------------------------------------
# Basic primitives.
# ---------------------------------------------------------------------------
def _resolve_ngr_slide(target):
    """Return NGR main image's runtime slide, or None if not loaded yet."""
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
    """Wrap process.ReadMemory returning bytes or None."""
    try:
        import lldb  # type: ignore
    except ImportError:
        return None
    err = lldb.SBError()
    data = process.ReadMemory(int(address), int(size), err)
    if err.Fail() or data is None:
        return None
    if not isinstance(data, (bytes, bytearray)):
        data = data.encode("latin-1")
    return bytes(data)


def _read_u64(process, address):
    raw = _read_bytes(process, address, 8)
    if raw is None or len(raw) != 8:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _read_i32(process, address):
    raw = _read_bytes(process, address, 4)
    if raw is None or len(raw) != 4:
        return None
    return int.from_bytes(raw, "little", signed=True)


def _hex(v, width=16):
    if v is None:
        return "?"
    return f"0x{v:0{width}x}"


def _reg_u64(frame, name):
    try:
        reg = frame.FindRegister(name)
        if reg and reg.IsValid():
            return int(reg.GetValueAsUnsigned())
    except Exception:
        return None
    return None


# ---------------------------------------------------------------------------
# FString decoding.
#
# UE4 ``FString`` is ``TArray<TCHAR>``; on iOS/macOS arm64 TCHAR is
# ``uint16_t`` (UTF-16-LE). The in-memory layout starts with:
#
#   0x00  TCHAR* Data         ; 8 bytes, pointer to UTF-16 buffer
#   0x08  int32  Num          ; 4 bytes, element count *including* NUL
#   0x0c  int32  Max          ; 4 bytes, allocator slack
#
# ``Num`` is >= 1 when there is content (the null terminator counts).
# ``Data`` is valid when ``Num > 0``; otherwise FString is empty / moved.
#
# We decode up to ``limit`` UTF-16 code units; if Num is implausibly large
# (> 4096) we clamp and mark ``truncated=True``.
# ---------------------------------------------------------------------------
def _decode_fstring(process, fstring_addr, limit=512):
    if not fstring_addr:
        return {"valid": False, "reason": "null-fstring-ptr"}
    data_ptr = _read_u64(process, fstring_addr)
    num = _read_i32(process, fstring_addr + 0x08)
    cap = _read_i32(process, fstring_addr + 0x0C)
    info = {
        "fstringAddr": _hex(fstring_addr),
        "dataPtr": _hex(data_ptr),
        "num": num,
        "max": cap,
    }
    if data_ptr is None or num is None:
        info.update({"valid": False, "reason": "read-failed"})
        return info
    if data_ptr == 0 or num is None or num <= 0:
        info.update({"valid": False, "reason": "empty-or-null"})
        return info
    truncated = False
    read_units = num
    if read_units > limit:
        read_units = limit
        truncated = True
    raw = _read_bytes(process, data_ptr, read_units * 2)
    if raw is None:
        info.update({"valid": False, "reason": "data-read-failed"})
        return info
    try:
        text = raw.decode("utf-16-le", errors="replace")
    except Exception:
        text = ""
    # Strip trailing NUL, if any.
    if text.endswith("\x00"):
        text = text.rstrip("\x00")
    info.update({"valid": True, "text": text, "truncated": truncated})
    return info


# ---------------------------------------------------------------------------
# Global dump helpers. Invoked inside probe callbacks so the driver can
# see how the two __common roots evolve across the lookup.
# ---------------------------------------------------------------------------
def _dump_commons(target, process):
    slide = _resolve_ngr_slide(target)
    if slide is None:
        return "slide=? root_a=? root_b=?"
    root_a_addr = _ROOT_A_UNSLID + slide
    root_b_addr = _ROOT_B_UNSLID + slide
    root_a_val = _read_u64(process, root_a_addr)
    root_b_val = _read_u64(process, root_b_addr)
    return (
        f"slide={_hex(slide)} "
        f"rootA@{_hex(root_a_addr)}=*{_hex(root_a_val)} "
        f"rootB@{_hex(root_b_addr)}=*{_hex(root_b_val)}"
    )


# ---------------------------------------------------------------------------
# BP callbacks.
# ---------------------------------------------------------------------------
def probe_inner_entry(frame, bp_loc, internal_dict):
    """Callback for 0x10017f3c8 entry. Print w0/w1/w2 + sp + slide info.

    0x10432dd98 calls ``0x10017f3c8(w0=[sp+0x14], w1=0, w2=0)`` so only
    x0 actually carries signal; keep x1/x2 for sanity.
    """
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    sp = _reg_u64(frame, "sp")
    print(
        f"[hok016c24] inner_entry 0x10017f3c8 "
        f"x0={_hex(x0)} x1={_hex(x1)} x2={_hex(x2)} sp={_hex(sp)} "
        f"({_dump_commons(target, process)})"
    )
    return False  # auto-continue


def probe_before_bl1(frame, bp_loc, internal_dict):
    """Callback for 0x10017f40c (before ``bl 0x1001ac168``). The call's
    ABI is ``find(root=x0, key=x1, out=x8)``; x8 = sp+0x60 is the output
    slot.
    """
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x8 = _reg_u64(frame, "x8")
    sp = _reg_u64(frame, "sp")
    # x1 here is actually the caller's original x0 (the int key passed
    # from 0x10432dd98), because 0x10017f3c8 did mov x1,x0 at entry.
    print(
        f"[hok016c24] before_bl1 0x10017f40c "
        f"x0={_hex(x0)} x1(key)={_hex(x1)} x8(out=sp+0x60)={_hex(x8)} sp={_hex(sp)} "
        f"({_dump_commons(target, process)})"
    )
    return False


def probe_after_bl1(frame, bp_loc, internal_dict):
    """Callback for 0x10017f410 (after ``bl 0x1001ac168``; next insn is
    ``ldr x8,[sp,#0x60]``). Read ``[sp+0x60]`` directly so we can see
    whether the lookup succeeded."""
    process = frame.GetThread().GetProcess()
    sp = _reg_u64(frame, "sp") or 0
    out_addr = sp + 0x60
    out_val = _read_u64(process, out_addr)
    # If non-null, dereference one more level: the value at out_val is
    # the "entry" object; its +0x10 field is later loaded as x1 of
    # bl 0x1001cd114, which looks like an FString pointer or key.
    inner_ptr = None
    inner_second = None
    if out_val:
        inner_ptr = _read_u64(process, out_val)
        inner_second = _read_u64(process, out_val + 0x10)
    print(
        f"[hok016c24] after_bl1 0x10017f410 "
        f"sp={_hex(sp)} [sp+0x60]={_hex(out_val)} "
        f"*entry(@+0x0)={_hex(inner_ptr)} *entry(@+0x10)={_hex(inner_second)}"
    )
    return False


def probe_before_bl2(frame, bp_loc, internal_dict):
    """Callback for 0x10017f428 (before ``bl 0x1001cd114``). ABI of the
    inner call looks like ``find_str(root=x0, key_fstring=x1, w2)``.
    """
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    w2 = _reg_u64(frame, "x2")
    w2 = (w2 or 0) & 0xFFFFFFFF
    sp = _reg_u64(frame, "sp")
    # Try to decode x1 as an FString (x1 = entry+0x10, which by the
    # red-black tree convention is typically a key payload; if the key
    # is an FString, this prints the literal NGR wants to acquire).
    fstring_info = _decode_fstring(process, x1) if x1 else {"valid": False}
    # Also try x1 as a bare ANSI string (in case the key is just
    # ``char*``).
    ansi = None
    if x1:
        raw = _read_bytes(process, x1, 128)
        if raw is not None:
            end = raw.find(b"\x00")
            if end >= 0:
                raw = raw[:end]
            try:
                ansi_candidate = raw.decode("utf-8", errors="replace")
                if 0 < len(ansi_candidate) < 128 and ansi_candidate.isprintable():
                    ansi = ansi_candidate
            except Exception:
                ansi = None
    print(
        f"[hok016c24] before_bl2 0x10017f428 "
        f"x0(rootB)={_hex(x0)} x1(keyptr)={_hex(x1)} w2={_hex(w2, 8)} "
        f"sp={_hex(sp)} "
        f"fstring={fstring_info} ansi={ansi!r} "
        f"({_dump_commons(target, process)})"
    )
    return False


def probe_after_bl2(frame, bp_loc, internal_dict):
    """Callback for 0x10017f42c (after ``bl 0x1001cd114``; next is
    ``mov x21, x0``). Report x0 return value."""
    x0 = _reg_u64(frame, "x0")
    print(
        f"[hok016c24] after_bl2 0x10017f42c "
        f"x0(return)={_hex(x0)}"
    )
    return False


def probe_fail_slot_1(frame, bp_loc, internal_dict):
    """Callback for 0x10017f658 (inner helper fail slot #1: bl 0x1001ac168
    returned out_ptr=0)."""
    process = frame.GetThread().GetProcess()
    sp = _reg_u64(frame, "sp") or 0
    out_val = _read_u64(process, sp + 0x60)
    print(
        f"[hok016c24] FAIL_SLOT_1 0x10017f658 "
        f"sp={_hex(sp)} [sp+0x60]={_hex(out_val)} "
        "(lookup A miss)"
    )
    return False


def probe_fail_slot_2(frame, bp_loc, internal_dict):
    """Callback for 0x10017f624 (inner helper fail slot #2: bl 0x1001cd114
    returned 0)."""
    x21 = _reg_u64(frame, "x21")
    print(
        f"[hok016c24] FAIL_SLOT_2 0x10017f624 "
        f"x21(=return from bl 0x1001cd114)={_hex(x21)} "
        "(lookup B miss)"
    )
    return False


# ---------------------------------------------------------------------------
# HOK-016-C.2.4b: 0x10432dd98 internal probes.
#
# HOK-016-C.2.4 first run (Scripts/hok016c24_ngr_readinessB_inner_args.py)
# showed that ``0x10017f3c8`` is **never reached** — none of the
# inner-helper probes fire. The w0=0 at ``0x108878698`` therefore comes
# from an *earlier* early-exit inside ``0x10432dd98``.
#
# Disassembly of ``0x10432dd98`` reveals two dominant early-exit paths
# before the ``bl 0x10017f3c8`` call at +0x240:
#
#   +0x54  b.eq  0x10432df8c         ; if w22 == [0x10f0df000+0xc08] -> alt path
#   +0x60  b.eq  0x10432de10         ; if w8+w22 == 1 -> alt path
#   +0x6c  bl    0x10432b734         ; 1st candidate lookup (find+register)
#   +0x70  cbz   w0, 0x10432e060     ; if w0==0 -> w19=0 -> return 0
#
# The dominant early-exit is the ``cbz w0, 0x10432e060`` at +0x70 because
# entry arg semantics (x1=1, x2 and x3 point to large stack buffers)
# match the "register+lookup" style call, and because the 0x10017f3c8
# BPs never fired.
#
# Add probes on:
#
#   * 0x10432dd98 +0x44: ldr w22,[sp,#0x40]            (after FString::Printf("%d",..))
#   * 0x10432dde8: cmp w22,w8 + b.eq (early-exit A to 0x10432df8c)
#   * 0x10432dde0: probe the global int at 0x10f0df000+0xc08 pre-cmp
#   * 0x10432de04: bl 0x10432b734 — capture x0/x1 pre-call
#   * 0x10432de08: cbz w0 — capture w0 post-call
#   * 0x10432e060: the w19=0 early-exit w19 slot
#
# And add FString-of-(sp+0x38) decoding since the call's arg2
# (x1 = sp+0x38) is a freshly Printf'd FString that likely encodes the
# lookup key ("1" as a string).
# ---------------------------------------------------------------------------
_OUTER_DECISION_GLOBAL_UNSLID = 0x10F0DFC08  # 0x10f0df000 + 0xc08
_SENTINEL_UNSLID = 0x10E1EEEF0


def probe_10432dd98_entry(frame, bp_loc, internal_dict):
    """Callback for 0x10432dd98 entry. Arg semantics observed in
    HOK-016-C.2.3:
        x0 = this (QtsFS subsystem)
        x1 = 1 (likely a mode/kind selector)
        x2 = pointer to a large stack struct on caller (FString*?)
        x3 = pointer to another stack struct (FString*?)
    Read FString at x2/x3 if they look like FStrings.
    """
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    x2 = _reg_u64(frame, "x2")
    x3 = _reg_u64(frame, "x3")
    fs_x2 = _decode_fstring(process, x2) if x2 else {"valid": False}
    fs_x3 = _decode_fstring(process, x3) if x3 else {"valid": False}
    print(
        f"[hok016c24] 10432dd98_entry "
        f"x0(this)={_hex(x0)} x1(mode)={_hex(x1)} "
        f"x2={_hex(x2)}={fs_x2} x3={_hex(x3)}={fs_x3} "
        f"({_dump_commons(target, process)})"
    )
    return False


def probe_10432dd98_after_printf(frame, bp_loc, internal_dict):
    """Callback just after ``bl 0x10473a3d4`` (FString::Printf("%d", …))
    at 0x10432dddc (``ldr w22, [sp,#0x40]``). Read:
      * the Printf'd FString at sp+0x38 (decode data + num + max)
      * the outer decision global at 0x10f0dfc08 (slid)
      * [sp+0x40] = Num field of the Printf'd FString
    """
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    slide = _resolve_ngr_slide(target)
    sp = _reg_u64(frame, "sp") or 0
    # After Printf, sp+0x38 is the out FString header.
    fs_info = _decode_fstring(process, sp + 0x38)
    num = _read_i32(process, sp + 0x40)
    # Decision global.
    decision_addr = _OUTER_DECISION_GLOBAL_UNSLID + (slide or 0)
    decision_val = _read_i32(process, decision_addr) if slide is not None else None
    # Sentinel for context.
    sent_val = None
    if slide is not None:
        sent_val = _read_bytes(process, _SENTINEL_UNSLID + slide, 1)
        sent_val = sent_val[0] if sent_val else None
    print(
        f"[hok016c24] 10432dd98_after_printf "
        f"sp={_hex(sp)} printf_fstring@sp+0x38={fs_info} num={num} "
        f"decision@{_hex(decision_addr)}={decision_val} "
        f"sentinel@0x10e1eeef0={sent_val!r}"
    )
    return False


def probe_10432dd98_before_bl_b734(frame, bp_loc, internal_dict):
    """Callback at 0x10432de04 (bl 0x10432b734 site). Read x0 (this) and
    x1 (which should = sp+0x38 = the Printf'd FString)."""
    process = frame.GetThread().GetProcess()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    fs_info = _decode_fstring(process, x1) if x1 else {"valid": False}
    print(
        f"[hok016c24] 10432dd98_before_bl_b734 "
        f"x0(this)={_hex(x0)} x1(fstring)={_hex(x1)}={fs_info}"
    )
    return False


def probe_10432dd98_after_bl_b734(frame, bp_loc, internal_dict):
    """Callback at 0x10432de08 (cbz w0 site after bl 0x10432b734). w0 is
    the return; 0 -> early-exit to 0x10432e060 -> return 0."""
    x0 = _reg_u64(frame, "x0")
    print(
        f"[hok016c24] 10432dd98_after_bl_b734 "
        f"x0(return)={_hex(x0)}"
    )
    return False


def probe_10432dd98_early_exit(frame, bp_loc, internal_dict):
    """Callback at 0x10432e060 (early-exit: mov w19, #0x0). Confirms the
    failure flows here from ``cbz w0, …`` after ``bl 0x10432b734``."""
    print("[hok016c24] 10432dd98_EARLY_EXIT @ 0x10432e060 (w19 <- 0)")
    return False


def probe_10432dd98_fail_exit_A(frame, bp_loc, internal_dict):
    """Callback at 0x10432e058 (the OTHER w19=0 exit; reached via
    ``10432df30 tbz w0,#0, 0x10432e014 -> bl 0x10017ad60 -> ... ->
    10432e044 cmp w20,#0x92 -> b.ne 10432e058``)."""
    x20 = _reg_u64(frame, "x20")
    print(
        f"[hok016c24] 10432dd98_FAIL_EXIT_A @ 0x10432e058 "
        f"x20(result_of_bl_0x10017ad60)={_hex(x20)} (w19 <- 0)"
    )
    return False


def probe_10432dd98_success_marker(frame, bp_loc, internal_dict):
    """Callback at 0x10432df34 (success marker: mov w19, #0x1)."""
    print("[hok016c24] 10432dd98_SUCCESS @ 0x10432df34 (w19 <- 1)")
    return False


def probe_10432dd98_after_vtable1(frame, bp_loc, internal_dict):
    """Callback after first ``blr x8`` at 0x10432deb4 (mov x21, x0).

    The vtable call at offset 0xf8 is dispatched on ``[x19+0x60]`` (the
    QtsFS ``this->something``); x21 captures its return."""
    x0 = _reg_u64(frame, "x0")
    print(f"[hok016c24] 10432dd98_after_vtable1 x0(=->x21)={_hex(x0)}")
    return False


def probe_10432dd98_after_vtable2(frame, bp_loc, internal_dict):
    """Callback after second ``blr x8`` at 0x10432ded8 (mov x20, x0)."""
    x0 = _reg_u64(frame, "x0")
    print(f"[hok016c24] 10432dd98_after_vtable2 x0(=->x20)={_hex(x0)}")
    return False


def probe_10432dd98_at_cbnzw21(frame, bp_loc, internal_dict):
    """Callback at 0x10432deec (cbnz w21 site).  w21 was set by
    ``10432deb4 mov x21, x0`` (the first vtable return).  If non-zero,
    the function jumps to 0x10432dfac which is yet another branch; if
    zero, continues to the ``10432df18 bl 0x10017faa0`` flow."""
    x21 = _reg_u64(frame, "x21")
    print(f"[hok016c24] 10432dd98_at_cbnzw21 @ 0x10432deec x21={_hex(x21)}")
    return False


def probe_10432dd98_at_cbzw20(frame, bp_loc, internal_dict):
    """Callback at 0x10432df0c (cbz w20).  w20 was set by
    ``10432ded8 mov x20, x0`` (the second vtable return).  If zero,
    jumps directly to 0x10432df34 = success; if non-zero, continues into
    ``10432df18 bl 0x10017faa0``."""
    x20 = _reg_u64(frame, "x20")
    w20 = (x20 or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_at_cbzw20 @ 0x10432df0c "
        f"x20={_hex(x20)} w20={_hex(w20, 8)}"
    )
    return False


def probe_10432dd98_before_bl_faa0(frame, bp_loc, internal_dict):
    """Callback at 0x10432df18 (bl 0x10017faa0).  Inputs: w0 =
    [sp+0x14], w1=1.  [sp+0x14] is the return of an earlier
    ``bl 0x104329c18`` call (unknown intent, perhaps a classifier)."""
    process = frame.GetThread().GetProcess()
    w0 = (_reg_u64(frame, "x0") or 0) & 0xFFFFFFFF
    w1 = (_reg_u64(frame, "x1") or 0) & 0xFFFFFFFF
    sp = _reg_u64(frame, "sp") or 0
    sp14 = _read_i32(process, sp + 0x14)
    print(
        f"[hok016c24] 10432dd98_before_bl_faa0 @ 0x10432df18 "
        f"w0={_hex(w0, 8)} w1={_hex(w1, 8)} sp+0x14={sp14}"
    )
    return False


def probe_10432dd98_after_bl_faa0(frame, bp_loc, internal_dict):
    """Callback at 0x10432df1c (cbnz w0 site after bl 0x10017faa0)."""
    w0 = (_reg_u64(frame, "x0") or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_after_bl_faa0 @ 0x10432df1c "
        f"w0(return)={_hex(w0, 8)}"
    )
    return False


def probe_10432dd98_before_bl_f3c8(frame, bp_loc, internal_dict):
    """Callback at 0x10432df28 (immediately before bl 0x10017f3c8).
    Redundant with the inner_entry probe at 0x10017f3c8 itself, but
    confirms whether this specific call-site is reached in the current
    run (answers the C.2.4 v2 question: was f3c8 really unreached?)."""
    w0 = (_reg_u64(frame, "x0") or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_before_bl_f3c8 @ 0x10432df28 "
        f"w0(arg1)={_hex(w0, 8)}"
    )
    return False


def probe_10432dd98_after_bl_f3c8(frame, bp_loc, internal_dict):
    """Callback at 0x10432df30 (tbz w0 site after bl 0x10017f3c8)."""
    w0 = (_reg_u64(frame, "x0") or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_after_bl_f3c8 @ 0x10432df30 "
        f"w0(return)={_hex(w0, 8)}"
    )
    return False


def probe_10432dd98_at_dfec(frame, bp_loc, internal_dict):
    """Callback at 0x10432dfec (the target of ``cbnz w0, 0x10432dfec``
    after bl 0x10017faa0).  Reached when bl 0x10017faa0 returns
    non-zero; from here, sentinel<3 jumps to success df34, otherwise
    falls into a logging call."""
    print("[hok016c24] 10432dd98_at_dfec @ 0x10432dfec (bl_faa0 returned non-zero)")
    return False


def probe_10432dd98_at_e014(frame, bp_loc, internal_dict):
    """Callback at 0x10432e014 (the target of ``tbz w0,#0,0x10432e014``
    after bl 0x10017f3c8).  Reached when bl 0x10017f3c8 returns w0=0
    (inner failure).  Entry does ``bl 0x10017ad60`` — likely a
    fault-category classifier whose return is tested against 0x92 later."""
    print("[hok016c24] 10432dd98_at_e014 @ 0x10432e014 (f3c8 returned 0)")
    return False


def probe_10432dd98_epilogue(frame, bp_loc, internal_dict):
    """Callback at 0x10432df74 (mov x0, x19 — end of function; x0/w19 is
    the return value).  Summarizes the final return."""
    x19 = _reg_u64(frame, "x19")
    w19 = (x19 or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_EPILOGUE @ 0x10432df74 "
        f"x19={_hex(x19)} w19(return)={_hex(w19, 8)}"
    )
    return False


# ---------------------------------------------------------------------------
# Deeper (0x10432b734) probes. Retained even though the v2 run shows
# 10432dd98 took the b.eq 10432df8c branch instead of reaching
# bl 0x10432b734 — useful if a later experiment coerces the function
# into the alternative path.
# ---------------------------------------------------------------------------
def probe_10432b734_entry(frame, bp_loc, internal_dict):
    """Callback at 0x10432b734 entry. Inner ABI: (x0=this, x1=fstring).
    We want to know what key (FString) is being looked up."""
    process = frame.GetThread().GetProcess()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    fs_info = _decode_fstring(process, x1) if x1 else {"valid": False}
    print(
        f"[hok016c24] 10432b734_entry "
        f"x0(this)={_hex(x0)} x1(fstring)={_hex(x1)}={fs_info}"
    )
    return False


def probe_10432b734_after_bl_b2a8(frame, bp_loc, internal_dict):
    """Callback at 0x10432b758 (cbz w0 site after bl 0x10432b2a8). w0
    decides whether the early-already-registered path is taken."""
    x0 = _reg_u64(frame, "x0")
    print(f"[hok016c24] 10432b734_after_bl_b2a8 x0(return)={_hex(x0)}")
    return False


def probe_10432b734_after_bl_ba84(frame, bp_loc, internal_dict):
    """Callback at 0x10432b770 (after bl 0x10432ba84). w0 is the return
    of the register/acquire call; 0 tends to indicate failure."""
    x0 = _reg_u64(frame, "x0")
    print(f"[hok016c24] 10432b734_after_bl_ba84 x0(return)={_hex(x0)}")
    return False


def probe_10432dd98_at_e06c(frame, bp_loc, internal_dict):
    """Callback at 0x10432e06c (target of ``cbz w20, 0x10432e06c`` at
    0x10432dfac).  First insn is ``mov x0, x1``; x1 here is whatever
    the previous code-flow stored into x1, and it becomes the arg for
    ``bl 0x10017f184`` two insns later.  Dump x0 / x1 so we can see
    what's being fed into 0x10017f184."""
    process = frame.GetThread().GetProcess()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    # If x1 looks like a stack/heap FString pointer, try to decode it.
    fs_info = _decode_fstring(process, x1) if x1 else {"valid": False}
    print(
        f"[hok016c24] 10432dd98_at_e06c @ 0x10432e06c "
        f"x0={_hex(x0)} x1={_hex(x1)} fstring={fs_info}"
    )
    return False


def probe_10432dd98_after_bl_f184(frame, bp_loc, internal_dict):
    """Callback at 0x10432e074 (tbnz w0 site, the key decision).

    ``bl 0x10017f184`` returned in w0; bit 0 decides whether we loop back
    to the ``10432dfbc`` path (w0 bit 0 set = reach bl 0x10017f3c8) or
    fall through to the 10432e078 vtable blr path that eventually lands
    on FAIL_EXIT_A @ 0x10432e058.  v3 observation: bit 0 = 0, fall through.
    """
    w0 = (_reg_u64(frame, "x0") or 0) & 0xFFFFFFFF
    print(
        f"[hok016c24] 10432dd98_after_bl_f184 @ 0x10432e074 "
        f"w0(return)={_hex(w0, 8)} bit0={w0 & 0x1}"
    )
    return False


def probe_f184_entry(frame, bp_loc, internal_dict):
    """Callback at 0x10017f184 entry.  x0 (becomes x1 at +0x14) is the
    int key used for the red-black tree lookup via bl 0x1001ac168."""
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    print(
        f"[hok016c24] f184_entry 0x10017f184 "
        f"x0(key)={_hex(x0)} "
        f"({_dump_commons(target, process)})"
    )
    return False


def probe_f184_after_bl1(frame, bp_loc, internal_dict):
    """Callback at 0x10017f1c0 (ldr x8,[sp,#0x20] right after
    bl 0x1001ac168 in 0x10017f184).  [sp+0x20] is the out entry pointer;
    ``cbz x8, 0x10017f2f0`` tests it at +0x3c and if zero bails out."""
    process = frame.GetThread().GetProcess()
    sp = _reg_u64(frame, "sp") or 0
    out_val = _read_u64(process, sp + 0x20)
    inner_plus0 = None
    inner_plus10 = None
    entry_dump = None
    if out_val:
        inner_plus0 = _read_u64(process, out_val)
        inner_plus10 = _read_u64(process, out_val + 0x10)
        raw = _read_bytes(process, out_val, 64)
        if raw:
            entry_dump = " ".join(f"{b:02x}" for b in raw)
    print(
        f"[hok016c24] f184_after_bl1 0x10017f1c0 "
        f"[sp+0x20]={_hex(out_val)} "
        f"*entry(@+0x0)={_hex(inner_plus0)} *entry(@+0x10)={_hex(inner_plus10)} "
        f"entry_hex64=[{entry_dump}]"
    )
    return False


def probe_f184_before_bl2(frame, bp_loc, internal_dict):
    """Callback at 0x10017f1d8 (immediately before ``bl 0x1001cd114`` in
    0x10017f184).  x0 = 0x10e184b18 (rootB), x1 = entry+0x10 which is
    likely an FString-style string key."""
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    x0 = _reg_u64(frame, "x0")
    x1 = _reg_u64(frame, "x1")
    fstring_info = _decode_fstring(process, x1) if x1 else {"valid": False}
    # Also try x1 as a plain char*.
    ansi = None
    if x1:
        raw = _read_bytes(process, x1, 128)
        if raw:
            end = raw.find(b"\x00")
            if end >= 0:
                raw = raw[:end]
            try:
                candidate = raw.decode("utf-8", errors="replace")
                if 0 < len(candidate) < 128 and candidate.isprintable():
                    ansi = candidate
            except Exception:
                pass
    # Raw hex dump of x1 for 48 bytes so we can reverse-engineer the
    # struct layout (v4 showed this is NOT an FString header but likely
    # a custom [length:u64][chars:N\0] PascalString).
    hex_dump = None
    if x1:
        raw = _read_bytes(process, x1, 48)
        if raw:
            hex_dump = " ".join(f"{b:02x}" for b in raw)
    # Extract the "chars" payload as interpreted ANSI.
    key_str = None
    if x1:
        raw = _read_bytes(process, x1, 48)
        if raw and len(raw) >= 16:
            length = int.from_bytes(raw[0:8], "little")
            if 0 < length < 64 and len(raw) >= 8 + length:
                key_bytes = raw[8:8 + length]
                try:
                    key_str = key_bytes.decode("utf-8", errors="replace")
                except Exception:
                    key_str = None
    # Peek rootB contents to see whether it's empty.
    root_b = None
    root_b_plus10 = None
    root_b_plus18 = None
    slide = _resolve_ngr_slide(target) or 0
    root_b_addr = _ROOT_B_UNSLID + slide
    root_b_hdr = _read_bytes(process, root_b_addr, 32)
    print(
        f"[hok016c24] f184_before_bl2 0x10017f1d8 "
        f"x0(rootB)={_hex(x0)} x1(keyptr)={_hex(x1)} "
        f"key_str={key_str!r} "
        f"rootB_hdr={' '.join(f'{b:02x}' for b in (root_b_hdr or b''))} "
        f"hex48@x1=[{hex_dump}]"
    )
    return False


def probe_f184_after_bl2(frame, bp_loc, internal_dict):
    """Callback at 0x10017f1dc (mov x19, x0 right after bl 0x1001cd114
    in 0x10017f184).  x0 is the return; 0 → cbz at +0x5c jumps to
    fail-slot-2 @ 0x10017f2bc."""
    x0 = _reg_u64(frame, "x0")
    print(f"[hok016c24] f184_after_bl2 0x10017f1dc x0(return)={_hex(x0)}")
    return False


def probe_f184_fail_slot_1(frame, bp_loc, internal_dict):
    """Callback at 0x10017f2f0 (``bl 0x1001ac168`` returned ptr=0 →
    cbz x8 target)."""
    process = frame.GetThread().GetProcess()
    sp = _reg_u64(frame, "sp") or 0
    out_val = _read_u64(process, sp + 0x20)
    print(
        f"[hok016c24] f184_FAIL_SLOT_1 0x10017f2f0 "
        f"[sp+0x20]={_hex(out_val)} (lookup A miss, int key not found)"
    )
    return False


def probe_f184_fail_slot_2(frame, bp_loc, internal_dict):
    """Callback at 0x10017f2bc (``bl 0x1001cd114`` returned 0 →
    cbz x0 target)."""
    x19 = _reg_u64(frame, "x19")
    print(
        f"[hok016c24] f184_FAIL_SLOT_2 0x10017f2bc "
        f"x19(=return from bl 0x1001cd114)={_hex(x19)} "
        "(lookup B miss, string key not found)"
    )
    return False


def __lldb_init_module(debugger, internal_dict):
    print(
        "[hok016c24] loaded; inner-helper probes: "
        "probe_inner_entry / probe_before_bl1 / probe_after_bl1 / "
        "probe_before_bl2 / probe_after_bl2 / "
        "probe_fail_slot_1 / probe_fail_slot_2; "
        "outer (0x10432dd98) probes: probe_10432dd98_entry / "
        "probe_10432dd98_after_printf / probe_10432dd98_before_bl_b734 / "
        "probe_10432dd98_after_bl_b734 / probe_10432dd98_early_exit / "
        "probe_10432dd98_fail_exit_A / probe_10432dd98_success_marker / "
        "probe_10432dd98_after_vtable1 / probe_10432dd98_after_vtable2 / "
        "probe_10432dd98_at_cbnzw21 / probe_10432dd98_at_cbzw20 / "
        "probe_10432dd98_before_bl_faa0 / probe_10432dd98_after_bl_faa0 / "
        "probe_10432dd98_before_bl_f3c8 / probe_10432dd98_after_bl_f3c8 / "
        "probe_10432dd98_at_dfec / probe_10432dd98_at_e014 / "
        "probe_10432dd98_epilogue; "
        "deeper (0x10432b734): probe_10432b734_entry / "
        "probe_10432b734_after_bl_b2a8 / probe_10432b734_after_bl_ba84"
    )
