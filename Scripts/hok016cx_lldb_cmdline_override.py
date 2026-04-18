"""HOK-016-C.X.1 LLDB helper: dynamic CmdLine seed override.

Load into LLDB via::

    command script import Scripts/hok016cx_lldb_cmdline_override.py
    script import hok016cx_lldb_cmdline_override as h; h.SEED = "empty"
    breakpoint set --shlib NGR --address 0x103a227a4 -N hok016cx_rewrite \
        --script-type python \
        -F hok016cx_lldb_cmdline_override.rewrite_cmdline_on_hit

The callback rewrites ``FCommandLine::CmdLine`` (unslid 0x10e20107a) to
a candidate seed value (UTF-16-LE + 2-byte null terminator), re-asserts
``FCommandLine::bCommandLineInitialized`` (0x10e201078) = 1, writes a
marker line to the transcript, and returns ``False`` (auto-continue).

Seed selection: set the module-level ``SEED`` global **before** the BP
fires. Valid values:

  - ``"empty"``       -> empty string (only ``\\x00\\x00`` terminator)
  - ``"project"``     -> ``"NGR"``
  - ``"ue4cmdfile"``  -> ``"../../../NGR/ue4commandline.txt"``
                         (points to the file actually present in iOS
                         cooked builds)
  - ``"uproject"``    -> ``"../../../NGR/NGR.uproject"``
                         (baseline / no-op control — matches HOK-015's
                         current seed value)

The callback is **one-shot** — it performs the rewrite on the first
successful hit (NGR main image mapped), and thereafter is no-op on
later hits, so it safely pairs with any downstream auto-continue BPs
that may share the thread.
"""

from __future__ import annotations

# Set by the LLDB launcher (see Scripts/hok016cx_ngr_seed_experiment.py
# which emits `script import hok016cx_lldb_cmdline_override as h; h.SEED = "empty"`
# as a pre-run command).
SEED = "empty"

# HOK-015 locator output (locked unslid addresses); __TEXT base is
# 0x100000000 on all observed NGR builds.
_NGR_TEXT_BASE_UNSLID = 0x100000000
_CMDLINE_BUFFER_UNSLID = 0x10e20107a
_BINITIALIZED_UNSLID = 0x10e201078

_SEED_CANDIDATES = {
    "empty": "",
    "project": "NGR",
    "ue4cmdfile": "../../../NGR/ue4commandline.txt",
    "uproject": "../../../NGR/NGR.uproject",
}

_done = False


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


def rewrite_cmdline_on_hit(frame, bp_loc, internal_dict):
    """LLDB Python breakpoint callback. Returns False (auto-continue)."""
    global _done
    import lldb  # type: ignore

    if _done:
        return False

    target = frame.GetThread().GetProcess().GetTarget()
    process = target.GetProcess()

    seed_str = _SEED_CANDIDATES.get(SEED)
    if seed_str is None:
        print(
            f"[hok016cx] unknown SEED={SEED!r}; "
            f"valid values: {sorted(_SEED_CANDIDATES)}"
        )
        _done = True
        return False

    slide = _resolve_ngr_slide(target)
    if slide is None:
        print(
            "[hok016cx] NGR main image not yet mapped; skipping rewrite. "
            "(callback will retry on next BP hit.)"
        )
        return False

    cmdline_addr = _CMDLINE_BUFFER_UNSLID + slide
    binit_addr = _BINITIALIZED_UNSLID + slide

    # Build seed payload: UTF-16-LE + 2-byte null terminator.
    seed_bytes = seed_str.encode("utf-16-le") + b"\x00\x00"
    # Zero the rest of the buffer tail so stale bytes from HOK-015's
    # preseed (e.g. "../../../NGR/NGR.uproject") don't bleed into
    # downstream readers. We cap the zero write to 256 bytes — enough
    # to cover any seed we'll try (< 64 TCHAR) without hammering the
    # full 32 KiB buffer on every BP hit.
    tail_zero_bytes = b"\x00" * max(256 - len(seed_bytes), 0)

    err = lldb.SBError()
    process.WriteMemory(cmdline_addr, seed_bytes + tail_zero_bytes, err)
    if err.Fail():
        print(
            f"[hok016cx] WriteMemory(cmdline) failed: {err.GetCString()!r}"
        )
        _done = True
        return False

    # Re-assert bInitialized = 1. HOK-015 already did this at PlayTools
    # constructor, but belt-and-suspenders: the callback runs much later
    # and if anyone cleared it in between the assertion prevents a
    # downstream FCommandLine fatal.
    err2 = lldb.SBError()
    process.WriteMemory(binit_addr, b"\x01", err2)
    if err2.Fail():
        print(
            f"[hok016cx] WriteMemory(bInitialized) failed: {err2.GetCString()!r}"
        )

    print(
        f"[hok016cx] rewrote FCommandLine::CmdLine @ 0x{cmdline_addr:x} "
        f"(slide=0x{slide:x}) to SEED={SEED!r} "
        f"({len(seed_bytes)} bytes UTF-16-LE)"
    )
    _done = True
    return False  # auto-continue


def __lldb_init_module(debugger, internal_dict):
    """LLDB reports module successfully loaded in the transcript."""
    print(
        f"[hok016cx] loaded; default SEED={SEED!r}. "
        "Override via: script import hok016cx_lldb_cmdline_override as h; h.SEED = \"...\""
    )
