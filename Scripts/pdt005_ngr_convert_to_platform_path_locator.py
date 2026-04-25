#!/usr/bin/env python3
"""PDT-005: 在 NGR 二进制中定位 ``FIOSPlatformFile::ConvertToPlatformPath`` 的 ``/var/`` 判断逻辑。

目标（见 ``LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md``）：
- 在 ``com.tencent.ngr`` 主二进制中搜索 ``"/var/"`` UTF-16 字符串常量；
- 追踪其 ADRP+ADD 引用位置，定位 ``StartsWith("/var/")`` 条件判断的机器码地址；
- 对关键引用点做周围反汇编，确认判断逻辑的边界（内联比较还是函数调用、条件跳转指令类型）；
- 产物 ``build/pdt-005-convert-to-platform-path-locate.json``。

脚本特性：
- 纯离线、零副作用：只读 NGR binary；
- 复用仓库已有的 Mach-O 布局解析与 ARM64 ``ADRP + ADD`` 解码 helper；
- 对整个 ``__TEXT,__text`` 做线性扫描，找出所有指向目标字符串的 PC-relative 常量。
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok004_ngr_startup_runner import run_command, utc_now_iso, write_report  # noqa: E402
from hok015_ngr_cmdline_locator import (  # noqa: E402
    MachOImage,
    MachOSection,
    decode_add_imm,
    decode_adrp,
    parse_macho_layout,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_BINARY_PATH = Path(
    os.path.expanduser(
        "~/Library/Containers/io.playcover.PlayCover/Applications/"
        "com.tencent.ngr.app/NGR"
    )
)
DEFAULT_OUTPUT = Path("build/pdt-005-convert-to-platform-path-locate.json")
TARGET_STRING_LITERAL = "/var/"
SECONDARY_LITERAL = "/User"


@dataclass(frozen=True)
class StringMatch:
    literal: str
    file_offset: int
    vmaddr: int
    section: MachOSection | None


@dataclass(frozen=True)
class AdrpAddRef:
    adrp_pc: int
    add_pc: int
    register: str
    target_vmaddr: int
    target_section: MachOSection | None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="PDT-005: locate ConvertToPlatformPath /var/ judgment in NGR binary"
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--binary-path", default=str(DEFAULT_BINARY_PATH))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return parser


def find_utf16le_strings(
    data: bytes, image: MachOImage, literals: list[str]
) -> dict[str, StringMatch]:
    """Find UTF-16-LE encoded strings in __TEXT,__ustring."""
    ustring = image.section("__TEXT", "__ustring")
    if ustring is None:
        raise SystemExit("Failed to locate __TEXT,__ustring section")
    results: dict[str, StringMatch] = {}
    for lit in literals:
        encoded = lit.encode("utf-16-le")
        sect_end = ustring.fileoff + ustring.size
        idx = data.find(encoded, ustring.fileoff, sect_end)
        if idx < 0:
            # Allow searching in other TEXT sections as fallback
            idx = data.find(encoded, image.text_fileoff, image.text_fileoff + 0x10000000)
            if idx < 0:
                continue
        vmaddr = ustring.vmaddr + (idx - ustring.fileoff) if idx >= ustring.fileoff else image.text_vmaddr + (idx - image.text_fileoff)
        sec = ustring if (ustring.fileoff <= idx < sect_end) else None
        results[lit] = StringMatch(
            literal=lit, file_offset=idx, vmaddr=vmaddr, section=sec
        )
    return results


def scan_adrp_add_refs(
    data: bytes, image: MachOImage, target_vmaddrs: set[int]
) -> list[AdrpAddRef]:
    """Linear-scan __TEXT,__text for ADRP+ADD pairs that materialise any of target_vmaddrs."""
    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("Failed to locate __TEXT,__text section")
    text_bytes = data[text.fileoff : text.fileoff + text.size]
    n = text.size // 4
    refs: list[AdrpAddRef] = []
    for i in range(n - 1):
        inst0 = struct.unpack_from("<I", text_bytes, i * 4)[0]
        adrp = decode_adrp(inst0, text.vmaddr + i * 4)
        if adrp is None:
            continue
        Rd, page_base = adrp
        inst1 = struct.unpack_from("<I", text_bytes, (i + 1) * 4)[0]
        add = decode_add_imm(inst1)
        if add is None:
            continue
        Rd_add, Rn_add, imm12 = add
        if Rd_add != Rd or Rn_add != Rd:
            continue
        absolute = page_base + imm12
        if absolute in target_vmaddrs:
            refs.append(
                AdrpAddRef(
                    adrp_pc=text.vmaddr + i * 4,
                    add_pc=text.vmaddr + (i + 1) * 4,
                    register=f"x{Rd}",
                    target_vmaddr=absolute,
                    target_section=image.section("__TEXT", "__ustring"),
                )
            )
    return refs


def disassemble_window(
    binary_path: Path, start: int, stop: int
) -> tuple[list[dict[str, Any]], str]:
    result = run_command(
        [
            "xcrun",
            "llvm-objdump",
            "--arch=arm64",
            "--disassemble",
            f"--start-address=0x{start:x}",
            f"--stop-address=0x{stop:x}",
            str(binary_path),
        ],
        cwd=REPO_ROOT,
    )
    if result["returncode"] != 0:
        raise SystemExit(f"llvm-objdump failed: {result['stderr']}")
    stdout = str(result["stdout"])
    instructions: list[dict[str, Any]] = []
    pattern = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]{8})\s+\t([^\t]+)(?:\t(.*))?$")
    for line in stdout.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        instructions.append(
            {
                "pc": f"0x{int(match.group(1), 16):x}",
                "encoding": f"0x{int(match.group(2), 16):08x}",
                "mnemonic": match.group(3).strip(),
                "operands": (match.group(4) or "").strip(),
            }
        )
    return instructions, stdout


def find_branch_instructions(instructions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Identify conditional/unconditional branch instructions in the window."""
    branches: list[dict[str, Any]] = []
    for inst in instructions:
        mnemonic = inst.get("mnemonic", "").upper()
        # Focus on conditional branches and TBZ/TBNZ/CBZ/CBNZ
        if mnemonic in (
            "B.EQ", "B.NE", "B.HS", "B.LO", "B.MI", "B.PL",
            "B.VS", "B.VC", "B.HI", "B.LS", "B.GE", "B.LT",
            "B.GT", "B.LE", "B.AL", "B.NV",
        ) or mnemonic.startswith(("TBZ", "TBNZ", "CBZ", "CBNZ")):
            branches.append(inst)
        # Also capture BL / B as potential function call boundaries
        elif mnemonic in ("BL", "B"):
            branches.append({**inst, "isCallOrJump": True})
    return branches


def find_compare_instructions(instructions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Identify compare / test instructions."""
    compares: list[dict[str, Any]] = []
    for inst in instructions:
        mnemonic = inst.get("mnemonic", "").upper()
        if mnemonic.startswith(("CMP", "CMN", "TST", "ANDS", "SUBS", "ADDS")):
            compares.append(inst)
    return compares


def main() -> int:
    args = build_parser().parse_args()
    binary_path = Path(os.path.expanduser(args.binary_path)).resolve()
    output_path = Path(os.path.expanduser(args.output))
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    if not binary_path.is_file():
        raise SystemExit(f"Binary not found: {binary_path}")

    image = parse_macho_layout(binary_path)
    data = binary_path.read_bytes()

    # 1. Locate /var/ and /User strings
    matches = find_utf16le_strings(
        data, image, [TARGET_STRING_LITERAL, SECONDARY_LITERAL]
    )
    target_vmaddrs = {m.vmaddr for m in matches.values()}

    # 2. Find ADRP+ADD references in __text
    refs = scan_adrp_add_refs(data, image, target_vmaddrs)

    # 3. Disassemble around each reference
    ref_details: list[dict[str, Any]] = []
    for ref in refs:
        window_start = ref.adrp_pc - 0x80
        window_stop = ref.add_pc + 0x100
        instructions, raw = disassemble_window(binary_path, window_start, window_stop)
        branches = find_branch_instructions(instructions)
        compares = find_compare_instructions(instructions)
        ref_details.append(
            {
                "literal": next(
                    (m.literal for m in matches.values() if m.vmaddr == ref.target_vmaddr),
                    None,
                ),
                "targetVMAddr": f"0x{ref.target_vmaddr:x}",
                "adrpPc": f"0x{ref.adrp_pc:x}",
                "addPc": f"0x{ref.add_pc:x}",
                "register": ref.register,
                "disassemblyWindow": {
                    "start": f"0x{window_start:x}",
                    "stop": f"0x{window_stop:x}",
                    "instructions": instructions,
                    "rawText": raw,
                },
                "branchesInWindow": branches,
                "comparesInWindow": compares,
            }
        )

    # Group by literal for readability
    grouped_refs: dict[str, list[dict[str, Any]]] = {}
    for detail in ref_details:
        lit = detail.get("literal") or "unknown"
        grouped_refs.setdefault(lit, []).append(detail)

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "workflow": "pdt-005-locate-convert-to-platform-path",
        "configuration": {
            "binaryPath": str(binary_path),
            "outputPath": str(output_path),
            "textVMAddrUnslid": f"0x{image.text_vmaddr:x}",
        },
        "stringMatches": {
            lit: {
                "literal": m.literal,
                "fileOffset": f"0x{m.file_offset:x}",
                "vmaddr": f"0x{m.vmaddr:x}",
                "section": {
                    "segname": m.section.segname,
                    "sectname": m.section.sectname,
                }
                if m.section is not None
                else None,
            }
            for lit, m in matches.items()
        },
        "adrpAddRefs": {
            "totalFound": len(refs),
            "byLiteral": {
                lit: [
                    {
                        "adrpPc": d["adrpPc"],
                        "addPc": d["addPc"],
                        "register": d["register"],
                        "targetVMAddr": d["targetVMAddr"],
                        "branchCount": len(d["branchesInWindow"]),
                        "compareCount": len(d["comparesInWindow"]),
                    }
                    for d in grouped_refs.get(lit, [])
                ]
                for lit in matches.keys()
            },
            "detailedWindows": ref_details,
        },
        "verdict": {
            "status": "located" if refs else "not-found",
            "message": (
                f"Found {len(refs)} ADRP+ADD reference(s) to target strings. "
                "Review detailedWindows for conditional-branch proximity to determine patch points."
                if refs
                else "No ADRP+ADD references found to /var/ or /User in __TEXT,__text."
            ),
        },
        "notes": [
            "扫描范围：整个 __TEXT,__text 的 ADRP+ADD 对；只保留指向目标字符串的引用。",
            "每个引用点反汇编了 ±0x80 ~ +0x100 的窗口；branchesInWindow 列出条件/无条件跳转，comparesInWindow 列出比较指令。",
            "若 /var/ 引用附近存在 TBZ/CBZ/B.cond 且与后续函数边界（BL）相邻，则极可能是 StartsWith 的内联比较。",
            "/User 引用用于对比：若两者出现在同一函数的不同分支，可进一步确认 ConvertToPlatformPath 的判断逻辑。",
        ],
    }

    write_report(output_path, report)
    print(f"report written: {output_path}")
    print(
        f"summary: found {len(refs)} ADRP+ADD ref(s) to {list(matches.keys())} "
        f"across {len(grouped_refs)} literal(s)"
    )
    for lit, details in grouped_refs.items():
        for d in details:
            print(
                f"  [{lit}] adrp={d['adrpPc']} add={d['addPc']} "
                f"branches={len(d['branchesInWindow'])} compares={len(d['comparesInWindow'])}"
            )
    return 0 if refs else 2


if __name__ == "__main__":
    raise SystemExit(main())
