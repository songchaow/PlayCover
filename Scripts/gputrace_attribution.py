from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_text_bytes(data: bytes) -> bytes:
    text = data.decode("utf-8", errors="replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.encode("utf-8")


def fingerprint_file(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    normalized = normalize_text_bytes(data)
    return {
        "size": len(data),
        "sha256": sha256_bytes(data),
        "normalizedTextSHA256": sha256_bytes(normalized),
    }


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload if isinstance(payload, dict) else None


def build_generated_source_index(bundle_dir: Path) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    by_sha256: dict[str, list[dict[str, Any]]] = {}
    by_normalized_sha256: dict[str, list[dict[str, Any]]] = {}

    modules_dir = bundle_dir / "modules"
    if modules_dir.is_dir():
        for module_dir in sorted(child for child in modules_dir.iterdir() if child.is_dir()):
            source_path = module_dir / "module.generated.metal"
            if not source_path.is_file():
                continue
            fingerprints = fingerprint_file(source_path)
            entry = {
                "kind": "module",
                "moduleKey": module_dir.name,
                "relativePath": str(source_path.relative_to(bundle_dir)),
                **fingerprints,
            }
            entries.append(entry)
            by_sha256.setdefault(entry["sha256"], []).append(entry)
            by_normalized_sha256.setdefault(entry["normalizedTextSHA256"], []).append(entry)

    replacements_dir = bundle_dir / "replacements"
    if replacements_dir.is_dir():
        for replacement_dir in sorted(child for child in replacements_dir.iterdir() if child.is_dir()):
            source_path = replacement_dir / "aggregate.generated.metal"
            if not source_path.is_file():
                continue
            replacement_meta = load_json(replacement_dir / "replacement.meta.json") or {}
            fingerprints = fingerprint_file(source_path)
            entry = {
                "kind": "replacementAggregate",
                "relativePath": str(source_path.relative_to(bundle_dir)),
                "corpusRelativeDirectory": str(replacement_dir.relative_to(bundle_dir)),
                "moduleKeys": sorted(replacement_meta.get("moduleKeys", []) or []),
                **fingerprints,
            }
            entries.append(entry)
            by_sha256.setdefault(entry["sha256"], []).append(entry)
            by_normalized_sha256.setdefault(entry["normalizedTextSHA256"], []).append(entry)

    return {
        "entries": entries,
        "bySHA256": by_sha256,
        "byNormalizedTextSHA256": by_normalized_sha256,
        "summary": {
            "entryCount": len(entries),
            "moduleGeneratedMetalCount": sum(1 for entry in entries if entry["kind"] == "module"),
            "replacementAggregateCount": sum(1 for entry in entries if entry["kind"] == "replacementAggregate"),
        },
    }


def dedupe_matches(matches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped: dict[tuple[str, str], dict[str, Any]] = {}
    for match in matches:
        key = (str(match.get("kind")), str(match.get("relativePath")))
        existing = deduped.get(key)
        if existing is None:
            copied = dict(match)
            copied["matchKinds"] = sorted(set(match.get("matchKinds", [])))
            deduped[key] = copied
            continue
        existing["matchKinds"] = sorted(set(existing.get("matchKinds", [])) | set(match.get("matchKinds", [])))
    return sorted(deduped.values(), key=lambda item: (str(item.get("kind")), str(item.get("relativePath"))))


def build_gputrace_attribution_for_paths(
    bundle_dir: Path,
    gputrace_dir: Path,
    gputrace_summary: dict[str, Any] | None,
    *,
    gputrace_relative_path: str | None = None,
) -> dict[str, Any] | None:
    if not isinstance(gputrace_summary, dict):
        return None
    if not gputrace_dir.is_dir():
        return None

    source_index = build_generated_source_index(bundle_dir)
    files = gputrace_summary.get("files") if isinstance(gputrace_summary.get("files"), dict) else {}
    visible_files: dict[str, dict[str, Any]] = {}
    attributed_module_keys: set[str] = set()
    attributed_replacement_directories: set[str] = set()
    visible_content_sha256: set[str] = set()

    for file_name, file_info in sorted(files.items()):
        if not isinstance(file_info, dict) or file_info.get("isMSL") is not True:
            continue
        source_path = gputrace_dir / file_name
        if not source_path.is_file():
            continue
        fingerprints = fingerprint_file(source_path)
        visible_content_sha256.add(fingerprints["sha256"])
        raw_matches = [
            {**entry, "matchKinds": ["sha256"]}
            for entry in source_index["bySHA256"].get(fingerprints["sha256"], [])
        ]
        normalized_matches = [
            {**entry, "matchKinds": ["normalizedTextSHA256"]}
            for entry in source_index["byNormalizedTextSHA256"].get(fingerprints["normalizedTextSHA256"], [])
        ]
        matches = dedupe_matches(raw_matches + normalized_matches)

        module_matches = [match for match in matches if match.get("kind") == "module"]
        replacement_matches = [match for match in matches if match.get("kind") == "replacementAggregate"]
        for match in module_matches:
            module_key = match.get("moduleKey")
            if isinstance(module_key, str) and module_key:
                attributed_module_keys.add(module_key)
        for match in replacement_matches:
            corpus_relative_directory = match.get("corpusRelativeDirectory")
            if isinstance(corpus_relative_directory, str) and corpus_relative_directory:
                attributed_replacement_directories.add(corpus_relative_directory)
            for module_key in match.get("moduleKeys", []) or []:
                if isinstance(module_key, str) and module_key:
                    attributed_module_keys.add(module_key)

        visible_files[file_name] = {
            "firstLine": file_info.get("firstLine"),
            "size": file_info.get("size"),
            "lines": file_info.get("lines"),
            **fingerprints,
            "attributed": bool(matches),
            "moduleMatches": module_matches,
            "replacementMatches": replacement_matches,
        }

    attributed_hashes = sorted(
        file_name for file_name, payload in visible_files.items() if payload.get("attributed") is True
    )
    unattributed_hashes = sorted(
        file_name for file_name, payload in visible_files.items() if payload.get("attributed") is not True
    )
    return {
        "schemaVersion": 2,
        "gputraceRelativePath": gputrace_relative_path,
        "gputracePath": str(gputrace_dir),
        "sourceIndexSummary": source_index["summary"],
        "visibleMSLFileCount": len(visible_files),
        "attributedVisibleMSLFileCount": len(attributed_hashes),
        "unattributedVisibleMSLFileCount": len(unattributed_hashes),
        "attributedVisibleMSLHashes": attributed_hashes,
        "unattributedVisibleMSLHashes": unattributed_hashes,
        "attributedModuleKeys": sorted(attributed_module_keys),
        "attributedReplacementDirectories": sorted(attributed_replacement_directories),
        "visibleMSLContentSHA256": sorted(visible_content_sha256),
        "visibleMSLFiles": visible_files,
    }



def build_gputrace_attribution(
    bundle_dir: Path,
    gputrace_relative_path: str | None,
    gputrace_summary: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if not gputrace_relative_path:
        return None

    gputrace_dir = bundle_dir / gputrace_relative_path
    return build_gputrace_attribution_for_paths(
        bundle_dir,
        gputrace_dir,
        gputrace_summary,
        gputrace_relative_path=gputrace_relative_path,
    )
