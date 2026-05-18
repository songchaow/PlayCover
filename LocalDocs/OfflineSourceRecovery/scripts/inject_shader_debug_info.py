#!/usr/bin/env python3
"""
inject_shader_debug_info.py — 向 .gputrace bundle 注入含 IR 注释增强的 shader stub 源码。

功能：
  1. 扫描 ShaderDebugInfo 中提取的 bitcode 模块
  2. 离线用 llvm-dis 反汇编为 LLVM IR
  3. 生成注释增强的 .metal stub 文件
  4. 注入到 .gputrace bundle 中缺失源码的 pipeline 位置

用法：
    python3 inject_shader_debug_info.py \
        --gputrace /path/to/capture.gputrace \
        --debug-info /path/to/ShaderDebugInfo/<bundleId> \
        [--llvm-dis /path/to/llvm-dis] \
        [--dry-run]

注意：
    当前版本由于缺少 pipeline ID → metallib 的精确映射，采用"按序填充"策略：
    将提取到的 shader 按照 metallib size 排序后，依次填充到缺失源码的 pipeline ID 中。
    这不保证一一对应关系的正确性，但足以验证 Xcode 是否能显示注入的源码。
    后续需要在运行时 hook 中收集精确映射关系。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inject IR-annotated shader stubs into a .gputrace bundle"
    )
    parser.add_argument(
        "--gputrace", required=True, help="Path to .gputrace bundle directory"
    )
    parser.add_argument(
        "--debug-info", required=True,
        help="Path to ShaderDebugInfo/<bundleId> directory"
    )
    parser.add_argument(
        "--llvm-dis",
        default=None,
        help="Path to llvm-dis binary (auto-detected if not specified)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Only print what would be done, don't write files"
    )
    parser.add_argument(
        "--max-inject", type=int, default=0,
        help="Maximum number of pipelines to inject (0=all)"
    )
    parser.add_argument(
        "--output-dir", default=None,
        help="Write generated stubs to separate dir instead of gputrace bundle (for inspection)"
    )
    return parser.parse_args()


def find_llvm_dis() -> Optional[str]:
    """Auto-detect llvm-dis location."""
    candidates = [
        "/opt/homebrew/bin/llvm-dis",
        "/opt/homebrew/opt/llvm/bin/llvm-dis",
        "/usr/local/bin/llvm-dis",
    ]
    # Also search homebrew cellar
    cellar = Path("/opt/homebrew/Cellar/llvm")
    if cellar.is_dir():
        for ver_dir in sorted(cellar.iterdir(), reverse=True):
            candidates.insert(0, str(ver_dir / "bin" / "llvm-dis"))

    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def disassemble_bitcode(bc_path: str, llvm_dis: str) -> Optional[str]:
    """Run llvm-dis on a bitcode file and return the IR text."""
    try:
        result = subprocess.run(
            [llvm_dis, bc_path, "-o", "-"],
            capture_output=True, timeout=30
        )
        if result.returncode == 0:
            return result.stdout.decode("utf-8", errors="replace")
        else:
            return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def load_debug_info_entries(debug_info_dir: str) -> list[dict]:
    """Load all extraction entries from ShaderDebugInfo directory."""
    entries = []
    for entry_name in sorted(os.listdir(debug_info_dir)):
        entry_dir = os.path.join(debug_info_dir, entry_name)
        meta_path = os.path.join(entry_dir, "extraction.meta.json")
        if not os.path.isfile(meta_path):
            continue
        try:
            meta = json.load(open(meta_path))
        except (json.JSONDecodeError, OSError):
            continue

        # Find bitcode modules
        modules_dir = os.path.join(entry_dir, "modules")
        module_paths = []
        if os.path.isdir(modules_dir):
            for mod_key in os.listdir(modules_dir):
                bc_path = os.path.join(modules_dir, mod_key, "module.bc")
                mod_meta_path = os.path.join(modules_dir, mod_key, "module.meta.json")
                if os.path.isfile(bc_path):
                    mod_meta = {}
                    if os.path.isfile(mod_meta_path):
                        try:
                            mod_meta = json.load(open(mod_meta_path))
                        except: pass
                    module_paths.append({
                        "bc_path": bc_path,
                        "module_key": mod_key,
                        "meta": mod_meta,
                    })

        entries.append({
            "entry_name": entry_name,
            "entry_dir": entry_dir,
            "meta": meta,
            "modules": module_paths,
        })
    return entries


def get_missing_pipeline_ids(gputrace_dir: str) -> list[str]:
    """Get pipeline IDs from index that don't have corresponding files."""
    index_path = os.path.join(gputrace_dir, "index")
    if not os.path.isfile(index_path):
        return []

    data = open(index_path, "rb").read()
    all_ids: set[str] = set()
    current = b""
    for byte in data:
        if byte == 0:
            s = current.decode("ascii", errors="ignore")
            if len(s) >= 10 and all(c in "0123456789ABCDEF" for c in s):
                all_ids.add(s)
            current = b""
        elif 32 <= byte < 127:
            current += bytes([byte])
        else:
            current = b""

    existing = set(
        f for f in os.listdir(gputrace_dir)
        if os.path.isfile(os.path.join(gputrace_dir, f))
        and len(f) >= 10
        and all(c in "0123456789ABCDEFabcdef" for c in f)
    )

    missing = sorted(all_ids - existing)
    return missing


def generate_stub_source(
    pipeline_id: str,
    entry: dict,
    module: dict,
    ir_text: Optional[str],
) -> str:
    """Generate a comment-annotated .metal stub with embedded IR."""
    meta = entry["meta"]
    mod_meta = module["meta"]

    function_names = mod_meta.get("functionNames", meta.get("totalFunctionNames", ["unknown"]))
    function_types = mod_meta.get("functionTypes", ["fragment"])
    selector = meta.get("selector", "unknown")
    cache_key = meta.get("cacheKey", "unknown")
    module_key = module.get("module_key", "unknown")
    metallib_size = meta.get("metallibSize", 0)
    bitcode_size = mod_meta.get("bitcodeSize", 0)
    is_valid = mod_meta.get("isValidLLVMBitcode", False)

    lines: list[str] = []
    lines.append("// === PlayCover Shader Debug Info ===")
    lines.append(f"// Pipeline: {pipeline_id}")
    lines.append(f"// Function: {', '.join(function_names)}")
    lines.append(f"// Type: {', '.join(function_types)}")
    lines.append(f"// Selector: {selector}")
    lines.append(f"// MetallibCacheKey: {cache_key}")
    lines.append(f"// ModuleKey: {module_key}")
    lines.append(f"// MetallibSize: {metallib_size}")
    lines.append(f"// BitcodeSize: {bitcode_size}")
    lines.append(f"// ValidLLVM: {is_valid}")
    lines.append("//")

    if ir_text:
        # Extract useful info from IR
        # Target triple
        triple_match = re.search(r'target triple = "([^"]+)"', ir_text)
        if triple_match:
            lines.append(f"// TargetTriple: {triple_match.group(1)}")

        # Struct types (buffer layouts)
        structs = re.findall(r'(%struct\.\w+)\s*=\s*type\s*\{[^}]+\}', ir_text)
        if structs:
            lines.append(f"// Structs: {', '.join(s.replace('%struct.', '') for s in structs[:10])}")

        # Texture/sampler parameters
        textures = re.findall(r'"air\.arg_name",\s*!"(_\w+)"', ir_text)
        if textures:
            unique_textures = sorted(set(textures))
            lines.append(f"// Resources: {', '.join(unique_textures[:15])}")

        # air.* intrinsics used
        intrinsics = sorted(set(re.findall(r'@(air\.\w+)', ir_text)))
        if intrinsics:
            lines.append(f"// Intrinsics: {', '.join(intrinsics[:20])}")

        lines.append("//")
        lines.append("// === LLVM IR BEGIN ===")
        for ir_line in ir_text.splitlines():
            lines.append(f"// {ir_line}")
        lines.append("// === LLVM IR END ===")
    else:
        lines.append("// [IR disassembly not available]")

    lines.append("")
    lines.append("#include <metal_stdlib>")
    lines.append("using namespace metal;")
    lines.append("")

    # Generate stub function based on type
    primary_name = function_names[0] if function_names else "unknownMain"
    primary_type = function_types[0] if function_types else "fragment"

    if primary_type == "kernel" or primary_type == "compute":
        lines.append(f"kernel void {primary_name}(")
        lines.append(f"    uint tid [[thread_position_in_grid]]")
        lines.append(") {")
        lines.append("    // Auto-generated stub — replace with actual MSL to Apply")
        lines.append("}")
    elif primary_type == "vertex":
        lines.append(f"struct VertexOut {{")
        lines.append(f"    float4 position [[position]];")
        lines.append(f"}};")
        lines.append(f"")
        lines.append(f"vertex VertexOut {primary_name}(")
        lines.append(f"    uint vid [[vertex_id]]")
        lines.append(") {")
        lines.append("    VertexOut out;")
        lines.append("    out.position = float4(0);")
        lines.append("    return out;")
        lines.append("}")
    else:  # fragment
        lines.append(f"fragment half4 {primary_name}(")
        lines.append(f"    float4 position [[position]]")
        lines.append(") {")
        lines.append("    // Auto-generated stub — replace with actual MSL to Apply")
        lines.append("    return half4(1.0h, 0.0h, 1.0h, 1.0h); // magenta = placeholder")
        lines.append("}")

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()

    gputrace_dir = os.path.expanduser(args.gputrace)
    debug_info_dir = os.path.expanduser(args.debug_info)

    if not os.path.isdir(gputrace_dir):
        print(f"ERROR: gputrace not found: {gputrace_dir}", file=sys.stderr)
        return 1
    if not os.path.isdir(debug_info_dir):
        print(f"ERROR: debug info dir not found: {debug_info_dir}", file=sys.stderr)
        return 1

    # Find llvm-dis
    llvm_dis = args.llvm_dis or find_llvm_dis()
    if not llvm_dis:
        print("WARNING: llvm-dis not found, IR will not be disassembled", file=sys.stderr)
    else:
        print(f"Using llvm-dis: {llvm_dis}")

    # Load debug info entries
    print(f"\nLoading ShaderDebugInfo from: {debug_info_dir}")
    entries = load_debug_info_entries(debug_info_dir)
    print(f"  Found {len(entries)} metallib entries")

    total_modules = sum(len(e["modules"]) for e in entries)
    print(f"  Total bitcode modules: {total_modules}")

    # Get missing pipeline IDs
    print(f"\nScanning gputrace: {gputrace_dir}")
    missing_ids = get_missing_pipeline_ids(gputrace_dir)
    print(f"  Missing pipeline IDs (no source file): {len(missing_ids)}")

    if not missing_ids:
        print("  Nothing to inject!")
        return 0

    # Flatten modules for injection
    flat_modules: list[tuple[dict, dict]] = []  # (entry, module)
    for entry in entries:
        for module in entry["modules"]:
            if module["meta"].get("isValidLLVMBitcode", False):
                flat_modules.append((entry, module))

    print(f"  Valid LLVM bitcode modules available: {len(flat_modules)}")

    # Determine how many to inject
    inject_count = min(len(missing_ids), len(flat_modules))
    if args.max_inject > 0:
        inject_count = min(inject_count, args.max_inject)

    print(f"\n{'[DRY RUN] ' if args.dry_run else ''}Will inject {inject_count} shader stubs")

    output_dir = args.output_dir or gputrace_dir
    if args.output_dir:
        os.makedirs(output_dir, exist_ok=True)

    # Process and inject
    injected = 0
    failed_dis = 0
    for i in range(inject_count):
        pipeline_id = missing_ids[i]
        entry, module = flat_modules[i]

        # Disassemble bitcode
        ir_text = None
        if llvm_dis:
            ir_text = disassemble_bitcode(module["bc_path"], llvm_dis)
            if ir_text is None:
                failed_dis += 1

        # Generate stub
        stub_source = generate_stub_source(pipeline_id, entry, module, ir_text)

        # Write to gputrace bundle
        output_path = os.path.join(output_dir, pipeline_id)
        if not args.dry_run:
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(stub_source)

        injected += 1
        if injected <= 3 or injected % 50 == 0:
            func_names = module["meta"].get("functionNames", ["?"])
            print(f"  [{injected}/{inject_count}] {pipeline_id} <- {func_names[0]} ({entry['entry_name']})")

    print(f"\nDone! Injected {injected} shader stubs.")
    if failed_dis > 0:
        print(f"  ({failed_dis} modules failed llvm-dis, injected without IR)")
    if args.output_dir:
        print(f"  Output directory: {output_dir}")
    else:
        print(f"  Written to: {gputrace_dir}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
