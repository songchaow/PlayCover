#!/usr/bin/env python3
"""HOK-016-C.2.2 driver: sentinel value probe + optional watchpoint capture.

Two modes (selected via ``--mode``):

1. ``probe`` (default): at each of the three known HOK-016-C.1 BP sites
   (``+900`` tbz / ``+912`` tbz / ``+1364`` failure sink), dump the runtime
   value of sentinel ``0x10e1eeef0`` + a 16-byte window. Also reads the
   byte once more at the failure sink (``+1364``) before the legacy stop
   handler runs.

   Purpose: determine whether the sentinel is ``= 0`` (BSS default, never
   written) or ``!= 0`` (written by someone but not to the required ``>= 4``
   level) at the moment the QtsFS readiness-B gate fails.

2. ``watchpoint``: in addition to the probe points above, arm a 1-byte
   modify watchpoint on the sentinel at **NGR main entry** (unslid
   ``0x107e5cad4``). Any subsequent store to the sentinel while the child
   runs will trigger a stop and full backtrace dump, revealing the writer
   function / image.

Per the LLDB-API quirks documented in HOK-016-C.X.1 (Dashboard 高频复用
经验)::

  - BP callback `script -F` is not accepted inline on `breakpoint set`; it
    must be split into two adjacent commands.
  - `breakpoint command add` implicitly targets the LAST created BP.
  - `register read` BP callback output is echoed as `(lldb)  register
    read x0` (two spaces) — use that anchor for regex harvest.

Output: ``build/hok-016c2-sentinel-probe.json`` or
``build/hok-016c2-sentinel-watch.json`` depending on mode.

Usage::

    python3 Scripts/hok016c2_ngr_sentinel_probe.py --mode probe
    python3 Scripts/hok016c2_ngr_sentinel_probe.py --mode watchpoint
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
LLDB_HELPER_PATH = SCRIPT_DIR / "hok016c2_lldb_sentinel_watch.py"

# Addresses locked by HOK-016-A/B/C.1.
BP_ADDR_BEFORE_TBZ_900 = "0x108877f54"   # +900 in 0x108877bd0
BP_ADDR_BEFORE_TBZ_912 = "0x108877f60"   # +912 in 0x108877bd0
BP_ADDR_FAILURE_SINK   = "0x108878124"   # +1364 in 0x108877bd0
# LC_MAIN entry (unslid) — NGR's `main()`; all dyld initializers have run.
NGR_MAIN_ENTRY         = "0x107e5cad4"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.2: probe sentinel 0x10e1eeef0 at QtsFS readiness "
            "check points and/or arm watchpoint to catch writer"
        )
    )
    ap.add_argument(
        "--mode",
        choices=("probe", "watchpoint"),
        default="probe",
        help=(
            "probe: dump sentinel byte + window at each BP (fast). "
            "watchpoint: additionally install modify watchpoint at NGR main "
            "entry to capture any subsequent write to sentinel."
        ),
    )
    ap.add_argument("--lldb-timeout", type=float, default=25.0)
    ap.add_argument("--settle-seconds", type=float, default=22.0)
    ap.add_argument(
        "--output",
        default=None,
        help="hok006 runner report output path (default depends on mode)",
    )
    ap.add_argument(
        "--run-build-install",
        action="store_true",
        help="run BuildScripts/build_and_install.sh before launch (default: skip)",
    )
    return ap


def _pre_run_commands_probe() -> list[str]:
    # Import helper once; then three probe BPs, one per site.
    cmds: list[str] = [
        f"command script import {LLDB_HELPER_PATH}",
        # +900 tbz — readiness A point; auto-continue after callback fires.
        f"breakpoint set --shlib NGR --address {BP_ADDR_BEFORE_TBZ_900} "
        f"-N hok016c2_probe_at_900 --auto-continue true",
        "breakpoint command add -s python "
        "-F hok016c2_lldb_sentinel_watch.probe_sentinel_on_hit",
        # +912 tbz — readiness B point (the failing gate).
        f"breakpoint set --shlib NGR --address {BP_ADDR_BEFORE_TBZ_912} "
        f"-N hok016c2_probe_at_912 --auto-continue true",
        "breakpoint command add -s python "
        "-F hok016c2_lldb_sentinel_watch.probe_sentinel_on_hit",
        # +1364 failure sink — hard-stop BP; dump bt + register.
        # No Python probe callback here because `breakpoint command add
        # -s python` would *replace* the shell `-C` callback list and
        # lose the `thread backtrace` / `register read x19 x24` output
        # we rely on for ground-truth backtrace harvest. The +912 probe
        # (one instruction before this +1364 sink) already captured the
        # sentinel value in the same run, so we don't need an extra
        # probe at +1364.
        f"breakpoint set --shlib NGR --address {BP_ADDR_FAILURE_SINK} "
        f"-N hok016c2_probe_at_failsink -C 'thread backtrace' "
        f"-C 'register read x19 x24'",
    ]
    return cmds


def _pre_run_commands_watchpoint() -> list[str]:
    # Combine probe (3 sites) with an NGR-main-entry BP that arms the
    # sentinel watchpoint. Probe fires at each tbz as in probe mode, plus
    # the watchpoint triggers an extra stop event if any code path writes
    # the sentinel after main entry.
    cmds = _pre_run_commands_probe()
    cmds.extend([
        # Install watchpoint at NGR main entry.
        f"breakpoint set --shlib NGR --address {NGR_MAIN_ENTRY} "
        f"-N hok016c2_install_wp --auto-continue true",
        "breakpoint command add -s python "
        "-F hok016c2_lldb_sentinel_watch.install_watchpoint_on_hit",
    ])
    return cmds


def main() -> int:
    args = build_parser().parse_args()

    default_output = (
        "build/hok-016c2-sentinel-probe.json"
        if args.mode == "probe"
        else "build/hok-016c2-sentinel-watch.json"
    )
    output_path = Path(args.output or default_output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    if args.mode == "probe":
        pre_run_commands = _pre_run_commands_probe()
    else:
        pre_run_commands = _pre_run_commands_watchpoint()

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        "--output", str(output_path),
    ]
    if not args.run_build_install:
        runner_cmd.append("--skip-build-install")
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print(f"HOK-016-C.2.2 mode={args.mode}")
    print(f"  probe points: +900 tbz (0x{int(BP_ADDR_BEFORE_TBZ_900,16):x}) / "
          f"+912 tbz (0x{int(BP_ADDR_BEFORE_TBZ_912,16):x}) / "
          f"+1364 fail sink (0x{int(BP_ADDR_FAILURE_SINK,16):x})")
    if args.mode == "watchpoint":
        print(f"  watchpoint install at NGR main entry "
              f"(0x{int(NGR_MAIN_ENTRY,16):x})")
    print(f"  output: {output_path}")
    print("invoking hok006 runner:")
    print("  " + " ".join(runner_cmd))
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
