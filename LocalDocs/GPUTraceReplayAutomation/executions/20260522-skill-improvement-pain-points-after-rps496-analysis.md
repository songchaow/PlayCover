# 20260522 — Skill 痛点回顾：RPS 496 binding 分析中暴露的可改进点

> **场景**：用 `gpu-trace-analysis` skill (R7.7) 在 LYSK trace 上对 RPS 496 / draw 69 做完整 binding + uniform 校验，并修正 `07-skin-forward-lighting.md` 中若干存量错误结论。
>
> **目的**：复盘这次分析里 agent **主动犯错的几次**，分清哪些是 skill 表达力不足导致的（可作为 R8 backlog），哪些是 agent 自身没看清楚的（不归 skill 管）。
>
> **可作为 R8 / R9 backlog 的输入**。

---

## 0. TL;DR — 改进方向优先级

| Pri | 改进项 | 预期收益 | 实现复杂度 |
|---|---|---|---|
| **P0** | per-draw "merged binding view"（slot ↔ IR `arg_name` ↔ resource label / size ↔ IR 期望大小，一表输出） | 杜绝 slot 错位 / IR-binding 名字错位（这次 ~80% 错误的根因） | 低（纯组合现有数据） |
| **P0** | 绑定大小 sanity check（`bound_buffer_length` vs IR `dereferenceable(N)`，标注 `OK / under / over / cross-section`） | 早期发现 cb6 这种"借用 Compute_0"或真 OOB 情况 | 低 |
| **P1** | uniform decode 自带 NaN / inf / denormal 计数 + 字段定位 | 避免 agent 漏掉 NaN（这次 cb5._FresnelColor.x 我差点没注意到） | 低 |
| **P1** | `dump-uniforms --names` 模式：直接按 IR `arg_name` 查询单个字段，不经 bind_slot | 避免 agent 把 slot 5 / slot 6 弄错（这次错误根因） | 低 |
| **P2** | 资源 provenance 反查：`resource-trace <rid>` 列出最近一次写它的 encoder / RPS / draw（"上游谁产的"） | 解决"rid 145 / rid 232 没 label，只能猜"的难题 | 中 |
| **P2** | 双 dump 差异对比：`dump-diff <a.json> <b.json>` 自动列出 cbuffer 字段差异 | 帮 agent 快速发现"已存档 dump 与最新 dump 不一致" | 低 |
| **P3** | host-side shader function 评估器（Pape SH / GGX 等常用 lighting 子函数有限算式） | 让 agent 能"把 cbuffer 值输入公式" 自动 sanity check | 高，需要先选 scope |

---

## 1. 这次分析中 agent 实际犯的 4 次错（事后归因）

### 1.1 把 cb5 误当成 cb6（最严重，最久才发现）

**症状**：在中途的分析里我写过一段"cb5 UnityPerMaterial 实际绑定到 Compute_0 144B，IR 期望 336B → OOB" — 这是**完全错的**。真相：
- frag buf slot 5 → IR `arg_name=UnityPerMaterial`（336B）→ ScratchBuffer @ 110912（足够）。
- frag buf slot 6 → IR `arg_name=PapePerRendererCB`（136B）→ Compute_0 144B（恰好够）。

我把两个 slot 颠倒了。

**为什么会错**：

1. `frame-list` 输出里 `bindings.fragment.buffers[]` 是按 `index` 排序的扁平数组。我看到第 7 项（index=6）是 `Compute_0 144B`，凭直觉觉得"最后一个 slot 是 cb5"，但其实最后一个是 cb6。
2. **没有任何输出告诉我 `slot 5 的 IR 名字是 UnityPerMaterial`**。我得 **`cd $WORK/shaders && grep "air.buffer.*location_index" library_410.ll`** 才能看到映射。这是两个数据源（frame-list JSON + IR `.ll`）的人工对接，agent 的脑内 join 容易出错。
3. 我后来用 `dump-uniforms 69 5` 重新查，输出里有 `binding_name: UnityPerMaterial`、`buffer_size: 336`、`buffer_label: ScratchBuffer0_0` 才纠正过来。**这个信息只在 `dump-uniforms` 单 slot 模式才有，`frame-list` 的 per-draw bindings 不暴露**。

**改进建议（P0）**：在 `frame-list` 的 per-draw `bindings` snapshot 里给每个 buffer / texture 槽位**直接附上 IR `arg_name` 与 IR 期望大小**。新 schema 草案：

```jsonc
"bindings": {
  "fragment": {
    "buffers": [
      {
        "index": 5,
        "resource_id": 2,
        "offset": 110912,
        "buffer_label": "ScratchBuffer0_0",
        "buffer_length": 4194304,
        // 新字段（来自 RPS 关联的 fragment library 的 air metadata）：
        "ir_arg_name": "UnityPerMaterial",
        "ir_arg_type_name": "UnityPerMaterial_Type",
        "ir_arg_size": 336,
        "size_check": "ok"  // ok / under / over / cross_section_unknown
      },
      {
        "index": 6,
        "resource_id": 103,
        "offset": 0,
        "buffer_label": "Compute_0",
        "buffer_length": 144,
        "ir_arg_name": "PapePerRendererCB",
        "ir_arg_size": 136,
        "size_check": "ok"
      }
    ],
    "textures": [
      {
        "index": 1,
        "resource_id": 145,
        "ir_arg_name": "_LightIndexMap",
        "ir_arg_type_name": "texture2d<half, sample>"
      }
      // ...
    ]
  }
}
```

**实现成本**：低。R7.2 已经有 `pipeline` 子命令做 RPS↔function 关联，R7.4 已经有 `shader-of-rps` 提取 air metadata。只要在 `frame-list` 里把 per-draw 的 `rps_key` → fragment library → metadata 这条链跑一遍即可。需要一个 metadata cache（同一 RPS 多次复用时不要重复 parse）。

**注**：`shader-of-drawcall --with-bindings` 已经返回 `bindings`，但它只包含原始的 slot/resource_id，**没有 IR arg_name**。如果在 `frame-list --with-bindings` 与 `shader-of-drawcall --with-bindings` 都加上 `ir_arg_name` / `ir_arg_size` / `size_check` 字段，这次错误就不会发生。

---

### 1.2 信任了已存档 cb0 dump（旧值），与新 dump 冲突未及时校对

**症状**：`OfflineSourceRecovery/.../SkinLighting/cb0_AddLightParams_active_lights.json` 里 slot 0 ShadowWeight = `(0, 1.875, 0, 0)`、slot 1 = `(0, 1, 0, 0)`；但本次 skill 重跑出来 slot 0 = `(0, 1, 0, 0)`、slot 1 = `(0, 0, 0, 0)`。两份不一致，我先信了存档版本的，后来用 `dump-uniforms --with-hex` 才确认新版本（hex 字节 = `00003c00...`，half 解码确认是 1.0 不是 1.875）。

**为什么会错**：旧的 cb0 dump 是在 R7 还没完成的某个时点用 ad-hoc Python 脚本 + 手工 offset 算出来的，**没有 reflection metadata**，作者可能数错了 stride（half4 stride=8 vs float4 stride=16）。skill 的 `dump-uniforms` 用 IR `air.struct_type_info` 自动读 stride，是权威的。

**改进建议（P2）**：

新增 `dump-diff` 子命令：

```bash
gputrace_replay_bridge dump-diff cb0_old.json cb0_new.json
# 输出：
# Field "_AdditionalLightShadowWeight[0]": old=(0,1.875,0,0)  new=(0,1,0,0)  DIFF
# Field "_AdditionalLightShadowWeight[1]": old=(0,1,0,0)      new=(0,0,0,0)  DIFF
# Field "_AdditionalLightPosition[0]":     old=(2.147,...)    new=(2.147,...) ok
# ...
```

**实现成本**：低（纯 JSON diff + 字段名识别）。

**辅助建议**：`dump-uniforms` 输出里加一个 `metadata.skill_version: "R7.7"` 字段，agent 能直接看出"这是 R7.7 抓的、那是 R6 时代手工抓的"。

---

### 1.3 把 `_LightIndexMap` 资源 id 弄错（rid 217 vs rid 145）

**症状**：07 doc 原文写 "LightIndexMap = rid 217 = `PL_Makeup_Blush_02_D`"。我开始也按这个查 — 但 IR 里明明 `air.location_index 1 → _LightIndexMap`，frame-list 里 fragment texture slot 1 → resource_id 145。**slot 1 / slot 8 颠倒**。

**为什么 07 doc 原作者会弄错（不是我这次的错，但同源痛点）**：他/她大概是按"第 N 张被采样的纹理"数的，把 unity_SpecCube0 当 0、_LightIndexMap 想成"第 1 张 2D"，然后再按某种方式数到 PL_Makeup_Blush_02_D。这是**典型的"slot 编号靠人工数"的坑**。

**改进建议**：和 §1.1 完全同源 — `frame-list` 直接附带 `ir_arg_name`，slot 编号不再需要人工从 IR `.ll` 里 grep 出来。

---

### 1.4 SH 数学公式手算错（不归 skill 管，但暴露一个机会）

**症状**：07 doc 原文写 "N=(0,1,0) → linear_sh ≈ (0.343, 0.344, 0.453)"，只取了 `_SHMaps[k].w`（DC 项），**漏算了 `_SHMaps[k].y * Ny = -0.06`** 这个减项。

**为什么 agent 容易错**：SH 公式本身简单，但 `_SHMaps[k]` 的 4 分量到底是 `(NxCoef, NyCoef, NzCoef, DC)` 还是 `(DC, NxCoef, NyCoef, NzCoef)` 这种字节序约定，得**回到 shader IR 里 case-by-case 看**。这次 EvaluatePapeSH 是 `dot(_SHMaps[0], half4(N, 1))`，所以 `.w = DC`、`.xyz = NxNyNz coef`，但**这个约定不写在 cbuffer 字段名里**，得读 shader。

**改进建议（P3，长期）**：

如果 skill 提供一个**"shader function 子表达式 evaluator"**：用户给一个 IR 函数（或一段 HLSL 翻译），加上 cbuffer 实测值 + 一个 N，skill 在 host 上用 LLVM JIT 跑（或翻译成 Python sympy），返回结果。

- 收益：agent "把数代回去" 不会算错。
- 成本：高。需要选定能 JIT 哪些 IR opcode，且 fragment IR 太大、不可能整个跑。**可行的中间方案**：让 agent 提交一个**白名单子表达式**（比如 `EvaluatePapeSH(N=(0,1,0))`），skill 反射出对应 IR 函数指针、做局部 evaluation。

短期**不值得做**，作为 R9+ 的 wishlist 即可。

---

## 2. 不是 agent 这次错，但分析中发现的 skill 表达力短板

### 2.1 NaN / inf / denormal 静默通过

cb5 `_FresnelColor.x = NaN`。`dump-uniforms` 在 JSON 里输出字符串 `"NaN"`，技术上没毛病，但 agent 容易**直接当成数值看过去**。

**改进建议（P1）**：`dump-uniforms` 与 `shader-of-drawcall --with-uniforms` 在结果末尾加一个 `value_health_summary`：

```json
"value_health_summary": {
  "nan_count": 1,
  "inf_count": 0,
  "denormal_count": 2,
  "negative_count": 5,           // 含负值的字段数（部分场景如 spot direction 是合法的，但能反映"是否需要人工看一眼"）
  "fields_with_nan": ["_FresnelColor.x"],
  "fields_with_inf": [],
  "fields_with_denormal": ["_EyeSparkle", "_LipSparkle"]
}
```

**实现成本**：低。一次遍历 decoded 树就算出来。

### 2.2 资源 label 经常为 null / 同名歧义

- rid 145（`_LightIndexMap`）`label=null`，agent 只能从 `width=128`、`pixelFormat=RGBA8Unorm`、`usage` 含 `renderTarget` 间接推断。
- rid 83 / 84 / 85 / 86 / 100 / 134 全部叫 `PL_Head`（顶点流 buffer），区分得靠 `length`。

**改进建议（P2，价值最大）**：实现 **`resource-trace <trace> <resource_id>`** 子命令，返回该资源的"生命周期"：

```jsonc
{
  "resource_id": 145,
  "first_seen_call_index": 12,                   // 何时 created
  "writers": [                                   // 谁写了它
    { "rps_key": 412, "rps_label": "Papegame/CalcLighting.CSMain",
      "encoder_index": 1, "draw_index_global": null, "call_index": 35 }
  ],
  "readers": [                                   // 谁读了它
    { "rps_key": 496, "rps_label": "Papegame/SkinMakeupNew",
      "encoder_index": 13, "draw_index_global": 69, "stage": "fragment", "tex_slot": 1 },
    // ...
  ],
  "inferred_role": "compute_output_consumed_as_texture",  // optional
  "label_chain": [null]
}
```

**收益**：

- "rid 145 没 label，是干嘛的？" → `resource-trace` 一看就知道是 `Papegame/CalcLighting.CSMain` 写的、被 SkinMakeupNew 当 `_LightIndexMap` 读的 → 这就是 cluster light index map。
- 大幅减少"猜"的成分，特别是对 TempBuffer 系列。

**实现成本**：中。需要扫一遍整个 trace 的 `setBuffer:`/`setFragmentTexture:`/render attachment 配置/blit 调用，建反向索引。可以缓存。

### 2.3 IR-name 反查能力不对称

现状：知道 slot → 找 IR arg_name 要 grep `library_NNN.ll`。
反向（知道 IR arg_name → 找 slot）也要 grep。

**改进建议（P1）**：`dump-uniforms` 加 `--names` 模式，按 IR arg_name 查询：

```bash
gputrace_replay_bridge dump-uniforms <trace> 69 \
    --stage fragment --by-name UnityPerMaterial --field _NonMetalSpecular
# 输出：
# {
#   "draw_index": 69, "stage": "fragment",
#   "binding_name": "UnityPerMaterial",
#   "field": "_NonMetalSpecular",
#   "offset": 54, "data_type": "half",
#   "value": 0.983398,
#   "buffer_resource_id": 2, "buffer_offset": 110912, "buffer_length": 4194304
# }
```

**收益**：agent 不再需要"知道 cb 编号 + 字段 offset"才能查值；可以直接说"给我 draw 69 的 `_NonMetalSpecular`"。这对 long tail 的字段查询特别有用（cb 数量多的 trace）。

**实现成本**：低。Python wrapper 层就能加（query name → 找到 binding name match → 找到 bind_slot → call 现有 dump-uniforms）。

### 2.4 `frame-list` 输出量级问题

draw 69 一个 draw 的 binding 已经包含 10 vbuf + 16 ftex + 7 fcbuf + 1 vtex = ~34 个对象。整 trace 244 个 draw 全 dump 出来 frame.json ~390KB（README 里说的）。**问题不在大小，而在 agent 端用 jq 切片取数据时容易写错路径**。

这次我多次写 `jq '.command_buffers[].encoders[].draws[] | select(.draw_index_global==69)'` —— path 比较深。

**改进建议（P2）**：wrapper 加一个 `draw-info` 子命令，把 `frame-list` 的某个 draw 提取出来，再嫁接 IR arg_name 注入（=§1.1 的方案放在 wrapper 里）：

```bash
python3 wrapper.py draw-info <trace> 69
# 直接输出一个扁平、agent-友好的 JSON：
# {
#   "draw_index_global": 69, "rps_key": 496, "rps_label": "...",
#   "vertex_bindings": {                            // 已和 IR arg_name join
#     "buffers": [
#       { "slot": 0, "ir_arg_name": "UnityPerCamera", "resource_id": 2, "offset": 109632, "size_ok": true },
#       ...
#     ],
#     "textures": [
#       { "slot": 0, "ir_arg_name": null, "resource_id": 171, "label": "fx_normal_wenli04", "note": "sticky_unused_in_ir" }
#     ]
#   },
#   "fragment_bindings": { ... },
#   "uniforms": { ... },                            // 可选 --with-uniforms
#   "value_health_summary": { ... }
# }
```

这其实是 `shader-of-drawcall --with-bindings --with-uniforms` 的"+ IR arg_name 注入"加强版，把这次分析路径里所有手动 jq 都消除。

**实现成本**：低（wrapper 层）。

---

## 3. R8 候选清单（优先级排序）

### R8.1（P0，强烈推荐先做）— per-draw merged binding view

**范围**：

- `frame-list <trace> [--with-bindings]` 输出里给每个 buffer / texture 槽位附上 `ir_arg_name` / `ir_arg_type_name` / `ir_arg_size` / `size_check`（来自 RPS 关联 library 的 `air.struct_type_info` / `air.texture` / `air.buffer` 元数据）。
- `shader-of-drawcall --with-bindings` 同样补上。
- 新增 wrapper-level `draw-info` 子命令（§2.4），给 agent 一个 single-call 的扁平视图。

**消除的痛点**：1.1 / 1.3 / 2.4 全部。

**风险**：metadata 解析有几个 corner case（vertex_input vs buffer 共表、push constant 等），需要单测覆盖。

### R8.2（P1）— size_check + value_health_summary

**范围**：

- `size_check`: `ok / under / over / unknown_offset_bound`（关键：判定一个绑定到 ScratchBuffer 中段的 cbuffer 是否真的"够长"，这要查相邻绑定看 section 大小）。
- `value_health_summary`：NaN / inf / denormal / suspicious-sign 计数 + 字段定位。

**消除的痛点**：2.1，以及 **在我没意识到的更多 trace 上，提前发现真 OOB 绑定**。

### R8.3（P1）— `dump-uniforms --by-name`

§2.3。低成本高收益。

### R8.4（P2）— `dump-diff` + skill_version metadata

§1.2。

### R8.5（P2）— `resource-trace`

§2.2。这次没踩坑只是因为我们关心的资源大多有 label，但**分析任意非主流 RT/buffer 时痛点会立刻凸显**。

### R8.6（P3，长期）— host-side function evaluator

§1.4。可以等到有第二个用例（除了 SH 之外）再排。

---

## 4. 行动建议

1. **R8.1 + R8.2 + R8.3 合并成一个 sprint** 做掉（都是 metadata join + 浅遍历，能复用一份 RPS→library→metadata 的 cache）。完成后这次分析里 ~80% 的 agent 错误根源都被消除。
2. **R8.4 单独做**，`dump-diff` 对长期 cross-trace / cross-version 校验非常有用。
3. **R8.5 单独做**，是 R7 backlog 里"frame-inspection-gap"的子项延伸。
4. **R8.6 暂搁**，等到 lighting/material 自动校验有第二个明确需求再启动。

---

## 5. 自我反思（agent 这一面）

不是所有错都该让 skill 背锅。这次我也确实有几次"读 JSON 不仔细"——特别是 §1.1 里把 slot 5/6 颠倒，是我自己看 frame-list 时的认知错误。

但这种错的**结构性根源**是 skill 让 agent 在多个数据源之间手工 join，这种 join 错误率随数据源数量平方上升。**最佳防御就是 skill 自己 join 好再交给 agent**，agent 只看一份事实表，错的可能性大幅下降。

R8.1 的核心价值就在这里。
