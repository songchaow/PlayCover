# R7：Frame-Inspection 能力缺口分析与改进矩阵

**来源**：2026-05-21 别的 agent 在使用 `gpu-trace-analysis` skill 调查 `com.papegames.lysk capture_20260518_110050.gputrace`（247 资源 / 50 RPS / 96 lib / ~81 400 GPU API 调用）时反馈的能力缺口；以及"从 draw call 反查 shader IR"的 7 段链路验证。
**结论**：当前 bridge/skill 在"渲染 bug 调查"任务上称职，但在"未知 trace 整体管线分析"与"draw call → shader 反查"两类任务上**严重欠拟合**。R7 的目标是补齐这些能力。
**进度**：R7.1 ✅（2026-05-21，越界保护 + 资源元数据补齐）；下一步 R7.2（`pipeline` 输出加 RPS↔shader 关联）。

> 本文档是 R7 的总入口。R6.3（CI/样本库自动化流水线）已确认不做，R7 是 R6 之后唯一的主线。

---

## 1. 当前 skill 的设计哲学（根因）

读 `SKILL.md` + `gputrace_replay_bridge.m` 可见取舍：

> **当前 skill 是 "shader bisecter + config knob tester"，不是 "frame inspector"。**

证据：
- `SKILL.md` 的 4 个调查场景（black screen / wrong color / crash / slow）都假定**用户已知 bug 现象**，工具帮助"二分定位 + 替换验证"。
- 5 子命令（`replay`/`pipeline`/`shader`/`config`/`help`）全围绕"重放并对比"。
- 没有任何子命令面向"**枚举本帧实际发生了什么**"。
- Xcode Frame Debugger 的 GUI 能力（draw list / encoder timeline / bind table / texture preview / uniform inspector）**一律未复刻**。

R4.2 + R6.1 选择 `makeDataSource → makeController → playAll/playTo` 路径，对 ObjectMap 静态 dump、对 controller 时间切片重放，但**未遍历 controller 持有的 CommandBuffer/Encoder 时序对象**。

---

## 2. 实测暴露的 14 处卡点

LYSK trace 全景调查任务里按出现顺序遇到的限制（每条都是"我尝试做什么 / 为什么不行 / 怎么绕"）：

| # | 想做的事 | 限制 | 绕路代价 |
|---|---|---|---|
| 1 | 拿本帧 encoder/pass/draw call 时间序 | bridge 仅暴露 ObjectMap 静态视图，无 CommandBuffer/Encoder 列表 | `--playto N` 二分扫 RT SHA-1 反推（±2k–5k 精度） |
| 2 | 知道 `--playto N` 的 N 上限 | ~~越界直接 `SIGSEGV`，无 `bounds` / `total_call_count`~~ → ✅ R7.1：`--bounds` + `total_call_count` + OOR 结构化错误 | 已解决 |
| 3 | 把 `playto N` 换算成 draw index | N 是 GPU API 调用编号，含大量 set\* | 完全无法精确换算 |
| 4 | 直接读 `.gputrace` bundle 内 `capture` / `index` / `device-resources-*` | 私有二进制（`MTSP`/`xdic`），无文档 schema | 放弃 |
| 5 | 解 `store0`（zlib 流）拿 shader 元数据 | 50 MB 内 90% 是本帧未派发的反射元数据 | 噪声大，仅能确认"shader 名存在过" |
| 6 | 导 `DirectionalShadowDepth` / stencil | bridge 拒绝 depth/stencil getBytes | 完全无法可视化 ShadowMap / stencil bit |
| 7 | 拿每个 encoder 的 attachments / bindings | 无 API | 用 RT format/尺寸/命名硬猜 |
| 8 | 拿 RT 的 `storageMode` / `usage` / `framebufferOnly` / `memoryless` | ~~资源元数据仅 `width/height/depth/format/textureType/mip/label`~~ → ✅ R7.1：texture/buffer 元数据全补齐 | 已解决 |
| 9 | 区分 buffer 用途（vertex/index/uniform/argbuf） | 仅 `length`+`label` | 靠命名经验 |
| 10 | 看某个 draw 的 cbuffer 实际值 | 无 API | 无法回答 |
| 11 | 区分 stencil bit | depth/stencil 不能导出 | 无法回答 |
| 12 | 确认本帧无 compute dispatch | `compute_pipeline_states_count=0`，但 trace 元数据有大量 compute 函数名 | 仅能间接判断 |
| 13 | 从 RPS 反查 fragment/vertex shader | bridge 无 RPS↔function/library 关联；`shader` 子命令仅按 lib_key 替换 | 必须自写 method swizzling 探针（已归档为 `rps_swizzle_probe.m`） |
| 14 | 从 draw call 反查 shader IR | 段 1（draw→RPS_key）完全未通；段 2~3 需用户写探针；段 4~7 跨 bridge / extract_shader_raw / llvm-dis 三工具拼装 | 当前完全没法做 |

---

## 3. 从 draw call 到 LLVM IR 的 7 段映射

用户的心智模型 = "第 N 个 draw call 用的是哪段 shader 代码？"
不应让用户感知 library / function / RPS / metallib / cacheKey / SDI / module.bc 这些中间层。

```
draw call N  ──[段1]── RPS_key ──[段2]── fragment MTLFunction* ──[段3]── function_key
                                                                            │
                                                          [段4: lib_key = fn_key - 1]
                                                                            ▼
                                       library_key ──[段5: pipeline 子命令]── library_<k>.metallib
                                                                            │
                                              [段6: cacheKey = PlayTools 同款算法]
                                                                            ▼
                                ShaderDebugInfo/<bundle>/<cacheKey>/modules/<hash>/module.bc
                                                                            │
                                                              [段7: llvm-dis]
                                                                            ▼
                                                               LLVM IR (.ll)
```

每段的现状：

| 段 | 现状 | 关键点 |
|---|------|--------|
| 1: draw→RPS | ❌ 未通 | 需 swizzle `MTLRenderCommandEncoder.setRenderPipelineState:` + `drawIndexedPrimitives:*` 计数 |
| 2: RPS→MTLFunction | ✅ 已通（用户需自写探针） | swizzle `MTLDevice.newRenderPipelineStateWithDescriptor:[options:reflection:]error:`，从 descriptor 取 fragment/vertexFunction。**PSO 编译完不再持有 function 引用**，只能创建那一刻拦截 |
| 3: MTLFunction→fn_key | ✅ 已通 | `objectMap.functionMap` 反向构建 `fnPtr→key`；用 `[NSValue valueWithNonretainedObject:fn]` 作 key 比直接 `id` 安全 |
| 4: fn_key→lib_key | ✅ 已通 | `library_key = function_key - 1`（trace 内部约定，非 Apple 通用）。兜底：探测 `libraryForKey:` 偶数 key 反向建表 |
| 5: lib_key→metallib | ✅ 已通 | bridge `pipeline` 子命令 |
| 6: metallib→cacheKey | ✅ 已通 | PlayTools 算法（见下方 §3.1） |
| 7: SDI module.bc→IR | ✅ 已通 | `llvm-dis`（Homebrew LLVM；Apple 自带链没有）|

### 3.1 cacheKey 算法（PlayTools 同款）

```python
def compute_cache_key(data: bytes) -> str:
    size = len(data)
    h = size
    for i in range(min(32, size)):
        h = (h * 31 + data[i]) & 0xFFFFFFFFFFFFFFFF
    if size > 32:
        for i in range(size - min(16, size - 32), size):
            h = (h * 31 + data[i]) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016X}_{size}"
```

cacheKey 直接对应 `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cacheKey>/`。

### 3.2 已验证的探针

`LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` (~200 行 ObjC，无外部依赖)
打通段 2~7。编译运行：

```bash
clang -O0 -fobjc-arc -framework Foundation -framework Metal -ldl -lobjc \
      -o rps_swizzle rps_swizzle_probe.m
codesign -s - rps_swizzle
./rps_swizzle <path-to.gputrace>
```

工程要点：
- swizzle 必须在 replay 触发的第一次 PSO 创建之前装上 — 即 `init_replay()` 之前。
- 类要找具体实现类（如 `AGXG16SDevice`），用 `class_getInstanceMethod` 沿继承链向上找 IMP。
- 两个变体都要装：带/不带 `options:reflection:`。

LYSK trace 65 个 RPS 的反查结果作为回归基线见 §6。

---

## 4. 关键认知：library 是错误的抽象层级

> "library_key" 对用户毫无意义。

具体表现：
1. **同一 RPS label 对应多个 library**：`Papegame/SkinMakeupNew` 出现 4 次（RPS 476/484/491/496），分别用 4 个不同 library。
2. **多个 RPS 共享同一 library**：RPS 474（Teeth）/ 475（SkinSSS）/ 476（SkinMakeupNew）/ 479（EyeSpec）共享 fragment lib_252 — Z-Prepass 阶段都退化成同一个 depth-only fragment。**所以 "library_key = shader 概念" 是错的**，library_key 只是 trace 内部对 metallib 实例的编号。
3. **"主 shader" 与 "prepass shader" 在 library 层无法区分**：只能通过 RPS 的 attachment 数 + blend state + `SV_TARGET*` 数量区分。

**结论**：用户视角的最小单位应是 **`RPS_key + label + RT-attachment 摘要`**，bridge 必须在 `pipeline` 输出里补上 vertex/fragment function key 与 attachment 摘要。

---

## 5. R7 改进矩阵（按依赖排序的 chunk 列表）

R7 拆成 7 个独立可 PR 的 chunk。每个 chunk 列出工时、风险、解锁能力与新 JSON schema。**优先级按 C1 → C5 顺序**。

### R7.1（原 C1）：bridge 越界保护 + 资源元数据补齐 — ✅ 已完成（2026-05-21）

**交付摘要**

- `replay` 输出新增 `total_call_count` / `last_call_index`
- 新增 `replay --bounds`：仅探边界后退出，不做资源枚举/导出
- `replay --playto N` 越界返回结构化 `{"error":"playto_out_of_range","max":...}`，exit 12 (`EXIT_PLAYTO_OOR`)，不再 SIGSEGV
- SIGSEGV/SIGBUS 兜底（`setjmp` + `sigaction`），框架行为变化时不 crash 进程
- texture 元数据补齐：`storageMode` / `cpuCacheMode` / `hazardTrackingMode` / `usage`(数组) / `framebufferOnly` / `memoryless` / `sampleCount` / `arrayLength` / `isDepthStencil`
- buffer 元数据补齐：`storageMode` / `cpuCacheMode` / `hazardTrackingMode`

**关键技术点（沉淀知识）**

- `total_call_count` 字段在 `controller + 0x5810`，类型 `uint32_t`，语义为**最后被 played 的 call index**。`playAll` 完成后等于 trace 的 total（LYSK 实测 = 3425）；`playTo(N)` 后实时变成 `N`。常量名：`CONTROLLER_LAST_CALL_INDEX_OFFSET`。
- 反汇编证据：`GTMTLReplayController_playTo` prologue `+0x038: add x23, x0, #0x5000` + `+0x110: ldr w8, [x23, #0x810]` + `+0x114: cmp w8, w19`（w19=target）。证据探针 `Scripts/call_count_probe.m` 保留作回归。
- LYSK 全景调查里看到的 ~81 400 是源 trace 的 raw GPU API 调用数（含每个 `setVertexBuffer:` 等），与 controller 时间序的 call index 粒度不同 — controller 维度的 3425 才是 `playTo` 合法上限。
- `--playto N` 当前先 `playAll` 探边界再 `rewind` + `playTo(N)`，多一次全帧开销（LYSK ~9ms，可忽略）；如未来某 trace `playAll` 代价大，可考虑做"二分而不全跑"探边界。

**越界保护策略**

| 场景 | 处理 |
|------|------|
| `--bounds` | 仅 1 次 `playAll` 探得 `total_call_count` 后退出 |
| `--playto N`（N ≤ total） | `playAll` → `rewind` → `playTo(N)`，正常输出 |
| `--playto N`（N > total） | 直接返回 OOR JSON，不调用 `playTo`，exit 12 |
| 默认 | 等价以前 `playAll`，附加 `total_call_count` / `last_call_index` |
| SIGSEGV/SIGBUS | `longjmp` 兜底，`replay_signal` 字段写入 JSON，进程不 crash（仅最后一道墙） |

**实测样例**（LYSK trace `capture_20260518_110050.gputrace`）

`replay --bounds`：
```json
{"command":"replay","bounds_only":true,"probe_rc":0,
 "probe_elapsed_ms":8.733,"total_call_count":3425}
```

`replay --playto 9999999`（OOR，exit 12）：
```json
{"command":"replay","error":"playto_out_of_range",
 "playto_index":9999999,"total_call_count":3425,"max":3425}
```

`replay --list-resources` 单条 texture：
```json
{"id":231,"type":"texture","width":583,"height":835,
 "pixelFormatName":"Depth32Float_Stencil8","textureType":"2D",
 "mipmapLevelCount":1,"sampleCount":1,"arrayLength":1,
 "storageMode":"shared","cpuCacheMode":"default",
 "hazardTrackingMode":"tracked",
 "usage":["shaderRead","renderTarget"],
 "framebufferOnly":false,"memoryless":false,
 "isDepthStencil":true,"label":"TempBuffer 123 583x835"}
```

**测试覆盖**：T7e/T7f/T7g/T7h（4 组 14 断言）已加入 `Scripts/test_gputrace_replay_bridge.sh` 和 skill 内同步副本，43/43 通过；常规集成测试 17/17 通过。

**对后续 R7 chunk 的衔接**

- R7.2 可在 `replay_context_init` 入口前安装 method swizzling，与 R7.1 改动（仅 `cmd_replay` 内）无冲突
- R7.3 (`frame-list`) 可用 `total_call_count` 校验每个 encoder 的 `[first_call_index, last_call_index]` 闭合性

**已知限制**：`+0x5810` 偏移在当前 macOS 版本稳定；系统升级后若反汇编 prologue 模式变化，需更新常量，回归脚本：`Scripts/call_count_probe.m`。

### R7.2（原 C1.5）：`pipeline` 输出加 RPS↔shader 关联

每个 RPS 输出从 `{key, class, label}` 扩展为：

```json
{
  "key": 484,
  "class": "AGXG16XFamilyRenderPipeline",
  "label": "Papegame/SkinMakeupNew",
  "vertex_function_key": 289,
  "fragment_function_key": 357,
  "vertex_library_key": 288,
  "fragment_library_key": 356,
  "color_attachment_count": 2,
  "color_attachments": [
    {"index": 0, "format": "RGBA8Unorm", "writeMask": "RGBA"},
    {"index": 1, "format": "RGBA8Unorm", "writeMask": "RGBA"}
  ],
  "depth_format": "Depth32Float_Stencil8",
  "stencil_format": "Depth32Float_Stencil8"
}
```

**实现**：bridge 内部在 `replay_context_init` 之前装 method swizzling（参考 `rps_swizzle_probe.m`），把 (rps, descriptor) 关联落到一张内表。`pipeline` dump 时把这张表带进 JSON。

**工时**：1 天；**风险**：低；**解锁**：消除 "library_key = shader" 的错误抽象；用户在 `pipeline` 输出直接看到 attachment 数 + function key，不用"3137 字节是不是 SubsurfacePass"的猜谜。

### R7.3（原 C2）：`frame-list` 子命令 — 枚举本帧 CommandBuffer / Encoder

```bash
gputrace_replay_bridge frame-list <trace> [--with-draws] [--with-bindings] [--with-timing]
```

输出形如：

```json
{
  "command_buffers": [{
    "index": 0, "label": "Frame Render",
    "encoders": [
      {"index": 0, "type": "render", "label": "Shadows.Draw",
       "color_attachments": [], "depth_attachment": 225, "stencil_attachment": null,
       "first_call_index": 12, "last_call_index": 287, "draw_count": 18,
       "gpu_start_ms": 0.0, "gpu_end_ms": 0.32, "gpu_duration_ms": 0.32},
      {"index": 1, "type": "render", "label": "RenderLoop.Draw",
       "color_attachments": [224, 228], "depth_attachment": 227,
       "first_call_index": 288, "last_call_index": 1450, "draw_count": 42}
    ]
  }]
}
```

**实现路径**：`MTLReplayController` 内部一定持有 CommandBuffer 列表（不然 `playAll` 没法工作）。从 controller 反射拿 `commandBuffers` / 每个 cb 的 `commandEncoders`，再从每个 encoder 取 RenderPassDescriptor（attachments）。

flag 增量：
- `--with-draws`：每个 encoder 的 draw 列表（vertex_count / instance_count / primitive_type / RPS key）
- `--with-bindings`：每个 draw 的 vertex_buffers / fragment_textures / sampler_states
- `--with-timing`：每个 cb 的 `GPUStartTime/GPUEndTime`，host time 微秒级

**工时**：1 天（不含 draws/bindings）+ 2 天（含）；**风险**：中；**解锁**：把"推断"二字从全景报告里彻底抹掉；compute encoder 也一并纳入（不再只有 `compute_pipeline_states_count=0` 一个数字）。

### R7.4（原 C2.5）：`shader-of-rps` 子命令（语义级反查）

```bash
gputrace_replay_bridge shader-of-rps <trace> <rps_key> [--stage fragment|vertex] [--with-ir]
```

行为：
1. 内部走 R7.2 已建立的 RPS↔shader 内表
2. 默认输出 fragment 的 metallib 路径 + cacheKey
3. `--with-ir` 时若 `llvm-dis` 与本机 SDI 目录可用，自动产出 `.ll`

**工时**：1 天；**风险**：中；**解锁**：从 RPS_key 一行命令拿 IR，不需要懂中间任何抽象层。

### R7.5（原 C3）：depth/stencil export + 完整 compute 支持

**子项 A — depth/stencil blit export**
- 当前 `--export` 直接拒绝 depth/stencil
- bridge 内部跑一次最小 RPS，把 depth 复制到一张临时 R32Float、stencil 复制到 R8Unorm，再 `getBytes`
- Apple sample code 标准做法，**无需私有 API**

**子项 B — compute encoder 在 frame-list 中明确化**
- trace 真没 compute 时返回 `compute_encoder_count: 0`
- 有 compute 时把 ComputeCommandEncoder 也列出来（与 render encoder 平级）

**工时**：半天；**风险**：低；**解锁**：ShadowMap 可视化 / stencil bit 可读 / SSS mask / character mask 等可见。

### R7.6（原 C4 + C4.5）：完整 Frame Debugger 等价 + draw 级 shader 反查

**子项 A — `frame-list --with-draws --with-bindings`**
- 见 R7.3 flag 描述

**子项 B — `dump-uniforms <encoder_index> <bind_index>`**
- 用 `MTLArgumentEncoder` 反射或按 cbuffer 元数据 layout 输出 JSON
- 无 layout 时退化为 hex dump + 基本类型猜测

```json
{"AsukaPerShader_PerCamera": {
  "_MainLightDirection": [0.42, -0.85, 0.31, 0.0],
  "_ProjectionMatrix": [[...],[...]]
}}
```

**子项 C — `shader-of-drawcall` 子命令（用户最终目标）**
```bash
gputrace_replay_bridge shader-of-drawcall <trace> <draw_index> [--stage fragment]
```
依赖：先打通"draw call → RPS_key"段（swizzle `setRenderPipelineState:` + `drawIndexedPrimitives:*` 计数），然后串到 `shader-of-rps`。

**工时**：3 天合计；**风险**：中；**解锁**：完全等价 Xcode Frame Debugger；`draw_index → IR` 一行命令。

### R7.7（原 C5）：`disasm` 子命令 — skill 自包含最后一公里

```bash
gputrace_replay_bridge disasm <trace> <rps_key>      # 自动选 fragment, 产出 .ll
gputrace_replay_bridge disasm <trace> <lib_key>      # 直接产出 .ll
```

cacheKey 算法用 ObjC 复刻进 bridge（见 §3.1），内部探测 `llvm-dis` 路径与本机 SDI 目录。

**工时**：1.5 天；**风险**：低；**解锁**：**全链路 7 段在一个二进制里完成**。skill 不再需要跨工程切换到 `LocalDocs/OfflineSourceRecovery/scripts/extract_shader_raw.py`。

---

## 6. LYSK 65 RPS 回归基线

`rps_swizzle_probe.m` 在 `capture_20260518_110050.gputrace` 跑出的 `(RPS_key, label, vertex_func_name, fragment_func_name, v_fn_key, f_fn_key)` 完整表（65 行）作为 R7.2/R7.4 实现的回归基线。下表展示前 10 行与所有 SkinMakeupNew 变体作为样例（仅作"通用机制演示"，不是结论性数据）：

| RPS# | label | v_fn_key | f_fn_key | (lib_key=f-1) |
|---|---|---|---|---|
| 440 | Unlit/TAA/TemporalAA | 257 | 259 | 258 |
| 441 | Unlit/TAA/TemporalAA | 265 | 267 | 266 |
| 442 | Unlit/FSR_EASU_PS | 263 | 271 | 270 |
| 443 | Unlit/FSR_RCAS_PS | 263 | 273 | 272 |
| 444 | Hidden/InternalClearMetal | 275 | 277 | 276 |
| 445 | TextMeshPro/Distance Field | 279 | 281 | 280 |
| 446 | Hidden/Papegame/DepthResolve | 263 | 291 | 290 |
| 447 | Unlit/SSAO | 293 | 295 | 294 |
| 448 | Unlit/SSAOBlur | 293 | 297 | 296 |
| 449 | Hidden/Papegame/ScreenSpaceShadowMap | 261 | 299 | 298 |
| ... | ... | ... | ... | ... |
| **476** | **Papegame/SkinMakeupNew**（Z-Prepass 退化） | 251 | 253 | 252 |
| **484** | **Papegame/SkinMakeupNew**（主 pass） | 289 | 357 | 356 |
| **491** | **Papegame/SkinMakeupNew**（Subsurface） | 389 | 391 | 390 |
| **496** | **Papegame/SkinMakeupNew**（另一变体） | 409 | 411 | 410 |

**关键观察**：
- 同一 label 对应 4 个不同 library — 见 §4
- RPS 474/475/476/479（Teeth/SkinSSS/SkinMakeupNew/EyeSpec）共享 f_fn_key=253（lib=252）— 见 §4

R7.2 实现完成后，bridge `pipeline` 输出应能产生与本表等价的内容。回归测试命令：跑 swizzle 探针 vs 跑 bridge `pipeline` → diff 关键字段。

---

## 7. R7 落地后的等价性表更新草案

| 能力维度 | CLI 等价目标 | R7 之后状态 |
|----------|-------------|-------------|
| Encoder/Pass 枚举 | `frame-list` 列出所有 encoder + attachments | 拟 ✅ R7.3 |
| Draw call 列表 | `frame-list --with-draws` | 拟 ✅ R7.6 |
| Binding 表 | `frame-list --with-bindings` | 拟 ✅ R7.6 |
| Uniform Inspector | `dump-uniforms` | 拟 ⚠️ 部分 R7.6（依赖 layout 元数据） |
| Depth/Stencil 可视化 | `--export` 内置 blit | 拟 ✅ R7.5 |
| Per-encoder GPU timing | `frame-list --with-timing` | 拟 ✅ R7.3 |
| RPS → fragment/vertex shader 反查 | `pipeline` 输出加 function/library key + `shader-of-rps` | 拟 ✅ R7.2 + R7.4 |
| Draw call → shader IR 反查 | `shader-of-drawcall <draw_index>` | 拟 ✅ R7.6 |
| Shader 反编译 | `disasm <rps_key>` 集成 cacheKey + llvm-dis | 拟 ✅ R7.7 |

---

## 8. 不在 R7 范围

明确不做的能力（与当前路径冲突或确认不可达）：

- GPU 硬件计数器 / Profiler / Derived Metrics — 需私有 entitlement + SIP 关闭，已在 R4.4 标注 ⛔
- 修改 `.gputrace` 落盘内容 — skill 设计原则是 read-only，R5.2 已覆盖"内存中替换"
- 完整 shader debugger（断点 / 单步 / 寄存器观察）— Apple 私有，R5.3 确认不可达

---

## 9. SKILL.md / playbook 文档更新（伴随 R7 各 chunk）

每个 R7 chunk 落地后，必须同步更新：

- **SKILL.md** — 在 "Investigation workflow" 之后加一节 **"Exploring an unknown trace's pipeline"**，明确：
  - 当前 skill 在该任务上的能力级别
  - 推荐的最小调用序列
  - 已知盲点（在对应 chunk 落地前）
  - 引导 agent 不要走弯路（zlib 解 store0、grep `unsorted-capture` 等）
- **`references/investigation-playbook.md`** — 加 "frame-overview" worked example（用 LYSK trace 作样例：从空白到 12-pass 全景报告需要的最少 bridge 调用序列）
- **`references/cli-reference.md`** — 同步新子命令的 flag/JSON schema/Python wrapper 接口

---

## 10. 一句话总结

从 draw call 反查到 shader IR 的链路在 macOS Metal replay 框架下是技术可达的（7 段全部走通），但 bridge 当前只做到了段 5~6，最关键的段 1~3 完全没暴露。补完这几段不需要任何私有 entitlement，只需 method swizzling + 反射代码 — 这是 R7 的核心工作。
