#!/usr/bin/env python3
"""Run the RIPC-010-A4 real iPad LLDB probe end-to-end."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pexpect

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_UDID = "00008103-0011050A0E3B001E"
DEFAULT_BUNDLE_ID = "com.songdog.ripc.debug"
DEFAULT_WAIT_SECONDS = 45.0
DEFAULT_ATTACH_TIMEOUT = 60.0
DEFAULT_COMMAND_TIMEOUT = 15.0

PROBE_PATH = REPO_ROOT / "Scripts" / "ripc_010a_materializer_probe.py"
DEFAULT_PROBE_JSON_PATH = BUILD_DIR / "ripc-010a-ipad-materializer-args.json"
DEFAULT_PROBE_LOG_PATH = Path("/tmp/ripc-010a-materializer-log.jsonl")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the RIPC-010-A4 real iPad LLDB probe")
    parser.add_argument("--udid", default=DEFAULT_UDID)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--wait-seconds", type=float, default=DEFAULT_WAIT_SECONDS)
    parser.add_argument("--attach-timeout", type=float, default=DEFAULT_ATTACH_TIMEOUT)
    parser.add_argument("--command-timeout", type=float, default=DEFAULT_COMMAND_TIMEOUT)
    parser.add_argument(
        "--pre-inject-delay",
        type=float,
        default=0.0,
        help="seconds to continue before interrupting and importing the probe",
    )
    parser.add_argument(
        "--output",
        default=str(BUILD_DIR / "ripc-010a-real-ipad-lldb-run.json"),
        help="structured run report path",
    )
    parser.add_argument(
        "--transcript",
        default=str(BUILD_DIR / "ripc-010a-real-ipad-lldb-transcript.log"),
        help="LLDB transcript output path",
    )
    parser.add_argument(
        "--launch-json",
        default="/tmp/ripc_010a_launch.json",
        help="temporary devicectl launch JSON path",
    )
    return parser


def run_command(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=REPO_ROOT, text=True, capture_output=True)


def derive_probe_artifact_paths(output_path: Path) -> tuple[Path, Path]:
    stem = output_path.stem
    prefix = "ripc-010a-real-ipad-lldb-run"
    if stem == prefix:
        return DEFAULT_PROBE_JSON_PATH, DEFAULT_PROBE_LOG_PATH
    if stem.startswith(f"{prefix}-"):
        suffix = stem[len(prefix) :]
        return (
            BUILD_DIR / f"ripc-010a-ipad-materializer-args{suffix}.json",
            Path("/tmp") / f"ripc-010a-materializer-log{suffix}.jsonl",
        )
    return (
        output_path.with_name(f"{stem}.materializer-args.json"),
        Path("/tmp") / f"{stem}.materializer-log.jsonl",
    )


def clear_artifact(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass


def format_mtime(path: Path) -> str | None:
    if not path.exists():
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(path.stat().st_mtime))


def launch_start_stopped(udid: str, bundle_id: str, launch_json: Path) -> dict:
    cmd = [
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        udid,
        "--terminate-existing",
        "--start-stopped",
        "--json-output",
        str(launch_json),
        bundle_id,
    ]
    result = run_command(cmd)
    if result.returncode != 0:
        raise RuntimeError(
            "devicectl launch failed: "
            f"stdout={result.stdout[-1000:]} stderr={result.stderr[-1000:]}"
        )
    payload = json.loads(launch_json.read_text(encoding="utf-8"))
    pid = int(payload["result"]["process"]["processIdentifier"])
    executable = payload["result"]["process"].get("executable")
    return {
        "command": cmd,
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "pid": pid,
        "executable": executable,
        "payload": payload,
    }


def _expect_prompt(child: pexpect.spawn, timeout: float) -> None:
    child.expect(r"\(lldb\)", timeout=timeout)


def _send_and_wait(child: pexpect.spawn, command: str, timeout: float) -> str:
    child.sendline(command)
    child.expect(r"\(lldb\)", timeout=timeout)
    return child.before


def _interrupt_to_prompt(child: pexpect.spawn, command_timeout: float) -> tuple[bool, str | None]:
    try:
        child.sendline("process interrupt")
        child.expect(r"Process .* stopped", timeout=max(command_timeout, 20.0))
        _expect_prompt(child, command_timeout)
        return True, None
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def attach_and_run(
    udid: str,
    pid: int,
    transcript_path: Path,
    attach_timeout: float,
    command_timeout: float,
    wait_seconds: float,
    pre_inject_delay: float,
    probe_json_path: Path,
    probe_log_path: Path,
) -> dict:
    transcript_path.parent.mkdir(parents=True, exist_ok=True)
    probe_json_path.parent.mkdir(parents=True, exist_ok=True)
    probe_log_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["TERM"] = "dumb"
    env["RIPC_010A_PROBE_JSON_PATH"] = str(probe_json_path)
    env["RIPC_010A_PROBE_LOG_PATH"] = str(probe_log_path)

    with transcript_path.open("w", encoding="utf-8") as transcript:
        child = pexpect.spawn(
            "/usr/bin/xcrun",
            ["lldb"],
            encoding="utf-8",
            timeout=max(attach_timeout, command_timeout, wait_seconds, pre_inject_delay, 10.0) + 10.0,
            cwd=str(REPO_ROOT),
            env=env,
        )
        child.logfile = transcript

        _expect_prompt(child, command_timeout)
        _send_and_wait(child, "settings set auto-confirm true", command_timeout)
        _send_and_wait(child, "settings set use-color false", command_timeout)
        _send_and_wait(child, f"device select {udid}", command_timeout)

        child.sendline(f"device process attach -p {pid}")
        child.expect(rf"Process {pid} stopped", timeout=attach_timeout)
        _expect_prompt(child, command_timeout)

        initial_backtrace = _send_and_wait(child, "thread backtrace", command_timeout)
        initial_image_list = _send_and_wait(child, "image list NGR", command_timeout)

        pre_inject_status = {
            "delaySeconds": pre_inject_delay,
            "continued": False,
            "interruptOk": True,
            "interruptError": None,
            "stoppedEarly": False,
            "earlyStopText": None,
            "backtraceAfterDelay": None,
            "imageListAfterDelay": None,
        }

        if pre_inject_delay > 0:
            child.sendline("continue")
            pre_inject_status["continued"] = True
            early_patterns = [rf"Process {pid} stopped", pexpect.TIMEOUT, pexpect.EOF]
            idx = child.expect(early_patterns, timeout=pre_inject_delay)
            if idx == 0:
                pre_inject_status["stoppedEarly"] = True
                pre_inject_status["earlyStopText"] = child.match.group(0)
                _expect_prompt(child, command_timeout)
            elif idx == 1:
                ok, err = _interrupt_to_prompt(child, command_timeout)
                pre_inject_status["interruptOk"] = ok
                pre_inject_status["interruptError"] = err
            else:
                pre_inject_status["interruptOk"] = False
                pre_inject_status["interruptError"] = "LLDB EOF before delayed injection"

            if pre_inject_status["interruptOk"]:
                pre_inject_status["backtraceAfterDelay"] = _send_and_wait(child, "thread backtrace", command_timeout)
                pre_inject_status["imageListAfterDelay"] = _send_and_wait(child, "image list NGR", command_timeout)

        _send_and_wait(child, f"command script import {PROBE_PATH}", command_timeout)
        pre_continue_breakpoint_list = _send_and_wait(child, "breakpoint list", command_timeout)

        child.sendline("continue")

        hits: list[str] = []
        unexpected_stops: list[str] = []
        deadline = time.monotonic() + wait_seconds
        patterns = [
            r"\[ripc-010a-[^\]]+\].*",
            rf"Process {pid} stopped",
            pexpect.TIMEOUT,
            pexpect.EOF,
        ]
        while time.monotonic() < deadline:
            remaining = max(0.5, min(5.0, deadline - time.monotonic()))
            idx = child.expect(patterns, timeout=remaining)
            if idx == 0:
                hits.append(child.match.group(0))
                continue
            if idx == 1:
                unexpected_stops.append(child.match.group(0))
                break
            if idx == 2:
                continue
            if idx == 3:
                break

        interrupt_ok, interrupt_error = _interrupt_to_prompt(child, command_timeout)

        breakpoint_list = ""
        backtrace_tail = ""
        final_image_list = ""
        process_status = ""
        if interrupt_ok:
            try:
                breakpoint_list = _send_and_wait(child, "breakpoint list", command_timeout)
            except Exception as exc:  # noqa: BLE001
                breakpoint_list = f"<error: {exc}>"
            try:
                backtrace_tail = _send_and_wait(child, "thread backtrace", command_timeout)
            except Exception as exc:  # noqa: BLE001
                backtrace_tail = f"<error: {exc}>"
            try:
                final_image_list = _send_and_wait(child, "image list NGR", command_timeout)
            except Exception as exc:  # noqa: BLE001
                final_image_list = f"<error: {exc}>"
            try:
                process_status = _send_and_wait(child, "process status", command_timeout)
            except Exception as exc:  # noqa: BLE001
                process_status = f"<error: {exc}>"

        try:
            child.sendline("quit")
            child.expect(pexpect.EOF, timeout=command_timeout)
        except Exception:
            try:
                child.close(force=True)
            except Exception:
                pass

    return {
        "preInjectStatus": pre_inject_status,
        "initialBacktrace": initial_backtrace,
        "initialImageList": initial_image_list,
        "preContinueBreakpointList": pre_continue_breakpoint_list,
        "hits": hits,
        "unexpectedStops": unexpected_stops,
        "interruptOk": interrupt_ok,
        "interruptError": interrupt_error,
        "breakpointList": breakpoint_list,
        "backtraceTail": backtrace_tail,
        "finalImageList": final_image_list,
        "processStatus": process_status,
    }


def read_probe_artifacts(probe_json_path: Path, probe_log_path: Path) -> dict:
    probe_payload = None
    if probe_json_path.exists():
        try:
            probe_payload = json.loads(probe_json_path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            probe_payload = {"error": str(exc)}
    probe_log_tail = None
    if probe_log_path.exists():
        try:
            lines = probe_log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            probe_log_tail = "\n".join(lines[-80:])
        except Exception as exc:  # noqa: BLE001
            probe_log_tail = f"<error: {exc}>"
    record_count = 0
    if isinstance(probe_payload, dict):
        explicit_count = probe_payload.get("recordCount")
        if isinstance(explicit_count, int):
            record_count = explicit_count
        else:
            records = probe_payload.get("records")
            if isinstance(records, list):
                record_count = len(records)
    return {
        "probeJsonPath": str(probe_json_path),
        "probeLogPath": str(probe_log_path),
        "probeJsonExists": probe_json_path.exists(),
        "probeLogExists": probe_log_path.exists(),
        "probeJsonModifiedAt": format_mtime(probe_json_path),
        "probeLogModifiedAt": format_mtime(probe_log_path),
        "recordCount": record_count,
        "probePayload": probe_payload,
        "probeLogTail": probe_log_tail,
    }


def main() -> int:
    args = build_parser().parse_args()
    output_path = Path(args.output).expanduser().resolve()
    transcript_path = Path(args.transcript).expanduser().resolve()
    launch_json = Path(args.launch_json).expanduser().resolve()
    probe_json_path, probe_log_path = derive_probe_artifact_paths(output_path)

    clear_artifact(probe_json_path)
    clear_artifact(probe_log_path)

    report: dict = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "bundleId": args.bundle_id,
        "udid": args.udid,
        "probePath": str(PROBE_PATH),
        "transcriptPath": str(transcript_path),
        "launchJsonPath": str(launch_json),
        "waitSeconds": args.wait_seconds,
        "attachTimeout": args.attach_timeout,
        "commandTimeout": args.command_timeout,
        "preInjectDelay": args.pre_inject_delay,
    }

    try:
        launch = launch_start_stopped(args.udid, args.bundle_id, launch_json)
        report["launch"] = {
            "pid": launch["pid"],
            "executable": launch["executable"],
            "stdoutTail": launch["stdout"][-2000:],
            "stderrTail": launch["stderr"][-2000:],
        }

        lldb = attach_and_run(
            udid=args.udid,
            pid=launch["pid"],
            transcript_path=transcript_path,
            attach_timeout=args.attach_timeout,
            command_timeout=args.command_timeout,
            wait_seconds=args.wait_seconds,
            pre_inject_delay=args.pre_inject_delay,
            probe_json_path=probe_json_path,
            probe_log_path=probe_log_path,
        )
        report["lldb"] = lldb
        report["artifacts"] = read_probe_artifacts(probe_json_path, probe_log_path)
        report["success"] = True
    except Exception as exc:  # noqa: BLE001
        report["success"] = False
        report["fatalError"] = {
            "type": type(exc).__name__,
            "message": str(exc),
        }
        report["artifacts"] = read_probe_artifacts(probe_json_path, probe_log_path)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(
        {
            "success": report.get("success"),
            "output": str(output_path),
            "recordCount": report.get("artifacts", {}).get("recordCount"),
            "pid": report.get("launch", {}).get("pid"),
        },
        ensure_ascii=False,
    ))
    return 0 if report.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
