#!/usr/bin/env python3
"""HOK-016-C.4 diagnostic runner: force storage-method success once.

Purpose
-------
HOK-016-C.2.7 narrowed the active failure to:

``0x1001bd464 -> 0x1001a5014 -> storage.vtable[0x18] (0x1001b3d0c)``

where the storage method returns ``0`` after the internal create-table helper
produces a null table / ``storage+0x30 = 0x9000b``.

This runner does one diagnostic-only experiment: at ``0x1001a522c`` (right
after the storage vtable call returns to ``a5014``), force ``x0 = 1`` so the
current failure path can continue down the success branch. The goal is to prove
whether this boolean gate is sufficient to move startup forward.

Output: ``build/hok-016c4-force-storage-success.json`` (hok006 runner schema).
No PlayTools / app binary modifications.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
HELPER_MODULE = str(SCRIPT_DIR / "hok016c27_lldb_mainchunk_watch.py")

BP_MAINCHUNK_CAPTURE = "0x10017f1dc"
BP_FORCE_STORAGE_SUCCESS = "0x1001a522c"
BP_FORCE_READY_SUCCESS = "0x1001a6958"
BP_A5014_RETURN = "0x1001bd888"
BP_BD464_AFTER_READY = "0x1001bd960"
BP_F184_RETURN = "0x10017f29c"
BP_DD98_RETURN = "0x10432e074"
BP_DORMANT_BRANCH = "0x10432dfdc"
BP_SECOND_GATE_RETURN = "0x10017fb44"
BP_SECOND_F3C8_RETURN = "0x10432df30"
BP_BE550_POST_LOOKUP = "0x1001be584"
BP_BE550_CHILD_PICK = "0x1001be5cc"
BP_F3C8_POST = "0x10017f51c"
BP_BC220_STAGE = "0x1001bc2a4"
BP_BC220_SLOT1_SOURCE = "0x1001bc45c"
BP_BC970_STAGE = "0x1001bca40"
BP_BA940_OVERRIDE_ALLOC = "0x1001bae58"
BP_BA940_OVERRIDE_ALLOC_POST = "0x1001bae70"
BP_BA940_OVERRIDE_SLOT = "0x1001bb010"
BP_BA940_OVERRIDE_SLOT_POST = "0x1001bb014"
BP_WRITER_STORE = "0x1001c6e78"
BP_FAILURE_SINK = "0x108878124"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "HOK-016-C.4 diagnostic checkpoint: force the storage-method return "
            "inside a5014 to success and see whether startup advances."
        )
    )
    parser.add_argument("--lldb-timeout", type=float, default=45.0)
    parser.add_argument("--settle-seconds", type=float, default=35.0)
    parser.add_argument(
        "--output",
        default="build/hok-016c4-force-storage-success.json",
        help="hok006 runner report output path",
    )
    parser.add_argument(
        "--force-ready-to-use",
        action="store_true",
        help="also force the 0x1001a6830 readiness/save-header result to success",
    )
    parser.add_argument(
        "--skip-mainchunk-watchpoint",
        action="store_true",
        help="capture mainChunk address without installing the dynamic +0x60 watchpoint",
    )
    parser.add_argument(
        "--trace-dormant-writer",
        action="store_true",
        help="add structured callbacks on the dual-force dormant writer chain",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    python_breakpoints = [
        (
            BP_MAINCHUNK_CAPTURE,
            "hok016c4_mainchunk_after_lookup",
            (
                "hok016c27_lldb_mainchunk_watch.snapshot_mainchunk_no_watch_on_hit"
                if args.skip_mainchunk_watchpoint
                else "hok016c27_lldb_mainchunk_watch.snapshot_mainchunk_on_hit"
            ),
        ),
        (
            BP_FORCE_STORAGE_SUCCESS,
            "hok016c4_force_storage_success",
            "hok016c27_lldb_mainchunk_watch.force_storage_success_on_hit",
        ),
        (
            BP_A5014_RETURN,
            "hok016c4_a5014_return",
            "hok016c27_lldb_mainchunk_watch.snapshot_bd464_after_a5014_on_hit",
        ),
        (
            BP_F184_RETURN,
            "hok016c4_f184_return",
            "hok016c27_lldb_mainchunk_watch.snapshot_postcall_on_hit",
        ),
        (
            BP_DD98_RETURN,
            "hok016c4_dd98_return",
            "hok016c27_lldb_mainchunk_watch.snapshot_postcall_on_hit",
        ),
    ]

    if args.force_ready_to_use:
        python_breakpoints.extend(
            [
                (
                    BP_FORCE_READY_SUCCESS,
                    "hok016c4_force_ready_success",
                    "hok016c27_lldb_mainchunk_watch.force_ready_to_use_success_on_hit",
                ),
                (
                    BP_BD464_AFTER_READY,
                    "hok016c4_bd464_after_ready",
                    "hok016c27_lldb_mainchunk_watch.snapshot_bd464_after_ready_on_hit",
                ),
            ]
        )

    if args.trace_dormant_writer:
        python_breakpoints.extend(
            [
                (
                    BP_DORMANT_BRANCH,
                    "hok016c4_dormant_branch",
                    "hok016c27_lldb_mainchunk_watch.snapshot_dormant_branch_on_hit",
                ),
                (
                    BP_SECOND_GATE_RETURN,
                    "hok016c4_second_gate_return",
                    "hok016c27_lldb_mainchunk_watch.snapshot_second_gate_return_on_hit",
                ),
                (
                    BP_SECOND_F3C8_RETURN,
                    "hok016c4_second_f3c8_return",
                    "hok016c27_lldb_mainchunk_watch.snapshot_second_f3c8_return_on_hit",
                ),
                (
                    BP_BE550_POST_LOOKUP,
                    "hok016c4_be550_post_lookup",
                    "hok016c27_lldb_mainchunk_watch.snapshot_be550_post_lookup_on_hit",
                ),
                (
                    BP_BE550_CHILD_PICK,
                    "hok016c4_be550_child_pick",
                    "hok016c27_lldb_mainchunk_watch.snapshot_be550_child_pick_on_hit",
                ),
                (
                    BP_F3C8_POST,
                    "hok016c4_f3c8_post",
                    "hok016c27_lldb_mainchunk_watch.snapshot_f3c8_post_on_hit",
                ),
                (
                    BP_BC220_STAGE,
                    "hok016c4_bc220_stage",
                    "hok016c27_lldb_mainchunk_watch.snapshot_bc220_stage_on_hit",
                ),
                (
                    BP_BC220_SLOT1_SOURCE,
                    "hok016c4_bc220_slot1_source",
                    "hok016c27_lldb_mainchunk_watch.snapshot_bc220_slot1_source_on_hit",
                ),
                (
                    BP_BC970_STAGE,
                    "hok016c4_bc970_stage",
                    "hok016c27_lldb_mainchunk_watch.snapshot_bc970_stage_on_hit",
                ),
                (
                    BP_BA940_OVERRIDE_ALLOC,
                    "hok016c4_ba940_override_alloc",
                    "hok016c27_lldb_mainchunk_watch.snapshot_ba940_override_alloc_on_hit",
                ),
                (
                    BP_BA940_OVERRIDE_ALLOC_POST,
                    "hok016c4_ba940_override_alloc_post",
                    "hok016c27_lldb_mainchunk_watch.snapshot_ba940_override_alloc_post_on_hit",
                ),
                (
                    BP_BA940_OVERRIDE_SLOT,
                    "hok016c4_ba940_override_slot",
                    "hok016c27_lldb_mainchunk_watch.snapshot_ba940_override_slot_write_on_hit",
                ),
                (
                    BP_BA940_OVERRIDE_SLOT_POST,
                    "hok016c4_ba940_override_slot_post",
                    "hok016c27_lldb_mainchunk_watch.snapshot_ba940_override_slot_post_on_hit",
                ),
                (
                    BP_WRITER_STORE,
                    "hok016c4_writer_store",
                    "hok016c27_lldb_mainchunk_watch.snapshot_writer_store_on_hit",
                ),
            ]
        )

    pre_run_commands: list[str] = [
        f"command script import {HELPER_MODULE}",
    ]
    for address, name, callback in python_breakpoints:
        pre_run_commands.append(
            f"breakpoint set --shlib NGR --address {address} -N {name} --auto-continue true"
        )
        pre_run_commands.append(
            f"breakpoint command add -s python -F {callback}"
        )

    pre_run_commands.append(
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c4_failure_sink -C 'thread backtrace' -C 'register read x19 x24 x0'"
    )

    runner_cmd: list[str] = [
        "python3",
        str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout",
        str(args.lldb_timeout),
        "--settle-seconds",
        str(args.settle_seconds),
        "--output",
        str(output_path),
    ]
    for command in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", command])

    print("HOK-016-C.4 storage-success checkpoint:")
    print(f"  mainChunk capture    : {BP_MAINCHUNK_CAPTURE}")
    print(
        "  mainChunk watchpoint : "
        + ("disabled" if args.skip_mainchunk_watchpoint else "enabled")
    )
    print(f"  force storage return : {BP_FORCE_STORAGE_SUCCESS}")
    if args.force_ready_to_use:
        print(f"  force ready result   : {BP_FORCE_READY_SUCCESS}")
        print(f"  ready return post    : {BP_BD464_AFTER_READY}")
    if args.trace_dormant_writer:
        print(f"  dormant branch       : {BP_DORMANT_BRANCH}")
        print(f"  second gate return   : {BP_SECOND_GATE_RETURN}")
        print(f"  second f3c8 return   : {BP_SECOND_F3C8_RETURN}")
        print(f"  be550 post-lookup    : {BP_BE550_POST_LOOKUP}")
        print(f"  be550 child pick     : {BP_BE550_CHILD_PICK}")
        print(f"  f3c8 post            : {BP_F3C8_POST}")
        print(f"  bc220 stage          : {BP_BC220_STAGE}")
        print(f"  bc220 slot1 src      : {BP_BC220_SLOT1_SOURCE}")
        print(f"  bc970 stage          : {BP_BC970_STAGE}")
        print(f"  ba940 override alloc : {BP_BA940_OVERRIDE_ALLOC}")
        print(f"  ba940 override post  : {BP_BA940_OVERRIDE_ALLOC_POST}")
        print(f"  ba940 override slot  : {BP_BA940_OVERRIDE_SLOT}")
        print(f"  ba940 override slot+ : {BP_BA940_OVERRIDE_SLOT_POST}")
        print(f"  writer store         : {BP_WRITER_STORE}")
    print(f"  a5014 return         : {BP_A5014_RETURN}")
    print(f"  f184 return path     : {BP_F184_RETURN}")
    print(f"  dd98 return path     : {BP_DD98_RETURN}")
    print(f"  failure sink         : {BP_FAILURE_SINK}")
    print(f"  output               : {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
