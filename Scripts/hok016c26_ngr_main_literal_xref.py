#!/usr/bin/env python3
"""HOK-016-C.2.6: 离线定位 NGR 二进制里 PascalString "main" 字面量及其
``adrp+add`` xref，用来猜 "谁应该把 main chunk 注册进 rootB"。

背景
----
HOK-016-C.2.4 / C.2.5 把 ``QtsFileSystem Create Failed!!`` 的真因锁定
到 ``0x10017f184`` 内 ``bl 0x1001cd114(rootB=0x10e184b18, "main"
PascalString, 1)`` 返回 0——rootB 运行期虽然被 reporter 内部 insert
过 2 个 entry，但 key 不是 "main"。iOS 下预期由更早期的 iOS-specific
初始化代码把 "main" 注册进去；macOS 下这段路径缺失。

C.2.5 的 xref 扫描器只负责找 ``rootB`` 这个**容器地址**的使用点；
本脚本反过来——找 lookup key 这个**字符串字面量**的使用点：

1. 在 NGR 二进制所有非 ``__text`` 段里扫 PascalString ``"main"``
   的字节 signature（HOK-016-C.2.4 v5 实测 entry+0x10 格式）：

       04 00 00 00 00 00 00 00  6d 61 69 6e 00 00 00 00
       length = 4 (u64 LE)       'm' 'a' 'i' 'n'  padding

   容器模板由 ``[length:u64][data:padded to 16]`` 组成（见 C.2.4
   hex48）；literal 在磁盘上通常以完整 16-byte 形式落地。扫描时
   接受两种 signature：

   - strict：``04 00 00 00 00 00 00 00 6d 61 69 6e 00 00 00 00``
     （16-byte PascalString literal）
   - relaxed：``04 00 00 00 00 00 00 00 6d 61 69 6e 00``
     （允许 padding 变形）

2. 对每个命中地址 ``L``，在 ``__text`` 里用和 C.2.5 相同的 adrp+add
   abstract-state 跟踪方式枚举 "把 L 或 L 附近（entry+0x10 语义
   往往 materialize 的是 entry 地址本身 = L-0x10）materialize 到
   寄存器" 的 xref。

3. 每个 xref 回溯到最近的 prologue anchor，得到所属函数入口 ``E``。

4. 对每个函数入口 ``E``，检查它是否在 ``__TEXT,__init_offsets`` 里
   直接出现（dyld static initializer），并记录该信息，供人工判定是
   否是 "iOS-specific 预注册 main" 的 registrar。

5. 额外产出一个 "浅 1 层 call graph" 关联：对每个 xref 所在函数入口
   ``E``，扫 ``__text`` 里所有 ``BL E`` 指令（32-bit 编码直接解），
   给出 caller 列表；用于在 E 不直接是 initializer 时快速看它被谁调
   过（比如 MessagingInit / QtsFileSystem_Init / reporter 等）。

输出 ``build/hok-016c26-main-literal.json``：

{
  "literalHits": [  { "vmaddr": "0x...", "signatureKind": "strict", "segname": "...", "sectname": "...", "context": "<hex of surrounding 64 bytes>" }, ... ],
  "xrefs": [
    {
      "literalAddr": "0x...",
      "adrpPc": "0x...", "addPc": "0x...", "dstReg": "x?",
      "functionEntry": "0x...",
      "isInitOffsetsEntry": false,
      "nearbyInsns": [ ... ],
      "callers": [ { "pc": "0x...", "functionEntry": "0x...", "isInitOffsetsEntry": bool }, ... ]
    }, ...
  ],
  "summary": { "literalCount": N, "xrefCount": M, "uniqueFunctions": K,
               "initializerFunctions": [...] }
}

脚本**零副作用**：只读 binary、调用 ``xcrun otool -l``，不修改任何
文件（除 ``--output``）。
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok015_ngr_cmdline_locator import (  # noqa: E402
    MachOImage,
    MachOSection,
    decode_add_imm,
    decode_adrp,
    parse_macho_layout,
)
from hok011_ngr_common_init_chain import (  # noqa: E402
    parse_init_offsets_section,
    read_init_offsets,
    resolve_initializer_entry_vmaddrs,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_BINARY_PATH = Path(
    os.path.expanduser(
        "~/Library/Containers/io.playcover.PlayCover/Applications/"
        "com.tencent.ngr.app/NGR"
    )
)
DEFAULT_OUTPUT = Path("build/hok-016c26-main-literal.json")

# 4-byte length prefix (u64 LE) + "main" + padding to 16 bytes.
SIG_STRICT = bytes.fromhex("04000000000000006d61696e00000000")
# Relaxed: first 13 bytes only (length + "main\0"); no tail padding constraint.
SIG_RELAXED_HEAD = bytes.fromhex("04000000000000006d61696e00")
# u32 length + "main" + NUL padding (some allocators use 32-bit length).
SIG_U32LEN = bytes.fromhex("040000006d61696e00")
# Plain C-string "main\0". False positives are expected (e.g. word-ending
# substrings like "*_main\0") — we filter during reporting by checking the
# preceding byte is also NUL (i.e. "main" is a standalone C-string, not
# the tail of a larger string).
SIG_CSTRING = b"main\x00"


# ---------------------------------------------------------------------------
# ARM64 instruction helpers (subset used by this script).
# ---------------------------------------------------------------------------

def _is_prologue_instruction(inst: int) -> bool:
    # ``sub sp, sp, #imm``
    if (inst & 0xFF800000) == 0xD1000000 and ((inst >> 5) & 0x1F) == 31 and (inst & 0x1F) == 31:
        return True
    # ``stp x29, x30, [sp, #imm]!`` pre-index: 0xA98003FD base; mask out imm7
    if (inst & 0xFFC0FFFF) == 0xA98003FD:
        return True
    # paciasp / pacibsp / bti c / bti jc (less reliable on their own).
    if inst in (0xD503233F, 0xD503237F, 0xD503245F, 0xD50324DF):
        return True
    return False


def _walk_back_to_prologue(
    text_bytes: bytes, hit_off: int, text_vmaddr: int, max_lookback: int = 8192
) -> int | None:
    limit_off = max(0, hit_off - max_lookback)
    off = hit_off - 4
    while off >= limit_off:
        inst = struct.unpack_from("<I", text_bytes, off)[0]
        if _is_prologue_instruction(inst):
            return text_vmaddr + off
        off -= 4
    return None


def _decode_bl(inst: int, pc: int) -> int | None:
    """Return absolute BL target for a BL instruction, else None.

    BL encoding: 1 00101 imm26 -> 0x94000000 mask 0xFC000000.
    """
    if (inst & 0xFC000000) != 0x94000000:
        return None
    imm26 = inst & 0x03FFFFFF
    if imm26 & (1 << 25):
        imm26 -= (1 << 26)
    return pc + (imm26 << 2)


def _insn_tag(inst: int) -> str:
    if (inst & 0x9F000000) == 0x90000000:
        return "adrp"
    if (inst & 0xFF800000) == 0x91000000:
        return "add (imm)"
    if (inst & 0xFC000000) == 0x94000000:
        return "bl"
    if (inst & 0xFC000000) == 0x14000000:
        return "b"
    if (inst & 0xFFE0FC1F) == 0xD63F0000:
        return "blr"
    if (inst & 0xBFC00000) == 0xB9000000:
        return "str (32-bit imm)"
    if (inst & 0xBFC00000) == 0xB9400000:
        return "ldr (32-bit imm)"
    if (inst & 0xFFC00000) == 0xF9000000:
        return "str (64-bit imm)"
    if (inst & 0xFFC00000) == 0xF9400000:
        return "ldr (64-bit imm)"
    if (inst & 0xFFC00000) == 0x39000000:
        return "strb"
    if (inst & 0xFFC00000) == 0x79000000:
        return "strh"
    if inst == 0xD65F03C0:
        return "ret"
    if _is_prologue_instruction(inst):
        if (inst & 0xFFC0FFFF) == 0xA98003FD:
            return "stp x29,x30,[sp,#imm]!"
        if (inst & 0xFF800000) == 0xD1000000:
            return "sub sp,sp,#imm"
        return "prologue"
    return f"other 0x{inst:08x}"


# ---------------------------------------------------------------------------
# Scan helpers.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class LiteralHit:
    vmaddr: int
    segname: str
    sectname: str
    signature_kind: str  # "strict" | "relaxed"
    context_hex: str


def scan_literal_in_section(
    data: bytes, section: MachOSection
) -> list[LiteralHit]:
    """Find all occurrences of the PascalString "main" literal plus
    standalone C-string "main\\0" in the section, scanning its on-disk
    bytes.

    The C-string mode explicitly requires the preceding byte to also be
    NUL (or the match to be at section start); without that filter we
    pick up every ``*_main\\0`` substring in ``__cstring`` /
    ``__objc_methname``, which is noise.
    """
    if section.size == 0 or section.fileoff == 0:
        return []
    start = section.fileoff
    end = start + section.size
    if end > len(data):
        return []
    section_bytes = data[start:end]

    hits: list[LiteralHit] = []

    def _add_hit(idx: int, kind: str) -> None:
        vmaddr = section.vmaddr + idx
        ctx_start = max(0, idx - 16)
        ctx_end = min(len(section_bytes), idx + 48)
        hits.append(
            LiteralHit(
                vmaddr=vmaddr,
                segname=section.segname,
                sectname=section.sectname,
                signature_kind=kind,
                context_hex=section_bytes[ctx_start:ctx_end].hex(),
            )
        )

    # Strict PascalString signature: 16-byte full cell.
    pos = 0
    while True:
        idx = section_bytes.find(SIG_STRICT, pos)
        if idx < 0:
            break
        _add_hit(idx, "pascal_strict")
        pos = idx + 1

    strict_offsets = {h.vmaddr - section.vmaddr for h in hits}

    # Relaxed PascalString signature (head only).
    pos = 0
    while True:
        idx = section_bytes.find(SIG_RELAXED_HEAD, pos)
        if idx < 0:
            break
        if idx not in strict_offsets:
            _add_hit(idx, "pascal_relaxed")
        pos = idx + 1

    # u32-length PascalString.
    pos = 0
    while True:
        idx = section_bytes.find(SIG_U32LEN, pos)
        if idx < 0:
            break
        _add_hit(idx, "pascal_u32len")
        pos = idx + 1

    # Standalone C-string "main\0" — precedes-with-NUL filter excludes
    # word-tails like "aac_main\0".
    pos = 0
    while True:
        idx = section_bytes.find(SIG_CSTRING, pos)
        if idx < 0:
            break
        is_standalone = idx == 0 or section_bytes[idx - 1] == 0
        if is_standalone:
            _add_hit(idx, "cstring")
        pos = idx + 1

    return hits


def scan_adrp_add_pairs(
    text_bytes: bytes,
    text_vmaddr: int,
    target_addrs: set[int],
    window_insns: int = 16,
) -> list[dict[str, Any]]:
    """Enumerate ``adrp+add`` pairs whose combined value lies in
    ``target_addrs``.

    We also check "adrp alone → effective = page" matches. For PascalString
    literals the typical materialization is **adrp + add**; but the literal
    might be at page base (add imm = 0) and compiler could fold the add.
    """
    hits: list[dict[str, Any]] = []
    adrp_page: list[int | None] = [None] * 32
    adrp_pc: list[int | None] = [None] * 32

    size = len(text_bytes)
    off = 0
    while off + 4 <= size:
        inst = struct.unpack_from("<I", text_bytes, off)[0]
        pc = text_vmaddr + off

        adrp_res = decode_adrp(inst, pc)
        if adrp_res is not None:
            dst, page = adrp_res
            adrp_page[dst] = page
            adrp_pc[dst] = pc
            # Note: adrp by itself could materialize a target that happens
            # to be page-aligned. We only recognize hits when an ADD
            # finalizes the offset, since PascalString literals we're
            # hunting for carry a non-zero page offset in practice (and
            # any page-aligned site would be tagged by the add-imm=0 case
            # too, since the compiler always emits add for full global
            # addresses).
            off += 4
            continue

        add_res = decode_add_imm(inst)
        if add_res is not None:
            dst, src, imm = add_res
            if adrp_page[src] is not None:
                combined = (adrp_page[src] + imm) & ((1 << 64) - 1)
                if combined in target_addrs:
                    near_start = max(0, off - window_insns * 4 // 2)
                    near_end = min(size, off + window_insns * 4 // 2 + 4)
                    window: list[dict[str, Any]] = []
                    cur = near_start
                    while cur < near_end:
                        w_inst = struct.unpack_from("<I", text_bytes, cur)[0]
                        window.append({
                            "pc": f"0x{text_vmaddr + cur:x}",
                            "encoding": f"0x{w_inst:08x}",
                            "tag": _insn_tag(w_inst),
                            "isHit": cur == off,
                        })
                        cur += 4
                    hits.append({
                        "literalAddr": f"0x{combined:x}",
                        "adrpPc": f"0x{adrp_pc[src]:x}",
                        "addPc": f"0x{pc:x}",
                        "dstReg": f"x{dst}",
                        "srcReg": f"x{src}",
                        "adrpPage": f"0x{adrp_page[src]:x}",
                        "addImm": f"0x{imm:x}",
                        "nearbyInsns": window,
                    })
            # After the add materializes a full address, invalidate the
            # adrp-page record on the dst register. If dst != src we still
            # keep src valid in case the compiler re-uses it.
            adrp_page[dst] = None
            adrp_pc[dst] = None
            off += 4
            continue

        # A plain MOV (wide imm / register) to Xn clobbers the remembered
        # page. We keep this conservative — a false negative (missed
        # clobber) is much cheaper than a false positive for our purpose.
        # MOVZ/MOVK/MOVN (32/64-bit): 1x100101xx immediate
        if (inst & 0x7F800000) in (0x12800000, 0x52800000, 0x72800000):
            dst = inst & 0x1F
            adrp_page[dst] = None
            adrp_pc[dst] = None
        # LDR (imm, 64-bit unsigned offset) writes Xt.
        elif (inst & 0xFFC00000) == 0xF9400000:
            dst = inst & 0x1F
            adrp_page[dst] = None
            adrp_pc[dst] = None
        off += 4
    return hits


def scan_bl_callers(
    text_bytes: bytes, text_vmaddr: int, targets: set[int]
) -> dict[int, list[int]]:
    """Find every ``bl <target>`` in the __text section; return a map
    from target vmaddr to list of BL-instruction pcs.
    """
    result: dict[int, list[int]] = {t: [] for t in targets}
    size = len(text_bytes)
    off = 0
    while off + 4 <= size:
        inst = struct.unpack_from("<I", text_bytes, off)[0]
        pc = text_vmaddr + off
        tgt = _decode_bl(inst, pc)
        if tgt is not None and tgt in result:
            result[tgt].append(pc)
        off += 4
    return result


def _safe_int(value: str) -> int:
    return int(value, 0)


# ---------------------------------------------------------------------------
# Main driver.
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.6: find PascalString 'main' literals in NGR "
            "binary and enumerate their adrp+add xrefs + shallow callers "
            "to locate the iOS-specific 'main' chunk registrar."
        )
    )
    p.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    p.add_argument(
        "--binary-path",
        default=str(DEFAULT_BINARY_PATH),
        help="path to NGR main binary",
    )
    p.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="output JSON path (default build/hok-016c26-main-literal.json)",
    )
    p.add_argument(
        "--max-xref-window-insns",
        type=int,
        default=16,
        help="size of the nearbyInsns window around each xref hit",
    )
    p.add_argument(
        "--max-callers-per-fn",
        type=int,
        default=32,
        help="cap the number of caller sites reported per function entry",
    )
    return p


def main() -> int:
    args = _build_parser().parse_args()
    binary_path = Path(args.binary_path).expanduser().resolve()
    if not binary_path.is_file():
        print(f"fatal: binary not found: {binary_path}", file=sys.stderr)
        return 1
    output_path = Path(args.output).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    image = parse_macho_layout(binary_path)
    data = binary_path.read_bytes()

    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("No __TEXT,__text section in NGR binary")
    text_bytes = data[text.fileoff:text.fileoff + text.size]

    # --- 1. literal scan across all non-__text file-backed sections ------
    literal_hits: list[LiteralHit] = []
    for section in image.sections:
        if section.segname == "__TEXT" and section.sectname == "__text":
            continue
        # Skip segment-level link/dyld sections (they're not data).
        if section.segname in ("__LINKEDIT", "__PAGEZERO"):
            continue
        literal_hits.extend(scan_literal_in_section(data, section))

    print(
        f"literal scan: {len(literal_hits)} PascalString 'main' hit(s) across "
        f"{sum(1 for _ in image.sections)} sections",
        file=sys.stderr,
    )

    literal_vmaddrs: set[int] = {h.vmaddr for h in literal_hits}

    # --- 2. adrp+add xref scan in __text for each literal ---------------
    xref_hits = scan_adrp_add_pairs(
        text_bytes,
        text.vmaddr,
        literal_vmaddrs,
        window_insns=args.max_xref_window_insns,
    )
    print(
        f"xref scan: {len(xref_hits)} adrp+add site(s) reference 'main' literal(s)",
        file=sys.stderr,
    )

    # --- 3. resolve each xref's enclosing function entry ----------------
    for hit in xref_hits:
        add_pc = _safe_int(hit["addPc"])
        hit_off = add_pc - text.vmaddr
        entry = _walk_back_to_prologue(text_bytes, hit_off, text.vmaddr)
        hit["functionEntry"] = f"0x{entry:x}" if entry is not None else None

    # --- 4. resolve __init_offsets initializer set -----------------------
    import subprocess
    proc = subprocess.run(
        ["xcrun", "otool", "-l", str(binary_path)],
        check=True, capture_output=True, text=True,
    )
    otool_out = proc.stdout
    init_section = parse_init_offsets_section(otool_out)
    initializer_entries: set[int] = set()
    if init_section is not None:
        offsets = read_init_offsets(binary_path, init_section)
        vmaddrs = resolve_initializer_entry_vmaddrs(offsets, image.text_vmaddr)
        initializer_entries = set(vmaddrs)
    print(
        f"__init_offsets: {len(initializer_entries)} initializer entries",
        file=sys.stderr,
    )

    for hit in xref_hits:
        fe = hit.get("functionEntry")
        hit["isInitOffsetsEntry"] = bool(
            fe is not None and _safe_int(fe) in initializer_entries
        )

    # --- 5. shallow 1-hop caller scan for each unique enclosing fn ------
    unique_functions: set[int] = {
        _safe_int(h["functionEntry"])
        for h in xref_hits
        if h.get("functionEntry") is not None
    }
    caller_map = scan_bl_callers(text_bytes, text.vmaddr, unique_functions)

    # Resolve each caller-PC to its enclosing function entry too, so the
    # output immediately tells us if the caller is itself an initializer.
    # We cap per-function caller list length to avoid multi-hundred
    # entries for very popular helpers.
    cap = max(1, args.max_callers_per_fn)
    caller_details: dict[int, list[dict[str, Any]]] = {}
    for fn_entry, caller_pcs in caller_map.items():
        details: list[dict[str, Any]] = []
        for pc in caller_pcs[:cap]:
            pc_off = pc - text.vmaddr
            caller_entry = _walk_back_to_prologue(text_bytes, pc_off, text.vmaddr)
            details.append({
                "pc": f"0x{pc:x}",
                "functionEntry": f"0x{caller_entry:x}" if caller_entry else None,
                "isInitOffsetsEntry": bool(
                    caller_entry is not None and caller_entry in initializer_entries
                ),
            })
        caller_details[fn_entry] = details

    for hit in xref_hits:
        fe = hit.get("functionEntry")
        if fe is None:
            hit["callers"] = []
            hit["callerCount"] = 0
            continue
        fe_int = _safe_int(fe)
        full_list = caller_map.get(fe_int, [])
        hit["callerCount"] = len(full_list)
        hit["callers"] = caller_details.get(fe_int, [])

    # --- 6. build summary & write report --------------------------------
    initializer_function_set: set[str] = set()
    for h in xref_hits:
        if h.get("isInitOffsetsEntry"):
            fe = h.get("functionEntry")
            if fe is not None:
                initializer_function_set.add(fe)

    # For the convenience of the next step, also surface which enclosing
    # functions have at least one caller that is itself an __init_offsets
    # initializer (i.e. reachable from dyld static init in one hop).
    indirect_initializer_function_set: set[str] = set()
    for h in xref_hits:
        fe = h.get("functionEntry")
        if fe is None:
            continue
        if any(c.get("isInitOffsetsEntry") for c in h.get("callers", [])):
            indirect_initializer_function_set.add(fe)

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "workflow": "hok-016c26-main-literal-xref",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "bundleId": args.bundle_id,
        "binaryPath": str(binary_path),
        "image": {
            "textVmaddr": f"0x{text.vmaddr:x}",
            "textFileoff": f"0x{text.fileoff:x}",
            "textSize": f"0x{text.size:x}",
            "initOffsetsCount": len(initializer_entries),
        },
        "literalHits": [
            {
                "vmaddr": f"0x{h.vmaddr:x}",
                "segname": h.segname,
                "sectname": h.sectname,
                "signatureKind": h.signature_kind,
                "contextHex": h.context_hex,
            }
            for h in literal_hits
        ],
        "xrefs": xref_hits,
        "summary": {
            "literalCount": len(literal_hits),
            "xrefCount": len(xref_hits),
            "uniqueFunctionEntries": len(unique_functions),
            "initializerFunctionEntries": sorted(initializer_function_set),
            "oneHopInitializerFunctionEntries": sorted(
                indirect_initializer_function_set
            ),
        },
    }

    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"wrote {output_path}: {len(literal_hits)} literals / "
        f"{len(xref_hits)} xrefs / {len(unique_functions)} enclosing fns",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
