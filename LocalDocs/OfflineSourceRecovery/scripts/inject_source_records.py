#!/usr/bin/env python3
"""
inject_source_records.py — 向 .gputrace 的 unused-device-resources 中注入
CSuwuw "library" + CU<b>Ut 记录对，使 Xcode 能够显示注入的 shader 源码。

基于对 MTSP 二进制格式的完整逆向工程。

记录格式：
  CSuwuw "library" (76 bytes):
    +0x00: record_size (uint32) = 76
    +0x04: flags (uint32) = 0xffffd007
    +0x08: zeros (24 bytes)
    +0x20: inner_size (uint32) = 70 (0x46)
    +0x24: "CSuwuw\0\0" (8 bytes)
    +0x2c: device_ptr (uint64)
    +0x34: "library\0" (8 bytes)
    +0x3c: library_ptr (uint64)
    +0x44: zeros (8 bytes)

  CU<b>Ut (108 bytes):
    +0x00: record_size (uint32) = 108
    +0x04: flags (uint32) = 0xffffc04f
    +0x08: zeros (24 bytes)
    +0x20: prefix (uint32) = 1
    +0x24: "CU<b>Ut\0" (8 bytes)
    +0x2c: device_ptr (uint64)
    +0x34: source_hex_id (17 bytes, null-terminated)
    +0x45: stats_hex_id (17 bytes, null-terminated)
    +0x56: zeros (10 bytes)
    +0x60: footer_magic (uint32) = 0x74
    +0x64: library_ptr (uint64)
    +0x6c: END

用法:
    python3 inject_source_records.py \\
        --gputrace /path/to/capture.gputrace \\
        --source-file /path/to/shader_source.metal \\
        --library-ptr 0x7b12cd8c0 \\
        [--device-ptr 0x7991e1800] \\
        [--dry-run]

    或批量模式:
    python3 inject_source_records.py \\
        --gputrace /path/to/capture.gputrace \\
        --batch-json /path/to/injection_plan.json \\
        [--dry-run]
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import shutil
from pathlib import Path
from typing import Optional


def parse_args():
    parser = argparse.ArgumentParser(description="Inject shader source records into .gputrace")
    parser.add_argument("--gputrace", required=True, help="Path to .gputrace bundle")
    parser.add_argument("--source-file", help="Path to shader source .metal file")
    parser.add_argument("--source-text", help="Inline shader source text")
    parser.add_argument("--library-ptr", help="Library pointer (hex, e.g. 0x7b12cd8c0)")
    parser.add_argument("--device-ptr", help="Device pointer (hex, auto-detected if omitted)")
    parser.add_argument("--batch-json", help="Batch injection plan JSON file")
    parser.add_argument("--dry-run", action="store_true", help="Don't modify files")
    parser.add_argument("--no-backup", action="store_true", help="Don't create backup")
    parser.add_argument("--stats-file", help="Optional bplist compile stats file to include")
    return parser.parse_args()


def generate_hex_id(content: str) -> str:
    """Generate a 16-char uppercase hex ID from content hash."""
    h = hashlib.sha256(content.encode('utf-8')).hexdigest().upper()
    return h[:16]


def detect_device_ptr(gputrace_dir: str) -> Optional[int]:
    """Auto-detect device pointer from file names."""
    for entry in os.listdir(gputrace_dir):
        if entry.startswith("device-resources-0x"):
            addr_str = entry.replace("device-resources-", "")
            return int(addr_str, 16)
    return None


def build_csuwuw_library_record(device_ptr: int, library_ptr: int) -> bytes:
    """Build a 76-byte CSuwuw 'library' record (Format A with 32-byte header)."""
    record = bytearray(76)
    
    # Header (32 bytes)
    struct.pack_into('<I', record, 0x00, 76)           # record_size
    struct.pack_into('<I', record, 0x04, 0xffffd007)   # flags (observed constant)
    # +0x08 to +0x1f: zeros (already zeroed)
    
    # Content (44 bytes)
    struct.pack_into('<I', record, 0x20, 0x46)         # inner_size = 70
    record[0x24:0x2c] = b'CSuwuw\x00\x00'             # tag (8 bytes)
    struct.pack_into('<Q', record, 0x2c, device_ptr)   # device_ptr
    record[0x34:0x3c] = b'library\x00'                 # label (8 bytes)
    struct.pack_into('<Q', record, 0x3c, library_ptr)  # library_ptr
    # +0x44 to +0x4b: zeros (already zeroed)
    
    return bytes(record)


def build_cu_b_ut_record(device_ptr: int, library_ptr: int,
                         source_hex_id: str, stats_hex_id: str) -> bytes:
    """Build a 108-byte CU<b>Ut record (Format A with 32-byte header)."""
    record = bytearray(108)
    
    # Header (32 bytes)
    struct.pack_into('<I', record, 0x00, 108)          # record_size
    struct.pack_into('<I', record, 0x04, 0xffffc04f)   # flags (observed constant)
    # +0x08 to +0x1f: zeros (already zeroed)
    
    # Content
    struct.pack_into('<I', record, 0x20, 1)            # prefix = 1
    record[0x24:0x2c] = b'CU<b>Ut\x00'               # tag (8 bytes: 7 chars + null)
    struct.pack_into('<Q', record, 0x2c, device_ptr)   # device_ptr
    
    # Source hex ID (16 chars + null = 17 bytes)
    src_bytes = source_hex_id.encode('ascii') + b'\x00'
    assert len(src_bytes) == 17, f"source_hex_id must be 16 chars, got {len(source_hex_id)}"
    record[0x34:0x45] = src_bytes
    
    # Stats hex ID (16 chars + null = 17 bytes)
    stats_bytes = stats_hex_id.encode('ascii') + b'\x00'
    assert len(stats_bytes) == 17, f"stats_hex_id must be 16 chars, got {len(stats_hex_id)}"
    record[0x45:0x56] = stats_bytes
    
    # +0x56 to +0x5f: zeros (10 bytes, already zeroed)
    
    # Footer
    struct.pack_into('<I', record, 0x60, 0x74)         # footer_magic (observed constant)
    struct.pack_into('<Q', record, 0x64, library_ptr)  # library_ptr
    
    return bytes(record)


def find_unused_device_resources(gputrace_dir: str) -> Optional[str]:
    """Find the unused-device-resources file in the bundle."""
    for entry in os.listdir(gputrace_dir):
        if entry.startswith("unused-device-resources-"):
            return os.path.join(gputrace_dir, entry)
    return None


def inject_single(gputrace_dir: str, source_text: str, library_ptr: int,
                  device_ptr: int, stats_content: Optional[bytes] = None,
                  dry_run: bool = False) -> dict:
    """Inject a single shader source into the gputrace bundle.
    
    Returns dict with hex IDs and status.
    """
    # Generate hex IDs
    source_hex_id = generate_hex_id(source_text)
    
    # Generate a different hex ID for stats (use a salt)
    if stats_content:
        stats_hex_id = hashlib.sha256(stats_content).hexdigest().upper()[:16]
    else:
        stats_hex_id = generate_hex_id(f"__stats__{source_text[:100]}")
    
    # Ensure IDs are unique (check for existing files)
    source_path = os.path.join(gputrace_dir, source_hex_id)
    stats_path = os.path.join(gputrace_dir, stats_hex_id)
    
    # If source file already exists with same content, skip
    if os.path.exists(source_path):
        existing = open(source_path, 'r', encoding='utf-8', errors='replace').read()
        if existing == source_text:
            return {"status": "already_exists", "source_id": source_hex_id}
    
    # Build records
    csuwuw_record = build_csuwuw_library_record(device_ptr, library_ptr)
    cu_b_ut_record = build_cu_b_ut_record(device_ptr, library_ptr, source_hex_id, stats_hex_id)
    
    result = {
        "status": "injected",
        "source_id": source_hex_id,
        "stats_id": stats_hex_id,
        "library_ptr": f"0x{library_ptr:x}",
        "device_ptr": f"0x{device_ptr:x}",
        "csuwuw_size": len(csuwuw_record),
        "cu_b_ut_size": len(cu_b_ut_record),
    }
    
    if dry_run:
        result["status"] = "dry_run"
        print(f"  [DRY RUN] Would inject: source={source_hex_id}, stats={stats_hex_id}")
        print(f"            library_ptr=0x{library_ptr:x}")
        print(f"            CSuwuw record: {len(csuwuw_record)} bytes")
        print(f"            CU<b>Ut record: {len(cu_b_ut_record)} bytes")
        return result
    
    # Find unused-device-resources file
    udr_path = find_unused_device_resources(gputrace_dir)
    if not udr_path:
        result["status"] = "error"
        result["error"] = "unused-device-resources file not found"
        return result
    
    # Append records to unused-device-resources
    with open(udr_path, 'ab') as f:
        f.write(csuwuw_record)
        f.write(cu_b_ut_record)
    
    # Write source sidecar file
    with open(source_path, 'w', encoding='utf-8') as f:
        f.write(source_text)
    
    # Write stats sidecar file (minimal bplist or empty marker)
    if stats_content:
        with open(stats_path, 'wb') as f:
            f.write(stats_content)
    else:
        # Create a minimal placeholder
        # Xcode seems to tolerate missing stats files gracefully
        # But we create an empty one just in case
        pass  # Don't create stats file if we don't have real data
    
    return result


def main():
    args = parse_args()
    gputrace_dir = os.path.expanduser(args.gputrace)
    
    if not os.path.isdir(gputrace_dir):
        print(f"ERROR: Not a directory: {gputrace_dir}", file=sys.stderr)
        return 1
    
    # Auto-detect device pointer
    if args.device_ptr:
        device_ptr = int(args.device_ptr, 16)
    else:
        device_ptr = detect_device_ptr(gputrace_dir)
        if device_ptr is None:
            print("ERROR: Could not detect device pointer. Use --device-ptr.", file=sys.stderr)
            return 1
        print(f"Auto-detected device pointer: 0x{device_ptr:x}")
    
    # Create backup
    if not args.dry_run and not args.no_backup:
        udr_path = find_unused_device_resources(gputrace_dir)
        if udr_path:
            backup_path = udr_path + ".bak"
            if not os.path.exists(backup_path):
                shutil.copy2(udr_path, backup_path)
                print(f"Backup created: {backup_path}")
    
    # Batch mode
    if args.batch_json:
        plan = json.load(open(args.batch_json))
        entries = plan if isinstance(plan, list) else plan.get("injections", [])
        
        print(f"\nBatch injection: {len(entries)} entries")
        results = []
        for i, entry in enumerate(entries):
            lib_ptr = int(entry["library_ptr"], 16)
            source_text = entry.get("source_text", "")
            if not source_text and "source_file" in entry:
                source_text = open(entry["source_file"], 'r').read()
            
            stats_content = None
            if "stats_file" in entry and os.path.exists(entry["stats_file"]):
                stats_content = open(entry["stats_file"], 'rb').read()
            
            result = inject_single(
                gputrace_dir, source_text, lib_ptr, device_ptr,
                stats_content=stats_content,
                dry_run=args.dry_run
            )
            results.append(result)
            
            if i < 5 or (i + 1) % 20 == 0:
                print(f"  [{i+1}/{len(entries)}] {result['status']}: source={result['source_id']}")
        
        injected = sum(1 for r in results if r["status"] == "injected")
        print(f"\nDone: {injected} injected, "
              f"{sum(1 for r in results if r['status'] == 'already_exists')} already existed, "
              f"{sum(1 for r in results if r['status'] == 'error')} errors")
        
        return 0
    
    # Single mode
    if not args.library_ptr:
        print("ERROR: --library-ptr required in single mode", file=sys.stderr)
        return 1
    
    library_ptr = int(args.library_ptr, 16)
    
    # Get source text
    if args.source_file:
        source_text = open(args.source_file, 'r', encoding='utf-8').read()
    elif args.source_text:
        source_text = args.source_text
    else:
        print("ERROR: --source-file or --source-text required", file=sys.stderr)
        return 1
    
    stats_content = None
    if args.stats_file and os.path.exists(args.stats_file):
        stats_content = open(args.stats_file, 'rb').read()
    
    result = inject_single(
        gputrace_dir, source_text, library_ptr, device_ptr,
        stats_content=stats_content,
        dry_run=args.dry_run
    )
    
    print(f"\nResult: {json.dumps(result, indent=2)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
