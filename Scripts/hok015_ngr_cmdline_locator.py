#!/usr/bin/env python3
"""HOK-015-A: 离线静态定位 ``com.tencent.ngr`` 的 UE4 ``FCommandLine`` 存储。

本脚本**纯离线**地在 NGR 主二进制里定位 HOK-015 需要的三组地址：

1. ``bInitializedAddr``：UE4 ``FCommandLine::bCommandLineInitialized`` 布尔
   所在的 ``__common`` 槽位（1 byte）。
2. ``cmdlineBufferAddr``：UE4 ``FCommandLine::CmdLine`` 字符数组的起始地址
   （UTF-16-LE ``TCHAR``）。
3. ``markerAddr``：fatal 字符串 "Attempting to get the command line but it
   hasn't been initialized yet." 的 vmaddr（运行期 UE4 fatal handler 会把
   这个字符串打到 stderr / 送进 UIAlertController message）。

定位原理：
 - 所有这些地址都在 ``__common`` / ``__ustring``；NGR 的 base vmaddr 记录在
   Mach-O ``__TEXT`` 段 vmaddr 里（观测值 ``0x100000000``）；PlayTools 侧
   会再用 runtime slide 还原实际地址。
 - **marker 字符串**：UE4 iOS 用 UTF-16-LE 存储 TCHAR 字面量，所以这里扫
   的是 ``"Attempting to get..."`` 的 UTF-16-LE 编码，不是 ASCII。
 - **``FCommandLine::Get()`` 的典型指令序列**（UE4 iOS UE4.25+ arm64）：
   ```
   adrp xN, <page(bInitialized)>
   ldrb wN, [xN, #<off(bInitialized)>]  ; load bCommandLineInitialized
   tbz  wN, #0, <fatal_branch>           ; if (!bInitialized) goto fatal
   adrp xM, <page(cmdlineBuffer)>
   add  xM, xM, #<off(cmdlineBuffer)>    ; load CmdLine TCHAR*
   bl   <consumer>                       ; pass CmdLine as arg
   ```
   这条序列在 NGR 二进制里出现 393 次（`FCommandLine::Get` 的众多 inline
   拷贝）；其中 **bInitialized 和 CmdLine 的 adrp 页面 + add 低 12 位完全
   一致**，因此用统计多数（mode）提取。
 - **``FError::LowLevelFatal`` 函数入口**：对 marker 字符串做 adrp+add 的
   callsite 落在同一个函数里（3 条不同的 fatal message 共用同一 helper）。
   入口地址只用于 audit，不作为 HOK-015-B 的必需输入。

输出 ``build/hok-015-cmdline-slots.json``：PlayTools 侧 pt_ngr_preseed_cmdline_once
按该报告硬编码常量；HOK-015-B 运行时再用 slide 还原。

使用：
    python3 Scripts/hok015_ngr_cmdline_locator.py \
        [--binary-path /path/to/NGR] \
        [--output build/hok-015-cmdline-slots.json]

默认 ``--binary-path`` 自动解析到
``~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR``。

脚本**零副作用**：只读 binary、不调用 ``codesign``、不 launch app、不修
改任何文件（除 ``--output``）。
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_BINARY_PATH = Path(
    os.path.expanduser(
        "~/Library/Containers/io.playcover.PlayCover/Applications/"
        "com.tencent.ngr.app/NGR"
    )
)
DEFAULT_OUTPUT = Path("build/hok-015-cmdline-slots.json")
MARKER_STRING = (
    "Attempting to get the command line but it hasn't been initialized yet."
)


# ---------------------------------------------------------------------------
# ARM64 instruction decoding helpers.
# ---------------------------------------------------------------------------

def decode_adrp(inst: int, pc: int) -> tuple[int, int] | None:
    """Return (Rd, target_page) for an ADRP instruction, None otherwise."""
    if (inst & 0x9F000000) != 0x90000000:
        return None
    immlo = (inst >> 29) & 0x3
    immhi = (inst >> 5) & 0x7FFFF
    imm21 = (immhi << 2) | immlo
    if imm21 & (1 << 20):
        imm21 -= (1 << 21)
    Rd = inst & 0x1F
    return Rd, (pc & ~0xFFF) + (imm21 << 12)


def decode_add_imm(inst: int) -> tuple[int, int, int] | None:
    """Return (Rd, Rn, imm) for ADD immediate (64-bit), None otherwise."""
    if (inst & 0xFF800000) != 0x91000000:
        return None
    sh = (inst >> 22) & 0x1
    imm12 = (inst >> 10) & 0xFFF
    if sh:
        imm12 <<= 12
    Rn = (inst >> 5) & 0x1F
    Rd = inst & 0x1F
    return Rd, Rn, imm12


def decode_ldrb_imm(inst: int) -> tuple[int, int, int] | None:
    """Return (Rt, Rn, imm12) for LDRB (immediate, unsigned offset)."""
    if (inst & 0xFFC00000) != 0x39400000:
        return None
    imm12 = (inst >> 10) & 0xFFF
    Rn = (inst >> 5) & 0x1F
    Rt = inst & 0x1F
    return Rt, Rn, imm12


def decode_tbz_tbnz(inst: int, pc: int) -> tuple[str, int, int, int] | None:
    """Return (kind, Rt, bit_pos, target) for TBZ/TBNZ, None otherwise."""
    if (inst & 0x7F000000) != 0x36000000:
        return None
    kind = "TBZ" if (inst & 0x01000000) == 0 else "TBNZ"
    b5 = (inst >> 31) & 0x1
    b40 = (inst >> 19) & 0x1F
    bit_pos = (b5 << 5) | b40
    imm14 = (inst >> 5) & 0x3FFF
    if imm14 & (1 << 13):
        imm14 -= (1 << 14)
    Rt = inst & 0x1F
    return kind, Rt, bit_pos, pc + (imm14 << 2)


# ---------------------------------------------------------------------------
# Mach-O parsing.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class MachOSection:
    segname: str
    sectname: str
    vmaddr: int
    vmsize: int
    fileoff: int
    size: int


@dataclass(frozen=True)
class MachOImage:
    text_vmaddr: int
    text_fileoff: int
    sections: list[MachOSection]

    def section(self, segname: str, sectname: str) -> MachOSection | None:
        for s in self.sections:
            if s.segname == segname and s.sectname == sectname:
                return s
        return None


def parse_macho_layout(binary_path: Path) -> MachOImage:
    """Parse ``otool -l`` output and extract segments/sections relevant to us."""
    proc = subprocess.run(
        ["xcrun", "otool", "-l", str(binary_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    lines = proc.stdout.splitlines()
    sections: list[MachOSection] = []
    text_vmaddr = 0
    text_fileoff = 0
    i = 0
    cur_segname: str | None = None
    # We'll walk the structured output: LC_SEGMENT_64 blocks contain
    # segname/vmaddr/fileoff/filesize then a sequence of "Section" entries.
    while i < len(lines):
        line = lines[i].strip()
        if line == "cmd LC_SEGMENT_64":
            # Read segment body until next "Load command" or "Section"
            seg_block: dict[str, str] = {}
            j = i + 1
            while j < len(lines):
                stripped = lines[j].strip()
                if (
                    stripped.startswith("Load command ")
                    or stripped == "Section"
                    or stripped == "cmd LC_SEGMENT_64"
                ):
                    break
                parts = stripped.split(None, 1)
                if len(parts) == 2:
                    seg_block[parts[0]] = parts[1]
                j += 1
            cur_segname = seg_block.get("segname")
            if cur_segname == "__TEXT":
                text_vmaddr = int(seg_block.get("vmaddr", "0"), 0)
                text_fileoff = int(seg_block.get("fileoff", "0"))
            i = j
            continue
        if line == "Section":
            sec_block: dict[str, str] = {}
            j = i + 1
            while j < len(lines):
                stripped = lines[j].strip()
                if (
                    stripped.startswith("Load command ")
                    or stripped == "Section"
                    or stripped == "cmd LC_SEGMENT_64"
                ):
                    break
                parts = stripped.split(None, 1)
                if len(parts) == 2:
                    sec_block[parts[0]] = parts[1]
                j += 1
            segname = sec_block.get("segname", cur_segname or "?")
            sectname = sec_block.get("sectname", "?")
            vmaddr = int(sec_block.get("addr", "0"), 0)
            vmsize = int(sec_block.get("size", "0"), 0)
            fileoff_s = sec_block.get("offset", "0")
            fileoff = int(fileoff_s)
            sections.append(
                MachOSection(
                    segname=segname,
                    sectname=sectname,
                    vmaddr=vmaddr,
                    vmsize=vmsize,
                    fileoff=fileoff,
                    size=vmsize,
                )
            )
            i = j
            continue
        i += 1
    return MachOImage(
        text_vmaddr=text_vmaddr, text_fileoff=text_fileoff, sections=sections
    )


# ---------------------------------------------------------------------------
# Marker string scan.
# ---------------------------------------------------------------------------

def find_marker_string(
    data: bytes, image: MachOImage, marker: str
) -> tuple[int, int]:
    """Find ``marker`` encoded as UTF-16-LE inside __ustring. Return
    (file_offset, vmaddr). Raise if not found.
    """
    ustring = image.section("__TEXT", "__ustring")
    if ustring is None:
        raise SystemExit("Failed to locate __TEXT,__ustring section")
    encoded = marker.encode("utf-16-le")
    sect_end = ustring.fileoff + ustring.size
    idx = data.find(encoded, ustring.fileoff, sect_end)
    if idx < 0:
        raise SystemExit(
            f"Marker string not found in __ustring: {marker!r} (utf-16-le)"
        )
    vmaddr = ustring.vmaddr + (idx - ustring.fileoff)
    return idx, vmaddr


# ---------------------------------------------------------------------------
# Core scan: FCommandLine::Get() inline sequence.
# ---------------------------------------------------------------------------

@dataclass
class CmdlineGetCallsite:
    """A concrete match of the inline ``FCommandLine::Get()`` guard+access
    sequence."""

    # PC of the ldrb (reads bInitialized)
    ldrb_pc: int
    # PC of the tbz (branches to fatal when not initialized)
    tbz_pc: int
    # PC of the add (materialises CmdLine TCHAR*)
    add_pc: int
    # Page + offset resolved from the adrp+ldrb pair -> bInitialized addr
    bInitialized_addr: int
    # Page + offset resolved from the adrp+add pair -> CmdLine buffer addr
    cmdline_buffer_addr: int
    # Target of the tbz (where fatal branch goes)
    fatal_branch_target: int


def scan_cmdline_get_callsites(
    data: bytes, image: MachOImage
) -> list[CmdlineGetCallsite]:
    """Scan the __text section for inline FCommandLine::Get() sequences:
        adrp xB, <bpage>
        ldrb wB, [xB, #<boff>]
        tbz  wB, #0, <fatal>
        adrp xC, <cpage>
        add  xC, xC, #<coff>
    """
    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("Failed to locate __TEXT,__text section")
    text_bytes = data[text.fileoff : text.fileoff + text.size]
    n = text.size // 4

    results: list[CmdlineGetCallsite] = []

    for i in range(n - 5):
        # Look for: ADRP Rb ; LDRB Rb,[Rb,#off] ; TBZ Rb,#0,<tgt> ; ADRP Rc ; ADD Rc,Rc,#off
        inst0 = struct.unpack_from("<I", text_bytes, i * 4)[0]
        adrp0 = decode_adrp(inst0, text.vmaddr + i * 4)
        if adrp0 is None:
            continue
        Rb, bpage = adrp0

        inst1 = struct.unpack_from("<I", text_bytes, (i + 1) * 4)[0]
        ldrb = decode_ldrb_imm(inst1)
        if ldrb is None:
            continue
        Rt1, Rn1, boff = ldrb
        if Rn1 != Rb or Rt1 != Rb:
            # FCommandLine::Get emits `ldrb wRb, [xRb, #off]` (Rt==Rn); require that.
            continue
        bInit = bpage + boff

        inst2 = struct.unpack_from("<I", text_bytes, (i + 2) * 4)[0]
        tbz = decode_tbz_tbnz(inst2, text.vmaddr + (i + 2) * 4)
        if tbz is None:
            continue
        tbz_kind, tbz_Rt, tbz_bit, tbz_tgt = tbz
        if tbz_kind != "TBZ" or tbz_Rt != Rb or tbz_bit != 0:
            continue

        # Next should be another ADRP (for CmdLine) then ADD
        inst3 = struct.unpack_from("<I", text_bytes, (i + 3) * 4)[0]
        adrp1 = decode_adrp(inst3, text.vmaddr + (i + 3) * 4)
        if adrp1 is None:
            continue
        Rc, cpage = adrp1

        inst4 = struct.unpack_from("<I", text_bytes, (i + 4) * 4)[0]
        add = decode_add_imm(inst4)
        if add is None:
            continue
        Rc_add, Rn_add, coff = add
        if Rn_add != Rc or Rc_add != Rc:
            continue
        cmdline = cpage + coff

        results.append(
            CmdlineGetCallsite(
                ldrb_pc=text.vmaddr + (i + 1) * 4,
                tbz_pc=text.vmaddr + (i + 2) * 4,
                add_pc=text.vmaddr + (i + 4) * 4,
                bInitialized_addr=bInit,
                cmdline_buffer_addr=cmdline,
                fatal_branch_target=tbz_tgt,
            )
        )

    return results


# ---------------------------------------------------------------------------
# Marker string reference scan (audit only).
# ---------------------------------------------------------------------------

def scan_marker_references(
    data: bytes, image: MachOImage, marker_vmaddr: int
) -> list[int]:
    """Find PCs that ADRP+ADD materialise the marker_vmaddr (audit aid).

    UE4 fatal helper passes the marker pointer as a format argument; these are
    the callsites that trigger UE4 ``FError::LowLevelFatal`` with the marker.
    """
    text = image.section("__TEXT", "__text")
    assert text is not None
    text_bytes = data[text.fileoff : text.fileoff + text.size]
    n = text.size // 4
    target_page = marker_vmaddr & ~0xFFF
    target_off12 = marker_vmaddr & 0xFFF
    hits: list[int] = []
    for i in range(n - 1):
        inst = struct.unpack_from("<I", text_bytes, i * 4)[0]
        adrp = decode_adrp(inst, text.vmaddr + i * 4)
        if adrp is None:
            continue
        Rd, page = adrp
        if page != target_page:
            continue
        nxt = struct.unpack_from("<I", text_bytes, (i + 1) * 4)[0]
        add = decode_add_imm(nxt)
        if add is None:
            continue
        Rd2, Rn, imm = add
        if Rn == Rd and imm == target_off12:
            hits.append(text.vmaddr + (i + 1) * 4)
    return hits


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="HOK-015-A: locate NGR UE4 FCommandLine slots in __common"
    )
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    ap.add_argument("--binary-path", default=str(DEFAULT_BINARY_PATH))
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return ap


def main() -> int:
    args = build_parser().parse_args()
    binary_path = Path(os.path.expanduser(args.binary_path)).resolve()
    output_path = Path(os.path.expanduser(args.output))
    if not output_path.is_absolute():
        output_path = (REPO_ROOT / output_path).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if not binary_path.exists():
        print(f"error: binary not found: {binary_path}", file=sys.stderr)
        return 1

    with open(binary_path, "rb") as f:
        data = f.read()

    image = parse_macho_layout(binary_path)

    # 1. Marker string.
    marker_fileoff, marker_vmaddr = find_marker_string(
        data, image, MARKER_STRING
    )

    # 2. Marker references (audit).
    marker_refs = scan_marker_references(data, image, marker_vmaddr)

    # 3. FCommandLine::Get inline sequences.
    callsites = scan_cmdline_get_callsites(data, image)

    # Bucket by bInitialized / cmdline buffer address; take the statistical mode.
    bInit_counter: collections.Counter[int] = collections.Counter()
    cmd_counter: collections.Counter[int] = collections.Counter()
    for cs in callsites:
        bInit_counter[cs.bInitialized_addr] += 1
        cmd_counter[cs.cmdline_buffer_addr] += 1

    if not bInit_counter:
        print("error: no FCommandLine::Get inline sequences matched", file=sys.stderr)
        report = {
            "schemaVersion": 1,
            "generatedAt": utc_now_iso(),
            "bundleId": args.bundle_id,
            "binaryPath": str(binary_path),
            "status": "locate-failed",
            "reason": "no_cmdline_get_sequence_matched",
        }
        output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        return 2

    bInit_addr, bInit_count = bInit_counter.most_common(1)[0]
    cmd_addr, cmd_count = cmd_counter.most_common(1)[0]

    # Sanity: bInit is 1-byte (LDRB), cmdline buffer should be adjacent / 2-byte aligned
    # (UTF-16 TCHAR). We don't enforce a hard layout, but record deltas.
    delta = cmd_addr - bInit_addr

    sample_callsites = [
        {
            "ldrbPc": f"0x{cs.ldrb_pc:x}",
            "tbzPc": f"0x{cs.tbz_pc:x}",
            "addPc": f"0x{cs.add_pc:x}",
            "bInitializedAddr": f"0x{cs.bInitialized_addr:x}",
            "cmdlineBufferAddr": f"0x{cs.cmdline_buffer_addr:x}",
            "fatalBranchTarget": f"0x{cs.fatal_branch_target:x}",
        }
        for cs in callsites[:8]
    ]

    report = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "binaryPath": str(binary_path),
        "status": "primed-candidate" if bInit_count > 10 else "low-confidence",
        "textVMAddrUnslid": f"0x{image.text_vmaddr:x}",
        "markerString": MARKER_STRING,
        "markerVMAddr": f"0x{marker_vmaddr:x}",
        "markerFileOffset": f"0x{marker_fileoff:x}",
        "markerReferenceCount": len(marker_refs),
        "markerReferenceCallsites": [f"0x{pc:x}" for pc in marker_refs],
        "bInitializedAddr": f"0x{bInit_addr:x}",
        "bInitializedModeCount": bInit_count,
        "bInitializedCandidatesTop": [
            {"addr": f"0x{a:x}", "count": c}
            for a, c in bInit_counter.most_common(5)
        ],
        "cmdlineBufferAddr": f"0x{cmd_addr:x}",
        "cmdlineBufferModeCount": cmd_count,
        "cmdlineBufferCandidatesTop": [
            {"addr": f"0x{a:x}", "count": c}
            for a, c in cmd_counter.most_common(5)
        ],
        "cmdlineBufferDeltaFromBInitialized": f"0x{delta:x}",
        # UE4 default; not directly encoded in the binary but documented via
        # FCommandLine::MaxCommandLineSize. HOK-015-B only writes a short
        # null-terminated TCHAR string well under any reasonable buffer, so this
        # is informational only.
        "cmdlineBufferSizeAssumed": 16384,
        "inlineCallsiteCount": len(callsites),
        "inlineCallsitesSample": sample_callsites,
        "seedValueTCHAR": "../../../NGR/NGR.uproject",
        "seedValueEncoding": "utf-16-le",
        "notes": [
            "marker string is stored as UTF-16-LE in __TEXT,__ustring (UE4 TCHAR=uint16_t on iOS/Mac)",
            "bInitialized is a 1-byte bool read via LDRB; fatal branch taken when bit0==0 (TBZ wRb, #0, ...)",
            "cmdline buffer is TCHAR[MaxCommandLineSize]; address materialised via adrp+add (no load)",
            "HOK-015-B writes seedValueTCHAR as UTF-16-LE into cmdlineBufferAddr, then sets bInitializedAddr byte to 1",
            "after HOK-015-B, UE4 FCommandLine::Get() inline TBZ falls through to the normal path (return CmdLine)",
        ],
    }

    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"HOK-015-A report written to {output_path}\n"
        f"  bInitializedAddr = 0x{bInit_addr:x} (mode count {bInit_count}/{len(callsites)})\n"
        f"  cmdlineBufferAddr = 0x{cmd_addr:x} (mode count {cmd_count}/{len(callsites)})\n"
        f"  marker references = {len(marker_refs)}\n"
        f"  inline FCommandLine::Get sequences = {len(callsites)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
