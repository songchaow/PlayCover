#!/usr/bin/env python3
"""HOK-016-B: 运行期 LLDB 抓 NGR QtsFileSystem reporter backtrace / 参数。

封装 ``Scripts/hok006_ngr_lldb_runner.py`` 的调用：消费 HOK-016-A 的
``build/hok-016-qts-fs-static.json``，把 reporter 入口 + 家族兄弟 callsite
作为 LLDB breakpoint 注入（所有 BP 必须用 ``--shlib NGR --address <unslid>``
格式，否则 ASLR 下命中不到；已在真机验证）；命中后抓
``thread backtrace`` + ``register read x0..x8``。

产物：``build/hok-016-qts-reporter-lldb.json``（hok006 runner 生成，语义
不变）。外加一份轻量 summary 方便 agent 消费，写到
``build/hok-016-qts-reporter-summary.json``，含：

  - reporter 入口命中信息（faultingFrame / faultingInstruction / backtrace）
  - x0..x8 原始值（从 LLDB transcript 提取）
  - 所有 BP 的 hit count
  - 和 HOK-015 locator 输出的 bInitialized / cmdlineBuffer 地址的交叉对照

用法：

    python3 Scripts/hok016_ngr_qts_reporter_trace.py \\
        [--static-report build/hok-016-qts-fs-static.json] \\
        [--output-full build/hok-016-qts-reporter-lldb.json] \\
        [--output-summary build/hok-016-qts-reporter-summary.json] \\
        [--lldb-timeout 15] [--settle-seconds 12]

前置条件：PlayCover.app 已安装、带 HOK-013/014/015 兜底的 PlayTools 已
apply；脚本自己不跑 ``BuildScripts/build_and_install.sh``（传
``--run-build-install`` 才跑）。

"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


DEFAULT_STATIC_REPORT = Path("build/hok-016-qts-fs-static.json")
DEFAULT_OUTPUT_FULL = Path("build/hok-016-qts-reporter-lldb.json")
DEFAULT_OUTPUT_SUMMARY = Path("build/hok-016-qts-reporter-summary.json")
DEFAULT_HOK015_REPORT = Path("build/hok-015-cmdline-slots.json")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _collect_breakpoint_targets(static_report: dict[str, Any]) -> list[tuple[str, str]]:
    """Return [(bp_name, unslid_vmaddr_str), ...] from HOK-016-A report.

    Breakpoints:
      hok016_reporter_entry  <- reporterFunction.entryFromDocumentedCallsite
      hok016_family_<value>  <- one per family string's adrpAddXrefs[0]
    """
    targets: list[tuple[str, str]] = []

    reporter = (static_report.get("reporterFunction") or {})
    entry = reporter.get("entryFromDocumentedCallsite")
    if entry:
        targets.append(("hok016_reporter_entry", str(entry)))

    family = (static_report.get("qtsFileSystemFamily") or {}).get("strings") or []
    for s in family:
        xrefs = s.get("adrpAddXrefs") or []
        if not xrefs:
            continue
        # The first xref is the most canonical adrp+add callsite; use it as
        # the BP target. Name the BP after the string value, sanitized.
        value = (s.get("value") or "")
        sanitized = re.sub(r"[^a-zA-Z0-9]+", "_", value).strip("_")[:48]
        name = f"hok016_family_{sanitized}" if sanitized else "hok016_family"
        targets.append((name, str(xrefs[0])))

    # De-dup on unslid address.
    seen: set[str] = set()
    out: list[tuple[str, str]] = []
    for name, addr in targets:
        key = addr.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append((name, addr))
    return out


def _build_pre_run_commands(targets: list[tuple[str, str]]) -> list[str]:
    """Compose `breakpoint set --shlib NGR --address <addr> -N <name>
    -C 'thread backtrace' -C 'register read ...'` commands.

    We pass ``--shlib NGR`` so the BP is a *module-relative* address which
    lldb re-resolves after NGR is slid into memory (verified manually —
    without ``--shlib`` the absolute VA mis-matches the runtime slide and
    the BP never fires).
    """
    register_read = "register read x0 x1 x2 x3 x4 x5 x6 x7 x8"
    commands: list[str] = []
    for name, addr in targets:
        cmd = (
            f"breakpoint set --shlib NGR --address {addr} -N {name} "
            f"-C 'thread backtrace' -C '{register_read}'"
        )
        commands.append(cmd)
    return commands


REGISTER_LINE_RE = re.compile(
    r"^\s*(x\d+|fp|lr|sp)\s*=\s*(0x[0-9a-fA-F]+)"
)


def _extract_register_state(
    transcript: str,
) -> list[dict[str, Any]]:
    """Parse the transcript for every `register read` block that follows a
    `stop reason = breakpoint` line. Returns a list of dicts with keys
    ``stopIndex``, ``threadLine``, ``registers``.
    """
    lines = transcript.splitlines()
    results: list[dict[str, Any]] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = re.search(r"thread #(\d+), stop reason = breakpoint (\S+)", line)
        if m is None:
            i += 1
            continue
        thread_line = line.strip()
        thread_id = int(m.group(1))
        bp_spec = m.group(2)
        # Walk forward to the next `register read` block within the next
        # ~50 lines; collect x-register assignments.
        registers: dict[str, str] = {}
        for j in range(i + 1, min(i + 80, n)):
            if "register read" in lines[j].lower() and "(lldb)" in lines[j]:
                # Collect subsequent register lines.
                for k in range(j + 1, min(j + 40, n)):
                    if lines[k].startswith("(lldb)") or "Process " in lines[k]:
                        break
                    mm = REGISTER_LINE_RE.match(lines[k])
                    if mm:
                        registers[mm.group(1)] = mm.group(2)
                break
        results.append(
            {
                "stopIndex": i,
                "threadId": thread_id,
                "breakpointSpec": bp_spec,
                "threadLine": thread_line,
                "registers": registers,
            }
        )
        i += 1
    return results


def _build_summary(
    static_report: dict[str, Any] | None,
    hok006_report: dict[str, Any],
    hok015_report: dict[str, Any] | None,
    targets: list[tuple[str, str]],
) -> dict[str, Any]:
    lldb = ((hok006_report.get("launch") or {}).get("lldb") or {})
    launch_app = (hok006_report.get("launch") or {}).get("launchAppWithLLDB") or {}
    parsed = launch_app.get("parsed") or {}
    full_transcript = ""
    if isinstance(parsed, dict):
        parsed_lldb = parsed.get("lldb") or {}
        full_transcript = str(parsed_lldb.get("transcript") or "")

    register_states = _extract_register_state(full_transcript)

    # Cross-reference x2 against HOK-015 cmdline buffer address.
    cmdline_addr_unslid: int | None = None
    b_init_addr_unslid: int | None = None
    if hok015_report:
        try:
            cmdline_addr_unslid = int(
                str(hok015_report.get("cmdlineBufferAddr") or ""), 16
            )
        except ValueError:
            cmdline_addr_unslid = None
        try:
            b_init_addr_unslid = int(
                str(hok015_report.get("bInitializedAddr") or ""), 16
            )
        except ValueError:
            b_init_addr_unslid = None

    register_notes: list[dict[str, Any]] = []
    for rs in register_states:
        regs = rs.get("registers") or {}
        note: dict[str, Any] = dict(rs)
        x2 = regs.get("x2")
        x1 = regs.get("x1")
        if x2 and cmdline_addr_unslid is not None:
            try:
                x2_val = int(x2, 16)
                # x2 may be slid; compare against cmdline addr + probable slide.
                # Compute probable slide from x0 of main image load (not known
                # here), so approximate: equal-modulo-alignment match means
                # unslid addresses are equal AND slide is 0; otherwise look
                # at low 28 bits (mach image is always 16MB aligned).
                note["x2MatchesCmdlineBufferLowBits"] = (
                    (x2_val & 0xFFFFFFF)
                    == (cmdline_addr_unslid & 0xFFFFFFF)
                )
                if note["x2MatchesCmdlineBufferLowBits"]:
                    note["x2Interpretation"] = (
                        "x2 is a pointer into FCommandLine::CmdLine (HOK-015 preseeded UTF-16-LE buffer)"
                    )
            except ValueError:
                pass
        if x1 and b_init_addr_unslid is not None:
            try:
                x1_val = int(x1, 16)
                note["x1MatchesBInitializedLowBits"] = (
                    (x1_val & 0xFFFFFFF)
                    == (b_init_addr_unslid & 0xFFFFFFF)
                )
            except ValueError:
                pass
        register_notes.append(note)

    # Find the first breakpoint hit per target name.
    bp_hits_by_name: dict[str, int] = {name: 0 for name, _ in targets}
    for rs in register_states:
        spec = str(rs.get("breakpointSpec") or "")
        # LLDB prints "breakpoint 1.1" etc; our names are attached but not
        # visible per-hit. Use target order as a proxy (breakpoint N.1 ->
        # Nth target).
        m = re.match(r"(\d+)", spec)
        if m:
            n_one_based = int(m.group(1))
            if 1 <= n_one_based <= len(targets):
                name = targets[n_one_based - 1][0]
                bp_hits_by_name[name] = bp_hits_by_name.get(name, 0) + 1

    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": hok006_report.get("bundleId"),
        "sourceReports": {
            "hok016StaticReport": (
                str((static_report or {}).get("binaryPath") or "")
                if static_report
                else None
            ),
            "hok015CmdlineSlotsReport": DEFAULT_HOK015_REPORT.as_posix()
            if hok015_report
            else None,
        },
        "targets": [
            {"breakpointName": name, "unslidAddress": addr}
            for name, addr in targets
        ],
        "lldb": {
            "timedOut": lldb.get("timedOut"),
            "didStop": lldb.get("didStop"),
            "stopReason": lldb.get("stopReason"),
            "faultingThread": lldb.get("faultingThread"),
            "faultingFrame": lldb.get("faultingFrame"),
            "faultingInstruction": lldb.get("faultingInstruction"),
            "backtraceDepth": lldb.get("backtraceDepth"),
            "backtraceHead": lldb.get("backtraceHead"),
            "blockingDialogCount": lldb.get("blockingDialogCount"),
        },
        "breakpointHits": bp_hits_by_name,
        "breakpointStops": register_notes,
        "checks": {
            "reporterEntryHit": bp_hits_by_name.get("hok016_reporter_entry", 0) > 0,
            "anyStopCaptured": bool(register_notes),
            "backtraceCaptured": int(lldb.get("backtraceDepth") or 0) > 0,
            "blockingDialogsZero": int(lldb.get("blockingDialogCount") or 0) == 0,
        },
    }
    summary["checks"]["overallPass"] = (
        summary["checks"]["reporterEntryHit"]
        and summary["checks"]["anyStopCaptured"]
        and summary["checks"]["backtraceCaptured"]
    )
    return summary


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="HOK-016-B: LLDB BP + backtrace capture for NGR QtsFileSystem reporter"
    )
    ap.add_argument("--static-report", default=str(DEFAULT_STATIC_REPORT))
    ap.add_argument("--hok015-report", default=str(DEFAULT_HOK015_REPORT))
    ap.add_argument("--output-full", default=str(DEFAULT_OUTPUT_FULL))
    ap.add_argument("--output-summary", default=str(DEFAULT_OUTPUT_SUMMARY))
    ap.add_argument("--lldb-timeout", type=float, default=15.0)
    ap.add_argument("--settle-seconds", type=float, default=12.0)
    ap.add_argument(
        "--run-build-install",
        action="store_true",
        help="run BuildScripts/build_and_install.sh before the LLDB launch (default: skip, reuses the installed PlayCover.app)",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()

    static_path = Path(args.static_report)
    if not static_path.is_absolute():
        static_path = (REPO_ROOT / static_path).resolve()
    hok015_path = Path(args.hok015_report)
    if not hok015_path.is_absolute():
        hok015_path = (REPO_ROOT / hok015_path).resolve()
    output_full = Path(args.output_full)
    if not output_full.is_absolute():
        output_full = (REPO_ROOT / output_full).resolve()
    output_summary = Path(args.output_summary)
    if not output_summary.is_absolute():
        output_summary = (REPO_ROOT / output_summary).resolve()

    static_report = _read_json(static_path)
    if static_report is None:
        print(
            f"error: HOK-016-A static report not found: {static_path}\n"
            f"       run `python3 Scripts/hok016_ngr_qts_locator.py` first.",
            file=sys.stderr,
        )
        return 1
    hok015_report = _read_json(hok015_path)
    # Missing HOK-015 report is non-fatal (cross-reference section becomes
    # degenerate), but warn loudly.
    if hok015_report is None:
        print(
            f"warn: HOK-015 cmdline slots report not found: {hok015_path}; "
            f"skipping x1/x2 cross-reference",
            file=sys.stderr,
        )

    targets = _collect_breakpoint_targets(static_report)
    if not targets:
        print(
            "error: no reporter / family targets resolved from static report",
            file=sys.stderr,
        )
        return 2
    pre_run_commands = _build_pre_run_commands(targets)

    # Build the hok006 runner command.
    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--lldb-timeout", str(args.lldb_timeout),
        "--settle-seconds", str(args.settle_seconds),
        "--output", str(output_full),
    ]
    if not args.run_build_install:
        runner_cmd.append("--skip-build-install")
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print("HOK-016-B targets:")
    for name, addr in targets:
        print(f"  {name:40s} -> {addr}")
    print()
    print("invoking hok006 runner: " + " ".join(runner_cmd))
    runner_proc = subprocess.run(runner_cmd, cwd=str(REPO_ROOT))
    if runner_proc.returncode not in (0, 2):
        # hok006 runner's exit code 2 means "overallPass=False"; we still
        # want a summary for either success or the HOK-016-B-specific pass
        # check, so 2 is acceptable.
        print(
            f"error: hok006 runner exited with {runner_proc.returncode}",
            file=sys.stderr,
        )
        return runner_proc.returncode

    hok006_report = _read_json(output_full)
    if hok006_report is None:
        print(f"error: hok006 runner did not produce {output_full}", file=sys.stderr)
        return 3

    summary = _build_summary(static_report, hok006_report, hok015_report, targets)
    output_summary.parent.mkdir(parents=True, exist_ok=True)
    output_summary.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"\nHOK-016-B summary written to {output_summary}")
    checks = summary.get("checks", {})
    for k, v in checks.items():
        print(f"  {k}: {v}")
    bt_head = summary.get("lldb", {}).get("backtraceHead") or []
    if bt_head:
        print("\n  backtrace head:")
        for bt in bt_head[:12]:
            print(f"    {bt}")

    return 0 if checks.get("overallPass") else 2


if __name__ == "__main__":
    raise SystemExit(main())
