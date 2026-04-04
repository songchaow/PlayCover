#!/usr/bin/env python3
"""
check_gputrace_sources.py — 检查 .gputrace 中 shader 源码覆盖率

用法:
    python3 check_gputrace_sources.py /path/to/xxx.gputrace
    python3 check_gputrace_sources.py /path/to/xxx.gputrace --diff /path/to/baseline.json
    python3 check_gputrace_sources.py /path/to/xxx.gputrace --save-baseline baseline.json

输出:
    - 源码文件数量、index 引用总数、覆盖率
    - 每个源码文件的行数和首行特征
    - --diff 模式下显示新增/删除的源码文件
"""

import argparse
import json
import os
import re
import sys


def find_source_files(gputrace_dir: str) -> dict[str, dict]:
    """扫描 gputrace 目录，找到所有 16 字符 hex 命名的源码文件。"""
    sources = {}
    for name in os.listdir(gputrace_dir):
        if not re.match(r'^[0-9A-F]{16}$', name):
            continue
        path = os.path.join(gputrace_dir, name)
        if not os.path.isfile(path):
            continue
        size = os.path.getsize(path)
        try:
            with open(path, 'r', errors='replace') as f:
                first_line = f.readline().strip()
                line_count = 1 + sum(1 for _ in f)
        except Exception:
            first_line = "<binary>"
            line_count = 0
        # 检查文件是否为合法 MSL：
        # 1. 直接以 #include 或 using 开头
        # 2. 以 // 注释开头但内容包含 metal_stdlib（PlayTools 生成格式）
        if first_line.startswith('#include') or first_line.startswith('using '):
            is_msl = True
        elif first_line.startswith('//'):
            try:
                with open(path, 'r', errors='replace') as fcheck:
                    content_sample = fcheck.read(2048)
                is_msl = 'metal_stdlib' in content_sample or 'PlayTools' in content_sample
            except Exception:
                is_msl = False
        else:
            is_msl = False
        sources[name] = {
            "size": size,
            "lines": line_count,
            "first_line": first_line[:80],
            "is_msl": is_msl,
        }
    return sources


def count_index_hashes(gputrace_dir: str) -> int:
    """统计 index 文件中引用的 16 字符 hex hash 数量。"""
    index_path = os.path.join(gputrace_dir, 'index')
    if not os.path.isfile(index_path):
        return -1
    data = open(index_path, 'rb').read()
    hashes = set(re.findall(rb'[0-9A-F]{16}', data))
    return len(hashes)


def main():
    parser = argparse.ArgumentParser(description='检查 gputrace shader 源码覆盖率')
    parser.add_argument('gputrace', help='.gputrace 目录路径')
    parser.add_argument('--diff', metavar='BASELINE', help='与基线 JSON 对比，显示变化')
    parser.add_argument('--save-baseline', metavar='OUTPUT', help='保存当前结果为基线 JSON')
    parser.add_argument('--json', action='store_true', help='输出 JSON 格式')
    args = parser.parse_args()

    gputrace = args.gputrace
    if not os.path.isdir(gputrace):
        print(f"ERROR: {gputrace} 不是目录", file=sys.stderr)
        sys.exit(1)

    sources = find_source_files(gputrace)
    index_count = count_index_hashes(gputrace)
    msl_count = sum(1 for s in sources.values() if s['is_msl'])
    coverage = (len(sources) / index_count * 100) if index_count > 0 else 0

    result = {
        "gputrace": os.path.basename(gputrace),
        "source_files": len(sources),
        "valid_msl_files": msl_count,
        "index_hash_references": index_count,
        "coverage_pct": round(coverage, 2),
        "files": sources,
    }

    # Diff 模式
    if args.diff:
        with open(args.diff) as f:
            baseline = json.load(f)
        baseline_names = set(baseline.get("files", {}).keys())
        current_names = set(sources.keys())
        added = sorted(current_names - baseline_names)
        removed = sorted(baseline_names - current_names)
        result["diff"] = {
            "baseline_count": len(baseline_names),
            "current_count": len(current_names),
            "added": added,
            "removed": removed,
        }

    # JSON 输出
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"=== gputrace shader 源码检查 ===")
        print(f"路径: {gputrace}")
        print(f"源码文件: {len(sources)} 个 (合法 MSL: {msl_count})")
        print(f"index 引用: {index_count} 个")
        print(f"覆盖率: {coverage:.1f}%")
        print()
        if sources:
            print(f"{'Hash':<20} {'Lines':>6} {'Size':>8} {'MSL':>4}  First Line")
            print("-" * 90)
            for name in sorted(sources.keys()):
                s = sources[name]
                print(f"{name:<20} {s['lines']:>6} {s['size']:>7}B {'✅' if s['is_msl'] else '❌':>4}  {s['first_line']}")
        else:
            print("⚠️  没有找到任何 shader 源码文件")

        if "diff" in result:
            d = result["diff"]
            print(f"\n=== 与基线对比 ===")
            print(f"基线: {d['baseline_count']} → 当前: {d['current_count']}")
            if d["added"]:
                print(f"新增 ({len(d['added'])}): {', '.join(d['added'][:10])}{'...' if len(d['added']) > 10 else ''}")
            if d["removed"]:
                print(f"删除 ({len(d['removed'])}): {', '.join(d['removed'][:10])}{'...' if len(d['removed']) > 10 else ''}")
            if not d["added"] and not d["removed"]:
                print("无变化")

    # 保存基线
    if args.save_baseline:
        with open(args.save_baseline, 'w') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        if not args.json:
            print(f"\n基线已保存: {args.save_baseline}")


if __name__ == '__main__':
    main()
