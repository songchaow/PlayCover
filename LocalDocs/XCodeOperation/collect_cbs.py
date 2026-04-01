#!/usr/bin/env python3
"""批量收集所有 Command Buffer 的 Render Encoder 列表。

遍历 GPU Frame Capture 中的每个 Command Buffer，展开后读取其子节点
（Render Encoder / presentDrawable），将结构化数据写入 JSON 文件。

功能特性:
    - 断点续传: 读取已有 JSON 数据，自动跳过已收集的 CB
    - 增量保存: 每收集完一个 CB 就立即写入文件，中断不丢失
    - 可指定起始 CB 编号，从中途恢复

用法:
    python3 collect_cbs.py                     # 从头开始
    python3 collect_cbs.py 5                   # 从第 5 个 CB 开始
    python3 collect_cbs.py -o /tmp/cbs.json    # 指定输出路径

输出: cb_data.json — {CB名: [子节点文本列表]}
"""
import sys, os, json, time, argparse

from xcode_gpu_ops import XcodeGPU

DEFAULT_DATA_FILE = os.path.join(os.path.dirname(__file__),
                                 "renderanalysistask", "cb_data.json")


def collect_command_buffers(start_from: int = 0, data_file: str = DEFAULT_DATA_FILE):
    """收集所有 Command Buffer 的子节点信息。"""
    # 断点续传: 读取已有数据
    if os.path.exists(data_file):
        with open(data_file) as f:
            try:
                result = json.load(f)
            except json.JSONDecodeError:
                result = {}
    else:
        os.makedirs(os.path.dirname(data_file), exist_ok=True)
        result = {}

    gpu = XcodeGPU(delay_after_action=0.8)

    print("=== 开始收集 Command Buffer 概览 ===", file=sys.stderr)

    # 获取初始 nav
    rows = gpu.list_navigator_rows()
    cb_rows = [r for r in rows if r["text"].startswith("Command Buffer")]
    print(f"共 {len(cb_rows)} 个 Command Buffer, 从 #{start_from} 开始", file=sys.stderr)

    # 折叠所有已展开的 CB
    for cb in cb_rows:
        if cb["expanded"]:
            print(f"  折叠 {cb['text']} (index={cb['index']})", file=sys.stderr)
            try:
                gpu.select_navigator_row(cb["index"])
                time.sleep(0.3)
                gpu.collapse_navigator_row(cb["index"])
                time.sleep(0.5)
            except Exception as e:
                print(f"  ⚠ 折叠失败: {e}", file=sys.stderr)

    # 重新读取折叠后的状态
    rows = gpu.list_navigator_rows()
    cb_rows = [r for r in rows if r["text"].startswith("Command Buffer")]

    for i in range(start_from, len(cb_rows)):
        cb = cb_rows[i]
        cb_name = cb["text"]
        cb_index = cb["index"]

        if cb_name in result and len(result[cb_name]) > 0:
            print(f"[{i+1}/{len(cb_rows)}] 跳过 {cb_name} "
                  f"(已有 {len(result[cb_name])} 个子节点)", file=sys.stderr)
            continue

        print(f"[{i+1}/{len(cb_rows)}] 展开 {cb_name} (index={cb_index})...",
              file=sys.stderr)

        try:
            # 关键: 先 select 让行滚动到可见区域
            gpu.select_navigator_row(cb_index)
            time.sleep(0.5)

            # 展开当前 CB
            gpu.expand_navigator_row(cb_index)
            time.sleep(1.0)

            # 读取展开后的 nav
            all_rows = gpu.list_navigator_rows()

            # 找到当前 CB 在展开后列表中的真实 index
            real_cb_idx = None
            for r in all_rows:
                if r["text"] == cb_name and r["selected"]:
                    real_cb_idx = r["index"]
                    break
            if real_cb_idx is None:
                for r in all_rows:
                    if r["text"] == cb_name:
                        real_cb_idx = r["index"]
                        break

            # 找到当前 CB 的子节点
            children = []
            if real_cb_idx is not None:
                for j in range(real_cb_idx + 1, len(all_rows)):
                    r = all_rows[j]
                    if r["text"].startswith("Command Buffer"):
                        break
                    children.append(r["text"])

            result[cb_name] = children
            print(f"  -> {len(children)} 个子节点", file=sys.stderr)

            # 立即保存
            with open(data_file, "w") as f:
                json.dump(result, f, indent=2, ensure_ascii=False)

            # 折叠当前 CB, 先 select 确保可见
            idx = real_cb_idx if real_cb_idx is not None else cb_index
            gpu.select_navigator_row(idx)
            time.sleep(0.3)
            gpu.collapse_navigator_row(idx)
            time.sleep(0.5)

            # 刷新 cb_rows 保证 index 正确
            rows = gpu.list_navigator_rows()
            cb_rows = [r for r in rows if r["text"].startswith("Command Buffer")]

        except Exception as e:
            print(f"  ❌ 错误: {e}", file=sys.stderr)
            with open(data_file, "w") as f:
                json.dump(result, f, indent=2, ensure_ascii=False)
            print(f"  已保存 {len(result)} 个 CB 的数据到 {data_file}", file=sys.stderr)
            print(f"  可使用 python3 collect_cbs.py {i} 继续", file=sys.stderr)
            sys.exit(1)

    # 最终保存
    with open(data_file, "w") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"=== 收集完成: {len(result)} 个 CB ===", file=sys.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(
        description="批量收集 GPU Frame Capture 中所有 Command Buffer 的子节点")
    parser.add_argument("start", type=int, nargs="?", default=0,
                        help="起始 CB 编号 (0-based，用于断点续传)")
    parser.add_argument("-o", "--output", default=DEFAULT_DATA_FILE,
                        help="输出 JSON 路径")
    args = parser.parse_args()
    collect_command_buffers(args.start, args.output)


if __name__ == "__main__":
    main()
