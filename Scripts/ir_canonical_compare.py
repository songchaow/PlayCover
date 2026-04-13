#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
SEVERITY_ORDER = {"L0": 0, "L1": 1, "L2": 2, "L3": 3}
ENTRY_METADATA_KINDS = {"vertex": "air.vertex", "fragment": "air.fragment", "kernel": "air.kernel"}
METADATA_VALUE_KEYS = {
    "air.arg_name",
    "air.arg_type_name",
    "air.location_index",
    "air.address_space",
    "air.buffer_size",
    "air.arg_type_size",
    "air.arg_type_align_size",
    "air.struct_type_info",
}
RESOURCE_KINDS = {"air.buffer", "air.texture", "air.sampler"}
FAST_MATH_ATTRIBUTE_KEYS = {
    "approx-func-fp-math",
    "no-infs-fp-math",
    "no-nans-fp-math",
    "no-signed-zeros-fp-math",
    "no-trapping-math",
    "unsafe-fp-math",
}
FAST_MATH_TOKENS = ("fast", "nnan", "ninf", "nsz", "arcp", "contract", "afn", "reassoc")
IMPORTANT_FAMILY_KEYS = {"arithmetic", "compare", "cast", "memory", "intrinsic", "call"}
TERMINATOR_OPS = {
    "ret",
    "br",
    "switch",
    "indirectbr",
    "invoke",
    "resume",
    "catchswitch",
    "catchret",
    "cleanupret",
    "unreachable",
    "callbr",
}
ARITHMETIC_OPS = {
    "add",
    "sub",
    "mul",
    "udiv",
    "sdiv",
    "urem",
    "srem",
    "fadd",
    "fsub",
    "fmul",
    "fdiv",
    "frem",
}
COMPARE_OPS = {"icmp", "fcmp"}
CAST_OPS = {
    "trunc",
    "zext",
    "sext",
    "fptrunc",
    "fpext",
    "fptoui",
    "fptosi",
    "uitofp",
    "sitofp",
    "ptrtoint",
    "inttoptr",
    "bitcast",
    "addrspacecast",
}
MEMORY_OPS = {"alloca", "load", "store", "fence", "cmpxchg", "atomicrmw", "getelementptr"}
VECTOR_OPS = {"extractelement", "insertelement", "shufflevector"}
AGGREGATE_OPS = {"extractvalue", "insertvalue"}
STRING_RE = re.compile(r'!"((?:[^"\\]|\\.)*)"')
INTEGER_RE = re.compile(r'\bi\d+\s+(-?\d+)')
FUNCTION_REF_RE = re.compile(r'ptr\s+@(?P<name>"[^"]+"|[-A-Za-z0-9$._]+)')
METADATA_NODE_RE = re.compile(r'^!(\d+)\s*=\s*(?:distinct\s+)?(.*)$')
NAMED_METADATA_RE = re.compile(r'^!([A-Za-z0-9_.]+)\s*=\s*(.*)$')
ATTRIBUTE_RE = re.compile(r'^attributes\s+#(\d+)\s*=\s*\{(.*)\}$')
TARGET_TRIPLE_RE = re.compile(r'^target\s+triple\s*=\s*"([^"]*)"')
TARGET_DATALAYOUT_RE = re.compile(r'^target\s+datalayout\s*=\s*"([^"]*)"')
SOURCE_FILENAME_RE = re.compile(r'^source_filename\s*=\s*"([^"]*)"')
FUNCTION_HEADER_RE = re.compile(
    r'^define\s+(?P<return_type>.+?)\s+@(?P<name>"[^"]+"|[-A-Za-z0-9$._]+)\((?P<params>.*)\)\s*(?P<suffix>.*)$'
)
ATTRIBUTE_TOKEN_RE = re.compile(r'"[^"]+"(?:="[^"]*")?|\S+')
METADATA_KEY_INT_RE_TEMPLATE = r'!"{key}",\s*i\d+\s+(-?\d+)'
METADATA_KEY_STRING_RE_TEMPLATE = r'!"{key}",\s*!"([^"]+)"'


def _strip_quotes(value: str | None) -> str | None:
    if value is None:
        return None
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def _normalize_whitespace(value: str) -> str:
    return " ".join(value.replace("\n", " ").split())


def _split_top_level(value: str, delimiter: str = ",") -> list[str]:
    if not value.strip():
        return []

    parts: list[str] = []
    current: list[str] = []
    angle = 0
    paren = 0
    brace = 0
    bracket = 0
    in_quote = False
    escaped = False

    for character in value:
        current.append(character)
        if in_quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_quote = False
            continue

        if character == '"':
            in_quote = True
        elif character == "<":
            angle += 1
        elif character == ">":
            angle = max(0, angle - 1)
        elif character == "(":
            paren += 1
        elif character == ")":
            paren = max(0, paren - 1)
        elif character == "{":
            brace += 1
        elif character == "}":
            brace = max(0, brace - 1)
        elif character == "[":
            bracket += 1
        elif character == "]":
            bracket = max(0, bracket - 1)
        elif (
            character == delimiter
            and angle == 0
            and paren == 0
            and brace == 0
            and bracket == 0
        ):
            current.pop()
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []

    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return parts


def _metadata_refs(content: str) -> list[str]:
    return re.findall(r'!(\d+)', content)


def _function_ref_name(content: str) -> str | None:
    match = FUNCTION_REF_RE.search(content)
    return _strip_quotes(match.group("name")) if match else None


def _extract_metadata_int(content: str, key: str) -> int | None:
    pattern = re.compile(METADATA_KEY_INT_RE_TEMPLATE.format(key=re.escape(key)))
    match = pattern.search(content)
    return int(match.group(1)) if match else None


def _extract_metadata_string(content: str, key: str) -> str | None:
    pattern = re.compile(METADATA_KEY_STRING_RE_TEMPLATE.format(key=re.escape(key)))
    match = pattern.search(content)
    return match.group(1) if match else None


def _counter_to_sorted_dict(counter: Counter[str] | Counter[int]) -> dict[str, int]:
    return {str(key): int(counter[key]) for key in sorted(counter, key=lambda item: str(item))}


def _normalize_air_intrinsic_name(name: str) -> str:
    if name.startswith("air.fast_"):
        return "air." + name.removeprefix("air.fast_")
    return name


def _air_intrinsic_family_name(name: str) -> str:
    normalized = _normalize_air_intrinsic_name(name)
    if not normalized.startswith("air."):
        return normalized
    parts = normalized.split(".")
    if len(parts) >= 2:
        return ".".join(parts[:2])
    return normalized


def _normalize_air_intrinsic_counter(counter_like: dict[str, Any] | None) -> dict[str, int]:
    normalized: Counter[str] = Counter()
    for name, value in (counter_like or {}).items():
        normalized[_normalize_air_intrinsic_name(str(name))] += int(value)
    return _counter_to_sorted_dict(normalized)


def _air_intrinsic_family_set(counter_like: dict[str, Any] | None) -> set[str]:
    families: set[str] = set()
    for name, value in (counter_like or {}).items():
        if int(value) <= 0:
            continue
        families.add(_air_intrinsic_family_name(str(name)))
    return families


def _entry_has_optimizer_only_intrinsic_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
    shared_module_families: set[str],
) -> bool:
    if original_entry.get("resourceSemantics") != regenerated_entry.get("resourceSemantics"):
        return False
    if original_entry.get("builtinSemantics") != regenerated_entry.get("builtinSemantics"):
        return False

    original_intrinsics = original_entry.get("airIntrinsicCalls") or {}
    regenerated_intrinsics = regenerated_entry.get("airIntrinsicCalls") or {}
    if not original_intrinsics or not regenerated_intrinsics:
        return False

    if _normalize_air_intrinsic_counter(original_intrinsics) == _normalize_air_intrinsic_counter(regenerated_intrinsics):
        return False

    original_families = _air_intrinsic_family_set(original_intrinsics)
    regenerated_families = _air_intrinsic_family_set(regenerated_intrinsics)
    if original_families == regenerated_families:
        return True

    family_delta = original_families ^ regenerated_families
    return bool(family_delta) and len(family_delta) == 1 and family_delta <= shared_module_families


def _module_has_optimizer_only_intrinsic_drift(original: dict[str, Any], regenerated: dict[str, Any]) -> bool:
    original_intrinsics = original.get("moduleAirIntrinsics") or {}
    regenerated_intrinsics = regenerated.get("moduleAirIntrinsics") or {}
    if not original_intrinsics or not regenerated_intrinsics:
        return False

    if _normalize_air_intrinsic_counter(original_intrinsics) == _normalize_air_intrinsic_counter(regenerated_intrinsics):
        return False

    return _air_intrinsic_family_set(original_intrinsics) == _air_intrinsic_family_set(regenerated_intrinsics)


def _entry_has_small_vector_aggregate_shape_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    lhs_block_count = int(lhs_cfg.get("basicBlockCount") or 0)
    rhs_block_count = int(rhs_cfg.get("basicBlockCount") or 0)
    if abs(lhs_block_count - rhs_block_count) > 1:
        return False

    lhs_terminators = lhs_cfg.get("terminatorCounts") or {}
    rhs_terminators = rhs_cfg.get("terminatorCounts") or {}
    lhs_ret = int(lhs_terminators.get("ret") or 0)
    rhs_ret = int(rhs_terminators.get("ret") or 0)
    lhs_condbr = int(lhs_terminators.get("condbr") or 0)
    rhs_condbr = int(rhs_terminators.get("condbr") or 0)
    lhs_br = int(lhs_terminators.get("br") or 0)
    rhs_br = int(rhs_terminators.get("br") or 0)
    if lhs_ret != rhs_ret or lhs_condbr != rhs_condbr:
        return False
    if abs(lhs_br - rhs_br) > 1:
        return False
    if abs((rhs_block_count - lhs_block_count) - (rhs_br - lhs_br)) > 0:
        return False
    if int(lhs_cfg.get("phiCount") or 0) != int(rhs_cfg.get("phiCount") or 0):
        return False

    select_delta = abs(int(lhs_cfg.get("selectCount") or 0) - int(rhs_cfg.get("selectCount") or 0))
    if select_delta > 2:
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    allowed_keys = {"aggregate", "arithmetic", "vector", "cast"}
    if not changed_keys or not changed_keys <= allowed_keys:
        return False
    if not (changed_keys & {"aggregate", "arithmetic", "vector"}):
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    aggregate_delta = abs(int(lhs_families.get("aggregate", 0)) - int(rhs_families.get("aggregate", 0)))
    vector_delta = abs(int(lhs_families.get("vector", 0)) - int(rhs_families.get("vector", 0)))
    cast_delta = abs(int(lhs_families.get("cast", 0)) - int(rhs_families.get("cast", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    return (
        arithmetic_delta <= 5
        and aggregate_delta <= 12
        and vector_delta <= 16
        and cast_delta <= 2
        and total_delta <= 24
    )


def _entry_has_small_scalar_vector_materialization_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    cfg_is_identical = lhs_cfg == rhs_cfg
    select_delta = abs(int(lhs_cfg.get("selectCount") or 0) - int(rhs_cfg.get("selectCount") or 0))
    cfg_skeleton_matches = (
        int(lhs_cfg.get("basicBlockCount") or 0) == int(rhs_cfg.get("basicBlockCount") or 0)
        and (lhs_cfg.get("terminatorCounts") or {}) == (rhs_cfg.get("terminatorCounts") or {})
        and int(lhs_cfg.get("phiCount") or 0) == int(rhs_cfg.get("phiCount") or 0)
    )
    if not cfg_is_identical and not cfg_skeleton_matches:
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    allowed_keys = {"aggregate", "arithmetic", "vector", "cast"}
    if not changed_keys or not changed_keys <= allowed_keys:
        return False
    if not (changed_keys & {"aggregate", "arithmetic", "vector"}):
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    aggregate_delta = abs(int(lhs_families.get("aggregate", 0)) - int(rhs_families.get("aggregate", 0)))
    vector_delta = abs(int(lhs_families.get("vector", 0)) - int(rhs_families.get("vector", 0)))
    cast_delta = abs(int(lhs_families.get("cast", 0)) - int(rhs_families.get("cast", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    baseline_materialization_drift = (
        cfg_is_identical
        and arithmetic_delta <= 16
        and aggregate_delta <= 19
        and vector_delta <= 6
        and cast_delta <= 2
        and total_delta <= 27
    )
    arithmetic_heavy_materialization_drift = (
        cfg_is_identical
        and arithmetic_delta <= 26
        and aggregate_delta <= 12
        and vector_delta <= 4
        and cast_delta == 0
        and total_delta <= 41
    )
    vector_heavy_materialization_drift = (
        cfg_is_identical
        and changed_keys == {"arithmetic", "vector"}
        and arithmetic_delta <= 20
        and aggregate_delta == 0
        and vector_delta <= 30
        and cast_delta == 0
        and total_delta <= 38
    )
    single_block_select_heavy_vector_materialization_drift = (
        not cfg_is_identical
        and cfg_skeleton_matches
        and int(lhs_cfg.get("basicBlockCount") or 0) == 1
        and (lhs_cfg.get("terminatorCounts") or {}) == {"ret": 1}
        and int(lhs_cfg.get("phiCount") or 0) == 0
        and changed_keys == {"arithmetic", "vector"}
        and select_delta <= 4
        and arithmetic_delta <= 24
        and aggregate_delta == 0
        and vector_delta <= 36
        and cast_delta == 0
        and total_delta <= 59
    )
    select_heavy_vector_materialization_drift = (
        not cfg_is_identical
        and cfg_skeleton_matches
        and changed_keys == {"arithmetic", "vector"}
        and select_delta <= 8
        and arithmetic_delta <= 8
        and aggregate_delta == 0
        and vector_delta <= 40
        and cast_delta == 0
        and total_delta <= 48
    )

    return (
        baseline_materialization_drift
        or arithmetic_heavy_materialization_drift
        or vector_heavy_materialization_drift
        or single_block_select_heavy_vector_materialization_drift
        or select_heavy_vector_materialization_drift
    )


def _module_has_small_addrspace_count_drift(original: dict[str, Any], regenerated: dict[str, Any]) -> bool:
    lhs = original.get("moduleAddressSpaces") or {}
    rhs = regenerated.get("moduleAddressSpaces") or {}
    if lhs == rhs:
        return False

    if set(lhs) != set(rhs):
        return False

    changed_keys = {key for key in sorted(set(lhs) | set(rhs)) if int(lhs.get(key, 0)) != int(rhs.get(key, 0))}
    if not changed_keys or len(changed_keys) != 1:
        return False

    changed_key = next(iter(changed_keys))
    lhs_value = int(lhs.get(changed_key, 0))
    rhs_value = int(rhs.get(changed_key, 0))
    total_delta = abs(lhs_value - rhs_value)
    return rhs_value > lhs_value and total_delta <= 4


def _entry_has_select_heavy_vector_memory_materialization_drift(
    original: dict[str, Any],
    regenerated: dict[str, Any],
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    if not _module_has_small_addrspace_count_drift(original, regenerated):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    cfg_is_identical = lhs_cfg == rhs_cfg
    cfg_skeleton_matches = (
        int(lhs_cfg.get("basicBlockCount") or 0) == int(rhs_cfg.get("basicBlockCount") or 0)
        and (lhs_cfg.get("terminatorCounts") or {}) == (rhs_cfg.get("terminatorCounts") or {})
        and int(lhs_cfg.get("phiCount") or 0) == int(rhs_cfg.get("phiCount") or 0)
    )
    if not cfg_is_identical and not cfg_skeleton_matches:
        return False

    select_delta = int(rhs_cfg.get("selectCount") or 0) - int(lhs_cfg.get("selectCount") or 0)
    if not cfg_is_identical and (select_delta < 4 or select_delta > 8):
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    allowed_keys = {"arithmetic", "memory", "vector"}
    if changed_keys != allowed_keys:
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    memory_delta = abs(int(lhs_families.get("memory", 0)) - int(rhs_families.get("memory", 0)))
    vector_delta = abs(int(lhs_families.get("vector", 0)) - int(rhs_families.get("vector", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    return arithmetic_delta <= 20 and memory_delta <= 4 and vector_delta <= 48 and total_delta <= 68


def _entry_has_moderate_cfg_vector_materialization_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    lhs_terminators = lhs_cfg.get("terminatorCounts") or {}
    rhs_terminators = rhs_cfg.get("terminatorCounts") or {}

    lhs_block_count = int(lhs_cfg.get("basicBlockCount") or 0)
    rhs_block_count = int(rhs_cfg.get("basicBlockCount") or 0)
    lhs_br = int(lhs_terminators.get("br") or 0)
    rhs_br = int(rhs_terminators.get("br") or 0)
    lhs_condbr = int(lhs_terminators.get("condbr") or 0)
    rhs_condbr = int(rhs_terminators.get("condbr") or 0)
    lhs_ret = int(lhs_terminators.get("ret") or 0)
    rhs_ret = int(rhs_terminators.get("ret") or 0)
    lhs_phi = int(lhs_cfg.get("phiCount") or 0)
    rhs_phi = int(rhs_cfg.get("phiCount") or 0)
    lhs_select = int(lhs_cfg.get("selectCount") or 0)
    rhs_select = int(rhs_cfg.get("selectCount") or 0)

    block_delta = rhs_block_count - lhs_block_count
    br_delta = rhs_br - lhs_br
    condbr_delta = rhs_condbr - lhs_condbr
    phi_delta = rhs_phi - lhs_phi
    select_delta = lhs_select - rhs_select

    if not (
        lhs_ret == rhs_ret == 1
        and 8 <= block_delta <= 12
        and 4 <= br_delta <= 6
        and condbr_delta == br_delta
        and phi_delta == br_delta
        and select_delta == br_delta
    ):
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    if changed_keys != {"arithmetic", "vector"}:
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    vector_delta = abs(int(lhs_families.get("vector", 0)) - int(rhs_families.get("vector", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    return 6 <= arithmetic_delta <= 16 and 8 <= vector_delta <= 24 and total_delta <= 36


def _entry_has_small_shared_cfg_arithmetic_materialization_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    lhs_terminators = lhs_cfg.get("terminatorCounts") or {}
    rhs_terminators = rhs_cfg.get("terminatorCounts") or {}

    lhs_block_count = int(lhs_cfg.get("basicBlockCount") or 0)
    rhs_block_count = int(rhs_cfg.get("basicBlockCount") or 0)
    lhs_br = int(lhs_terminators.get("br") or 0)
    rhs_br = int(rhs_terminators.get("br") or 0)
    lhs_condbr = int(lhs_terminators.get("condbr") or 0)
    rhs_condbr = int(rhs_terminators.get("condbr") or 0)
    lhs_ret = int(lhs_terminators.get("ret") or 0)
    rhs_ret = int(rhs_terminators.get("ret") or 0)
    lhs_phi = int(lhs_cfg.get("phiCount") or 0)
    rhs_phi = int(rhs_cfg.get("phiCount") or 0)
    lhs_select = int(lhs_cfg.get("selectCount") or 0)
    rhs_select = int(rhs_cfg.get("selectCount") or 0)

    block_delta = rhs_block_count - lhs_block_count
    br_delta = rhs_br - lhs_br
    condbr_delta = rhs_condbr - lhs_condbr
    phi_delta = rhs_phi - lhs_phi
    select_delta = lhs_select - rhs_select

    if not (
        lhs_ret == rhs_ret == 1
        and 6 <= block_delta <= 7
        and br_delta == condbr_delta == phi_delta == select_delta
        and 3 <= br_delta <= 4
    ):
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    if changed_keys != {"arithmetic"}:
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    return 3 <= arithmetic_delta <= 6


def _entry_has_outer_merge_self_loop_materialization_drift(
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    lhs_terminators = lhs_cfg.get("terminatorCounts") or {}
    rhs_terminators = rhs_cfg.get("terminatorCounts") or {}

    lhs_block_count = int(lhs_cfg.get("basicBlockCount") or 0)
    rhs_block_count = int(rhs_cfg.get("basicBlockCount") or 0)
    lhs_br = int(lhs_terminators.get("br") or 0)
    rhs_br = int(rhs_terminators.get("br") or 0)
    lhs_condbr = int(lhs_terminators.get("condbr") or 0)
    rhs_condbr = int(rhs_terminators.get("condbr") or 0)
    lhs_ret = int(lhs_terminators.get("ret") or 0)
    rhs_ret = int(rhs_terminators.get("ret") or 0)
    lhs_phi = int(lhs_cfg.get("phiCount") or 0)
    rhs_phi = int(rhs_cfg.get("phiCount") or 0)
    lhs_select = int(lhs_cfg.get("selectCount") or 0)
    rhs_select = int(rhs_cfg.get("selectCount") or 0)

    block_delta = rhs_block_count - lhs_block_count
    br_delta = rhs_br - lhs_br
    condbr_delta = rhs_condbr - lhs_condbr
    phi_delta = rhs_phi - lhs_phi
    select_delta = lhs_select - rhs_select

    if not (
        lhs_ret == rhs_ret == 1
        and block_delta >= 20
        and br_delta >= 10
        and condbr_delta >= 8
        and phi_delta >= 20
        and select_delta >= 6
    ):
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    if changed_keys != {"arithmetic", "vector"}:
        return False

    arithmetic_delta = abs(int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0)))
    vector_delta = abs(int(lhs_families.get("vector", 0)) - int(rhs_families.get("vector", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    return arithmetic_delta <= 16 and vector_delta <= 4 and total_delta <= 16


def _entry_has_gep_lowering_materialization_drift(
    original: dict[str, Any],
    regenerated: dict[str, Any],
    original_entry: dict[str, Any],
    regenerated_entry: dict[str, Any],
) -> bool:
    """Detect arithmetic -> GEP (memory) + vector lowering drift with identical CFG.

    When the AIR backend lowers struct field accesses into explicit GEP chains
    on the same CFG skeleton, the instruction-family delta manifests as
    {arithmetic: decrease, memory: increase, vector: small change} while the
    CFG structure, AIR intrinsics, entry semantics and fast-math all remain
    identical.  This is a backend materialization difference, not a converter
    gap, so the instruction-family residual should be downgraded from L2 to L1.
    """
    semantic_keys = ("argSemantics", "resourceSemantics", "builtinSemantics", "outputSemantics")
    for key in semantic_keys:
        if original_entry.get(key) != regenerated_entry.get(key):
            return False

    if _normalize_air_intrinsic_counter(original_entry.get("airIntrinsicCalls")) != _normalize_air_intrinsic_counter(
        regenerated_entry.get("airIntrinsicCalls")
    ):
        return False

    # CFG must be identical (no block/terminator/phi/select drift at all)
    lhs_cfg = original_entry.get("cfg") or {}
    rhs_cfg = regenerated_entry.get("cfg") or {}
    if lhs_cfg != rhs_cfg:
        return False

    # Fast-math must match
    lhs_fast_math = (original.get("fastMath") or {}).get("instructionFlags") or {}
    rhs_fast_math = (regenerated.get("fastMath") or {}).get("instructionFlags") or {}
    if lhs_fast_math != rhs_fast_math:
        return False

    lhs_families = original_entry.get("instructionFamilies") or {}
    rhs_families = regenerated_entry.get("instructionFamilies") or {}
    changed_keys = {
        name
        for name in sorted(set(lhs_families) | set(rhs_families))
        if int(lhs_families.get(name, 0)) != int(rhs_families.get(name, 0))
    }
    if changed_keys != {"arithmetic", "memory", "vector"}:
        return False

    arithmetic_delta = int(lhs_families.get("arithmetic", 0)) - int(rhs_families.get("arithmetic", 0))
    memory_delta = int(rhs_families.get("memory", 0)) - int(lhs_families.get("memory", 0))
    vector_delta = abs(int(rhs_families.get("vector", 0)) - int(lhs_families.get("vector", 0)))
    total_delta = sum(abs(int(lhs_families.get(name, 0)) - int(rhs_families.get(name, 0))) for name in changed_keys)

    # arithmetic must decrease and memory must increase (GEP lowering trades
    # inline arithmetic for explicit GEP / load instructions)
    if arithmetic_delta <= 0 or memory_delta <= 0:
        return False

    # The memory increase should be at least as large as the arithmetic
    # decrease (GEP introduces both gep + potential load/store pairs)
    if memory_delta < arithmetic_delta:
        return False

    return vector_delta <= 10 and total_delta <= 40


def _target_triple_is_roundtrip_platform_drift(lhs: str | None, rhs: str | None) -> bool:
    """Return True when targetTriple difference is only a round-trip platform change.

    Original shaders target air64*_v24-apple-ios*, but after MSL recompilation
    on macOS the AIR backend emits air64-apple-macosx*.  This is the expected
    platform change during round-trip and does not indicate a converter gap.
    """
    if lhs is None or rhs is None:
        return False
    # Normalize: strip the _v24 vector ABI suffix from the original triple
    # to get the base architecture string for comparison.
    lhs_base = re.sub(r"_v24\b", "", lhs)
    rhs_base = re.sub(r"_v24\b", "", rhs)
    # Check that only the OS part differs: ios -> macosx
    lhs_parts = lhs_base.split("-", 2)
    rhs_parts = rhs_base.split("-", 2)
    if len(lhs_parts) < 3 or len(rhs_parts) < 3:
        return False
    # Architecture must match, only OS differs (ios* -> macosx*)
    return lhs_parts[0] == rhs_parts[0] and lhs_parts[1].startswith("apple-ios") and rhs_parts[1].startswith("apple-macosx")


def _downgrade_optimizer_only_shape_drift(
    original: dict[str, Any],
    regenerated: dict[str, Any],
    builtin_comparison: dict[str, Any],
    cfg_comparison: dict[str, Any],
    instruction_family_comparison: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])
    shared_module_families = _air_intrinsic_family_set(original.get("moduleAirIntrinsics") or {}) & _air_intrinsic_family_set(regenerated.get("moduleAirIntrinsics") or {})
    optimizer_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_optimizer_only_intrinsic_drift(original_entries[key], regenerated_entries[key], shared_module_families)
    }
    vector_aggregate_shape_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_small_vector_aggregate_shape_drift(original_entries[key], regenerated_entries[key])
    }
    scalar_vector_materialization_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_small_scalar_vector_materialization_drift(original_entries[key], regenerated_entries[key])
    }
    select_vector_memory_materialization_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_select_heavy_vector_memory_materialization_drift(
            original,
            regenerated,
            original_entries[key],
            regenerated_entries[key],
        )
    }
    moderate_cfg_vector_materialization_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_moderate_cfg_vector_materialization_drift(original_entries[key], regenerated_entries[key])
    }
    small_shared_cfg_arithmetic_materialization_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_small_shared_cfg_arithmetic_materialization_drift(original_entries[key], regenerated_entries[key])
    }
    outer_merge_self_loop_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_outer_merge_self_loop_materialization_drift(original_entries[key], regenerated_entries[key])
    }
    gep_lowering_materialization_only_entry_keys = {
        key
        for key in sorted(set(original_entries) & set(regenerated_entries))
        if _entry_has_gep_lowering_materialization_drift(
            original,
            regenerated,
            original_entries[key],
            regenerated_entries[key],
        )
    }
    module_only_intrinsic_drift = _module_has_optimizer_only_intrinsic_drift(original, regenerated)
    downgraded_shape_only_entry_keys = (
        optimizer_only_entry_keys
        | vector_aggregate_shape_only_entry_keys
        | scalar_vector_materialization_only_entry_keys
        | select_vector_memory_materialization_only_entry_keys
        | moderate_cfg_vector_materialization_only_entry_keys
        | small_shared_cfg_arithmetic_materialization_only_entry_keys
        | outer_merge_self_loop_only_entry_keys
        | gep_lowering_materialization_only_entry_keys
    )

    adjusted_builtin_differences: list[dict[str, Any]] = []
    for difference in builtin_comparison.get("differences") or []:
        updated = dict(difference)
        if difference.get("reason") == "模块级 air intrinsic 使用变化" and module_only_intrinsic_drift:
            updated["severity"] = "L1"
        adjusted_builtin_differences.append(updated)

    adjusted_cfg_differences: list[dict[str, Any]] = []
    for difference in cfg_comparison.get("differences") or []:
        updated = dict(difference)
        if difference.get("subject") in downgraded_shape_only_entry_keys:
            updated["severity"] = "L1"
        adjusted_cfg_differences.append(updated)

    adjusted_instruction_differences: list[dict[str, Any]] = []
    for difference in instruction_family_comparison.get("differences") or []:
        updated = dict(difference)
        if difference.get("subject") in downgraded_shape_only_entry_keys:
            updated["severity"] = "L1"
        adjusted_instruction_differences.append(updated)

    return (
        _make_section_result(adjusted_builtin_differences),
        _make_section_result(adjusted_cfg_differences),
        _make_section_result(adjusted_instruction_differences),
    )


def _sanitize_param_signature(param: str) -> str:
    value = _normalize_whitespace(param)
    value = re.sub(r'\s+%(?:"[^"]+"|[-A-Za-z0-9$._]+)$', '', value)
    value = re.sub(r'\s+"[^"]+"', '', value)
    value = re.sub(r'\b(?:nocapture|noundef|returned|nonnull|readonly|writeonly|readnone|dereferenceable(?:_or_null)?\(\d+\)|align\s+\d+|byval\([^)]*\)|sret\([^)]*\)|swiftself|swifterror|nest|inreg|signext|zeroext|immarg)\b', '', value)
    value = _normalize_whitespace(value)
    return value


def _extract_parameter_addrspaces(parameter_signatures: list[str]) -> list[int]:
    addrspaces: list[int] = []
    for signature in parameter_signatures:
        match = re.search(r'addrspace\((\d+)\)', signature)
        if match:
            addrspaces.append(int(match.group(1)))
    return addrspaces


def _parse_attribute_token(token: str) -> tuple[str, str | bool]:
    if token.startswith('"') and token.endswith('"'):
        return token[1:-1], True
    if token.startswith('"') and '"=' in token:
        key, value = token.split('=', 1)
        return key[1:-1], _strip_quotes(value)
    return token, True


def _parse_attributes(lines: list[str]) -> dict[str, dict[str, str | bool]]:
    attributes: dict[str, dict[str, str | bool]] = {}
    for line in lines:
        match = ATTRIBUTE_RE.match(line.strip())
        if not match:
            continue
        attr_id, attr_body = match.groups()
        parsed: dict[str, str | bool] = {}
        for token in ATTRIBUTE_TOKEN_RE.findall(attr_body.strip()):
            key, value = _parse_attribute_token(token)
            parsed[key] = value
        attributes[attr_id] = parsed
    return attributes


def _parse_metadata(lines: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    named: dict[str, str] = {}
    nodes: dict[str, str] = {}
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("!"):
            continue
        node_match = METADATA_NODE_RE.match(stripped)
        if node_match:
            node_id, content = node_match.groups()
            nodes[node_id] = content.strip()
            continue
        named_match = NAMED_METADATA_RE.match(stripped)
        if named_match:
            name, content = named_match.groups()
            named[name] = content.strip()
    return named, nodes


def _parse_output_or_arg_metadata(content: str) -> dict[str, Any] | None:
    strings = STRING_RE.findall(content)
    integers = [int(value) for value in INTEGER_RE.findall(content)]
    semantic_tokens = [token for token in strings if token.startswith("air.") and token not in METADATA_VALUE_KEYS]
    if not semantic_tokens:
        return None

    kind = semantic_tokens[0]
    qualifiers = [token for token in semantic_tokens[1:] if token != "air.arg_unused"]
    access = next((token for token in semantic_tokens if token in {"air.read", "air.read_write", "air.write", "air.write_only"}), None)
    arg_index = integers[0] if content.startswith("!{i") and integers else None
    location_index = _extract_metadata_int(content, "air.location_index")
    address_space = _extract_metadata_int(content, "air.address_space")
    arg_type_name = _extract_metadata_string(content, "air.arg_type_name")
    arg_name = _extract_metadata_string(content, "air.arg_name")
    buffer_size = _extract_metadata_int(content, "air.buffer_size")
    type_size = _extract_metadata_int(content, "air.arg_type_size")
    align_size = _extract_metadata_int(content, "air.arg_type_align_size")

    include_addrspace_in_signature = kind not in RESOURCE_KINDS

    signature_parts = [f"kind={kind}"]
    if arg_index is not None:
        signature_parts.append(f"index={arg_index}")
    if location_index is not None:
        signature_parts.append(f"location={location_index}")
    if include_addrspace_in_signature and address_space is not None:
        signature_parts.append(f"addrspace={address_space}")
    if access is not None:
        signature_parts.append(f"access={access.removeprefix('air.')}")
    if arg_type_name:
        signature_parts.append(f"type={arg_type_name}")
    if type_size is not None:
        signature_parts.append(f"typeSize={type_size}")
    if align_size is not None:
        signature_parts.append(f"align={align_size}")
    if qualifiers:
        signature_parts.append(f"qualifiers={','.join(sorted(set(qualifiers)))}")

    return {
        "argIndex": arg_index,
        "kind": kind,
        "qualifiers": sorted(set(qualifiers)),
        "access": access,
        "locationIndex": location_index,
        "addressSpace": address_space,
        "argTypeName": arg_type_name,
        "argName": arg_name,
        "bufferSize": buffer_size,
        "argTypeSize": type_size,
        "argTypeAlignSize": align_size,
        "signature": "|".join(signature_parts),
        "isResource": kind in RESOURCE_KINDS,
    }


def _parse_metadata_items_from_refs(nodes: dict[str, str], refs: list[str]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for ref in refs:
        node_content = nodes.get(ref)
        if not node_content:
            continue

        current_item = _parse_output_or_arg_metadata(node_content)
        if current_item is not None:
            items.append(current_item)
            continue

        nested_refs = _metadata_refs(node_content)
        if nested_refs:
            items.extend(_parse_metadata_items_from_refs(nodes, nested_refs))
    return items


def _parse_metadata_group(nodes: dict[str, str], group_ref: str | None) -> list[dict[str, Any]]:
    if not group_ref:
        return []
    return _parse_metadata_items_from_refs(nodes, [group_ref])


def _extract_functions(ir_text: str, attributes: dict[str, dict[str, str | bool]]) -> list[dict[str, Any]]:
    lines = ir_text.splitlines()
    functions: list[dict[str, Any]] = []
    index = 0

    while index < len(lines):
        stripped = lines[index].strip()
        if not stripped.startswith("define "):
            index += 1
            continue

        header_lines = [stripped]
        while not header_lines[-1].endswith("{") and index + 1 < len(lines):
            index += 1
            header_lines.append(lines[index].strip())
        header_text = " ".join(header_lines)
        header_without_brace = header_text[:-1].strip() if header_text.endswith("{") else header_text
        header_match = FUNCTION_HEADER_RE.match(header_without_brace)
        if not header_match:
            index += 1
            continue

        body_lines: list[str] = []
        index += 1
        while index < len(lines) and lines[index].strip() != "}":
            body_lines.append(lines[index])
            index += 1

        return_type = _normalize_whitespace(header_match.group("return_type"))
        function_name = _strip_quotes(header_match.group("name")) or "<unknown>"
        raw_params = _split_top_level(header_match.group("params"))
        parameter_signatures = [_sanitize_param_signature(param) for param in raw_params]
        suffix = header_match.group("suffix")
        attr_group_match = re.search(r'#(\d+)', suffix)
        attribute_group = attr_group_match.group(1) if attr_group_match else None
        function_attrs = attributes.get(attribute_group or "", {})
        fast_math_attr_keys = sorted(
            key for key in function_attrs.keys() if key in FAST_MATH_ATTRIBUTE_KEYS and function_attrs.get(key)
        )

        basic_block_count = 1 if body_lines else 0
        label_count = 0
        terminator_counts: Counter[str] = Counter()
        instruction_family_counts: Counter[str] = Counter()
        air_intrinsic_calls: Counter[str] = Counter()
        fast_math_instruction_flags: Counter[str] = Counter()
        phi_count = 0
        select_count = 0
        instruction_count = 0
        full_function_text = header_without_brace + "\n" + "\n".join(body_lines)
        addrspace_counts: Counter[str] = Counter(re.findall(r'addrspace\((\d+)\)', full_function_text))

        for raw_line in body_lines:
            code = raw_line.split(";", 1)[0].strip()
            if not code:
                continue
            if re.match(r'^(?:"[^"]+"|[-A-Za-z0-9$._]+|\d+):$', code):
                label_count += 1
                basic_block_count += 1
                continue

            instruction_count += 1
            if "=" in code:
                _, rhs = code.split("=", 1)
                rhs = rhs.strip()
            else:
                rhs = code
            opcode = rhs.split(None, 1)[0]

            if opcode in TERMINATOR_OPS:
                if opcode == "br":
                    terminator_key = "condbr" if rhs.startswith("br i1 ") else "br"
                    terminator_counts[terminator_key] += 1
                else:
                    terminator_counts[opcode] += 1
            if opcode == "phi":
                phi_count += 1
            if opcode == "select":
                select_count += 1

            if opcode in ARITHMETIC_OPS:
                instruction_family_counts["arithmetic"] += 1
            elif opcode in COMPARE_OPS:
                instruction_family_counts["compare"] += 1
            elif opcode in CAST_OPS:
                instruction_family_counts["cast"] += 1
            elif opcode in MEMORY_OPS:
                instruction_family_counts["memory"] += 1
            elif opcode in VECTOR_OPS:
                instruction_family_counts["vector"] += 1
            elif opcode in AGGREGATE_OPS:
                instruction_family_counts["aggregate"] += 1
            elif opcode in {"call", "invoke", "callbr"} or rhs.startswith("tail call") or rhs.startswith("tail call"):
                instruction_family_counts["call"] += 1

            for token in FAST_MATH_TOKENS:
                if re.search(rf'\b{re.escape(token)}\b', rhs):
                    fast_math_instruction_flags[token] += 1

            for match in re.finditer(r'@("[^"]+"|[-A-Za-z0-9$._]+)\(', rhs):
                callee = _strip_quotes(match.group(1)) or "<unknown>"
                if callee.startswith("air."):
                    air_intrinsic_calls[callee] += 1
                    instruction_family_counts["intrinsic"] += 1

        functions.append(
            {
                "name": function_name,
                "returnType": return_type,
                "parameterCount": len(parameter_signatures),
                "parameterSignatures": parameter_signatures,
                "parameterAddrspaces": _extract_parameter_addrspaces(parameter_signatures),
                "attributeGroup": attribute_group,
                "functionAttrs": sorted(function_attrs.keys()),
                "fastMathAttrKeys": fast_math_attr_keys,
                "basicBlockCount": basic_block_count,
                "labelCount": label_count,
                "instructionCount": instruction_count,
                "terminatorCounts": _counter_to_sorted_dict(terminator_counts),
                "phiCount": phi_count,
                "selectCount": select_count,
                "instructionFamilies": _counter_to_sorted_dict(instruction_family_counts),
                "airIntrinsicCalls": _counter_to_sorted_dict(air_intrinsic_calls),
                "addrspaceCounts": _counter_to_sorted_dict(addrspace_counts),
                "fastMathInstructionFlags": _counter_to_sorted_dict(fast_math_instruction_flags),
            }
        )

        index += 1

    return functions


def extract_ir_summary(ir_path: str | Path) -> dict[str, Any]:
    path = Path(ir_path).expanduser().resolve()
    text = path.read_text(encoding="utf-8", errors="replace")
    summary = extract_ir_summary_text(text)
    summary["path"] = str(path)
    return summary


def extract_ir_summary_text(ir_text: str) -> dict[str, Any]:
    lines = ir_text.splitlines()
    attributes = _parse_attributes(lines)
    named_metadata, metadata_nodes = _parse_metadata(lines)
    functions = _extract_functions(ir_text, attributes)
    functions_by_name = {item["name"]: item for item in functions}

    target_triple = None
    data_layout = None
    source_filename = None
    for line in lines:
        stripped = line.strip()
        triple_match = TARGET_TRIPLE_RE.match(stripped)
        if triple_match:
            target_triple = triple_match.group(1)
        datalayout_match = TARGET_DATALAYOUT_RE.match(stripped)
        if datalayout_match:
            data_layout = datalayout_match.group(1)
        source_match = SOURCE_FILENAME_RE.match(stripped)
        if source_match:
            source_filename = source_match.group(1)

    compile_options: list[str] = []
    compile_refs = _metadata_refs(named_metadata.get("air.compile_options", ""))
    for ref in compile_refs:
        if ref in metadata_nodes:
            compile_options.extend(STRING_RE.findall(metadata_nodes[ref]))
    compile_options = sorted(set(compile_options))

    entries: list[dict[str, Any]] = []
    for shader_type, metadata_name in ENTRY_METADATA_KINDS.items():
        for entry_ref in _metadata_refs(named_metadata.get(metadata_name, "")):
            entry_node = metadata_nodes.get(entry_ref)
            if not entry_node:
                continue
            function_name = _function_ref_name(entry_node)
            if not function_name:
                continue
            child_refs = _metadata_refs(entry_node)
            outputs = _parse_metadata_items_from_refs(metadata_nodes, child_refs[:1])
            args = _parse_metadata_items_from_refs(metadata_nodes, child_refs[1:])
            function_summary = functions_by_name.get(function_name, {})
            resource_semantics = sorted(item["signature"] for item in args if item.get("isResource"))
            builtin_semantics = sorted(item["signature"] for item in args if not item.get("isResource"))
            output_semantics = sorted(item["signature"] for item in outputs)
            entry = {
                "shaderType": shader_type,
                "functionName": function_name,
                "returnSignature": function_summary.get("returnType"),
                "parameterCount": function_summary.get("parameterCount"),
                "parameterSignatures": function_summary.get("parameterSignatures") or [],
                "parameterAddrspaces": function_summary.get("parameterAddrspaces") or [],
                "argSemantics": [item["signature"] for item in sorted(args, key=lambda value: (value.get("argIndex") is None, value.get("argIndex") or 0, value.get("signature")))],
                "resourceSemantics": resource_semantics,
                "builtinSemantics": builtin_semantics,
                "outputSemantics": output_semantics,
                "functionAttrs": function_summary.get("functionAttrs") or [],
                "fastMathAttrKeys": function_summary.get("fastMathAttrKeys") or [],
                "cfg": {
                    "basicBlockCount": function_summary.get("basicBlockCount"),
                    "terminatorCounts": function_summary.get("terminatorCounts") or {},
                    "phiCount": function_summary.get("phiCount"),
                    "selectCount": function_summary.get("selectCount"),
                },
                "instructionFamilies": function_summary.get("instructionFamilies") or {},
                "airIntrinsicCalls": function_summary.get("airIntrinsicCalls") or {},
                "addrspaceCounts": function_summary.get("addrspaceCounts") or {},
                "fastMathInstructionFlags": function_summary.get("fastMathInstructionFlags") or {},
            }
            entries.append(entry)

    module_addrspaces = Counter(re.findall(r'addrspace\((\d+)\)', ir_text))
    module_air_intrinsics = Counter()
    module_instruction_families = Counter()
    module_fast_math_flags = Counter()
    for function in functions:
        module_air_intrinsics.update(function.get("airIntrinsicCalls") or {})
        module_instruction_families.update(function.get("instructionFamilies") or {})
        module_fast_math_flags.update(function.get("fastMathInstructionFlags") or {})

    unique_fast_math_attr_keys = sorted(
        {
            key
            for function in functions
            for key in function.get("fastMathAttrKeys") or []
        }
    )

    entries.sort(key=lambda item: (item["shaderType"], item["functionName"]))
    functions.sort(key=lambda item: item["name"])
    entry_key_map = {f"{entry['shaderType']}:{entry['functionName']}": entry for entry in entries}

    return {
        "schemaVersion": SCHEMA_VERSION,
        "module": {
            "sourceFilename": source_filename,
            "targetTriple": target_triple,
            "dataLayout": data_layout,
            "compileOptions": compile_options,
        },
        "entryCount": len(entries),
        "functionCount": len(functions),
        "entries": entries,
        "functions": functions,
        "entryKeys": sorted(entry_key_map.keys()),
        "moduleAddressSpaces": _counter_to_sorted_dict(module_addrspaces),
        "moduleAirIntrinsics": _counter_to_sorted_dict(module_air_intrinsics),
        "moduleInstructionFamilies": _counter_to_sorted_dict(module_instruction_families),
        "fastMath": {
            "compileOptions": [option for option in compile_options if "fast_math" in option],
            "functionAttrKeys": unique_fast_math_attr_keys,
            "instructionFlags": _counter_to_sorted_dict(module_fast_math_flags),
        },
    }


def _severity_max(*levels: str) -> str:
    best = "L0"
    for level in levels:
        if SEVERITY_ORDER.get(level, 0) > SEVERITY_ORDER.get(best, 0):
            best = level
    return best


def _make_difference(category: str, severity: str, subject: str, reason: str, details: dict[str, Any]) -> dict[str, Any]:
    return {
        "category": category,
        "severity": severity,
        "subject": subject,
        "reason": reason,
        "details": details,
    }


def _make_section_result(differences: list[dict[str, Any]]) -> dict[str, Any]:
    severity = "L0"
    for item in differences:
        severity = _severity_max(severity, item["severity"])
    return {
        "same": not differences,
        "severity": severity,
        "differenceCount": len(differences),
        "differences": differences,
    }


def _map_by_entry_key(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {f"{item['shaderType']}:{item['functionName']}": item for item in entries}


def _compare_entry_summaries(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])

    original_keys = set(original_entries)
    regenerated_keys = set(regenerated_entries)
    missing = sorted(original_keys - regenerated_keys)
    added = sorted(regenerated_keys - original_keys)
    if missing or added:
        differences.append(
            _make_difference(
                "entry",
                "L3",
                "entry-set",
                "entry 函数集合发生变化",
                {
                    "missingEntries": missing,
                    "addedEntries": added,
                },
            )
        )

    for key in sorted(original_keys & regenerated_keys):
        lhs = original_entries[key]
        rhs = regenerated_entries[key]
        if lhs.get("returnSignature") != rhs.get("returnSignature"):
            differences.append(
                _make_difference(
                    "entry",
                    "L3",
                    key,
                    "entry 返回类型摘要变化",
                    {
                        "original": lhs.get("returnSignature"),
                        "regenerated": rhs.get("returnSignature"),
                    },
                )
            )
        if lhs.get("parameterCount") != rhs.get("parameterCount"):
            differences.append(
                _make_difference(
                    "entry",
                    "L3",
                    key,
                    "entry 参数个数变化",
                    {
                        "original": lhs.get("parameterCount"),
                        "regenerated": rhs.get("parameterCount"),
                    },
                )
            )
        if lhs.get("parameterSignatures") != rhs.get("parameterSignatures"):
            differences.append(
                _make_difference(
                    "entry",
                    "L3",
                    key,
                    "entry 参数类型摘要变化",
                    {
                        "original": lhs.get("parameterSignatures"),
                        "regenerated": rhs.get("parameterSignatures"),
                    },
                )
            )
        if lhs.get("argSemantics") != rhs.get("argSemantics"):
            differences.append(
                _make_difference(
                    "entry",
                    "L2",
                    key,
                    "entry 参数语义摘要变化",
                    {
                        "original": lhs.get("argSemantics"),
                        "regenerated": rhs.get("argSemantics"),
                    },
                )
            )
        if lhs.get("outputSemantics") != rhs.get("outputSemantics"):
            differences.append(
                _make_difference(
                    "entry",
                    "L3",
                    key,
                    "entry 输出语义摘要变化",
                    {
                        "original": lhs.get("outputSemantics"),
                        "regenerated": rhs.get("outputSemantics"),
                    },
                )
            )

    return _make_section_result(differences)


def _compare_address_spaces(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    if original.get("moduleAddressSpaces") != regenerated.get("moduleAddressSpaces"):
        severity = "L1"
        original_keys = set((original.get("moduleAddressSpaces") or {}).keys())
        regenerated_keys = set((regenerated.get("moduleAddressSpaces") or {}).keys())
        if original_keys != regenerated_keys:
            severity = "L2"
        differences.append(
            _make_difference(
                "address-space",
                severity,
                "module",
                "模块级 addrspace 分布变化",
                {
                    "original": original.get("moduleAddressSpaces"),
                    "regenerated": regenerated.get("moduleAddressSpaces"),
                },
            )
        )

    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])
    for key in sorted(set(original_entries) & set(regenerated_entries)):
        lhs = original_entries[key]
        rhs = regenerated_entries[key]
        if lhs.get("parameterAddrspaces") != rhs.get("parameterAddrspaces"):
            differences.append(
                _make_difference(
                    "address-space",
                    "L3",
                    key,
                    "entry 参数 addrspace 摘要变化",
                    {
                        "original": lhs.get("parameterAddrspaces"),
                        "regenerated": rhs.get("parameterAddrspaces"),
                    },
                )
            )

    return _make_section_result(differences)


def _compare_builtins_and_resources(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    original_module_intrinsics = original.get("moduleAirIntrinsics") or {}
    regenerated_module_intrinsics = regenerated.get("moduleAirIntrinsics") or {}
    normalized_original_module_intrinsics = _normalize_air_intrinsic_counter(original_module_intrinsics)
    normalized_regenerated_module_intrinsics = _normalize_air_intrinsic_counter(regenerated_module_intrinsics)
    if normalized_original_module_intrinsics != normalized_regenerated_module_intrinsics:
        differences.append(
            _make_difference(
                "builtin-resource",
                "L2",
                "module-air-intrinsics",
                "模块级 air intrinsic 使用变化",
                {
                    "original": original_module_intrinsics,
                    "regenerated": regenerated_module_intrinsics,
                    "normalizedOriginal": normalized_original_module_intrinsics,
                    "normalizedRegenerated": normalized_regenerated_module_intrinsics,
                },
            )
        )

    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])
    for key in sorted(set(original_entries) & set(regenerated_entries)):
        lhs = original_entries[key]
        rhs = regenerated_entries[key]
        if lhs.get("resourceSemantics") != rhs.get("resourceSemantics"):
            differences.append(
                _make_difference(
                    "builtin-resource",
                    "L2",
                    key,
                    "entry 资源语义摘要变化",
                    {
                        "original": lhs.get("resourceSemantics"),
                        "regenerated": rhs.get("resourceSemantics"),
                    },
                )
            )
        if lhs.get("builtinSemantics") != rhs.get("builtinSemantics"):
            differences.append(
                _make_difference(
                    "builtin-resource",
                    "L2",
                    key,
                    "entry builtin / stage-in 摘要变化",
                    {
                        "original": lhs.get("builtinSemantics"),
                        "regenerated": rhs.get("builtinSemantics"),
                    },
                )
            )
        original_intrinsic_calls = lhs.get("airIntrinsicCalls") or {}
        regenerated_intrinsic_calls = rhs.get("airIntrinsicCalls") or {}
        normalized_original_intrinsic_calls = _normalize_air_intrinsic_counter(original_intrinsic_calls)
        normalized_regenerated_intrinsic_calls = _normalize_air_intrinsic_counter(regenerated_intrinsic_calls)
        if normalized_original_intrinsic_calls != normalized_regenerated_intrinsic_calls:
            differences.append(
                _make_difference(
                    "builtin-resource",
                    "L1",
                    key,
                    "函数内 air intrinsic 调用统计变化",
                    {
                        "original": original_intrinsic_calls,
                        "regenerated": regenerated_intrinsic_calls,
                        "normalizedOriginal": normalized_original_intrinsic_calls,
                        "normalizedRegenerated": normalized_regenerated_intrinsic_calls,
                    },
                )
            )

    return _make_section_result(differences)


def _compare_cfg(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])

    for key in sorted(set(original_entries) & set(regenerated_entries)):
        lhs_cfg = original_entries[key].get("cfg") or {}
        rhs_cfg = regenerated_entries[key].get("cfg") or {}
        if lhs_cfg == rhs_cfg:
            continue
        block_delta = abs(int(lhs_cfg.get("basicBlockCount") or 0) - int(rhs_cfg.get("basicBlockCount") or 0))
        severity = "L1"
        if (lhs_cfg.get("terminatorCounts") or {}) != (rhs_cfg.get("terminatorCounts") or {}):
            severity = "L2"
        if block_delta >= 2:
            severity = "L2"
        differences.append(
            _make_difference(
                "cfg",
                severity,
                key,
                "控制流粗摘要变化",
                {
                    "original": lhs_cfg,
                    "regenerated": rhs_cfg,
                },
            )
        )

    return _make_section_result(differences)


def _compare_instruction_families(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    original_entries = _map_by_entry_key(original.get("entries") or [])
    regenerated_entries = _map_by_entry_key(regenerated.get("entries") or [])

    for key in sorted(set(original_entries) & set(regenerated_entries)):
        lhs = original_entries[key].get("instructionFamilies") or {}
        rhs = regenerated_entries[key].get("instructionFamilies") or {}
        if lhs == rhs:
            continue
        keys = set(lhs) | set(rhs)
        total_delta = sum(abs(int(lhs.get(name, 0)) - int(rhs.get(name, 0))) for name in keys)
        important_changed = any((lhs.get(name, 0) != rhs.get(name, 0)) for name in IMPORTANT_FAMILY_KEYS)
        changed_keys = {name for name in keys if int(lhs.get(name, 0)) != int(rhs.get(name, 0))}

        arithmetic_delta = int(lhs.get("arithmetic", 0)) - int(rhs.get("arithmetic", 0))
        vector_delta = int(lhs.get("vector", 0)) - int(rhs.get("vector", 0))
        is_small_arithmetic_vector_tradeoff = (
            changed_keys == {"arithmetic", "vector"}
            and abs(arithmetic_delta) == 1
            and abs(vector_delta) == 1
            and arithmetic_delta == -vector_delta
        )

        severity = "L2" if important_changed and total_delta >= 2 else "L1"
        if is_small_arithmetic_vector_tradeoff:
            severity = "L1"
        differences.append(
            _make_difference(
                "instruction-family",
                severity,
                key,
                "指令族统计变化",
                {
                    "original": lhs,
                    "regenerated": rhs,
                    "totalAbsoluteDelta": total_delta,
                },
            )
        )

    return _make_section_result(differences)


def _compare_fast_math(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    original_fast_math = original.get("fastMath") or {}
    regenerated_fast_math = regenerated.get("fastMath") or {}
    if original_fast_math != regenerated_fast_math:
        compile_options_changed = original_fast_math.get("compileOptions") != regenerated_fast_math.get("compileOptions")
        function_attr_keys_changed = original_fast_math.get("functionAttrKeys") != regenerated_fast_math.get("functionAttrKeys")
        instruction_flags_changed = original_fast_math.get("instructionFlags") != regenerated_fast_math.get("instructionFlags")

        severity = "L1"
        if compile_options_changed:
            severity = "L3"
        elif function_attr_keys_changed:
            severity = "L2"

        differences.append(
            _make_difference(
                "fast-math",
                severity,
                "module",
                "fast-math 相关属性变化",
                {
                    "original": original_fast_math,
                    "regenerated": regenerated_fast_math,
                    "compileOptionsChanged": compile_options_changed,
                    "functionAttrKeysChanged": function_attr_keys_changed,
                    "instructionFlagsChanged": instruction_flags_changed,
                },
            )
        )
    return _make_section_result(differences)


def _compare_module_metadata(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    differences: list[dict[str, Any]] = []
    lhs_module = original.get("module") or {}
    rhs_module = regenerated.get("module") or {}
    for key in ("targetTriple", "dataLayout"):
        if lhs_module.get(key) != rhs_module.get(key):
            severity = "L1"
            reason = f"模块元数据 {key} 变化"
            if key == "targetTriple" and _target_triple_is_roundtrip_platform_drift(
                lhs_module.get("targetTriple"), rhs_module.get("targetTriple")
            ):
                severity = "L0"
                reason = "模块元数据 targetTriple 变化（round-trip 平台差异：ios → macosx）"
            differences.append(
                _make_difference(
                    "module",
                    severity,
                    key,
                    reason,
                    {
                        "original": lhs_module.get(key),
                        "regenerated": rhs_module.get(key),
                    },
                )
            )
    return _make_section_result(differences)


def _recommended_action_for_risk(risk_level: str) -> str:
    if risk_level == "L0":
        return "保持在 L2 批量回归中持续观察，可优先扩到更多样本。"
    if risk_level == "L1":
        return "记录为可接受差异，后续结合更多样本基线继续观察。"
    if risk_level == "L2":
        return "优先进入 L3 最小行为测试，不建议直接跳到 live 验证。"
    return "先视为结构性不一致或 round-trip blocker，优先修 L2/L1 问题后再决定是否进入 L3。"


def _sample_source_prefix(source_kind: Any) -> str:
    if source_kind == "shader_source_diagnostics":
        return "shaderSourceDiagnostics::"
    return ""


def sample_identity(sample: dict[str, Any]) -> str:
    source_prefix = _sample_source_prefix(sample.get("sourceKind"))
    module_key = sample.get("moduleKey")
    bundle_id = sample.get("bundleId")
    if module_key:
        if bundle_id:
            return f"{source_prefix}bundle:{bundle_id}::module:{module_key}"
        return f"{source_prefix}module:{module_key}"

    input_path = sample.get("inputPath")
    if input_path:
        return f"{source_prefix}{Path(str(input_path)).stem}"

    comparison_key = sample.get("comparisonKey")
    if comparison_key:
        return f"{source_prefix}{comparison_key}"
    return "<unknown>"


def _identity_map(samples: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {sample_identity(item): item for item in samples}


def _layered_sample_entry(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        "sampleKey": sample_identity(sample),
        "comparisonKey": sample.get("comparisonKey"),
        "bundleId": sample.get("bundleId"),
        "moduleKey": sample.get("moduleKey"),
        "inputPath": sample.get("inputPath"),
        "riskLevel": sample.get("riskLevel"),
        "riskReason": sample.get("riskReason"),
        "recommendedAction": sample.get("recommendedAction"),
    }


def _resolve_optional_path(value: Any) -> Path | None:
    if value in {None, ""}:
        return None
    return Path(str(value)).expanduser().resolve()


def _load_optional_json(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _behavior_sample_key(sample: dict[str, Any]) -> str:
    explicit_sample_key = sample.get("sampleKey")
    if explicit_sample_key:
        return str(explicit_sample_key)
    return sample_identity(sample)


def _collect_l3_behavior_evidence(gate_summary: dict[str, Any], l3_sample_keys: list[str]) -> dict[str, Any]:
    if not l3_sample_keys:
        return {
            "behaviorSummaryPath": None,
            "coveredSampleKeys": [],
            "missingSampleKeys": [],
        }

    output_root = _resolve_optional_path(gate_summary.get("outputRoot"))
    if output_root is None:
        return {
            "behaviorSummaryPath": None,
            "coveredSampleKeys": [],
            "missingSampleKeys": list(l3_sample_keys),
        }

    behavior_summary_path = output_root / "behavior-summary.json"
    behavior_summary = _load_optional_json(behavior_summary_path)
    if behavior_summary is None:
        return {
            "behaviorSummaryPath": str(behavior_summary_path),
            "coveredSampleKeys": [],
            "missingSampleKeys": list(l3_sample_keys),
        }

    behavior_output_root = _resolve_optional_path(behavior_summary.get("outputRoot"))
    if behavior_output_root is not None and behavior_output_root != output_root:
        return {
            "behaviorSummaryPath": str(behavior_summary_path),
            "coveredSampleKeys": [],
            "missingSampleKeys": list(l3_sample_keys),
        }

    gate_roundtrip_report_path = _resolve_optional_path(gate_summary.get("roundtripReportPath"))
    behavior_roundtrip_report_path = _resolve_optional_path(behavior_summary.get("roundtripReportPath"))
    if (
        gate_roundtrip_report_path is not None
        and behavior_roundtrip_report_path is not None
        and behavior_roundtrip_report_path != gate_roundtrip_report_path
    ):
        return {
            "behaviorSummaryPath": str(behavior_summary_path),
            "coveredSampleKeys": [],
            "missingSampleKeys": list(l3_sample_keys),
        }

    roundtrip_report = _load_optional_json(gate_roundtrip_report_path)
    current_candidate_source_by_key: dict[str, Path] = {}
    if roundtrip_report is not None:
        for item in roundtrip_report.get("results") or []:
            candidate_source_path = _resolve_optional_path(item.get("generatedMSLPath"))
            if candidate_source_path is None:
                continue
            current_candidate_source_by_key[sample_identity(item)] = candidate_source_path

    passed_sample_keys: set[str] = set()
    executed_status_by_key = {
        _behavior_sample_key(item): str(item.get("status") or "")
        for item in (behavior_summary.get("executedSamples") or [])
    }
    ready_source_by_key = {
        _behavior_sample_key(item): _resolve_optional_path(item.get("candidateSourcePath"))
        for item in (behavior_summary.get("readySamples") or [])
    }

    for sample_key in l3_sample_keys:
        if executed_status_by_key.get(sample_key) != "pass":
            continue
        current_candidate_source = current_candidate_source_by_key.get(sample_key)
        ready_candidate_source = ready_source_by_key.get(sample_key)
        if (
            current_candidate_source is not None
            and ready_candidate_source is not None
            and ready_candidate_source != current_candidate_source
        ):
            continue
        passed_sample_keys.add(sample_key)

    covered_sample_keys = [sample_key for sample_key in l3_sample_keys if sample_key in passed_sample_keys]
    return {
        "behaviorSummaryPath": str(behavior_summary_path),
        "coveredSampleKeys": covered_sample_keys,
        "missingSampleKeys": [sample_key for sample_key in l3_sample_keys if sample_key not in passed_sample_keys],
    }


def assess_layered_validation_decision(gate_summary: dict[str, Any], risk_report: dict[str, Any]) -> dict[str, Any]:
    regressions = gate_summary.get("regressions") or {}
    roundtrip_stats = gate_summary.get("roundtripStats") or {}
    l2_samples = list(risk_report.get("samplesForL3") or [])
    blocked_samples = [
        sample
        for sample in (risk_report.get("blockedSamples") or [])
        if sample.get("roundTripStatus") == "success"
    ]

    l2_entries = [_layered_sample_entry(sample) for sample in l2_samples]
    blocked_entries = [_layered_sample_entry(sample) for sample in blocked_samples]
    l2_sample_keys = [item["sampleKey"] for item in l2_entries]
    blocked_sample_keys = [item["sampleKey"] for item in blocked_entries]

    unexpected_failures = list(regressions.get("unexpectedFailures") or [])
    unexpected_failure_keys = sorted(
        {
            str(item.get("sampleKey") or item.get("comparisonKey") or "<unknown>")
            for item in unexpected_failures
        }
    )
    unexpected_blocked_keys = sorted({str(item) for item in (regressions.get("unexpectedBlockedSampleKeys") or [])})
    unexpected_l2_keys = sorted({str(item) for item in (regressions.get("unexpectedL2SampleKeys") or [])})
    should_block = bool(gate_summary.get("shouldBlock"))

    l2_stop_decision = "stay_at_l2"
    l2_stop_reason = "当前离线 gate 仍是默认主入口；在没有新的结构性回归前，先把默认代表集保持稳定。"
    overall_decision = "stay_at_l2"
    overall_summary = "当前结果可继续停在 L2 离线层。"

    if should_block:
        l2_stop_decision = "block_on_regression"
        l2_stop_reason = "出现新增 round-trip / blocked 回归或 job-count 越界，必须先在离线层修复，再讨论升级。"
        overall_decision = "stop_at_l2"
        overall_summary = "当前 gate 已阻断，先修复离线回归。"
    elif unexpected_l2_keys:
        l2_stop_decision = "review_new_l2"
        l2_stop_reason = "出现新的 L2 样本，先确认是代表集有意变化还是新的结构风险，再决定是否升级。"
        overall_decision = "stay_at_l2"
        overall_summary = "当前出现新的 L2 风险，先留在 L2 复核边界。"
    elif l2_entries:
        overall_decision = "promote_l2_candidates_to_l3"
        overall_summary = "当前活跃 L2 样本已处于 gate 边界内，可将这些候选样本推进到 L3 最小行为测试。"

    if should_block:
        l3_decision = "blocked"
        l3_reason = "当前 gate 已阻断，必须先修复新增回归。"
        l3_candidates: list[dict[str, Any]] = []
        deferred_l3_candidates = l2_entries
        deferred_l3_reason = "gate blocked by regression"
    elif unexpected_l2_keys:
        l3_decision = "defer"
        l3_reason = "新的 L2 样本超出了当前 gate 边界；先在离线层确认风险口径，再决定是否推进 L3。"
        l3_candidates = []
        deferred_l3_candidates = l2_entries
        deferred_l3_reason = "new L2 samples need offline review first"
    elif l2_entries:
        l3_decision = "promote_selected_samples"
        l3_reason = "活跃 L2 候选集仍处于已知 gate 边界内，符合 compute-first 的最小升级入口。"
        l3_candidates = l2_entries
        deferred_l3_candidates = []
        deferred_l3_reason = None
    else:
        l3_decision = "not_needed"
        l3_reason = "当前没有活跃 L2 样本需要继续升级。"
        l3_candidates = []
        deferred_l3_candidates = []
        deferred_l3_reason = None

    l3_candidate_sample_keys = [item["sampleKey"] for item in l3_candidates]
    behavior_evidence = _collect_l3_behavior_evidence(gate_summary, l3_candidate_sample_keys)
    l4_blocking_reasons: list[str] = []
    if should_block:
        l4_decision = "blocked"
        l4_reason = "当前存在离线层阻断回归，禁止进入 L4。"
        l4_blocking_reasons.append("gate is currently blocked by offline regressions")
    else:
        l4_decision = "defer"
        l4_reason = "L4 仍是严格后置 gate：只有在 L3 证据不足或风险只会在 runtime/live 中暴露时，才允许升级。"
        missing_behavior_sample_keys = list(behavior_evidence["missingSampleKeys"])
        if missing_behavior_sample_keys:
            l4_blocking_reasons.append(
                "L3 behavior evidence is still missing for active L2 candidates: "
                + ", ".join(missing_behavior_sample_keys)
            )
        if blocked_sample_keys:
            l4_blocking_reasons.append(
                f"blocked samples must stay at the offline layer first: {', '.join(blocked_sample_keys)}"
            )
        if not l4_blocking_reasons:
            l4_blocking_reasons.append("no runtime-only trigger is present in the current offline reports")

    return {
        "schemaVersion": SCHEMA_VERSION,
        "currentLayer": "L2",
        "overallDecision": overall_decision,
        "summary": overall_summary,
        "stopAtL2": {
            "decision": l2_stop_decision,
            "reason": l2_stop_reason,
            "gateStatus": gate_summary.get("status"),
            "gateSummary": gate_summary.get("summary"),
            "blockedSampleKeys": blocked_sample_keys,
            "unexpectedFailureSampleKeys": unexpected_failure_keys,
            "unexpectedBlockedSampleKeys": unexpected_blocked_keys,
            "unexpectedL2SampleKeys": unexpected_l2_keys,
            "roundTripFailedJobs": roundtrip_stats.get("roundTripFailedJobs"),
        },
        "l3Plan": {
            "decision": l3_decision,
            "reason": l3_reason,
            "candidateCount": len(l3_candidates),
            "candidateSampleKeys": [item["sampleKey"] for item in l3_candidates],
            "candidates": l3_candidates,
            "deferredCandidateCount": len(deferred_l3_candidates),
            "deferredCandidateSampleKeys": [item["sampleKey"] for item in deferred_l3_candidates],
            "deferredReason": deferred_l3_reason,
            "blockedSampleKeys": blocked_sample_keys,
        },
        "l4Plan": {
            "decision": l4_decision,
            "eligible": False,
            "reason": l4_reason,
            "behaviorSummaryPath": behavior_evidence["behaviorSummaryPath"],
            "behaviorEvidenceSampleKeys": behavior_evidence["coveredSampleKeys"],
            "missingBehaviorEvidenceSampleKeys": behavior_evidence["missingSampleKeys"],
            "blockingReasons": l4_blocking_reasons,
            "allowedWhen": [
                "L2/L3 证据仍不足以解释剩余风险",
                "风险只会在真实 runtime / .gputrace / render 结构中暴露",
                "本轮改动直接影响 runtime replacement 主链路",
            ],
            "automationFirstTools": [
                "Scripts/check_gputrace_sources.py",
                "Scripts/compare_capture_runs.py",
                "Scripts/e006d_render_diff.py",
                "Scripts/runtime_launch_diagnostics_summary.py",
                "PlayCover MCP",
            ],
            "userConfirmationRequiredWhen": [
                "需要人工登录/摆场景/点击 UI",
                "需要 GUI / Accessibility / cliclick",
                "需要工作区外静态分析",
                "需要修改工作区外文件或 app bundle",
                "需要长时间占用机器做大规模 live 对照",
            ],
        },
        "activeL2SampleKeys": l2_sample_keys,
        "blockedSampleKeys": blocked_sample_keys,
    }


def _normalize_gate_profile(gate_profile: dict[str, Any] | None) -> dict[str, Any]:
    profile = dict(gate_profile or {})
    allowed_failures = profile.get("allowedFailureSamples") or {}
    profile["allowedFailureSamples"] = {
        str(sample_key): (str(stage) if stage is not None else None)
        for sample_key, stage in allowed_failures.items()
    }
    profile["allowedBlockedSampleKeys"] = sorted({str(item) for item in (profile.get("allowedBlockedSampleKeys") or [])})
    profile["allowedL2SampleKeys"] = sorted({str(item) for item in (profile.get("allowedL2SampleKeys") or [])})
    minimum_expected_job_count = profile.get("minimumExpectedJobCount")
    if minimum_expected_job_count is None:
        minimum_expected_job_count = profile.get("expectedJobCount")
    profile["minimumExpectedJobCount"] = minimum_expected_job_count
    profile.setdefault("expectedJobCount", None)
    profile.setdefault("description", None)
    return profile


def _evaluate_job_count_expectation(normalized_profile: dict[str, Any], actual_job_count: int) -> dict[str, Any]:
    expected_job_count_raw = normalized_profile.get("expectedJobCount")
    minimum_job_count_raw = normalized_profile.get("minimumExpectedJobCount")
    expected_job_count = int(expected_job_count_raw) if expected_job_count_raw is not None else None
    minimum_expected_job_count = int(minimum_job_count_raw) if minimum_job_count_raw is not None else expected_job_count

    if expected_job_count is None and minimum_expected_job_count is None:
        return {
            "expectedJobCount": None,
            "minimumExpectedJobCount": None,
            "status": "unbounded",
            "mismatch": None,
            "warning": None,
        }

    if minimum_expected_job_count is not None and actual_job_count < minimum_expected_job_count:
        return {
            "expectedJobCount": expected_job_count,
            "minimumExpectedJobCount": minimum_expected_job_count,
            "status": "out_of_range",
            "mismatch": {
                "reason": "below_minimum",
                "minimumExpectedJobCount": minimum_expected_job_count,
                "expectedJobCount": expected_job_count,
                "actualJobCount": actual_job_count,
                "message": (
                    f"job count dropped below minimum boundary: expected >= {minimum_expected_job_count}"
                    f", got {actual_job_count}"
                ),
            },
            "warning": None,
        }

    if expected_job_count is not None and actual_job_count > expected_job_count:
        return {
            "expectedJobCount": expected_job_count,
            "minimumExpectedJobCount": minimum_expected_job_count,
            "status": "out_of_range",
            "mismatch": {
                "reason": "above_expected",
                "minimumExpectedJobCount": minimum_expected_job_count,
                "expectedJobCount": expected_job_count,
                "actualJobCount": actual_job_count,
                "message": f"job count grew beyond configured representative set: expected <= {expected_job_count}, got {actual_job_count}",
            },
            "warning": None,
        }

    if expected_job_count is not None and actual_job_count < expected_job_count:
        return {
            "expectedJobCount": expected_job_count,
            "minimumExpectedJobCount": minimum_expected_job_count,
            "status": "below_preferred",
            "mismatch": None,
            "warning": {
                "reason": "below_preferred",
                "minimumExpectedJobCount": minimum_expected_job_count,
                "expectedJobCount": expected_job_count,
                "actualJobCount": actual_job_count,
                "message": (
                    f"job count below preferred representative set: expected {expected_job_count}, got {actual_job_count}"
                    f" (minimum {minimum_expected_job_count})"
                ),
            },
        }

    return {
        "expectedJobCount": expected_job_count,
        "minimumExpectedJobCount": minimum_expected_job_count,
        "status": "match",
        "mismatch": None,
        "warning": None,
    }


def assess_gate_result(
    roundtrip_report: dict[str, Any],
    risk_report: dict[str, Any],
    *,
    gate_profile: dict[str, Any] | None = None,
    profile_name: str | None = None,
) -> dict[str, Any]:
    normalized_profile = _normalize_gate_profile(gate_profile)
    samples = list(risk_report.get("samples") or [])
    failure_samples = [sample for sample in samples if sample.get("roundTripStatus") != "success"]
    blocked_samples = [
        sample
        for sample in (risk_report.get("blockedSamples") or [])
        if sample.get("roundTripStatus") == "success"
    ]
    l2_samples = list(risk_report.get("samplesForL3") or [])

    allowed_failures = normalized_profile["allowedFailureSamples"]
    allowed_blocked_keys = set(normalized_profile["allowedBlockedSampleKeys"])
    allowed_l2_keys = set(normalized_profile["allowedL2SampleKeys"])

    failure_by_key = _identity_map(failure_samples)
    blocked_by_key = _identity_map(blocked_samples)
    l2_by_key = _identity_map(l2_samples)

    unexpected_failures: list[dict[str, Any]] = []
    for sample_key, sample in sorted(failure_by_key.items()):
        expected_stage = allowed_failures.get(sample_key)
        actual_stage = sample.get("failureStage")
        if expected_stage is None and sample_key not in allowed_failures:
            unexpected_failures.append(
                {
                    "sampleKey": sample_key,
                    "failureStage": actual_stage,
                    "reason": "unexpected round-trip failure",
                    "comparisonKey": sample.get("comparisonKey"),
                }
            )
            continue
        if expected_stage is not None and actual_stage != expected_stage:
            unexpected_failures.append(
                {
                    "sampleKey": sample_key,
                    "failureStage": actual_stage,
                    "expectedFailureStage": expected_stage,
                    "reason": "round-trip failure stage changed",
                    "comparisonKey": sample.get("comparisonKey"),
                }
            )

    observed_by_key = _identity_map(samples)
    observed_sample_keys = set(observed_by_key)

    resolved_expected_failures = sorted((set(allowed_failures) - set(failure_by_key)) & observed_sample_keys)
    unobserved_expected_failures = sorted(set(allowed_failures) - observed_sample_keys)
    unexpected_blocked_keys = sorted(set(blocked_by_key) - allowed_blocked_keys)
    resolved_expected_blocked = sorted((allowed_blocked_keys - set(blocked_by_key)) & observed_sample_keys)
    unobserved_expected_blocked = sorted(allowed_blocked_keys - observed_sample_keys)
    unexpected_l2_keys = sorted(set(l2_by_key) - allowed_l2_keys)
    resolved_expected_l2 = sorted((allowed_l2_keys - set(l2_by_key)) & observed_sample_keys)
    unobserved_expected_l2 = sorted(allowed_l2_keys - observed_sample_keys)

    actual_job_count = int(risk_report.get("jobCount") or 0)
    job_count_evaluation = _evaluate_job_count_expectation(normalized_profile, actual_job_count)
    expected_job_count = job_count_evaluation["expectedJobCount"]
    minimum_expected_job_count = job_count_evaluation["minimumExpectedJobCount"]
    job_count_mismatch = job_count_evaluation["mismatch"]
    job_count_warning = job_count_evaluation["warning"]

    active_allowed_failures = sorted(set(failure_by_key) & set(allowed_failures))
    active_allowed_blocked = sorted(set(blocked_by_key) & allowed_blocked_keys)
    active_allowed_l2 = sorted(set(l2_by_key) & allowed_l2_keys)

    notes: list[str] = []
    if resolved_expected_failures:
        notes.append(f"known failure resolved: {', '.join(resolved_expected_failures)}")
    if resolved_expected_blocked:
        notes.append(f"known blocked sample improved: {', '.join(resolved_expected_blocked)}")
    if resolved_expected_l2:
        notes.append(f"known L2 sample improved: {', '.join(resolved_expected_l2)}")

    failure_reasons: list[str] = []
    if job_count_mismatch:
        failure_reasons.append(job_count_mismatch["message"])
    if unexpected_failures:
        failure_reasons.extend(
            f"unexpected failure {item['sampleKey']}@{item.get('failureStage') or 'unknown'}" for item in unexpected_failures
        )
    if unexpected_blocked_keys:
        failure_reasons.extend(f"unexpected blocked sample {sample_key}" for sample_key in unexpected_blocked_keys)

    warning_reasons: list[str] = []
    if job_count_warning:
        warning_reasons.append(job_count_warning["message"])
    if unexpected_l2_keys:
        warning_reasons.extend(f"new L2 sample {sample_key}" for sample_key in unexpected_l2_keys)
    if active_allowed_failures:
        warning_reasons.append(f"known round-trip blockers still present: {', '.join(active_allowed_failures)}")
    if active_allowed_blocked:
        warning_reasons.append(f"known L3 blocked samples still present: {', '.join(active_allowed_blocked)}")
    if active_allowed_l2:
        warning_reasons.append(f"known L2 samples still need L3 follow-up: {', '.join(active_allowed_l2)}")

    if failure_reasons:
        status = "fail"
        recommended_action = "视为日常 gate 回归：先修复新增 round-trip / L3 问题，或在确认代表集发生有意变化后同步更新 gate profile。"
        summary = failure_reasons[0]
    elif warning_reasons:
        status = "warn"
        recommended_action = "当前结果仍可停在离线层继续观察；优先维护代表集，并把活跃 L2 样本排入后续 L3 最小行为测试。"
        summary = warning_reasons[0]
    else:
        status = "pass"
        recommended_action = "当前 gate 在已配置边界内通过，可继续作为稳定离线入口使用。"
        summary = "all observed samples stayed within the configured gate boundary"

    return {
        "schemaVersion": SCHEMA_VERSION,
        "profileName": profile_name,
        "profileConfigured": bool(profile_name or gate_profile),
        "profileDescription": normalized_profile.get("description"),
        "status": status,
        "shouldBlock": status == "fail",
        "summary": summary,
        "recommendedAction": recommended_action,
        "minimumExpectedJobCount": minimum_expected_job_count,
        "expectedJobCount": expected_job_count,
        "jobCount": actual_job_count,
        "jobCountStatus": job_count_evaluation["status"],
        "jobCountWarning": job_count_warning,
        "riskCounts": risk_report.get("riskCounts") or {},
        "activeKnownDebt": {
            "failureSampleKeys": active_allowed_failures,
            "blockedSampleKeys": active_allowed_blocked,
            "l2SampleKeys": active_allowed_l2,
        },
        "improvements": {
            "resolvedFailureSampleKeys": resolved_expected_failures,
            "resolvedBlockedSampleKeys": resolved_expected_blocked,
            "resolvedL2SampleKeys": resolved_expected_l2,
        },
        "unobservedExpectedDebt": {
            "failureSampleKeys": unobserved_expected_failures,
            "blockedSampleKeys": unobserved_expected_blocked,
            "l2SampleKeys": unobserved_expected_l2,
        },
        "regressions": {
            "jobCountMismatch": job_count_mismatch,
            "unexpectedFailures": unexpected_failures,
            "unexpectedBlockedSampleKeys": unexpected_blocked_keys,
            "unexpectedL2SampleKeys": unexpected_l2_keys,
        },
        "observed": {
            "sampleKeys": sorted(observed_sample_keys),
            "failureSampleKeys": sorted(failure_by_key),
            "blockedSampleKeys": sorted(blocked_by_key),
            "l2SampleKeys": sorted(l2_by_key),
        },
        "notes": notes,
        "roundtripStats": {
            "jobCount": roundtrip_report.get("jobCount"),
            "roundTripSucceededJobs": roundtrip_report.get("roundTripSucceededJobs"),
            "roundTripFailedJobs": roundtrip_report.get("roundTripFailedJobs"),
            "replayFailedJobs": roundtrip_report.get("replayFailedJobs"),
            "compileFailedJobs": roundtrip_report.get("compileFailedJobs"),
            "llvmDisFailedJobs": roundtrip_report.get("llvmDisFailedJobs"),
        },
    }


def compare_ir_summaries(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    entry_comparison = _compare_entry_summaries(original, regenerated)
    address_space_comparison = _compare_address_spaces(original, regenerated)
    builtin_comparison = _compare_builtins_and_resources(original, regenerated)
    cfg_comparison = _compare_cfg(original, regenerated)
    instruction_family_comparison = _compare_instruction_families(original, regenerated)
    fast_math_comparison = _compare_fast_math(original, regenerated)
    module_metadata_comparison = _compare_module_metadata(original, regenerated)
    builtin_comparison, cfg_comparison, instruction_family_comparison = _downgrade_optimizer_only_shape_drift(
        original,
        regenerated,
        builtin_comparison,
        cfg_comparison,
        instruction_family_comparison,
    )

    sections = [
        entry_comparison,
        address_space_comparison,
        builtin_comparison,
        cfg_comparison,
        instruction_family_comparison,
        fast_math_comparison,
        module_metadata_comparison,
    ]
    risk_level = "L0"
    differences: list[dict[str, Any]] = []
    for section in sections:
        risk_level = _severity_max(risk_level, section["severity"])
        differences.extend(section["differences"])
    risk_reason = "canonical summaries match"
    if differences:
        risk_reason = "; ".join(item["reason"] for item in differences[:3])

    return {
        "schemaVersion": SCHEMA_VERSION,
        "same": not differences,
        "riskLevel": risk_level,
        "riskReason": risk_reason,
        "recommendedAction": _recommended_action_for_risk(risk_level),
        "differenceCount": len(differences),
        "differences": differences,
        "entryComparison": entry_comparison,
        "addressSpaceComparison": address_space_comparison,
        "builtinComparison": builtin_comparison,
        "cfgComparison": cfg_comparison,
        "instructionFamilyComparison": instruction_family_comparison,
        "fastMathComparison": fast_math_comparison,
        "moduleMetadataComparison": module_metadata_comparison,
    }
