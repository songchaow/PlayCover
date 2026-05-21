# 05 — 复现 / 工具 / 数据 schema

## 1. 复现入口（从零开始）

```bash
# 1) 准备 bridge（幂等）
SKILL_DIR=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")

# 2) 设定 trace
TRACE=$HOME/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace

# 3) 4 条核心命令（与本目录 data/ 中的 JSON 一一对应）
"$BRIDGE" replay "$TRACE" --bounds         > data/bounds.json
"$BRIDGE" replay "$TRACE" --list-resources > data/replay.json
"$BRIDGE" pipeline "$TRACE" /tmp/lysk-pipelines  > data/pipelines.json
"$BRIDGE" frame-list "$TRACE"              > data/frame.json
```

> 4 条命令的 wall-clock 总耗时 ~30s（M 系列）。

## 2. 本文档目录里 `data/` 7 个 JSON 速查

| 文件 | 由什么命令产出 | 主键 / 重要字段 |
|---|---|---|
| `bounds.json` | `replay --bounds` | `total_call_count` |
| `replay.json` | `replay --list-resources` | `resources[].{id,width,height,pixelFormatName,label,usage}` |
| `pipelines.json` | `pipeline` | `render_pipeline_states[].{key,label,vertex_function_key,fragment_function_key,vertex_library_key,fragment_library_key,color_attachment_count,depth_format}`, `compute_pipeline_states[]`, `libraries_count` |
| `frame.json` | `frame-list` | `command_buffers[].encoders[].{index,type,first_call_index,last_call_index,draw_count,color_attachments[],depth_attachment,draws[]}`, `draw_to_rps_map[]` |
| `cb1_summary.json` | jq 派生 | CB1 的 30 个 encoder 一行式精简 |
| `cb3_summary.json` | jq 派生 | CB3 的 30 个 encoder 一行式精简（用于校验双缓冲对称） |
| `rps_index.json` | jq 派生 | 65 个 RPS 精简表 |
| `textures_index.json` | jq 派生 | 247 个资源中所有 texture 的精简表 |

派生 JSON 的生成方式：

```bash
# cb1 / cb3 摘要
jq '[.command_buffers[1].encoders[] | {idx:.index, type, calls:[.first_call_index,.last_call_index], draws:.draw_count, color:[.color_attachments[]?|{tex:.texture_id,fmt:.format}], depth:.depth_attachment, rps:([.draws[]?.rps_key]|unique)}]' \
   data/frame.json > data/cb1_summary.json

jq '[.command_buffers[3].encoders[] | {idx:.index, type, calls:[.first_call_index,.last_call_index], draws:.draw_count, color:[.color_attachments[]?|{tex:.texture_id,fmt:.format}], depth:.depth_attachment, rps:([.draws[]?.rps_key]|unique)}]' \
   data/frame.json > data/cb3_summary.json

# RPS / 纹理索引
jq '[.render_pipeline_states[] | {key,label,vertex_function_key,fragment_function_key,vertex_library_key,fragment_library_key,color_attachment_count,depth_format,stencil_format}]' \
   data/pipelines.json > data/rps_index.json

jq '[.resources[] | select(.type=="texture") | {id, w:.width, h:.height, format:.pixelFormatName, label, usage}]' \
   data/replay.json > data/textures_index.json
```

## 3. 常用 jq 速查（直接拷可跑）

```bash
cd /Users/songdogwang/Codes/PlayCover/LocalDocs/LYSKGPUTraceAnalysis

# 3.1 CB1 一行式 encoder 流水线
jq -r '.[] | "E\(.idx) \(.type) calls=\(.calls[0])-\(.calls[1]) draws=\(.draws) color=\([.color[]?|"\(.tex):\(.fmt)"]|join(",")) depth=\(.depth.texture_id // "-"):\(.depth.format // "-") rps=\(.rps|@csv)"' \
   data/cb1_summary.json

# 3.2 找一个 RPS 的所有 draw（含 encoder 索引、ic 数）
jq '.draw_to_rps_map[] | select(.rps_key==496)' data/frame.json

# 3.3 找一种 label（如所有 SkinMakeupNew）的所有 RPS
jq -r '.[] | select(.label | contains("SkinMakeupNew")) | "\(.key) \(.label) vf=\(.vertex_function_key)/\(.fragment_function_key) lib=\(.vertex_library_key)/\(.fragment_library_key) color#=\(.color_attachment_count)"' \
   data/rps_index.json

# 3.4 所有 attachment 用过的纹理 ID（去重）
jq '[.command_buffers[].encoders[]?.color_attachments[]?.texture_id, .command_buffers[].encoders[]?.depth_attachment.texture_id // empty] | map(select(.!=null)) | unique' \
   data/frame.json

# 3.5 所有 ic=27894 的 draw（如皮肤几何在哪些 pass 出现）
jq '.command_buffers[].encoders[].draws[]? | select(.index_count==27894) | {idx:.draw_index_global, rps:.rps_key, lbl:.rps_label}' \
   data/frame.json
```

## 4. 拉 IR 的快速命令

```bash
BRIDGE=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge
WRAPPER=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py
TRACE=$HOME/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
OUT=/tmp/lysk-shaders

# RPS → IR
"$BRIDGE" shader-of-rps "$TRACE" 496 --with-ir --output-dir "$OUT/rps_496"

# library_key → IR（跳过 RPS 这一跳）
"$BRIDGE" disasm "$TRACE" 411 --with-ir --output-dir "$OUT/lib_411"  # 注：411 是 fragment_library_key 示例

# draw_index → IR + bindings + uniforms（一行命令三件套，皮肤合成 draw）
python3 "$WRAPPER" shader-of-drawcall "$TRACE" 69 \
    --stage fragment --with-ir --with-uniforms \
    --output-dir "$OUT/draw_69"
```

## 5. 资源导出（截屏式分析）

```bash
# 把主 HDR 场景颜色 224 dump 出来（RGBA16F bytes）
"$BRIDGE" replay "$TRACE" --export 224 /tmp/scene_224.bin

# 把 swapchain 147（CB1 输出）dump 出来
"$BRIDGE" replay "$TRACE" --export 147 /tmp/swapchain_147.bin

# GBuffer
"$BRIDGE" replay "$TRACE" --export 228 /tmp/gbuf0.bin
"$BRIDGE" replay "$TRACE" --export 229 /tmp/gbuf1.bin

# 半分辨率 SSS 链路三张关键图
"$BRIDGE" replay "$TRACE" --export 232 /tmp/skin_lighting_after_sss.bin
"$BRIDGE" replay "$TRACE" --export 237 /tmp/sss_h_blur.bin
"$BRIDGE" replay "$TRACE" --export 234 /tmp/sss_mask_or_ao.bin
```

> ⚠ Depth/Stencil 纹理（225/226/227/231/139）`--export` 当前会拒绝（R7.5 子项 A）。要看 depth 必须写一个 sample-into-color 的 shader 替代，或等 R7.5 落地。

## 6. CB1 vs CB3 对称性校验（可选）

```bash
# 简单字节级对比 encoder 顺序、attachment 形状（应只有「TAA history 互换 + swapchain 互换」差异）
diff <(jq -r '.[] | "E\(.idx) \(.type) draws=\(.draws) color=\(.color|map("\(.fmt)")|join(",")) depth=\(.depth.format // "-")"' data/cb1_summary.json) \
     <(jq -r '.[] | "E\(.idx-31) \(.type) draws=\(.draws) color=\(.color|map("\(.fmt)")|join(",")) depth=\(.depth.format // "-")"' data/cb3_summary.json)
# → 输出应只剩 TAA(E18) 与 swapchain(E30) 两处的 tex_id 不同；其它格式/顺序逐字符相等
```

## 7. Extension Hooks（如需深挖盲区）

| 想拿到的东西 | 当前状态 | 路径 |
|---|---|---|
| `CalcLighting.CSMain` 的 dispatch 网格 / threadgroup size | ❌ | 给 bridge 加 `setComputePipelineState:` + `dispatchThreadgroups:*` swizzle（R7.5 子项 B），输出到 `frame-list` 的 compute encoder `dispatches[]` 字段 |
| 每个 attachment 的 loadAction / storeAction | ❌ | 给 bridge 加 `MTLRenderPassDescriptor` 拷贝读取（R7 backlog），目前 `frame-list` 的 `color_attachments[].loadAction/storeAction` 输出为 null |
| Depth / Stencil 纹理可视化导出 | ❌ | R7.5 子项 A — 在 bridge 内部用 blit 转成 R32F color → 再 export |
| GUI 名（如 "Subsurface" or "FSR_RCAS"）→ draw_index 反查 | ❌ | R7.6-E（wrapper-only，<1 天，依赖现有 frame-list label） |
| GPU 时间 / per-encoder ms | ❌ | 该 trace 内 CB 没 `commit`，`GPUStartTime/GPUEndTime` 全 0；用 `replay --playto N` host-side 二分作替代 |

## 8. 工具版本

- bridge：`.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge`（R7.7，`setup.sh` 当时构建）
- wrapper：`.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py`
- macOS / GPU：Apple Silicon（`AGXG16XFamilyComputePipeline` 出现 ⇒ M3 family；M1/M2 也兼容）
- jq：随系统

## 9. 时间戳

- 分析跑通时间：2026-05-21
- bridge 集成测试基线：148/148（详见 `LocalDocs/GPUTraceReplayAutomation/README.md`）
- 对应 trace 捕获时间：2026-05-18 11:00:50（文件名）

## 10. 后续可以做的事

1. **跨 trace 对比**：另抓一份「皮肤显示异常」的 trace，跑同样 4 条命令，diff `cb1_summary.json` / `rps_index.json` 即可一眼看出新增 / 缺失 / 顺序变化。
2. **半分辨率 lighting 分桶可视化**：把 234（SSS-mask + AO 复用）单独导出可视化为热度图，能直接看出 LYSK 的「哪些像素走 SSS」决策面。
3. **TAA 历史对账**：用 CB1 写出的 239 与 CB3 读到的 239 做字节级 hash 对比，验证 LastFrame chain 一致性。
4. **Bloom 金字塔覆盖率分析**：导出 240–244 五张图叠加为热度图，可估每级 bloom 的能量分布。
