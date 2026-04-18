#!/usr/bin/env python3
"""HOK-016-C.2.5 rootB xref scan.

The C.2.2 writer scan only finds direct ``str <reg>, [rootB]`` style
writes. It missed the more common pattern in which rootB's address is
**passed as an argument** (usually x0) to a red-black-tree insert /
emplace helper; that helper then writes into rootB from inside its own
frame, where our constant-propagation abstract state has no idea the
pointer-in-hand is rootB.

This scanner takes a complementary angle: enumerate **every** ``adrp+add``
pair that materializes the literal address 0x10e184b18 (or any other
target passed via ``--target-address``) into a register. For each match
we:

* classify the destination register (hint: ``x0`` = first arg; ``x1`` =
  second arg; ``x8`` = indirect result pointer / this-ptr sloppy,
  commonly a helper's own "inferior address" in macOS ABI);
* walk back to the nearest function prologue so the enclosing function
  entry is known;
* grab a 32-insn disassembly window around the match so the caller can
  tell whether the site is a **store**, a **BL target setup**, a
  **pointer comparison**, or something else.

Output: ``build/hok-016c25-rootB-xrefs.json`` (default).

This is a **read-only, offline** analysis script — no LLDB, no running
target.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_BINARY_PATH = Path(
    os.path.expanduser(
        "~/Library/Containers/io.playcover.PlayCover/Applications/"
        "com.tencent.ngr.app/NGR"
    )
)
DEFAULT_TARGET_ADDRESS = 0x10E184B18
DEFAULT_OUTPUT = Path("build/hok-016c25-rootB-xrefs.json")


def _run_otool(binary_path: Path) -> str:
    return subprocess.check_output(
        ["/usr/bin/xcrun", "otool", "-arch", "arm64", "-l", str(binary_path)],
        text=True,
    )


def _parse_text_section(otool_output: str) -> tuple[int, int, int]:
    """Return (vmaddr, fileoff, size) of __TEXT,__text."""
    in_text = False
    vmaddr = fileoff = size = 0
    section = None
    got_addr = got_size = got_offset = False
    for line in otool_output.splitlines():
        stripped = line.strip()
        if stripped.startswith("sectname "):
            section = stripped[len("sectname "):].strip()
            in_text = False
            got_addr = got_size = got_offset = False
        elif stripped.startswith("segname "):
            segname = stripped[len("segname "):].strip()
            in_text = segname == "__TEXT" and section == "__text"
        elif in_text:
            if stripped.startswith("addr "):
                vmaddr = int(stripped.split()[1], 0)
                got_addr = True
            elif stripped.startswith("size "):
                size = int(stripped.split()[1], 0)
                got_size = True
            elif stripped.startswith("offset "):
                fileoff = int(stripped.split()[1])
                got_offset = True
            if got_addr and got_size and got_offset:
                break
    return vmaddr, fileoff, size


def _decode_adrp(insn: int, pc: int) -> tuple[int, int] | None:
    """Return (dst_reg, imm_page_addr) if insn is ADRP, else None."""
    if (insn & 0x9F000000) != 0x90000000:
        return None
    immlo = (insn >> 29) & 0x3
    immhi = (insn >> 5) & 0x7FFFF
    imm = ((immhi << 2) | immlo) << 12
    # Sign-extend 33-bit immediate.
    if imm & (1 << 32):
        imm |= ~((1 << 33) - 1)
    imm &= (1 << 64) - 1
    dst = insn & 0x1F
    target = (pc & ~0xFFF) + imm
    # Treat as unsigned 64-bit.
    target &= (1 << 64) - 1
    return dst, target


def _decode_add_imm(insn: int) -> tuple[int, int, int] | None:
    """Return (dst, src, imm12) if insn is ADD Xd, Xn, #imm12 (with
    optional LSL #12 shift)."""
    # ADD (immediate) 64-bit: sf=1, op=0, S=0, 0100010 shift(2) imm12(12) Rn(5) Rd(5)
    if (insn & 0xFFC00000) == 0x91000000:
        sh = (insn >> 22) & 0x3
        imm12 = (insn >> 10) & 0xFFF
        src = (insn >> 5) & 0x1F
        dst = insn & 0x1F
        if sh == 0:
            return dst, src, imm12
        if sh == 1:
            return dst, src, imm12 << 12
    return None


def _walk_back_to_prologue(text_bytes: bytes, hit_off: int,
                           text_vmaddr: int,
                           max_lookback: int = 4096) -> int | None:
    """Walk backwards from the hit offset looking for a typical ARM64
    prologue marker: ``sub sp, sp, #imm`` or ``stp x29, x30, [sp, …]!``
    or ``paciasp`` / ``pacibsp`` / ``stp xN, xM, [sp, …]!``.

    Return the function's unslid entry address, or None if nothing
    plausible turned up.
    """
    limit_off = max(0, hit_off - max_lookback)
    # Scan backwards 4 bytes at a time.
    off = hit_off - 4
    while off >= limit_off:
        insn = struct.unpack_from("<I", text_bytes, off)[0]
        # sub sp, sp, #imm (64-bit): 1101 0001 00xx xxxx xxxx xxxx xxx1 1111
        if (insn & 0xFF0003FF) == 0xD10003FF:
            return text_vmaddr + off
        # stp x29, x30, [sp, #imm]! pre-indexed: 1010 1001 10xx xxxx xxx1 1111 0111 1101
        if (insn & 0xFFC0FFFF) == 0xA98003FD:
            return text_vmaddr + off
        # paciasp / pacibsp / bti
        if insn in (0xD503233F, 0xD503237F, 0xD503245F, 0xD50324DF,
                    0xD503201F):
            pass  # these are too common inside functions; skip
        off -= 4
    return None


def _insn_tag(insn: int) -> str:
    # Very rough classification for the nearby-insn dump; just enough
    # so a human can skim the context and tell what's going on.
    if (insn & 0x9F000000) == 0x90000000:
        return "adrp"
    if (insn & 0xFFC00000) == 0x91000000:
        return "add"
    if (insn & 0xFC000000) == 0x94000000:
        return "bl"
    if (insn & 0xFC000000) == 0x14000000:
        return "b"
    if (insn & 0xFFE0FC1F) == 0xD63F0000:
        return "blr"
    if (insn & 0xBFC00000) == 0xB9000000:
        return "str (imm)"
    if (insn & 0xBFC00000) == 0xB9400000:
        return "ldr (imm)"
    if (insn & 0xFFC00000) == 0xF9000000:
        return "str.x"
    if (insn & 0xFFC00000) == 0xF9400000:
        return "ldr.x"
    return f"other 0x{insn:08x}"


def scan_adrp_add_pairs(
    text_bytes: bytes,
    text_vmaddr: int,
    target_addr: int,
    window_insns: int = 32,
) -> list[dict[str, Any]]:
    """Enumerate ``adrp Xn, <page>; add Xn, Xn, #<off>`` pairs whose
    combined value equals ``target_addr``. The add does NOT need to
    come immediately after the adrp; we allow up to 6 insns gap so
    long as the intermediate insns don't overwrite Xn.

    Returns a list of hits, each a dict ready to serialize.
    """
    hits: list[dict[str, Any]] = []
    # Map from reg idx -> most recent ADRP (page) seen; -1 = invalid.
    adrp_page: list[int | None] = [None] * 32
    adrp_pc: list[int | None] = [None] * 32

    size = len(text_bytes)
    off = 0
    while off + 4 <= size:
        insn = struct.unpack_from("<I", text_bytes, off)[0]
        pc = text_vmaddr + off

        adrp_res = _decode_adrp(insn, pc)
        if adrp_res is not None:
            dst, page = adrp_res
            adrp_page[dst] = page
            adrp_pc[dst] = pc
            off += 4
            continue

        add_res = _decode_add_imm(insn)
        if add_res is not None:
            dst, src, imm = add_res
            if adrp_page[src] is not None:
                combined = (adrp_page[src] + imm) & ((1 << 64) - 1)
                if combined == target_addr:
                    # Grab nearby window.
                    near_start = max(0, off - window_insns * 4 // 2)
                    near_end = min(size, off + window_insns * 4 // 2)
                    window: list[dict[str, Any]] = []
                    cur = near_start
                    while cur < near_end:
                        w_insn = struct.unpack_from("<I", text_bytes, cur)[0]
                        window.append({
                            "pc": f"0x{text_vmaddr + cur:x}",
                            "encoding": f"0x{w_insn:08x}",
                            "tag": _insn_tag(w_insn),
                            "isHit": cur == off,
                        })
                        cur += 4
                    # Walk back to prologue.
                    entry = _walk_back_to_prologue(
                        text_bytes, off, text_vmaddr, max_lookback=8192
                    )
                    hits.append({
                        "adrpPc": f"0x{adrp_pc[src]:x}",
                        "addPc": f"0x{pc:x}",
                        "dstReg": f"x{dst}",
                        "srcReg": f"x{src}",
                        "adrpPage": f"0x{adrp_page[src]:x}",
                        "addImm": f"0x{imm:x}",
                        "effectiveTarget": f"0x{combined:x}",
                        "functionEntry": f"0x{entry:x}" if entry else None,
                        "nearbyInsns": window,
                    })
            # If src == dst, after add the register is clobbered; but
            # in the adrp+add sequence we typically have dst==src so
            # the page is consumed. Either way, invalidate dst.
            adrp_page[dst] = None
            adrp_pc[dst] = None
            off += 4
            continue

        # Any other write to a register invalidates the remembered
        # page.  Rough heuristic: check common writers (mov imm, ldr,
        # add reg-reg, etc.) that target Xn.
        # The cleanest ARM64 way is to mask out the Rd field for
        # instructions we know write to a register.  For robustness we
        # just clear regs when we see common write patterns.
        # MOV (wide imm) / MOVZ / MOVK / MOVN:
        if (insn & 0x7F800000) in (0x12800000, 0x52800000, 0x72800000):
            dst = insn & 0x1F
            adrp_page[dst] = None
            adrp_pc[dst] = None
        # LDR (imm, 64-bit): 1111 1001 01xx xxxx xxxx xxxx xxxx xxxx
        elif (insn & 0xFFC00000) == 0xF9400000:
            dst = insn & 0x1F
            adrp_page[dst] = None
            adrp_pc[dst] = None

        off += 4
    return hits


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.5: enumerate all adrp+add pairs whose combined "
            "value equals the target rootB address. Complementary to "
            "the C.2.2 writer-scan (which only finds direct stores)."
        )
    )
    parser.add_argument(
        "--binary-path",
        default=str(DEFAULT_BINARY_PATH),
        help="path to NGR main binary",
    )
    parser.add_argument(
        "--target-address",
        default=f"0x{DEFAULT_TARGET_ADDRESS:x}",
        help="target global address to xref (default: rootB=0x10e184b18)",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="output JSON path under build/",
    )
    args = parser.parse_args()

    binary_path = Path(args.binary_path).expanduser().resolve()
    if not binary_path.is_file():
        print(f"fatal: binary not found: {binary_path}", file=sys.stderr)
        return 1
    target_addr = int(args.target_address, 0)
    output_path = Path(args.output).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    otool_output = _run_otool(binary_path)
    text_vmaddr, text_fileoff, text_size = _parse_text_section(otool_output)
    print(
        f"scanning __text vmaddr=0x{text_vmaddr:x} "
        f"fileoff=0x{text_fileoff:x} size=0x{text_size:x} "
        f"target=0x{target_addr:x}",
        file=sys.stderr,
    )
    raw = binary_path.read_bytes()
    text_bytes = raw[text_fileoff:text_fileoff + text_size]

    hits = scan_adrp_add_pairs(text_bytes, text_vmaddr, target_addr)

    # Group by destination register for quick human scan.
    by_dst: dict[str, int] = {}
    by_func: dict[str, int] = {}
    for h in hits:
        by_dst[h["dstReg"]] = by_dst.get(h["dstReg"], 0) + 1
        fe = h.get("functionEntry") or "<unknown>"
        by_func[fe] = by_func.get(fe, 0) + 1

    report = {
        "schemaVersion": 1,
        "workflow": "hok-016c25-rootB-xref-scan",
        "bundleId": DEFAULT_BUNDLE_ID,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "binaryPath": str(binary_path),
        "target": {"address": f"0x{target_addr:x}"},
        "image": {
            "textVmaddr": f"0x{text_vmaddr:x}",
            "textFileoff": f"0x{text_fileoff:x}",
            "textSize": f"0x{text_size:x}",
        },
        "summary": {
            "totalHits": len(hits),
            "byDstReg": by_dst,
            "byFunctionEntry": by_func,
        },
        "hits": hits,
    }

    output_path.write_text(json.dumps(report, indent=2))
    print(
        f"wrote {output_path} with {len(hits)} hits; "
        f"byDstReg={by_dst} byFunc={len(by_func)} distinct",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
