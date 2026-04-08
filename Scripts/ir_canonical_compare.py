#!/usr/bin/env python3
from __future__ import annotations

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


def _parse_output_or_arg_metadata(content: str) -> dict[str, Any]:
    strings = STRING_RE.findall(content)
    integers = [int(value) for value in INTEGER_RE.findall(content)]
    semantic_tokens = [token for token in strings if token.startswith("air.") and token not in METADATA_VALUE_KEYS]
    kind = semantic_tokens[0] if semantic_tokens else None
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

    signature_parts = [f"kind={kind or '<none>'}"]
    if arg_index is not None:
        signature_parts.append(f"index={arg_index}")
    if location_index is not None:
        signature_parts.append(f"location={location_index}")
    if address_space is not None:
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


def _parse_metadata_group(nodes: dict[str, str], group_ref: str | None) -> list[dict[str, Any]]:
    if not group_ref or group_ref not in nodes:
        return []
    group_node = nodes[group_ref]
    return [_parse_output_or_arg_metadata(nodes[ref]) for ref in _metadata_refs(group_node) if ref in nodes]


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
            outputs = _parse_metadata_group(metadata_nodes, child_refs[0] if len(child_refs) >= 1 else None)
            args = _parse_metadata_group(metadata_nodes, child_refs[1] if len(child_refs) >= 2 else None)
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
    if original.get("moduleAirIntrinsics") != regenerated.get("moduleAirIntrinsics"):
        differences.append(
            _make_difference(
                "builtin-resource",
                "L2",
                "module-air-intrinsics",
                "模块级 air intrinsic 使用变化",
                {
                    "original": original.get("moduleAirIntrinsics"),
                    "regenerated": regenerated.get("moduleAirIntrinsics"),
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
        if lhs.get("airIntrinsicCalls") != rhs.get("airIntrinsicCalls"):
            differences.append(
                _make_difference(
                    "builtin-resource",
                    "L1",
                    key,
                    "函数内 air intrinsic 调用统计变化",
                    {
                        "original": lhs.get("airIntrinsicCalls"),
                        "regenerated": rhs.get("airIntrinsicCalls"),
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
        severity = "L2" if important_changed and total_delta >= 2 else "L1"
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
    if original.get("fastMath") != regenerated.get("fastMath"):
        severity = "L2"
        if (original.get("fastMath") or {}).get("compileOptions") != (regenerated.get("fastMath") or {}).get("compileOptions"):
            severity = "L3"
        differences.append(
            _make_difference(
                "fast-math",
                severity,
                "module",
                "fast-math 相关属性变化",
                {
                    "original": original.get("fastMath"),
                    "regenerated": regenerated.get("fastMath"),
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
            differences.append(
                _make_difference(
                    "module",
                    "L1",
                    key,
                    f"模块元数据 {key} 变化",
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


def compare_ir_summaries(original: dict[str, Any], regenerated: dict[str, Any]) -> dict[str, Any]:
    entry_comparison = _compare_entry_summaries(original, regenerated)
    address_space_comparison = _compare_address_spaces(original, regenerated)
    builtin_comparison = _compare_builtins_and_resources(original, regenerated)
    cfg_comparison = _compare_cfg(original, regenerated)
    instruction_family_comparison = _compare_instruction_families(original, regenerated)
    fast_math_comparison = _compare_fast_math(original, regenerated)
    module_metadata_comparison = _compare_module_metadata(original, regenerated)

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
