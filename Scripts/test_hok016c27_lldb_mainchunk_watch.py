from __future__ import annotations

import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok016c27_lldb_mainchunk_watch import (  # noqa: E402
    _format_materialize_target_trace_context,
    _materialize_target_phase_for_pc,
)


class HOK016C27LLDBMainchunkWatchTests(unittest.TestCase):
    def test_materialize_target_phase_mapping_uses_named_checkpoints(self) -> None:
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A068), "entry")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A10C), "post-helper2")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A238), "branch-238")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A3E0), "branch-3e0")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A580), "branch-580")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A31C), "ret-31c")
        self.assertEqual(_materialize_target_phase_for_pc(0x10432A555), "pc-0x10432a555")

    def test_materialize_target_trace_context_formats_compact_call_header(self) -> None:
        trace = {
            "call_id": 7,
            "entry_lr": 0x100122F58,
            "entry_x0": 0x10E16DED8,
            "entry_x1": 0x600003C1B390,
            "entry_x2": 0x10AA4678C,
            "entry_x3": 0x600003159FB0,
        }

        self.assertEqual(
            _format_materialize_target_trace_context(trace),
            " call=7 entryLR=0x100122f58 entryX0=0x10e16ded8"
            " entryX1=0x600003c1b390 entryX2=0x10aa4678c entryX3=0x600003159fb0",
        )
        self.assertEqual(_format_materialize_target_trace_context(None), " trace=untracked")


if __name__ == "__main__":
    unittest.main()
