#!/usr/bin/env python3
"""
HOK-007B: 为 `com.tencent.ngr` 在 `0x10480df08` / `fileOffset=0x480df08` 的 faulting callsite
设计并应用**一个**最小可逆 patch 候选（候选 E），并产出结构化报告。

当前 patch 候选（候选 E）
-------------------------
faulting 指令：
    0x10480df08: ldr x8, [x19]       ; 磁盘字节 680240f9

HOK-007A 已证明 x19 在崩溃时为 0，造成 null deref；`0x10480df08` 之后是标准的 C++ 虚函数
`blr x8` 序列，说明调用方用了一个未初始化 / null 的 `this`。`0x10480df24` 正是本函数的
stack-cookie 校验 + 寄存器恢复 + `ret` 入口（epilogue），函数 prologue 已完整执行。

因此最小可逆 patch 是在 `0x10480df08` 处把 `ldr x8, [x19]` 替换为无条件分支
`b 0x10480df24`：在被调用方 `this == nullptr` 时把该函数变成静默 no-op，
而 prologue/epilogue 的栈帧 / cookie 对称性仍然保持。

- 目标地址偏移：`0x10480df24 - 0x10480df08 = 0x1c`，即 7 条 4 字节指令。
- ARM64 `b` 编码：`0x14000000 | imm26`，imm26=7 → `0x14000007`。
- 小端磁盘字节：`07000014`。
- file offset：`0x480df08`。
- 原始字节（小端）：`680240f9`。

默认行为
---------
- `--dry-run`（默认）：不修改二进制，仅输出**计划中的** bytes diff、回滚方式与校验清单到报告。
- `--apply`：先校验磁盘原始字节 == 期望字节、计算 sha256、写入 backup，然后覆盖目标字节，
  重新 `codesign -f -s -`，再对照期望的 post-patch 字节做二次校验。
- `--revert`：读取 backup 字节恢复原指令并重新签名；同样要先校验当前磁盘字节 ==
  期望的 post-patch 字节，避免误操作。

所有模式都会把结构化结果写入 `build/hok-007b-ngr-patch-report.json`，并在 dry-run / apply /
revert 之间共享同一个 schema，便于下游脚本消费。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))


DEFAULT_BUNDLE_ID = "com.tencent.ngr"
DEFAULT_CALLSITE_REPORT = Path("build/hok-007-ngr-callsite-report.json")
DEFAULT_OUTPUT = Path("build/hok-007b-ngr-patch-report.json")
DEFAULT_BACKUP_DIR = Path("build/hok-007b-backups")

# Candidate E constants.
CANDIDATE_NAME = "candidate-e-branch-to-epilogue"
FAULT_PC = 0x10480DF08
EPILOGUE_PC = 0x10480DF24
FAULT_FILE_OFFSET = 0x480DF08
EXPECTED_ORIGINAL_BYTES_LE = "680240f9"
EXPECTED_PATCHED_BYTES_LE = "07000014"
PATCH_LENGTH = 4


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Apply the HOK-007B minimal-reversible patch candidate to the NGR binary")
    parser.add_argument(
        "--callsite-report",
        default=str(DEFAULT_CALLSITE_REPORT),
        help="HOK-007A structured report path (default: build/hok-007-ngr-callsite-report.json)",
    )
    parser.add_argument(
        "--binary-path",
        help="explicit NGR binary path; defaults to the path embedded in the callsite report",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="structured JSON report path (default: build/hok-007b-ngr-patch-report.json)",
    )
    parser.add_argument(
        "--backup-dir",
        default=str(DEFAULT_BACKUP_DIR),
        help="directory used to store the original 4-byte window before apply (default: build/hok-007b-backups)",
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--dry-run",
        action="store_true",
        help="default mode; do not modify the binary, only emit the planned diff",
    )
    mode_group.add_argument(
        "--apply",
        action="store_true",
        help="apply the patch in-place; backs up the original bytes and re-signs ad-hoc",
    )
    mode_group.add_argument(
        "--revert",
        action="store_true",
        help="revert a previously-applied patch using the stored backup bytes",
    )
    parser.add_argument(
        "--skip-codesign",
        action="store_true",
        help="skip ad-hoc codesign after apply/revert (diagnostic only; binary will not launch cleanly)",
    )
    return parser


def parse_hex_int(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        return None
    return int(text, 0)


def load_callsite_report(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"HOK-007A callsite report not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_binary_path(explicit: str | None, report: dict[str, Any]) -> Path:
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f"Binary not found: {path}")
        return path
    configured = ((report.get("configuration") or {}).get("binaryPath"))
    if not configured:
        raise SystemExit("Could not resolve NGR binary path from callsite report; pass --binary-path")
    path = Path(str(configured)).expanduser().resolve()
    if not path.is_file():
        raise SystemExit(f"Binary not found: {path}")
    return path


def encode_b_instruction(source_pc: int, target_pc: int) -> int:
    """Encode an ARM64 unconditional ``b`` instruction from ``source_pc`` to ``target_pc``."""
    delta = target_pc - source_pc
    if delta % 4 != 0:
        raise ValueError(f"unaligned branch delta: {delta}")
    imm26 = delta // 4
    if imm26 < -(1 << 25) or imm26 >= (1 << 25):
        raise ValueError(f"imm26 out of range: {imm26}")
    imm26 &= (1 << 26) - 1
    return 0x14000000 | imm26


def instruction_to_little_endian_hex(instruction: int) -> str:
    return instruction.to_bytes(4, "little").hex()


def read_binary_slice(binary_path: Path, offset: int, length: int) -> bytes:
    with binary_path.open("rb") as handle:
        handle.seek(offset)
        return handle.read(length)


def write_binary_slice(binary_path: Path, offset: int, payload: bytes) -> None:
    with binary_path.open("r+b") as handle:
        handle.seek(offset)
        handle.write(payload)


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def run_command(cmd: list[str], cwd: Path | None = None) -> dict[str, Any]:
    completed = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd is not None else None,
        check=False,
        capture_output=True,
        text=True,
    )
    return {
        "command": list(cmd),
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def codesign_adhoc(binary_path: Path) -> dict[str, Any]:
    return run_command(["codesign", "-f", "-s", "-", str(binary_path)])


def write_report(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def build_patch_plan(fault_pc: int = FAULT_PC, epilogue_pc: int = EPILOGUE_PC) -> dict[str, Any]:
    instruction = encode_b_instruction(fault_pc, epilogue_pc)
    expected_patched_hex = instruction_to_little_endian_hex(instruction)
    if expected_patched_hex != EXPECTED_PATCHED_BYTES_LE:
        raise AssertionError(
            f"Patch encoding mismatch: computed {expected_patched_hex} but expected {EXPECTED_PATCHED_BYTES_LE}"
        )
    return {
        "candidate": CANDIDATE_NAME,
        "description": (
            "Replace `ldr x8, [x19]` at 0x10480df08 with `b 0x10480df24`, "
            "falling straight into the function's stack-cookie check + epilogue so that "
            "the dyld-era caller passing this==nullptr results in a silent no-op return."
        ),
        "faultPc": f"0x{fault_pc:x}",
        "branchTargetPc": f"0x{epilogue_pc:x}",
        "branchDeltaBytes": epilogue_pc - fault_pc,
        "fileOffset": f"0x{FAULT_FILE_OFFSET:x}",
        "patchLengthBytes": PATCH_LENGTH,
        "originalInstruction": "ldr x8, [x19]",
        "replacementInstruction": f"b 0x{epilogue_pc:x}",
        "originalBytesLe": EXPECTED_ORIGINAL_BYTES_LE,
        "patchedBytesLe": expected_patched_hex,
        "encodedInstructionBe": f"0x{instruction:08x}",
        "rollback": {
            "strategy": "restore 4 bytes from backup file and re-codesign ad-hoc",
            "backupFilenamePattern": "hok-007b-<binarySha256Prefix>.bin",
        },
        "signingImpact": (
            "Ad-hoc signature is invalidated by the byte change; re-sign with "
            "`codesign -f -s - <binary>` after apply or revert."
        ),
    }


def backup_file_for(backup_dir: Path, binary_sha256: str) -> Path:
    return backup_dir / f"hok-007b-{binary_sha256[:16]}.bin"


def summarize_region_match(
    observed_original: bytes,
    observed_patched: bytes,
) -> dict[str, Any]:
    return {
        "observedOriginalHex": observed_original.hex(),
        "observedPatchedHex": observed_patched.hex(),
        "matchesExpectedOriginal": observed_original.hex() == EXPECTED_ORIGINAL_BYTES_LE,
        "matchesExpectedPatched": observed_patched.hex() == EXPECTED_PATCHED_BYTES_LE,
    }


def run_dry_run(binary_path: Path, plan: dict[str, Any]) -> dict[str, Any]:
    current_bytes = read_binary_slice(binary_path, FAULT_FILE_OFFSET, PATCH_LENGTH)
    match = summarize_region_match(current_bytes, current_bytes)
    state = "original" if match["matchesExpectedOriginal"] else (
        "already-patched" if current_bytes.hex() == EXPECTED_PATCHED_BYTES_LE else "unexpected"
    )
    return {
        "mode": "dry-run",
        "state": state,
        "binarySha256": sha256_file(binary_path),
        "currentBytesHex": current_bytes.hex(),
        "expectedOriginalHex": EXPECTED_ORIGINAL_BYTES_LE,
        "expectedPatchedHex": EXPECTED_PATCHED_BYTES_LE,
        "matches": match,
    }


def run_apply(
    binary_path: Path,
    backup_dir: Path,
    plan: dict[str, Any],
    skip_codesign: bool,
) -> dict[str, Any]:
    pre_bytes = read_binary_slice(binary_path, FAULT_FILE_OFFSET, PATCH_LENGTH)
    pre_sha = sha256_file(binary_path)
    if pre_bytes.hex() != EXPECTED_ORIGINAL_BYTES_LE:
        if pre_bytes.hex() == EXPECTED_PATCHED_BYTES_LE:
            return {
                "mode": "apply",
                "state": "already-patched",
                "binarySha256Pre": pre_sha,
                "binarySha256Post": pre_sha,
                "currentBytesHex": pre_bytes.hex(),
                "expectedOriginalHex": EXPECTED_ORIGINAL_BYTES_LE,
                "expectedPatchedHex": EXPECTED_PATCHED_BYTES_LE,
                "codesign": None,
                "message": "Binary already matches the patched byte pattern; no change applied.",
            }
        raise SystemExit(
            f"Refusing to apply: observed bytes {pre_bytes.hex()} at file offset 0x{FAULT_FILE_OFFSET:x} "
            f"do not match expected original {EXPECTED_ORIGINAL_BYTES_LE}; re-run HOK-007A first."
        )

    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_path = backup_file_for(backup_dir, pre_sha)
    backup_path.write_bytes(pre_bytes)

    write_binary_slice(binary_path, FAULT_FILE_OFFSET, bytes.fromhex(EXPECTED_PATCHED_BYTES_LE))

    post_bytes = read_binary_slice(binary_path, FAULT_FILE_OFFSET, PATCH_LENGTH)
    if post_bytes.hex() != EXPECTED_PATCHED_BYTES_LE:
        raise SystemExit(
            f"Patch write verification failed: observed {post_bytes.hex()} but expected {EXPECTED_PATCHED_BYTES_LE}"
        )
    post_sha = sha256_file(binary_path)

    codesign_result = None
    if not skip_codesign:
        codesign_result = codesign_adhoc(binary_path)
        if codesign_result["returncode"] != 0:
            raise SystemExit(
                f"codesign failed after apply: returncode={codesign_result['returncode']} "
                f"stderr={codesign_result['stderr']}"
            )

    return {
        "mode": "apply",
        "state": "applied",
        "binarySha256Pre": pre_sha,
        "binarySha256Post": post_sha,
        "currentBytesHex": post_bytes.hex(),
        "expectedOriginalHex": EXPECTED_ORIGINAL_BYTES_LE,
        "expectedPatchedHex": EXPECTED_PATCHED_BYTES_LE,
        "backupPath": str(backup_path),
        "backupBytesHex": pre_bytes.hex(),
        "codesign": codesign_result,
    }


def run_revert(
    binary_path: Path,
    backup_dir: Path,
    skip_codesign: bool,
) -> dict[str, Any]:
    pre_bytes = read_binary_slice(binary_path, FAULT_FILE_OFFSET, PATCH_LENGTH)
    pre_sha = sha256_file(binary_path)
    if pre_bytes.hex() == EXPECTED_ORIGINAL_BYTES_LE:
        return {
            "mode": "revert",
            "state": "already-original",
            "binarySha256Pre": pre_sha,
            "binarySha256Post": pre_sha,
            "currentBytesHex": pre_bytes.hex(),
            "expectedOriginalHex": EXPECTED_ORIGINAL_BYTES_LE,
            "expectedPatchedHex": EXPECTED_PATCHED_BYTES_LE,
            "codesign": None,
            "message": "Binary already matches the original byte pattern; nothing to revert.",
        }
    if pre_bytes.hex() != EXPECTED_PATCHED_BYTES_LE:
        raise SystemExit(
            f"Refusing to revert: observed bytes {pre_bytes.hex()} at file offset 0x{FAULT_FILE_OFFSET:x} "
            f"do not match expected patched pattern {EXPECTED_PATCHED_BYTES_LE}."
        )

    if not backup_dir.is_dir():
        raise SystemExit(f"No backup directory present: {backup_dir}")
    candidates = sorted(backup_dir.glob("hok-007b-*.bin"))
    if not candidates:
        raise SystemExit(f"No hok-007b backup files found under {backup_dir}")
    backup_path = candidates[-1]
    backup_bytes = backup_path.read_bytes()
    if backup_bytes.hex() != EXPECTED_ORIGINAL_BYTES_LE:
        raise SystemExit(
            f"Backup {backup_path} does not contain the expected original bytes "
            f"({backup_bytes.hex()} vs {EXPECTED_ORIGINAL_BYTES_LE})"
        )

    write_binary_slice(binary_path, FAULT_FILE_OFFSET, backup_bytes)
    post_bytes = read_binary_slice(binary_path, FAULT_FILE_OFFSET, PATCH_LENGTH)
    if post_bytes.hex() != EXPECTED_ORIGINAL_BYTES_LE:
        raise SystemExit(
            f"Revert write verification failed: observed {post_bytes.hex()} but expected {EXPECTED_ORIGINAL_BYTES_LE}"
        )
    post_sha = sha256_file(binary_path)

    codesign_result = None
    if not skip_codesign:
        codesign_result = codesign_adhoc(binary_path)
        if codesign_result["returncode"] != 0:
            raise SystemExit(
                f"codesign failed after revert: returncode={codesign_result['returncode']} "
                f"stderr={codesign_result['stderr']}"
            )

    return {
        "mode": "revert",
        "state": "reverted",
        "binarySha256Pre": pre_sha,
        "binarySha256Post": post_sha,
        "currentBytesHex": post_bytes.hex(),
        "expectedOriginalHex": EXPECTED_ORIGINAL_BYTES_LE,
        "expectedPatchedHex": EXPECTED_PATCHED_BYTES_LE,
        "backupPath": str(backup_path),
        "codesign": codesign_result,
    }


def determine_mode(args: argparse.Namespace) -> str:
    if args.apply:
        return "apply"
    if args.revert:
        return "revert"
    return "dry-run"


def main() -> int:
    args = build_parser().parse_args()
    mode = determine_mode(args)

    callsite_report = load_callsite_report(Path(args.callsite_report).expanduser().resolve())
    overall_pass = bool(((callsite_report.get("checks") or {}).get("overallPass")))
    if not overall_pass:
        raise SystemExit(
            "HOK-007A callsite report does not report overallPass=true; "
            "re-run Scripts/hok007_ngr_callsite_mapper.py before designing a patch."
        )

    binary_path = resolve_binary_path(args.binary_path, callsite_report)
    backup_dir = Path(args.backup_dir).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    plan = build_patch_plan()

    if mode == "dry-run":
        outcome = run_dry_run(binary_path, plan)
    elif mode == "apply":
        outcome = run_apply(binary_path, backup_dir, plan, skip_codesign=args.skip_codesign)
    else:
        outcome = run_revert(binary_path, backup_dir, skip_codesign=args.skip_codesign)

    checks = {
        "planEncodingConsistent": plan["patchedBytesLe"] == EXPECTED_PATCHED_BYTES_LE,
        "binaryAccessible": binary_path.is_file(),
        "callsiteReportOverallPass": overall_pass,
        "observedOriginalBytesMatch": outcome.get("currentBytesHex") == EXPECTED_ORIGINAL_BYTES_LE
        or outcome.get("state") in {"applied", "already-patched"},
        "observedPatchedBytesMatch": outcome.get("currentBytesHex") == EXPECTED_PATCHED_BYTES_LE
        if mode == "apply"
        else outcome.get("currentBytesHex") == EXPECTED_ORIGINAL_BYTES_LE
        if mode == "revert"
        else True,
    }

    report = {
        "schemaVersion": 1,
        "workflow": "hok-007b-ngr-patch-runner",
        "generatedAt": utc_now_iso(),
        "bundleId": DEFAULT_BUNDLE_ID,
        "mode": mode,
        "configuration": {
            "binaryPath": str(binary_path),
            "callsiteReportPath": str(Path(args.callsite_report).expanduser().resolve()),
            "backupDir": str(backup_dir),
            "outputPath": str(output_path),
            "skipCodesign": bool(args.skip_codesign),
        },
        "plan": plan,
        "outcome": outcome,
        "checks": checks,
        "nextStep": {
            "status": "ready-for-live-loop" if outcome.get("state") in {"applied", "already-patched"} else "dry-run-complete",
            "message": (
                "After `--apply` completes, rerun `Scripts/hok004_ngr_startup_runner.py` + "
                "`Scripts/hok006_ngr_lldb_runner.py` to confirm whether the faulting window moved."
            ),
        },
    }
    write_report(output_path, report)

    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
