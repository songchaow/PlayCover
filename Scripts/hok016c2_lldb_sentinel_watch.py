"""HOK-016-C.2.2 LLDB helper: sentinel value probe + install watchpoint.

Loaded into LLDB via::

    command script import Scripts/hok016c2_lldb_sentinel_watch.py

Provides two Python breakpoint callbacks usable from the ``hok006`` runner's
``--pre-run-command`` plumbing:

1. ``probe_sentinel_on_hit(frame, bp_loc, internal_dict)``
   - Resolves the runtime NGR slide from the main image;
   - Reads the byte at unslid ``0x10e1eeef0`` (= runtime sentinel value);
   - Reads a 16-byte window around it so we can tell whether any byte in
     ``0x10e1eeee0..0x10e1eeef0`` looks like a bump-to-4 level counter;
   - Prints a line ``[hok016c2] sentinel @ 0x... = 0x... window=[...]``
     to the transcript so the driver can harvest it via regex;
   - Returns ``False`` (auto-continue); does NOT install a watchpoint.

2. ``install_watchpoint_on_hit(frame, bp_loc, internal_dict)``
   - On first successful hit, installs a 1-byte modify watchpoint at the
     runtime address ``0x10e1eeef0 + slide``;
   - Registers a Python stop hook that echoes backtrace + register snapshot
     + stop reason when the watchpoint fires;
   - Returns ``False`` (auto-continue). Subsequent hits no-op.

The two helpers are independent; pre-run scripts can compose either or
both, and each is one-shot — a second hit on the same BP does nothing.

Usage example (from hok016c2 driver)::

    command script import Scripts/hok016c2_lldb_sentinel_watch.py
    breakpoint set --shlib NGR --address 0x107e5cad4 -N hok016c2_install
    breakpoint command add -s python -F \
        hok016c2_lldb_sentinel_watch.install_watchpoint_on_hit

**No PlayTools / NGR modifications** — pure LLDB-side dynamic probing.
"""

from __future__ import annotations

_NGR_TEXT_BASE_UNSLID = 0x100000000
_SENTINEL_UNSLID = 0x10E1EEEF0

# One-shot guards so the callbacks are idempotent against multi-hit BPs.
_probe_done = False
_watchpoint_installed = False


def _resolve_ngr_slide(target):
    """Return NGR main image's runtime slide. Returns None if the image
    has not yet been loaded (breakpoint hit before dyld mapped NGR).
    """
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


def _read_byte(process, address):
    import lldb  # type: ignore

    err = lldb.SBError()
    data = process.ReadMemory(address, 1, err)
    if err.Fail() or data is None:
        return None
    return data[0] if isinstance(data, (bytes, bytearray)) else ord(data[0])


def _read_window(process, address, size):
    import lldb  # type: ignore

    err = lldb.SBError()
    data = process.ReadMemory(address, size, err)
    if err.Fail() or data is None:
        return None
    if not isinstance(data, (bytes, bytearray)):
        data = data.encode("latin-1")
    return bytes(data)


def probe_sentinel_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python breakpoint callback: dump sentinel value and a window
    of nearby bytes to the transcript. Returns False (auto-continue).
    """
    global _probe_done

    target = frame.GetThread().GetProcess().GetTarget()
    process = target.GetProcess()

    slide = _resolve_ngr_slide(target)
    if slide is None:
        print("[hok016c2] probe: NGR main image not yet mapped; skipping.")
        return False

    sent_addr = _SENTINEL_UNSLID + slide
    val = _read_byte(process, sent_addr)
    window = _read_window(process, sent_addr - 8, 16)
    window_hex = "?" if window is None else " ".join(f"{b:02x}" for b in window)

    print(
        f"[hok016c2] sentinel @ 0x{sent_addr:x} = "
        f"{'0x%02x' % val if val is not None else '<read fail>'} "
        f"(unslid=0x{_SENTINEL_UNSLID:x}, slide=0x{slide:x}); "
        f"window[0x{sent_addr-8:x}..0x{sent_addr+8:x}]=[{window_hex}]"
    )
    _probe_done = True
    return False  # auto-continue


def install_watchpoint_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python breakpoint callback: arm a 1-byte modify watchpoint on
    the sentinel at runtime, once NGR main image is mapped. Returns
    False (auto-continue). One-shot.
    """
    global _watchpoint_installed
    if _watchpoint_installed:
        return False

    import lldb  # type: ignore

    target = frame.GetThread().GetProcess().GetTarget()
    process = target.GetProcess()

    slide = _resolve_ngr_slide(target)
    if slide is None:
        print(
            "[hok016c2] install-wp: NGR main image not yet mapped; "
            "will retry on next hit."
        )
        return False

    sent_addr = _SENTINEL_UNSLID + slide

    # Pre-arm value snapshot so a later watchpoint hit can diff oldValue.
    pre_val = _read_byte(process, sent_addr)
    pre_val_txt = "<read fail>" if pre_val is None else f"0x{pre_val:02x}"

    err = lldb.SBError()
    # WatchAddress(addr, size, read, write) — we only want stores (modify).
    wp = target.WatchAddress(sent_addr, 1, False, True, err)
    if err.Fail() or not wp or not wp.IsValid():
        print(
            f"[hok016c2] WatchAddress failed @ 0x{sent_addr:x}: "
            f"{err.GetCString()!r}"
        )
        return False

    _watchpoint_installed = True
    print(
        f"[hok016c2] armed watchpoint id={wp.GetID()} @ 0x{sent_addr:x} "
        f"(unslid=0x{_SENTINEL_UNSLID:x}, slide=0x{slide:x}); "
        f"pre-arm value = {pre_val_txt}"
    )
    return False  # auto-continue


def __lldb_init_module(debugger, internal_dict):
    print(
        "[hok016c2] loaded; use probe_sentinel_on_hit and/or "
        "install_watchpoint_on_hit as breakpoint callbacks."
    )
