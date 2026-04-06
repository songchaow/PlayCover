from __future__ import annotations

import re
from pathlib import Path
from typing import Any


HEX_SOURCE_NAME = re.compile(r"^[0-9A-F]{16}$")


def inspect_gputrace_file(path: Path) -> dict[str, Any]:
    size = path.stat().st_size
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            first_line = handle.readline().strip()
            line_count = 1 + sum(1 for _ in handle)
    except OSError:
        first_line = "<binary>"
        line_count = 0

    if first_line.startswith("#include") or first_line.startswith("using "):
        is_msl = True
    elif first_line.startswith("//"):
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                content_sample = handle.read(2048)
            is_msl = "metal_stdlib" in content_sample or "PlayTools" in content_sample
        except OSError:
            is_msl = False
    else:
        is_msl = False

    return {
        "size": size,
        "lines": line_count,
        "firstLine": first_line[:80],
        "isMSL": is_msl,
    }



def count_index_hashes(gputrace_dir: Path) -> int:
    index_path = gputrace_dir / "index"
    if not index_path.is_file():
        return -1
    index_data = index_path.read_bytes()
    return len(set(re.findall(rb"[0-9A-F]{16}", index_data)))



def inspect_gputrace_dir(gputrace_dir: Path) -> dict[str, Any]:
    if not gputrace_dir.is_dir():
        raise SystemExit(f"gputrace directory not found: {gputrace_dir}")

    files: dict[str, dict[str, Any]] = {}
    for child in sorted(gputrace_dir.iterdir()):
        if not child.is_file() or not HEX_SOURCE_NAME.match(child.name):
            continue
        files[child.name] = inspect_gputrace_file(child)

    index_hash_references = count_index_hashes(gputrace_dir)
    valid_msl_files = sum(1 for file_info in files.values() if file_info["isMSL"])
    source_files = len(files)
    non_msl_files = source_files - valid_msl_files
    coverage_pct = round(valid_msl_files / index_hash_references * 100, 2) if index_hash_references > 0 else 0.0

    return {
        "gputraceName": gputrace_dir.name,
        "sourceFiles": source_files,
        "validMSLFiles": valid_msl_files,
        "nonMSLFiles": non_msl_files,
        "indexHashReferences": index_hash_references,
        "coveragePct": coverage_pct,
        "files": files,
    }
