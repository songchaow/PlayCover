from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

import sys

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok006_ngr_lldb_runner import (  # noqa: E402
    evaluate_lldb_capture,
    extract_lldb_evidence,
    summarize_lldb_evidence,
)


class HOK006NGRLLDBRunnerTests(unittest.TestCase):
    def test_extract_lldb_evidence_returns_nested_lldb_payload(self) -> None:
        launch_outcome = {
            "parsed": {
                "bundleIdentifier": "com.tencent.ngr",
                "lldb": {
                    "didStop": True,
                    "stopReason": "EXC_BAD_ACCESS (code=1, address=0x0)",
                },
            }
        }

        evidence = extract_lldb_evidence(launch_outcome)

        self.assertEqual(evidence, launch_outcome["parsed"]["lldb"])

    def test_summarize_lldb_evidence_surfaces_faulting_details(self) -> None:
        evidence = {
            "processIdentifier": 24769,
            "timedOut": False,
            "didStop": True,
            "stopReason": "EXC_BAD_ACCESS (code=1, address=0x0)",
            "signal": "SIGSEGV",
            "faultAddress": "0x0",
            "faultingThread": "1",
            "faultingFrame": "frame #0: 0x0000000101234567 NGR`foo + 12",
            "faultingInstruction": "->  0x0000000101234567 <+12>: ldr x8, [x0]",
            "backtrace": [
                "frame #0: 0x0000000101234567 NGR`foo + 12",
                "frame #1: 0x0000000107654321 NGR`bar + 44",
            ],
            "transcriptTail": "Process 24769 stopped\n* thread #1, stop reason = EXC_BAD_ACCESS (code=1, address=0x0)",
        }

        summary = summarize_lldb_evidence(evidence)

        self.assertTrue(summary["present"])
        self.assertFalse(summary["timedOut"])
        self.assertTrue(summary["didStop"])
        self.assertEqual(summary["faultAddress"], "0x0")
        self.assertEqual(summary["backtraceDepth"], 2)
        self.assertEqual(summary["backtraceHead"][0], evidence["backtrace"][0])

    def test_summarize_lldb_evidence_preserves_timeout_safe_transcript_tail(self) -> None:
        evidence = {
            "timedOut": True,
            "didStop": False,
            "backtrace": [],
            "transcript": "lldb waited without crash",
        }

        summary = summarize_lldb_evidence(evidence)
        capture = evaluate_lldb_capture(summary)

        self.assertTrue(summary["present"])
        self.assertTrue(summary["timedOut"])
        self.assertFalse(summary["didStop"])
        self.assertEqual(summary["transcriptTail"], "lldb waited without crash")
        self.assertTrue(capture["evidencePresent"])
        self.assertTrue(capture["timedOut"])
        self.assertFalse(capture["automationReady"])


if __name__ == "__main__":
    unittest.main()
