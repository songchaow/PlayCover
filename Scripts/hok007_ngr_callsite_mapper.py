#!/usr/bin/env python3
"""
HOK-007A: 离线映射 `com.tencent.ngr` 的崩溃 callsite，确认 LLDB / `.ips` / 二进制字节流三者一致。
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok004_ngr_startup_runner import run_command, utc_now_iso, write_report  # noqa: E402


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_CRASH_REPORTS_ROOT = Path.home() / "Library/Logs/DiagnosticReports"
DEFAULT_LLDB_REPORT = Path("build/hok-006-ngr-lldb-report.json")
DEFAULT_OUTPUT = Path("build/hok-007-ngr-callsite-report.json")
DEFAULT_BEFORE_COUNT = 8
DEFAULT_AFTER_COUNT = 8


@dataclass(frozen=True)
class MachORegion:
    segname: str
    sectname: str | None
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Map the HOK-007 com.tencent.ngr crash callsite offline")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="target bundle identifier")
    parser.add_argument(
        "--lldb-report",
        default=str(DEFAULT_LLDB_REPORT),
        help="structured JSON report emitted by Scripts/hok006_ngr_lldb_runner.py",
    )
    parser.add_argument(
        "--ips-path",
        help="explicit .ips crash report path; defaults to the latest report referenced by the LLDB report",
    )
    parser.add_argument(
        "--binary-path",
        help="explicit NGR executable path; defaults to the path embedded in the LLDB transcript",
    )
    parser.add_argument(
        "--crash-reports-root",
        default=str(DEFAULT_CRASH_REPORTS_ROOT),
        help="macOS crash report root used for fallback report discovery",
    )
    parser.add_argument(
        "--before-count",
        type=int,
        default=DEFAULT_BEFORE_COUNT,
        help="number of instructions to request before the faulting PC",
    )
    parser.add_argument(
        "--after-count",
        type=int,
        default=DEFAULT_AFTER_COUNT,
        help="number of instructions to request after the faulting PC",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="structured JSON report output path under build/",
    )
    return parser


def parse_hex_int(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        return None
    return int(text, 0)


def compact_instruction_text(value: str | None) -> str | None:
    if not value:
        return None
    return " ".join(str(value).strip().split())


def parse_faulting_frame(frame: str | None) -> dict[str, Any]:
    if not frame:
        return {"raw": frame, "address": None, "image": None, "symbol": None, "symbolOffset": None}
    match = re.search(r"0x([0-9a-fA-F]+)\s+([^`\s]+)`(.+?)\s+\+\s+(\d+)", frame)
    if not match:
        return {"raw": frame, "address": None, "image": None, "symbol": None, "symbolOffset": None}
    return {
        "raw": frame,
        "address": int(match.group(1), 16),
        "image": match.group(2),
        "symbol": match.group(3),
        "symbolOffset": int(match.group(4), 10),
    }


def parse_faulting_instruction(instruction: str | None) -> dict[str, Any]:
    if not instruction:
        return {"raw": instruction, "address": None, "instructionOffset": None, "text": None}
    match = re.search(r"0x([0-9a-fA-F]+)\s+<\+(\d+)>:\s*(.+)$", instruction)
    if not match:
        return {
            "raw": instruction,
            "address": None,
            "instructionOffset": None,
            "text": compact_instruction_text(instruction.removeprefix("->")),
        }
    return {
        "raw": instruction,
        "address": int(match.group(1), 16),
        "instructionOffset": int(match.group(2), 10),
        "text": compact_instruction_text(match.group(3)),
    }


def parse_lldb_target_binary_path(text: str) -> Path | None:
    patterns = [
        r'target create "([^"]+)"',
        r"Current executable set to '([^']+)'",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return Path(match.group(1)).expanduser().resolve()
    return None


def parse_lldb_registers(text: str) -> dict[str, int]:
    registers: dict[str, int] = {}
    for name, value in re.findall(r"^\s*([a-z]{1,4}\d{0,2}|fp|lr|sp|pc|far|cpsr)\s*=\s*(0x[0-9a-fA-F]+)", text, re.MULTILINE):
        registers[name] = int(value, 16)
    return registers


def extract_lldb_payload(report: dict[str, Any]) -> tuple[dict[str, Any], str]:
    launch = ((report.get("launch") or {}).get("launchAppWithLLDB") or {})
    parsed = launch.get("parsed") if isinstance(launch.get("parsed"), dict) else {}
    lldb = parsed.get("lldb") if isinstance(parsed.get("lldb"), dict) else {}
    raw_text = str(launch.get("rawText") or "")
    transcript = str(lldb.get("transcript") or "")
    combined_text = "\n".join(part for part in [transcript, raw_text] if part)
    return lldb, combined_text


def parse_json_documents(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    documents: list[Any] = []
    index = 0
    length = len(text)
    while index < length:
        while index < length and text[index].isspace():
            index += 1
        if index >= length:
            break
        document, next_index = decoder.raw_decode(text, index)
        documents.append(document)
        index = next_index
    return documents


def load_ips_report(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    documents = parse_json_documents(path.read_text(encoding="utf-8"))
    if len(documents) < 2:
        raise SystemExit(f"Expected two JSON documents in .ips report: {path}")
    header = documents[0] if isinstance(documents[0], dict) else {}
    body = documents[1] if isinstance(documents[1], dict) else {}
    return header, body


def decode_instruction_stream_bytes(stream: dict[str, Any]) -> dict[str, Any]:
    before_pc = base64.b64decode(str(stream.get("beforePC") or "")) if stream.get("beforePC") else b""
    at_pc = base64.b64decode(str(stream.get("atPC") or "")) if stream.get("atPC") else b""
    return {
        "beforePC": before_pc,
        "atPC": at_pc,
        "beforePCHex": before_pc.hex(),
        "atPCHex": at_pc.hex(),
        "beforePCLength": len(before_pc),
        "atPCLength": len(at_pc),
    }


def collect_ips_registers(body: dict[str, Any]) -> tuple[dict[str, int], dict[str, Any]]:
    threads = body.get("threads") if isinstance(body.get("threads"), list) else []
    triggered = next((thread for thread in threads if isinstance(thread, dict) and thread.get("triggered")), None)
    if not isinstance(triggered, dict):
        return {}, {}
    thread_state = triggered.get("threadState") if isinstance(triggered.get("threadState"), dict) else {}
    registers: dict[str, int] = {}
    x_registers = thread_state.get("x") if isinstance(thread_state.get("x"), list) else []
    for index, register in enumerate(x_registers):
        if isinstance(register, dict) and register.get("value") is not None:
            registers[f"x{index}"] = int(register["value"])
    for name in ["pc", "far", "lr", "sp", "fp", "cpsr"]:
        if isinstance(thread_state.get(name), dict) and thread_state[name].get("value") is not None:
            registers[name] = int(thread_state[name]["value"])
    frames = triggered.get("frames") if isinstance(triggered.get("frames"), list) else []
    first_frame = frames[0] if frames and isinstance(frames[0], dict) else {}
    return registers, first_frame


def latest_crash_report(root: Path) -> Path | None:
    candidates = sorted(root.glob("NGR-*.ips"), key=lambda item: item.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def resolve_ips_path(explicit_path: str | None, report: dict[str, Any], crash_reports_root: Path) -> Path:
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f".ips report not found: {path}")
        return path

    new_reports = ((report.get("crashReports") or {}).get("newReports") or [])
    for item in reversed(new_reports):
        if isinstance(item, dict) and item.get("path"):
            path = Path(str(item["path"])).expanduser().resolve()
            if path.is_file():
                return path

    fallback = latest_crash_report(crash_reports_root)
    if fallback is not None:
        return fallback.resolve()
    raise SystemExit("No .ips report could be resolved from the LLDB report or crash report root")


def resolve_binary_path(explicit_path: str | None, lldb_text: str) -> Path:
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f"Binary not found: {path}")
        return path
    binary_path = parse_lldb_target_binary_path(lldb_text)
    if binary_path is None or not binary_path.is_file():
        raise SystemExit("Could not resolve the concrete NGR binary path from the LLDB report; pass --binary-path")
    return binary_path


def parse_macho_regions(otool_output: str) -> list[MachORegion]:
    segments: list[dict[str, Any]] = []
    current_segment: dict[str, Any] | None = None
    current_section: dict[str, Any] | None = None

    def flush_section() -> None:
        nonlocal current_section
        if current_segment is not None and current_section is not None:
            current_segment.setdefault("sections", []).append(current_section)
        current_section = None

    def flush_segment() -> None:
        nonlocal current_segment
        flush_section()
        if current_segment is not None:
            segments.append(current_segment)
        current_segment = None

    for line in otool_output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Load command "):
            flush_segment()
            continue
        if stripped == "cmd LC_SEGMENT_64":
            current_segment = {"sections": []}
            current_section = None
            continue
        if current_segment is None:
            continue
        if stripped == "Section":
            flush_section()
            current_section = {}
            continue
        parts = stripped.split(None, 1)
        if len(parts) != 2:
            continue
        key, value = parts
        target = current_section if current_section is not None else current_segment
        target[key] = value

    flush_segment()

    regions: list[MachORegion] = []
    for segment in segments:
        segname = str(segment.get("segname") or "")
        vmaddr = parse_hex_int(segment.get("vmaddr")) or 0
        vmsize = parse_hex_int(segment.get("vmsize")) or 0
        fileoff = parse_hex_int(segment.get("fileoff")) or 0
        filesize = parse_hex_int(segment.get("filesize")) or 0
        regions.append(
            MachORegion(
                segname=segname,
                sectname=None,
                vmaddr=vmaddr,
                vmsize=vmsize,
                fileoff=fileoff,
                filesize=filesize,
            )
        )
        for section in segment.get("sections") or []:
            sectname = str(section.get("sectname") or "")
            section_segname = str(section.get("segname") or segname)
            regions.append(
                MachORegion(
                    segname=section_segname,
                    sectname=sectname,
                    vmaddr=parse_hex_int(section.get("addr")) or 0,
                    vmsize=parse_hex_int(section.get("size")) or 0,
                    fileoff=parse_hex_int(section.get("offset")) or 0,
                    filesize=parse_hex_int(section.get("size")) or 0,
                )
            )
    return regions


def preferred_text_base(regions: list[MachORegion]) -> int:
    for region in regions:
        if region.sectname is None and region.segname == "__TEXT":
            return region.vmaddr
    for region in regions:
        if region.sectname is None and region.filesize > 0:
            return region.vmaddr
    raise SystemExit("Could not determine the preferred __TEXT vmaddr from otool -l output")


def resolve_region_for_address(regions: list[MachORegion], preferred_pc: int) -> MachORegion | None:
    section_candidates = [
        region
        for region in regions
        if region.sectname is not None and region.vmaddr <= preferred_pc < (region.vmaddr + region.vmsize)
    ]
    if section_candidates:
        return section_candidates[0]
    segment_candidates = [
        region
        for region in regions
        if region.sectname is None and region.vmaddr <= preferred_pc < (region.vmaddr + region.vmsize)
    ]
    return segment_candidates[0] if segment_candidates else None


def parse_llvm_objdump_window(disassembly: str) -> list[dict[str, Any]]:
    instructions: list[dict[str, Any]] = []
    for line in disassembly.splitlines():
        match = re.match(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F ]+)\s+(.+)$", line)
        if not match:
            continue
        instructions.append(
            {
                "address": int(match.group(1), 16),
                "bytes": "".join(match.group(2).split()).lower(),
                "instruction": compact_instruction_text(match.group(3)),
                "raw": line.rstrip(),
            }
        )
    return instructions


def disassemble_window(binary_path: Path, preferred_pc: int, before_count: int, after_count: int, repo_root: Path) -> list[dict[str, Any]]:
    start_address = max(preferred_pc - max(before_count, 0) * 4, 0)
    stop_address = preferred_pc + (max(after_count, 0) + 1) * 4
    result = run_command(
        [
            "xcrun",
            "llvm-objdump",
            "--arch=arm64",
            "--disassemble",
            f"--start-address=0x{start_address:x}",
            f"--stop-address=0x{stop_address:x}",
            str(binary_path),
        ],
        cwd=repo_root,
    )
    if result["returncode"] != 0:
        raise SystemExit(f"llvm-objdump failed: {result['stderr']}")
    return parse_llvm_objdump_window(result["stdout"])


def read_binary_slice(binary_path: Path, offset: int, length: int) -> bytes:
    if offset < 0 or length < 0:
        return b""
    with binary_path.open("rb") as handle:
        handle.seek(offset)
        return handle.read(length)


def resolve_file_offset(region: MachORegion, preferred_pc: int) -> int:
    return region.fileoff + (preferred_pc - region.vmaddr)


def summarize_region(region: MachORegion | None) -> dict[str, Any] | None:
    if region is None:
        return None
    return {
        "segname": region.segname,
        "sectname": region.sectname,
        "vmaddr": f"0x{region.vmaddr:x}",
        "vmsize": f"0x{region.vmsize:x}",
        "fileoff": f"0x{region.fileoff:x}",
        "filesize": f"0x{region.filesize:x}",
    }


def determine_overall_pass(checks: dict[str, Any]) -> bool:
    return bool(
        checks.get("faultPcPresent")
        and checks.get("ipsPcPresent")
        and checks.get("ipsImageOffsetPresent")
        and checks.get("binaryResolved")
        and checks.get("textBaseResolved")
        and checks.get("imageOffsetMatchesFaultPc")
        and checks.get("regionResolved")
        and checks.get("fileOffsetResolved")
        and checks.get("beforePcBytesMatch")
        and checks.get("atPcBytesMatch")
        and checks.get("disassemblyContainsFaultPc")
        and checks.get("disassemblyMatchesFaultInstruction")
        and checks.get("faultAddressMatchesIpsFar")
        and checks.get("x19NullConfirmed")
    )


def main() -> int:
    args = build_parser().parse_args()
    repo_root = SCRIPT_DIR.parent
    report_path = Path(args.lldb_report).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    crash_reports_root = Path(args.crash_reports_root).expanduser().resolve()

    report = json.loads(report_path.read_text(encoding="utf-8"))
    lldb_payload, lldb_text = extract_lldb_payload(report)
    binary_path = resolve_binary_path(args.binary_path, lldb_text)
    ips_path = resolve_ips_path(args.ips_path, report, crash_reports_root)
    ips_header, ips_body = load_ips_report(ips_path)

    fault_frame = parse_faulting_frame(str(lldb_payload.get("faultingFrame") or ""))
    fault_instruction = parse_faulting_instruction(str(lldb_payload.get("faultingInstruction") or ""))
    lldb_registers = parse_lldb_registers(lldb_text)
    ips_registers, ips_first_frame = collect_ips_registers(ips_body)
    used_images = ips_body.get("usedImages") if isinstance(ips_body.get("usedImages"), list) else []
    used_image = next(
        (
            image
            for image in used_images
            if isinstance(image, dict)
            and (
                str(image.get("name") or "") == "NGR"
                or str(image.get("path") or "").endswith("/NGR")
            )
        ),
        {},
    )
    used_image_base = parse_hex_int(used_image.get("base"))
    crash_image_offset = parse_hex_int(ips_first_frame.get("imageOffset"))
    fault_pc = fault_frame.get("address") or fault_instruction.get("address")
    ips_pc = ips_registers.get("pc")
    ips_far = ips_registers.get("far")
    fault_address = parse_hex_int(lldb_payload.get("faultAddress"))
    stream_bytes = decode_instruction_stream_bytes(ips_body.get("instructionByteStream") or {})

    otool_result = run_command(["xcrun", "otool", "-l", str(binary_path)], cwd=repo_root)
    if otool_result["returncode"] != 0:
        raise SystemExit(f"otool -l failed: {otool_result['stderr']}")
    regions = parse_macho_regions(otool_result["stdout"])
    text_base = preferred_text_base(regions)
    preferred_pc = text_base + crash_image_offset if crash_image_offset is not None else None
    region = resolve_region_for_address(regions, preferred_pc) if preferred_pc is not None else None
    file_offset = resolve_file_offset(region, preferred_pc) if region is not None and preferred_pc is not None else None

    before_length = stream_bytes["beforePCLength"]
    at_length = stream_bytes["atPCLength"]
    actual_before = read_binary_slice(binary_path, max((file_offset or 0) - before_length, 0), before_length) if file_offset is not None else b""
    actual_at = read_binary_slice(binary_path, file_offset or 0, at_length) if file_offset is not None else b""

    disassembly = disassemble_window(
        binary_path,
        preferred_pc or 0,
        before_count=max(args.before_count, 0),
        after_count=max(args.after_count, 0),
        repo_root=repo_root,
    )
    disassembly_fault_line = next((line for line in disassembly if line["address"] == preferred_pc), None)

    checks = {
        "faultPcPresent": fault_pc is not None,
        "ipsPcPresent": ips_pc is not None,
        "ipsImageOffsetPresent": crash_image_offset is not None,
        "binaryResolved": binary_path.is_file(),
        "textBaseResolved": text_base is not None,
        "imageOffsetMatchesFaultPc": bool(
            fault_pc is not None
            and used_image_base is not None
            and crash_image_offset is not None
            and (fault_pc - used_image_base) == crash_image_offset
        ),
        "regionResolved": region is not None,
        "fileOffsetResolved": file_offset is not None,
        "beforePcBytesMatch": actual_before == stream_bytes["beforePC"],
        "atPcBytesMatch": actual_at == stream_bytes["atPC"],
        "disassemblyContainsFaultPc": disassembly_fault_line is not None,
        "disassemblyMatchesFaultInstruction": compact_instruction_text(fault_instruction.get("text"))
        == compact_instruction_text((disassembly_fault_line or {}).get("instruction")),
        "faultAddressMatchesIpsFar": fault_address == ips_far,
        "x19NullConfirmed": ips_registers.get("x19") == 0 and lldb_registers.get("x19") == 0,
    }
    checks["overallPass"] = determine_overall_pass(checks)
    checks["exitCode"] = 0 if checks["overallPass"] else 1

    output_report = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "workflow": "hok-007-ngr-callsite-mapper",
        "configuration": {
            "lldbReportPath": str(report_path),
            "ipsPath": str(ips_path),
            "binaryPath": str(binary_path),
            "outputPath": str(output_path),
            "beforeCount": max(args.before_count, 0),
            "afterCount": max(args.after_count, 0),
        },
        "lldb": {
            "processIdentifier": lldb_payload.get("processIdentifier"),
            "stopReason": lldb_payload.get("stopReason"),
            "faultAddress": lldb_payload.get("faultAddress"),
            "faultingFrame": fault_frame,
            "faultingInstruction": fault_instruction,
            "registers": {name: f"0x{value:x}" for name, value in sorted(lldb_registers.items())},
        },
        "crashReport": {
            "path": str(ips_path),
            "header": {
                "incidentId": ips_header.get("incident_id"),
                "sliceUUID": ips_header.get("slice_uuid"),
                "timestamp": ips_header.get("timestamp"),
            },
            "body": {
                "captureTime": ips_body.get("captureTime"),
                "procLaunch": ips_body.get("procLaunch"),
                "procPath": ips_body.get("procPath"),
                "faultingThread": ips_body.get("faultingThread"),
                "usedImage": {
                    "name": used_image.get("name"),
                    "path": used_image.get("path"),
                    "base": f"0x{used_image_base:x}" if used_image_base is not None else None,
                    "size": f"0x{parse_hex_int(used_image.get('size')):x}" if parse_hex_int(used_image.get("size")) is not None else None,
                    "uuid": used_image.get("uuid"),
                },
                "firstFrame": {
                    "imageOffset": f"0x{crash_image_offset:x}" if crash_image_offset is not None else None,
                    "imageIndex": ips_first_frame.get("imageIndex"),
                },
                "registers": {name: f"0x{value:x}" for name, value in sorted(ips_registers.items())},
                "instructionByteStream": {
                    "beforePCLength": stream_bytes["beforePCLength"],
                    "atPCLength": stream_bytes["atPCLength"],
                    "beforePCHex": stream_bytes["beforePCHex"],
                    "atPCHex": stream_bytes["atPCHex"],
                },
            },
        },
        "mapping": {
            "usedImageBase": f"0x{used_image_base:x}" if used_image_base is not None else None,
            "faultPc": f"0x{fault_pc:x}" if fault_pc is not None else None,
            "ipsPc": f"0x{ips_pc:x}" if ips_pc is not None else None,
            "crashImageOffset": f"0x{crash_image_offset:x}" if crash_image_offset is not None else None,
            "preferredTextBase": f"0x{text_base:x}" if text_base is not None else None,
            "preferredPc": f"0x{preferred_pc:x}" if preferred_pc is not None else None,
            "region": summarize_region(region),
            "fileOffset": f"0x{file_offset:x}" if file_offset is not None else None,
            "actualBinaryBytes": {
                "beforePCHex": actual_before.hex(),
                "atPCHex": actual_at.hex(),
            },
            "disassembly": {
                "faultLine": disassembly_fault_line,
                "window": disassembly,
            },
        },
        "checks": checks,
        "nextStep": {
            "status": "ready-for-hok-007b" if checks["overallPass"] else "blocked",
            "message": (
                "HOK-007A 已证明 fault PC / imageOffset / instructionByteStream / file bytes / x19=0 一致；下一步进入最小可逆 patch 候选设计。"
                if checks["overallPass"]
                else "HOK-007A 仍未完成 callsite 映射，请先修复离线证据链。"
            ),
        },
    }

    write_report(output_path, output_report)
    print(f"report written: {output_path}")
    print(
        "summary: "
        f"faultPc={output_report['mapping']['faultPc'] or 'n/a'} "
        f"imageOffset={output_report['mapping']['crashImageOffset'] or 'n/a'} "
        f"fileOffset={output_report['mapping']['fileOffset'] or 'n/a'} "
        f"beforePcBytesMatch={checks['beforePcBytesMatch']} "
        f"atPcBytesMatch={checks['atPcBytesMatch']} "
        f"disassemblyMatchesFaultInstruction={checks['disassemblyMatchesFaultInstruction']} "
        f"x19NullConfirmed={checks['x19NullConfirmed']} "
        f"overallPass={checks['overallPass']}"
    )
    return int(checks["exitCode"])


if __name__ == "__main__":
    raise SystemExit(main())
