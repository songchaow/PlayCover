#!/usr/bin/env python3
"""从当前位置步进，每到一个新 Render Encoder 就收集 summary。

策略: 步进 draw call，检测 RE 变化时收集一次 summary。
由于步进很慢，限制总步数。
"""
import sys, os, json, time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from xcode_gpu_ops import XcodeGPU

DATA_FILE = os.path.join(os.path.dirname(__file__), "key_pass_details.json")

max_steps = int(sys.argv[1]) if len(sys.argv) > 1 else 500

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
        print(f"Step {step}: -> {new_cb} > {new_re}", file=sys.stderr, flush=True)
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
                with open(DATA_FILE, "w") as f:
                    json.dump(results, f, indent=2, ensure_ascii=False)
                
                print(f"  Pipeline: {s.get('pipeline_state', 'N/A')}, "
                      f"V: {s.get('vertex_function', 'N/A')}, "
                      f"F: {s.get('fragment_function', 'N/A')}, "
                      f"Attachments: {len(s.get('attachments', []))}", 
                      file=sys.stderr, flush=True)
            except Exception as e:
                print(f"  ⚠ summary 失败: {e}", file=sys.stderr)
        
        # 如果回到已访问过的 CB（说明已经遍历完一帧），停止
        if len(visited_re) >= 26:
            print("已收集所有 26 个 RE 的数据", file=sys.stderr)
            break

# 最终保存
with open(DATA_FILE, "w") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)
print(f"=== 完成: 收集了 {len(results)} 个 RE 的详细数据 ===", file=sys.stderr)
