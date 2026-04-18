#!/usr/bin/env python3
"""HOK-016-C.2.3 driver: step into 0x108878534 to pinpoint the true
readiness-B failure origin.

Background (HOK-016-C.2.2 discovery):
  - sentinel 0x10e1eeef0 runtime value = **0x05** (not 0!), so
    0x108878534 +48/56 `ldrb/b.lo` is NOT the early exit — it's a guard
    that, when sentinel >= 4, *executes* `bl 0x104331a90` (the cleanup
    or flush call) and then falls through.
  - 0x108878534 only spans 0x108878534..0x1088786ec (~440 bytes, not
    544 as claimed); +352 `bl 0x10432dd98` is the last bl before the
    dispositive `tbz w0,#0, +84 (0x1088786f0)` at +360.
  - No earlier conditional branch in the 0..352 region can bail out
    with w0=0 when sentinel=5 — so the Create-Failed source MUST be
    `0x10432dd98` returning 0.

This driver sets three BPs to validate:

  1. `0x108878694` (+352): immediately before `bl 0x10432dd98` — prove
     the call is reached and log inputs (x0, x1, x2, x3 = args).
  2. `0x108878698` (+356): immediately after the bl — log w0 (the
     return value = `tbz` input).
  3. `0x108878124` (+1364 in 0x108877bd0, the failure sink): final
     hard-stop + bt dump (same as HOK-016-C.1).

Plus probe at +912 tbz (HOK-016-C.1 baseline) and NGR main entry BP to
also record the sentinel value as extra evidence.

Output: `build/hok-016c2-step-into-readinessB.json`.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
LLDB_HELPER_PATH = SCRIPT_DIR / "hok016c2_lldb_sentinel_watch.py"

# Addresses locked by HOK-016-A/B/C.1/C.2.2.
BP_BEFORE_BL_10432DD98 = "0x108878694"  # +352 in 0x108878534
BP_AFTER_BL_10432DD98  = "0x108878698"  # +356 in 0x108878534
BP_BEFORE_TBZ_912      = "0x108877f60"  # +912 in 0x108877bd0 (reporter's gate)
BP_FAILURE_SINK        = "0x108878124"  # +1364 in 0x108877bd0
# Entry of the inner function we suspect returns 0:
BP_AT_10432DD98_ENTRY  = "0x10432dd98"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.3: step-into 0x108878534 to attribute readiness-B "
            "failure to the `bl 0x10432dd98` call"
        )
    )
    ap.add_argument("--lldb-timeout", type=float, default=25.0)
    ap.add_argument("--settle-seconds", type=float, default=22.0)
    ap.add_argument(
        "--output",
        default="build/hok-016c2-step-into-readinessB.json",
        help="hok006 runner report output path",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    pre_run_commands: list[str] = [
        # Import LLDB helper for sentinel probe callback.
        f"command script import {LLDB_HELPER_PATH}",
        # Probe sentinel at +912 tbz (the outer gate, already known to
        # see w0=0). Keep this BP present so we carry forward baseline
        # parity with HOK-016-C.1.
        f"breakpoint set --shlib NGR --address {BP_BEFORE_TBZ_912} "
        f"-N hok016c2_probe_at_912 --auto-continue true",
        "breakpoint command add -s python "
        "-F hok016c2_lldb_sentinel_watch.probe_sentinel_on_hit",
        # BP #2: before `bl 0x10432dd98` — capture arg registers.
        f"breakpoint set --shlib NGR --address {BP_BEFORE_BL_10432DD98} "
        f"-N hok016c2_before_bl_10432dd98 "
        f"-C 'register read x0 x1 x2 x3 x22' "
        f"--auto-continue true",
        # BP #3: after `bl 0x10432dd98` — capture return value.
        f"breakpoint set --shlib NGR --address {BP_AFTER_BL_10432DD98} "
        f"-N hok016c2_after_bl_10432dd98 "
        f"-C 'register read x0' "
        f"--auto-continue true",
        # BP #4: entry of 0x10432dd98 itself — prove whether the call
        # actually dispatches here. Probe registers.
        f"breakpoint set --shlib NGR --address {BP_AT_10432DD98_ENTRY} "
        f"-N hok016c2_at_10432dd98_entry "
        f"-C 'register read x0 x1 x2 x3' "
        f"--auto-continue true",
        # BP #5: failure sink hard-stop (HOK-016-C.1 parity).
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c2_probe_at_failsink "
        f"-C 'thread backtrace' "
        f"-C 'register read x19 x24'",
    ]

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        "--output", str(output_path),
    ]
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-C.2.3 step-into readiness B:")
    print(f"  +352 before bl 0x10432dd98: {BP_BEFORE_BL_10432DD98}")
    print(f"  +356 after  bl 0x10432dd98: {BP_AFTER_BL_10432DD98}")
    print(f"  entry 0x10432dd98         : {BP_AT_10432DD98_ENTRY}")
    print(f"  +912 tbz (outer gate)     : {BP_BEFORE_TBZ_912}")
    print(f"  +1364 failure sink        : {BP_FAILURE_SINK}")
    print(f"  output: {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
