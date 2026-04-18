#!/usr/bin/env python3
"""HOK-016-C.X.1: seed replacement experiment runner.

For each candidate seed value, this driver:

1. ``command script import`` the LLDB helper
   ``hok016cx_lldb_cmdline_override.py``;
2. Set ``hok016cx_lldb_cmdline_override.SEED = <candidate>``;
3. Set a script breakpoint on NGR ``0x103a227a4`` (MessagingInit entry)
   whose Python callback rewrites ``FCommandLine::CmdLine`` in place;
4. Set auto-continue BPs on the two ``tbz`` gates of ``0x108877bd0``
   (+900 / +912) to record w0 at the moment of each check;
5. Set a hard-stop BP on ``0x108878124`` (Create Failed sink) so the
   legacy hok006 stop handler quits the run once the failure sink is
   reached;
6. Run the hok006 runner with the full pre-run command stream, capture
   ``build/hok-016cx-<seed>-trace.json`` per candidate.

Then the driver parses each run's transcript for:

  * whether ``[UE4] Project file not found`` still appears;
  * whether the ``hok016cx`` rewrite actually fired;
  * w0 @ +900 / +912 values;
  * whether the Create Failed sink fired (indicating QtsFileSystem still
    failed).

A summary is printed and written to
``build/hok-016cx-summary.json``.

**No PlayTools changes, no NGR binary changes** — this is a pure LLDB
dynamic experiment to validate whether HOK-015's seed value affects
``0x108878534``'s Readiness-B decision.

Usage::

    python3 Scripts/hok016cx_ngr_seed_experiment.py \\
        [--seeds empty,project,ue4cmdfile,uproject] \\
        [--lldb-timeout 25] [--settle-seconds 22]

The default seed list runs 4 candidates sequentially; each candidate
launch takes ~35s including settle + teardown.
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
LLDB_HELPER_PATH = SCRIPT_DIR / "hok016cx_lldb_cmdline_override.py"

DEFAULT_SEEDS = ["empty", "project", "ue4cmdfile", "uproject"]
DEFAULT_SUMMARY_PATH = Path("build/hok-016cx-summary.json")

# Breakpoint targets (all unslid, HOK-016-A/B/C.1 locked).
BP_REWRITE_AT = "0x103a227a4"     # MessagingInit entry (pre-QtsFS init)
BP_AT_900 = "0x108877f54"         # +900 tbz (readiness A w0)
BP_AT_912 = "0x108877f60"         # +912 tbz (readiness B w0 — key)
BP_FAIL_SINK = "0x108878124"      # +1364 Create Failed sink


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _run_one_seed(
    seed: str, lldb_timeout: float, settle_seconds: float
) -> tuple[int, Path]:
    """Run hok006 runner for a single seed candidate. Returns
    (returncode, output_path)."""
    output_path = (REPO_ROOT / f"build/hok-016cx-{seed}-trace.json").resolve()
    pre_run_commands = [
        # 1. Import the LLDB helper + set SEED global.
        f"command script import {LLDB_HELPER_PATH}",
        f'script import hok016cx_lldb_cmdline_override as h; h.SEED = "{seed}"',
        # 2. BP on MessagingInit entry (pre-QtsFS bootstrap on the same
        #    NSThread worker). LLDB's `breakpoint set` has no direct
        #    Python-callback option; attach the Python callback in a
        #    second command. `breakpoint command add` with no explicit
        #    bp-id targets the **last created breakpoint**, so the
        #    `breakpoint set` and `breakpoint command add` pair MUST
        #    stay adjacent (no other `breakpoint set` between them).
        f"breakpoint set --shlib NGR --address {BP_REWRITE_AT} "
        f"-N hok016cx_rewrite",
        "breakpoint command add -s python "
        "-F hok016cx_lldb_cmdline_override.rewrite_cmdline_on_hit",
        # 3. w0 probes at the two tbz gates in 0x108877bd0.
        f"breakpoint set --shlib NGR --address {BP_AT_900} "
        f"-N bp_at_900_before_tbz -C 'register read x0' --auto-continue true",
        f"breakpoint set --shlib NGR --address {BP_AT_912} "
        f"-N bp_at_912_before_tbz -C 'register read x0' --auto-continue true",
        # 4. Hard-stop at Create Failed sink (terminates the run).
        f"breakpoint set --shlib NGR --address {BP_FAIL_SINK} "
        f"-N bp_at_1364_failure_sink -C 'thread backtrace' "
        f"-C 'register read x19 x24'",
    ]

    runner_cmd: list[str] = [
        "python3", str(REPO_ROOT / "Scripts/hok006_ngr_lldb_runner.py"),
        "--skip-build-install",
        "--lldb-timeout", str(lldb_timeout),
        "--settle-seconds", str(settle_seconds),
        "--output", str(output_path),
    ]
    for cmd in pre_run_commands:
        runner_cmd.extend(["--pre-run-command", cmd])

    print(f"\n=== running seed={seed!r} ===")
    print("  output: " + str(output_path))
    # Suppress hok006 runner stdout to keep the summary readable; errors
    # still flow through. The structured JSON report is sufficient.
    proc = subprocess.run(
        runner_cmd, cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    # Print last line of hok006 runner's summary so we know it finished.
    if proc.stdout:
        last = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
        if last: print("  hok006 summary: " + last[:200])
    return proc.returncode, output_path


def _parse_run_report(seed: str, report_path: Path) -> dict[str, Any]:
    """Extract the seed-experiment-relevant signals from a hok006 report."""
    if not report_path.exists():
        return {"seed": seed, "error": f"report not found: {report_path}"}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return {"seed": seed, "error": f"json decode failed: {exc}"}

    parsed = (report.get("launch") or {}).get("launchAppWithLLDB") or {}
    parsed = parsed.get("parsed") or {}
    lldb = parsed.get("lldb") or {}
    transcript = str(lldb.get("transcript") or "")
    lines = transcript.splitlines()

    rewrite_hits = [
        l for l in lines
        if "[hok016cx] rewrote FCommandLine::CmdLine" in l
    ]
    ue4_not_found = [
        l for l in lines
        if "Project file not found" in l
    ]
    # Harvest x0 at each BP-callback-echoed `register read x0` block.
    # Critically, LLDB echoes BP `-C` callback commands with a *double*
    # space after `(lldb)` (e.g. `(lldb)  register read x0`) while
    # interactive/scripted `breakpoint set ... -C 'register read x0'`
    # commands only use a single space. Anchoring on the double-space
    # prefix avoids matching the BP-creation lines in the pre-run
    # preamble (which also contain the phrase "register read x0" inside
    # the -C argument).
    x0_values: list[str] = []
    for i, l in enumerate(lines):
        if l.startswith("(lldb)  register read x0"):
            for j in range(i + 1, min(len(lines), i + 5)):
                m = re.match(r"\s*x0\s*=\s*(0x[0-9a-fA-F]+)", lines[j])
                if m:
                    x0_values.append(m.group(1))
                    break
    fail_sink_hits = len(re.findall(r"stop reason = breakpoint \d+\.", transcript))

    # Infer w0@+900 (first x0) and w0@+912 (second x0) by position.
    w0_at_900 = x0_values[0] if len(x0_values) >= 1 else None
    w0_at_912 = x0_values[1] if len(x0_values) >= 2 else None

    return {
        "seed": seed,
        "reportPath": str(report_path),
        "transcriptLength": len(transcript),
        "rewriteHitCount": len(rewrite_hits),
        "rewriteMessage": (rewrite_hits[0].strip() if rewrite_hits else None),
        "ue4ProjectFileNotFoundCount": len(ue4_not_found),
        "ue4ProjectFileNotFoundFirst": (
            ue4_not_found[0].strip() if ue4_not_found else None
        ),
        "x0ReadingsAll": x0_values,
        "w0At900": w0_at_900,
        "w0At912": w0_at_912,
        "failSinkHitCount": fail_sink_hits,
        # Core go/no-go: seed candidate "wins" when readiness-B tbz
        # sees w0 != 0 AND failure sink was not hit.
        "readinessBPass": (
            w0_at_912 is not None and int(w0_at_912, 16) != 0
        ),
        "failSinkClear": fail_sink_hits == 0,
    }


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=(
            "HOK-016-C.X.1: dynamically override FCommandLine::CmdLine "
            "seed via LLDB Python, compare w0@+912 across candidates"
        )
    )
    ap.add_argument(
        "--seeds",
        default=",".join(DEFAULT_SEEDS),
        help=(
            "comma-separated seed candidate keys (from "
            "hok016cx_lldb_cmdline_override._SEED_CANDIDATES)"
        ),
    )
    ap.add_argument("--lldb-timeout", type=float, default=25.0)
    ap.add_argument("--settle-seconds", type=float, default=22.0)
    ap.add_argument(
        "--output-summary",
        default=str(DEFAULT_SUMMARY_PATH),
        help="summary JSON output path",
    )
    return ap


def main() -> int:
    args = build_parser().parse_args()
    seeds = [s.strip() for s in args.seeds.split(",") if s.strip()]
    if not seeds:
        print("error: no seeds provided", file=sys.stderr)
        return 1

    summary_path = Path(args.output_summary)
    if not summary_path.is_absolute():
        summary_path = (REPO_ROOT / summary_path).resolve()
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    per_seed: list[dict[str, Any]] = []
    for seed in seeds:
        rc, report_path = _run_one_seed(
            seed, args.lldb_timeout, args.settle_seconds
        )
        parsed = _parse_run_report(seed, report_path)
        parsed["runnerReturnCode"] = rc
        per_seed.append(parsed)

    summary = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "seeds": seeds,
        "perSeed": per_seed,
        "winners": [
            p["seed"] for p in per_seed
            if p.get("readinessBPass") and p.get("failSinkClear")
        ],
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"\n=== HOK-016-C.X.1 summary: {summary_path} ===")
    print(
        f"  {'seed':<12}  {'rewriteHit':<10}  {'ue4NotFound':<12}  "
        f"{'w0@+900':<18}  {'w0@+912':<18}  {'failSink':<10}  winner?"
    )
    for p in per_seed:
        is_winner = p.get("readinessBPass") and p.get("failSinkClear")
        print(
            f"  {p.get('seed',''):<12}  "
            f"{p.get('rewriteHitCount',0):<10}  "
            f"{p.get('ue4ProjectFileNotFoundCount',0):<12}  "
            f"{str(p.get('w0At900','N/A')):<18}  "
            f"{str(p.get('w0At912','N/A')):<18}  "
            f"{p.get('failSinkHitCount',0):<10}  "
            f"{'YES' if is_winner else ''}"
        )
    print(f"\nwinners: {summary['winners'] or '(none)'}")
    return 0 if summary["winners"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
