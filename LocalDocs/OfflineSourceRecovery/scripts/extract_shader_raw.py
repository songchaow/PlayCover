#!/usr/bin/env python3
"""
extract_shader_raw.py — 从 ShaderDebugInfo 中按 library 地址提取 shader 的 IR 到 ShaderRaw 目录。

自动映射机制:
  1. 解压 gputrace 的 store0，对其中每个 metallib 计算 cacheKey
  2. 给定 library_ptr 时，通过 metallib 内容 hash 自动匹配到 ShaderDebugInfo 条目
  3. 映射结果缓存到 library_ptr_map.json

cacheKey 算法（与 PlayTools 运行时一致）:
  hash = fold(size, head_32_bytes, tail_16_bytes)  →  "{hash:016X}_{size}"

用法:
    # 按 library 地址提取（自动查找映射）
    python3 extract_shader_raw.py --library 0x7b12cf580 --library 0x7b12cd4c0 \\
        --shader-name SkinMakeupNew

    # 按 cacheKey 直接提取（不需要 gputrace）
    python3 extract_shader_raw.py --cache-key C2F2D89403D39FBF_7593 \\
        --shader-name SkinMakeupNew_vertex

    # 全量构建映射表
    python3 extract_shader_raw.py --build-map

    # 列出所有已知映射
    python3 extract_shader_raw.py --list
"""

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path
from typing import Optional


# === 默认路径配置 ===
DEFAULT_GPUTRACE = os.path.expanduser(
    "~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace"
)
DEFAULT_SDI_DIR = os.path.expanduser(
    "~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk"
)
DEFAULT_OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "gputracebinaryreplacement", "ShaderRaw"
)
MAP_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library_ptr_map.json")


# === cacheKey 算法 ===
def compute_cache_key(data: bytes) -> str:
    """
    复现 PlayTools 的 cacheKey 计算算法。
    Swift 源码:
        hashValue = UInt64(size)
        for byte in head(32) { hashValue = hashValue &* 31 &+ UInt64(byte) }
        for byte in tail(16) { hashValue = hashValue &* 31 &+ UInt64(byte) }
        return String(format: "%016llX_%d", hashValue, size)
    """
    size = len(data)
    hash_value = size
    MASK = 0xFFFFFFFFFFFFFFFF  # uint64 overflow

    head_bytes = min(32, size)
    tail_bytes = min(16, max(0, size - 32))

    for i in range(head_bytes):
        hash_value = (hash_value * 31 + data[i]) & MASK

    if tail_bytes > 0:
        tail_start = size - tail_bytes
        for i in range(tail_start, size):
            hash_value = (hash_value * 31 + data[i]) & MASK

    return f'{hash_value:016X}_{size}'


# === Store0 工具 ===
def decompress_store0(store0_path: str) -> bytes:
    """解压分块 zlib 压缩的 store0 文件。"""
    with open(store0_path, 'rb') as f:
        compressed = f.read()

    dec = zlib.decompressobj()
    chunks = []
    remaining = compressed
    while remaining:
        try:
            chunk = dec.decompress(remaining, 4 * 1024 * 1024)
            chunks.append(chunk)
            remaining = dec.unused_data
            if not remaining:
                chunks.append(dec.flush())
                break
            dec = zlib.decompressobj()
        except zlib.error:
            break

    return b''.join(chunks)


def find_metallibs_in_store0(store0_data: bytes) -> list:
    """在 store0 中找到所有 metallib，返回 [(offset, size, data), ...]"""
    results = []
    offset = 0
    while True:
        pos = store0_data.find(b'MTLB', offset)
        if pos == -1:
            break
        if pos + 20 <= len(store0_data):
            file_size = struct.unpack_from('<I', store0_data, pos + 16)[0]
            if 0 < file_size < 10 * 1024 * 1024 and pos + file_size <= len(store0_data):
                results.append((pos, file_size, store0_data[pos:pos + file_size]))
        offset = pos + 4
    return results


# === Device-Resources 解析 ===
def find_library_ptrs_in_device_resources(dr_path: str) -> list:
    """找到所有 CSuwuw "library" 记录的 library_ptr，返回 [lib_ptr, ...]"""
    with open(dr_path, 'rb') as f:
        dr_data = f.read()

    csuwuw_tag = b'CSuwuw\x00\x00'
    offset = 0
    ptrs = []
    while offset < len(dr_data):
        pos = dr_data.find(csuwuw_tag, offset)
        if pos == -1:
            break
        label_offset = pos + 16
        if label_offset + 8 <= len(dr_data):
            label = dr_data[label_offset:label_offset + 8]
            if label == b'library\x00':
                lib_ptr = struct.unpack_from('<Q', dr_data, pos + 24)[0]
                ptrs.append(lib_ptr)
        offset = pos + 8
    return ptrs


# === 自动映射构建 ===
def build_full_map(gputrace_dir: str, sdi_dir: str, verbose: bool = False) -> dict:
    """
    构建完整的 library_ptr → cacheKey 映射表。
    
    方法: 对 store0 中的每个 metallib 计算 cacheKey，
    然后与 device-resources 中的 library_ptr 通过 metallib 内容匹配。
    
    由于 library_ptr → store0 metallib 的直接映射不可从 gputrace 中程序化提取，
    此函数构建的是 {cacheKey: metadata} 和所有 library_ptr 列表。
    实际的 library_ptr → cacheKey 映射需要用户确认或通过附加启发式。
    """
    print("=== 构建映射表 ===\n")

    # 1. 解压 store0 并计算每个 metallib 的 cacheKey
    store0_path = os.path.join(gputrace_dir, 'store0')
    if not os.path.exists(store0_path):
        print(f"ERROR: store0 不存在: {store0_path}", file=sys.stderr)
        return {}

    print("解压 store0...")
    store0_data = decompress_store0(store0_path)
    metallibs = find_metallibs_in_store0(store0_data)
    print(f"  解压后: {len(store0_data):,} bytes, 找到 {len(metallibs)} 个 metallib")

    # 计算每个 metallib 的 cacheKey
    store0_cache_keys = {}  # cacheKey → (offset, size)
    for pos, size, data in metallibs:
        ck = compute_cache_key(data)
        store0_cache_keys[ck] = (pos, size)

    # 2. 验证 ShaderDebugInfo 中存在对应条目
    valid_keys = {}  # cacheKey → SDI metadata
    for ck in store0_cache_keys:
        entry_path = os.path.join(sdi_dir, ck)
        if os.path.isdir(entry_path):
            meta = _read_sdi_metadata(sdi_dir, ck)
            if meta:
                valid_keys[ck] = meta

    print(f"  store0 → ShaderDebugInfo 匹配: {len(valid_keys)}/{len(metallibs)}")

    # 3. 获取所有 library_ptr
    dr_path = None
    for entry in os.listdir(gputrace_dir):
        if entry.startswith("device-resources-"):
            dr_path = os.path.join(gputrace_dir, entry)
            break

    all_lib_ptrs = []
    if dr_path:
        all_lib_ptrs = find_library_ptrs_in_device_resources(dr_path)
        print(f"  device-resources 中 library 地址: {len(all_lib_ptrs)}")

    # 4. 加载现有映射（保留手动添加的条目）
    existing_map = {}
    if os.path.exists(MAP_FILE):
        with open(MAP_FILE) as f:
            existing_map = json.load(f)

    # 5. 输出映射摘要
    print(f"\n已建立映射: {len(existing_map)} 条")
    print(f"ShaderDebugInfo 有效条目: {len(valid_keys)} 条")
    print(f"总 library 地址: {len(all_lib_ptrs)} 个")

    unmapped = [p for p in all_lib_ptrs if f"0x{p:x}" not in existing_map]
    print(f"未映射 library 地址: {len(unmapped)} 个")

    # 6. 返回合并后的映射（保留已有 + 可用的 SDI 信息）
    result = dict(existing_map)

    # 将有效的 cacheKey 信息保存为参考
    result["__sdi_entries__"] = {
        ck: {
            "functionType": meta.get("functionType", "unknown"),
            "metallibSize": meta.get("metallibSize", 0),
        }
        for ck, meta in valid_keys.items()
    }
    result["__library_ptrs__"] = [f"0x{p:x}" for p in all_lib_ptrs]

    return result


def auto_resolve_library(lib_ptr_hex: str, gputrace_dir: str, sdi_dir: str,
                         map_data: dict, verbose: bool = False) -> Optional[str]:
    """
    自动解析 library_ptr → cacheKey。
    
    方法: 由于 library_ptr 和 store0 metallib 之间无直接索引，
    使用启发式方法:
    1. 检查映射表中是否已有
    2. 通过 metallib 大小唯一性推断（如果只有一个 SDI 条目匹配该 size）
    3. 给出候选列表让用户选择
    """
    # 已有映射
    if lib_ptr_hex in map_data:
        entry = map_data[lib_ptr_hex]
        if isinstance(entry, dict) and 'cacheKey' in entry:
            return entry['cacheKey']

    return None


# === SDI 元数据读取 ===
def _read_sdi_metadata(sdi_dir: str, cache_key: str) -> Optional[dict]:
    """读取 ShaderDebugInfo 条目的元数据。"""
    entry_path = os.path.join(sdi_dir, cache_key)
    if not os.path.isdir(entry_path):
        return None

    meta = {'cacheKey': cache_key}

    # 读取 extraction meta
    meta_path = os.path.join(entry_path, 'extraction.meta.json')
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            emeta = json.load(f)
        meta['functionNames'] = emeta.get('totalFunctionNames', [])
        meta['metallibSize'] = emeta.get('metallibSize', 0)

    # 读取 module meta
    modules_dir = os.path.join(entry_path, 'modules')
    if os.path.exists(modules_dir):
        for mod_dir in os.listdir(modules_dir):
            mod_meta_path = os.path.join(modules_dir, mod_dir, 'module.meta.json')
            if os.path.exists(mod_meta_path):
                with open(mod_meta_path) as f:
                    mod_meta = json.load(f)
                func_types = mod_meta.get('functionTypes', [])
                if func_types:
                    meta['functionType'] = func_types[0]
                break

    return meta


def get_sdi_info(sdi_dir: str, cache_key: str) -> Optional[dict]:
    """获取 ShaderDebugInfo 条目的完整路径信息。"""
    entry_path = os.path.join(sdi_dir, cache_key)
    if not os.path.isdir(entry_path):
        return None

    info = {
        'cacheKey': cache_key,
        'path': entry_path,
        'metallib': os.path.join(entry_path, 'library.metallib'),
    }

    meta_path = os.path.join(entry_path, 'extraction.meta.json')
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            meta = json.load(f)
        info['functionNames'] = meta.get('totalFunctionNames', [])

    modules_dir = os.path.join(entry_path, 'modules')
    if os.path.exists(modules_dir):
        for mod_dir in os.listdir(modules_dir):
            mod_path = os.path.join(modules_dir, mod_dir)
            bc_path = os.path.join(mod_path, 'module.bc')
            mod_meta_path = os.path.join(mod_path, 'module.meta.json')

            if os.path.exists(bc_path):
                info['bitcode'] = bc_path

            if os.path.exists(mod_meta_path):
                with open(mod_meta_path) as f:
                    mod_meta = json.load(f)
                info['functionType'] = mod_meta.get('functionTypes', ['unknown'])[0]
            break

    return info


# === LLVM-dis 工具 ===
def find_llvm_dis() -> Optional[str]:
    """查找 llvm-dis 可执行文件。"""
    # 1. PATH 中查找
    for path_dir in os.environ.get('PATH', '').split(':'):
        candidate = os.path.join(path_dir, 'llvm-dis')
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    # 2. 常见 Homebrew 路径
    for alt_path in [
        "/opt/homebrew/opt/llvm/bin/llvm-dis",
        "/usr/local/opt/llvm/bin/llvm-dis",
        "/opt/homebrew/bin/llvm-dis",
    ]:
        if os.path.exists(alt_path):
            return alt_path

    return None


# === 搜索功能 ===
def search_shader(sdi_dir: str, keyword: str, verbose: bool = False) -> int:
    """
    在所有 ShaderDebugInfo 的 metallib 中搜索包含关键字的 shader。
    
    搜索范围: metallib 中的可读字符串（uniform 名、struct 名、buffer 名等）。
    关键字不区分大小写。
    """
    keyword_lower = keyword.lower()
    print(f"搜索关键字: \"{keyword}\"\n")

    matches = []

    for entry in sorted(os.listdir(sdi_dir)):
        entry_path = os.path.join(sdi_dir, entry)
        if not os.path.isdir(entry_path):
            continue

        metallib_path = os.path.join(entry_path, 'library.metallib')
        if not os.path.exists(metallib_path):
            continue

        # 读取 metallib 并提取可读字符串
        with open(metallib_path, 'rb') as f:
            data = f.read()

        # 提取 ASCII 字符串（长度 >= 4）
        strings = _extract_strings(data, min_len=4)
        matched_strings = [s for s in strings if keyword_lower in s.lower()]

        if matched_strings:
            # 读取 metadata
            meta = _read_sdi_metadata(sdi_dir, entry)
            func_type = meta.get('functionType', '?') if meta else '?'
            size = meta.get('metallibSize', 0) if meta else 0

            matches.append({
                'cacheKey': entry,
                'functionType': func_type,
                'metallibSize': size,
                'matched': matched_strings[:10],  # 最多显示 10 个匹配
            })

    if not matches:
        print(f"  未找到包含 \"{keyword}\" 的 shader")
        return 1

    # 按 functionType 分组显示
    print(f"找到 {len(matches)} 个匹配的 shader:\n")

    by_type = {}
    for m in matches:
        ft = m['functionType']
        by_type.setdefault(ft, []).append(m)

    for ft in sorted(by_type.keys()):
        entries = by_type[ft]
        print(f"  [{ft}] ({len(entries)} 个)")
        for m in entries:
            ck = m['cacheKey']
            size = m['metallibSize']
            matched_preview = ', '.join(m['matched'][:3])
            if len(m['matched']) > 3:
                matched_preview += f" ... (+{len(m['matched'])-3})"
            print(f"    {ck}  (size={size})")
            if verbose:
                print(f"      匹配: {matched_preview}")
        print()

    # 如果只有少量匹配，显示提取命令
    if len(matches) <= 6:
        print("提取命令:")
        for m in matches:
            print(f"  python3 {sys.argv[0]} --cache-key {m['cacheKey']} --shader-name <NAME>")

    return 0


def _extract_strings(data: bytes, min_len: int = 4) -> list:
    """从二进制数据中提取 ASCII 可读字符串。"""
    strings = []
    current = []
    for byte in data:
        if 32 <= byte <= 126:
            current.append(chr(byte))
        else:
            if len(current) >= min_len:
                strings.append(''.join(current))
            current = []
    if len(current) >= min_len:
        strings.append(''.join(current))
    return strings


# === 提取功能 ===
def extract_shader(sdi_dir: str, cache_key: str, output_dir: str,
                   shader_name: Optional[str], lib_ptr: Optional[str],
                   llvm_dis_path: Optional[str],
                   no_ir: bool, no_metallib: bool, no_bitcode: bool,
                   verbose: bool) -> bool:
    """从 ShaderDebugInfo 提取 shader 到 output_dir。"""
    info = get_sdi_info(sdi_dir, cache_key)
    if not info:
        print(f"ERROR: ShaderDebugInfo 条目不存在: {cache_key}", file=sys.stderr)
        return False

    func_type = info.get('functionType', 'unknown')

    # 确定输出文件名前缀
    if shader_name:
        prefix = shader_name
    else:
        prefix = cache_key.rsplit('_', 1)[0]

    # 文件命名
    if lib_ptr:
        base_name = f"{prefix}_{func_type}_lib{lib_ptr}"
    else:
        base_name = f"{prefix}_{func_type}"

    os.makedirs(output_dir, exist_ok=True)
    results = []

    # 1. 复制 metallib
    if not no_metallib and os.path.exists(info['metallib']):
        dst = os.path.join(output_dir, f"{base_name}.metallib")
        shutil.copy2(info['metallib'], dst)
        results.append(f"metallib → {os.path.basename(dst)}")

    # 2. 复制 bitcode
    if not no_bitcode and 'bitcode' in info:
        dst = os.path.join(output_dir, f"{base_name}.bc")
        shutil.copy2(info['bitcode'], dst)
        results.append(f"bitcode → {os.path.basename(dst)}")

    # 3. 生成 IR (.ll)
    if not no_ir and 'bitcode' in info:
        ll_dst = os.path.join(output_dir, f"{base_name}.ll")
        if llvm_dis_path:
            result = subprocess.run(
                [llvm_dis_path, '-o', ll_dst, info['bitcode']],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                results.append(f"IR → {os.path.basename(ll_dst)}")
            else:
                print(f"  WARNING: llvm-dis failed: {result.stderr.strip()}", file=sys.stderr)
                results.append("IR generation failed")
        else:
            results.append("IR skipped (llvm-dis not found)")

    # 输出结果
    print(f"\n  [{func_type}] {cache_key}")
    if lib_ptr:
        print(f"  library: {lib_ptr}")
    for r in results:
        print(f"    {r}")

    return True


# === 映射表管理 ===
def load_map(map_file: str) -> dict:
    """加载映射表，过滤掉内部元数据键。"""
    if not os.path.exists(map_file):
        return {}
    with open(map_file) as f:
        data = json.load(f)
    # 过滤内部键
    return {k: v for k, v in data.items() if not k.startswith("__")}


def save_map(map_file: str, lib_map: dict):
    """保存映射表。"""
    with open(map_file, 'w') as f:
        json.dump(lib_map, f, indent=2, ensure_ascii=False)


def add_to_map(map_file: str, lib_ptr_hex: str, cache_key: str,
               func_type: str = "", shader_name: str = "", note: str = ""):
    """向映射表中添加一条记录。"""
    lib_map = load_map(map_file)
    lib_map[lib_ptr_hex] = {
        "cacheKey": cache_key,
        "functionType": func_type,
        "shaderName": shader_name,
        "note": note,
    }
    save_map(map_file, lib_map)


def resolve_library_to_cachekey(lib_ptr_hex: str, gputrace_dir: str, sdi_dir: str,
                                map_file: str, verbose: bool = False) -> Optional[str]:
    """
    解析 library 地址到 cacheKey。
    
    1. 先查映射表
    2. 映射表没有则尝试自动推断:
       - 解压 store0，遍历所有 metallib
       - 对每个 metallib 用 compute_cache_key 计算 cacheKey
       - 在 SDI 中验证存在
       - 如果能通过 metallib size 唯一匹配到某个 library，就自动绑定
    3. 自动推断失败则提示用户手动指定
    """
    # 1. 查映射表
    lib_map = load_map(map_file)
    if lib_ptr_hex in lib_map:
        return lib_map[lib_ptr_hex].get('cacheKey')

    # 尝试不同格式的地址
    lib_ptr_int = int(lib_ptr_hex, 16)
    for k, v in lib_map.items():
        try:
            if int(k, 16) == lib_ptr_int:
                return v.get('cacheKey')
        except (ValueError, TypeError):
            continue

    # 2. 自动推断
    print(f"\n  library {lib_ptr_hex} 不在映射表中，尝试自动推断...")

    store0_path = os.path.join(gputrace_dir, 'store0')
    if not os.path.exists(store0_path):
        print(f"  ERROR: store0 不存在，无法自动推断", file=sys.stderr)
        return None

    # 解压并扫描
    store0_data = decompress_store0(store0_path)
    metallibs = find_metallibs_in_store0(store0_data)

    # 对每个 metallib 计算 cacheKey
    available_entries = []
    for pos, size, data in metallibs:
        ck = compute_cache_key(data)
        entry_path = os.path.join(sdi_dir, ck)
        if os.path.isdir(entry_path):
            meta = _read_sdi_metadata(sdi_dir, ck)
            if meta:
                available_entries.append(meta)

    if not available_entries:
        print("  ERROR: 无法找到匹配的 ShaderDebugInfo 条目", file=sys.stderr)
        return None

    # 按 functionType 分组显示候选列表
    print(f"\n  找到 {len(available_entries)} 个可用的 ShaderDebugInfo 条目")
    print(f"  请从以下列表中选择 library {lib_ptr_hex} 对应的条目:\n")

    # 分组
    by_type = {}
    for entry in available_entries:
        ft = entry.get('functionType', 'unknown')
        by_type.setdefault(ft, []).append(entry)

    for ft, entries in sorted(by_type.items()):
        print(f"  === {ft} ({len(entries)} 个) ===")
        for i, e in enumerate(entries[:20]):  # 最多显示 20 个
            ck = e['cacheKey']
            size = e.get('metallibSize', 0)
            print(f"    {ck}  (size={size})")
        if len(entries) > 20:
            print(f"    ... 还有 {len(entries) - 20} 个")

    print(f"\n  使用以下命令手动添加映射:")
    print(f"    python3 {sys.argv[0]} --add-map {lib_ptr_hex} <cacheKey> [--func-type vertex|fragment] [--shader-name Name]")
    print(f"\n  或使用 --cache-key 模式直接提取:")
    print(f"    python3 {sys.argv[0]} --cache-key <cacheKey> --shader-name <Name>")

    return None


# === CLI ===
def parse_args():
    parser = argparse.ArgumentParser(
        description="从 ShaderDebugInfo 提取 shader IR 到 ShaderRaw 目录",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # 操作模式
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-map", action="store_true",
                      help="全量构建映射表（扫描 store0 + SDI）")
    mode.add_argument("--add-map", nargs=2, metavar=("LIB_PTR", "CACHE_KEY"),
                      help="手动添加一条 library_ptr → cacheKey 映射")
    mode.add_argument("--list", action="store_true",
                      help="列出映射表中的所有条目")
    mode.add_argument("--search",
                      help="按关键字搜索 shader（在 metallib 字符串中匹配 uniform/struct 名称）")

    # 提取参数
    parser.add_argument("--library", action="append", dest="libraries",
                        help="Library 地址 (hex, e.g. 0x7b12cf580)，可多次指定")
    parser.add_argument("--cache-key", action="append", dest="cache_keys",
                        help="直接指定 cacheKey，可多次指定")

    # 路径配置
    parser.add_argument("--gputrace", default=DEFAULT_GPUTRACE,
                        help="gputrace bundle 路径")
    parser.add_argument("--shader-debug-info", default=DEFAULT_SDI_DIR,
                        help="ShaderDebugInfo 目录路径")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help="输出目录 (ShaderRaw)")
    parser.add_argument("--map-file", default=MAP_FILE,
                        help="映射表 JSON 文件路径")

    # 输出选项
    parser.add_argument("--shader-name",
                        help="Shader 名称前缀")
    parser.add_argument("--func-type", choices=["vertex", "fragment", "kernel"],
                        help="函数类型（用于 --add-map）")
    parser.add_argument("--note", default="",
                        help="备注（用于 --add-map）")
    parser.add_argument("--no-ir", action="store_true",
                        help="不生成 .ll 文件")
    parser.add_argument("--no-metallib", action="store_true",
                        help="不复制 .metallib 文件")
    parser.add_argument("--no-bitcode", action="store_true",
                        help="不复制 .bc 文件")
    parser.add_argument("--verbose", "-v", action="store_true")

    return parser.parse_args()


def main():
    args = parse_args()
    sdi_dir = os.path.expanduser(args.shader_debug_info)

    # === 列出映射表 ===
    if args.list:
        lib_map = load_map(args.map_file)
        if not lib_map:
            print("映射表为空或不存在")
            print(f"  路径: {args.map_file}")
            print("  使用 --add-map 或 --build-map 创建")
            return 0

        print(f"映射表: {args.map_file}")
        print(f"条目数: {len(lib_map)}\n")
        for lib_ptr, info in sorted(lib_map.items()):
            if isinstance(info, dict):
                ft = info.get('functionType', '?')
                ck = info.get('cacheKey', '?')
                name = info.get('shaderName', '')
                print(f"  {lib_ptr:20s} → {ck:30s} [{ft:8s}] {name}")
        return 0

    # === 搜索 shader ===
    if args.search:
        return search_shader(sdi_dir, args.search, verbose=args.verbose)

    # === 添加映射 ===
    if args.add_map:
        lib_ptr_hex, cache_key = args.add_map
        lib_ptr_hex = lib_ptr_hex.lower()
        if not lib_ptr_hex.startswith("0x"):
            lib_ptr_hex = "0x" + lib_ptr_hex

        # 验证 cacheKey 存在
        if not os.path.isdir(os.path.join(sdi_dir, cache_key)):
            print(f"WARNING: ShaderDebugInfo 条目不存在: {cache_key}", file=sys.stderr)

        # 自动检测 functionType
        func_type = args.func_type or ""
        if not func_type:
            meta = _read_sdi_metadata(sdi_dir, cache_key)
            if meta:
                func_type = meta.get('functionType', '')

        add_to_map(args.map_file, lib_ptr_hex, cache_key,
                   func_type=func_type,
                   shader_name=args.shader_name or "",
                   note=args.note)

        print(f"已添加映射: {lib_ptr_hex} → {cache_key} [{func_type}]")
        return 0

    # === 构建映射表 ===
    if args.build_map:
        gputrace_dir = os.path.expanduser(args.gputrace)
        result = build_full_map(gputrace_dir, sdi_dir, verbose=args.verbose)

        # 只保存用户映射部分（不保存内部元数据）
        user_map = {k: v for k, v in result.items() if not k.startswith("__")}
        save_map(args.map_file, user_map)
        print(f"\n映射表已保存: {args.map_file} ({len(user_map)} 条)")
        return 0

    # === 按 cacheKey 提取 ===
    if args.cache_keys:
        output_dir = os.path.expanduser(args.output_dir)
        llvm_dis = find_llvm_dis()
        if not llvm_dis and not args.no_ir:
            print("WARNING: llvm-dis 未找到，将跳过 IR 生成", file=sys.stderr)

        print(f"输出目录: {output_dir}")
        for cache_key in args.cache_keys:
            extract_shader(
                sdi_dir, cache_key, output_dir,
                shader_name=args.shader_name, lib_ptr=None,
                llvm_dis_path=llvm_dis,
                no_ir=args.no_ir, no_metallib=args.no_metallib,
                no_bitcode=args.no_bitcode, verbose=args.verbose
            )
        return 0

    # === 按 library 地址提取 ===
    if args.libraries:
        gputrace_dir = os.path.expanduser(args.gputrace)
        output_dir = os.path.expanduser(args.output_dir)
        llvm_dis = find_llvm_dis()
        if not llvm_dis and not args.no_ir:
            print("WARNING: llvm-dis 未找到，将跳过 IR 生成", file=sys.stderr)

        print(f"输出目录: {output_dir}")
        success_count = 0

        for lib_ptr_str in args.libraries:
            lib_ptr_hex = lib_ptr_str.lower()
            if not lib_ptr_hex.startswith("0x"):
                lib_ptr_hex = "0x" + lib_ptr_hex

            # 解析映射
            cache_key = resolve_library_to_cachekey(
                lib_ptr_hex, gputrace_dir, sdi_dir, args.map_file,
                verbose=args.verbose
            )
            if not cache_key:
                continue

            # 获取 shader_name
            lib_map = load_map(args.map_file)
            entry = lib_map.get(lib_ptr_hex, {})
            shader_name = args.shader_name or entry.get('shaderName')

            ok = extract_shader(
                sdi_dir, cache_key, output_dir,
                shader_name=shader_name, lib_ptr=lib_ptr_hex,
                llvm_dis_path=llvm_dis,
                no_ir=args.no_ir, no_metallib=args.no_metallib,
                no_bitcode=args.no_bitcode, verbose=args.verbose
            )
            if ok:
                success_count += 1

        print(f"\n完成: {success_count}/{len(args.libraries)} 个 shader 已提取")
        return 0 if success_count == len(args.libraries) else 1

    # 未指定操作
    print("用法:")
    print("  提取 shader:")
    print("    --library 0x7b12cf580         按 library 地址提取（查映射表）")
    print("    --cache-key <KEY>             按 cacheKey 直接提取")
    print("")
    print("  管理映射:")
    print("    --add-map <LIB_PTR> <KEY>     添加映射条目")
    print("    --build-map                   全量扫描并构建映射表")
    print("    --list                        列出所有映射")
    print("")
    print("  选项:")
    print("    --shader-name <NAME>          输出文件名前缀")
    print("    --output-dir <DIR>            输出目录")
    print("    --no-ir / --no-metallib / --no-bitcode")
    print("")
    print("  使用 --help 查看完整选项")
    return 1


if __name__ == "__main__":
    sys.exit(main())
