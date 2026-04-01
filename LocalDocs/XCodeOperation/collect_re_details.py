#!/usr/bin/env python3
"""步进遍历 draw call，每到一个新 Render Encoder 就收集完整 summary。

策略: 步进 draw call，通过 breadcrumbs 检测 RE 变化，变化时收集一次
editor summary（pipeline state / vertex & fragment resources / attachments）。

功能特性:
    - 自动检测 Render Encoder 切换
    - 增量保存: 每收集到新 RE 数据立即写入 JSON
    - 自动停止: 收集满指定数量的 RE 后停止（默认 26，一帧的 RE 总数）
    - 可指定最大步数防止无限运行

用法:
    python3 collect_re_details.py              # 默认最多 500 步
    python3 collect_re_details.py 200          # 限制 200 步
    python3 collect_re_details.py -o out.json  # 指定输出路径
    python3 collect_re_details.py --re-count 10  # 只收集 10 个 RE

输出: key_pass_details.json — [{command_buffer, render_encoder, draw_call, summary}]

注意:
    - editor summary 每次约 25-30s，整帧 26 个 RE 约需 15-20 分钟
    - 步进操作会自动跨 Command Buffer 边界
"""
import sys, os, json, time, argparse

from xcode_gpu_ops import XcodeGPU

DEFAULT_DATA_FILE = os.path.join(os.path.dirname(__file__),
                                 "renderanalysistask", "key_pass_details.json")


def collect_render_encoder_details(max_steps: int = 500,
                                   data_file: str = DEFAULT_DATA_FILE,
                                   re_count: int = 26):
    """步进遍历 draw call，收集每个 Render Encoder 的完整 summary。"""
    os.makedirs(os.path.dirname(data_file), exist_ok=True)

    gpu = XcodeGPU(delay_after_action=0.2)

    # 读取当前位置
    bc = gpu.read_breadcrumbs()
    current_re = bc.get("render_encoder", "")
    current_cb = bc.get("command_buffer", "")
    print(f"开始位置: {current_cb} > {current_re}", file=sys.stderr)

    results = []
    visited_re = set()

    # 收集当前位置的 summary
    print(f"收集 {current_re} summary...", file=sys.stderr)
    try:
        s = gpu.read_editor_summary()
        results.append({
            "command_buffer": current_cb,
            "render_encoder": current_re,
            "draw_call": bc.get("draw_call", ""),
            "summary": s
        })
        visited_re.add(current_re)
    except Exception as e:
        print(f"  ⚠ summary 失败: {e}", file=sys.stderr)

    for step in range(max_steps):
        gpu.step_next_draw_call()
        time.sleep(0.3)

        bc = gpu.read_breadcrumbs()
        new_re = bc.get("render_encoder", "")
        new_cb = bc.get("command_buffer", "")

        if new_re != current_re:
            print(f"Step {step}: -> {new_cb} > {new_re}",
                  file=sys.stderr, flush=True)
            current_re = new_re
            current_cb = new_cb

            if current_re not in visited_re:
                print(f"  收集 summary...", file=sys.stderr, flush=True)
                try:
                    s = gpu.read_editor_summary()
                    results.append({
                        "command_buffer": current_cb,
                        "render_encoder": current_re,
                        "draw_call": bc.get("draw_call", ""),
                        "summary": s
                    })
                    visited_re.add(current_re)

                    # 保存中间结果
                    with open(data_file, "w") as f:
                        json.dump(results, f, indent=2, ensure_ascii=False)

                    print(f"  Pipeline: {s.get('pipeline_state', 'N/A')}, "
                          f"V: {s.get('vertex_function', 'N/A')}, "
                          f"F: {s.get('fragment_function', 'N/A')}, "
                          f"Attachments: {len(s.get('attachments', []))}",
                          file=sys.stderr, flush=True)
                except Exception as e:
                    print(f"  ⚠ summary 失败: {e}", file=sys.stderr)

            # 如果已收集足够数量的 RE，停止
            if len(visited_re) >= re_count:
                print(f"已收集所有 {re_count} 个 RE 的数据", file=sys.stderr)
                break

    # 最终保存
    with open(data_file, "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"=== 完成: 收集了 {len(results)} 个 RE 的详细数据 ===", file=sys.stderr)
    return results


def main():
    parser = argparse.ArgumentParser(
        description="步进遍历 draw call，收集每个 Render Encoder 的 GPU 绑定详情")
    parser.add_argument("max_steps", type=int, nargs="?", default=500,
                        help="最大步进次数 (默认 500)")
    parser.add_argument("-o", "--output", default=DEFAULT_DATA_FILE,
                        help="输出 JSON 路径")
    parser.add_argument("--re-count", type=int, default=26,
                        help="目标 Render Encoder 数量 (默认 26)")
    args = parser.parse_args()
    collect_render_encoder_details(args.max_steps, args.output, args.re_count)


if __name__ == "__main__":
    main()
