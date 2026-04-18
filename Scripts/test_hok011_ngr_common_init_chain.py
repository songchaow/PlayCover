from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok011_ngr_common_init_chain import (  # noqa: E402
    InitOffsetsSection,
    decode_add_imm,
    decode_adrp,
    decode_aarch64_str_imm,
    parse_init_offsets_section,
    read_init_offsets,
    resolve_initializer_entry_vmaddrs,
    scan_initializer_for_store_to,
)


class DecodeHelperTests(unittest.TestCase):
    def test_decode_adrp_parses_page_base(self) -> None:
        self.assertEqual(decode_adrp("adrp x21, 0x10e200000"), ("x21", 0x10E200000))
        self.assertIsNone(decode_adrp("adrp w0, 0x123"))  # only x registers
        self.assertIsNone(decode_adrp("bl 0x10a9ec9e4"))

    def test_decode_add_imm_parses_destination_source_and_imm(self) -> None:
        self.assertEqual(decode_add_imm("add x8, x8, #0x6f8"), ("x8", "x8", 0x6F8))
        self.assertEqual(decode_add_imm("add x19, sp, #0x18"), ("x19", "sp", 0x18))
        self.assertIsNone(decode_add_imm("adrp x8, 0x123"))

    def test_decode_str_imm_extracts_offset(self) -> None:
        self.assertEqual(decode_aarch64_str_imm("str x0, [x8, #0x6f8]"), ("x0", "x8", 0x6F8))
        self.assertEqual(decode_aarch64_str_imm("str x0, [x8]"), ("x0", "x8", 0))
        self.assertEqual(decode_aarch64_str_imm("str xzr, [sp, #0x10]"), ("xzr", "sp", 0x10))
        # Pre-/post-index variants are intentionally not supported.
        self.assertIsNone(decode_aarch64_str_imm("str x0, [x8], #8"))
        self.assertIsNone(decode_aarch64_str_imm("str x0, [x8, #8]!"))


class InitOffsetsSectionTests(unittest.TestCase):
    def test_parse_init_offsets_section_extracts_vmaddr_and_fileoff(self) -> None:
        otool_output = (
            "Section\n"
            "  sectname __text\n"
            "   segname __TEXT\n"
            "      addr 0x0000000100004000\n"
            "      size 0x0000000000010000\n"
            "    offset 16384\n"
            "     align 2^2 (4)\n"
            "    reloff 0\n"
            "    nreloc 0\n"
            "     flags 0x80000400\n"
            " reserved1 0\n"
            " reserved2 0\n"
            "Section\n"
            "  sectname __init_offsets\n"
            "   segname __TEXT\n"
            "      addr 0x000000010aa0b940\n"
            "      size 0x0000000000002f00\n"
            "    offset 178305344\n"
            "     align 2^2 (4)\n"
            "    reloff 0\n"
            "    nreloc 0\n"
            "     flags 0x00000016\n"
            " reserved1 0\n"
            " reserved2 0\n"
        )
        section = parse_init_offsets_section(otool_output)
        self.assertIsNotNone(section)
        assert section is not None
        self.assertEqual(section.vmaddr, 0x10AA0B940)
        self.assertEqual(section.fileoff, 178305344)
        self.assertEqual(section.vmsize, 0x2F00)
        self.assertEqual(section.count, 3008)

    def test_parse_init_offsets_returns_none_when_absent(self) -> None:
        self.assertIsNone(parse_init_offsets_section("Section\n  sectname __text\n   segname __TEXT\n     flags 0\n"))

    def test_read_init_offsets_unpacks_little_endian_u32(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "fake"
            offsets = [0x4000, 0x4010, 0x4020, 0x4030]
            payload = struct.pack(f"<{len(offsets)}I", *offsets)
            prefix = b"\x00" * 128
            binary.write_bytes(prefix + payload)
            section = InitOffsetsSection(
                vmaddr=0x100000000,
                vmsize=len(payload),
                fileoff=len(prefix),
                filesize=len(payload),
                count=len(offsets),
            )
            self.assertEqual(read_init_offsets(binary, section), offsets)

    def test_resolve_initializer_entry_vmaddrs_adds_text_base(self) -> None:
        self.assertEqual(
            resolve_initializer_entry_vmaddrs([0x4000, 0x5000], 0x100000000),
            [0x100004000, 0x100005000],
        )


def _make_fake_binary_with_disasm(
    tmp_path: Path,
    init_addr: int,
    instructions: list[bytes],
) -> Path:
    """Lay out a fake NGR-like binary in memory.  The scanner shells out to llvm-objdump, which
    requires a real Mach-O; for unit testing we prefer to instead inject a fake ``disassemble_range``
    via monkeypatching — but that change of contract is better done at the call site.  For
    now we only assert the decoder helpers above; end-to-end scanning is covered by the live
    run against the real NGR binary.
    """
    binary = tmp_path / "fake.bin"
    binary.write_bytes(b"\x00" * 4096)
    return binary


class ScannerUnitTests(unittest.TestCase):
    def test_scanner_detects_adrp_add_str_pattern(self) -> None:
        # Drive the scanner in isolation by patching `disassemble_range`.
        import hok011_ngr_common_init_chain as hok011

        fake_init_addr = 0x1000001F0
        target_address = 0x10E2146F8

        # Construct a synthetic initializer:
        #   adrp x8, 0x10e214000
        #   add  x8, x8, #0x6f8
        #   str  x0, [x8]
        #   ret
        synthetic = [
            {"address": 0x1000001F0, "bytes": "", "text": "stp x29, x30, [sp, #-0x10]!", "raw": ""},
            {"address": 0x1000001F4, "bytes": "", "text": "adrp x8, 0x10e214000", "raw": ""},
            {"address": 0x1000001F8, "bytes": "", "text": "add x8, x8, #0x6f8", "raw": ""},
            {"address": 0x1000001FC, "bytes": "", "text": "str x0, [x8]", "raw": ""},
            {"address": 0x100000200, "bytes": "", "text": "ldp x29, x30, [sp], #0x10", "raw": ""},
            {"address": 0x100000204, "bytes": "", "text": "ret", "raw": ""},
        ]

        original = hok011.disassemble_range
        try:
            hok011.disassemble_range = lambda *a, **kw: synthetic  # type: ignore[attr-defined]
            hits = scan_initializer_for_store_to(
                binary_path=Path("/nonexistent"),
                init_addr=fake_init_addr,
                target_address=target_address,
                max_instructions=64,
            )
        finally:
            hok011.disassemble_range = original  # type: ignore[attr-defined]

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].initializer_address, fake_init_addr)
        self.assertEqual(hits[0].instruction_address, 0x1000001FC)
        # When x8 was assembled via `adrp + add`, the scanner reports the effective
        # address of the base register (page + #imm) rather than the raw adrp page.
        self.assertIn("0x10e2146f8", hits[0].reason)
        self.assertIn("add-effective(x8)", hits[0].reason)

    def test_scanner_detects_adrp_str_offset_pattern(self) -> None:
        import hok011_ngr_common_init_chain as hok011

        fake_init_addr = 0x100000300
        target_address = 0x10E2146F8

        synthetic = [
            {"address": 0x100000300, "bytes": "", "text": "adrp x8, 0x10e214000", "raw": ""},
            {"address": 0x100000304, "bytes": "", "text": "str x1, [x8, #0x6f8]", "raw": ""},
            {"address": 0x100000308, "bytes": "", "text": "ret", "raw": ""},
        ]

        original = hok011.disassemble_range
        try:
            hok011.disassemble_range = lambda *a, **kw: synthetic  # type: ignore[attr-defined]
            hits = scan_initializer_for_store_to(
                binary_path=Path("/nonexistent"),
                init_addr=fake_init_addr,
                target_address=target_address,
                max_instructions=64,
            )
        finally:
            hok011.disassemble_range = original  # type: ignore[attr-defined]

        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].instruction_address, 0x100000304)

    def test_scanner_ignores_unrelated_stores(self) -> None:
        import hok011_ngr_common_init_chain as hok011

        fake_init_addr = 0x100000400
        target_address = 0x10E2146F8

        synthetic = [
            {"address": 0x100000400, "bytes": "", "text": "adrp x8, 0x10e200000", "raw": ""},  # different page
            {"address": 0x100000404, "bytes": "", "text": "str x0, [x8, #0x6f8]", "raw": ""},
            {"address": 0x100000408, "bytes": "", "text": "ret", "raw": ""},
        ]

        original = hok011.disassemble_range
        try:
            hok011.disassemble_range = lambda *a, **kw: synthetic  # type: ignore[attr-defined]
            hits = scan_initializer_for_store_to(
                binary_path=Path("/nonexistent"),
                init_addr=fake_init_addr,
                target_address=target_address,
                max_instructions=64,
            )
        finally:
            hok011.disassemble_range = original  # type: ignore[attr-defined]

        self.assertEqual(hits, [])

    def test_scanner_stops_at_ret(self) -> None:
        import hok011_ngr_common_init_chain as hok011

        fake_init_addr = 0x100000500
        target_address = 0x10E2146F8

        synthetic = [
            {"address": 0x100000500, "bytes": "", "text": "ret", "raw": ""},
            {"address": 0x100000504, "bytes": "", "text": "adrp x8, 0x10e214000", "raw": ""},
            {"address": 0x100000508, "bytes": "", "text": "str x0, [x8, #0x6f8]", "raw": ""},
        ]

        original = hok011.disassemble_range
        try:
            hok011.disassemble_range = lambda *a, **kw: synthetic  # type: ignore[attr-defined]
            hits = scan_initializer_for_store_to(
                binary_path=Path("/nonexistent"),
                init_addr=fake_init_addr,
                target_address=target_address,
                max_instructions=64,
            )
        finally:
            hok011.disassemble_range = original  # type: ignore[attr-defined]

        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
