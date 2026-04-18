from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok007_ngr_callsite_mapper import (  # noqa: E402
    MachORegion,
    compact_instruction_text,
    decode_instruction_stream_bytes,
    parse_faulting_frame,
    parse_faulting_instruction,
    parse_json_documents,
    parse_lldb_registers,
    parse_lldb_target_binary_path,
    parse_llvm_objdump_window,
    resolve_file_offset,
    resolve_region_for_address,
)


class HOK007NGRCallsiteMapperTests(unittest.TestCase):
    def test_parse_lldb_target_binary_path_prefers_target_create_line(self) -> None:
        transcript = (
            '(lldb) target create "/tmp/com.tencent.ngr.app/NGR"\n'
            "Current executable set to '/tmp/com.tencent.ngr.app/NGR' (arm64).\n"
        )

        path = parse_lldb_target_binary_path(transcript)

        self.assertEqual(path, Path("/tmp/com.tencent.ngr.app/NGR").resolve())

    def test_parse_json_documents_handles_ips_header_and_body(self) -> None:
        text = '{"header":1}\n{\n  "body": 2\n}'

        documents = parse_json_documents(text)

        self.assertEqual(documents, [{"header": 1}, {"body": 2}])

    def test_parse_faulting_fields_extracts_address_symbol_and_instruction(self) -> None:
        frame = "frame #0: 0x000000010480df08 NGR`___lldb_unnamed_symbol272374 + 124"
        instruction = "->  0x10480df08 <+124>: ldr    x8, [x19]"

        parsed_frame = parse_faulting_frame(frame)
        parsed_instruction = parse_faulting_instruction(instruction)

        self.assertEqual(parsed_frame["address"], 0x10480DF08)
        self.assertEqual(parsed_frame["symbol"], "___lldb_unnamed_symbol272374")
        self.assertEqual(parsed_frame["symbolOffset"], 124)
        self.assertEqual(parsed_instruction["address"], 0x10480DF08)
        self.assertEqual(parsed_instruction["instructionOffset"], 124)
        self.assertEqual(parsed_instruction["text"], "ldr x8, [x19]")

    def test_parse_lldb_registers_extracts_x19_and_pc(self) -> None:
        text = (
            "General Purpose Registers:\n"
            "       x19 = 0x0000000000000000\n"
            "        pc = 0x000000010480df08\n"
            "       far = 0x0000000000000000\n"
        )

        registers = parse_lldb_registers(text)

        self.assertEqual(registers["x19"], 0)
        self.assertEqual(registers["pc"], 0x10480DF08)
        self.assertEqual(registers["far"], 0)

    def test_decode_instruction_stream_bytes_decodes_base64_payloads(self) -> None:
        decoded = decode_instruction_stream_bytes(
            {
                "beforePC": "AQIDBA==",
                "atPC": "aAJA+Q==",
            }
        )

        self.assertEqual(decoded["beforePCHex"], "01020304")
        self.assertEqual(decoded["atPCHex"], "680240f9")
        self.assertEqual(decoded["atPCLength"], 4)

    def test_resolve_region_and_file_offset_prefers_section_match(self) -> None:
        regions = [
            MachORegion(segname="__TEXT", sectname=None, vmaddr=0x100000000, vmsize=0x1000, fileoff=0, filesize=0x1000),
            MachORegion(segname="__TEXT", sectname="__text", vmaddr=0x100000100, vmsize=0x200, fileoff=0x100, filesize=0x200),
        ]

        region = resolve_region_for_address(regions, 0x100000124)

        self.assertIsNotNone(region)
        self.assertEqual(region.sectname, "__text")
        self.assertEqual(resolve_file_offset(region, 0x100000124), 0x124)

    def test_parse_llvm_objdump_window_extracts_instruction_rows(self) -> None:
        disassembly = (
            "10480df08:\t68 02 40 f9\tldr\tx8, [x19]\n"
            "10480df0c:\t08 09 40 f9\tldr\tx8, [x8, #0x10]\n"
        )

        rows = parse_llvm_objdump_window(disassembly)

        self.assertEqual(rows[0]["address"], 0x10480DF08)
        self.assertEqual(rows[0]["bytes"], "680240f9")
        self.assertEqual(rows[0]["instruction"], "ldr x8, [x19]")
        self.assertEqual(rows[1]["instruction"], "ldr x8, [x8, #0x10]")

    def test_compact_instruction_text_normalizes_spacing(self) -> None:
        self.assertEqual(compact_instruction_text("  ldr    x8,   [x19]  "), "ldr x8, [x19]")


if __name__ == "__main__":
    unittest.main()
