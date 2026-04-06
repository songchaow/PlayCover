from __future__ import annotations

import re
from pathlib import Path
from typing import Any


HEX_SOURCE_NAME = re.compile(r"^[0-9A-F]{16}$")
INDEX_HASH_PATTERN = re.compile(rb"[0-9A-F]{16}")


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



def extract_index_hashes(gputrace_dir: Path) -> list[str]:
    index_path = gputrace_dir / "index"
    if not index_path.is_file():
        return []
    index_data = index_path.read_bytes()
    return sorted({match.decode("ascii") for match in INDEX_HASH_PATTERN.findall(index_data)})



def count_index_hashes(gputrace_dir: Path) -> int:
    return len(extract_index_hashes(gputrace_dir))



def inspect_gputrace_dir(gputrace_dir: Path) -> dict[str, Any]:
    if not gputrace_dir.is_dir():
        raise SystemExit(f"gputrace directory not found: {gputrace_dir}")

    files: dict[str, dict[str, Any]] = {}
    for child in sorted(gputrace_dir.iterdir()):
        if not child.is_file() or not HEX_SOURCE_NAME.match(child.name):
            continue
        files[child.name] = inspect_gputrace_file(child)

    index_hashes = extract_index_hashes(gputrace_dir)
    referenced_hashes = set(index_hashes)
    valid_msl_hashes = sorted(name for name, file_info in files.items() if file_info["isMSL"])
    non_msl_hashes = sorted(name for name, file_info in files.items() if file_info["isMSL"] is not True)
    referenced_valid_msl_hashes = sorted(name for name in valid_msl_hashes if name in referenced_hashes)
    referenced_non_msl_hashes = sorted(name for name in non_msl_hashes if name in referenced_hashes)
    missing_referenced_hashes = sorted(hash_name for hash_name in index_hashes if hash_name not in files)
    unreferenced_valid_msl_hashes = sorted(name for name in valid_msl_hashes if name not in referenced_hashes)
    unreferenced_non_msl_hashes = sorted(name for name in non_msl_hashes if name not in referenced_hashes)
    index_hash_references = len(index_hashes)
    valid_msl_files = len(valid_msl_hashes)
    source_files = len(files)
    non_msl_files = source_files - valid_msl_files
    coverage_pct = round(len(referenced_valid_msl_hashes) / index_hash_references * 100, 2) if index_hash_references > 0 else 0.0

    return {
        "gputraceName": gputrace_dir.name,
        "sourceFiles": source_files,
        "validMSLFiles": valid_msl_files,
        "nonMSLFiles": non_msl_files,
        "indexHashReferences": index_hash_references,
        "indexHashes": index_hashes,
        "validMSLHashes": valid_msl_hashes,
        "nonMSLHashes": non_msl_hashes,
        "referencedValidMSLHashes": referenced_valid_msl_hashes,
        "referencedNonMSLHashes": referenced_non_msl_hashes,
        "missingReferencedHashes": missing_referenced_hashes,
        "unreferencedValidMSLHashes": unreferenced_valid_msl_hashes,
        "unreferencedNonMSLHashes": unreferenced_non_msl_hashes,
        "coveragePct": coverage_pct,
        "files": files,
    }
