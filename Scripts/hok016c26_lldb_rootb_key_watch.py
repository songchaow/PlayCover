"""HOK-016-C.2.6 LLDB helper: arm a watchpoint on rootB and dump
the *key* of each newly inserted node so we can attribute the 'main'
PascalString (if it appears) to a specific call chain.

C.2.5 already confirmed that rootB ``0x10e184b18`` gets ``insert``ed twice
inside the reporter chain (watchpoint on rootB[0..7], PC both times =
``0x1001cf020`` inside the Qtsk red-black tree insert helper at
``0x1001cef38``). But C.2.5 only recorded *that* an insert happened — it
did not dump the *key* of the inserted node, so we still don't know
whether one of those 2 inserts was the 'main' chunk that C.2.4's
``bl 0x1001cd114`` is trying to look up.

This helper arms the same 8-byte modify watchpoint on rootB[0..7] and
dumps, on every hit:

1. Register snapshot (x19, x21, x22, x23 — insert helper uses x21 as the
   newly allocated node base).
2. The new node's key at ``node+0x20`` (Qtsk PascalString:
   ``[length:u32][w9:u32][inline_chars_or_ptr:8]``).
3. The top 6 backtrace frames.

Additionally, the helper also exposes a ``snapshot_rootb_on_hit`` BP
callback for placement at the lookup helper ``0x1001cd114`` — when armed,
each hit logs ``[hok016c26-lookup]`` with rootB's runtime header, x0
(root arg), and a decode of the PascalString at x1 (key arg). This lets
us confirm whether the lookup sees the "main" entry that an earlier
insert wrote.

**Pure LLDB probe — no PlayTools / NGR modifications**.

Loaded into LLDB via::

    command script import Scripts/hok016c26_lldb_rootb_key_watch.py
"""

from __future__ import annotations

_NGR_TEXT_BASE_UNSLID = 0x100000000

# rootB = the Qtsk red-black tree whose lookup for "main" is failing.
_ROOTB_UNSLID = 0x10E184B18

# Width of the watched window. C.2.5 proved 8 bytes at rootB[0..7] is
# enough to catch both reporter-internal inserts (insert helper touches
# the leftmost/root pointer slot). 64-byte watchpoints on Apple Silicon
# have stricter alignment / hardware-slot requirements and we verified
# that 64-byte requests *silently fail to catch stores* at rootB=
# 0x10e184b18 even though WatchAddress returned success. Stick to 8.
_WATCH_WIDTH = 8

# Offsets into a freshly allocated red-black-tree node where the key
# PascalString lives. Derived from disasm of the insert helper
# 0x1001cef38 (Qtsk::STGlobalMemData chunk insert):
#
#   0x1001cefd0 mov x21, x0          ; x21 = allocated node
#   0x1001ceff8 bl  0x1016c57f8(x0=node+0x20, x1=chars, w2=length)
#     ^ this copies the key's chars into node+0x20
#   0x1001cf004 str x23, [x21, #0x10]  ; x23 is the parent link, NOT a key
#
# So the actual key is at node+0x20 as a Qtsk PascalString, and its
# layout (from the C.2.4 analysis of the cousin structure in rootA):
#
#   node+0x20: [length:u32] [w9_flag:u32]
#   node+0x28: inline chars if w9<2 (8 bytes), else data-ptr-to-chars
#   node+0x30: tail / inline padding
#
# We dump 32 bytes starting at node+0x20 to cover header + inline chars.
_NODE_KEY_OFFSET = 0x20
_KEY_DUMP_WIDTH = 32

_watchpoint_installed = False
_subtree_watch_installed = False
_hit_counter = 0


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
    import lldb  # type: ignore

    err = lldb.SBError()
    raw = process.ReadMemory(address, size, err)
    if err.Fail() or raw is None:
        return None
    if not isinstance(raw, (bytes, bytearray)):
        raw = raw.encode("latin-1")
    return bytes(raw)


def _hex_dump(data):
    if data is None:
        return "<read fail>"
    return " ".join(f"{b:02x}" for b in data)


def _read_u64(process, address):
    raw = _read_bytes(process, address, 8)
    if raw is None or len(raw) != 8:
        return None
    return int.from_bytes(raw, "little", signed=False)


def install_rootb_wide_watch(frame, bp_loc, internal_dict):
    """LLDB Python BP callback: at the BP site, resolve NGR slide and
    install a wide (64-byte) modify watchpoint on rootB.

    This is intended to fire at NGR's ``main`` entry (after dyld static
    inits), so captured writes are *insert-time writes* performed during
    runtime library bring-up.
    """
    global _watchpoint_installed
    if _watchpoint_installed:
        return False

    import lldb  # type: ignore

    target = frame.GetThread().GetProcess().GetTarget()
    process = target.GetProcess()

    slide = _resolve_ngr_slide(target)
    if slide is None:
        print("[hok016c26] install-wp: NGR not yet mapped; will retry.")
        return False

    rootb_addr = _ROOTB_UNSLID + slide
    pre_bytes = _read_bytes(process, rootb_addr, _WATCH_WIDTH)
    print(
        f"[hok016c26] pre-arm rootB @ 0x{rootb_addr:x} "
        f"(unslid=0x{_ROOTB_UNSLID:x}, slide=0x{slide:x}); "
        f"dump[{_WATCH_WIDTH}]={_hex_dump(pre_bytes)}"
    )

    err = lldb.SBError()
    wp = target.WatchAddress(rootb_addr, _WATCH_WIDTH, False, True, err)
    if err.Fail() or not wp or not wp.IsValid():
        print(
            f"[hok016c26] WatchAddress failed @ 0x{rootb_addr:x}: "
            f"{err.GetCString()!r}"
        )
        # Fall back to 8 bytes if the hardware doesn't support 64.
        err2 = lldb.SBError()
        wp = target.WatchAddress(rootb_addr, 8, False, True, err2)
        if err2.Fail() or not wp or not wp.IsValid():
            print(
                f"[hok016c26] WatchAddress fallback 8B also failed: "
                f"{err2.GetCString()!r}"
            )
            return False
        print(
            f"[hok016c26] fallback-armed 8-byte watchpoint id={wp.GetID()} "
            f"@ 0x{rootb_addr:x}"
        )
    else:
        print(
            f"[hok016c26] armed {_WATCH_WIDTH}-byte watchpoint id={wp.GetID()} "
            f"@ 0x{rootb_addr:x}"
        )

    # Attach the Python per-hit dumper callback directly to the freshly
    # created watchpoint. Older SBWatchpoint does NOT expose
    # SetScriptCallbackFunction directly, so we drive LLDB's command
    # interpreter to install the Python callback on the freshly created
    # watchpoint id. This avoids the ID-timing race of declaring the
    # callback before the watchpoint exists.
    wp_id = wp.GetID()
    debugger = target.GetDebugger()
    ci = debugger.GetCommandInterpreter()
    import lldb  # already imported above
    res = lldb.SBCommandReturnObject()
    cmd = (
        "watchpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.dump_node_key_on_hit "
        f"{wp_id}"
    )
    ci.HandleCommand(cmd, res)
    if not res.Succeeded():
        print(
            "[hok016c26] failed to attach dump_node_key_on_hit: "
            f"err={res.GetError()!r}"
        )
    else:
        print(
            "[hok016c26] attached dump_node_key_on_hit to watchpoint id="
            f"{wp_id}"
        )

    _watchpoint_installed = True
    return False  # auto-continue


def dump_node_key_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python BP/watchpoint callback: on every hit, dump the
    candidate new-node key.

    Heuristic: in the Qtsk insert helper at 0x1001cef38, after
    ``str x23, [x21, #0x10]`` the newly allocated node lives at x21 and
    its key pointer is at ``[x21 + 0x10]``. We therefore:

      1) Dump x19, x21, x22, x23 (insert helper's core state).
      2) Read candidate key pointer at ``[x21 + 0x10]``; if that looks
         like a valid address, dump 32 bytes of its PascalString.
      3) Also try ``x23`` directly (it *is* the key pointer immediately
         before the ``str``).
      4) Dump the first 64 bytes of rootB so we can see what field was
         just written.
      5) Print a 4-frame backtrace so the call chain is visible.

    Returns False → auto-continue, so multiple inserts are captured.
    """
    global _hit_counter

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    _hit_counter += 1
    pc = frame.GetPC()
    fn = frame.GetFunctionName() or "<unknown>"

    # Register snapshot.
    reg_names = ("x0", "x1", "x2", "x19", "x20", "x21", "x22", "x23", "x24")
    regs: dict[str, int] = {}
    for rn in reg_names:
        val = frame.FindRegister(rn)
        if val and val.IsValid():
            try:
                regs[rn] = int(val.GetValue(), 0)
            except (TypeError, ValueError):
                regs[rn] = 0

    print(
        f"[hok016c26] hit#{_hit_counter} pc=0x{pc:x} fn={fn} "
        f"x19=0x{regs.get('x19', 0):x} x21=0x{regs.get('x21', 0):x} "
        f"x22=0x{regs.get('x22', 0):x} x23=0x{regs.get('x23', 0):x}"
    )

    # Dump first 64 bytes of rootB — shows which field moved.
    slide = _resolve_ngr_slide(target)
    if slide is not None:
        rootb_addr = _ROOTB_UNSLID + slide
        rootb_dump = _read_bytes(process, rootb_addr, _WATCH_WIDTH)
        print(
            f"[hok016c26] hit#{_hit_counter} rootB@0x{rootb_addr:x} "
            f"dump[{_WATCH_WIDTH}]={_hex_dump(rootb_dump)}"
        )

    # Candidate key paths. Based on insert-helper disasm, the real key
    # PascalString is stored at ``node+0x20`` as
    # ``[length:u32][w9_flag:u32][inline_chars_or_ptr...]`` with the
    # classic Qtsk Small-String-Optimization:
    #   if w9 < 2  → chars are inline at node+0x28 (8 bytes of chars)
    #   else       → node+0x28 holds an external data pointer
    #
    # At watchpoint-hit time the callee-saved x21 register reliably
    # holds the newly-allocated node base (the insert helper at
    # 0x1001cef38 does `mov x21, x0` immediately after alloc and never
    # clobbers it before the watchpoint-triggering store).
    for cand_reg in ("x21",):
        node = regs.get(cand_reg, 0)
        if not node or node < 0x100000000:
            continue
        key_start = node + _NODE_KEY_OFFSET
        header = _read_bytes(process, key_start, _KEY_DUMP_WIDTH)
        if header is None or len(header) < 16:
            print(
                f"[hok016c26] hit#{_hit_counter} read-fail at "
                f"{cand_reg}+0x{_NODE_KEY_OFFSET:x} = 0x{key_start:x}"
            )
            continue
        length = int.from_bytes(header[0:4], "little", signed=False)
        w9_flag = int.from_bytes(header[4:8], "little", signed=False)
        inline_chars = header[8:16]
        # Best-effort ASCII decode of inline chars.
        try:
            chars_ascii = inline_chars.decode("ascii", errors="replace")
        except Exception:
            chars_ascii = "?"
        # If w9 >= 2, the 'chars' field is really a data pointer; try to
        # read it so we can also print the heap-stored chars.
        external_preview = None
        if w9_flag >= 2:
            ext_ptr = int.from_bytes(inline_chars, "little", signed=False)
            if ext_ptr > 0x100000000 and ext_ptr < 0x200000000000:
                ext_raw = _read_bytes(process, ext_ptr, min(32, max(0, length)))
                if ext_raw is not None:
                    try:
                        external_preview = ext_raw.decode(
                            "ascii", errors="replace"
                        )
                    except Exception:
                        external_preview = ext_raw.hex()
        print(
            f"[hok016c26] hit#{_hit_counter} key @ {cand_reg}+0x{_NODE_KEY_OFFSET:x} "
            f"(=0x{key_start:x}): length={length} w9={w9_flag} "
            f"inline_chars_ascii={chars_ascii!r} "
            f"hex32={_hex_dump(header)}"
            + (f" external={external_preview!r}" if external_preview else "")
        )

    # Short backtrace — just the top 6 frames.
    bt_limit = 6
    frames = []
    for i in range(min(bt_limit, thread.GetNumFrames())):
        fr = thread.GetFrameAtIndex(i)
        frames.append(
            f"#{i} 0x{fr.GetPC():x} {fr.GetFunctionName() or '<unknown>'}"
        )
    print(f"[hok016c26] hit#{_hit_counter} backtrace: " + " | ".join(frames))
    return False  # auto-continue


def snapshot_lookup2_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python BP callback for the second-level lookup helper
    ``0x1001ba82c(mainChunk, key)``.

    Logs:
    - x0 = mainChunk object
    - x1 = key PascalString (typically expected to be "1")
    - *(x0 + 0x60) = secondary subtree root
    """
    process = frame.GetThread().GetProcess()
    regs = {}
    for rn in ("x0", "x1"):
        reg = frame.FindRegister(rn)
        if reg and reg.IsValid():
            try:
                regs[rn] = int(reg.GetValue(), 0)
            except (TypeError, ValueError):
                regs[rn] = 0
    obj = regs.get("x0", 0)
    key_ptr = regs.get("x1", 0)
    subtree = _read_u64(process, obj + 0x60) if obj > 0x100000000 else None
    key_decode = "<nil>"
    if key_ptr > 0x100000000:
        key_raw = _read_bytes(process, key_ptr, 16)
        if key_raw and len(key_raw) == 16:
            length = int.from_bytes(key_raw[0:4], "little", signed=False)
            w9 = int.from_bytes(key_raw[4:8], "little", signed=False)
            inline = key_raw[8:16]
            try:
                chars = inline.decode("ascii", errors="replace")
            except Exception:
                chars = inline.hex()
            key_decode = (
                f"length={length} w9={w9} chars={chars!r} hex={key_raw.hex()}"
            )
    print(
        f"[hok016c26-lookup2] x0(mainChunk)=0x{obj:x} "
        f"x1(key)=0x{key_ptr:x} key_decoded=[{key_decode}] "
        f"mainChunk+0x60=0x{(subtree or 0):x}"
    )
    return False  # auto-continue


def snapshot_rootb_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python BP callback for placement at the lookup helper entry
    ``0x1001cd114``. On every hit, dump:

    - the lookup helper's x0 (root container pointer) and x1 (key ptr)
    - the PascalString decode of x1 (length:u32, w9:u32, inline_chars)
    - the runtime header of rootB (first 16 bytes)

    This lets us correlate each failing ``bl 0x1001cd114(rootB, "main", 1)``
    call with whether rootB actually contains the "main" entry at that
    moment.

    Returns False → auto-continue, so every lookup call is logged.
    """
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    pc = frame.GetPC()
    regs: dict[str, int] = {}
    for rn in ("x0", "x1", "x2"):
        val = frame.FindRegister(rn)
        if val and val.IsValid():
            try:
                regs[rn] = int(val.GetValue(), 0)
            except (TypeError, ValueError):
                regs[rn] = 0

    # Decode the key PascalString at x1.
    key_ptr = regs.get("x1", 0)
    key_decode = "<nil>"
    if key_ptr > 0x100000000:
        key_raw = _read_bytes(process, key_ptr, 16)
        if key_raw and len(key_raw) == 16:
            length = int.from_bytes(key_raw[0:4], "little", signed=False)
            w9 = int.from_bytes(key_raw[4:8], "little", signed=False)
            inline = key_raw[8:16]
            try:
                chars = inline.decode("ascii", errors="replace")
            except Exception:
                chars = inline.hex()
            key_decode = (
                f"length={length} w9={w9} chars={chars!r} hex={key_raw.hex()}"
            )

    slide = _resolve_ngr_slide(target)
    rootb_hdr = "<unresolved>"
    if slide is not None:
        rootb_addr = _ROOTB_UNSLID + slide
        hdr_raw = _read_bytes(process, rootb_addr, 32)
        if hdr_raw:
            rootb_hdr = hdr_raw.hex()

    print(
        f"[hok016c26-lookup] pc=0x{pc:x} "
        f"x0(root)=0x{regs.get('x0', 0):x} "
        f"x1(key)=0x{key_ptr:x} "
        f"x2(w2)=0x{regs.get('x2', 0):x} "
        f"key_decoded=[{key_decode}] "
        f"rootB_header32={rootb_hdr}"
    )
    # Short backtrace so we can correlate lookup order with insert
    # order across the entire trace.
    bt_limit = 8
    frames = []
    for i in range(min(bt_limit, thread.GetNumFrames())):
        fr = thread.GetFrameAtIndex(i)
        frames.append(
            f"#{i} 0x{fr.GetPC():x}"
        )
    tid = thread.GetThreadID()
    print(
        f"[hok016c26-lookup] thread_id={tid} bt=" + " ".join(frames)
    )
    return False  # auto-continue


def _attach_watchpoint_callback(target, wp, callback_name):
    """Best-effort helper to attach a Python callback to an LLDB watchpoint
    using the command interpreter.
    """
    import lldb  # type: ignore

    debugger = target.GetDebugger()
    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()
    cmd = f"watchpoint command add -s python -F {callback_name} {wp.GetID()}"
    ci.HandleCommand(cmd, res)
    return res.Succeeded(), res.GetError()


def snapshot_subtree_watch_on_hit(frame, bp_loc, internal_dict):
    """Callback for the dynamically-installed watchpoint on
    ``mainChunk+0x60``. Logs every write attempt to the secondary lookup
    tree root used by ``0x1001ba82c(mainChunk, \"1\")``.
    """
    thread = frame.GetThread()
    process = thread.GetProcess()
    frame0 = thread.GetFrameAtIndex(0)
    pc = frame0.GetPC()
    x0 = frame0.FindRegister("x0")
    x0v = 0
    if x0 and x0.IsValid():
        try:
            x0v = int(x0.GetValue(), 0)
        except (TypeError, ValueError):
            x0v = 0
    print(f"[hok016c26-subtree] write-hit pc=0x{pc:x} x0=0x{x0v:x}")
    return False


def snapshot_postcall_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python BP callback for post-call snapshots on the narrowed
    failure chain.

    We reuse this callback for multiple PCs:

    - ``0x10017f1dc``: right after ``bl 0x1001cd114`` inside
      ``0x10017f184``. Here x0 is the rootB-lookup result.
    - ``0x1001bd588``: right after ``bl 0x1001ba82c(mainChunk, \"1\")``
      inside ``0x1001bd448``.
    - ``0x10017f29c``: right after ``bl 0x1001bd448`` and right before the
      two stack-flag tests at ``sp+0x14`` / ``sp+0x2c``.
    - ``0x10432e074``: right after ``bl 0x10017f184`` inside
      ``0x10432dd98``. Here x0 is the final return of ``0x10017f184``.

    The callback prints x0/x19/x20/sp plus a few stack bytes around the
    soon-to-be-tested flag slots. On the first ``0x10017f1dc`` hit it also
    arms a dynamic watchpoint on ``mainChunk+0x60`` so we can prove whether
    the secondary subtree root ever gets populated later in the same run.
    """
    global _subtree_watch_installed

    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    pc = frame.GetPC()
    regs: dict[str, int] = {}
    for rn in ("x0", "x19", "x20", "sp"):
        reg = frame.FindRegister(rn)
        if reg and reg.IsValid():
            try:
                regs[rn] = int(reg.GetValue(), 0)
            except (TypeError, ValueError):
                regs[rn] = 0

    stack_preview = "<no-sp>"
    sp = regs.get("sp", 0)
    if sp:
        raw = _read_bytes(process, sp, 0x40)
        if raw is not None:
            stack_preview = raw.hex()

    extra = ""
    # At 0x10017f1dc x0 is the successful rootB->"main" lookup result.
    # Dump a few interesting fields from that returned object so we can
    # tell whether its internal +0x60 subtree (used by 0x1001ba82c for
    # the secondary lookup of key "1") is empty.
    if pc == 0x10017F1DC:
        obj = regs.get("x0", 0)
        if obj > 0x100000000:
            subtree_addr = obj + 0x60
            obj60 = _read_u64(process, subtree_addr)
            obje0 = _read_bytes(process, obj + 0xE0, 16)
            extra = (
                f" obj+0x60=0x{(obj60 or 0):x}"
                f" obj+0xe0[16]={_hex_dump(obje0)}"
            )
            if not _subtree_watch_installed:
                try:
                    import lldb  # type: ignore
                    err = lldb.SBError()
                    wp = target.WatchAddress(subtree_addr, 8, False, True, err)
                    if not err.Fail() and wp and wp.IsValid():
                        ok, cmd_err = _attach_watchpoint_callback(
                            target,
                            wp,
                            "hok016c26_lldb_rootb_key_watch.snapshot_subtree_watch_on_hit",
                        )
                        if ok:
                            _subtree_watch_installed = True
                            extra += f" subtree-wp=id{wp.GetID()}@0x{subtree_addr:x}"
                        else:
                            extra += f" subtree-wp-attach-failed={cmd_err!r}"
                    else:
                        extra += f" subtree-wp-install-failed={err.GetCString()!r}"
                except Exception as exc:
                    extra += f" subtree-wp-exc={exc!r}"

    print(
        f"[hok016c26-post] pc=0x{pc:x} x0=0x{regs.get('x0', 0):x} "
        f"x19=0x{regs.get('x19', 0):x} x20=0x{regs.get('x20', 0):x} "
        f"sp=0x{sp:x} stack40={stack_preview}{extra}"
    )
    return False  # auto-continue


def __lldb_init_module(debugger, internal_dict):
    print(
        "[hok016c26] loaded; use install_rootb_wide_watch + "
        "dump_node_key_on_hit as breakpoint / watchpoint callbacks."
    )
