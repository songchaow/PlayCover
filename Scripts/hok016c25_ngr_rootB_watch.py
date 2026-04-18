#!/usr/bin/env python3
"""HOK-016-C.2.5 rootB writer live-trace.

Context (see HOK-016-qts-fs-create-failed.md C.2.4 section):

* rootB @ 0x10e184b18 is a Qtsk red-black tree. At the moment the
  readiness-B reporter is entered, rootB is still in its empty sentinel
  self-loop state (header ``<ptr>,<ptr>,1,0,...``), so the
  ``bl 0x1001cd114`` string-key lookup for ``"main"`` returns 0 and the
  Create Failed path triggers.
* The C.2.2-style writer-scan found only 1 **direct** store-to-absolute
  (``0x1001cf314 str x8, [x1]``) which is the static-constructor's own
  "root->self" sentinel initialization — not an actual insert.
* The C.2.5 xref scan enumerated 94 adrp+add pairs that materialize
  0x10e184b18 into a register; 93 of them put it into x0 (first arg),
  which strongly suggests insert/emplace is done by **calling a helper
  with x0=rootB** rather than writing inline.

This driver arms a **1-byte modify watchpoint** on the first 8 bytes of
rootB (``0x10e184b18..0x10e184b20``) right at NGR's ``main`` entry. By
that point the dyld static constructors (including ``0x1001cf20c``
which writes the sentinel self-loop) have already finished, so any
subsequent store is **the actual insert** we want to attribute.

Each watchpoint hit prints a stop reason + backtrace + register read,
then auto-continues so later hits are also captured.

Output: ``build/hok-016c25-rootB-watch.json`` (hok006 runner schema).
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

# NGR main (unslid) — all dyld initializers have run by now.
NGR_MAIN_ENTRY = "0x107e5cad4"
ROOTB_UNSLID = "0x10e184b18"
# readiness-B failure sink — hard-stop so we can inspect final state.
BP_FAILURE_SINK = "0x108878124"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.5: live-trace rootB writers by arming a watchpoint "
            "at NGR main entry, so only post-dyld-static-init stores are "
            "captured."
        )
    )
    ap.add_argument("--lldb-timeout", type=float, default=40.0)
    ap.add_argument("--settle-seconds", type=float, default=32.0)
    ap.add_argument(
        "--output",
        default="build/hok-016c25-rootB-watch.json",
        help="hok006 runner report output path",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    # We use the LLDB-python trick that was already proven in the HOK-016-C.X
    # series: craft a breakpoint at NGR main entry, have its callback install
    # a watchpoint on rootB, then let the process continue. Every subsequent
    # watchpoint hit auto-continues after dumping bt + registers.
    pre_run_commands: list[str] = [
        # 1) BP at NGR main entry to arm the rootB watchpoint.
        f"breakpoint set --shlib NGR --address {NGR_MAIN_ENTRY} "
        f"-N hok016c25_main_entry "
        # We arm an 8-byte modify watchpoint; the first qword of rootB is the
        # red-black tree "root" pointer which any insert must touch.
        f"-C 'watchpoint set expression -w write -s 8 -- {ROOTB_UNSLID}' "
        f"-C 'continue' "
        f"--auto-continue true --one-shot true",
        # 2) failure-sink hard stop — so the run always terminates at the
        # reporter Create Failed site (same as C.2.3/C.2.4 parity).
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c25_failure_sink "
        f"-C 'thread backtrace' "
        f"-C 'register read x19 x24'",
    ]

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        # HOK-012 style plumbing so watchpoint hits + stop reasons are
        # actually harvested into the structured JSON (watchpoint mode).
        "--watch-address", ROOTB_UNSLID,
        "--watch-size", "8",
        "--defer-watchpoint-install",
        # Leave the writer-address empty so hok006 does NOT auto-append its
        # own "writer-BP -> watchpoint" line (we do that via the main-entry
        # BP above).
        "--writer-address", "",
        "--output", str(output_path),
    ]
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-C.2.5 rootB writer watch:")
    print(f"  arm watchpoint on {ROOTB_UNSLID} at NGR main entry "
          f"({NGR_MAIN_ENTRY})")
    print(f"  failure sink hard-stop: {BP_FAILURE_SINK}")
    print(f"  output: {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
