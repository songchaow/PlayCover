#!/usr/bin/env python3
"""HOK-016-C.2.7 driver: trace ``mainChunk -> \"1\"`` lookup and subtree writes.

Purpose
-------
HOK-016-C.2.6 proved that:

* ``rootB[\"main\"]`` already succeeds;
* the returned ``mainChunk`` object exists;
* ``0x1001ba82c(mainChunk, \"1\")`` returns 0;
* ``mainChunk+0x60`` stayed null in the failing run.

This driver pushes one step deeper by wiring focused LLDB Python-callback
breakpoints around the second-level lookup chain:

1. ``0x1001cd114`` entry (rootB lookup) — correlate the successful
   ``rootB -> \"main\"`` call with the narrowed path.
2. ``0x10017f1dc`` — capture the returned ``mainChunk`` object and arm a
   dynamic watchpoint on ``mainChunk+0x60``.
3. ``0x1001bd448`` entry — log the exact caller/args asking for child
   key ``\"1\"``.
4. ``0x1001ba82c`` entry — log the second-level lookup itself plus caller
   LR/backtrace.
5. ``0x1001bd588`` / ``0x10017f29c`` / ``0x10432e074`` — capture the
   return values as failure propagates back out.

Output: ``build/hok-016c27-mainchunk-subtree-trace.json`` (hok006 runner
schema). No PlayTools / NGR modifications.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
HELPER_MODULE = str(SCRIPT_DIR / "hok016c27_lldb_mainchunk_watch.py")

BP_FAILURE_SINK = "0x108878124"
BP_LOOKUP_HELPER = "0x1001cd114"
BP_F184_AFTER_LOOKUP = "0x10017f1dc"
BP_BD448_ENTRY = "0x1001bd448"
BP_LOOKUP2_ENTRY = "0x1001ba82c"
BP_BD448_AFTER_LOOKUP1 = "0x1001bd588"
BP_F184_BEFORE_FLAG_TESTS = "0x10017f29c"
BP_DD98_AFTER_F184 = "0x10432e074"
BP_BA50C_ENTRY = "0x1001ba50c"
BP_BD464_AFTER_BA50C = "0x1001bd800"
BP_BD464_AFTER_A5014 = "0x1001bd888"
BP_A5014_PRECHECK = "0x1001a50ec"
BP_A5014_AFTER_OPEN_DB = "0x1001a5114"
BP_A5014_AFTER_STORAGE = "0x1001a522c"
BP_STORAGE_METHOD_ENTRY = "0x1001b3d0c"
BP_STORAGE_CREATE_TABLE_CALL = "0x1001b3df0"
BP_CREATE_TABLE_ENTRY = "0x10012bb7c"
BP_CREATE_TABLE_IMPL_GATE_CALL = "0x10012502c"
BP_CREATE_TABLE_IMPL_GATE_RET = "0x100125030"
BP_CREATE_TABLE_IMPL_ERR9 = "0x100125334"
BP_CREATE_TABLE_IMPL_ENTRY_BUILD = "0x10012581c"
BP_CREATE_TABLE_IMPL_DEEP_CALL = "0x10012595c"
BP_CREATE_TABLE_IMPL_DEEP_ENTRY = "0x1001148b8"
BP_CREATE_TABLE_IMPL_DEEP_STAGE1 = "0x100114994"
BP_CREATE_TABLE_IMPL_DEEP_STAGE2 = "0x1001142a4"
BP_CREATE_TABLE_IMPL_ERR_DIRECT = "0x100122f98"
BP_CREATE_TABLE_IMPL_FINAL_CHECK = "0x100125960"
BP_CREATE_TABLE_IMPL_RETURN = "0x1001259c4"
BP_STORAGE_AFTER_CREATE_TABLE = "0x1001b3df4"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.7: trace the mainChunk -> '1' subtree lookup and "
            "watch for any runtime write to mainChunk+0x60."
        )
    )
    parser.add_argument("--lldb-timeout", type=float, default=45.0)
    parser.add_argument("--settle-seconds", type=float, default=35.0)
    parser.add_argument(
        "--output",
        default="build/hok-016c27-mainchunk-subtree-trace.json",
        help="hok006 runner report output path",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    python_breakpoints = [
        (
            BP_LOOKUP_HELPER,
            "hok016c27_rootb_lookup",
            "hok016c27_lldb_mainchunk_watch.snapshot_rootb_lookup_on_hit",
        ),
        (
            BP_F184_AFTER_LOOKUP,
            "hok016c27_mainchunk_after_lookup",
            "hok016c27_lldb_mainchunk_watch.snapshot_mainchunk_on_hit",
        ),
        (
            BP_BD448_ENTRY,
            "hok016c27_bd448_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_bd448_entry_on_hit",
        ),
        (
            BP_LOOKUP2_ENTRY,
            "hok016c27_lookup2_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_lookup2_on_hit",
        ),
        (
            BP_BA50C_ENTRY,
            "hok016c27_ba50c_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_ba50c_entry_on_hit",
        ),
        (
            BP_BD464_AFTER_BA50C,
            "hok016c27_bd464_after_ba50c",
            "hok016c27_lldb_mainchunk_watch.snapshot_ba50c_return_on_hit",
        ),
        (
            BP_BD464_AFTER_A5014,
            "hok016c27_bd464_after_a5014",
            "hok016c27_lldb_mainchunk_watch.snapshot_bd464_after_a5014_on_hit",
        ),
        (
            BP_A5014_PRECHECK,
            "hok016c27_a5014_precheck",
            "hok016c27_lldb_mainchunk_watch.snapshot_a5014_precheck_on_hit",
        ),
        (
            BP_A5014_AFTER_OPEN_DB,
            "hok016c27_a5014_after_open_db",
            "hok016c27_lldb_mainchunk_watch.snapshot_a5014_db_on_hit",
        ),
        (
            BP_A5014_AFTER_STORAGE,
            "hok016c27_a5014_after_storage",
            "hok016c27_lldb_mainchunk_watch.snapshot_a5014_storage_on_hit",
        ),
        (
            BP_STORAGE_METHOD_ENTRY,
            "hok016c27_storage_method_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_storage_method_entry_on_hit",
        ),
        (
            BP_STORAGE_CREATE_TABLE_CALL,
            "hok016c27_storage_create_table_call",
            "hok016c27_lldb_mainchunk_watch.snapshot_storage_create_table_call_on_hit",
        ),
        (
            BP_CREATE_TABLE_ENTRY,
            "hok016c27_create_table_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_entry_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_GATE_CALL,
            "hok016c27_create_table_impl_gate_call",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_gate_call_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_GATE_RET,
            "hok016c27_create_table_impl_gate_ret",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_gate_ret_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_ERR9,
            "hok016c27_create_table_impl_err9",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_err9_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_ENTRY_BUILD,
            "hok016c27_create_table_impl_entry_build",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_entry_build_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_DEEP_CALL,
            "hok016c27_create_table_impl_deep_call",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_deep_call_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_DEEP_ENTRY,
            "hok016c27_create_table_impl_deep_entry",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_deep_entry_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_DEEP_STAGE1,
            "hok016c27_create_table_impl_deep_stage1",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_deep_stage1_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_DEEP_STAGE2,
            "hok016c27_create_table_impl_deep_stage2",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_deep_stage2_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_ERR_DIRECT,
            "hok016c27_create_table_impl_err_direct",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_err_direct_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_FINAL_CHECK,
            "hok016c27_create_table_impl_final_check",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_final_check_on_hit",
        ),
        (
            BP_CREATE_TABLE_IMPL_RETURN,
            "hok016c27_create_table_impl_return",
            "hok016c27_lldb_mainchunk_watch.snapshot_create_table_impl_return_on_hit",
        ),
        (
            BP_STORAGE_AFTER_CREATE_TABLE,
            "hok016c27_storage_after_create_table",
            "hok016c27_lldb_mainchunk_watch.snapshot_storage_after_create_table_on_hit",
        ),
        (
            BP_BD448_AFTER_LOOKUP1,
            "hok016c27_bd448_after_lookup1",
            "hok016c27_lldb_mainchunk_watch.snapshot_postcall_on_hit",
        ),
        (
            BP_F184_BEFORE_FLAG_TESTS,
            "hok016c27_f184_before_flag_tests",
            "hok016c27_lldb_mainchunk_watch.snapshot_postcall_on_hit",
        ),
        (
            BP_DD98_AFTER_F184,
            "hok016c27_dd98_after_f184",
            "hok016c27_lldb_mainchunk_watch.snapshot_postcall_on_hit",
        ),
    ]

    pre_run_commands: list[str] = [
        f"command script import {HELPER_MODULE}",
    ]
    for address, name, callback in python_breakpoints:
        pre_run_commands.append(
            f"breakpoint set --shlib NGR --address {address} "
            f"-N {name} --auto-continue true"
        )
        pre_run_commands.append(
            f"breakpoint command add -s python -F {callback}"
        )

    pre_run_commands.append(
        f"breakpoint set --shlib NGR --address {BP_FAILURE_SINK} "
        f"-N hok016c27_failure_sink "
        f"-C 'thread backtrace' "
        f"-C 'register read x19 x24'"
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
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-C.2.7 mainChunk subtree trace:")
    print(f"  rootB lookup helper: {BP_LOOKUP_HELPER}")
    print(f"  mainChunk capture   : {BP_F184_AFTER_LOOKUP}")
    print(f"  bd448 entry         : {BP_BD448_ENTRY}")
    print(f"  lookup2 entry       : {BP_LOOKUP2_ENTRY}")
    print(f"  ba50c entry         : {BP_BA50C_ENTRY}")
    print(f"  ba50c return        : {BP_BD464_AFTER_BA50C}")
    print(f"  a5014 precheck      : {BP_A5014_PRECHECK}")
    print(f"  a5014 open-db       : {BP_A5014_AFTER_OPEN_DB}")
    print(f"  a5014 storage       : {BP_A5014_AFTER_STORAGE}")
    print(f"  storage method      : {BP_STORAGE_METHOD_ENTRY}")
    print(f"  storage create-call : {BP_STORAGE_CREATE_TABLE_CALL}")
    print(f"  create-table entry  : {BP_CREATE_TABLE_ENTRY}")
    print(f"  create-table gate   : {BP_CREATE_TABLE_IMPL_GATE_CALL}, {BP_CREATE_TABLE_IMPL_GATE_RET}")
    print(f"  create-table err=9  : {BP_CREATE_TABLE_IMPL_ERR9}")
    print(f"  create-table build  : {BP_CREATE_TABLE_IMPL_ENTRY_BUILD}")
    print(f"  create-table deep   : {BP_CREATE_TABLE_IMPL_DEEP_CALL}, {BP_CREATE_TABLE_IMPL_DEEP_ENTRY}")
    print(f"  create-table stages : {BP_CREATE_TABLE_IMPL_DEEP_STAGE1}, {BP_CREATE_TABLE_IMPL_DEEP_STAGE2}")
    print(f"  err direct writer   : {BP_CREATE_TABLE_IMPL_ERR_DIRECT}")
    print(f"  create-table check  : {BP_CREATE_TABLE_IMPL_FINAL_CHECK}")
    print(f"  create-table return : {BP_CREATE_TABLE_IMPL_RETURN}")
    print(f"  storage table       : {BP_STORAGE_AFTER_CREATE_TABLE}")
    print(f"  a5014 return        : {BP_BD464_AFTER_A5014}")
    print(f"  lookup2 return      : {BP_BD448_AFTER_LOOKUP1}")
    print(f"  f184 return path    : {BP_F184_BEFORE_FLAG_TESTS}, {BP_DD98_AFTER_F184}")
    print(f"  failure sink        : {BP_FAILURE_SINK}")
    print(f"  output              : {output_path}")
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
