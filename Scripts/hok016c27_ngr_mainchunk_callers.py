#!/usr/bin/env python3
"""HOK-016-C.2.7 offline caller scan for the ``mainChunk -> \"1\"`` path.

This script complements the live LLDB trace by answering a static question:
which functions in the NGR main binary call the three key helpers involved in
the narrowed failure chain?

Targets:

* ``0x1001ba82c`` — second-level lookup helper ``lookup2(mainChunk, \"1\")``
* ``0x1001bd448`` — wrapper that prepares out-slots around ``lookup2``
* ``0x1001cd114`` — rootB string-key lookup helper (used for ``\"main\"``)

For each target the script reports:

1. Every direct ``bl <target>`` callsite in ``__TEXT,__text``.
2. The enclosing function entry for each callsite (walk-back to prologue).
3. A small instruction window around the callsite.
4. Nearby ``str/strb/strh`` stores using immediate offset ``#0x60`` within the
   same instruction window — a cheap hint for candidate subtree-root writers.
5. One shallow caller level for each unique caller function entry.

Output: ``build/hok-016c27-mainchunk-callers.json``.

Read-only/offline: the script only reads the NGR Mach-O on disk.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hok015_ngr_cmdline_locator import (  # noqa: E402
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
DEFAULT_OUTPUT = Path("build/hok-016c27-mainchunk-callers.json")
DEFAULT_WINDOW_INSNS = 24

TARGETS = {
    "lookup2": 0x1001BA82C,
    "bd448": 0x1001BD448,
    "rootbLookup": 0x1001CD114,
}


def _decode_bl(inst: int, pc: int) -> int | None:
    if (inst & 0xFC000000) != 0x94000000:
        return None
    imm26 = inst & 0x03FFFFFF
    if imm26 & (1 << 25):
        imm26 -= (1 << 26)
    return pc + (imm26 << 2)


def _is_prologue_instruction(inst: int) -> bool:
    if (inst & 0xFF800000) == 0xD1000000 and ((inst >> 5) & 0x1F) == 31 and (inst & 0x1F) == 31:
        return True
    if (inst & 0xFFC0FFFF) == 0xA98003FD:
        return True
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


def _insn_tag(inst: int) -> str:
    if decode_adrp(inst, 0) is not None:
        return "adrp"
    if decode_add_imm(inst) is not None:
        return "add (imm)"
    if (inst & 0xFC000000) == 0x94000000:
        return "bl"
    if (inst & 0xFC000000) == 0x14000000:
        return "b"
    if (inst & 0xFFE0FC1F) == 0xD63F0000:
        return "blr"
    if (inst & 0xFFC00000) == 0xF9000000:
        return "str (64-bit imm)"
    if (inst & 0xBFC00000) == 0xB9000000:
        return "str (32-bit imm)"
    if (inst & 0xFFC00000) == 0x39000000:
        return "strb"
    if (inst & 0xFFC00000) == 0x79000000:
        return "strh"
    if (inst & 0xFFC00000) == 0xF9400000:
        return "ldr (64-bit imm)"
    if (inst & 0xBFC00000) == 0xB9400000:
        return "ldr (32-bit imm)"
    if inst == 0xD65F03C0:
        return "ret"
    if _is_prologue_instruction(inst):
        return "prologue"
    return f"other 0x{inst:08x}"


def _decode_store_imm(inst: int) -> tuple[str, int, int, int] | None:
    # STR Xt, [Xn, #imm12 * 8]
    if (inst & 0xFFC00000) == 0xF9000000:
        imm12 = (inst >> 10) & 0xFFF
        return "str64", inst & 0x1F, (inst >> 5) & 0x1F, imm12 * 8
    # STR Wt, [Xn, #imm12 * 4]
    if (inst & 0xBFC00000) == 0xB9000000:
        imm12 = (inst >> 10) & 0xFFF
        return "str32", inst & 0x1F, (inst >> 5) & 0x1F, imm12 * 4
    # STRB Wt, [Xn, #imm12]
    if (inst & 0xFFC00000) == 0x39000000:
        imm12 = (inst >> 10) & 0xFFF
        return "strb", inst & 0x1F, (inst >> 5) & 0x1F, imm12
    # STRH Wt, [Xn, #imm12 * 2]
    if (inst & 0xFFC00000) == 0x79000000:
        imm12 = (inst >> 10) & 0xFFF
        return "strh", inst & 0x1F, (inst >> 5) & 0x1F, imm12 * 2
    return None


def _build_window(
    text_bytes: bytes,
    text_vmaddr: int,
    hit_off: int,
    window_insns: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    start = max(0, hit_off - (window_insns // 2) * 4)
    end = min(len(text_bytes), hit_off + (window_insns // 2) * 4 + 4)

    window: list[dict[str, Any]] = []
    offset60_stores: list[dict[str, Any]] = []
    cur = start
    while cur < end:
        inst = struct.unpack_from("<I", text_bytes, cur)[0]
        pc = text_vmaddr + cur
        window.append(
            {
                "pc": f"0x{pc:x}",
                "encoding": f"0x{inst:08x}",
                "tag": _insn_tag(inst),
                "isHit": cur == hit_off,
            }
        )
        store = _decode_store_imm(inst)
        if store is not None:
            kind, rt, rn, imm = store
            if imm == 0x60:
                offset60_stores.append(
                    {
                        "pc": f"0x{pc:x}",
                        "kind": kind,
                        "srcReg": f"x{rt}" if kind == "str64" else f"w{rt}",
                        "baseReg": f"x{rn}",
                        "offset": "0x60",
                    }
                )
        cur += 4

    return window, offset60_stores


def _scan_bl_callers(text_bytes: bytes, text_vmaddr: int, targets: set[int]) -> dict[int, list[int]]:
    result: dict[int, list[int]] = {target: [] for target in targets}
    off = 0
    size = len(text_bytes)
    while off + 4 <= size:
        inst = struct.unpack_from("<I", text_bytes, off)[0]
        pc = text_vmaddr + off
        target = _decode_bl(inst, pc)
        if target is not None and target in result:
            result[target].append(pc)
        off += 4
    return result


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "HOK-016-C.2.7: enumerate static callers of the mainChunk failure-path "
            "helpers and highlight nearby #0x60 store instructions."
        )
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument(
        "--binary-path",
        default=str(DEFAULT_BINARY_PATH),
        help="path to the NGR main binary",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="output JSON path (default: build/hok-016c27-mainchunk-callers.json)",
    )
    parser.add_argument(
        "--window-insns",
        type=int,
        default=DEFAULT_WINDOW_INSNS,
        help="instruction window size around each direct/shallow callsite",
    )
    parser.add_argument(
        "--max-shallow-callers",
        type=int,
        default=32,
        help="cap shallow callers reported for each unique direct caller function",
    )
    return parser


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

    direct = _scan_bl_callers(text_bytes, text.vmaddr, set(TARGETS.values()))

    targets_report: dict[str, Any] = {}
    unique_direct_functions: dict[int, set[str]] = {}

    for name, target in TARGETS.items():
        callsites: list[dict[str, Any]] = []
        for call_pc in direct[target]:
            hit_off = call_pc - text.vmaddr
            function_entry = _walk_back_to_prologue(text_bytes, hit_off, text.vmaddr)
            window, offset60_stores = _build_window(
                text_bytes,
                text.vmaddr,
                hit_off,
                args.window_insns,
            )
            callsites.append(
                {
                    "callPc": f"0x{call_pc:x}",
                    "callerFunctionEntry": f"0x{function_entry:x}" if function_entry else None,
                    "nearbyInsns": window,
                    "nearbyOffset60Stores": offset60_stores,
                }
            )
            if function_entry is not None:
                unique_direct_functions.setdefault(function_entry, set()).add(name)

        targets_report[name] = {
            "targetVmaddr": f"0x{target:x}",
            "directCallCount": len(callsites),
            "uniqueCallerFunctionCount": len(
                {entry for entry in (c["callerFunctionEntry"] for c in callsites) if entry is not None}
            ),
            "callsites": callsites,
        }

    shallow_targets = set(unique_direct_functions.keys())
    shallow = _scan_bl_callers(text_bytes, text.vmaddr, shallow_targets) if shallow_targets else {}
    function_report: list[dict[str, Any]] = []
    for function_entry in sorted(unique_direct_functions.keys()):
        shallow_callsites: list[dict[str, Any]] = []
        for call_pc in shallow.get(function_entry, [])[: args.max_shallow_callers]:
            hit_off = call_pc - text.vmaddr
            caller_entry = _walk_back_to_prologue(text_bytes, hit_off, text.vmaddr)
            window, offset60_stores = _build_window(
                text_bytes,
                text.vmaddr,
                hit_off,
                args.window_insns,
            )
            shallow_callsites.append(
                {
                    "callPc": f"0x{call_pc:x}",
                    "callerFunctionEntry": f"0x{caller_entry:x}" if caller_entry else None,
                    "nearbyInsns": window,
                    "nearbyOffset60Stores": offset60_stores,
                }
            )

        function_report.append(
            {
                "functionEntry": f"0x{function_entry:x}",
                "targetNames": sorted(unique_direct_functions[function_entry]),
                "shallowCallerCount": len(shallow.get(function_entry, [])),
                "shallowCallsites": shallow_callsites,
            }
        )

    report = {
        "bundleId": args.bundle_id,
        "binaryPath": str(binary_path),
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "targets": targets_report,
        "directCallerFunctions": function_report,
        "summary": {
            "targetCount": len(TARGETS),
            "uniqueDirectCallerFunctionCount": len(unique_direct_functions),
            "windowInsns": args.window_insns,
        },
    }
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
