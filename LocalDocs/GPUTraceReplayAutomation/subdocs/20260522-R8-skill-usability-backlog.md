# R8：Skill 可用性收尾 — agent 多数据源 join 错误的结构性消除

**来源**：2026-05-22 在 LYSK trace 上对 RPS 496 / draw 69 做完整 binding + uniform 校验时，复盘发现 agent 多次"在 frame-list JSON + IR `.ll` + dump-uniforms 三份数据源之间手工 join 出错"，~80% 错误根因都是 skill 输出未自动 join，让 agent 承担了易错的脑内 join。

**定位**：R7 主线（draw → IR + bindings + uniforms 三件套）已闭环，R8 不再补新数据来源，而是把已有数据源**自动 join 后再交给 agent**，结构性降低错误率。R8.1 + R8.2 + R8.3 共享一份 `RPS → library → AIR metadata` cache，建议合并成一个 sprint。

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

## 2. R8 子项清单

| 子项 | 状态 | 消除的痛点 |
|------|------|-----------|
| **R8.1** per-draw merged binding view | ✅ 完成 | §1.1 / §1.3 |
| **R8.2** value_health_summary | ✅ 完成 | §1.4 |
| **R8.3** `dump-uniforms --by-name` | ✅ 完成 | §1.1 反向 |
| **R8.4** `dump-diff` + `skill_version` metadata | BACKLOG | §1.2 |
| **R8.5** `resource-trace <rid>` 资源 provenance | BACKLOG | §1.5 |
| **R8.6** host-side shader function evaluator | WISHLIST | §1.6 |

---

## 3. Sprint α 实现详情（已完成 2026-05-22）

### 3.1 R8.1：`draw-info` 子命令 + AIR Metadata 自动注入

**架构**（wrapper-only，bridge 零变更）：
```
draw-info <trace> <draw_index> [--with-uniforms] [--output-dir] [--pretty]
    ├── frame-list --with-bindings → 目标 draw 的 bindings + rps_key
    ├── pipeline → rps_key 的 vertex/fragment library_key
    ├── disasm --with-ir (per library, cached) → .ll IR 文件
    ├── parse_air_metadata(.ll) → slot → {arg_name, type_name, size}
    └── enrich_stage_bindings() → 注入到 JSON + 计算 size_check
```

**AIR Metadata Parser**：正则提取 `air.buffer` / `air.texture` / `air.sampler` 的 `{location_index, arg_name, arg_type_name, arg_type_size}`。缓存以 `library_key` 为键。

**size_check 规则**：`ok`（available ≥ ir_arg_size 且 ≤ 4×）/ `under`（真 OOB）/ `over`（疑似借用大 section）/ None（信息不足）。

**验证**（LYSK draw 69 / RPS 496 = SkinMakeupNew）：fragment 7/7 buf + 16/16 tex 全注入，§1.1(slot颠倒)和§1.3(rid错位)结构性消除。vertex 3/10（7 个 stage_in 顶点输入属已知不注入范畴）。

**已知局限**：vertex stage_in 不注入 metadata / size_check 需 buffer_length / argument buffer 二级 indirect 不展开。

### 3.2 R8.2：`value_health_summary`

对 decoded 字段树遍历统计 NaN/inf/denormal。输出 schema：
```json
"value_health_summary": { "nan_count": 1, "inf_count": 0, "denormal_count": 0,
  "fields_with_nan": ["_FresnelColor"], "fields_with_inf": [], "fields_with_denormal": [] }
```

检测规则：NaN（`"NaN"` 或 `math.isnan`）/ inf / denormal（`0 < |v| < 6.1e-5` half 阈值）。注入到 `dump-uniforms` / `shader-of-drawcall --with-uniforms` / `draw-info --with-uniforms`。验证：LYSK draw 69 slot 5 `_FresnelColor.x = NaN` 正确检出。

### 3.3 R8.3：`dump-uniforms --by-name`

按 IR `arg_name` 直接查值，绕过 `bind_slot` 心算：
```bash
python3 gputrace_replay_wrapper.py dump-uniforms <trace> 69 0 --by-name UnityPerMaterial [--field _NonMetalSpecular]
```

解析链路：`--by-name` → frame-list → pipeline → disasm → parse_air_metadata → name→slot → 精确匹配(失败则子串匹配) → 解析出 bind_slot → 调标准 dump-uniforms。`--field` 从 decoded 树做子串过滤。验证：`--by-name UnityPerMaterial` 正确解析到 slot 5。

### 3.4 设计决策汇总

| 决策 | 理由 |
|------|------|
| 全 wrapper-only，bridge 零变更 | R8 Sprint α 纯组合现有数据源，无需新 swizzle/API |
| AIR metadata 从 .ll 正则解析 | llvm-dis 标准输出格式稳定；解析 bitcode 需链接 llvm-c |
| 缓存以 library_key 为键 | LYSK 96 lib → 65 RPS → 244 draws，复用率高 |
| denormal 使用 half 阈值 (6.1e-5) | LYSK cbuffer 主要 half 精度 |
| --by-name 失败输出 available_names | 避免 agent "name_not_found → 重跑 pipeline → grep IR" 循环 |
| value_health_summary 仅异常时输出 | 正常 draw 不增加输出噪声 |

---

## 4. R8.4 / R8.5 / R8.6 概览（BACKLOG / WISHLIST）

- **R8.4**（`dump-diff`）：双 dump JSON 自动比对 + `metadata.skill_version` 来源标记。解决§1.2"旧 dump 与新 dump 冲突"。0.3 天。
- **R8.5**（`resource-trace <rid>`）：扫全 trace 建资源 writers/readers 反向索引 + `inferred_role`。解决§1.5"非主流 RT/buffer 没 label"。1 天。
- **R8.6**（shader evaluator）：host-side IR 子表达式 JIT。成本高覆盖窄，等第二个明确用例再启动。

---

## 5. 与 R7 的边界

- R7 = "能不能拿到"（数据通路端到端打通）
- R8 = "拿到的怎么不让人用错"（自动 join 后再交给 agent）

两者不重叠。R8 只新增字段、不修改既有字段，数据结构严格向后兼容。

**根本洞察**：agent 在多数据源间手工 join 的错误率随数据源数量平方上升。skill 自己 join 好再交给 agent 看一份事实表，错误率大幅下降。

---

## 6. R10/R11：数据质量盲区与防呆加固（2026-05-26）

R10（ASTC 压缩纹理导出修复）暴露了**不同于 §1 的全新错误模式**：导出数据本身就是错的（Metal 返回压缩块而非像素），但 agent 没有结构化手段发现。

问题域分类：
- §1：数据源正确但 agent 拼接出错 → 已被 R8.1~R8.3 结构性消除
- R10/R11：数据源返回非预期格式 → R11 防呆加固

### 6.1 R11 实现（2026-05-26 完成）

| 子项 | 实现 | 改动文件 |
|------|------|---------|
| **R11.1** 导出自动验证 | 采样前 64KB 检测全零/大小一致性/非零占比，输出 `export_verification` JSON | bridge.m |
| **R11.2** `.meta.json` sidecar | 自动写 width/height/bytes_per_pixel/pixel_format/was_decompressed/channel_order | bridge.m |
| **R11.3** 压缩格式标记 | `--list-resources` 输出 `compressed: true` + `block_size`；新增 `compressed_block_size()` + 增强 `pixel_format_name()` | bridge.m + wrapper.py |
| **R11.4** SKILL.md 更新 | Known Blind Spots + Pattern 5 + description 扩展 | SKILL.md + cli-reference.md |

验证：LYSK 57 个压缩纹理正确标记；导出 ASTC_6x6_LDR → RGBA8Unorm 正确解压；148/148 集成测试通过。
