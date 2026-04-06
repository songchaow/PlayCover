#!/usr/bin/env python3
"""
check_gputrace_sources.py — 检查 `.gputrace` 中 shader 源码覆盖率，并可选归因到当前 `ShaderCorpus` / run snapshot。

用法:
    python3 check_gputrace_sources.py /path/to/xxx.gputrace
    python3 check_gputrace_sources.py /path/to/xxx.gputrace --bundle-dir /path/to/ShaderCorpus/<bundleId>
    python3 check_gputrace_sources.py /path/to/xxx.gputrace --diff /path/to/baseline.json
    python3 check_gputrace_sources.py /path/to/xxx.gputrace --save-baseline baseline.json

输出:
    - hex hash 文件数量、合法 MSL 数量、非 MSL 数量
    - `index` 引用总数，以及基于 `valid_msl_files` 的覆盖率
    - 每个可见 hash 文件的首行特征
    - 可选：把可见 MSL 归因到 `module.generated.metal` / `aggregate.generated.metal`
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from gputrace_attribution import build_gputrace_attribution_for_paths
from gputrace_sources import inspect_gputrace_dir



def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="检查 gputrace shader 源码覆盖率")
    parser.add_argument("gputrace", help=".gputrace 目录路径")
    parser.add_argument("--bundle-dir", help="可选：用于归因的 bundle 目录（如 ShaderCorpus/<bundleId> 或快照 bundle 目录）")
    parser.add_argument("--diff", metavar="BASELINE", help="与基线 JSON 对比，显示变化")
    parser.add_argument("--save-baseline", metavar="OUTPUT", help="保存当前结果为基线 JSON")
    parser.add_argument("--json", action="store_true", help="输出 JSON 格式")
    return parser.parse_args()



def convert_files_for_cli(summary: dict[str, Any]) -> dict[str, dict[str, Any]]:
    files = summary.get("files") if isinstance(summary.get("files"), dict) else {}
    return {
        name: {
            "size": file_info.get("size"),
            "lines": file_info.get("lines"),
            "first_line": file_info.get("firstLine"),
            "is_msl": file_info.get("isMSL"),
        }
        for name, file_info in sorted(files.items())
        if isinstance(file_info, dict)
    }



def build_result(gputrace_path: Path, summary: dict[str, Any], attribution: dict[str, Any] | None) -> dict[str, Any]:
    files = convert_files_for_cli(summary)
    result = {
        "gputrace": gputrace_path.name,
        "source_files": summary.get("sourceFiles", 0),
        "valid_msl_files": summary.get("validMSLFiles", 0),
        "non_msl_files": summary.get("nonMSLFiles", 0),
        "index_hash_references": summary.get("indexHashReferences", -1),
        "coverage_pct": summary.get("coveragePct", 0.0),
        "files": files,
    }
    if attribution is not None:
        result["attribution"] = attribution
    return result



def print_human_readable(result: dict[str, Any]) -> None:
    print("=== gputrace shader 源码检查 ===")
    print(f"路径: {result['gputrace']}")
    print(
        f"hex 文件: {result['source_files']} 个 "
        f"(合法 MSL: {result['valid_msl_files']} / 非 MSL: {result['non_msl_files']})"
    )
    print(f"index 引用: {result['index_hash_references']} 个")
    print(f"覆盖率(valid_msl/index): {float(result['coverage_pct']):.1f}%")
    print()

    files = result.get("files") if isinstance(result.get("files"), dict) else {}
    if files:
        print(f"{'Hash':<20} {'Lines':>6} {'Size':>8} {'MSL':>4}  First Line")
        print("-" * 90)
        for name, file_info in sorted(files.items()):
            print(
                f"{name:<20} {int(file_info.get('lines') or 0):>6} "
                f"{int(file_info.get('size') or 0):>7}B "
                f"{'✅' if file_info.get('is_msl') else '❌':>4}  "
                f"{str(file_info.get('first_line') or '')}"
            )
    else:
        print("⚠️  没有找到任何 shader 源码文件")

    attribution = result.get("attribution") if isinstance(result.get("attribution"), dict) else None
    if attribution is not None:
        print("\n=== 可见 MSL 归因 ===")
        print(
            f"可见 MSL: {attribution.get('visibleMSLFileCount', 0)}，"
            f"已归因: {attribution.get('attributedVisibleMSLFileCount', 0)}，"
            f"未归因: {attribution.get('unattributedVisibleMSLFileCount', 0)}"
        )
        module_keys = attribution.get("attributedModuleKeys") or []
        replacement_dirs = attribution.get("attributedReplacementDirectories") or []
        unattributed_hashes = attribution.get("unattributedVisibleMSLHashes") or []
        print(
            "匹配到的 moduleKey: "
            + (", ".join(module_keys) if module_keys else "<none>")
        )
        print(
            "匹配到的 replacement 目录: "
            + (", ".join(replacement_dirs) if replacement_dirs else "<none>")
        )
        if unattributed_hashes:
            print("未归因可见 MSL hash: " + ", ".join(unattributed_hashes))



def main() -> int:
    args = parse_args()

    gputrace_path = Path(args.gputrace).expanduser().resolve()
    if not gputrace_path.is_dir():
        print(f"ERROR: {gputrace_path} 不是目录", file=sys.stderr)
        return 1

    summary = inspect_gputrace_dir(gputrace_path)
    attribution = None
    if args.bundle_dir:
        bundle_dir = Path(args.bundle_dir).expanduser().resolve()
        if not bundle_dir.is_dir():
            print(f"ERROR: bundle 目录不存在: {bundle_dir}", file=sys.stderr)
            return 1
        attribution = build_gputrace_attribution_for_paths(bundle_dir, gputrace_path, summary)

    result = build_result(gputrace_path, summary, attribution)

    if args.diff:
        baseline_path = Path(args.diff).expanduser().resolve()
        with baseline_path.open("r", encoding="utf-8") as handle:
            baseline = json.load(handle)
        baseline_names = set((baseline.get("files") or {}).keys()) if isinstance(baseline, dict) else set()
        current_names = set((result.get("files") or {}).keys()) if isinstance(result, dict) else set()
        result["diff"] = {
            "baseline_count": len(baseline_names),
            "current_count": len(current_names),
            "added": sorted(current_names - baseline_names),
            "removed": sorted(baseline_names - current_names),
        }

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print_human_readable(result)
        if "diff" in result:
            diff = result["diff"]
            print("\n=== 与基线对比 ===")
            print(f"基线: {diff['baseline_count']} → 当前: {diff['current_count']}")
            if diff["added"]:
                print(f"新增 ({len(diff['added'])}): {', '.join(diff['added'][:10])}{'...' if len(diff['added']) > 10 else ''}")
            if diff["removed"]:
                print(f"删除 ({len(diff['removed'])}): {', '.join(diff['removed'][:10])}{'...' if len(diff['removed']) > 10 else ''}")
            if not diff["added"] and not diff["removed"]:
                print("无变化")

    if args.save_baseline:
        output_path = Path(args.save_baseline).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2, ensure_ascii=False)
        if not args.json:
            print(f"\n基线已保存: {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
