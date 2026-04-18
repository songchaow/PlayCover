#!/usr/bin/env python3
"""HOK-016-C.2.4 driver: attribute readiness-B failure inside
``0x10017f3c8`` to the specific lookup call that returns 0 on macOS.

Background (see ``LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md``
HOK-016-C.2.3 section):

* ``0x108878534 +352 bl 0x10432dd98`` returns 0 on macOS (confirmed by
  ``Scripts/hok016c2_ngr_step_into_readinessB.py``).
* Inside ``0x10432dd98``, the decisive call is
  ``+412 bl 0x10017f3c8(w0=[sp+0x14], w1=0, w2=0)`` whose w0 controls
  the outer ``tbz w0,#0`` at +416.
* ``0x10017f3c8`` itself is a lookup + acquire helper against two
  ``__common`` globals:

  1. ``[sp+0x60] = find_int(root=*(0x10e1849f0), key=x1)`` via
     ``bl 0x1001ac168``; NULL result -> fail_slot_1 @ 0x10017f658.
  2. If non-NULL: ``x0 = find_str(root=0x10e184b18, key=[sp+0x60]+0x10, w2=1)``
     via ``bl 0x1001cd114``; NULL result -> fail_slot_2 @ 0x10017f624.

This driver installs LLDB Python-callback BPs at:

| ``+0x00`` (0x10017f3c8)  | probe_inner_entry    | inputs (x0=key, x1=0, x2=0) |
| ``+0x44`` (0x10017f40c)  | probe_before_bl1     | x0=rootA, x1=key, x8=out     |
| ``+0x48`` (0x10017f410)  | probe_after_bl1      | [sp+0x60] = entry ptr        |
| ``+0x60`` (0x10017f428)  | probe_before_bl2     | x0=rootB, x1=entry+0x10 key  |
| ``+0x64`` (0x10017f42c)  | probe_after_bl2      | x0 return                    |
| ``fail_slot_1`` 0x10017f658 | probe_fail_slot_1 | lookup A miss                |
| ``fail_slot_2`` 0x10017f624 | probe_fail_slot_2 | lookup B miss                |

Plus the HOK-016-C.2.3 shell-callback BPs at the readiness-B boundary
(``0x108878694`` / ``0x108878698`` / ``0x10432dd98`` / failure sink) so
the run produces a full picture from outer ``bl`` down to inner
lookup miss.

Output: ``build/hok-016c24-readinessB-inner-args.json`` (hok006 runner
schema). The goal is to capture the ``[hok016c24] ...`` transcript
lines with the real UTF-16-LE FString content or bare key pointers so
we can decide whether HOK-016-C.5 (path fixup) or HOK-016-C.4 (local
interpose) is the right next step.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
LLDB_HELPER_PATH = SCRIPT_DIR / "hok016c24_lldb_inner_probes.py"

# Readiness-B boundary (HOK-016-C.2.3 parity; kept so both runs share
# transcript conventions).
BP_BEFORE_BL_10432DD98 = "0x108878694"
BP_AFTER_BL_10432DD98 = "0x108878698"
BP_AT_10432DD98_ENTRY = "0x10432dd98"
BP_FAILURE_SINK = "0x108878124"

# Inner helper (0x10017f3c8) probes — kept so we can **prove** the
# function is unreachable in this run (0-hit => outer early-exit before
# reaching it).
BP_INNER_ENTRY        = "0x10017f3c8"  # stp x28,x27
BP_INNER_BEFORE_BL1   = "0x10017f40c"  # bl 0x1001ac168
BP_INNER_AFTER_BL1    = "0x10017f410"  # ldr x8,[sp,#0x60]
BP_INNER_BEFORE_BL2   = "0x10017f428"  # bl 0x1001cd114
BP_INNER_AFTER_BL2    = "0x10017f42c"  # mov x21,x0
BP_INNER_FAIL_SLOT_1  = "0x10017f658"  # cbz x8 target after bl1
BP_INNER_FAIL_SLOT_2  = "0x10017f624"  # cbz x0 target after bl2

# Outer (0x10432dd98) internal probes — these are the **new** ones added
# after the first C.2.4 run revealed the 0x10017f3c8 BPs never fire.
BP_OUTER_ENTRY            = "0x10432dd98"  # duplicates BP_AT_10432DD98_ENTRY
BP_OUTER_AFTER_PRINTF     = "0x10432dddc"  # ldr w22, [sp, #0x40]
BP_OUTER_BEFORE_BL_B734   = "0x10432de04"  # bl 0x10432b734
BP_OUTER_AFTER_BL_B734    = "0x10432de08"  # cbz w0, ...
BP_OUTER_EARLY_EXIT       = "0x10432e060"  # mov w19, #0x0 (early exit B)

# C.2.4 v3: additions to cover the de10 .. df30 corridor (the v2 blind
# spot which the b.eq 0x10432df8c branch reroutes into).
BP_OUTER_AFTER_VTABLE1    = "0x10432deb4"  # mov x21, x0 (post-blr x8 #1)
BP_OUTER_AFTER_VTABLE2    = "0x10432ded8"  # mov x20, x0 (post-blr x8 #2)
BP_OUTER_AT_CBNZW21       = "0x10432deec"  # cbnz w21, 0x10432dfac
BP_OUTER_AT_CBZW20        = "0x10432df0c"  # cbz w20, 0x10432df34
BP_OUTER_BEFORE_BL_FAA0   = "0x10432df18"  # bl 0x10017faa0
BP_OUTER_AFTER_BL_FAA0    = "0x10432df1c"  # cbnz w0, 0x10432dfec
BP_OUTER_BEFORE_BL_F3C8   = "0x10432df28"  # bl 0x10017f3c8 (outer call site)
BP_OUTER_AFTER_BL_F3C8    = "0x10432df30"  # tbz w0,#0, 0x10432e014
BP_OUTER_AT_DFEC          = "0x10432dfec"  # target of cbnz after faa0
BP_OUTER_AT_E014          = "0x10432e014"  # target of tbz after f3c8
BP_OUTER_FAIL_EXIT_A      = "0x10432e058"  # mov w19, #0x0 (fail path A)
BP_OUTER_SUCCESS_MARKER   = "0x10432df34"  # mov w19, #0x1
BP_OUTER_EPILOGUE         = "0x10432df74"  # mov x0, x19 (function return)

# C.2.4 v4: the v3 run revealed the real failure decision is at
# ``bl 0x10017f184`` (not 0x10017f3c8). Add focused probes around that
# callsite + its inner lookup pattern.
BP_OUTER_AT_E06C          = "0x10432e06c"  # target of cbz w20 at 0x10432dfac
BP_OUTER_AFTER_BL_F184    = "0x10432e074"  # tbnz w0,#0 site
BP_F184_ENTRY             = "0x10017f184"
BP_F184_AFTER_BL1         = "0x10017f1c0"  # ldr x8,[sp,#0x20]
BP_F184_BEFORE_BL2        = "0x10017f1d8"  # bl 0x1001cd114
BP_F184_AFTER_BL2         = "0x10017f1dc"  # mov x19, x0
BP_F184_FAIL_SLOT_1       = "0x10017f2f0"  # cbz x8 target (lookup A miss)
BP_F184_FAIL_SLOT_2       = "0x10017f2bc"  # cbz x0 target (lookup B miss)

# Even deeper (0x10432b734) internal probes.
BP_B734_ENTRY             = "0x10432b734"
BP_B734_AFTER_BL_B2A8     = "0x10432b758"  # cbz w0 after bl 0x10432b2a8
BP_B734_AFTER_BL_BA84     = "0x10432b770"  # adrp after bl 0x10432ba84

# Each Python-callback BP must be created via two consecutive LLDB
# commands (HOK-016-C.X踩坑): ``breakpoint set`` then
# ``breakpoint command add -s python -F <module.func>`` with no other
# ``breakpoint set`` in between.
_PY_PROBES: list[tuple[str, str, str]] = [
    # Inner helper (retained for reachability evidence; v2 showed 0
    # hits, so if v3 also shows 0 hits this confirms the failure is
    # attributable entirely to the 10432dd98 de10..df30 corridor).
    (BP_INNER_ENTRY,      "hok016c24_inner_entry",      "hok016c24_lldb_inner_probes.probe_inner_entry"),
    (BP_INNER_BEFORE_BL1, "hok016c24_before_bl1",       "hok016c24_lldb_inner_probes.probe_before_bl1"),
    (BP_INNER_AFTER_BL1,  "hok016c24_after_bl1",        "hok016c24_lldb_inner_probes.probe_after_bl1"),
    (BP_INNER_BEFORE_BL2, "hok016c24_before_bl2",       "hok016c24_lldb_inner_probes.probe_before_bl2"),
    (BP_INNER_AFTER_BL2,  "hok016c24_after_bl2",        "hok016c24_lldb_inner_probes.probe_after_bl2"),
    (BP_INNER_FAIL_SLOT_1,"hok016c24_inner_fail_slot_1","hok016c24_lldb_inner_probes.probe_fail_slot_1"),
    (BP_INNER_FAIL_SLOT_2,"hok016c24_inner_fail_slot_2","hok016c24_lldb_inner_probes.probe_fail_slot_2"),
    # Outer (0x10432dd98) early-exit attribution — v2 probes.
    (BP_OUTER_ENTRY,        "hok016c24_outer_entry",        "hok016c24_lldb_inner_probes.probe_10432dd98_entry"),
    (BP_OUTER_AFTER_PRINTF, "hok016c24_outer_after_printf", "hok016c24_lldb_inner_probes.probe_10432dd98_after_printf"),
    (BP_OUTER_BEFORE_BL_B734, "hok016c24_outer_before_bl_b734", "hok016c24_lldb_inner_probes.probe_10432dd98_before_bl_b734"),
    (BP_OUTER_AFTER_BL_B734,  "hok016c24_outer_after_bl_b734",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_bl_b734"),
    (BP_OUTER_EARLY_EXIT,     "hok016c24_outer_early_exit",     "hok016c24_lldb_inner_probes.probe_10432dd98_early_exit"),
    # v3: de10..df30 corridor probes.
    (BP_OUTER_AFTER_VTABLE1,  "hok016c24_outer_after_vtable1",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_vtable1"),
    (BP_OUTER_AFTER_VTABLE2,  "hok016c24_outer_after_vtable2",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_vtable2"),
    (BP_OUTER_AT_CBNZW21,     "hok016c24_outer_at_cbnzw21",     "hok016c24_lldb_inner_probes.probe_10432dd98_at_cbnzw21"),
    (BP_OUTER_AT_CBZW20,      "hok016c24_outer_at_cbzw20",      "hok016c24_lldb_inner_probes.probe_10432dd98_at_cbzw20"),
    (BP_OUTER_BEFORE_BL_FAA0, "hok016c24_outer_before_bl_faa0", "hok016c24_lldb_inner_probes.probe_10432dd98_before_bl_faa0"),
    (BP_OUTER_AFTER_BL_FAA0,  "hok016c24_outer_after_bl_faa0",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_bl_faa0"),
    (BP_OUTER_BEFORE_BL_F3C8, "hok016c24_outer_before_bl_f3c8", "hok016c24_lldb_inner_probes.probe_10432dd98_before_bl_f3c8"),
    (BP_OUTER_AFTER_BL_F3C8,  "hok016c24_outer_after_bl_f3c8",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_bl_f3c8"),
    (BP_OUTER_AT_DFEC,        "hok016c24_outer_at_dfec",        "hok016c24_lldb_inner_probes.probe_10432dd98_at_dfec"),
    (BP_OUTER_AT_E014,        "hok016c24_outer_at_e014",        "hok016c24_lldb_inner_probes.probe_10432dd98_at_e014"),
    (BP_OUTER_FAIL_EXIT_A,    "hok016c24_outer_fail_exit_a",    "hok016c24_lldb_inner_probes.probe_10432dd98_fail_exit_A"),
    (BP_OUTER_SUCCESS_MARKER, "hok016c24_outer_success",        "hok016c24_lldb_inner_probes.probe_10432dd98_success_marker"),
    (BP_OUTER_EPILOGUE,       "hok016c24_outer_epilogue",       "hok016c24_lldb_inner_probes.probe_10432dd98_epilogue"),
    # v4: 0x10017f184 is the real decision point (v3 showed FAIL_EXIT_A
    # @ 0x10432e058 is reached via bl 0x10017f184 returning w0 with
    # bit0 = 0).
    (BP_OUTER_AT_E06C,        "hok016c24_outer_at_e06c",        "hok016c24_lldb_inner_probes.probe_10432dd98_at_e06c"),
    (BP_OUTER_AFTER_BL_F184,  "hok016c24_outer_after_bl_f184",  "hok016c24_lldb_inner_probes.probe_10432dd98_after_bl_f184"),
    (BP_F184_ENTRY,           "hok016c24_f184_entry",           "hok016c24_lldb_inner_probes.probe_f184_entry"),
    (BP_F184_AFTER_BL1,       "hok016c24_f184_after_bl1",       "hok016c24_lldb_inner_probes.probe_f184_after_bl1"),
    (BP_F184_BEFORE_BL2,      "hok016c24_f184_before_bl2",      "hok016c24_lldb_inner_probes.probe_f184_before_bl2"),
    (BP_F184_AFTER_BL2,       "hok016c24_f184_after_bl2",       "hok016c24_lldb_inner_probes.probe_f184_after_bl2"),
    (BP_F184_FAIL_SLOT_1,     "hok016c24_f184_fail_slot_1",     "hok016c24_lldb_inner_probes.probe_f184_fail_slot_1"),
    (BP_F184_FAIL_SLOT_2,     "hok016c24_f184_fail_slot_2",     "hok016c24_lldb_inner_probes.probe_f184_fail_slot_2"),
    # 0x10432b734 interior.
    (BP_B734_ENTRY,           "hok016c24_b734_entry",           "hok016c24_lldb_inner_probes.probe_10432b734_entry"),
    (BP_B734_AFTER_BL_B2A8,   "hok016c24_b734_after_b2a8",      "hok016c24_lldb_inner_probes.probe_10432b734_after_bl_b2a8"),
    (BP_B734_AFTER_BL_BA84,   "hok016c24_b734_after_ba84",      "hok016c24_lldb_inner_probes.probe_10432b734_after_bl_ba84"),
]


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.4: step into 0x10017f3c8's two inner lookup "
            "bl's and capture the arguments (FString / key pointer) so "
            "we can decide whether path-fixup or local interpose is the "
            "right fix path."
        )
    )
    ap.add_argument("--lldb-timeout", type=float, default=30.0)
    ap.add_argument("--settle-seconds", type=float, default=22.0)
    ap.add_argument(
        "--output",
        default="build/hok-016c24-readinessB-inner-args.json",
        help="hok006 runner report output path",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    pre_run_commands: list[str] = [
        f"command script import {LLDB_HELPER_PATH}",
    ]

    # --- HOK-016-C.2.3 parity BPs (shell callbacks, no Python). ---
    # NOTE: the 0x10432dd98 entry used to live here as a shell-callback BP
    # in the first C.2.4 run; it has been moved into the Python-callback
    # group below (probe_10432dd98_entry) so we can decode its FString
    # args. Two BPs on the same address would contaminate each other.
    pre_run_commands.append(
        f"breakpoint set --shlib NGR --address {BP_BEFORE_BL_10432DD98} "
        f"-N hok016c24_before_bl_10432dd98 "
        f"-C 'register read x0 x1 x2 x3 x22' --auto-continue true"
    )
    pre_run_commands.append(
        f"breakpoint set --shlib NGR --address {BP_AFTER_BL_10432DD98} "
        f"-N hok016c24_after_bl_10432dd98 "
        f"-C 'register read x0' --auto-continue true"
    )

    # --- Python-callback BPs (inner helper + fail slots). ---
    # For each pair, the ``breakpoint set`` and ``breakpoint command add``
    # must be adjacent (HOK-016-C.X踩坑).
    for address, name, callback in _PY_PROBES:
        pre_run_commands.append(
            f"breakpoint set --shlib NGR --address {address} "
            f"-N {name} --auto-continue true"
        )
        pre_run_commands.append(
            f"breakpoint command add -s python -F {callback}"
        )

    # --- Final failure sink (hard-stop, same as HOK-016-C.2.3). ---
    pre_run_commands.append(
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c24_probe_at_failsink "
        f"-C 'thread backtrace' "
        f"-C 'register read x19 x24'"
    )

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        "--output", str(output_path),
    ]
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-C.2.4 inner-helper args probe:")
    print(f"  readiness-B parity BPs:")
    print(f"    +352 before bl 0x10432dd98: {BP_BEFORE_BL_10432DD98}")
    print(f"    +356 after  bl 0x10432dd98: {BP_AFTER_BL_10432DD98}")
    print(f"    entry 0x10432dd98        : {BP_AT_10432DD98_ENTRY}")
    print(f"    +1364 failure sink       : {BP_FAILURE_SINK}")
    print(f"  inner helper probes (python callbacks):")
    for address, name, callback in _PY_PROBES:
        print(f"    {address}  {name} -> {callback}")
    print(f"  output: {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
