#!/usr/bin/env python3
"""HOK-016-C.2.2: 全 ``__text`` 扫描 NGR 主二进制里所有写入 sentinel
``0x10e1eeef0`` 的指令。

动机
----
HOK-016-C.2.1 用 HOK-011 的 ``__init_offsets`` 扫描器对目标地址
``0x10e1eeef0`` 执行后：**0 hit**。这说明（与 ``0x10e2146f8`` 相同）sentinel
writer 不在 dyld 的 initializer 可达链上；必须把扫描面放大到整个 ``__text``
段。除此之外，sentinel 是 byte（``cmp w8, #0x4`` / ``cmp w8, #0x2``），
writer 很可能写半 byte 值而不是 64-bit store：

    adrp  x?, <page(0x10e1eeef0)>
    add   x?, x?, #<off(0x10e1eeef0) & 0xfff>   ; 或直接 str #imm12
    strb  wN, [x?]
    ; 或  strh wN, [x?]
    ; 或  str  wN, [x?]    (32-bit)

HOK-011 的扫描器只解析 ``str``（64-bit / 32-bit general-register store），
**未覆盖 ``strb`` / ``strh``**，这也可能让 writer 漏网。HOK-016-C.2.2 扫描
器按"以 raw-bytes 解析 ARM64 32-bit 定长指令"的套路重写：

1. 读入 NGR 主二进制；从 ``otool -l`` 结构化获取 ``__text`` / ``__common``。
2. 以 4 字节步长在 ``__text`` 段内顺序 decode。对每条 adrp / add / str /
   strb / strh / strw / strx 指令跟踪 per-register 的 abstract-state
   （adrp page + add offset）。
3. 命中条件：``[base_reg + imm] == target_address`` 且该 adrp/add/str
   三指令对应的 dataflow 可达（same basic block，不被中间 mov 清空）。
4. 命中一次就回溯到最近的 prologue anchor（``stp x29,x30,[sp,#imm]!`` /
   ``sub sp,sp,#imm`` / ``pacibsp`` / ``paciasp``），打印所属函数入口，
   并 dump 命中点前后若干条指令方便跟 HOK-016-B reporter 调用链做交叉。
5. 输出 ``build/hok-016c2-sentinel-writer.json``。

脚本**零副作用**：只读 binary、调用 ``otool -l``。不调用 ``codesign``、不
launch app、不修改 binary 或任何 PlayTools 代码。

用法::

    python3 Scripts/hok016c2_ngr_sentinel_writer_scan.py \
        [--binary-path /path/to/NGR] \
        [--target-address 0x10e1eeef0] \
        [--output build/hok-016c2-sentinel-writer.json]

默认 ``--binary-path`` 自动解析到
``~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR``。
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
from hok016_ngr_qts_locator import (  # noqa: E402
    _is_prologue_instruction,
    find_function_entry,
)


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_BINARY_PATH = Path(
    os.path.expanduser(
        "~/Library/Containers/io.playcover.PlayCover/Applications/"
        "com.tencent.ngr.app/NGR"
    )
)
DEFAULT_OUTPUT = Path("build/hok-016c2-sentinel-writer-full-text.json")
DEFAULT_TARGET_ADDRESS = 0x10E1EEEF0


# ---------------------------------------------------------------------------
# Store instruction decoders (immediate, unsigned offset form).
# ---------------------------------------------------------------------------
#
# We match only the plain "unsigned offset" form (LDST_POS / LDR_POS) — the
# form typically emitted for global-variable writes — i.e. no pre-/post-index
# and no extended/register offset. That keeps the decoder tight and matches
# the forms we observed for the family store sites in HOK-011 and HOK-016.

def decode_strb_imm(inst: int) -> tuple[int, int, int] | None:
    """STRB (immediate, unsigned offset): size=00, V=0, opc=00.

    Encoding: 00111001 00 imm12 Rn Rt -> 0x39000000 mask 0xFFC00000.
    imm12 scale = 1 byte.
    """
    if (inst & 0xFFC00000) != 0x39000000:
        return None
    imm12 = (inst >> 10) & 0xFFF
    Rn = (inst >> 5) & 0x1F
    Rt = inst & 0x1F
    return Rt, Rn, imm12  # 1-byte scale


def decode_strh_imm(inst: int) -> tuple[int, int, int] | None:
    """STRH (immediate, unsigned offset): size=01, V=0, opc=00.

    Encoding: 01111001 00 imm12 Rn Rt -> 0x79000000 mask 0xFFC00000.
    imm12 scale = 2 bytes.
    """
    if (inst & 0xFFC00000) != 0x79000000:
        return None
    imm12 = (inst >> 10) & 0xFFF
    Rn = (inst >> 5) & 0x1F
    Rt = inst & 0x1F
    return Rt, Rn, imm12 * 2


def decode_str_imm_w(inst: int) -> tuple[int, int, int] | None:
    """STR (immediate, unsigned offset, 32-bit): size=10, V=0, opc=00.

    Encoding: 10111001 00 imm12 Rn Rt -> 0xB9000000 mask 0xFFC00000.
    imm12 scale = 4 bytes.
    """
    if (inst & 0xFFC00000) != 0xB9000000:
        return None
    imm12 = (inst >> 10) & 0xFFF
    Rn = (inst >> 5) & 0x1F
    Rt = inst & 0x1F
    return Rt, Rn, imm12 * 4


def decode_str_imm_x(inst: int) -> tuple[int, int, int] | None:
    """STR (immediate, unsigned offset, 64-bit): size=11, V=0, opc=00.

    Encoding: 11111001 00 imm12 Rn Rt -> 0xF9000000 mask 0xFFC00000.
    imm12 scale = 8 bytes.
    """
    if (inst & 0xFFC00000) != 0xF9000000:
        return None
    imm12 = (inst >> 10) & 0xFFF
    Rn = (inst >> 5) & 0x1F
    Rt = inst & 0x1F
    return Rt, Rn, imm12 * 8


def decode_mov_reg(inst: int) -> tuple[int, int] | None:
    """MOV (register, 64-bit): alias of ORR Xd, XZR, Xm.

    ORR (shifted register) encoding: sf=1, opc=01, shift=00, N=0, Rm, imm6=0, Rn=31, Rd
    Mask out Rm (bits 16..20) for detection.
    """
    if (inst & 0xFFE0FFE0) != 0xAA0003E0:
        return None
    Rm = (inst >> 16) & 0x1F
    Rd = inst & 0x1F
    return Rd, Rm


STORE_DECODERS = (
    ("strb", decode_strb_imm, 1),
    ("strh", decode_strh_imm, 2),
    ("str.w", decode_str_imm_w, 4),
    ("str.x", decode_str_imm_x, 8),
)


# ---------------------------------------------------------------------------
# Scan.
# ---------------------------------------------------------------------------

@dataclass
class WriterHit:
    inst_pc: int
    mnemonic: str
    src_reg: int
    base_reg: int
    imm: int
    base_value: int
    base_source: str  # "adrp" | "adrp+add" | "propagated"
    target_address: int
    store_width: int


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def scan_text_for_writes_to(
    data: bytes,
    image: MachOImage,
    target_address: int,
) -> list[WriterHit]:
    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("No __TEXT,__text section; binary may not be a regular Mach-O executable")

    # Abstract per-register state:
    #  page_base[R] = last adrp page (if set; register not clobbered since)
    #  add_eff[R]   = effective address if R was computed by `adrp+add` or
    #                 propagated via `mov`/`add x?, xSrc, #0`.
    page_base: dict[int, int] = {}
    add_eff: dict[int, int] = {}
    adrp_pc: dict[int, int] = {}       # track the adrp pc that contributed
    add_pc: dict[int, int] = {}        # track the add pc that contributed

    hits: list[WriterHit] = []
    text_end = text.fileoff + text.size

    # iterate 4-byte instructions in __text
    for file_off in range(text.fileoff, text_end, 4):
        inst = struct.unpack_from("<I", data, file_off)[0]
        pc = text.vmaddr + (file_off - text.fileoff)

        # --- ADRP ---
        adrp = decode_adrp(inst, pc)
        if adrp is not None:
            Rd, page = adrp
            page_base[Rd] = page
            add_eff.pop(Rd, None)
            adrp_pc[Rd] = pc
            continue

        # --- ADD (imm) ---
        addimm = decode_add_imm(inst)
        if addimm is not None:
            Rd, Rn, imm = addimm
            if Rn in page_base:
                add_eff[Rd] = page_base[Rn] + imm
                add_pc[Rd] = pc
                # If Rd != Rn, the adrp's register is still valid.
                if Rd != Rn:
                    pass
            elif Rn in add_eff:
                add_eff[Rd] = add_eff[Rn] + imm
                add_pc[Rd] = pc
            else:
                add_eff.pop(Rd, None)
                add_pc.pop(Rd, None)
            # Any subsequent plain adrp record on Rd is gone as soon as it
            # becomes an add target.
            if Rd != Rn:
                page_base.pop(Rd, None)
                adrp_pc.pop(Rd, None)
            continue

        # --- MOV (reg) — propagate abstract state ---
        mov = decode_mov_reg(inst)
        if mov is not None:
            Rd, Rm = mov
            if Rd == Rm:
                continue
            page_base.pop(Rd, None)
            add_eff.pop(Rd, None)
            adrp_pc.pop(Rd, None)
            add_pc.pop(Rd, None)
            if Rm in add_eff:
                add_eff[Rd] = add_eff[Rm]
                add_pc[Rd] = add_pc.get(Rm, pc)
            if Rm in page_base:
                page_base[Rd] = page_base[Rm]
                adrp_pc[Rd] = adrp_pc.get(Rm, pc)
            continue

        # --- Stores we care about ---
        for mnemonic, decoder, width in STORE_DECODERS:
            parsed = decoder(inst)
            if parsed is None:
                continue
            Rt, Rn, imm = parsed
            base_value: int | None = None
            base_source: str | None = None
            if Rn in add_eff:
                base_value = add_eff[Rn]
                base_source = "adrp+add"
            elif Rn in page_base:
                base_value = page_base[Rn]
                base_source = "adrp"
            if base_value is None:
                break  # can't resolve base; this store isn't the one we want.
            effective = base_value + imm
            if effective == target_address:
                hits.append(
                    WriterHit(
                        inst_pc=pc,
                        mnemonic=mnemonic,
                        src_reg=Rt,
                        base_reg=Rn,
                        imm=imm,
                        base_value=base_value,
                        base_source=base_source,
                        target_address=effective,
                        store_width=width,
                    )
                )
            break  # don't try other decoders after a successful store decode.

        # Note: we intentionally do NOT clobber abstract state on other insns.
        # The scanner is a fast global sweep; for each hit we do a dedicated
        # walk-back to attribute to a function. False positives cost us only
        # a one-off prologue walk-back; the underlying Mach-O __text has
        # ~tens of MB, and missing a writer is strictly worse than emitting
        # an extra non-writer hit.

    return hits


def dump_nearby_insns(
    data: bytes, image: MachOImage, center_pc: int, before: int = 6, after: int = 4
) -> list[dict[str, Any]]:
    text = image.section("__TEXT", "__text")
    if text is None:
        return []
    # Decode a small disasm window around the hit using raw bytes; we only
    # emit a hex encoding + tag of the primary opcode class so the JSON is
    # self-contained (no objdump dependency at this phase).
    out: list[dict[str, Any]] = []
    start_pc = (center_pc - before * 4) & ~0x3
    total = before + 1 + after
    for k in range(total):
        pc = start_pc + k * 4
        if pc < text.vmaddr or pc >= text.vmaddr + text.size:
            continue
        file_off = text.fileoff + (pc - text.vmaddr)
        inst = struct.unpack_from("<I", data, file_off)[0]
        tag = classify_inst(inst, pc)
        out.append({
            "pc": f"0x{pc:x}",
            "encoding": f"0x{inst:08x}",
            "tag": tag,
            "isHit": pc == center_pc,
        })
    return out


def classify_inst(inst: int, pc: int) -> str:
    if _is_prologue_instruction(inst):
        if (inst & 0xFFC00000) == 0xA9800000:
            return "stp x29,x30,[sp,#imm]!"
        if (inst & 0xFF800000) == 0xD1000000:
            return "sub sp,sp,#imm"
        if inst == 0xD503237F:
            return "pacibsp"
        if inst == 0xD503233F:
            return "paciasp"
    if decode_adrp(inst, pc) is not None:
        return "adrp"
    if decode_add_imm(inst) is not None:
        return "add (imm)"
    for mnemonic, decoder, _w in STORE_DECODERS:
        if decoder(inst) is not None:
            return mnemonic
    if (inst & 0xFFC00000) == 0x39400000:
        return "ldrb"
    if (inst & 0xFFC00000) == 0x79400000:
        return "ldrh"
    if (inst & 0xFFC00000) == 0xB9400000:
        return "ldr (32-bit)"
    if (inst & 0xFFC00000) == 0xF9400000:
        return "ldr (64-bit)"
    if inst == 0xD65F03C0:
        return "ret"
    if (inst & 0xFC000000) == 0x94000000:
        return "bl"
    if (inst & 0xFC000000) == 0x14000000:
        return "b"
    return f"other 0x{inst:08x}"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Scan full __TEXT of NGR binary for stores targeting a given __common byte sentinel",
    )
    p.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="target bundle identifier")
    p.add_argument(
        "--binary-path",
        default=str(DEFAULT_BINARY_PATH),
        help="explicit NGR binary path",
    )
    p.add_argument(
        "--target-address",
        default=hex(DEFAULT_TARGET_ADDRESS),
        help="absolute VM address of the sentinel slot to find writers for (default 0x10e1eeef0)",
    )
    p.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="structured JSON report output path",
    )
    return p


def main() -> int:
    args = build_parser().parse_args()
    binary_path = Path(args.binary_path).expanduser().resolve()
    if not binary_path.is_file():
        raise SystemExit(f"Binary not found: {binary_path}")
    target_address = int(args.target_address, 0)
    output_path = Path(args.output).expanduser().resolve()

    image = parse_macho_layout(binary_path)
    data = binary_path.read_bytes()
    text = image.section("__TEXT", "__text")
    if text is None:
        raise SystemExit("No __TEXT,__text section")
    common = image.section("__DATA", "__common")

    print(
        f"scan __text: vmaddr=0x{text.vmaddr:x} size=0x{text.size:x} (~{text.size // (1024 * 1024)}MB)",
        file=sys.stderr,
    )
    hits = scan_text_for_writes_to(data, image, target_address)
    print(f"scan complete: {len(hits)} writer hits", file=sys.stderr)

    hit_payload: list[dict[str, Any]] = []
    for hit in hits:
        entry_vmaddr = find_function_entry(data, image, hit.inst_pc)
        hit_payload.append({
            "instructionAddress": f"0x{hit.inst_pc:x}",
            "mnemonic": hit.mnemonic,
            "storeWidth": hit.store_width,
            "srcReg": f"x{hit.src_reg}" if hit.mnemonic == "str.x" else f"w{hit.src_reg}",
            "baseReg": f"x{hit.base_reg}",
            "imm": f"0x{hit.imm:x}",
            "baseValue": f"0x{hit.base_value:x}",
            "baseSource": hit.base_source,
            "effectiveTarget": f"0x{hit.target_address:x}",
            "functionEntry": f"0x{entry_vmaddr:x}" if entry_vmaddr else None,
            "nearbyInsns": dump_nearby_insns(data, image, hit.inst_pc),
        })

    report = {
        "schemaVersion": 1,
        "workflow": "hok-016c2-sentinel-writer-scan",
        "generatedAt": _utc_now_iso(),
        "bundleId": args.bundle_id,
        "configuration": {
            "binaryPath": str(binary_path),
            "targetAddress": f"0x{target_address:x}",
            "outputPath": str(output_path),
        },
        "image": {
            "textVmaddr": f"0x{text.vmaddr:x}",
            "textFileoff": f"0x{text.fileoff:x}",
            "textSize": f"0x{text.size:x}",
            "commonVmaddr": f"0x{common.vmaddr:x}" if common else None,
            "commonSize": f"0x{common.size:x}" if common else None,
        },
        "target": {
            "address": f"0x{target_address:x}",
            "insideCommon": bool(
                common
                and common.vmaddr <= target_address < common.vmaddr + common.size
            ),
        },
        "hits": hit_payload,
        "checks": {
            "binaryResolved": True,
            "textSectionResolved": True,
            "anyHitFound": bool(hit_payload),
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if hit_payload else 1


if __name__ == "__main__":
    sys.exit(main())
