#!/usr/bin/env python3
"""HOK-016-C.1: 运行期追踪 NGR QtsFileSystem 在 macOS/PlayCover 下
失败分支的 w0 来源。

封装 ``Scripts/hok006_ngr_lldb_runner.py``：在 `0x108877bd0` 的两条
`tbz w0, #0, fail` 判定点前（`+900`, `+912`）以及 fail sink（`+1364`）
设 LLDB breakpoint，抓每次 tbz 前的 w0 以精确定位哪一个 bl 调用返回 0。

前提：HOK-016-A 已落、HOK-016-B 已跑过（确认 reporter / 分支地址）。

背景（见 ``LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md``）：
  - reporter `0x108879164 +176 bl 0x108877bd0; +180 tbz w0, #0, +364` 是
    进入 "QtsFileSystem Create Failed!!" 分支的唯一入口；
  - `0x108877bd0` 自身有两处 `tbz w0, #0, <fail_cleanup>` 判定：
      `+900 tbz w0, #0, +1332`  ← 对应 `+896 bl 0x108876a94`（Readiness
                                   check A，观察到返回 1/ok）
      `+912 tbz w0, #0, +1364`  ← 对应 `+908 bl 0x108878534`（Readiness
                                   check B，观察到返回 0/fail）
  - 两条分支最终汇到 `+1380 mov w19, #0 → ret 0`，使 reporter 把
    "Create Failed!!" alert 投递给 UIAlertController。

产物：
  - ``build/hok-016c-w0-trace.json``：hok006 runner 原始 report，
    transcript 含每次 tbz 前的 ``register read x0`` 输出。

用法：

    python3 Scripts/hok016c_ngr_qts_w0_trace.py \\
        [--lldb-timeout 25] [--settle-seconds 22] \\
        [--output build/hok-016c-w0-trace.json]

BP 设计思路：
  - bp_at_900_before_tbz / bp_at_912_before_tbz 使用 ``--auto-continue
    true`` 让进程不在这两个 BP 上 hard-stop，仅通过 `-C 'register read
    x0'` 把 w0 值回吐到 transcript；
  - bp_at_1364_failure_sink 不带 auto-continue，作为**终止 BP**——命中
    一次后 hok006 runner 的 legacy stop handler 会 dump `thread
    backtrace all` / `register read` / `quit`，终结本次 run。

透过 transcript line 号解析：
  transcript 的
    `(lldb)  register read x0`
    `      x0 = 0x0000000000000001`  ← bp_at_900 / w0=1（readiness A ok）
    `(lldb)  register read x0`
    `      x0 = 0x0000000000000000`  ← bp_at_912 / w0=0（readiness B fail）
    `stop reason = breakpoint 3.1`   ← bp_at_1364 命中、dump bt
  就是本轮期望的证据链。

**UE4-side 辅助观察**：同一 run 的 NGR stderr/stdout 在 transcript 里
会出现一条关键 UE4 log——
  ``[UE4] Project file not found: ../../../NGR/NGR.uproject``
——说明 HOK-015 preseed 的 cmdline 种子 `"../../../NGR/NGR.uproject"`
在 macOS/PlayCover 布局下确实**找不到**（iOS cooked build 不保留
.uproject 文件；但 UE4 仍基于此路径展开，QtsFileSystem 的
``0x108878534`` 检查因此失败）。HOK-016-C.2 的方向由此引出：试验把
HOK-015 的 seedValue 换成 UE4 能接受的最小形态（空串 / 仅 project
name），观察 ``0x108878534`` 是否走不同分支。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


# Addresses locked by HOK-016-A/B (static + LLDB walk-back consistent).
BP_ADDR_BEFORE_TBZ_900 = "0x108877f54"   # +900 in 0x108877bd0
BP_ADDR_BEFORE_TBZ_912 = "0x108877f60"   # +912 in 0x108877bd0
BP_ADDR_FAILURE_SINK   = "0x108878124"   # +1364 in 0x108877bd0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.1: trace QtsFileSystem Create-Failed branch's w0 "
            "origin via LLDB breakpoints on tbz gates"
        )
    )
    ap.add_argument("--lldb-timeout", type=float, default=25.0)
    ap.add_argument("--settle-seconds", type=float, default=22.0)
    ap.add_argument(
        "--output",
        default="build/hok-016c-w0-trace.json",
        help="hok006 runner report output path",
    )
    ap.add_argument(
        "--run-build-install",
        action="store_true",
        help="run BuildScripts/build_and_install.sh before launch (default: skip)",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()

    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    # Three breakpoints, composed exactly as verified in HOK-016-C.1 notes.
    pre_run_commands = [
        # w0 just before +900 tbz — readiness A (0x108876a94 return).
        f"breakpoint set --shlib NGR --address {BP_ADDR_BEFORE_TBZ_900} "
        "-N bp_at_900_before_tbz -C 'register read x0' --auto-continue true",
        # w0 just before +912 tbz — readiness B (0x108878534 return).
        f"breakpoint set --shlib NGR --address {BP_ADDR_BEFORE_TBZ_912} "
        "-N bp_at_912_before_tbz -C 'register read x0' --auto-continue true",
        # +1364 failure sink — dumps bt and registers, then hok006 legacy
        # stop handler (stop -> quit) terminates the run.
        f"breakpoint set --shlib NGR --address {BP_ADDR_FAILURE_SINK} "
        "-N bp_at_1364_failure_sink -C 'thread backtrace' "
        "-C 'register read x19 x24'",
    ]

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

    print("HOK-016-C.1 trace points:")
    print(f"  {BP_ADDR_BEFORE_TBZ_900}   +900 tbz  (readiness A / 0x108876a94)")
    print(f"  {BP_ADDR_BEFORE_TBZ_912}   +912 tbz  (readiness B / 0x108878534)")
    print(f"  {BP_ADDR_FAILURE_SINK}   +1364 failure sink")
    print()
    print("invoking hok006 runner:")
    print("  " + " ".join(runner_cmd))
    return subprocess.run(runner_cmd, cwd=str(REPO_ROOT)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
