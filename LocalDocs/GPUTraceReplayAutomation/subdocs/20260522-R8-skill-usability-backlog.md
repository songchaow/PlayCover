# R8：Skill 可用性收尾 — agent 多数据源 join 错误的结构性消除

**来源**：2026-05-22 在 LYSK trace 上对 RPS 496 / draw 69 做完整 binding + uniform 校验时，复盘发现 agent 多次"在 frame-list JSON + IR `.ll` + dump-uniforms 三份数据源之间手工 join 出错"，~80% 错误根因都是 skill 输出未自动 join，让 agent 承担了易错的脑内 join。

**定位**：R7 主线（draw → IR + bindings + uniforms 三件套）已闭环，R8 不再补新数据来源，而是把已有数据源**自动 join 后再交给 agent**，结构性降低错误率。R8.1 + R8.2 + R8.3 共享一份 `RPS → library → AIR metadata` cache，建议合并成一个 sprint。

**优先级与排期**：以主 dashboard `README.md` 的"下一步"与"任务 TODO" 段为准，本文档只承载实现细节与设计决策。

> 任务状态（进度 / 卡点 / 下一步 / TODO）以主 dashboard `README.md` 为准；本文档只承载实现细节与设计决策。

---

## 1. 实测错误案例（2026-05-22 RPS 496 / draw 69 复盘）

### 1.1 cb5 / cb6 slot 颠倒（最严重，最久才发现）

**症状**：分析中曾写出"cb5 UnityPerMaterial 绑到 Compute_0 144B，IR 期望 336B → OOB"。**事实相反**：
- frag buf slot 5 → IR `arg_name=UnityPerMaterial`（336B）→ ScratchBuffer @ 110912（足够）
- frag buf slot 6 → IR `arg_name=PapePerRendererCB`（136B）→ Compute_0 144B（恰好够）

**根因**：`frame-list` 输出的 `bindings.fragment.buffers[]` 按 `index` 排序的扁平数组，**没有任何字段告诉 agent "slot 5 的 IR 名字是 UnityPerMaterial"**。agent 必须 `cd $WORK/shaders && grep "air.buffer.*location_index" library_410.ll` 才能看到映射 — 这是两个数据源（frame-list JSON + IR `.ll`）的人工对接，错误率随数据源数量平方上升。

**纠正路径**：用 `dump-uniforms 69 5` 单 slot 模式才看到 `binding_name: UnityPerMaterial / buffer_size: 336 / buffer_label: ScratchBuffer0_0`，**这个信息只在 dump-uniforms 暴露，frame-list 的 per-draw bindings 不暴露**。

### 1.2 已存档 dump 与新 dump 冲突未及时校对

**症状**：`OfflineSourceRecovery/.../SkinLighting/cb0_AddLightParams_active_lights.json` 里 ShadowWeight slot 0 = `(0, 1.875, 0, 0)`、slot 1 = `(0, 1, 0, 0)`；本次 skill 重跑出 slot 0 = `(0, 1, 0, 0)`、slot 1 = `(0, 0, 0, 0)`。先信旧版本，`dump-uniforms --with-hex` 验证 hex `00003c00...` half 解码 = 1.0 才纠正。

**根因**：旧 dump 是 R7 之前 ad-hoc Python 脚本算的，**没有 reflection metadata**，作者数错 stride（half4=8 vs float4=16）。skill 的 `dump-uniforms` 用 IR `air.struct_type_info` 自动读 stride，是权威的，但**输出无版本/来源标记**，agent 无法一眼判定哪份是权威的。

### 1.3 `_LightIndexMap` 资源 id 弄错（rid 217 vs rid 145）

**症状**：旧 doc 写 "LightIndexMap = rid 217"，实际 IR `air.location_index 1 → _LightIndexMap`，frame-list 里 fragment texture slot 1 → resource_id 145。**slot 1 / slot 8 颠倒**。

**根因**：与 1.1 完全同源 — slot 编号靠人工数，"第 N 张被采样的纹理"心智不可靠。

### 1.4 NaN 静默通过

cb5 `_FresnelColor.x = NaN`。`dump-uniforms` 输出字符串 `"NaN"`，技术上没毛病，但 agent 容易直接当数值看过去。skill 对**数值健康度**没有结构化提示。

### 1.5 资源 label 经常为 null / 同名歧义

- rid 145（`_LightIndexMap`）`label=null`，agent 只能从 `width=128` / `pixelFormat=RGBA8Unorm` / `usage` 含 `renderTarget` 间接推断
- rid 83 / 84 / 85 / 86 / 100 / 134 全部叫 `PL_Head`（顶点流 buffer），区分得靠 `length`

无 `resource-trace` 反查 → agent 只能猜。

### 1.6 SH 数学公式手算错（不归 skill 管，但暴露机会）

旧 doc "N=(0,1,0) → linear_sh ≈ (0.343, 0.344, 0.453)" 漏算 `_SHMaps[k].y * Ny = -0.06` 减项。`_SHMaps[k]` 4 分量字节序约定（`(NxCoef, NyCoef, NzCoef, DC)` vs `(DC, NxCoef, NyCoef, NzCoef)`）只能回 IR 看 — `dot(_SHMaps[0], half4(N, 1))` 表明 `.w = DC`、`.xyz = NxNyNz coef`，但**这个约定不写在 cbuffer 字段名里**。短期不值得做 host-side IR 子表达式 evaluator（成本高，覆盖窄）。

---

## 2. R8 子项清单（按优先级）

| 子项 | 优先级 | 工时 | 消除的痛点 | 实现成本 |
|------|--------|------|-----------|---------|
| **R8.1** per-draw merged binding view（slot ↔ IR `arg_name` ↔ resource label / size ↔ IR 期望大小） | **P0** | 0.5–1 天 | §1.1 / §1.3 / §2.4 | 低（纯组合现有数据） |
| **R8.2** size_check + value_health_summary（NaN/inf/denormal/binding 大小不匹配计数与字段定位） | **P1** | 0.5 天 | §1.4 + 隐藏的 OOB | 低 |
| **R8.3** `dump-uniforms --by-name`（按 IR arg_name 反查字段，绕过 bind_slot） | **P1** | 0.3 天 | §1.1 反向 | 低（wrapper 层即可） |
| **R8.4** `dump-diff` + `skill_version` metadata（双 dump 自动比对 + 来源标记） | P2 | 0.3 天 | §1.2 | 低 |
| **R8.5** `resource-trace <rid>`（资源 provenance：写者 / 读者 / 推断 role） | P2 | 1 天 | §1.5 | 中（需扫全 trace 建反向索引） |
| **R8.6** host-side shader function evaluator（白名单 IR 子表达式 JIT） | P3（搁置） | 高 | §1.6 | 高，覆盖窄 |

---

## 3. R8.1 实现要点（per-draw merged binding view）

### 3.1 目标 schema（新增字段加粗）

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
        // 新增（来自 RPS 关联 fragment library 的 air metadata）：
        "ir_arg_name": "UnityPerMaterial",
        "ir_arg_type_name": "UnityPerMaterial_Type",
        "ir_arg_size": 336,
        "size_check": "ok"          // ok / under / over / cross_section_unknown
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
      { "index": 1, "resource_id": 145,
        "ir_arg_name": "_LightIndexMap",
        "ir_arg_type_name": "texture2d<half, sample>" }
    ]
  }
}
```

### 3.2 数据来源链路

R7.2（pipeline）已能获取 RPS 关联 library；R7.4（shader-of-rps）已能读取 AIR metadata。R8.1 把这条链路在 `frame-list --with-bindings` 的 emit 阶段跑一遍：每个 draw 的 `rps_key` → fragment library / vertex library → `air.struct_type_info` / `air.texture` / `air.buffer` 元数据 → 注入到 `bindings.<stage>.{buffers|textures}[i]`。

**关键**：metadata 解析有 cache（同一 RPS 多次复用不重 parse）；解析失败时字段缺省 + 顶层 `metadata_join_failed_count` 上报，不阻塞 binding 输出。

### 3.3 wrapper 层 `draw-info` 子命令（§2.4 痛点）

`frame-list` 整 trace 244 draw 的 JSON ~390KB，agent 用 `jq '.command_buffers[].encoders[].draws[] | select(.draw_index_global==69)'` 路径过深易错。R8.1 在 wrapper 层加 `draw-info <trace> <draw_index>`：

- 内部就是 `frame-list --with-bindings` 后切片到目标 draw
- 输出**扁平、agent 友好**的单 draw JSON（含 `vertex_bindings` / `fragment_bindings` / 可选 `uniforms` / 可选 `value_health_summary`）
- 与 `shader-of-drawcall --with-bindings --with-uniforms` 的差别：`draw-info` 默认输出 IR arg_name 已注入的 binding 视图（不强制走 IR + uniforms 决策路径）；`shader-of-drawcall` 是"我要全套"的入口

### 3.4 `shader-of-drawcall --with-bindings` 同步覆盖

R7.6-D 已让 `shader-of-drawcall` 返回 `bindings`，R8.1 同样为这条路径补上 `ir_arg_name` 字段。所有"含 bindings"的输出 schema 严格一致。

### 3.5 corner case

- **vertex_input vs buffer 共表**：`stage_in` 顶点输入与普通 buffer 在 IR `air.buffer` 列表里都有，需用 `air.location_index` 区分
- **push constant**：M-series 偶发 inline buffer，`resource_id=null` 时 `ir_arg_name` 仍可填
- **argument buffer 二级 indirect**：当前不展开（与 R7.6-B 已知局限对齐）

---

## 4. R8.2 实现要点（size_check + value_health_summary）

### 4.1 size_check 取值

| 取值 | 判定 |
|------|------|
| `ok` | `bound_buffer_length - offset >= ir_arg_size` |
| `under` | `bound_buffer_length - offset < ir_arg_size`（真 OOB / 跨 section） |
| `over` | `bound_buffer_length - offset > 4 × ir_arg_size`（疑似借用了大 section） |
| `cross_section_unknown` | 一个 ScratchBuffer 内多个 cbuffer 紧邻，无法仅凭 length 判定（需相邻绑定 offset 推断） |

LYSK 实战中"Compute_0 144B 借给 PapePerRendererCB 136B"是典型 `over` → 引导 agent 单独审视而非默认报错。

### 4.2 value_health_summary

```json
"value_health_summary": {
  "nan_count": 1,
  "inf_count": 0,
  "denormal_count": 2,
  "fields_with_nan": ["_FresnelColor.x"],
  "fields_with_inf": [],
  "fields_with_denormal": ["_EyeSparkle", "_LipSparkle"]
}
```

一次遍历 decoded 树即可计算；`dump-uniforms` 与 `shader-of-drawcall --with-uniforms` 在结果末尾追加。负值不计入（部分场景如 spot direction 是合法的，避免误报）。

---

## 5. R8.3 实现要点（dump-uniforms --by-name）

```bash
gputrace_replay_bridge dump-uniforms <trace> 69 \
    --stage fragment --by-name UnityPerMaterial --field _NonMetalSpecular
# 输出（仅相关字段）：
# { "draw_index": 69, "stage": "fragment",
#   "binding_name": "UnityPerMaterial",
#   "field": "_NonMetalSpecular",
#   "offset": 54, "data_type": "half", "value": 0.983398,
#   "buffer_resource_id": 2, "buffer_offset": 110912, "buffer_length": 4194304 }
```

实现层级：wrapper-only（query name → 经 R7.2 reflection 找到 binding name match → 找到 bind_slot → 调现有 `dump-uniforms`）。bridge 零变更。

---

## 6. R8.4 / R8.5 / R8.6 概览

### R8.4：`dump-diff` + skill_version metadata

```bash
gputrace_replay_wrapper.py dump-diff cb0_old.json cb0_new.json
# Field "_AdditionalLightShadowWeight[0]": old=(0,1.875,0,0)  new=(0,1,0,0)  DIFF
# Field "_AdditionalLightShadowWeight[1]": old=(0,1,0,0)      new=(0,0,0,0)  DIFF
# Field "_AdditionalLightPosition[0]":     old=(2.147,...)    new=(2.147,...) ok
```

辅助：`dump-uniforms` 输出加 `metadata.skill_version: "R7.7+R8.1"` 字段，让 agent 一眼分辨权威性。纯 JSON 字段名识别，wrapper 层。

### R8.5：`resource-trace <rid>` 资源 provenance

```jsonc
{
  "resource_id": 145,
  "first_seen_call_index": 12,
  "writers": [
    { "rps_key": 412, "rps_label": "Papegame/CalcLighting.CSMain",
      "encoder_index": 1, "call_index": 35 }
  ],
  "readers": [
    { "rps_key": 496, "rps_label": "Papegame/SkinMakeupNew",
      "encoder_index": 13, "draw_index_global": 69, "stage": "fragment", "tex_slot": 1 }
  ],
  "inferred_role": "compute_output_consumed_as_texture"
}
```

实现：扫 trace 的 `setBuffer:` / `setFragmentTexture:` / render attachment 配置 / blit 调用建反向索引。可缓存。中等成本，但解决"非主流 RT/buffer 没 label"的猜谜场景。

### R8.6：host-side shader function evaluator（搁置）

让 agent "把 cbuffer 实测值代入公式 sanity check" 不再手算错。需先选 scope（Pape SH / GGX 等常用 lighting 子表达式），用 LLVM JIT 跑反射出的 IR 函数。成本高、覆盖窄，等到第二个明确用例（除 SH 外）再启动。

---

## 7. Sprint 建议

1. **Sprint α（强烈推荐先做）**：R8.1 + R8.2 + R8.3 合并 — 都是 metadata join + 浅遍历，复用一份 `RPS → library → AIR metadata` cache。完成后 §1 中 ~80% 的 agent 错误根源被消除。预计 1.5 天合计。
2. **Sprint β**：R8.4 单做。`dump-diff` 对长期 cross-trace / cross-version 校验非常有用。
3. **Sprint γ**：R8.5 单做。是 R7 backlog "frame-inspection-gap" 的子项延伸。
4. **R8.6 暂搁**，等到 lighting/material 自动校验有第二个明确需求再启动。

---

## 8. 与 R7 的边界

- R7 = 把"draw → IR + bindings + uniforms"的端到端**数据通路**打通（R7.1~R7.7 + R7.6-A/B/C/D，已闭环）
- R8 = 把已通路的数据**自动 join 后再交给 agent**，让 agent 不再承担易错的脑内 join

R7 和 R8 不重叠：R7 是"能不能拿到"，R8 是"拿到的怎么不让人用错"。两者在数据结构（`FrameDrawBindings` / `DumpUniformsResult` / `ShaderOfDrawcallResult`）上严格向后兼容 — R8 只新增字段、不修改既有字段。

---

## 9. 自我反思（agent 这一面）

不是所有错都该让 skill 背锅。§1.1 把 slot 5/6 颠倒确实有 agent 自身"读 JSON 不仔细"的成分。但**结构性根源**是 skill 让 agent 在多数据源之间手工 join，错误率随数据源数量平方上升。**最佳防御就是 skill 自己 join 好再交给 agent**，agent 只看一份事实表，错的可能性大幅下降 — R8.1 的核心价值就在这里。
