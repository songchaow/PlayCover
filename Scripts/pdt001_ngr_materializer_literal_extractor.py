#!/usr/bin/env python3
"""PDT-001-A: 离线提取 ``com.tencent.ngr`` materializer compare literal。

目标（见 ``LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md``）：
- 静态反汇编 ``0x10432a068`` 中 ``0x10432a17c..0x10432a224`` 的 compare ladder；
- 提取 compare 使用的固定 literal，并判断是否与路径 / 文件名相关；
- 输出 ``build/pdt-001a-compare-literals.json`` 作为 PathDifferenceTrial 的
  结构化证据。

脚本特性：
- 纯离线、零副作用：只读 NGR binary，不 launch app，不改动除 ``--output`` 外的文件；
- 复用仓库已有的 Mach-O 布局解析与 ARM64 ``ADRP + ADD`` 解码 helper；
- 只关注 materializer 目标函数窗口内的 PC-relative 常量，避免把外围噪音混进报告。
"""

from __future__ import annotations

import argparse
import os
import re
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
DEFAULT_OUTPUT = Path("build/pdt-001a-compare-literals.json")
DEFAULT_START_ADDRESS = 0x10432A068
DEFAULT_STOP_ADDRESS = 0x10432A31C
DEFAULT_TARGET_ENTRY = 0x10432A068
DEFAULT_COMPARE_START = 0x10432A17C
DEFAULT_COMPARE_STOP = 0x10432A224
DEFAULT_SECOND_COMPARE = 0x10432A238


@dataclass(frozen=True)
class DisassembledInstruction:
    pc: int
    encoding: int
    mnemonic: str
    operands: str
    raw: str


@dataclass(frozen=True)
class PcRelativeConstant:
    register: str
    adrp_pc: int
    add_pc: int
    page_base: int
    page_offset: int
    absolute_address: int
    section: MachOSection | None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="PDT-001-A: extract materializer compare literals from NGR binary"
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--binary-path", default=str(DEFAULT_BINARY_PATH))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument(
        "--start-address",
        default=f"0x{DEFAULT_START_ADDRESS:x}",
        help="disassembly start address (unslid)",
    )
    parser.add_argument(
        "--stop-address",
        default=f"0x{DEFAULT_STOP_ADDRESS:x}",
        help="disassembly stop address (unslid, exclusive)",
    )
    return parser


def parse_hex_int(value: str) -> int:
    return int(str(value).strip(), 0)


def parse_objdump_window(disassembly: str) -> list[DisassembledInstruction]:
    instructions: list[DisassembledInstruction] = []
    pattern = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]{8})\s+\t([^\t]+)(?:\t(.*))?$")
    for line in disassembly.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        instructions.append(
            DisassembledInstruction(
                pc=int(match.group(1), 16),
                encoding=int(match.group(2), 16),
                mnemonic=match.group(3).strip(),
                operands=(match.group(4) or "").strip(),
                raw=line.rstrip(),
            )
        )
    return instructions


def disassemble_target(binary_path: Path, start_address: int, stop_address: int) -> tuple[list[DisassembledInstruction], str]:
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
        cwd=REPO_ROOT,
    )
    if result["returncode"] != 0:
        raise SystemExit(f"llvm-objdump failed: {result['stderr']}")
    stdout = str(result["stdout"])
    return parse_objdump_window(stdout), stdout


def find_section_for_vmaddr(image: MachOImage, vmaddr: int) -> MachOSection | None:
    for section in image.sections:
        if section.vmaddr <= vmaddr < (section.vmaddr + section.size):
            return section
    return None


def vmaddr_to_file_offset(section: MachOSection | None, vmaddr: int) -> int | None:
    if section is None:
        return None
    return section.fileoff + (vmaddr - section.vmaddr)


def read_utf16le_cstring(data: bytes, section: MachOSection | None, vmaddr: int, *, max_code_units: int = 512) -> dict[str, Any]:
    file_offset = vmaddr_to_file_offset(section, vmaddr)
    if file_offset is None:
        return {
            "vmaddr": f"0x{vmaddr:x}",
            "fileOffset": None,
            "utf16": None,
            "utf16Length": 0,
            "rawHex": "",
        }
    cursor = file_offset
    out = bytearray()
    units = 0
    data_len = len(data)
    while cursor + 1 < data_len and units < max_code_units:
        lo = data[cursor]
        hi = data[cursor + 1]
        if lo == 0 and hi == 0:
            break
        out.extend((lo, hi))
        cursor += 2
        units += 1
    return {
        "vmaddr": f"0x{vmaddr:x}",
        "fileOffset": f"0x{file_offset:x}",
        "utf16": out.decode("utf-16-le", errors="replace"),
        "utf16Length": units,
        "rawHex": out.hex(),
    }


def read_utf16le_containing_string(data: bytes, section: MachOSection | None, vmaddr: int, *, max_code_units: int = 512) -> dict[str, Any] | None:
    file_offset = vmaddr_to_file_offset(section, vmaddr)
    if file_offset is None or section is None:
        return None
    start = file_offset
    section_start = section.fileoff
    section_end = section.fileoff + section.size
    while start - 2 >= section_start:
        if data[start - 2] == 0 and data[start - 1] == 0:
            break
        start -= 2
    cursor = start
    out = bytearray()
    units = 0
    while cursor + 1 < section_end and units < max_code_units:
        lo = data[cursor]
        hi = data[cursor + 1]
        if lo == 0 and hi == 0:
            break
        out.extend((lo, hi))
        cursor += 2
        units += 1
    full_text = out.decode("utf-16-le", errors="replace")
    prefix_units = max((file_offset - start) // 2, 0)
    return {
        "startVMAddr": f"0x{section.vmaddr + (start - section.fileoff):x}",
        "startFileOffset": f"0x{start:x}",
        "utf16": full_text,
        "utf16Length": len(full_text),
        "addressCodeUnitOffset": prefix_units,
        "suffixFromAddress": full_text[prefix_units:],
    }


def literal_heuristics(value: str | None) -> dict[str, Any]:
    text = value or ""
    lower = text.lower()
    return {
        "containsSlash": "/" in text or "\\" in text,
        "containsDotDb": ".db" in lower,
        "containsPaks": "paks" in lower,
        "containsSaved": "saved" in lower,
        "containsContent": "content" in lower,
        "containsDriveColon": ":" in text,
        "pathOrFilenameRelated": any(token in lower for token in ["/", "\\", ".db", "paks", "saved", "content"]),
    }


def extract_pc_relative_constants(instructions: list[DisassembledInstruction], image: MachOImage) -> list[PcRelativeConstant]:
    constants: list[PcRelativeConstant] = []
    for index in range(len(instructions) - 1):
        current = instructions[index]
        nxt = instructions[index + 1]
        adrp = decode_adrp(current.encoding, current.pc)
        if adrp is None:
            continue
        add = decode_add_imm(nxt.encoding)
        if add is None:
            continue
        reg_index, page_base = adrp
        rd, rn, imm = add
        if rd != reg_index or rn != reg_index:
            continue
        absolute_address = page_base + imm
        constants.append(
            PcRelativeConstant(
                register=f"x{reg_index}",
                adrp_pc=current.pc,
                add_pc=nxt.pc,
                page_base=page_base,
                page_offset=imm,
                absolute_address=absolute_address,
                section=find_section_for_vmaddr(image, absolute_address),
            )
        )
    return constants


def summarize_constant(
    constant: PcRelativeConstant,
    decoded: dict[str, Any] | None = None,
    containing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    section = constant.section
    payload: dict[str, Any] = {
        "register": constant.register,
        "adrpPc": f"0x{constant.adrp_pc:x}",
        "addPc": f"0x{constant.add_pc:x}",
        "pageBase": f"0x{constant.page_base:x}",
        "pageOffset": f"0x{constant.page_offset:x}",
        "absoluteAddress": f"0x{constant.absolute_address:x}",
        "section": {
            "segname": section.segname,
            "sectname": section.sectname,
        }
        if section is not None
        else None,
    }
    if decoded is not None:
        payload["decoded"] = decoded
        payload["heuristics"] = literal_heuristics(decoded.get("utf16"))
    if containing is not None:
        payload["containingString"] = containing
        payload["containingHeuristics"] = literal_heuristics(containing.get("utf16"))
    return payload


def build_relation(primary: dict[str, Any], secondary: dict[str, Any]) -> dict[str, Any]:
    first_addr = int(primary["absoluteAddress"], 16)
    second_addr = int(secondary["absoluteAddress"], 16)
    first_text = ((primary.get("decoded") or {}).get("utf16") or "")
    second_text = ((secondary.get("decoded") or {}).get("utf16") or "")
    byte_delta = second_addr - first_addr
    code_unit_delta = byte_delta // 2 if byte_delta % 2 == 0 else None
    suffix_match = False
    if code_unit_delta is not None and code_unit_delta >= 0 and first_text:
        suffix_match = first_text[code_unit_delta:] == second_text
    return {
        "byteDelta": byte_delta,
        "utf16CodeUnitDelta": code_unit_delta,
        "secondStartsInsidePrimary": byte_delta >= 0,
        "secondaryEqualsPrimarySuffix": suffix_match,
    }


def main() -> int:
    args = build_parser().parse_args()
    binary_path = Path(os.path.expanduser(args.binary_path)).resolve()
    output_path = Path(os.path.expanduser(args.output))
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()

    if not binary_path.is_file():
        raise SystemExit(f"Binary not found: {binary_path}")

    start_address = parse_hex_int(args.start_address)
    stop_address = parse_hex_int(args.stop_address)
    image = parse_macho_layout(binary_path)
    data = binary_path.read_bytes()
    instructions, raw_disassembly = disassemble_target(binary_path, start_address, stop_address)
    constants = extract_pc_relative_constants(instructions, image)

    ustring_constants = [
        constant
        for constant in constants
        if constant.section is not None
        and constant.section.segname == "__TEXT"
        and constant.section.sectname == "__ustring"
    ]
    ustring_constants.sort(key=lambda item: (item.absolute_address, item.add_pc))

    unique_ustring_constants: list[PcRelativeConstant] = []
    seen_ustring_addresses: set[int] = set()
    for constant in ustring_constants:
        if constant.absolute_address in seen_ustring_addresses:
            continue
        seen_ustring_addresses.add(constant.absolute_address)
        unique_ustring_constants.append(constant)

    decoded_literals = [
        summarize_constant(
            constant,
            read_utf16le_cstring(data, constant.section, constant.absolute_address),
            read_utf16le_containing_string(data, constant.section, constant.absolute_address),
        )
        for constant in unique_ustring_constants
    ]

    primary_literal = decoded_literals[0] if decoded_literals else None
    secondary_literal = decoded_literals[1] if len(decoded_literals) > 1 else None

    any_path_related = any(
        bool((literal.get("heuristics") or {}).get("pathOrFilenameRelated"))
        or bool((literal.get("containingHeuristics") or {}).get("pathOrFilenameRelated"))
        for literal in decoded_literals
    )

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "workflow": "pdt-001a-ngr-materializer-literal-extractor",
        "configuration": {
            "binaryPath": str(binary_path),
            "outputPath": str(output_path),
            "targetEntry": f"0x{DEFAULT_TARGET_ENTRY:x}",
            "disassemblyRange": {
                "start": f"0x{start_address:x}",
                "stop": f"0x{stop_address:x}",
            },
            "compareRange": {
                "firstStageStart": f"0x{DEFAULT_COMPARE_START:x}",
                "firstStageStop": f"0x{DEFAULT_COMPARE_STOP:x}",
                "secondStageStart": f"0x{DEFAULT_SECOND_COMPARE:x}",
            },
        },
        "materializerTarget": {
            "entry": f"0x{DEFAULT_TARGET_ENTRY:x}",
            "instructionCount": len(instructions),
            "textVMAddrUnslid": f"0x{image.text_vmaddr:x}",
        },
        "pcRelativeConstants": {
            "all": [summarize_constant(constant) for constant in constants],
            "ustringCandidates": decoded_literals,
        },
        "compareLiterals": {
            "primary": primary_literal,
            "secondary": secondary_literal,
            "relation": build_relation(primary_literal, secondary_literal)
            if primary_literal is not None and secondary_literal is not None
            else None,
        },
        "disassembly": {
            "rawWindowPathHint": "build/pdt001-target-disasm.txt",
            "window": [
                {
                    "pc": f"0x{instruction.pc:x}",
                    "encoding": f"0x{instruction.encoding:08x}",
                    "mnemonic": instruction.mnemonic,
                    "operands": instruction.operands,
                }
                for instruction in instructions
            ],
            "rawText": raw_disassembly,
        },
        "verdict": {
            "status": "path-related" if any_path_related else "not-path-related",
            "message": (
                "materializer compare literal 至少包含路径/文件名相关片段（如 slash / .db / Paks / Saved / Content），支持路径差异假设继续进入 PDT-001-B。"
                if any_path_related
                else "materializer compare literal 未呈现路径/文件名相关片段，PDT-001-A 倾向证伪路径差异假设。"
            ),
        },
        "notes": [
            "脚本只解 materializer 目标函数窗口内的 ADRP+ADD 常量；报告中的 ustringCandidates 是 compare ladder 直接用到的 UTF-16 literal 候选。",
            "本轮真实反汇编显示：first compare 的 x23 = 0x10c09aca2，second compare 的 suffix literal = 0x10c09aca6；它们位于同一 __TEXT,__ustring 页，后者相对前者偏移 4 字节（2 个 UTF-16 code unit）。",
            "若 verdict=path-related，则说明 materializer 至少在比较路径/文件名后缀，而不是完全与路径无关的随机常量。",
        ],
    }

    write_report(output_path, report)

    primary_text = (((primary_literal or {}).get("decoded") or {}).get("utf16") or "n/a")
    secondary_text = (((secondary_literal or {}).get("decoded") or {}).get("utf16") or "n/a")
    print(f"report written: {output_path}")
    print(
        "summary: "
        f"primary={primary_text!r} "
        f"secondary={secondary_text!r} "
        f"pathRelated={any_path_related}"
    )
    return 0 if decoded_literals else 2


if __name__ == "__main__":
    raise SystemExit(main())
