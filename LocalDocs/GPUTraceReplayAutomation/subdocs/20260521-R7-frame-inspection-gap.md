# R7：Frame-Inspection 能力缺口分析与改进矩阵

**来源**：2026-05-21 别的 agent 在使用 `gpu-trace-analysis` skill 调查 LYSK trace（247 资源 / 50 RPS / 96 lib）时反馈的能力缺口；以及"draw call 反查 shader IR"的 7 段链路验证。
**结论**：当前 bridge/skill 在"渲染 bug 调查"任务上称职；R7 的目标是把"未知 trace 整体管线分析"与"draw call → shader 反查"两类任务也补齐。
**进度**：R7.1 / R7.2 / R7.3 / R7.4 / R7.6-A / R7.6-C / R7.7 ✅（2026-05-21）；**剩余 R7.6-B（当前最高优先级，依赖 A）→ R7.5（横向新能力）**。优先级二次评估见 §5。
**主回归基线 trace**：
- LYSK：`/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`（4 cb / 62 enc / 244 draws / 65 RPS / 96 lib / 3425 calls）— 端到端 IR 链主基线
- compute-only：`~/Desktop/reference_test_inject.gputrace`（2 cb / 2 compute enc / 0 draws / 0 RPS / 3 compute PSO / 27 calls）— OOR / `draw_count=0` / `rps_not_found` 多样本回归

> 本文档是 R7 的总入口。R6.3（CI/样本库自动化流水线）已确认不做，R7 是 R6 之后唯一的主线。

---

## 1. 设计哲学根因

> **早期 skill 是 "shader bisecter + config knob tester"，不是 "frame inspector"。**

证据：原 5 子命令（`replay`/`pipeline`/`shader`/`config`/`help`）全围绕"重放并对比"，假定用户已知 bug 现象。Xcode Frame Debugger 的 GUI 能力（draw list / encoder timeline / bind table / texture preview / uniform inspector）一律未复刻。R7 通过 `frame-list` / `shader-of-rps` / `shader-of-drawcall` / `disasm` 把"枚举本帧实际发生了什么 + 语义级反查"补上。

---

## 2. 14 处卡点（实测）

LYSK 全景调查中按出现顺序遇到的限制：

| # | 想做的事 | 限制 | 状态 |
|---|---|---|---|
| 1 | 拿本帧 encoder/pass/draw call 时间序 | 无 CommandBuffer/Encoder 列表 | ✅ R7.3 |
| 2 | 知道 `--playto N` 的 N 上限 | 越界 SIGSEGV | ✅ R7.1 |
| 3 | 把 `playto N` 换算成 draw index | N 含大量 set\* | ✅ R7.3（每 draw 落 `call_index`） |
| 4 | 直接读 `.gputrace` bundle 内私有二进制 | 无文档 schema | 放弃（R7.3 swizzle-first 不依赖落盘） |
| 5 | 解 `store0`（zlib）拿 shader 元数据 | 90% 是反射元数据 | 已绕过（R7.2/R7.3/R7.4 内存对象） |
| 6 | 导 depth/stencil 纹理 | bridge 拒绝 | ⏳ R7.5 子项 A |
| 7 | 拿 encoder attachments / bindings | 无 API | attachments ✅ R7.3；bindings ✅ R7.6-A |
| 8 | RT 的 storageMode/usage/framebufferOnly/memoryless | 元数据缺失 | ✅ R7.1 |
| 9 | 区分 buffer 用途（vertex/index/uniform/argbuf） | 仅 length+label | ✅ R7.6-A（binding 表反推） |
| 10 | 看某 draw 的 cbuffer 实际值 | 无 API | ⏳ R7.6 子项 B |
| 11 | 区分 stencil bit | 不能导出 | ⏳ R7.5 子项 A |
| 12 | 确认本帧无 compute dispatch | RPS 元数据有 compute 函数名误导 | ✅ R7.3（dispatch 计数留 R7.5-B） |
| 13 | RPS → fragment/vertex shader | 无关联 | ✅ R7.2 |
| 14 | draw call → shader IR | 7 段未通 | ✅ R7.3+R7.2+R7.4+R7.6-C+R7.7（一行命令） |

---

## 3. draw call → LLVM IR 的 7 段映射

用户心智 = "第 N 个 draw call 用的是哪段 shader？"

```
draw N ─[1]─ RPS_key ─[2]─ fragment MTLFunction* ─[3]─ function_key
                                                          │
                                              [4: lib = fn_key - 1]
                                                          ▼
                              library_key ─[5: pipeline]─ library_<k>.metallib
                                                          │
                                          [6: cacheKey = PlayTools 算法]
                                                          ▼
              ShaderDebugInfo/<bundle>/<cacheKey>/modules/<hash>/module.bc
                                                          │
                                                  [7: llvm-dis]
                                                          ▼
                                                   LLVM IR (.ll)
```

| 段 | 实现 |
|---|------|
| 1: draw→RPS | R7.3 bridge swizzle `MTLCommandQueue/CommandBuffer/RenderCommandEncoder` 链。LYSK 244/244 命中 |
| 2: RPS→MTLFunction | R7.2 swizzle `MTLDevice.newRenderPipelineStateWithDescriptor:[options:reflection:]error:`（PSO 编译完不再持有 function 引用，必须创建那一刻拦截） |
| 3: MTLFunction→fn_key | `objectMap.functionMap` 反向构建 `fnPtr→key`；用 `[NSValue valueWithNonretainedObject:fn]` 作 key |
| 4: fn_key→lib_key | 约定 `library_key = function_key - 1`（trace 内部，非 Apple 通用）；兜底偶数 key 向下扫 `libraryForKey:` |
| 5: lib_key→metallib | bridge `pipeline` 子命令 |
| 6: metallib→cacheKey | PlayTools 算法（见 §3.1）；bridge `compute_playtools_cache_key` |
| 7: bitcode→IR | `--with-ir` 调 `llvm-dis`（Homebrew LLVM；Apple 自带链没有） |

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

### 3.2 历史探针（仅作回归对照）

`LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` (~200 行 ObjC) — R7.2 / R7.4 已把核心算法搬进 bridge，**日常工作不再需要单独跑**；仅在 `rps_correlated_count` 与 `rps_captured_count` 出现 0 / 不匹配时作回归对照。

---

## 4. 关键认知：library 是错误的抽象层级

> "library_key" 对用户毫无意义。

1. **同一 RPS label 对应多个 library**：`Papegame/SkinMakeupNew` 出现 4 次（RPS 476/484/491/496），分别用 4 个不同 library。
2. **多个 RPS 共享同一 library**：RPS 474（Teeth）/ 475（SkinSSS）/ 476（SkinMakeupNew）/ 479（EyeSpec）共享 fragment lib_252（Z-Prepass 阶段都退化成同一个 depth-only fragment）。
3. **"主 shader"与"prepass shader"在 library 层无法区分** — 只能通过 RPS 的 attachment 数 + blend state + `SV_TARGET*` 数量区分。

**结论**：用户视角的最小单位应是 **`RPS_key + label + RT-attachment 摘要`** — 这正是 R7.2 已交付的内容。

---

## 5. R7 改进矩阵（按依赖排序）

R7 拆成 7 个独立 chunk。已完成 7 个（R7.1/R7.2/R7.3/R7.4/R7.6-A/R7.6-C/R7.7），剩余 R7.6-B（**当前 P0**，依赖 R7.6-A 的 binding 表）→ R7.5（P2，横向新能力）。

**优先级演进史**（2026-05-21 多次二次评估）：原排期 R7.5 → R7.6-A → R7.6-B；按"先解锁已交付能力，再加新能力"原则，R7.7（SDI fallback 把 R7.4 命中率从 3.1% 拉到 100%）抢占 R7.5；随后 R7.6-A（紧邻 `shader-of-drawcall` 补 binding 表）抢占 R7.5；R7.6-A 落地后，R7.6-B（依赖 R7.6-A）成为 P0；R7.5（depth/stencil + dispatch 计数）落到 P2。理由：

| 能力 | 是否紧邻已交付能力？ | 场景覆盖 | 实现成本 |
|------|---------------------|----------|----------|
| **R7.6-B**（uniforms） | ✅ R7.6-A 的 binding 表给出 buffer_id+offset 后，B 是把字节解码成 cbuffer JSON 的天然下一步 | UV 错 / 矩阵错 / 光源错 / 材质参数错 — 几乎所有"shader 看似正确但输出错"的最终调查终点 | 1 天，bridge 复用 `bufferForKey:` + reflection / hex dump |
| R7.5（depth/stencil + dispatch 计数） | ❌ 横向新能力 | ShadowMap / SSS / stencil bit 类专项 + compute-heavy trace | 1.5 天，需新写 blit pass + 新 export 接口 |

### R7.1：bridge 越界保护 + 资源元数据补齐 — ✅ 已完成

**交付**：`replay --bounds` / `total_call_count` / `last_call_index` / OOR 结构化错误（exit 12）/ SIGSEGV `setjmp` 兜底 / texture buffer 元数据全补齐。

**关键技术点**：
- `total_call_count` 字段在 `controller + 0x5810`（`uint32_t`），语义为最后被 played 的 call index。`playAll` 完成后 = trace total（LYSK = 3425）。常量 `CONTROLLER_LAST_CALL_INDEX_OFFSET`。
- 反汇编证据：`GTMTLReplayController_playTo` `+0x038: add x23, x0, #0x5000` + `+0x110: ldr w8, [x23, #0x810]` + `+0x114: cmp w8, w19`。回归探针 `Scripts/call_count_probe.m`。
- `--playto N` 当前先 `playAll` 探边界再 `rewind` + `playTo(N)`，多一次全帧开销（LYSK ~9ms 可忽略）。
- 偏移 `+0x5810` 系统升级后可能变化 — 回归脚本 `Scripts/call_count_probe.m`。

### R7.2：`pipeline` 输出加 RPS↔shader 关联 — ✅ 已完成

**交付**：每个 RPS 增加 vertex/fragment function/library key + attachment 摘要 + raster sample count；顶层 `rps_correlated_count` / `rps_captured_count` 作 swizzle 健康度指标。

**关键技术点**：
- bridge ~250 行 §"RPS Swizzle Capture"。`rps_install_swizzles()` 沿 `MTLCreateSystemDefaultDevice()` 类继承链向上找具体设备实现类（如 `AGXG16SDevice`），swizzle `newRenderPipelineStateWithDescriptor:[options:reflection:]error:` 三变体。
- **必须在 `replay_context_init()` 之前安装**：`makeController` 触发 PSO 编译；早一点 `MTLCreateSystemDefaultDevice` 之前类还没具化，晚一点漏掉。
- RPS scan 范围 `rpsMaxKey = funcMap_max + 200`（LYSK function key max=439，RPS 延伸到 496，原来的 +50 headroom 静默截断 491/495/496）。
- 兜底：`library_key = fn_key - 1` 约定失败时按偶数 key 向下扫 `libraryForKey:`。

**LYSK 65 RPS 回归基线**：`rps_count: 65 / rps_correlated_count: 65 / rps_captured_count: 65`。

### R7.3：`frame-list` 子命令（swizzle-first） — ✅ 已完成

**交付**：`frame-list <trace> [--with-draws] [--with-timing]`。LYSK 实测 `{cb=4, encoders=62 (56 render + 2 compute + 4 blit), draws=244, total_call_count=3425, draw_to_rps_map.length=244, 0 个 null rps_key}`。同时打通"段 1（draw→RPS_key）" → `shader-of-drawcall` 退化为薄封装。

**JSON schema**（精简，完整见 `cli-reference.md`）：
```json
{ "command_buffer_count": 4, "encoder_count": 62, "draw_count": 244,
  "rps_correlated_count": 65, "total_call_count": 3425,
  "command_buffers": [{"index":0,"encoders":[
    {"index":0,"type":"render","first_call_index":12,"last_call_index":287,
     "color_attachments":[],"depth_attachment":225,"draw_count":18,
     "draws":[{"draw_index_global":0,"rps_key":449,"primitive_type":"triangle"}]}]}],
  "draw_to_rps_map": [{"draw_index_global":0,"rps_key":449,"encoder_index":0,"draw_in_encoder":0}] }
```

**关键技术点**：
- swizzle 安装顺序：`rps_install_swizzles()` → `frame_install_swizzles()` 都在 `replay_context_init()` 之前。`frame_install_swizzles` 通过 `MTLCreateSystemDefaultDevice → newCommandQueue → commandBuffer` 拿 concrete impl 类立即 swizzle queue / cb 方法。
- **render encoder 类延迟安装**：concrete class 在 `renderCommandEncoderWithDescriptor:` 第一次调用前不易拿到 — 在 swizzle thunk 内首次拿到 encoder 实例时立即 `frame_install_render_encoder_swizzles(object_getClass(encoder))`，幂等保护。
- `swizzle_in_hierarchy(cls, sel, newImp, &origSlot)` 用 `class_copyMethodList` 校验"该类自己声明了该方法"，避免污染 NSObject 基类；R7.2/R7.3 共用 ~30 行 dedup。
- **capture gate** `g_frame_capture_armed`（`volatile sig_atomic_t`）：`frame_install_swizzles` 期间为 0 屏蔽 throwaway；`cmd_frame_list` 在 `safe_playAll` 之前置 1，之后置 0。
- draw → rps_key 映射：`current_rps_ptr` 在 `FrameEncoderEntry` 上独立维护，`setRenderPipelineState:` 更新，`endEncoding` 清零；输出时按 `[objectMap renderPipelineStateForKey:k]` 在 `[0..rpsScan]` 内建 `rps_ptr → rps_key` 字典。
- 容量预算：`g_cb_captured[256] / g_encoder_captured[1024] / g_draws_captured[16384]`（LYSK 留 ~50× headroom）。
- draw 变体：7 个 `drawPrimitives:* / drawIndexedPrimitives:*` 全 swizzle（含 baseVertex/baseInstance）。Indirect draw 未覆盖（LYSK 不用）。

**已知局限**：
- per-encoder timing 在 LYSK 上恒为 null（replay-internal cb 不 commit `MTLCommandBuffer.GPUStartTime/EndTime`）。需要精准时间时回退 `replay --playto N` 二分。
- compute encoder 已在 timeline 列出，但 `compute_dispatch_count=0`（占位字段，待 R7.5-B 补 `setComputePipelineState:` / `dispatchThreadgroups:*` swizzle）。
- binding 表数据量比 draws 大 ~1 个数量级，单独立项 R7.6-A。
- indirect draw 未覆盖。

**架构决策（为什么 swizzle-first，不是反射 `controller.commandBuffers`）**：原计划反射存在两个未验证风险（controller 是否持有扁平 cb 列表 / RenderPassDescriptor 是否在内存）。swizzle 公开 API 把两个风险一起消除：`MTLCommandQueue → MTLCommandBuffer → MTLRenderCommandEncoder → drawXXX` 是公开 Metal API，replay 框架不可能绕过。同时一次冲刺顺手打通"段 1 draw→RPS_key"，把 `shader-of-drawcall` 退化为薄封装（工时 1 天 → 0.5 天）。

### R7.4：`shader-of-rps` 子命令 — ✅ 已完成

**交付**：`shader-of-rps <trace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]`。复用 R7.2 内表 + functionMap 反向表 → metallib + AIR + `cache_key_metallib` 一次性产出；`--with-ir` 调 `llvm-dis` 直出 `.ll`。失败结构化（`rps_not_found / descriptor_not_captured / stage_function_absent / function_key_unresolved / library_not_found / no_air_bitcode / llvm_dis_not_found`），exit 11 但 stdout JSON 完整保留。

**已知盲点**：LYSK 96 lib 中仅 3 个有 `bitcodeData`（~3% 命中率），多数库需 R7.7 SDI 路径补足。

### R7.5：depth/stencil export + compute dispatch 计数补齐 — **P2（横向新能力）**

> **优先级**：原排期 R7.7 完成后 R7.5 接棒为 P0；2026-05-21 二次评估改为 P2，让位给 R7.6-A（紧邻 `shader-of-drawcall` 补足，场景覆盖更广 + 工时相当）。R7.5 是横向新能力，独立可达，无前置依赖；落在 R7.6-A/B 之后。子项 A ≈ 1.5 天 + 子项 B ≈ 0.5 天，合计 1–1.5 天。

**子项 A — depth/stencil blit export**
- 当前 `replay --export <id> <path>` 直接拒绝 depth/stencil 纹理
- bridge 内部跑一次最小 RPS / blit pass，把 depth 复制到临时 R32Float、stencil 复制到 R8Unorm，再 `getBytes` 落盘
- Apple sample code 标准做法，**无需私有 API**

**子项 B — compute encoder dispatch 计数（R7.3 占位字段补齐）**
- R7.3 已让 ComputeCommandEncoder 在 timeline 中与 render/blit encoder 平级列出（type=compute），但 `compute_dispatch_count` 恒为 0
- 把 `MTLComputeCommandEncoder.setComputePipelineState:` / `dispatchThreadgroups:*` / `dispatchThreads:*` 接入 R7.3 的 swizzle 集合，记录 dispatch 计数 + compute pipeline pointer
- 顺手处理 R7.6-C 暴露的 R7.3 trace-shape 假设盲点：compute-only trace 上 `draw_count > 0` / `rps_correlated_count > 0` 隐式假设导致 14 个健康路径断言失败 — 改为"draw 类断言仅在有 render encoder 时启用"

**风险**：低；**解锁**：ShadowMap 可视化 / stencil bit 可读 / SSS mask / character mask 可见 + compute-heavy trace 真实 dispatch 数。

### R7.6 子项 C：`shader-of-drawcall` 薄封装 — ✅ 已完成

**交付**：wrapper-only 路径（bridge 二进制零变更）。
- `shader-of-drawcall <trace> <draw_index> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]`
- 实现 = `frame_list → draw_to_rps_map[draw_index] → shader_of_rps`
- `ShaderOfDrawcallResult` 含 `draw_index / encoder_index / draw_in_encoder / call_index / rps_key / rps_label / shader: ShaderOfRpsResult? / error? / hint?`
- 错误模型：`draw_index >= draw_count` → `DrawIndexOutOfRange`（CLI exit 12，含 `draw_count=0` compute-only 友好 hint）；下游软错误透传顶层（exit 11）；负 idx / 非法 stage → `ValueError`

**端到端验证（LYSK）**：

| 案例 | rps_key | rps_label | 一致性 |
|------|---------|-----------|--------|
| `shader-of-drawcall 0 --with-ir` | 472 | Papegame/Cloth/ClothStandard | metallib 字节级一致；R7.7 之前 `no_air_bitcode`，R7.7 之后产 IR |
| `shader-of-drawcall 103 --with-ir` | 444 | Hidden/InternalClearMetal | metallib + AIR + cacheKey + .ll 字节级一致（仅差 ModuleID 注释行，是 llvm-dis 行为） |

**为什么 wrapper-only**：bridge 内复刻 R7.3 swizzle + R7.4 cacheKey + llvm-dis 调用约 ~150 行胶水，需重构全局表让两条逻辑并存，集成测试需 bridge+wrapper 双份。wrapper-only 直接复用两个已测试 Python 入口，~120 行胶水，bridge 二进制零变更。性能差异（多一次 Python 出入 ~50ms）单次调试可忽略。

### R7.6 子项 A — `frame-list --with-bindings` — ✅ 已完成（2026-05-21）

**交付**：`frame-list <trace> [--with-bindings|--no-bindings]`（默认 ON）。在 R7.3 swizzle 集合上扩展 12 个 `set*` 方法（vertex/fragment × buffer/buffers/bytes/texture/textures/sampler），每 draw 把当前 encoder 的 vertex/fragment binding state snapshot 到 `FrameDrawEntry`；emit 阶段通过 (ptr → resource_id) 反向字典 O(1) 解析；inline `setVertexBytes` 落 `inline_bytes_size` 字段。

**LYSK 主基线实测**：244/244 draw 全部捕获 vertex + fragment binding；avg 8 vertex buffer / draw + 16 fragment texture / draw（PBR 渲染密度不变量）；inline_count=0；vb0 不变量 244/244；JSON 体积 105KB → 394KB（+275%，可控），`--no-bindings` -73%。

**版本与测试**：bridge 0.5.0 → 0.6.0；集成测试 102 → **116/116**（新增 14 项断言：schema / vb0 不变量 / 抑制效果 / 与 shader-of-rps 链兼容）。compute-only trace 上 draw 类断言通过 `[ "$BIND_DRAW_COUNT" -gt 0 ]` 守卫自动跳过。

**新增 dataclass**（wrapper 侧）：`FrameBufferBinding` / `FrameTextureBinding` / `FrameSamplerBinding` / `FrameStageBindings` / `FrameDrawBindings`；`FrameDraw +bindings`；`FrameListResult +with_bindings`；`frame_list() +with_bindings: bool = True`。

**已知局限**：inline buffer 只记 size 不复制 bytes；sampler 不解析 resource_id（不在 objectMap.resources）；compute encoder bindings 留 R7.5-B；indirect draw 留待后补；argument buffer 二级 indirect 由 R7.6-B 配合 reflection 展开。

**详见** `subdocs/20260521-R7.6-A-frame-list-bindings.md`（设计决策 / 数据结构 / JSON schema / 测试断言矩阵）。

### R7.6 子项 B — `dump-uniforms <encoder_index> <draw_index> <bind_slot>`（P1，1 天，依赖子项 A）

- `MTLArgumentEncoder` 反射或按 cbuffer 元数据 layout 输出 JSON
- 无 layout 时退化为 hex dump + 基本类型猜测

```json
{"AsukaPerShader_PerCamera": {
  "_MainLightDirection": [0.42, -0.85, 0.31, 0.0],
  "_ProjectionMatrix": [[...],[...]] }}
```

### R7.7：`disasm` 子命令 + SDI module.bc fallback — ✅ 已完成（2026-05-21）

**抢占 R7.5 成 P0 的理由**：R7.6-C 刚交付的 `shader-of-drawcall --with-ir` 在 LYSK 主样本上仅 ~3% 命中率（96 lib 中仅 3 个有 `bitcodeData`），95%+ 请求得到 `no_air_bitcode` — 即"刚交付的一行命令在主样本上几乎不可用"。R7.7 通过 SDI 路径把命中率拉到 100%。

```bash
disasm <trace> <library_key> --with-ir [--output-dir DIR]                # library 路径（默认）
disasm <trace> <rps_key> --key-type rps --with-ir [--output-dir DIR]      # rps 路径，转发到 shader-of-rps
```

**交付**：
- 新子命令 `disasm`（library_key 默认；`--key-type rps` 转发到 `cmd_shader_of_rps`）
- 统一 IR 产出 helper `emit_ir_for_library(lib_key, airData, cacheKey, outputDir, with_ir)`：先试 `bitcodeData`（`ir_source = "bitcodeData"`），失败按 SDI 路径找 `module.bc`（`ir_source = "sdi_module_bc"`），都失败返回 `ir_error = "no_air_bitcode_and_no_sdi"`
- `shader-of-rps` / `shader-of-drawcall` / `disasm` 三入口**自动共享 R7.7 fallback**，对用户透明
- bridge 0.4.0 → 0.5.0；集成测试 88 → **102/102**

**新输出字段**（`shader-of-rps` / `disasm` 共用）：
```json
{ "ir_source": "bitcodeData" | "sdi_module_bc",
  "sdi_module_bc_path": "/tmp/out/library_374.module.bc",
  "sdi_module_bc_size": 10800,
  "sdi_bundle_id": "com.papegames.lysk",
  "sdi_module_hash": "cb5a538c...",
  "sdi_source_path": "/Users/.../ShaderDebugInfo/com.papegames.lysk/5368B920C0D59DE1_11041/modules/cb5a538c.../module.bc" }
```

**LYSK 96 lib 命中率实测**：

| 路径 | 命中数 | 命中率 |
|------|--------|--------|
| `bitcodeData` only（R7.4 原路径） | 3 / 96 | 3.1% |
| SDI module.bc only（R7.7 新增） | 93 / 96 | 96.9% |
| AIR ∪ SDI（**完全互斥**） | **96 / 96** | **100.0%** |

LYSK 上 AIR 与 SDI 没有任何重叠 — 印证"必须双路径才能完整覆盖"。

**核心设计决策 — 不解析 bundle_id**：
- trace 内 `metadata` plist **不存** bundle_id（实测 LYSK trace 仅有 `(uuid)` / `DYCaptureSession.*` / `DYCaptureEngine.*` 字段）
- 路径解析方式（如 `Containers/<bundle>/Data/Documents/Captures`）不稳健 — 用户可能拷贝到 `~/Desktop`，或 PlayCover 内 trace 不在游戏容器下
- **最优策略**：直接遍历 `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/*/<cacheKey>/modules/*/module.bc`，取第一个匹配。cacheKey 含 metallib 字节长度后缀（例 `5368B920C0D59DE1_11041`），跨 app 哈希碰撞概率统计可忽略
- 副作用：`sdi_bundle_id` 字段从扫描结果反向得出，对用户依然是有用的诊断信息

**核心设计决策 — bridge 内统一 helper 而非 wrapper 拼接**：让 `shader-of-rps` / `shader-of-drawcall` / `disasm` 三入口免改命令受益；`cmd_shader_of_rps` 重构去除 inline metallib/AIR/llvm-dis 调用，改为一行 `emit_ir_for_library(...)`，代码减少 ~70 行。

**已知局限**：
- `<hash>` 多个候选：SDI 目录里同一 cacheKey 下理论上可能有多个 `<sha256>/module.bc`（不同 entry-point 变体）。R7.7 v1 取第一个；LYSK 实测每 cacheKey 只有一个 hash。如未来碰多 hash，v2 可按 metallib `module.meta.json.functionNames[]` 匹配。
- 跨 bundle 路径假设：遍历所有 `<bundle>/` 目录而非锁单一 bundle；如未来用户报告碰撞，可加 `--sdi-bundle-id` flag 显式覆盖。
- SDI 缓存清理后 `module.bc` 不在 → 软失败 + hint "run the app once through PlayCover to populate ShaderDebugInfo"。
- bundle_id 解析功能未做：原计划在 bridge 加 `replay --bundle-id`，因 SDI 路径扫描无需 bundle_id 而省略；如未来需要可后续按需加。

**改动量**：

| 文件 | 改动 |
|------|------|
| `Scripts/gputrace_replay_bridge.m` | +~200 行 helper（`sdi_root_path` / `find_sdi_module_bc` / `emit_ir_for_library`）+ ~150 行 `cmd_disasm` + cmd_shader_of_rps 重构（净 -70 行）；version 0.4.0 → 0.5.0 |
| `Scripts/gputrace_replay_wrapper.py` | `ShaderOfRpsResult` +6 字段；新增 `DisasmResult` + `disasm()` 方法 ~110 行；CLI subparser ~30 行 |
| `Scripts/test_gputrace_replay_bridge.sh` | T2/T4 命令列表更新；新增 T7p 系列 ~85 行（12 断言） |
| `.codebuddy/skills/gpu-trace-analysis/` | 三件套 + SKILL.md + cli-reference.md 全同步；测试数 88 → 102 |

---

## 6. LYSK 65 RPS 回归基线（精选）

`rps_swizzle_probe.m` 在 `capture_20260518_110050.gputrace` 跑出的 65 行 `(RPS_key, label, vertex/fragment fn name, fn key)` 完整表，是 R7.2/R7.4 的回归基线。前 10 行 + 全部 SkinMakeupNew 变体作样例：

| RPS# | label | v_fn_key | f_fn_key | (lib_key=f-1) |
|---|---|---|---|---|
| 440 | Unlit/TAA/TemporalAA | 257 | 259 | 258 |
| 441 | Unlit/TAA/TemporalAA | 265 | 267 | 266 |
| 444 | Hidden/InternalClearMetal | 275 | 277 | 276 |
| 445 | TextMeshPro/Distance Field | 279 | 281 | 280 |
| ... | ... | ... | ... | ... |
| **476** | **Papegame/SkinMakeupNew**（Z-Prepass 退化） | 251 | 253 | 252 |
| **484** | **Papegame/SkinMakeupNew**（主 pass） | 289 | 357 | 356 |
| **491** | **Papegame/SkinMakeupNew**（Subsurface） | 389 | 391 | 390 |
| **496** | **Papegame/SkinMakeupNew**（另一变体） | 409 | 411 | 410 |

**关键观察**：同一 label 4 个不同 library；RPS 474/475/476/479 共享 f_fn_key=253（lib=252）— 见 §4。

R7.2 已交付：bridge `pipeline` 与本表 65/65 一致。回归命令：跑 `LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` 与 bridge `pipeline` 对比。

### Compute-only trace 回归（reference_test_inject）

| 断言 | 期望 |
|------|------|
| `frame-list` exit | 0 |
| `frame-list draw_count` | 0 |
| `frame-list command_buffer_count` | ≥ 1 |
| `frame-list encoder_count`（type=compute） | ≥ 1 |
| `frame-list draw_to_rps_map` | `[]` |
| `shader-of-rps 999` | exit 11，`rps_not_found` |
| `shader-of-drawcall 0` | exit 12，`draw_index_out_of_range` + 友好 hint |
| `pipeline rps_count` | 0 |
| `pipeline compute_pipeline_states_count` | 3 |

**已知盲点**：R7.3 原 T7l/m/n 断言隐式假设 `draw_count > 0`，compute-only trace 上 14 项失败 — 不在 R7.6-C/R7.7 责任范围，由 R7.5-B 顺手处理（断言改为"draw 类断言仅在有 render encoder 时启用"）。

---

## 7. R7 落地后的等价性表

| 能力维度 | CLI 等价目标 | 状态 |
|----------|-------------|------|
| Encoder/Pass 枚举 | `frame-list` 列出所有 encoder + attachments | ✅ R7.3 |
| Draw call 列表 | `frame-list --with-draws`（默认开启） | ✅ R7.3 |
| Binding 表 | `frame-list --with-bindings`（默认开启） | ✅ R7.6-A |
| Uniform Inspector | `dump-uniforms` | ⏳ R7.6-B（**当前 P0**） |
| Depth/Stencil 可视化 | `--export` 内置 blit | ⏳ R7.5-A |
| Per-encoder GPU timing | `frame-list --with-timing` | ⚠️ R7.3 部分（replay-internal cb 不 commit） |
| Compute encoder 在 frame-list 中明确化 | `frame-list` 含 type=compute | ✅ R7.3（dispatch 计数留 R7.5-B） |
| RPS → shader 反查 | `pipeline` 输出 function/library key | ✅ R7.2 |
| RPS_key → shader IR 一行命令 | `shader-of-rps --with-ir` | ✅ R7.4 + R7.7 |
| Draw call → RPS_key 反查 | `frame-list draw_to_rps_map` | ✅ R7.3 |
| Draw call → shader IR 一行命令 | `shader-of-drawcall <draw_index>` | ✅ R7.6-C + R7.7 |
| Draw call → bindings 表 | `frame-list --with-bindings` 内建 | ✅ R7.6-A |
| Shader 反编译（覆盖无 AIR 的 library） | `disasm <library_key>` SDI module.bc 路径 | ✅ R7.7（LYSK 96/96） |

---

## 8. 不在 R7 范围

- GPU 硬件计数器 / Profiler / Derived Metrics — 需私有 entitlement + SIP 关闭（R4.4 ⛔）
- 修改 `.gputrace` 落盘内容 — skill 设计原则 read-only，R5.2 已覆盖"内存中替换"
- 完整 shader debugger（断点/单步/寄存器观察）— Apple 私有，R5.3 不可达

---

## 9. SKILL.md / playbook 文档更新（伴随 R7 各 chunk）

每个 R7 chunk 落地后，必须同步：
- **SKILL.md** — 在 "Investigation workflow" 后加 **"Exploring an unknown trace's pipeline"**：能力级别 / 推荐最小调用序列 / 已知盲点 / 引导 agent 不走弯路（zlib 解 store0、grep `unsorted-capture` 等）
- **`references/investigation-playbook.md`** — frame-overview worked example
- **`references/cli-reference.md`** — 新子命令 flag/JSON schema/wrapper 接口

R7.1~R7.7 + R7.6-A 落地时已同步过这三处。后续 R7.5/R7.6-B 起按相同惯例。

---

## 10. 一句话总结

draw call → shader IR 的 7 段映射在 macOS Metal replay 框架下技术可达且已 7/7 走通：R7.1（边界）+ R7.2（pipeline RPS↔shader）+ R7.3（frame-list swizzle-first：encoder timeline + draw→RPS_key）+ R7.4（shader-of-rps）+ R7.6-A（frame-list --with-bindings：每 draw vertex/fragment buffer/texture/sampler 表，LYSK 244/244）+ R7.6-C（shader-of-drawcall 薄封装）+ R7.7（disasm + SDI module.bc fallback — IR 命中率 3.1%→100%）端到端串通，CLI 形态上 "draw_index → IR + bindings" 是真正的一行命令。LYSK 主基线 + reference_test_inject compute-only 两路回归通过，集成测试 116/116。**当前最高优先级 R7.6-B**（`dump-uniforms`，强依赖 R7.6-A 已交付的 binding 表 — 把 buffer_id+offset 延伸到"buffer 字节按 cbuffer 布局解码成 JSON"）— 1 天；R7.5（depth/stencil + dispatch 计数，1.5 天，独立专项）排在其后。
