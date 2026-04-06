from __future__ import annotations

import re
from collections import Counter
from pathlib import Path
from typing import Any


HEX_SOURCE_NAME = re.compile(r"^[0-9A-F]{14,16}$")
RAW_INDEX_HEX_TOKEN_PATTERN = re.compile(rb"(?<![0-9A-F])[0-9A-F]{14,16}(?![0-9A-F])")
INDEX_HASH_PATTERN = re.compile(rb"(?<![0-9A-F])[0-9A-F]{16}(?![0-9A-F])")
BPLIST_HEADER = b"bplist00"



def detect_content_type(data: bytes, first_line: str) -> tuple[bool, str]:
    if data.startswith(BPLIST_HEADER):
        return False, "bplist"

    if first_line.startswith("#include") or first_line.startswith("using "):
        return True, "msl"

    if first_line.startswith("//"):
        content_sample = data[:2048].decode("utf-8", errors="replace")
        is_msl = "metal_stdlib" in content_sample or "PlayTools" in content_sample
        return is_msl, "msl" if is_msl else "comment-text"

    if b"\x00" in data[:512]:
        return False, "binary"

    return False, "text"



def count_hash_lengths(items: list[str]) -> dict[str, int]:
    counts = Counter(len(item) for item in items)
    return {str(length): counts[length] for length in sorted(counts)}



def inspect_gputrace_file(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    size = len(data)
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    first_line = lines[0].strip() if lines else ""
    line_count = len(lines) if lines else (1 if text else 0)
    is_msl, content_type = detect_content_type(data, first_line)

    return {
        "size": size,
        "lines": line_count,
        "firstLine": first_line[:80],
        "isMSL": is_msl,
        "contentType": content_type,
        "hashLength": len(path.name),
    }



def extract_raw_index_hex_tokens_from_bytes(index_data: bytes) -> list[str]:
    return sorted({match.decode("ascii") for match in RAW_INDEX_HEX_TOKEN_PATTERN.findall(index_data)})



def extract_index_hashes_from_bytes(index_data: bytes) -> list[str]:
    return sorted({match.decode("ascii") for match in INDEX_HASH_PATTERN.findall(index_data)})



def extract_raw_index_hex_tokens(gputrace_dir: Path) -> list[str]:
    index_path = gputrace_dir / "index"
    if not index_path.is_file():
        return []
    return extract_raw_index_hex_tokens_from_bytes(index_path.read_bytes())



def extract_index_hashes(gputrace_dir: Path) -> list[str]:
    index_path = gputrace_dir / "index"
    if not index_path.is_file():
        return []
    return extract_index_hashes_from_bytes(index_path.read_bytes())



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

    index_path = gputrace_dir / "index"
    index_data = index_path.read_bytes() if index_path.is_file() else b""
    raw_index_hex_tokens = extract_raw_index_hex_tokens_from_bytes(index_data)
    raw_index_hex_token_set = set(raw_index_hex_tokens)
    index_hashes = extract_index_hashes_from_bytes(index_data)
    referenced_hashes = set(index_hashes)
    valid_msl_hashes = sorted(name for name, file_info in files.items() if file_info["isMSL"])
    non_msl_hashes = sorted(name for name, file_info in files.items() if file_info["isMSL"] is not True)
    referenced_valid_msl_hashes = sorted(name for name in valid_msl_hashes if name in referenced_hashes)
    referenced_non_msl_hashes = sorted(name for name in non_msl_hashes if name in referenced_hashes)
    missing_referenced_hashes = sorted(hash_name for hash_name in index_hashes if hash_name not in files)
    unreferenced_valid_msl_hashes = sorted(name for name in valid_msl_hashes if name not in referenced_hashes)
    unreferenced_non_msl_hashes = sorted(name for name in non_msl_hashes if name not in referenced_hashes)
    noncanonical_visible_hashes = sorted(name for name in files if len(name) != 16)
    noncanonical_visible_hashes_mentioned_in_index = sorted(
        name for name in noncanonical_visible_hashes if name in raw_index_hex_token_set
    )
    raw_index_noncanonical_hashes = sorted(token for token in raw_index_hex_tokens if len(token) != 16)
    index_hash_references = len(index_hashes)
    valid_msl_files = len(valid_msl_hashes)
    source_files = len(files)
    non_msl_files = source_files - valid_msl_files
    coverage_pct = round(len(referenced_valid_msl_hashes) / index_hash_references * 100, 2) if index_hash_references > 0 else 0.0
    non_msl_type_counts = Counter(
        str(file_info.get("contentType") or "unknown")
        for file_info in files.values()
        if file_info["isMSL"] is not True
    )

    return {
        "gputraceName": gputrace_dir.name,
        "sourceFiles": source_files,
        "validMSLFiles": valid_msl_files,
        "nonMSLFiles": non_msl_files,
        "indexHashReferences": index_hash_references,
        "indexHashes": index_hashes,
        "rawIndexHexTokens": raw_index_hex_tokens,
        "validMSLHashes": valid_msl_hashes,
        "nonMSLHashes": non_msl_hashes,
        "referencedValidMSLHashes": referenced_valid_msl_hashes,
        "referencedNonMSLHashes": referenced_non_msl_hashes,
        "missingReferencedHashes": missing_referenced_hashes,
        "unreferencedValidMSLHashes": unreferenced_valid_msl_hashes,
        "unreferencedNonMSLHashes": unreferenced_non_msl_hashes,
        "sourceHashLengthCounts": count_hash_lengths(sorted(files)),
        "indexHashLengthCounts": count_hash_lengths(index_hashes),
        "rawIndexHashLengthCounts": count_hash_lengths(raw_index_hex_tokens),
        "nonCanonicalVisibleHashes": noncanonical_visible_hashes,
        "nonCanonicalVisibleHashesMentionedInIndex": noncanonical_visible_hashes_mentioned_in_index,
        "rawIndexNonCanonicalHashes": raw_index_noncanonical_hashes,
        "nonMSLTypeCounts": {kind: non_msl_type_counts[kind] for kind in sorted(non_msl_type_counts)},
        "coveragePct": coverage_pct,
        "files": files,
    }
