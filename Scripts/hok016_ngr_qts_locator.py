#!/usr/bin/env python3
"""HOK-016-A: 离线静态定位 ``com.tencent.ngr`` 的 ``QtsFileSystem`` 家族
字符串与 reporter 函数。

背景（见 ``LocalDocs/HOKCrash/00-Dashboard.md`` 当前主线 HOK-016）：
  - HOK-015 之后 ``launch-events.jsonl`` 仍然 1 次 ``hok014_ngr_alert_suppressed``
    ``message="QtsFileSystem Create Failed!!"``；这条路径与 UE4
    ``FCommandLine::Get()`` fatal **完全不在同一条 call graph**。
  - 静态上，``"QtsFileSystem Create Failed!!"`` 只有 1 条 adrp+add xref，
    指向 ``0x1088792d4``（reporter 函数内部）。reporter 上游走 virtual
    dispatch / 函数指针，静态 BL / B 零匹配，所以**静态能做到的就是**：
    * 精确锁定 reporter 函数**入口地址**（prologue 扫描）；
    * 把 reporter 入口前 N 条 disasm + 使用的 adrp/add 指针 dump 下来，
      辅助后续 HOK-016-B LLDB BP 判定命中点是否是真的 reporter；
    * 把 ``"QtsFileSystem"`` 前缀的 ASCII 字符串全扫一遍，形成家族视图
      （``Create Failed`` / ``Open Failed`` / ``Init Failed`` 等兄弟字
      符串通常共用同一个 reporter，可以反过来标定 reporter 责任域）。

输出 ``build/hok-016-qts-fs-static.json``：供 HOK-016-B 的 LLDB runner 消费，
以及人工对照 reporter 行为。

脚本**零副作用**：只读 binary、不调用 ``codesign``、不 launch app、不修
改任何文件（除 ``--output``）。

用法::

    python3 Scripts/hok016_ngr_qts_locator.py \
        [--binary-path /path/to/NGR] \
        [--output build/hok-016-qts-fs-static.json]

默认 ``--binary-path`` 自动解析到
``~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR``。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Reuse HOK-015 locator helpers for Mach-O parsing and ARM64 instruction decode.
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

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
DEFAULT_OUTPUT = Path("build/hok-016-qts-fs-static.json")

# Target reporter callsite documented in Dashboard HOK-016.
DEFAULT_REPORTER_CALLSITE = "0x1088792d4"

PRIMARY_MARKER = "QtsFileSystem Create Failed!!"
FAMILY_PREFIX = "QtsFileSystem"
# A few well-known UE4 / iOS UI strings often seen near the QtsFileSystem
# family; we include them so callers can verify reporter_func is *really*
# `UE_LOG(LogQts, Fatal, ...)` style vs something else entirely.
ADJACENT_HINTS = ("Message", "QtsFS", "QtsFileSystem")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# ASCII / CString scanners.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class StringHit:
    segname: str
    sectname: str
    file_offset: int
    vmaddr: int
    value: str


@dataclass(frozen=True)
class StringEncoding:
    """Describes a (section, encoding) pair for string scanning."""
    segname: str
    sectname: str
    encoding: str  # "ascii" or "utf-16-le"
    unit_size: int  # 1 for ASCII/UTF-8, 2 for UTF-16-LE


def _iter_string_sections(image: MachOImage) -> list[tuple[MachOSection, StringEncoding]]:
    """Return (section, encoding) pairs that plausibly contain strings.

    NGR stores UE4 TCHAR (UTF-16-LE) string literals in ``__TEXT,__ustring``
    and the ``QtsFileSystem Create Failed!!`` message is in that section
    (Dashboard HOK-016 documents vmaddr ``0x10c09d070``). We also scan the
    ASCII C-string sections so future refactors that switch to ASCII are
    surfaced without changes to this script.
    """
    wanted: list[tuple[str, str, str, int]] = [
        ("__TEXT", "__cstring", "ascii", 1),
        ("__TEXT", "__const", "ascii", 1),
        ("__TEXT", "__objc_methname", "ascii", 1),
        ("__TEXT", "__objc_classname", "ascii", 1),
        ("__TEXT", "__objc_methtype", "ascii", 1),
        ("__DATA", "__cstring", "ascii", 1),
        ("__DATA_CONST", "__cstring", "ascii", 1),
        ("__DATA_CONST", "__const", "ascii", 1),
        # UE4 TCHAR string literals live here; UTF-16-LE with 2-byte
        # null terminator.
        ("__TEXT", "__ustring", "utf-16-le", 2),
    ]
    result: list[tuple[MachOSection, StringEncoding]] = []
    for s in image.sections:
        for segname, sectname, encoding, unit_size in wanted:
            if s.segname == segname and s.sectname == sectname:
                result.append(
                    (s, StringEncoding(segname=segname, sectname=sectname, encoding=encoding, unit_size=unit_size))
                )
                break
    return result


def _decode_string_at(
    data: bytes, start: int, end: int, encoding: str, unit_size: int
) -> tuple[int, str]:
    """Return (end_offset, decoded_value) for a null-terminated string that
    starts at ``start`` in ``data``. ``end`` bounds the section.

    For UTF-16-LE, the null terminator is two zero bytes on a 2-byte boundary.
    """
    if unit_size == 1:
        zero = data.find(b"\x00", start, end)
        if zero < 0:
            zero = end
        try:
            value = data[start:zero].decode("ascii")
        except UnicodeDecodeError:
            value = data[start:zero].decode("utf-8", errors="replace")
        return zero, value
    # UTF-16-LE: walk 2 bytes at a time looking for \x00\x00 on even offset.
    cursor = start
    while cursor + 2 <= end:
        if data[cursor] == 0 and data[cursor + 1] == 0:
            break
        cursor += 2
    value = data[start:cursor].decode("utf-16-le", errors="replace")
    return cursor, value


def scan_strings_with_prefix(
    data: bytes,
    image: MachOImage,
    prefix: str,
    limit: int | None = None,
) -> list[StringHit]:
    """Scan all string sections (ASCII in __cstring/__const, UTF-16-LE in
    __ustring) for null-terminated strings that start with ``prefix``.

    Returns a list of ``StringHit`` sorted by section walking order; each
    hit carries the absolute file offset + reconstructed vmaddr + decoded
    Python ``str`` value.
    """
    ascii_prefix = prefix.encode("ascii")
    utf16_prefix = prefix.encode("utf-16-le")
    hits: list[StringHit] = []
    for sec, enc in _iter_string_sections(image):
        if sec.size <= 0:
            continue
        base = sec.fileoff
        end = sec.fileoff + sec.size
        unit_size = enc.unit_size
        prefix_bytes = ascii_prefix if enc.encoding == "ascii" else utf16_prefix
        cursor = base
        # For ASCII, step past any zero padding. For UTF-16-LE, align to
        # 2 bytes and step past \x00\x00 terminators.
        while cursor + unit_size <= end:
            if unit_size == 1:
                if data[cursor] == 0:
                    cursor += 1
                    continue
            else:  # unit_size == 2
                if (cursor - base) % 2 != 0:
                    cursor += 1
                    continue
                if data[cursor] == 0 and data[cursor + 1] == 0:
                    cursor += 2
                    continue
            string_start = cursor
            if data[string_start:string_start + len(prefix_bytes)] == prefix_bytes:
                end_off, value = _decode_string_at(
                    data, string_start, end, enc.encoding, unit_size
                )
                vmaddr = sec.vmaddr + (string_start - sec.fileoff)
                hits.append(
                    StringHit(
                        segname=sec.segname,
                        sectname=sec.sectname,
                        file_offset=string_start,
                        vmaddr=vmaddr,
                        value=value,
                    )
                )
                if limit is not None and len(hits) >= limit:
                    return hits
                cursor = end_off + unit_size
            else:
                # Skip to the next candidate by finding the section-local
                # terminator.
                end_off, _ = _decode_string_at(
                    data, string_start, end, enc.encoding, unit_size
                )
                cursor = end_off + unit_size
    return hits


# Back-compat alias: old name, same semantics.
scan_ascii_strings_with_prefix = scan_strings_with_prefix


# ---------------------------------------------------------------------------
# ADRP + ADD reference scanner (copied in spirit from HOK-015 locator).
# ---------------------------------------------------------------------------

def scan_adrp_add_references(
    data: bytes, image: MachOImage, target_vmaddr: int
) -> list[int]:
    """Return PCs of ADRP+ADD pairs that materialize ``target_vmaddr``."""
    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("Failed to locate __TEXT,__text section")
    text_bytes = data[text.fileoff: text.fileoff + text.size]
    n = text.size // 4
    target_page = target_vmaddr & ~0xFFF
    target_off12 = target_vmaddr & 0xFFF
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
            # The ADRP+ADD pair resolves to target. Record the ADD pc
            # (higher-level callers use this as "the xref").
            hits.append(text.vmaddr + (i + 1) * 4)
    return hits


# ---------------------------------------------------------------------------
# ARM64 prologue detection for reporter function entry.
# ---------------------------------------------------------------------------

def decode_stp_pre_index_x29_x30_sp(inst: int) -> bool:
    """Return True if ``inst`` is ``stp x29, x30, [sp, #imm]!`` (pre-index).

    Encoding (64-bit pair, GPR, pre-index):
        bit 31: sf (1 -> 64-bit)
        bits 30..29: 10
        bits 28..27: 10
        bit 26: 0 (integer)
        bits 25..23: 010 -> pre-index STP
        bit 22: L (0 -> STP)
        Rt / Rt2 must be 29 / 30; Rn must be 31 (SP).
    Concretely: ``0xA9Bxxxxx`` with low fields set. Test with hex mask:
        (inst & 0x7FC003E0) == 0x29800020 is ambiguous, so we check the
        layout explicitly.
    """
    if (inst & 0xFFC00000) != 0xA9800000:
        # Not a pre-index STP (64-bit, pre-index) at all.
        return False
    # sf=1, opc=10, V=0, L=0, imm7, Rt2, Rn, Rt
    Rt = inst & 0x1F
    Rt2 = (inst >> 10) & 0x1F
    Rn = (inst >> 5) & 0x1F
    return Rt == 29 and Rt2 == 30 and Rn == 31


def decode_sub_sp_sp_imm(inst: int) -> bool:
    """Return True if ``inst`` is ``sub sp, sp, #imm`` (immediate)."""
    # SUB (immediate, 64-bit): 1|10|100010|sh|imm12|Rn|Rd
    if (inst & 0xFF800000) != 0xD1000000:
        return False
    Rn = (inst >> 5) & 0x1F
    Rd = inst & 0x1F
    return Rn == 31 and Rd == 31


def decode_pacibsp(inst: int) -> bool:
    """Return True if ``inst`` is ``pacibsp`` (0xD503237F)."""
    return inst == 0xD503237F


def decode_paciasp(inst: int) -> bool:
    """Return True if ``inst`` is ``paciasp`` (0xD503233F)."""
    return inst == 0xD503233F


def _is_prologue_instruction(inst: int) -> bool:
    """Heuristic: an ARM64 function prologue 'anchor' instruction.

    Accepts the typical first instruction of a non-leaf function on
    macOS/iOS: ``stp x29, x30, [sp, #-NN]!`` / ``sub sp, sp, #NN`` /
    ``pacibsp`` / ``paciasp``.
    """
    return (
        decode_stp_pre_index_x29_x30_sp(inst)
        or decode_sub_sp_sp_imm(inst)
        or decode_pacibsp(inst)
        or decode_paciasp(inst)
    )


def find_function_entry(
    data: bytes, image: MachOImage, pc_inside_function: int, max_walkback: int = 4096
) -> int | None:
    """Walk backwards from ``pc_inside_function`` (inside __TEXT,__text)
    and return the vmaddr of the first instruction that looks like a
    function prologue anchor.

    We bound the search to ``max_walkback`` instructions (16 KiB) to avoid
    pathological walks; UE4 + NGR's largest observed function body fits
    well under this budget.
    """
    text = image.section("__TEXT", "__text")
    if text is None:
        return None
    # Align pc to 4-byte boundary.
    pc = pc_inside_function & ~0x3
    if pc < text.vmaddr or pc >= text.vmaddr + text.size:
        return None
    i = (pc - text.vmaddr) // 4
    steps = 0
    while i >= 0 and steps < max_walkback:
        file_off = text.fileoff + i * 4
        inst = struct.unpack_from("<I", data, file_off)[0]
        if _is_prologue_instruction(inst):
            return text.vmaddr + i * 4
        i -= 1
        steps += 1
    return None


def dump_disasm_window(
    data: bytes, image: MachOImage, entry_vmaddr: int, num_instructions: int
) -> list[dict[str, Any]]:
    """Return a list of ``{pc, encoding, mnemonicHint}`` entries starting at
    ``entry_vmaddr``. We keep the disasm lightweight: raw encoding + a few
    opcode hints (ADRP / ADD / STP / SUB / BL / RET / etc.) so the
    JSON report is self-contained without shelling out to otool.
    """
    text = image.section("__TEXT", "__text")
    if text is None:
        return []
    results: list[dict[str, Any]] = []
    for k in range(num_instructions):
        pc = entry_vmaddr + k * 4
        if pc >= text.vmaddr + text.size:
            break
        file_off = text.fileoff + (pc - text.vmaddr)
        inst = struct.unpack_from("<I", data, file_off)[0]
        hint = _mnemonic_hint(inst, pc, data, image)
        results.append(
            {
                "pc": f"0x{pc:x}",
                "encoding": f"0x{inst:08x}",
                "mnemonicHint": hint,
            }
        )
    return results


def _mnemonic_hint(
    inst: int, pc: int, data: bytes, image: MachOImage
) -> str:
    """Return a short human-readable hint for one ARM64 instruction.

    We prefer to resolve ADRP+ADD / ADRP+LDR patterns into the effective
    target vmaddr so the reporter's string arguments are visible in the
    report. If the helper cannot classify the instruction confidently,
    it falls back to ``f"raw:0x{inst:08x}"``.
    """
    if decode_stp_pre_index_x29_x30_sp(inst):
        return "stp x29,x30,[sp,#imm]!"
    if decode_sub_sp_sp_imm(inst):
        return "sub sp,sp,#imm"
    if decode_pacibsp(inst):
        return "pacibsp"
    if decode_paciasp(inst):
        return "paciasp"
    if inst == 0xD65F03C0:
        return "ret"
    if (inst & 0xFC000000) == 0x94000000:
        # BL <label>
        imm26 = inst & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= (1 << 26)
        target = pc + (imm26 << 2)
        return f"bl 0x{target:x}"
    if (inst & 0xFC000000) == 0x14000000:
        imm26 = inst & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= (1 << 26)
        target = pc + (imm26 << 2)
        return f"b 0x{target:x}"
    adrp = decode_adrp(inst, pc)
    if adrp is not None:
        Rd, page = adrp
        return f"adrp x{Rd},0x{page:x}"
    add = decode_add_imm(inst)
    if add is not None:
        Rd, Rn, imm = add
        return f"add x{Rd},x{Rn},#0x{imm:x}"
    return f"raw:0x{inst:08x}"


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="HOK-016-A: locate NGR QtsFileSystem reporter function & family strings"
    )
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    ap.add_argument("--binary-path", default=str(DEFAULT_BINARY_PATH))
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    ap.add_argument(
        "--reporter-callsite",
        default=DEFAULT_REPORTER_CALLSITE,
        help=(
            "an address *inside* the reporter function (documented in "
            f"Dashboard HOK-016 as {DEFAULT_REPORTER_CALLSITE}). The walker "
            "goes backwards from here to find the function prologue."
        ),
    )
    ap.add_argument(
        "--disasm-window",
        type=int,
        default=32,
        help=(
            "number of ARM64 instructions to dump from the reporter function "
            "entry onwards (default: 32)."
        ),
    )
    ap.add_argument(
        "--family-prefix",
        default=FAMILY_PREFIX,
        help=f"scan C strings whose prefix matches this value (default: {FAMILY_PREFIX!r}).",
    )
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

    # 1. Locate the primary marker string as a C string.
    primary_hits = scan_ascii_strings_with_prefix(
        data, image, PRIMARY_MARKER, limit=4
    )
    if not primary_hits:
        report = {
            "schemaVersion": 1,
            "generatedAt": utc_now_iso(),
            "bundleId": args.bundle_id,
            "binaryPath": str(binary_path),
            "status": "locate-failed",
            "reason": "primary_marker_not_found_as_cstring",
            "markerString": PRIMARY_MARKER,
        }
        output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"error: primary marker not located; wrote {output_path}", file=sys.stderr)
        return 2

    primary = primary_hits[0]

    # 2. Scan ADRP+ADD xrefs to the primary marker (should find exactly 1 per
    # Dashboard; record all so regressions are visible).
    marker_xrefs = scan_adrp_add_references(data, image, primary.vmaddr)

    # 3. Resolve reporter function entry by walking back from the documented
    # callsite inside it.
    reporter_callsite = int(args.reporter_callsite, 0)
    reporter_entry = find_function_entry(
        data, image, pc_inside_function=reporter_callsite
    )

    # Fallback: use the first marker xref's walk-back if the Dashboard
    # callsite happens to be wrong (keeps the report self-healing).
    reporter_entry_via_xref: int | None = None
    if marker_xrefs:
        reporter_entry_via_xref = find_function_entry(
            data, image, pc_inside_function=marker_xrefs[0]
        )

    # 4. Dump disasm window from reporter entry.
    disasm: list[dict[str, Any]] = []
    if reporter_entry is not None:
        disasm = dump_disasm_window(
            data, image, reporter_entry, args.disasm_window
        )

    # 5. Scan the full QtsFileSystem string family for the reporter's
    # "responsibility domain".
    family_hits = scan_ascii_strings_with_prefix(
        data, image, args.family_prefix, limit=None
    )
    # Keep only a sensible max in the report (family can be long; 64 is
    # enough to cover a UE4 subsystem).
    family_hits_trimmed = family_hits[:64]
    family_with_xrefs: list[dict[str, Any]] = []
    for fh in family_hits_trimmed:
        xrefs = scan_adrp_add_references(data, image, fh.vmaddr)
        family_with_xrefs.append(
            {
                "value": fh.value,
                "vmaddr": f"0x{fh.vmaddr:x}",
                "segSect": f"{fh.segname},{fh.sectname}",
                "adrpAddXrefCount": len(xrefs),
                "adrpAddXrefs": [f"0x{x:x}" for x in xrefs[:8]],
            }
        )

    # 6. Also include any `"Message"` title string so HOK-016-B's LLDB
    # BP evidence can be cross-checked against title+message arg order.
    message_hits = scan_ascii_strings_with_prefix(
        data, image, "Message", limit=16
    )
    message_refs = [
        {
            "value": mh.value,
            "vmaddr": f"0x{mh.vmaddr:x}",
            "segSect": f"{mh.segname},{mh.sectname}",
        }
        for mh in message_hits if mh.value == "Message"
    ]

    report = {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "bundleId": args.bundle_id,
        "binaryPath": str(binary_path),
        "status": (
            "primed"
            if (reporter_entry is not None and marker_xrefs)
            else "locate-partial"
        ),
        "textVMAddrUnslid": f"0x{image.text_vmaddr:x}",
        "primaryMarker": {
            "value": primary.value,
            "vmaddr": f"0x{primary.vmaddr:x}",
            "fileOffset": f"0x{primary.file_offset:x}",
            "segSect": f"{primary.segname},{primary.sectname}",
            "allHits": [
                {
                    "value": h.value,
                    "vmaddr": f"0x{h.vmaddr:x}",
                    "segSect": f"{h.segname},{h.sectname}",
                }
                for h in primary_hits
            ],
        },
        "markerXrefs": {
            "count": len(marker_xrefs),
            "callsites": [f"0x{x:x}" for x in marker_xrefs],
        },
        "reporterCallsite": {
            "documented": args.reporter_callsite,
            "documentedVMAddr": f"0x{reporter_callsite:x}",
        },
        "reporterFunction": {
            "entryFromDocumentedCallsite": (
                f"0x{reporter_entry:x}" if reporter_entry is not None else None
            ),
            "entryFromFirstMarkerXref": (
                f"0x{reporter_entry_via_xref:x}"
                if reporter_entry_via_xref is not None
                else None
            ),
            "entryAgreement": (
                reporter_entry is not None
                and reporter_entry_via_xref is not None
                and reporter_entry == reporter_entry_via_xref
            ),
            "disasmFromEntry": disasm,
        },
        "qtsFileSystemFamily": {
            "prefix": args.family_prefix,
            "totalFound": len(family_hits),
            "truncatedTo": len(family_hits_trimmed),
            "strings": family_with_xrefs,
        },
        "adjacentHints": {
            "Message": message_refs,
        },
        "notes": [
            'primary marker "QtsFileSystem Create Failed!!" is a UTF-16-LE TCHAR literal (__TEXT,__ustring); reporter consumes it via adrp+add.',
            "reporter callsite documented at 0x1088792d4; entryFromDocumentedCallsite is the walked-back function prologue (stp x29,x30 / pacibsp).",
            "the reporter function is expected to be the VFS failure dispatcher; callers are virtual dispatch / function pointers (no direct BL xref). HOK-016-B sets an LLDB BP on the reporter entry to capture backtrace + arg registers at the moment of failure.",
            'the "QtsFileSystem" family covers sibling messages (Open / Init / ...) that usually share this reporter; matching family members with >=1 adrpAddXref confirms the responsibility domain.',
            'after HOK-016-A, HOK-016-B runs `Scripts/hok006_ngr_lldb_runner.py` with `--pre-run-command "breakpoint set --address <reporter-entry>"` to collect backtrace + x0..x8 when the reporter fires.',
        ],
    }

    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    # Terse stdout summary.
    print(f"HOK-016-A report written to {output_path}")
    print(
        f"  primary marker vmaddr   = 0x{primary.vmaddr:x} "
        f"({primary.segname},{primary.sectname})"
    )
    print(
        f"  marker ADRP+ADD xrefs   = {len(marker_xrefs)} "
        f"({', '.join(f'0x{x:x}' for x in marker_xrefs)})"
    )
    if reporter_entry is not None:
        print(f"  reporter entry          = 0x{reporter_entry:x}")
    else:
        print("  reporter entry          = NOT FOUND (walk-back failed)")
    if reporter_entry_via_xref is not None:
        print(f"  reporter entry via xref = 0x{reporter_entry_via_xref:x}")
    print(
        f"  QtsFileSystem family    = {len(family_hits)} strings "
        f"({len(family_hits_trimmed)} in report)"
    )
    return 0 if report["status"] == "primed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
