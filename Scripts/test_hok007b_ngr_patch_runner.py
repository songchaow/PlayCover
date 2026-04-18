from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from hok007b_ngr_patch_runner import (  # noqa: E402
    CANDIDATE_NAME,
    EPILOGUE_PC,
    EXPECTED_ORIGINAL_BYTES_LE,
    EXPECTED_PATCHED_BYTES_LE,
    FAULT_FILE_OFFSET,
    FAULT_PC,
    PATCH_LENGTH,
    build_patch_plan,
    encode_b_instruction,
    instruction_to_little_endian_hex,
    read_binary_slice,
    resolve_binary_path,
    run_apply,
    run_dry_run,
    run_revert,
    write_binary_slice,
)


class HOK007BEncodingTests(unittest.TestCase):
    def test_encode_b_instruction_matches_candidate_e_target(self) -> None:
        encoded = encode_b_instruction(FAULT_PC, EPILOGUE_PC)
        self.assertEqual(encoded, 0x14000007)
        self.assertEqual(instruction_to_little_endian_hex(encoded), EXPECTED_PATCHED_BYTES_LE)

    def test_encode_b_instruction_rejects_unaligned_delta(self) -> None:
        with self.assertRaises(ValueError):
            encode_b_instruction(FAULT_PC, EPILOGUE_PC + 1)

    def test_encode_b_instruction_supports_backward_branch(self) -> None:
        encoded = encode_b_instruction(FAULT_PC, FAULT_PC - 4)
        # b -4  => imm26 = -1 = 0x3FFFFFF  => word = 0x17FFFFFF
        self.assertEqual(encoded, 0x17FFFFFF)

    def test_encode_b_instruction_rejects_out_of_range(self) -> None:
        with self.assertRaises(ValueError):
            encode_b_instruction(0, (1 << 28))  # 256MiB forward, exceeds 128MiB range

    def test_build_patch_plan_returns_candidate_e_metadata(self) -> None:
        plan = build_patch_plan()
        self.assertEqual(plan["candidate"], CANDIDATE_NAME)
        self.assertEqual(plan["faultPc"], f"0x{FAULT_PC:x}")
        self.assertEqual(plan["branchTargetPc"], f"0x{EPILOGUE_PC:x}")
        self.assertEqual(plan["fileOffset"], f"0x{FAULT_FILE_OFFSET:x}")
        self.assertEqual(plan["originalBytesLe"], EXPECTED_ORIGINAL_BYTES_LE)
        self.assertEqual(plan["patchedBytesLe"], EXPECTED_PATCHED_BYTES_LE)
        self.assertEqual(plan["patchLengthBytes"], PATCH_LENGTH)


def _make_fake_binary(tmp_path: Path, byte_hex: str) -> Path:
    """Create a sparse file large enough to contain FAULT_FILE_OFFSET and seed patch-window bytes."""
    binary_path = tmp_path / "NGR_fake"
    total = FAULT_FILE_OFFSET + PATCH_LENGTH + 16
    with binary_path.open("wb") as handle:
        handle.truncate(total)
    write_binary_slice(binary_path, FAULT_FILE_OFFSET, bytes.fromhex(byte_hex))
    return binary_path


class HOK007BPatchRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_resolve_binary_path_from_report_configuration(self) -> None:
        binary = self.tmp_path / "ngr-bin"
        binary.write_bytes(b"\x00")
        report = {"configuration": {"binaryPath": str(binary)}}
        resolved = resolve_binary_path(None, report)
        self.assertEqual(resolved, binary.resolve())

    def test_resolve_binary_path_prefers_explicit_argument(self) -> None:
        binary = self.tmp_path / "explicit-bin"
        binary.write_bytes(b"\x00")
        report = {"configuration": {"binaryPath": "/nonexistent"}}
        resolved = resolve_binary_path(str(binary), report)
        self.assertEqual(resolved, binary.resolve())

    def test_dry_run_reports_original_state(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_ORIGINAL_BYTES_LE)
        outcome = run_dry_run(binary, build_patch_plan())
        self.assertEqual(outcome["mode"], "dry-run")
        self.assertEqual(outcome["state"], "original")
        self.assertEqual(outcome["currentBytesHex"], EXPECTED_ORIGINAL_BYTES_LE)

    def test_dry_run_reports_already_patched_state(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_PATCHED_BYTES_LE)
        outcome = run_dry_run(binary, build_patch_plan())
        self.assertEqual(outcome["state"], "already-patched")

    def test_dry_run_reports_unexpected_state(self) -> None:
        binary = _make_fake_binary(self.tmp_path, "deadbeef")
        outcome = run_dry_run(binary, build_patch_plan())
        self.assertEqual(outcome["state"], "unexpected")

    def test_run_apply_writes_patched_bytes_and_backs_up_original(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_ORIGINAL_BYTES_LE)
        backup_dir = self.tmp_path / "backups"
        outcome = run_apply(binary, backup_dir, build_patch_plan(), skip_codesign=True)

        self.assertEqual(outcome["state"], "applied")
        self.assertEqual(outcome["currentBytesHex"], EXPECTED_PATCHED_BYTES_LE)
        self.assertEqual(outcome["backupBytesHex"], EXPECTED_ORIGINAL_BYTES_LE)

        patched_bytes = read_binary_slice(binary, FAULT_FILE_OFFSET, PATCH_LENGTH)
        self.assertEqual(patched_bytes.hex(), EXPECTED_PATCHED_BYTES_LE)

        backup_path = Path(outcome["backupPath"])
        self.assertTrue(backup_path.is_file())
        self.assertEqual(backup_path.read_bytes().hex(), EXPECTED_ORIGINAL_BYTES_LE)

    def test_run_apply_is_idempotent_when_already_patched(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_PATCHED_BYTES_LE)
        backup_dir = self.tmp_path / "backups"
        outcome = run_apply(binary, backup_dir, build_patch_plan(), skip_codesign=True)
        self.assertEqual(outcome["state"], "already-patched")
        # Binary bytes unchanged.
        self.assertEqual(
            read_binary_slice(binary, FAULT_FILE_OFFSET, PATCH_LENGTH).hex(),
            EXPECTED_PATCHED_BYTES_LE,
        )

    def test_run_apply_rejects_unexpected_original_bytes(self) -> None:
        binary = _make_fake_binary(self.tmp_path, "cafebabe")
        backup_dir = self.tmp_path / "backups"
        with self.assertRaises(SystemExit):
            run_apply(binary, backup_dir, build_patch_plan(), skip_codesign=True)
        # Binary bytes untouched after refusal.
        self.assertEqual(
            read_binary_slice(binary, FAULT_FILE_OFFSET, PATCH_LENGTH).hex(),
            "cafebabe",
        )

    def test_run_revert_restores_original_bytes_from_backup(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_ORIGINAL_BYTES_LE)
        backup_dir = self.tmp_path / "backups"
        run_apply(binary, backup_dir, build_patch_plan(), skip_codesign=True)

        outcome = run_revert(binary, backup_dir, skip_codesign=True)
        self.assertEqual(outcome["state"], "reverted")
        self.assertEqual(
            read_binary_slice(binary, FAULT_FILE_OFFSET, PATCH_LENGTH).hex(),
            EXPECTED_ORIGINAL_BYTES_LE,
        )

    def test_run_revert_is_idempotent_when_already_original(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_ORIGINAL_BYTES_LE)
        backup_dir = self.tmp_path / "backups"
        outcome = run_revert(binary, backup_dir, skip_codesign=True)
        self.assertEqual(outcome["state"], "already-original")

    def test_run_revert_requires_backup_when_patched(self) -> None:
        binary = _make_fake_binary(self.tmp_path, EXPECTED_PATCHED_BYTES_LE)
        backup_dir = self.tmp_path / "backups-empty"
        with self.assertRaises(SystemExit):
            run_revert(binary, backup_dir, skip_codesign=True)


if __name__ == "__main__":
    unittest.main()
