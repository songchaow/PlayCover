#!/usr/bin/env python3
"""
HOK-011: 离线分析 `com.tencent.ngr` 的 dyld static initializer 链路，定位哪个 initializer
应该为 faulting caller 读到的 ``__common`` 槽位（默认 ``0x10e2146f8``）赋值。

动机
----
HOK-006 结构化 backtrace 显示 `com.tencent.ngr` 崩溃于 dyld `findAndRunAllInitializers`
执行期间；HOK-007A 离线 mapping 证明 faulting line 是 ``ldr x8, [x19]`` / ``x19 = 0``；
进一步分析 caller（`frame#1`）后确定 ``x19`` 来自 ``ldr x0, [x21 + 0x6f8]``，该地址
``0x10e2146f8`` 位于 ``__DATA,__common`` 内、由全局构造器负责填充。

方案 B 的第一步即是找出「应当写该 __common 槽位的那个 initializer」。本脚本做的事：

1. 读取 Mach-O load commands，解析 ``__TEXT,__init_offsets`` 得到所有 initializer 入口 PC。
2. 用 ``llvm-objdump`` 反汇编每个 initializer 函数（保守窗口），扫描形如
   ``adrp x?, <page>`` + 后续的 ``add``/``str`` 组合，判定是否存在对 ``target_address``
   的 store-site。支持的模式覆盖常见的 `adrp + add + str`, `adrp + str (#offset)`。
3. 把命中的 initializer 入口地址、反汇编片段、附近符号全量写入
   ``build/hok-011-ngr-common-init-chain-report.json``。

默认目标地址 ``0x10e2146f8`` 来自 HOK-007A callsite 与 caller 反汇编的交叉结果。也接受
``--target-address`` 自行传入其它 ``__common`` / ``__data`` 槽位，方便复用到其它
"应当初始化但没被初始化" 的排查。

脚本**零副作用**：只读 binary、只调用 ``llvm-objdump`` / ``otool``；不执行 ``codesign``、
不 launch app、不修改任何文件（除 ``--output`` 指定的报告路径）。
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok007_ngr_callsite_mapper import (  # noqa: E402
    MachORegion,
    parse_macho_regions,
    preferred_text_base,
    resolve_region_for_address,
    summarize_region,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_CALLSITE_REPORT = Path("build/hok-007-ngr-callsite-report.json")
DEFAULT_OUTPUT = Path("build/hok-011-ngr-common-init-chain-report.json")
DEFAULT_TARGET_ADDRESS = 0x10E2146F8
DEFAULT_DISASM_WINDOW_INSTRUCTIONS = 512  # 2KiB; cover even fairly large initializers.


@dataclass(frozen=True)
class InitOffsetsSection:
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    count: int


@dataclass(frozen=True)
class StoreHit:
    initializer_address: int
    instruction_address: int
    reason: str
    disassembly_snippet: list[str]


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan NGR static initializers to find the one that writes a given __common slot"
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="target bundle identifier")
    parser.add_argument(
        "--callsite-report",
        default=str(DEFAULT_CALLSITE_REPORT),
        help="HOK-007A callsite report (used only to resolve the binary path when --binary-path is absent)",
    )
    parser.add_argument(
        "--binary-path",
        help="explicit NGR binary path; defaults to the one recorded in the callsite report",
    )
    parser.add_argument(
        "--target-address",
        default=hex(DEFAULT_TARGET_ADDRESS),
        help="absolute VM address of the __common slot that is expected to be initialized (default: 0x10e2146f8)",
    )
    parser.add_argument(
        "--disasm-window",
        type=int,
        default=DEFAULT_DISASM_WINDOW_INSTRUCTIONS,
        help="maximum number of instructions to disassemble per initializer when chasing a store-site",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="structured JSON report output path",
    )
    parser.add_argument(
        "--max-hits",
        type=int,
        default=16,
        help="stop scanning after this many candidate store-sites (avoids running-away on false positives)",
    )
    return parser


def run_command(cmd: list[str]) -> dict[str, Any]:
    completed = subprocess.run(cmd, check=False, capture_output=True, text=True)
    return {
        "command": list(cmd),
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def load_callsite_report(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"HOK-007A callsite report not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_binary_path(explicit: str | None, report: dict[str, Any]) -> Path:
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f"Binary not found: {path}")
        return path
    configured = (report.get("configuration") or {}).get("binaryPath")
    if not configured:
        raise SystemExit("Could not resolve binary path; pass --binary-path or provide a callsite report with configuration.binaryPath")
    path = Path(str(configured)).expanduser().resolve()
    if not path.is_file():
        raise SystemExit(f"Binary not found: {path}")
    return path


def parse_init_offsets_section(otool_output: str) -> InitOffsetsSection | None:
    # llvm's `otool -l` emits one Section block per section.  We need the one whose sectname
    # is __init_offsets and segname is __TEXT; capture its vm addr/size and file offset/size.
    lines = otool_output.splitlines()
    current: dict[str, Any] = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Section"):
            current = {}
            continue
        if stripped.startswith("sectname "):
            current["sectname"] = stripped.split(None, 1)[1]
        elif stripped.startswith("segname "):
            current["segname"] = stripped.split(None, 1)[1]
        elif stripped.startswith("addr "):
            current["addr"] = int(stripped.split(None, 1)[1], 16)
        elif stripped.startswith("size "):
            size_text = stripped.split(None, 1)[1]
            current["size"] = int(size_text, 16) if size_text.startswith("0x") else int(size_text)
        elif stripped.startswith("offset "):
            current["offset"] = int(stripped.split(None, 1)[1])
        elif stripped.startswith("flags "):
            if current.get("sectname") == "__init_offsets" and current.get("segname") == "__TEXT":
                size = int(current["size"])
                if size % 4 != 0:
                    raise SystemExit(f"Unexpected __init_offsets size not 4-byte aligned: {size}")
                return InitOffsetsSection(
                    vmaddr=int(current["addr"]),
                    vmsize=size,
                    fileoff=int(current["offset"]),
                    filesize=size,
                    count=size // 4,
                )
    return None


def read_init_offsets(binary_path: Path, section: InitOffsetsSection) -> list[int]:
    with binary_path.open("rb") as handle:
        handle.seek(section.fileoff)
        raw = handle.read(section.filesize)
    if len(raw) != section.filesize:
        raise SystemExit(
            f"Short read of __init_offsets: got {len(raw)} bytes, expected {section.filesize}"
        )
    return list(struct.unpack(f"<{section.count}I", raw))


def resolve_initializer_entry_vmaddrs(offsets: list[int], text_base: int) -> list[int]:
    # Entries are file offsets *relative to the __TEXT segment*.
    # With the standard macOS loader, __TEXT starts at vm base (text_base) and starts at file
    # offset 0 of the slice.  So `vmaddr = text_base + offset`.
    return [text_base + off for off in offsets]


DISASM_ROW_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F ]+)\s+(.+)$")


def disassemble_range(binary_path: Path, start: int, stop: int) -> list[dict[str, Any]]:
    result = run_command([
        "xcrun",
        "llvm-objdump",
        "--arch=arm64",
        "--disassemble",
        f"--start-address=0x{start:x}",
        f"--stop-address=0x{stop:x}",
        str(binary_path),
    ])
    if result["returncode"] != 0:
        raise SystemExit(f"llvm-objdump failed: {result['stderr']}")
    instructions: list[dict[str, Any]] = []
    for line in result["stdout"].splitlines():
        match = DISASM_ROW_RE.match(line)
        if not match:
            continue
        instructions.append(
            {
                "address": int(match.group(1), 16),
                "bytes": "".join(match.group(2).split()).lower(),
                "text": match.group(3).strip(),
                "raw": line.rstrip(),
            }
        )
    return instructions


def decode_aarch64_str_imm(text: str) -> tuple[str, str, int] | None:
    """Parse ``str xN, [xM, #imm]`` / ``str xN, [xM]`` /  ``str wN, ...`` variants.

    Returns (src_reg, base_reg, imm) if the instruction is a non-indexed register-plus-offset
    integer store we care about; otherwise None.
    """
    # Examples we care about:
    #   str  x20, [x8, #0x6f8]
    #   str  x8, [x9]
    # We ignore pre-/post-indexed (``[xM, #imm]!`` or ``[xM], #imm``) for simplicity — these
    # rarely appear for global writes.
    cleaned = re.sub(r"\s+", " ", text.strip())
    match = re.match(
        r"str\s+([xw]\d{1,2}|xzr|wzr),\s*\[\s*(x\d{1,2}|sp)\s*(?:,\s*#?(-?0x[0-9a-fA-F]+|-?\d+))?\s*\]\s*$",
        cleaned,
    )
    if not match:
        return None
    src, base, imm_text = match.groups()
    if imm_text is None:
        imm = 0
    else:
        imm = int(imm_text, 0)
    return src, base, imm


def decode_adrp(text: str) -> tuple[str, int] | None:
    # `adrp xN, 0xPAGE` – we extract the page base.
    match = re.match(r"adrp\s+(x\d{1,2}),\s*0x([0-9a-fA-F]+)", text.strip())
    if not match:
        return None
    return match.group(1), int(match.group(2), 16)


def decode_add_imm(text: str) -> tuple[str, str, int] | None:
    # add xN, xM, #imm  — matches either decimal or hex, with or without 0x.
    match = re.match(
        r"add\s+(x\d{1,2}),\s*(x\d{1,2}|sp),\s*#?(-?0x[0-9a-fA-F]+|-?\d+)",
        text.strip(),
    )
    if not match:
        return None
    return match.group(1), match.group(2), int(match.group(3), 0)


def scan_initializer_for_store_to(
    binary_path: Path,
    init_addr: int,
    target_address: int,
    max_instructions: int,
) -> list[StoreHit]:
    stop_addr = init_addr + max_instructions * 4
    instructions = disassemble_range(binary_path, init_addr, stop_addr)
    if not instructions:
        return []

    # Track two pieces of symbolic state per register:
    #  - page_base[reg] = last adrp page (if set)
    #  - add_eff[reg]   = effective address if reg is the result of `adrp+add` or `add` of a
    #                      known register; used to detect `str xN, [xM]` where xM already
    #                      holds the final address.
    page_base: dict[str, int] = {}
    add_eff: dict[str, int] = {}

    hits: list[StoreHit] = []

    def snippet_around(center_idx: int) -> list[str]:
        start = max(center_idx - 4, 0)
        end = min(center_idx + 1, len(instructions))
        return [instructions[i]["raw"] for i in range(start, end)]

    for idx, insn in enumerate(instructions):
        text = insn["text"]
        # Function likely ends at `ret` — stop scanning to avoid walking into the next function.
        if text.startswith("ret"):
            break

        adrp = decode_adrp(text)
        if adrp is not None:
            reg, page = adrp
            page_base[reg] = page
            add_eff.pop(reg, None)
            continue

        add_triple = decode_add_imm(text)
        if add_triple is not None:
            dst, src, imm = add_triple
            if src in page_base:
                add_eff[dst] = page_base[src] + imm
            elif src in add_eff:
                add_eff[dst] = add_eff[src] + imm
            else:
                add_eff.pop(dst, None)
            page_base.pop(dst, None)
            continue

        store = decode_aarch64_str_imm(text)
        if store is not None:
            _src, base, imm = store
            base_addr: int | None = None
            reason: str | None = None
            if base in page_base:
                base_addr = page_base[base]
                reason = f"adrp({base})=0x{base_addr:x} + #0x{imm:x}"
            elif base in add_eff:
                base_addr = add_eff[base]
                reason = f"add-effective({base})=0x{base_addr:x} + #0x{imm:x}"
            if base_addr is not None:
                effective_target = base_addr + imm
                if effective_target == target_address:
                    hits.append(
                        StoreHit(
                            initializer_address=init_addr,
                            instruction_address=insn["address"],
                            reason=reason or "",
                            disassembly_snippet=snippet_around(idx),
                        )
                    )
            continue

        # Any other instruction: leave the abstract state alone — it's safe to keep prior
        # adrp/add mappings since registers used for global writes typically aren't clobbered
        # in a single basic block.  To be a bit safer we clear the first explicit mov
        # targeting a previously-tracked register.
        mov_match = re.match(r"mov\s+(x\d{1,2}),", text.strip())
        if mov_match:
            clobbered = mov_match.group(1)
            page_base.pop(clobbered, None)
            add_eff.pop(clobbered, None)

    return hits


def collect_nearby_symbols(
    binary_path: Path,
    center_address: int,
    window_bytes: int = 0x400,
) -> list[str]:
    # `llvm-objdump --syms` prints all symbols, which lets us report "nearest known symbol" for
    # user-facing debugging.  This is best-effort: heavily stripped binaries produce very few.
    result = run_command(["xcrun", "llvm-objdump", "--syms", str(binary_path)])
    if result["returncode"] != 0:
        return []
    near: list[tuple[int, str]] = []
    for line in result["stdout"].splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+(?:g|l|w)\s+.*\s+(\S+)\s*$", line)
        if not match:
            continue
        addr = int(match.group(1), 16)
        if abs(addr - center_address) <= window_bytes:
            near.append((addr, match.group(2)))
    near.sort(key=lambda item: abs(item[0] - center_address))
    return [f"0x{addr:x} {name}" for addr, name in near[:6]]


def main() -> int:
    args = build_parser().parse_args()
    repo_root = SCRIPT_DIR.parent
    target_address = int(args.target_address, 0)

    callsite_report_path = Path(args.callsite_report).expanduser()
    callsite_report: dict[str, Any] = {}
    if callsite_report_path.is_file():
        callsite_report = json.loads(callsite_report_path.read_text(encoding="utf-8"))
    binary_path = resolve_binary_path(args.binary_path, callsite_report)
    output_path = Path(args.output).expanduser().resolve()

    otool = run_command(["xcrun", "otool", "-l", str(binary_path)])
    if otool["returncode"] != 0:
        raise SystemExit(f"otool -l failed: {otool['stderr']}")
    regions = parse_macho_regions(otool["stdout"])
    text_base = preferred_text_base(regions)

    init_section = parse_init_offsets_section(otool["stdout"])
    if init_section is None:
        raise SystemExit(
            "Binary does not contain a __TEXT,__init_offsets section; HOK-011 assumes the "
            "chained-fixups era layout used by recent iOS/macOS SDKs."
        )

    offsets = read_init_offsets(binary_path, init_section)
    initializers = resolve_initializer_entry_vmaddrs(offsets, text_base)

    target_region = resolve_region_for_address(regions, target_address)

    scan_summary: list[dict[str, Any]] = []
    hits: list[StoreHit] = []
    progress_stride = max(len(initializers) // 20, 1)
    for index, init_addr in enumerate(initializers):
        if len(hits) >= args.max_hits:
            scan_summary.append({
                "stoppedAt": index,
                "reason": f"max-hits {args.max_hits} reached",
            })
            break
        local_hits = scan_initializer_for_store_to(
            binary_path=binary_path,
            init_addr=init_addr,
            target_address=target_address,
            max_instructions=args.disasm_window,
        )
        hits.extend(local_hits)
        if index % progress_stride == 0:
            print(
                f"scanned {index}/{len(initializers)} initializers, hits so far: {len(hits)}",
                file=sys.stderr,
            )

    print(f"scan complete: {len(initializers)} initializers, {len(hits)} store-site hits", file=sys.stderr)

    hit_payload = []
    for hit in hits:
        hit_payload.append({
            "initializerAddress": f"0x{hit.initializer_address:x}",
            "instructionAddress": f"0x{hit.instruction_address:x}",
            "reason": hit.reason,
            "disassemblySnippet": hit.disassembly_snippet,
            "nearbySymbols": collect_nearby_symbols(binary_path, hit.initializer_address),
        })

    report = {
        "schemaVersion": 1,
        "workflow": "hok-011-ngr-common-init-chain",
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "configuration": {
            "binaryPath": str(binary_path),
            "callsiteReportPath": str(callsite_report_path.resolve()) if callsite_report_path.exists() else None,
            "targetAddress": f"0x{target_address:x}",
            "disasmWindowInstructions": args.disasm_window,
            "maxHits": args.max_hits,
            "outputPath": str(output_path),
        },
        "initializers": {
            "sectionVmaddr": f"0x{init_section.vmaddr:x}",
            "sectionFileoff": f"0x{init_section.fileoff:x}",
            "sectionSize": f"0x{init_section.vmsize:x}",
            "count": init_section.count,
            "textBase": f"0x{text_base:x}",
            "sampleEntries": [f"0x{addr:x}" for addr in initializers[:8]],
        },
        "target": {
            "address": f"0x{target_address:x}",
            "region": summarize_region(target_region),
        },
        "hits": hit_payload,
        "scan": {
            "scannedCount": min(len(initializers), args.max_hits) if not scan_summary else scan_summary[0]["stoppedAt"],
            "maxHitsReached": len(hits) >= args.max_hits,
        },
        "checks": {
            "binaryResolved": True,
            "initOffsetsResolved": True,
            "targetRegionResolved": target_region is not None,
            "anyHitFound": bool(hit_payload),
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if hit_payload else 1


if __name__ == "__main__":
    sys.exit(main())
