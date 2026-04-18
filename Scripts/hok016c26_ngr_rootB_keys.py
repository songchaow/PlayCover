#!/usr/bin/env python3
"""HOK-016-C.2.6 rootB node-key watch driver.

Purpose
-------
C.2.5 confirmed that rootB ``0x10e184b18`` gets two insert-type writes
during the reporter call chain (PC at ``0x1001cf020`` inside the Qtsk
red-black tree insert helper at ``0x1001cef38``); however C.2.5 did
**not** dump the key of each inserted node. So we still don't know
whether either of the 2 inserts actually was the ``"main"`` chunk that
``bl 0x1001cd114`` is trying to find.

This driver wraps ``hok006_ngr_lldb_runner.py`` and, via
``--pre-run-command`` plumbing:

1. Imports ``Scripts/hok016c26_lldb_rootb_key_watch.py``.
2. At NGR ``main`` entry (unslid ``0x107e5cad4``), installs a wide
   64-byte modify watchpoint on rootB via Python callback.
3. Attaches a watchpoint command using the ``dump_node_key_on_hit``
   Python callback that, on every hit, prints:
   - register snapshot (x19..x24)
   - 64-byte dump of rootB
   - the candidate new-node key string (via node[+0x10] and x23 direct
     paths)
   - top 6 backtrace frames
   then auto-continues.
4. As a safety net, hard-stops at the readiness-B failure sink
   ``0x108878124`` so the run always terminates deterministically.

Output: ``build/hok-016c26-rootB-keys.json`` (hok006 runner schema).

No NGR / PlayTools modifications.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

NGR_MAIN_ENTRY = "0x107e5cad4"
ROOTB_UNSLID = "0x10e184b18"
BP_FAILURE_SINK = "0x108878124"

# Lookup helper called by 0x10017f184 with (x0=rootB, x1=key, w2=1).
# Every call is a "does rootB contain this key?" probe. We BP on entry
# and dump x0/x1/rootB-header so we can correlate insert vs lookup.
BP_LOOKUP_HELPER = "0x1001cd114"
# Right after the rootB lookup returns inside 0x10017f184.
BP_F184_AFTER_LOOKUP = "0x10017f1dc"
# Right after 0x1001ba82c(mainChunk, "1") returns inside 0x1001bd448.
BP_BD448_AFTER_LOOKUP1 = "0x1001bd588"
# Right after 0x1001bd448 returns, before sp+0x14 / sp+0x2c flags are tested.
BP_F184_BEFORE_FLAG_TESTS = "0x10017f29c"
# Right after 0x10017f184 returns to 0x10432dd98.
BP_DD98_AFTER_F184 = "0x10432e074"

# Absolute path so LLDB's `command script import` always resolves, regardless
# of the child process's CWD (which is *not* the repo root).
HELPER_MODULE = str(SCRIPT_DIR / "hok016c26_lldb_rootb_key_watch.py")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.6: watchpoint on rootB with per-hit key dump "
            "to identify which (if any) insert registers key \"main\"."
        )
    )
    ap.add_argument("--lldb-timeout", type=float, default=45.0)
    ap.add_argument("--settle-seconds", type=float, default=35.0)
    ap.add_argument(
        "--output",
        default="build/hok-016c26-rootB-keys.json",
        help="hok006 runner report output path",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    pre_run_commands: list[str] = [
        # 1) Load the Python helper module into LLDB.
        f"command script import {HELPER_MODULE}",
        # 2) BP at NGR main entry → install the rootB watchpoint AND
        #    attach the per-hit key-dump callback to it (done inside the
        #    `install_rootb_wide_watch` callback via
        #    `watchpoint command add <id>` driven from within Python).
        f"breakpoint set --shlib NGR --address {NGR_MAIN_ENTRY} "
        f"-N hok016c26_main_entry --auto-continue true --one-shot true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.install_rootb_wide_watch",
        # 3) BP at the lookup helper entry; log every ``bl 0x1001cd114
        #    (rootB, key, w2=1)`` with its key decode and rootB's current
        #    header — critical for proving whether rootB already contains
        #    "main" at lookup time.
        f"breakpoint set --shlib NGR --address {BP_LOOKUP_HELPER} "
        f"-N hok016c26_lookup_entry --auto-continue true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.snapshot_rootb_on_hit",
        # 4) Post-call narrowing points on the actual failing chain.
        f"breakpoint set --shlib NGR --address {BP_F184_AFTER_LOOKUP} "
        f"-N hok016c26_f184_after_lookup --auto-continue true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.snapshot_postcall_on_hit",
        f"breakpoint set --shlib NGR --address {BP_BD448_AFTER_LOOKUP1} "
        f"-N hok016c26_bd448_after_lookup1 --auto-continue true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.snapshot_postcall_on_hit",
        f"breakpoint set --shlib NGR --address {BP_F184_BEFORE_FLAG_TESTS} "
        f"-N hok016c26_f184_before_flag_tests --auto-continue true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.snapshot_postcall_on_hit",
        f"breakpoint set --shlib NGR --address {BP_DD98_AFTER_F184} "
        f"-N hok016c26_dd98_after_f184 --auto-continue true",
        "breakpoint command add -s python -F "
        "hok016c26_lldb_rootb_key_watch.snapshot_postcall_on_hit",
        # 5) Readiness-B failure sink hard stop (no extra callbacks, so
        #    we inherit hok006's built-in backtrace capture).
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c26_failure_sink "
        f"-C 'thread backtrace' "
        f"-C 'register read x19 x24'",
    ]

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        # We do NOT want hok006 to auto-install its own watchpoint — we
        # install the watchpoint ourselves from the main-entry BP so the
        # `watchpoint command add 1` numbering is stable.
        "--output", str(output_path),
    ]
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-C.2.6 rootB node-key watch:")
    print(f"  arm 64-byte watchpoint on {ROOTB_UNSLID} at NGR main entry "
          f"({NGR_MAIN_ENTRY})")
    print(f"  dump candidate key on every hit (via x21/x22/x23 heuristics)")
    print(f"  failure sink hard-stop: {BP_FAILURE_SINK}")
    print(f"  output: {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
