#!/usr/bin/env python3
"""
analyze_reference_gputrace.py — 对 .gputrace 进行精确的 MTSP 记录分析。

重点分析：
1. CU<b>Ut 记录的完整字段布局（源码关联记录）
2. CSuwuw 记录（library/pipeline 注册）
3. CUt 记录（pipeline 标识符）
4. MTSP header 中 size/offset 的含义
5. 对比 unused-device-resources 和 device-resources 中的记录差异

输出：逐条记录的 hex dump + 字段解析报告

用法：
    python3 analyze_reference_gputrace.py /path/to/capture.gputrace [--focus-source]
"""

import os
import sys
import struct
import re
from pathlib import Path
from typing import Optional

# MTSP Magic
MTSP_MAGIC = b"MTSP"


def read_mtsp_header(data: bytes) -> dict:
    """读取 MTSP 16 字节 header"""
    if len(data) < 16:
        return {}
    magic = data[0:4]
    version = struct.unpack_from("<I", data, 4)[0]
    size = struct.unpack_from("<I", data, 8)[0]
    offset = struct.unpack_from("<I", data, 12)[0]
    return {
        "magic": magic.decode("ascii", errors="replace"),
        "version": version,
        "size": size,
        "offset": offset,
        "file_size": len(data),
    }


def hex_dump(data: bytes, start: int = 0, max_bytes: int = 128) -> str:
    """生成对齐的 hex dump"""
    lines = []
    for i in range(0, min(len(data), max_bytes), 16):
        hex_part = " ".join(f"{data[i+j]:02x}" for j in range(min(16, len(data) - i)))
        ascii_part = "".join(
            chr(data[i+j]) if 32 <= data[i+j] < 127 else "."
            for j in range(min(16, len(data) - i))
        )
        lines.append(f"  {start+i:08x}: {hex_part:<48s} {ascii_part}")
    return "\n".join(lines)


def find_all_markers(data: bytes, marker: bytes) -> list[int]:
    """查找所有 marker 出现位置"""
    positions = []
    pos = 0
    while pos < len(data):
        idx = data.find(marker, pos)
        if idx == -1:
            break
        positions.append(idx)
        pos = idx + 1
    return positions


def extract_null_terminated_string(data: bytes, offset: int) -> str:
    """从 offset 开始提取 null 结尾字符串"""
    end = data.find(b"\x00", offset)
    if end == -1:
        end = min(offset + 64, len(data))
    return data[offset:end].decode("ascii", errors="replace")


def analyze_csuwuw_record(data: bytes, file_offset: int, report: list[str]):
    """分析一条 CSuwuw 记录"""
    marker_pos = data.find(b"CSuwuw")
    if marker_pos == -1:
        report.append("    [ERROR] CSuwuw marker not found in record data")
        return

    report.append(f"    Marker 'CSuwuw' at record offset +{marker_pos}")

    # 分析 marker 之后的内容
    # 根据 Dashboard 中的逆向结论：
    # offset+9: device_ptr (8 bytes)
    # offset+17: padding/nulls
    # Then: label string (null-terminated)
    # Then: secondary address (8 bytes)

    remaining = data[marker_pos:]
    report.append(f"    Post-marker hex dump ({len(remaining)} bytes):")
    report.append(hex_dump(remaining, file_offset + marker_pos, max_bytes=80))

    # CSuwuw + \x00\x00\x00 = 9 bytes
    if marker_pos + 9 + 8 <= len(data):
        device_ptr = struct.unpack_from("<Q", data, marker_pos + 9)[0]
        report.append(f"    device_ptr = 0x{device_ptr:x} (at +{marker_pos+9})")

    # Find label string after device_ptr
    str_search_start = marker_pos + 17
    # Skip nulls
    while str_search_start < len(data) and data[str_search_start] == 0:
        str_search_start += 1
    if str_search_start < len(data):
        label = extract_null_terminated_string(data, str_search_start)
        report.append(f"    label = \"{label}\" (at +{str_search_start})")

        # After label: secondary address
        after_label = str_search_start + len(label) + 1
        if after_label + 8 <= len(data):
            sec_addr = struct.unpack_from("<Q", data, after_label)[0]
            report.append(f"    secondary_addr = 0x{sec_addr:x} (at +{after_label})")


def analyze_cu_b_ut_record(data: bytes, file_offset: int, report: list[str]):
    """分析 CU<b>Ut 记录 — 这是源码关联的核心"""
    marker = b"CU<b>Ut"
    marker_pos = data.find(marker)
    if marker_pos == -1:
        report.append("    [ERROR] CU<b>Ut marker not found")
        return

    report.append(f"    Marker 'CU<b>Ut' at record offset +{marker_pos}")

    # 完整记录 hex dump
    report.append(f"    Full record hex dump ({len(data)} bytes):")
    report.append(hex_dump(data, file_offset, max_bytes=min(len(data), 200)))

    # 逐字段分析
    # 根据 Dashboard:
    # offset 0: prefix (4 bytes) — 01 00 00 00 for CU<b>Ut
    # offset 4: tag "CU<b>Ut\0" (8 bytes)
    # offset 12: device_ptr (8 bytes)
    # offset 20: source_hex_id (17 bytes = 16 hex + null)
    # offset 37: stats_hex_id (17 bytes = 16 hex + null)
    # offset 54: padding (6 bytes)
    # offset 60: footer value (4 bytes)
    # offset 64: library_ptr (8 bytes)
    # offset 72: footer value (4 bytes)
    # offset 76: footer value (4 bytes)
    # offset 80+: padding

    report.append("\n    === Field-by-field analysis ===")

    if len(data) >= 4:
        prefix = struct.unpack_from("<I", data, 0)[0]
        report.append(f"    [+0x00] prefix = 0x{prefix:08x} ({prefix})")

    if marker_pos >= 0:
        report.append(f"    [+0x{marker_pos:02x}] tag = 'CU<b>Ut' ({len(marker)} bytes)")

    tag_end = marker_pos + len(marker)
    # Check for null terminator after tag
    if tag_end < len(data) and data[tag_end] == 0:
        tag_end += 1
        report.append(f"    [+0x{marker_pos:02x}] tag with null = {tag_end - marker_pos} bytes")

    # Device ptr after tag
    if tag_end + 8 <= len(data):
        device_ptr = struct.unpack_from("<Q", data, tag_end)[0]
        report.append(f"    [+0x{tag_end:02x}] device_ptr = 0x{device_ptr:x}")

    # Source hex ID after device ptr
    hex_id_start = tag_end + 8
    if hex_id_start + 17 <= len(data):
        source_id = extract_null_terminated_string(data, hex_id_start)
        report.append(f"    [+0x{hex_id_start:02x}] source_hex_id = \"{source_id}\"")

    # Stats hex ID
    stats_id_start = hex_id_start + 17
    if stats_id_start + 17 <= len(data):
        stats_id = extract_null_terminated_string(data, stats_id_start)
        report.append(f"    [+0x{stats_id_start:02x}] stats_hex_id = \"{stats_id}\"")

    # Footer analysis - dump remaining bytes
    footer_start = stats_id_start + 17
    if footer_start < len(data):
        remaining = data[footer_start:]
        report.append(f"    [+0x{footer_start:02x}] footer ({len(remaining)} bytes):")
        # Parse as uint32 values
        for i in range(0, min(len(remaining), 32), 4):
            if i + 4 <= len(remaining):
                val = struct.unpack_from("<I", remaining, i)[0]
                signed_val = struct.unpack_from("<i", remaining, i)[0]
                report.append(f"      [+0x{footer_start+i:02x}] uint32=0x{val:08x} int32={signed_val}")
        # Also check for 8-byte pointers
        for i in range(0, min(len(remaining), 32), 8):
            if i + 8 <= len(remaining):
                ptr = struct.unpack_from("<Q", remaining, i)[0]
                if 0x70000000 <= ptr <= 0x800000000:
                    report.append(f"      [+0x{footer_start+i:02x}] likely_ptr = 0x{ptr:x}")


def analyze_cut_record(data: bytes, file_offset: int, report: list[str]):
    """分析 CUt 记录"""
    marker = b"CUt\x00"
    marker_pos = data.find(marker)
    if marker_pos == -1:
        # Try without null
        marker_pos = data.find(b"CUt")
        if marker_pos == -1:
            report.append("    [ERROR] CUt marker not found")
            return

    report.append(f"    Marker 'CUt' at record offset +{marker_pos}")
    report.append(f"    Full record hex dump ({len(data)} bytes):")
    report.append(hex_dump(data, file_offset, max_bytes=min(len(data), 160)))

    # Fields:
    # prefix (4 bytes) — 01 10 00 00 for CUt
    if len(data) >= 4:
        prefix = struct.unpack_from("<I", data, 0)[0]
        report.append(f"    [+0x00] prefix = 0x{prefix:08x}")

    tag_end = marker_pos + 4  # "CUt\0"
    if tag_end + 8 <= len(data):
        device_ptr = struct.unpack_from("<Q", data, tag_end)[0]
        report.append(f"    [+0x{tag_end:02x}] device_ptr = 0x{device_ptr:x}")

    # Hex ID
    hex_id_start = tag_end + 8
    if hex_id_start < len(data):
        hex_id = extract_null_terminated_string(data, hex_id_start)
        report.append(f"    [+0x{hex_id_start:02x}] pipeline_hex_id = \"{hex_id}\"")

    # Footer
    footer_start = hex_id_start + 17  # 16 hex + null
    if footer_start < len(data):
        remaining = data[footer_start:]
        report.append(f"    [+0x{footer_start:02x}] footer ({len(remaining)} bytes):")
        for i in range(0, min(len(remaining), 40), 4):
            if i + 4 <= len(remaining):
                val = struct.unpack_from("<I", remaining, i)[0]
                signed_val = struct.unpack_from("<i", remaining, i)[0]
                report.append(f"      [+0x{footer_start+i:02x}] uint32=0x{val:08x} int32={signed_val}")
        for i in range(0, min(len(remaining), 40), 8):
            if i + 8 <= len(remaining):
                ptr = struct.unpack_from("<Q", remaining, i)[0]
                if 0x70000000 <= ptr <= 0x800000000:
                    report.append(f"      [+0x{footer_start+i:02x}] likely_ptr = 0x{ptr:x}")


def scan_records(data: bytes, file_name: str, report: list[str], focus_source: bool = False):
    """扫描 MTSP 流中的所有记录"""
    header = read_mtsp_header(data)
    report.append(f"\n{'='*80}")
    report.append(f"FILE: {file_name}")
    report.append(f"{'='*80}")
    report.append(f"  MTSP Header: magic={header.get('magic')}, version={header.get('version')}, "
                  f"size={header.get('size')}, offset={header.get('offset')}")
    report.append(f"  File size: {header.get('file_size')} bytes")
    report.append(f"  Declared size vs file size: {header.get('size')} vs {header.get('file_size')}")

    if data[:4] != MTSP_MAGIC:
        report.append("  [ERROR] Not an MTSP file")
        return

    # 查找关键 marker 位置
    markers_of_interest = {
        b"CSuwuw": "CSuwuw (library/pipeline registration)",
        b"CU<b>Ut": "CU<b>Ut (source code association)",
        b"CUt\x00": "CUt (pipeline identifier)",
        b"CiUul": "CiUul (compile stats association)",
    }

    for marker, desc in markers_of_interest.items():
        positions = find_all_markers(data, marker)
        report.append(f"\n  Marker '{desc}': {len(positions)} occurrences")
        if positions and len(positions) <= 20:
            for pos in positions:
                report.append(f"    at offset 0x{pos:08x}")

    # 精确扫描记录 — 尝试用 record_size 做连续解析
    report.append(f"\n  --- Record Scan (record-by-record) ---")

    offset = 16  # Skip header
    record_idx = 0
    records_by_type: dict[str, list] = {}

    csuwuw_records = []  # 收集 CSuwuw
    cu_b_ut_records = []  # 收集 CU<b>Ut
    cut_records = []  # 收集 CUt

    while offset < len(data) - 4:
        record_size = struct.unpack_from("<I", data, offset)[0]

        # 验证 record_size
        if record_size == 0 or record_size > 0x400000 or offset + record_size > len(data):
            offset += 4
            continue

        record_data = data[offset:offset + record_size]

        # 识别记录类型
        record_type = identify_record_type(record_data)

        if record_type == "unknown":
            offset += 4
            continue

        # 收集记录统计
        if record_type not in records_by_type:
            records_by_type[record_type] = []
        records_by_type[record_type].append((offset, record_size))

        # 重点分析目标记录
        if record_type == "CSuwuw":
            csuwuw_records.append((offset, record_size, record_data))
        elif record_type == "CU<b>Ut":
            cu_b_ut_records.append((offset, record_size, record_data))
        elif record_type == "CUt":
            cut_records.append((offset, record_size, record_data))

        record_idx += 1
        offset += record_size

    # 报告记录类型统计
    report.append(f"\n  Total records parsed: {record_idx}")
    report.append(f"\n  Record type distribution:")
    for rtype, rlist in sorted(records_by_type.items(), key=lambda x: -len(x[1])):
        report.append(f"    {rtype:20s}: {len(rlist):6d} records")

    # 详细分析 CSuwuw 记录
    if csuwuw_records:
        report.append(f"\n  {'='*60}")
        report.append(f"  CSuwuw RECORDS (Library/Pipeline Registration): {len(csuwuw_records)} total")
        report.append(f"  {'='*60}")

        # 只显示前 10 条 + 最后 5 条
        show_records = csuwuw_records[:10]
        if len(csuwuw_records) > 15:
            show_records += csuwuw_records[-5:]
            report.append(f"  (showing first 10 + last 5 of {len(csuwuw_records)})")

        for i, (rec_offset, rec_size, rec_data) in enumerate(show_records):
            report.append(f"\n  --- CSuwuw #{i} at offset 0x{rec_offset:08x}, size={rec_size} ---")
            analyze_csuwuw_record(rec_data, rec_offset, report)

    # 详细分析 CU<b>Ut 记录 (最重要！)
    if cu_b_ut_records:
        report.append(f"\n  {'='*60}")
        report.append(f"  CU<b>Ut RECORDS (SOURCE CODE ASSOCIATION): {len(cu_b_ut_records)} total")
        report.append(f"  {'='*60}")
        report.append("  *** THIS IS THE KEY TO SOURCE CODE INJECTION ***")

        for i, (rec_offset, rec_size, rec_data) in enumerate(cu_b_ut_records):
            report.append(f"\n  --- CU<b>Ut #{i} at offset 0x{rec_offset:08x}, size={rec_size} ---")
            analyze_cu_b_ut_record(rec_data, rec_offset, report)

    # 详细分析 CUt 记录
    if cut_records:
        report.append(f"\n  {'='*60}")
        report.append(f"  CUt RECORDS (Pipeline Identifier): {len(cut_records)} total")
        report.append(f"  {'='*60}")

        show_cut = cut_records[:10]
        if len(cut_records) > 10:
            report.append(f"  (showing first 10 of {len(cut_records)})")

        for i, (rec_offset, rec_size, rec_data) in enumerate(show_cut):
            report.append(f"\n  --- CUt #{i} at offset 0x{rec_offset:08x}, size={rec_size} ---")
            analyze_cut_record(rec_data, rec_offset, report)

    # 查找 CSuwuw "library" + CU<b>Ut 配对
    if csuwuw_records and cu_b_ut_records:
        report.append(f"\n  {'='*60}")
        report.append(f"  CSuwuw + CU<b>Ut RECORD PAIRS (Source-linked libraries)")
        report.append(f"  {'='*60}")

        # 找 CSuwuw label="library" 的记录，看下一条是否是 CU<b>Ut
        for i, (rec_offset, rec_size, rec_data) in enumerate(csuwuw_records):
            marker_pos = rec_data.find(b"CSuwuw")
            if marker_pos == -1:
                continue
            # 提取 label
            str_start = marker_pos + 17
            while str_start < len(rec_data) and rec_data[str_start] == 0:
                str_start += 1
            if str_start < len(rec_data):
                label = extract_null_terminated_string(rec_data, str_start)
                if label == "library":
                    # 检查下一条记录
                    next_offset = rec_offset + rec_size
                    for cu_offset, cu_size, cu_data in cu_b_ut_records:
                        if cu_offset == next_offset:
                            report.append(f"\n  PAIR FOUND: CSuwuw@0x{rec_offset:08x} + CU<b>Ut@0x{cu_offset:08x}")
                            report.append(f"    CSuwuw size={rec_size}, CU<b>Ut size={cu_size}")
                            report.append(f"    Combined size = {rec_size + cu_size}")
                            break


def identify_record_type(data: bytes) -> str:
    """识别记录类型"""
    if len(data) < 8:
        return "unknown"

    # 在前 128 字节内搜索 marker
    search_range = min(len(data), 128)

    # 按优先级检查（长 marker 先检查，避免误匹配）
    checks = [
        (b"CU<b>Ut", "CU<b>Ut"),
        (b"CSuwuw", "CSuwuw"),
        (b"CtU<b>ulul", "CtU"),
        (b"CiUul", "CiUul"),
        (b"C@3ul@3ul", "C@3ul"),
        (b"Ctulul", "Ctulul"),
        (b"Ciulul", "Ciulul"),
        (b"CiulSl", "CiulSl"),
        (b"Culul", "Culul"),
        (b"Cuwuw", "Cuwuw"),
    ]

    for marker, rtype in checks:
        if data.find(marker, 4, search_range) != -1:
            return rtype

    # 短 marker（需要更小心）
    for i in range(4, search_range):
        if i + 4 <= len(data):
            if data[i:i+4] == b"CUt\x00":
                return "CUt"
            if data[i:i+3] == b"Ctt" and (i+3 >= len(data) or data[i+3] == 0):
                return "Ctt"
            if data[i:i+3] == b"Cuw" and (i+3 >= len(data) or data[i+3] == 0):
                return "Cuw"
            if data[i:i+3] == b"Cut" and (i+3 >= len(data) or data[i+3] == 0):
                return "Cut"
            if data[i:i+3] == b"Cul" and (i+3 >= len(data) or data[i+3] not in (ord('u'),)):
                return "Cul"
            if data[i:i+4] == b"CS\x00\x00":
                return "CS"
            if data[i:i+4] == b"Ct\x00\x00":
                return "Ct"
            if data[i:i+4] == b"C\x00\x00\x00":
                return "C"
            if data[i:i+3] == b"Ci\x00":
                return "Ci"
            if data[i:i+3] == b"CU\x00":
                return "CU"

    return "unknown"


def analyze_sidecar_files(gputrace_dir: str, report: list[str]):
    """分析 sidecar 文件（hex ID 文件）"""
    report.append(f"\n{'='*80}")
    report.append("SIDECAR FILES (Source/Stats)")
    report.append(f"{'='*80}")

    sidecar_files = []
    for entry in os.listdir(gputrace_dir):
        full_path = os.path.join(gputrace_dir, entry)
        if not os.path.isfile(full_path):
            continue
        # Check if hex ID filename (16 chars, all hex)
        if len(entry) == 16 and all(c in "0123456789ABCDEFabcdef" for c in entry):
            sidecar_files.append(entry)

    report.append(f"  Found {len(sidecar_files)} sidecar files (hex ID names)")

    for fname in sorted(sidecar_files):
        fpath = os.path.join(gputrace_dir, fname)
        size = os.path.getsize(fpath)
        with open(fpath, "rb") as f:
            first_bytes = f.read(64)

        # Determine type
        if first_bytes.startswith(b"bplist"):
            ftype = "bplist (compile stats)"
        elif b"#include" in first_bytes or b"metal_stdlib" in first_bytes:
            ftype = "metal source"
        elif first_bytes[:4] == b"MTLB":
            ftype = "metallib"
        else:
            ftype = f"unknown (first 4: {first_bytes[:4].hex()})"

        report.append(f"  {fname}: {size:>8d} bytes — {ftype}")

        # If it's source, show first 3 lines
        if "metal source" in ftype:
            text = first_bytes.decode("utf-8", errors="replace")
            lines = text.split("\n")[:3]
            for line in lines:
                report.append(f"    | {line.rstrip()}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} /path/to/capture.gputrace [--focus-source]")
        sys.exit(1)

    gputrace_dir = sys.argv[1]
    focus_source = "--focus-source" in sys.argv

    if not os.path.isdir(gputrace_dir):
        print(f"ERROR: Not a directory: {gputrace_dir}", file=sys.stderr)
        sys.exit(1)

    report: list[str] = []
    report.append("=" * 80)
    report.append("GPUTRACE MTSP BINARY ANALYSIS REPORT")
    report.append(f"Target: {gputrace_dir}")
    report.append("=" * 80)

    # List all files in bundle
    report.append(f"\n--- Bundle Contents ---")
    entries = sorted(os.listdir(gputrace_dir))
    for entry in entries:
        full_path = os.path.join(gputrace_dir, entry)
        if os.path.isdir(full_path):
            report.append(f"  [DIR]  {entry}/")
        else:
            size = os.path.getsize(full_path)
            report.append(f"  [FILE] {entry} ({size:,d} bytes)")

    # Analyze each MTSP file
    mtsp_files = []
    for entry in entries:
        full_path = os.path.join(gputrace_dir, entry)
        if os.path.isfile(full_path) and os.path.getsize(full_path) >= 16:
            with open(full_path, "rb") as f:
                magic = f.read(4)
            if magic == MTSP_MAGIC:
                mtsp_files.append(entry)

    report.append(f"\n  MTSP files found: {len(mtsp_files)}")
    for mf in mtsp_files:
        report.append(f"    - {mf}")

    # Prioritize unused-device-resources (contains CU<b>Ut records)
    priority_order = []
    for mf in mtsp_files:
        if "unused-device-resources" in mf:
            priority_order.insert(0, mf)
        elif "device-resources" in mf and "unused" not in mf and "delta" not in mf:
            priority_order.insert(1 if priority_order else 0, mf)
        else:
            priority_order.append(mf)

    for mf in priority_order:
        full_path = os.path.join(gputrace_dir, mf)
        data = open(full_path, "rb").read()
        scan_records(data, mf, report, focus_source)

    # Analyze sidecar files
    analyze_sidecar_files(gputrace_dir, report)

    # Output report
    output = "\n".join(report)
    print(output)

    # Also save to file
    report_path = os.path.join(gputrace_dir, "_analysis_report.txt")
    with open(report_path, "w") as f:
        f.write(output)
    print(f"\n\n[Report saved to: {report_path}]")


if __name__ == "__main__":
    main()
