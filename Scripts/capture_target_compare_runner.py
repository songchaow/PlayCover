#!/usr/bin/env python3
"""
capture_target_compare_runner.py — 固化 CTF2-004 的 `device` vs `queue_scope` snapshot 对照流程。

示例：
    python3 Scripts/capture_target_compare_runner.py finalize-pair \
        --bundle-id com.papegames.lysk \
        --pair-label fresh-round-1 \
        --device-gputrace ~/captures/device.gputrace \
        --queue-scope-gputrace ~/captures/queue_scope.gputrace

    python3 Scripts/capture_target_compare_runner.py compare-pair \
        --bundle-id com.papegames.lysk \
        --pair-label fresh-round-1
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
SNAPSHOT_SCRIPT = SCRIPT_DIR / "snapshot_capture_run.py"
COMPARE_SCRIPT = SCRIPT_DIR / "compare_capture_runs.py"
DEFAULT_OUTPUT_ROOT = Path("build/capture-target-fix2-snapshots")
DEFAULT_REPORTS_DIRNAME = "reports"
DEFAULT_COMPARE_TARGET_A = "device"
DEFAULT_COMPARE_TARGET_B = "queue_scope"
VALID_CAPTURE_TARGETS = ("device", "scope", "queue", "queue_scope")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Orchestrate the standard CaptureTargetFix2 snapshot comparison workflow"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    finalize_target_parser = subparsers.add_parser(
        "finalize-target",
        help="snapshot one capture target run with launch diagnostics and optional gputrace preservation",
    )
    add_finalize_target_args(finalize_target_parser)

    finalize_pair_parser = subparsers.add_parser(
        "finalize-pair",
        help="snapshot both `device` and `queue_scope` runs, then emit a compare report",
    )
    add_finalize_pair_args(finalize_pair_parser)

    compare_pair_parser = subparsers.add_parser(
        "compare-pair",
        help="run compare_capture_runs.py against two finalized target snapshots",
    )
    add_compare_pair_args(compare_pair_parser)
    return parser


def add_common_snapshot_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument(
        "--pair-label",
        required=True,
        help="shared label for this same-round comparison; per-target labels become <pair-label>-<target>",
    )
    parser.add_argument(
        "--container",
        help="override PlayCover container root passed to snapshot_capture_run.py",
    )
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="snapshot root directory (default: build/capture-target-fix2-snapshots)",
    )
    parser.add_argument(
        "--diagnostics-root",
        help="override RuntimeLaunchDiagnostics root passed to snapshot_capture_run.py",
    )
    parser.add_argument(
        "--launch-summary-limit",
        type=int,
        default=5,
        help="how many recent processLaunchId groups to preserve in each snapshot",
    )
    parser.add_argument(
        "--skip-diagnostics",
        action="store_true",
        help="forward --skip-diagnostics to snapshot_capture_run.py",
    )
    parser.add_argument(
        "--skip-launch-diagnostics",
        action="store_true",
        help="forward --skip-launch-diagnostics to snapshot_capture_run.py",
    )


def add_finalize_target_args(parser: argparse.ArgumentParser) -> None:
    add_common_snapshot_args(parser)
    parser.add_argument(
        "--capture-target",
        required=True,
        choices=VALID_CAPTURE_TARGETS,
        help="capture target metadata for this finalized snapshot",
    )
    parser.add_argument("--gputrace", help="optional .gputrace directory for this target run")
    parser.add_argument(
        "--capture-status-json",
        help="optional get_capture_status JSON file for this target run",
    )
    parser.add_argument(
        "--latest-gputrace",
        action="store_true",
        help="use the newest .gputrace from the configured capture root",
    )
    parser.add_argument(
        "--capture-root",
        help="override the directory searched by --latest-gputrace",
    )
    parser.add_argument(
        "--print-snapshot-path",
        action="store_true",
        help="print the finalized snapshot bundle path after creation",
    )


def add_finalize_pair_args(parser: argparse.ArgumentParser) -> None:
    add_common_snapshot_args(parser)
    parser.add_argument("--device-gputrace", required=True, help="device target .gputrace directory")
    parser.add_argument(
        "--device-capture-status-json",
        help="optional get_capture_status JSON captured during the device-target run",
    )
    parser.add_argument(
        "--queue-scope-gputrace",
        required=True,
        help="queue_scope target .gputrace directory",
    )
    parser.add_argument(
        "--queue-scope-capture-status-json",
        help="optional get_capture_status JSON captured during the queue_scope run",
    )
    parser.add_argument(
        "--report-output",
        help="optional JSON output path for the compare report",
    )


def add_compare_pair_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument("--pair-label", required=True, help="shared pair label used during snapshot finalization")
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help="snapshot root directory (default: build/capture-target-fix2-snapshots)",
    )
    parser.add_argument(
        "--target-a",
        default=DEFAULT_COMPARE_TARGET_A,
        choices=VALID_CAPTURE_TARGETS,
        help="first capture target label to compare (default: device)",
    )
    parser.add_argument(
        "--target-b",
        default=DEFAULT_COMPARE_TARGET_B,
        choices=VALID_CAPTURE_TARGETS,
        help="second capture target label to compare (default: queue_scope)",
    )
    parser.add_argument(
        "--report-output",
        help="optional JSON output path for the compare report",
    )


def default_capture_root(bundle_id: str) -> Path:
    return Path.home() / "Library/Containers" / bundle_id / "Data/Documents/Captures"


def resolve_latest_gputrace(capture_root: Path) -> Path:
    expanded_root = capture_root.expanduser().resolve()
    if not expanded_root.is_dir():
        raise SystemExit(f"capture root not found: {expanded_root}")

    candidates = [
        child for child in expanded_root.iterdir() if child.is_dir() and child.suffix == ".gputrace"
    ]
    if not candidates:
        raise SystemExit(f"no .gputrace directories found under {expanded_root}")

    candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return candidates[0]


def run_command(command: list[str]) -> int:
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)
    return completed.returncode


def snapshot_label(pair_label: str, capture_target: str) -> str:
    return f"{pair_label}-{capture_target}"


def snapshot_bundle_dir(output_root: Path, pair_label: str, capture_target: str, bundle_id: str) -> Path:
    return output_root / snapshot_label(pair_label, capture_target) / bundle_id


def resolve_report_output(
    output_root: Path,
    pair_label: str,
    bundle_id: str,
    target_a: str,
    target_b: str,
    explicit_output: str | None,
) -> Path:
    if explicit_output:
        return Path(explicit_output).expanduser().resolve()
    return output_root / DEFAULT_REPORTS_DIRNAME / f"{pair_label}-{target_a}-vs-{target_b}" / f"{bundle_id}.json"


def build_snapshot_command(
    *,
    bundle_id: str,
    pair_label: str,
    capture_target: str,
    output_root: Path,
    container: str | None,
    diagnostics_root: str | None,
    launch_summary_limit: int,
    skip_diagnostics: bool,
    skip_launch_diagnostics: bool,
    gputrace: str | None,
    capture_status_json: str | None,
) -> list[str]:
    command = [
        sys.executable,
        str(SNAPSHOT_SCRIPT),
        "--bundle-id",
        bundle_id,
        "--label",
        snapshot_label(pair_label, capture_target),
        "--output-root",
        str(output_root),
        "--capture-target",
        capture_target,
        "--launch-summary-limit",
        str(max(launch_summary_limit, 1)),
    ]
    if container:
        command.extend(["--container", container])
    if diagnostics_root:
        command.extend(["--diagnostics-root", diagnostics_root])
    if skip_diagnostics:
        command.append("--skip-diagnostics")
    if skip_launch_diagnostics:
        command.append("--skip-launch-diagnostics")
    if gputrace:
        command.extend(["--gputrace", gputrace])
    if capture_status_json:
        command.extend(["--capture-status-json", capture_status_json])
    return command


def resolve_target_gputrace(args: argparse.Namespace) -> Path | None:
    if args.gputrace and args.latest_gputrace:
        raise SystemExit("--gputrace and --latest-gputrace are mutually exclusive")
    if args.gputrace:
        return Path(args.gputrace).expanduser().resolve()
    if not args.latest_gputrace:
        return None

    capture_root = Path(args.capture_root).expanduser().resolve() if args.capture_root else default_capture_root(args.bundle_id)
    return resolve_latest_gputrace(capture_root)


def finalize_target(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root).expanduser().resolve()
    gputrace_path = resolve_target_gputrace(args)
    command = build_snapshot_command(
        bundle_id=args.bundle_id,
        pair_label=args.pair_label,
        capture_target=args.capture_target,
        output_root=output_root,
        container=args.container,
        diagnostics_root=args.diagnostics_root,
        launch_summary_limit=args.launch_summary_limit,
        skip_diagnostics=args.skip_diagnostics,
        skip_launch_diagnostics=args.skip_launch_diagnostics,
        gputrace=str(gputrace_path) if gputrace_path is not None else None,
        capture_status_json=args.capture_status_json,
    )
    run_command(command)
    snapshot_path = snapshot_bundle_dir(output_root, args.pair_label, args.capture_target, args.bundle_id)
    print(f"target snapshot created: {snapshot_path}")
    if args.print_snapshot_path:
        print(snapshot_path)
    return 0


def compare_pair(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root).expanduser().resolve()
    run_a = snapshot_bundle_dir(output_root, args.pair_label, args.target_a, args.bundle_id)
    run_b = snapshot_bundle_dir(output_root, args.pair_label, args.target_b, args.bundle_id)
    report_output = resolve_report_output(
        output_root,
        args.pair_label,
        args.bundle_id,
        args.target_a,
        args.target_b,
        args.report_output,
    )
    command = [
        sys.executable,
        str(COMPARE_SCRIPT),
        "--run-a",
        str(run_a),
        "--run-b",
        str(run_b),
        "--output",
        str(report_output),
    ]
    run_command(command)
    print(f"pair compare report: {report_output}")
    return 0


def finalize_pair(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root).expanduser().resolve()
    for capture_target, gputrace, capture_status_json in (
        ("device", args.device_gputrace, args.device_capture_status_json),
        ("queue_scope", args.queue_scope_gputrace, args.queue_scope_capture_status_json),
    ):
        command = build_snapshot_command(
            bundle_id=args.bundle_id,
            pair_label=args.pair_label,
            capture_target=capture_target,
            output_root=output_root,
            container=args.container,
            diagnostics_root=args.diagnostics_root,
            launch_summary_limit=args.launch_summary_limit,
            skip_diagnostics=args.skip_diagnostics,
            skip_launch_diagnostics=args.skip_launch_diagnostics,
            gputrace=str(Path(gputrace).expanduser().resolve()),
            capture_status_json=capture_status_json,
        )
        run_command(command)

    compare_args = argparse.Namespace(
        bundle_id=args.bundle_id,
        pair_label=args.pair_label,
        output_root=str(output_root),
        target_a=DEFAULT_COMPARE_TARGET_A,
        target_b=DEFAULT_COMPARE_TARGET_B,
        report_output=args.report_output,
    )
    compare_pair(compare_args)
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "finalize-target":
        return finalize_target(args)
    if args.command == "finalize-pair":
        return finalize_pair(args)
    if args.command == "compare-pair":
        return compare_pair(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
