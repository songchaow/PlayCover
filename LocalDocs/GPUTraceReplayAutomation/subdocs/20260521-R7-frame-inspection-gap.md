# R7：Frame-Inspection 能力缺口分析与改进矩阵

**来源**：2026-05-21 别的 agent 在使用 `gpu-trace-analysis` skill 调查 `com.papegames.lysk capture_20260518_110050.gputrace`（247 资源 / 50 RPS / 96 lib / ~81 400 GPU API 调用）时反馈的能力缺口；以及"从 draw call 反查 shader IR"的 7 段链路验证。
**结论**：当前 bridge/skill 在"渲染 bug 调查"任务上称职，但在"未知 trace 整体管线分析"与"draw call → shader 反查"两类任务上**严重欠拟合**。R7 的目标是补齐这些能力。
**进度**：R7.1 / R7.2 / R7.3 / R7.4 / R7.6-C ✅（2026-05-21）；剩余 R7.5 / R7.6 子项 A·B / R7.7。
**主回归基线 trace 路径**：
- LYSK：`/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`（4 cb / 62 enc / 244 draws / 65 RPS / 96 lib / 3425 calls）— 端到端 IR 链主基线
- compute-only：`~/Desktop/reference_test_inject.gputrace`（2 cb / 2 compute enc / 0 draws / 0 RPS / 3 compute PSO / 27 calls）— OOR / `draw_count=0` / `rps_not_found` 多样本回归

> 本文档是 R7 的总入口。R6.3（CI/样本库自动化流水线）已确认不做，R7 是 R6 之后唯一的主线。

---

## 1. 当前 skill 的设计哲学（根因）

读 `SKILL.md` + `gputrace_replay_bridge.m` 可见取舍：

> **当前 skill 是 "shader bisecter + config knob tester"，不是 "frame inspector"。**

证据：
- `SKILL.md` 的 4 个调查场景（black screen / wrong color / crash / slow）都假定**用户已知 bug 现象**，工具帮助"二分定位 + 替换验证"。
- 5 子命令（`replay`/`pipeline`/`shader`/`config`/`help`）全围绕"重放并对比"。R7.2 加 `pipeline` 字段、R7.4 加 `shader-of-rps` 已把"语义级反查"补上一半（RPS→IR），但**仍然没有任何子命令面向"枚举本帧实际发生了什么"**。
- Xcode Frame Debugger 的 GUI 能力（draw list / encoder timeline / bind table / texture preview / uniform inspector）**一律未复刻**。

R4.2 + R6.1 选择 `makeDataSource → makeController → playAll/playTo` 路径，对 ObjectMap 静态 dump、对 controller 时间切片重放，但**未遍历 controller 持有的 CommandBuffer/Encoder 时序对象**。

---

## 2. 实测暴露的 14 处卡点

LYSK trace 全景调查任务里按出现顺序遇到的限制（每条都是"我尝试做什么 / 为什么不行 / 怎么绕"）：

| # | 想做的事 | 限制 | 绕路代价 |
|---|---|---|---|
| 1 | 拿本帧 encoder/pass/draw call 时间序 | ~~bridge 仅暴露 ObjectMap 静态视图，无 CommandBuffer/Encoder 列表~~ → ✅ R7.3：`frame-list` 输出 `command_buffers[].encoders[].draws[]` 树 + 扁平 `draw_to_rps_map[]`；`first/last_call_index` 来自 R7.1 controller offset | 已解决 |
| 2 | 知道 `--playto N` 的 N 上限 | ~~越界直接 `SIGSEGV`，无 `bounds` / `total_call_count`~~ → ✅ R7.1：`--bounds` + `total_call_count` + OOR 结构化错误 | 已解决 |
| 3 | 把 `playto N` 换算成 draw index | ~~N 是 GPU API 调用编号，含大量 set\*~~ → ✅ R7.3：每个 encoder 的 `[first_call_index, last_call_index]` + 每 draw 的 `call_index` 字段已落表，`playto N` 与 draw index 已可精确换算 | 已解决 |
| 4 | 直接读 `.gputrace` bundle 内 `capture` / `index` / `device-resources-*` | 私有二进制（`MTSP`/`xdic`），无文档 schema | 放弃（绕过：R7.3 swizzle-first 路径完全不依赖落盘 schema） |
| 5 | 解 `store0`（zlib 流）拿 shader 元数据 | 50 MB 内 90% 是本帧未派发的反射元数据 | 已绕过：R7.2/R7.3/R7.4 直接从内存对象拿 |
| 6 | 导 `DirectionalShadowDepth` / stencil | bridge 拒绝 depth/stencil getBytes | ⏳ R7.5 子项 A |
| 7 | 拿每个 encoder 的 attachments / bindings | ~~无 API~~ → ✅ R7.3：`frame-list` 每个 render encoder 输出 `color_attachments[]` / `depth_attachment` / `stencil_attachment`（reference 到 trace-internal resource id）。**bindings 仍待 R7.6 子项 A** | attachments 已解决；bindings 待 R7.6 |
| 8 | 拿 RT 的 `storageMode` / `usage` / `framebufferOnly` / `memoryless` | ~~资源元数据仅 `width/height/depth/format/textureType/mip/label`~~ → ✅ R7.1：texture/buffer 元数据全补齐 | 已解决 |
| 9 | 区分 buffer 用途（vertex/index/uniform/argbuf） | 仅 `length`+`label` | ⏳ R7.6 子项 A 落地后由 binding 表反推（如 `setVertexBuffer:atIndex:0` → vertex；`setFragmentBuffer:atIndex:K` 且 K 是已知 cbuffer 槽 → uniform） |
| 10 | 看某个 draw 的 cbuffer 实际值 | 无 API | ⏳ R7.6 子项 B（`dump-uniforms`） |
| 11 | 区分 stencil bit | depth/stencil 不能导出 | ⏳ R7.5 子项 A |
| 12 | 确认本帧无 compute dispatch | ~~`compute_pipeline_states_count=0`，但 trace 元数据有大量 compute 函数名~~ → ✅ R7.3：`frame-list` 已 type=compute 列出 ComputeCommandEncoder（dispatch 计数留 R7.5 子项 B 补齐） | 已基本解决 |
| 13 | 从 RPS 反查 fragment/vertex shader | ~~bridge 无 RPS↔function/library 关联；`shader` 子命令仅按 lib_key 替换~~ → ✅ R7.2：`pipeline` 内置 swizzle，输出 vertex/fragment fn key + lib key + attachment 摘要 | 已解决 |
| 14 | 从 draw call 反查 shader IR | ~~段 1（draw→RPS_key）完全未通；段 2~3 需用户写探针；段 4~7 跨 bridge / extract_shader_raw / llvm-dis 三工具拼装~~ → ✅ R7.3 通段 1（`draw_to_rps_map`）+ R7.2/R7.4 通段 2~7（`shader-of-rps --with-ir`）；端到端两条命令完成。✅ R7.6 子项 C（2026-05-21）`shader-of-drawcall <draw_index> --with-ir` 把两条命令合成一条，与 `shader-of-rps` 形成 `(知 RPS / 知 draw_index)` 两入口对称 | 已解决（一行命令） |

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
| 1: draw→RPS | ✅ R7.3 已通（bridge 内置 swizzle） | swizzle `MTLCommandQueue.commandBuffer*` / `MTLCommandBuffer.{render,compute,blit}CommandEncoder*` / `MTLRenderCommandEncoder.{setRenderPipelineState:, drawXXX:*, endEncoding}`。`current_rps_ptr` 在每个 encoder 上独立维护，`drawXXX:` 落表时取当前值。LYSK 244/244 命中。详见 §5.3 |
| 2: RPS→MTLFunction | ✅ R7.2 已通（bridge 内置 swizzle） | swizzle `MTLDevice.newRenderPipelineStateWithDescriptor:[options:reflection:]error:`，从 descriptor 取 fragment/vertexFunction。**PSO 编译完不再持有 function 引用**，只能创建那一刻拦截 |
| 3: MTLFunction→fn_key | ✅ R7.2 已通 | `objectMap.functionMap` 反向构建 `fnPtr→key`；用 `[NSValue valueWithNonretainedObject:fn]` 作 key 比直接 `id` 安全 |
| 4: fn_key→lib_key | ✅ R7.2 已通 | `library_key = function_key - 1`（trace 内部约定，非 Apple 通用）。bridge 实现兜底：约定失败按偶数 key 向下扫一遍 `libraryForKey:` |
| 5: lib_key→metallib | ✅ 已通 | bridge `pipeline` 子命令 |
| 6: metallib→cacheKey | ✅ R7.4 已通（bridge 内置 ObjC 复刻） | PlayTools 算法（见下方 §3.1），bridge 在 `shader-of-rps` 时直接计算 |
| 7: SDI module.bc→IR | ✅ R7.4 已通 | `--with-ir` 调 `llvm-dis`（Homebrew LLVM；Apple 自带链没有）|

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

ObjC 复刻（`compute_playtools_cache_key`）已在 `Scripts/gputrace_replay_bridge.m` 内置，`shader-of-rps` 自动调用。
cacheKey 直接对应 `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cacheKey>/`。

### 3.2 历史探针（R7.2/R7.4 已合入 bridge，仅留作回归对比）

`LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` (~200 行 ObjC，无外部依赖)
打通段 2~7。R7.2 / R7.4 把它的核心算法搬进 `gputrace_replay_bridge.m`，**日常工作不再需要单独跑这个探针**；仅在怀疑 bridge swizzle 失效（`rps_correlated_count` 与 `rps_captured_count` 出现 0 / 不匹配）时作为回归对照。

---

## 4. 关键认知：library 是错误的抽象层级

> "library_key" 对用户毫无意义。

具体表现：
1. **同一 RPS label 对应多个 library**：`Papegame/SkinMakeupNew` 出现 4 次（RPS 476/484/491/496），分别用 4 个不同 library。
2. **多个 RPS 共享同一 library**：RPS 474（Teeth）/ 475（SkinSSS）/ 476（SkinMakeupNew）/ 479（EyeSpec）共享 fragment lib_252 — Z-Prepass 阶段都退化成同一个 depth-only fragment。**所以 "library_key = shader 概念" 是错的**，library_key 只是 trace 内部对 metallib 实例的编号。
3. **"主 shader" 与 "prepass shader" 在 library 层无法区分**：只能通过 RPS 的 attachment 数 + blend state + `SV_TARGET*` 数量区分。

**结论**：用户视角的最小单位应是 **`RPS_key + label + RT-attachment 摘要`**，bridge 必须在 `pipeline` 输出里补上 vertex/fragment function key 与 attachment 摘要 — 这正是 R7.2 已交付的内容。

---

## 5. R7 改进矩阵（按依赖排序的 chunk 列表）

R7 拆成 7 个独立可 PR 的 chunk。每个 chunk 列出工时、风险、解锁能力与新 JSON schema。

**优先级**：原计划按 R7.1 → R7.7 顺序；R7.1/R7.2/R7.3/R7.4 + **R7.6 子项 C** 已完成（2026-05-21；R7.6-C 详见 §5.6）。**当前最高优先级**为 **R7.5**（depth/stencil blit + compute dispatch 计数）。R7.6 子项 A/B/R7.7 排在其后。

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

**已知限制**：`+0x5810` 偏移在当前 macOS 版本稳定；系统升级后若反汇编 prologue 模式变化，需更新常量，回归脚本：`Scripts/call_count_probe.m`。

### R7.2（原 C1.5）：`pipeline` 输出加 RPS↔shader 关联 — ✅ 已完成（2026-05-21）

**交付摘要**

每个 RPS 的 JSON 从 `{key, class, label}` 扩展为：

```json
{
  "key": 484,
  "class": "AGXG16XFamilyRenderPipeline",
  "label": "Papegame/SkinMakeupNew",
  "vertex_function_key": 289,
  "fragment_function_key": 357,
  "vertex_library_key": 288,
  "fragment_library_key": 356,
  "vertex_function_name": "...",
  "fragment_function_name": "...",
  "color_attachment_count": 2,
  "color_attachments": [
    {"index": 0, "format": "RGBA8Unorm", "pixelFormat": 70, "writeMask": "RGBA", "blendingEnabled": false},
    {"index": 1, "format": "RGBA8Unorm", "pixelFormat": 70, "writeMask": "RGBA", "blendingEnabled": false}
  ],
  "depth_format": "Depth32Float_Stencil8",
  "stencil_format": "Depth32Float_Stencil8",
  "raster_sample_count": 1
}
```

顶层新增 `rps_correlated_count` / `rps_captured_count` 作为 swizzle 健康度指标 — 0 表示 swizzle 未生效；正常情况下两者应等于 `render_pipeline_states_count`。

**实现要点**

- bridge 内部新增 ~250 行 §"RPS Swizzle Capture"，`RPSCaptureEntry` + `g_rps_captured[1024]`。
- `rps_install_swizzles()` 沿 `MTLCreateSystemDefaultDevice()` 类继承链向上找具体设备实现类（如 `AGXG16SDevice`），用 `class_getInstanceMethod` + `method_setImplementation` 替换 `newRenderPipelineStateWithDescriptor:[options:reflection:]error:` 的 3 个变体。
- **必须在 `replay_context_init()` 之前安装**：`makeController` 触发 PSO 编译；早一点也不行（`MTLCreateSystemDefaultDevice` 之前类还没具化），晚一点就漏掉。实测 `MTLCreateSystemDefaultDevice` 与 `replay_context_init` 之间没有 PSO 编译，覆盖完全。
- swizzled IMP 调原 IMP 拿到 RPS 实例，再 `rps_capture_descriptor(rps, desc)` 把 (vfunc_ptr/ffunc_ptr/label/attachments/depth/stencil/sample_count) 落表。
- `cmd_pipeline` 用 `objectMap.functionMap` 建反向 `fnPtr→fn_key` 表，再用 `library_key = fn_key - 1` 约定（兜底：偶数 key 向下扫一遍 `libraryForKey:`）。
- RPS scan 范围扩展：`rpsMaxKey = funcMap_max + 200`，专为 RPS 循环用 — LYSK trace max function key=439 而 RPS keys 一直延伸到 496，原来的 +50 headroom 会静默截断 491/495/496。

**LYSK 65 RPS 回归基线**：`rps_count: 65 / rps_correlated_count: 65 / rps_captured_count: 65`，与 §6 表完全一致。

### R7.3（原 C2 + 段 1）：`frame-list` 子命令 — Swizzle-First 同时打通 encoder 列表 + draw→RPS 映射 — ✅ 已完成（2026-05-21）

**交付摘要（实测数据来自 LYSK trace `capture_20260518_110050.gputrace`）**

- `frame-list <trace> [--with-draws] [--no-draws] [--with-timing]` 已上线，default `--with-draws`。
- bridge 内新增 ~600 行 §"Frame Swizzle Capture"。复用 `swizzle_in_hierarchy()` 通用 helper（同时被 R7.2 的 RPS swizzle 用了），减少重复代码。
- 进程级单例：`g_cb_captured[256]` / `g_encoder_captured[1024]` / `g_draws_captured[16384]`，capture gate `g_frame_capture_armed` 仅在 `playAll` 期间打开，过滤掉 `makeController` 阶段框架创建的 throwaway CB / encoder。
- LYSK 端到端：`{cb=4, encoders=62 (56 render + 2 compute + 4 blit), draws=244, total_call_count=3425}`，`enc_sum == draw_to_rps_map.length == 244`，**0 个 null `rps_key`**，`rps_correlated_count=65`（与 R7.2 的 65/65 RPS 完全一致）。
- 端到端联动：`draw_to_rps_map[0].rps_key=472` → `shader-of-rps 472` 出 `library_374.metallib (11041B)` + `cache_key_metallib=5368B920C0D59DE1_11041` — 用户最终目标"draw N → shader IR" 在两个命令内闭环。
- Python wrapper 同步：新增 `FrameListResult` / `FrameCommandBuffer` / `FrameEncoder` / `FrameDraw` / `FrameAttachment` / `FrameDrawToRps` dataclass + `ReplayBridge.frame_list()` 方法 + CLI 子命令 `python3 gputrace_replay_wrapper.py frame-list <trace>`。
- 集成测试：原 63 项 + 新增 18 项 R7.3 断言（含 invariant 检查与 frame-list→shader-of-rps 链） = **81/81 通过**。

**CLI 形态**

```bash
gputrace_replay_bridge frame-list <trace> [--with-draws|--no-draws] [--with-timing]
```

`--with-draws` 默认开启（成本极低）。`--with-bindings` 字段保留给 R7.6 子项 A。

JSON schema（精简示例，完整 schema 见 `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md`）：

```json
{
  "command_buffer_count": 4, "encoder_count": 62, "draw_count": 244,
  "rps_correlated_count": 65, "total_call_count": 3425,
  "command_buffers": [{
    "index": 0, "encoders": [
      {"index": 0, "type": "render", "first_call_index": 12, "last_call_index": 287,
       "color_attachments": [], "depth_attachment": 225, "draw_count": 18,
       "draws": [{"draw_index_global": 0, "rps_key": 449, "primitive_type": "triangle", ...}]}
    ]}],
  "draw_to_rps_map": [{"draw_index_global": 0, "rps_key": 449, "encoder_index": 0, "draw_in_encoder": 0}]
}
```

**关键技术点（实现层根因）**

- **swizzle 安装顺序**：`rps_install_swizzles()` → `frame_install_swizzles()` 都必须在 `replay_context_init()` 之前。`frame_install_swizzles` 通过 `MTLCreateSystemDefaultDevice → newCommandQueue → commandBuffer` 拿到 concrete impl 类，立即 swizzle queue / cb 上的方法。
- **render encoder 类延迟安装**：`MTLRenderCommandEncoder` 的 concrete class（如 `AGXG16XFamilyRenderCommandEncoder`）在 `renderCommandEncoderWithDescriptor:` 第一次调用前不易拿到 — 在该方法 swizzle thunk 内首次拿到 encoder 实例时立即 `frame_install_render_encoder_swizzles(object_getClass(encoder))`，幂等保护。
- **`swizzle_in_hierarchy(cls, sel, newImp, &origSlot)`** 校验"该类自己声明了这个方法"（用 `class_copyMethodList`，而不是 `class_getInstanceMethod`，后者会沿继承链返回 NSObject 实现），避免污染基类。该 helper 同时被 R7.2 RPS swizzle 与 R7.3 frame swizzle 复用，~30 行代码 deduplication。
- **capture gate** `g_frame_capture_armed`（`volatile sig_atomic_t`）：`frame_install_swizzles` 期间为 0，throwaway queue+cb 被 swizzle 但落表函数早退；`cmd_frame_list` 在 `safe_playAll` 之前置 1，之后置 0。结果：`g_cb_captured / g_encoder_captured / g_draws_captured` 只反映真实回放，不会被 framework 在 `makeController` 阶段创建的辅助对象污染。
- **draw → rps_key 两步映射**：每次 `drawXXX:` swizzle thunk 落表 `current_rps_ptr`（在 `FrameEncoderEntry` 上独立维护，`setRenderPipelineState:` 更新，`endEncoding` 清零）。输出时按 `[objectMap renderPipelineStateForKey:k]` 在 `[0..rpsScan]` 内建 `rps_ptr → rps_key` 字典（headroom 与 `pipeline` 子命令一致）。LYSK 244/244 命中。
- **render pass attachment 快照**：encoder 在 `renderCommandEncoderWithDescriptor:` swizzle thunk 内立即 snapshot RenderPassDescriptor — `colorAttachments[0..7]` / `depthAttachment` / `stencilAttachment` 的 `texture / pixelFormat`，`texture` 通过 `frame_lookup_resource_id` 反查 `objectMap.resources` 得 trace-internal resource id（与 `replay --list-resources` 对齐）。
- **进程级容量预算**：`g_cb_captured[256]` / `g_encoder_captured[1024]` / `g_draws_captured[16384]`，按 LYSK 3425 calls / 244 draw 留 ~50× headroom。
- **`first/last_call_index` 来源**：复用 R7.1 的 `*(uint32_t *)(controller + 0x5810)`，每次 swizzle 入口实时读取。
- **draw 变体覆盖**：7 个 `drawPrimitives:* / drawIndexedPrimitives:*` 变体全部 swizzle（含 `baseVertex/baseInstance`）。Indirect draw（`drawPrimitives:indirectBuffer:` 等）暂未覆盖，LYSK trace 不用；如未来需要，加入 `frame_install_render_encoder_swizzles` 即可（结构化数据上 `vertex_count/instance_count=0 + indirect:true`）。
- **timing 字段语义**：`MTLCommandBuffer.GPUStartTime/EndTime` 在很多 replay-internal CB 上保持 0，bridge 翻译为 `gpu_duration_ms: null`（不让 callers 误把 0 当"零开销"）。`--with-timing` 仍保留 flag，未来若需精确可补"基于 `addCompletedHandler:` 回调"的路径。

**回归基线**

| 指标 | LYSK 期望值 | 实测 |
|------|-------------|------|
| `command_buffer_count` | 4 | 4 |
| `encoder_count` (render/compute/blit) | 56/2/4 | 56/2/4 |
| `draw_count` | 244 | 244 |
| `enc.draw_count.sum() == len(draw_to_rps_map)` | True | True |
| `none(rps_key) in draw_to_rps_map` | 0 | 0 |
| `rps_correlated_count == R7.2 rps_count` | 65 | 65 |
| `total_call_count` | 3425 | 3425 |
| `frame-list elapsed_ms` | <50ms | ~12ms |

**端到端 draw → IR 闭环（LYSK 实测）**

```bash
RPS_KEY=$(./gputrace_replay_bridge frame-list "$LYSK" 2>/dev/null \
            | jq '.draw_to_rps_map[0].rps_key')          # → 472
./gputrace_replay_bridge shader-of-rps "$LYSK" $RPS_KEY --output-dir /tmp/r73_chained
# → library_374.metallib (11041B) + cache_key_metallib=5368B920C0D59DE1_11041
```

7 段全通：draw 0 → RPS 472 → fragment_function_key 375 → library_key 374 → metallib (11041B) + AIR + cacheKey。

**改动量（参考）**

- `Scripts/gputrace_replay_bridge.m` +~620 行（"Frame Swizzle Capture" + `cmd_frame_list`），version 0.3.0 → 0.4.0
- `Scripts/gputrace_replay_wrapper.py` +6 dataclass + `frame_list()` 方法 + CLI subparser（~150 行）
- `Scripts/test_gputrace_replay_bridge.sh` +18 项 R7.3 断言（T7l/T7m/T7n），总数 63 → 81
- skill 同源同步：`scripts/gputrace_replay_bridge.m` / `gputrace_replay_wrapper.py` / `test_bridge.sh` / `setup.sh` 重编 + ad-hoc 签名
- 文档同步：SKILL.md（六→七子命令 + workflow 加 frame timeline）、`cli-reference.md`（新 `## Subcommand: frame-list`）、`investigation-playbook.md`（Pattern 7 升级为 R7.2+R7.3+R7.4 联动）

**已知局限**

- per-encoder timing 在 LYSK 上恒为 null（replay-internal cb 不 commit）。需要精准 per-segment 时间时回退到 `replay --playto N` 二分（playbook Pattern 4）。
- compute encoder 的 `setComputePipelineState:` / `dispatchThreadgroups:*` 未接入 swizzle — R7.5 子项 B 顺手补齐；当前 `compute_dispatch_count` 恒为 0，但 compute encoder 本身已列在 timeline 中。
- binding 表（`setVertexBuffer:` / `setFragmentTexture:` 等）按设计推迟到 R7.6 子项 A（数据量比 draws 大 ~1 数量级 + 独立 binding 模型）。
- indirect draw 未覆盖（同上"draw 变体覆盖"段）。

**架构决策：为什么 swizzle-first，不是反射 `controller.commandBuffers`**

原 R7.3 计划是反射 `MTLReplayController.commandBuffers`，存在两个未验证风险：(1) controller 是否真的持有扁平 CommandBuffer 列表（vs dispatch queue 派发不缓存）—— 未导出符号无法静态确认；(2) 每个 cb 的 encoder 列表能否反射到、RenderPassDescriptor 是否还在内存 —— 全是问号。

swizzle 公开 API 把两个风险一起消除：`MTLCommandQueue → MTLCommandBuffer → MTLRenderCommandEncoder → drawXXX` 是公开 Metal API，replay 框架不可能绕过；只要装在 `replay_context_init` 之前（与 R7.2 RPS swizzle 同时机），`playAll` 期间真实发生的每个 encoder/draw 100% 命中。同时**一次冲刺顺手打通原 R7.6 段 1（draw→RPS_key）**，把 `shader-of-drawcall` 退化为薄封装（R7.6 子项 C 工时 1 天 → 0.5 天）。

### R7.4（原 C2.5）：`shader-of-rps` 子命令（语义级反查）— ✅ 已完成（2026-05-21）

```bash
gputrace_replay_bridge shader-of-rps <trace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
```

**交付摘要**

- 复用 R7.2 内表 + functionMap 反向表 → metallib + AIR + `cache_key_metallib` 一次性产出
- `--with-ir` 自动找 `llvm-dis`（Homebrew → PATH）→ 跑 `llvm-dis $airPath -o $llPath` → 写 `ir_ll_path/ir_ll_size`
- 失败结构化（`rps_not_found` / `descriptor_not_captured` / `stage_function_absent` / `function_key_unresolved` / `library_not_found` / `no_air_bitcode` / `llvm_dis_not_found`），exit 11 但 stdout JSON 完整保留供 wrapper 继续解析
- Python wrapper 同步：`ColorAttachment` / `ShaderOfRpsResult` dataclass + `ReplayBridge.shader_of_rps()` 方法

**端到端实测（LYSK trace, RPS 444 = `Hidden/InternalClearMetal`，f_fn=277, f_lib=276）**：

```text
function_name: clear_fshader
library_metallib_path: /tmp/r74_validate/library_276.metallib (7888 bytes)
library_air_path:      /tmp/r74_validate/library_276.air (6448 bytes)
ir_ll_path:            /tmp/r74_validate/library_276.ll (3257 bytes)
cache_key_metallib:    CB535F216771DC94_7888
```

`.ll` 头部确认是合法 LLVM IR（`define <{ <4 x float>, <4 x half> }> @clear_vprog ...`，`target triple = "air64_v28-apple-macosx26.5.0"`）。

**边缘情况**：

| 场景 | 输入 | 退出码 | JSON `error` |
|------|------|--------|--------------|
| 不存在的 RPS_key | `shader-of-rps … 999999` | 11 | `rps_not_found` |
| 非法 `--stage` | `--stage banana` | 1 (USAGE) | — (stderr message) |
| 库无 AIR | `shader-of-rps … 484 --with-ir` | 0 | `ir_error: no_air_bitcode`（多数 `_MTLLibrary` 仅有 metallib，约 LYSK 96 lib 中 3 个有 AIR） |

### R7.5（原 C3）：depth/stencil export + compute dispatch 计数补齐

> **优先级**：R7.6 子项 C 已于 2026-05-21 完成；**R7.5 现为当前最高优先级**。子项 A（depth/stencil blit）是新能力，工时 ≈ 1.5 天（写 Metal blit pipeline + 测试 + 文档）；子项 B（compute dispatch 计数）依赖 R7.3 swizzle 基础设施，工时 ≈ 0.5 天。整体 1–1.5 天合计。

**子项 A — depth/stencil blit export**
- 当前 `replay --export <id> <path>` 直接拒绝 depth/stencil 纹理
- bridge 内部跑一次最小 RPS / blit pass，把 depth 复制到临时 R32Float、stencil 复制到 R8Unorm，再 `getBytes` 落盘
- Apple sample code 标准做法，**无需私有 API**

**子项 B — compute encoder dispatch 计数（R7.3 占位字段补齐）**
- R7.3 已让 ComputeCommandEncoder 在 `frame-list` timeline 中与 render/blit encoder 平级列出（type=compute），但 `compute_dispatch_count` 字段恒为 0
- 子项 B：把 `MTLComputeCommandEncoder.setComputePipelineState:` / `dispatchThreadgroups:*` / `dispatchThreads:*` 接入 R7.3 的 swizzle 集合，记录 dispatch 计数 + 每次 dispatch 的 compute pipeline pointer（最小实现：仅 dispatch 数；完整实现：把 dispatch 也落到 `draws[]` 兄弟字段如 `dispatches[]`）

**工时**：半天；**风险**：低；**解锁**：ShadowMap 可视化 / stencil bit 可读 / SSS mask / character mask 等可见 + compute-heavy trace 的真实 dispatch 数。

### R7.6（原 C4 + C4.5）：完整 Frame Debugger 等价 + draw 级 shader 反查

> **注**：R7.3 改为 swizzle-first 后，"段 1 draw→RPS_key" 已在 R7.3 完成。R7.6 退化为以下三块。**子项 C 已于 2026-05-21 完成（wrapper-only 路径）**；子项 A/B 排在 R7.5 之后。

### R7.6 子项 C（原"当前最高优先级"）：`shader-of-drawcall` 薄封装 — ✅ 已完成（2026-05-21）

**交付摘要**

| 项目 | 内容 |
|------|------|
| 实现路径 | wrapper-only（`Scripts/gputrace_replay_wrapper.py`），bridge 二进制完全不改 |
| 新增 dataclass | `ShaderOfDrawcallResult`（含 `draw_index / encoder_index / draw_in_encoder / call_index / rps_key / rps_label / shader: ShaderOfRpsResult? / error? / hint?`），`DrawIndexOutOfRange` 异常类 |
| 新增方法 | `ReplayBridge.shader_of_drawcall(trace, draw_index, *, stage='fragment', with_ir=False, output_dir=None, timeout=300.0)` |
| CLI subparser | `python3 gputrace_replay_wrapper.py shader-of-drawcall <trace> <draw_index> [--stage fragment\|vertex] [--with-ir] [--output-dir DIR]` |
| 错误模型 | `draw_index >= draw_count` → `DrawIndexOutOfRange`（CLI exit 12，含 `draw_count=0` compute-only 友好 hint）；下游 `shader-of-rps` 的 `rps_not_found` / `no_air_bitcode` / `descriptor_not_captured` 等结构化错误透传到顶层并 CLI exit 11；负 idx / 非法 stage → `ValueError` |
| Skill 同步 | `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py`、`scripts/test_bridge.sh`、`SKILL.md` 能力表 + worked example、`references/cli-reference.md` 新增 §"Subcommand: shader-of-drawcall (wrapper-only)" + dataclass 表项、`references/investigation-playbook.md` Pattern 7 末尾"One-shot"小节 |
| 集成测试 | `Scripts/test_gputrace_replay_bridge.sh` T7o 系列（3 个子测试，7 个断言）：①LYSK draw_index=0 wrapper 输出与手工链 metallib 字节级一致 + 顶层 frame-list 嵌入字段完整 ②OOR 99999999 → exit 12 + structured error ③模块 API 三种异常合约（`DrawIndexOutOfRange` + 负 idx ValueError + 非法 stage ValueError） |

**端到端验证（LYSK trace, 2026-05-21）**

| 案例 | rps_key | rps_label | metallib | AIR | cacheKey | .ll |
|------|---------|-----------|----------|-----|----------|-----|
| `shader-of-drawcall 0 --with-ir` | 472 | Papegame/Cloth/ClothStandard | `library_236.metallib` ✅ 字节一致 | (no AIR) | ✅ | (no IR; `no_air_bitcode`) |
| `shader-of-drawcall 103 --with-ir` | 444 | Hidden/InternalClearMetal | `library_276.metallib` ✅ 字节一致 | `library_276.air` ✅ 字节一致 | `CB535F216771DC94_7888` ✅ | ✅ 仅差 `; ModuleID = '...air'` 路径注释（llvm-dis 行为，非语义差异） |

**Compute-only trace 回归（reference_test_inject.gputrace, 2026-05-21）**

| 断言 | 实测 |
|------|------|
| `frame-list` exit | 0 ✅ |
| `frame-list` 输出 `draw_count` | 0 ✅ |
| `frame-list` 输出 `command_buffer_count` | 2 ✅ |
| `frame-list` 输出 `encoder_count` | 2（compute encoder） ✅ |
| `frame-list` 输出 `draw_to_rps_map` | `[]` ✅ |
| `shader-of-rps 999` | exit 11，`rps_not_found` ✅ |
| `shader-of-drawcall 0` | exit 12，`draw_index_out_of_range` + 友好 hint "trace has no render draws" ✅ |
| `pipeline` 输出 `render_pipeline_states_count` | 0 ✅ |
| `pipeline` 输出 `compute_pipeline_states_count` | 3 ✅ |

**测试套件总数**：81 → 88（GPUTRACE_PATH=LYSK 时全部通过）。compute-only trace 上 R7.3 原有"健康路径"断言（draw_count > 0、rps_correlated_count > 0 等）会失败 14 项，属 R7.3 的 trace-shape 假设盲点暴露，**不在 R7.6-C 责任范围**。

**实现亮点**
- 纯 Python 胶水代码 ~120 行（不含 dataclass 定义和文档），bridge 二进制零变更。
- `rps_label` 通过遍历 `frame_list.command_buffers` 树补齐（`draw_to_rps_map` 扁平表里没有 label），让用户在顶层 JSON 直接看到 "Papegame/Cloth/ClothStandard" 这类语义信息，不必再回查 frame-list 输出。
- 与 `shader-of-rps` 同款 exit-code 语义：软错误 exit 11、OOR exit 12、bridge 子进程错误透传原码，shell 流水线无需解析 JSON 即可分支。
- compute-only OOR hint 单独定制（"trace has no render draws"），帮助用户区分"这个 trace 不该用 shader-of-drawcall"vs"我打错了 draw_index"两种心智错误。

详见 `executions/20260521-R7.6-C-shader-of-drawcall-execution.md`。

---

### R7.6 子项 A — `frame-list --with-bindings`

- swizzle `setVertexBuffer:offset:atIndex:` / `setVertexTexture:atIndex:` / `setFragmentBuffer:*` / `setFragmentTexture:*` / `setVertexBytes:length:atIndex:`（inline）等
- 每个 draw 关联当时的完整 binding 表（buffer_id / texture_id / offset / index）
- 数据量比 R7.3 draws 大 ~1 个数量级，故单独立项

**子项 B — `dump-uniforms <encoder_index> <draw_index> <bind_slot>`**
- 用 `MTLArgumentEncoder` 反射或按 cbuffer 元数据 layout 输出 JSON
- 无 layout 时退化为 hex dump + 基本类型猜测
- 依赖子项 A 的 binding 表来定位 buffer

```json
{"AsukaPerShader_PerCamera": {
  "_MainLightDirection": [0.42, -0.85, 0.31, 0.0],
  "_ProjectionMatrix": [[...],[...]]
}}
```

**整体工时**（R7.3 完成后）：
- 子项 C: 0.5 天 ← **最先做**
- 子项 A: 1.5 天
- 子项 B: 1 天

**风险**：低（公开 API + 已有基础设施）；**解锁**：完全等价 Xcode Frame Debugger；`draw_index → IR` 一行命令。

#### 多样本回归（伴随子项 C 落地）

子项 C 落地时**必须用第二个 trace 回归 R7.3/R7.4**，原因：当前回归基线 100% 依赖 LYSK trace 单样本，容易掩盖 trace-shape 假设错误。

推荐第二样本：`~/Desktop/reference_test_inject.gputrace`（compute-only，3 kernel / 4 buffer / 0 render pipeline / 0 draw call）。

回归断言（加入 `Scripts/test_gputrace_replay_bridge.sh` T7o 系列）：

| 断言 | 期望 |
|------|------|
| `frame-list reference_test_inject` exit | 0 |
| `frame-list` 输出 `draw_count` | 0（无 render encoder） |
| `frame-list` 输出 `command_buffer_count` | ≥ 1（compute trace 仍至少有一个 cb） |
| `frame-list` 输出 `encoder_count` 中 type=compute | ≥ 1 |
| `frame-list` 输出 `draw_to_rps_map` | `[]`（empty array） |
| `shader-of-rps` 任意 RPS_key | exit 11，error=`rps_not_found` |
| `shader-of-drawcall 0` | exit 非零 + 结构化 `draw_index_out_of_range` |
| `pipeline reference_test_inject` 输出 `rps_count` | 0 |
| `pipeline reference_test_inject` 输出 `compute_pipeline_states_count` | 3 |

新增**回归基线表**（除 LYSK 65 RPS 之外）保存于 §6 末尾。

### R7.7（原 C5）：`disasm` 子命令 — skill 自包含最后一公里

```bash
gputrace_replay_bridge disasm <trace> <rps_key>      # 自动选 fragment, 产出 .ll
gputrace_replay_bridge disasm <trace> <lib_key>      # 直接产出 .ll
```

R7.4 已把 cacheKey + llvm-dis 集成进 `shader-of-rps`，`disasm` 在 R7.7 主要做：①支持直接传 `lib_key`（不走 RPS）； ②探测 SDI 目录路径并直接读 `module.bc`（覆盖 `bitcodeData` 缺失但 SDI 有缓存的情形 — LYSK 96 lib 中 93 个属于这一类）。

**工时**：1.5 天；**风险**：低；**解锁**：**全链路 7 段在一个二进制里完成**，覆盖率从 R7.4 的 ~3% AIR 提升到接近 100%。

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

R7.2 已交付：bridge `pipeline` 与本表 65/65 一致。**回归测试命令**：跑 `LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` 与 bridge `pipeline` 对比（`rps_correlated_count` 应等于 `rps_captured_count`，且与本表关键字段一致）。

---

## 7. R7 落地后的等价性表更新

| 能力维度 | CLI 等价目标 | R7 之后状态 |
|----------|-------------|-------------|
| Encoder/Pass 枚举 | `frame-list` 列出所有 encoder + attachments | ✅ R7.3 |
| Draw call 列表 | `frame-list --with-draws`（默认开启） | ✅ R7.3 |
| Binding 表 | `frame-list --with-bindings` | ⏳ R7.6 子项 A |
| Uniform Inspector | `dump-uniforms` | ⏳ 部分 R7.6 子项 B（依赖 layout 元数据） |
| Depth/Stencil 可视化 | `--export` 内置 blit | ⏳ R7.5 子项 A |
| Per-encoder GPU timing | `frame-list --with-timing` | ⚠️ R7.3 部分（replay-internal cb 不 commit，时间字段 null） |
| Compute encoder 在 frame-list 中明确化 | `frame-list` 含 type=compute | ✅ R7.3（compute encoder 已平级列出，dispatch 计数留 R7.5 子项 B） |
| RPS → fragment/vertex shader 反查 | `pipeline` 输出加 function/library key | ✅ R7.2 |
| RPS_key → shader IR 一行命令 | `shader-of-rps --with-ir` | ✅ R7.4 |
| **Draw call → RPS_key 反查** | `frame-list` 输出 `draw_to_rps_map` | ✅ R7.3 |
| **Draw call → shader IR 一行命令** | `shader-of-drawcall <draw_index>` | ✅ R7.6-C |
| Shader 反编译（覆盖无 AIR 的 library） | `disasm <rps_key>` SDI module.bc 路径 | ⏳ R7.7 |

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

R7.1/R7.2/R7.3/R7.4 落地时已同步过这三处。后续 R7.5/R7.6/R7.7 起按相同惯例。

---

## 10. 一句话总结

draw call → shader IR 的 7 段映射在 macOS Metal replay 框架下技术可达且已 7/7 走通：R7.1（边界）+ R7.2（pipeline RPS↔shader）+ R7.3（frame-list swizzle-first：encoder timeline + draw→RPS_key）+ R7.4（shader-of-rps 一行命令出 metallib/AIR/IR）+ **R7.6-C（shader-of-drawcall 薄封装 — 两命令合一，2026-05-21）** 五个 chunk 端到端串通，用户最终目标"draw_index → IR"已经是**真正的一行命令**（`python3 gputrace_replay_wrapper.py shader-of-drawcall <trace> <draw_index> --with-ir`）。LYSK 主基线 + reference_test_inject compute-only 第二样本两路回归通过，集成测试 88/88。**当前最高优先级切换为 R7.5**（depth/stencil blit + compute dispatch 计数）。R7.6 子项 A/B（binding/uniform）/ R7.7（SDI module.bc 覆盖无 AIR）排在其后，属体验补完。
