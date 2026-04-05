#!/usr/bin/env python3
"""
e006d_matrix_runner.py — 串联 E-006d8 的 replacement 开关、run 快照与矩阵分析。

示例：
    python3 Scripts/e006d_matrix_runner.py prepare-run \
        --bundle-id com.miHoYo.Yuanshen \
        --mode off \
        --run-index 1

    python3 Scripts/e006d_matrix_runner.py finalize-run \
        --bundle-id com.miHoYo.Yuanshen \
        --mode off \
        --run-index 1 \
        --gputrace ~/captures/replacement-off-run1.gputrace

    python3 Scripts/e006d_matrix_runner.py analyze \
        --bundle-id com.miHoYo.Yuanshen \
        --output build/e006d-run-matrix.json
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
SET_MODE_SCRIPT = SCRIPT_DIR / "set_shader_replacement_mode.py"
SNAPSHOT_SCRIPT = SCRIPT_DIR / "snapshot_capture_run.py"
ANALYZE_SCRIPT = SCRIPT_DIR / "analyze_capture_run_matrix.py"
DEFAULT_RUNS_ROOT = Path("build/e006d-run-snapshots")


def default_capture_root(bundle_id: str) -> Path:
    return Path.home() / "Library/Containers" / bundle_id / "Data/Documents/Captures"


def resolve_latest_gputrace(capture_root: Path) -> Path:
    expanded_root = capture_root.expanduser().resolve()
    if not expanded_root.is_dir():
        raise SystemExit(f"capture root not found: {expanded_root}")

    candidates = [
        child for child in expanded_root.iterdir()
        if child.is_dir() and child.suffix == ".gputrace"
    ]
    if not candidates:
        raise SystemExit(f"no .gputrace directories found under {expanded_root}")

    candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return candidates[0]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Orchestrate the standard E-006d8 off/on matrix workflow"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser(
        "prepare-run",
        help="toggle replacement mode and print the standard next-step commands",
    )
    add_common_run_args(prepare_parser, include_gputrace=False)
    prepare_parser.add_argument(
        "--container",
        help="override PlayCover container root passed to the toggle script",
    )
    prepare_parser.add_argument(
        "--print-path",
        action="store_true",
        help="forward --print-path to set_shader_replacement_mode.py",
    )

    finalize_parser = subparsers.add_parser(
        "finalize-run",
        help="snapshot one run using the standard replacement-<mode>-runN label",
    )
    add_common_run_args(finalize_parser, include_gputrace=True)
    finalize_parser.add_argument(
        "--container",
        help="override PlayCover container root passed to the snapshot script",
    )
    finalize_parser.add_argument(
        "--output-root",
        default=str(DEFAULT_RUNS_ROOT),
        help="snapshot root directory (default: build/e006d-run-snapshots)",
    )
    finalize_parser.add_argument(
        "--skip-diagnostics",
        action="store_true",
        help="forward --skip-diagnostics to snapshot_capture_run.py",
    )
    finalize_parser.add_argument(
        "--print-compare-path",
        action="store_true",
        help="forward --print-compare-path to snapshot_capture_run.py",
    )
    finalize_parser.add_argument(
        "--latest-gputrace",
        action="store_true",
        help="use the newest .gputrace from the target app's default Captures directory",
    )
    finalize_parser.add_argument(
        "--capture-root",
        help="override the directory searched by --latest-gputrace (default: ~/Library/Containers/<bundle-id>/Data/Documents/Captures)",
    )

    analyze_parser = subparsers.add_parser(
        "analyze",
        help="run analyze_capture_run_matrix.py against the standard runs root",
    )
    analyze_parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    analyze_parser.add_argument(
        "--runs-root",
        default=str(DEFAULT_RUNS_ROOT),
        help="snapshot root containing <label>/<bundle-id> directories",
    )
    analyze_parser.add_argument("--output", help="optional matrix report output path")

    return parser


def add_common_run_args(parser: argparse.ArgumentParser, *, include_gputrace: bool) -> None:
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("off", "on"),
        help="replacement mode for this run",
    )
    parser.add_argument(
        "--run-index",
        type=int,
        required=True,
        help="1-based index used to generate replacement-<mode>-runN labels",
    )
    if include_gputrace:
        parser.add_argument("--gputrace", help="optional .gputrace directory for this run")


def standard_label(mode: str, run_index: int) -> str:
    if run_index <= 0:
        raise SystemExit("--run-index must be >= 1")
    return f"replacement-{mode}-run{run_index}"


def run_command(command: list[str]) -> int:
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)
    return completed.returncode


def prepare_run(args: argparse.Namespace) -> int:
    label = standard_label(args.mode, args.run_index)
    capture_root = default_capture_root(args.bundle_id)
    command = [
        sys.executable,
        str(SET_MODE_SCRIPT),
        "--bundle-id",
        args.bundle_id,
        "--mode",
        args.mode,
    ]
    if args.container:
        command.extend(["--container", args.container])
    if args.print_path:
        command.append("--print-path")
    run_command(command)

    print(f"prepared {label}")
    print("next:")
    print("1. Launch the app and reproduce the same scene once.")
    print(f"2. If you capture a trace, prefer the target app default Captures directory: {capture_root}")
    print("3. Finalize the run with:")
    finalize_command = [
        "python3",
        "Scripts/e006d_matrix_runner.py",
        "finalize-run",
        "--bundle-id",
        args.bundle_id,
        "--mode",
        args.mode,
        "--run-index",
        str(args.run_index),
        "--latest-gputrace",
        "--print-compare-path",
    ]
    print("   " + " ".join(finalize_command))
    print("   # Or replace --latest-gputrace with --gputrace /path/to/trace.gputrace if needed")
    return 0


def resolve_finalize_gputrace(args: argparse.Namespace) -> Path | None:
    if args.gputrace and args.latest_gputrace:
        raise SystemExit("--gputrace and --latest-gputrace are mutually exclusive")

    if args.gputrace:
        return Path(args.gputrace).expanduser().resolve()

    if not args.latest_gputrace:
        return None

    capture_root = Path(args.capture_root).expanduser().resolve() if args.capture_root else default_capture_root(args.bundle_id)
    return resolve_latest_gputrace(capture_root)


def finalize_run(args: argparse.Namespace) -> int:
    label = standard_label(args.mode, args.run_index)
    gputrace_path = resolve_finalize_gputrace(args)
    command = [
        sys.executable,
        str(SNAPSHOT_SCRIPT),
        "--bundle-id",
        args.bundle_id,
        "--label",
        label,
        "--output-root",
        args.output_root,
    ]
    if args.container:
        command.extend(["--container", args.container])
    if gputrace_path is not None:
        print(f"using gputrace: {gputrace_path}")
        command.extend(["--gputrace", str(gputrace_path)])
    if args.skip_diagnostics:
        command.append("--skip-diagnostics")
    if args.print_compare_path:
        command.append("--print-compare-path")
    return run_command(command)


def analyze_runs(args: argparse.Namespace) -> int:
    command = [
        sys.executable,
        str(ANALYZE_SCRIPT),
        "--runs-root",
        args.runs_root,
        "--bundle-id",
        args.bundle_id,
    ]
    if args.output:
        command.extend(["--output", args.output])
    return run_command(command)


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "prepare-run":
        return prepare_run(args)
    if args.command == "finalize-run":
        return finalize_run(args)
    if args.command == "analyze":
        return analyze_runs(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
