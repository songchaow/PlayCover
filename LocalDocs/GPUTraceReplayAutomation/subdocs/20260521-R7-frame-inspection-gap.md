# R7：Frame-Inspection 能力缺口分析与改进矩阵

**来源**：2026-05-21 别的 agent 在使用 `gpu-trace-analysis` skill 调查 LYSK trace（247 资源 / 50 RPS / 96 lib）时反馈的能力缺口；以及"draw call 反查 shader IR"的 7 段链路验证。
**结论**：当前 bridge/skill 在"渲染 bug 调查"任务上称职；R7 的目标是把"未知 trace 整体管线分析"与"draw call → shader 反查"两类任务也补齐。
**进度与剩余项**：以主 dashboard `README.md` 的"下一步"与"任务 TODO" 段为准，本文档只承载实现细节、设计决策、回归基线。集成测试基线：LYSK 主基线 **148/148**（R7.6-D 后），compute-only `reference_test_inject` 79/93（14 个 R7.3 已知盲点不变）。优先级演进史见 §5。
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
| 10 | 看某 draw 的 cbuffer 实际值 | 无 API | ✅ R7.6-B |
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

R7 拆成 9 个独立 chunk（R7.1~R7.7 + R7.6-D 收尾联动 + R7.6-E label 反查）。已完成 9 个（R7.1/R7.2/R7.3/R7.4/R7.6-A/R7.6-B/R7.6-C/R7.6-D/R7.7），剩余 **R7.6-E（当前 P0，wrapper-only label 反查，0.3 天）** + **R7.5（R8 Sprint α 后接棒 P0，独立横向硬能力，1–1.5 天）**。**R8 Sprint α**（R8.1+R8.2+R8.3，agent 多数据源 join 错误的结构性消除，1.5 天）在 R7.6-E 与 R7.5 之间接棒 P0 — 详见 `20260522-R8-skill-usability-backlog.md`，本文档不再展开 R8 实现细节。

**优先级演进史**（多次二次评估精简版）：原排期 R7.5 → R7.6-A → R7.6-B；按"先解锁已交付能力，再加新能力"原则，R7.7（SDI fallback 把 R7.4 命中率 3.1% → 100%）→ R7.6-A（紧邻 `shader-of-drawcall` 补 binding 表）→ R7.6-B（依赖 R7.6-A）→ R7.6-D（wrapper 联动三件套）连续抢占 R7.5；R7.6-D 落地后再次让位给 R7.6-E（用户实战 `locate_shader.py` 暴露 GUI↔CLI 入口阻抗，0.3 天 wrapper-only）。**2026-05-22 RPS 496 / draw 69 复盘后又抢占一次**：发现 ~80% agent 错误根源是"在多份数据源之间手工 join"（非"工具能力不够"），R8 Sprint α（merged binding view + size_check + value_health + by-name 查询，1.5 天合并）对真实工作流接入度的提升 > R7.5 横向硬能力，故插队到 R7.5 之前。各候选当时取舍速览：

| 能力 | 紧邻已交付能力？ | 场景覆盖 | 实现成本 |
|------|---------------------|----------|----------|
| **R7.6-E（当前 P0）** | ✅ frame-list 已含 rps_label / vertex_function_name / fragment_function_name；纯后处理过滤 | "GUI 看 shader 名 → CLI 拿三件套" — 解锁 R7.6-D 在真实工作流的接入度 | 0.3 天，纯 wrapper 后处理，bridge 零变更 |
| **R8 Sprint α（R7.6-E 后接棒 P0）** | ✅ R7.2 reflection + R7.4 air metadata + R7.6-A binding 表已交付，sprint = "把它们 join 后再交给 agent" | 消除 ~80% agent 多数据源 join 错误（slot 5/6 颠倒、texture rid 错位、NaN 静默通过、binding 大小不匹配漏检） | 1.5 天合计（共享一份 RPS→library→AIR metadata cache） |
| R7.6-D（已交付） | ✅ frame-list bindings + dump-uniforms 都已交付，只差 wrapper 层把它们附到 `ShaderOfDrawcallResult` 上 | "draw N → IR + bindings + uniforms 一行命令" — 与 GUI 选 draw 时默认看到一屏完整上下文的体验对齐 | 0.5 天，纯 Python 胶水，bridge 零变更（实测耗时一上午） |
| R7.6-B（uniforms，已交付） | ✅ R7.6-A 的 binding 表给出 buffer_id+offset 后，B 是把字节解码成 cbuffer JSON 的天然下一步 | UV 错 / 矩阵错 / 光源错 / 材质参数错 — 几乎所有"shader 看似正确但输出错"的最终调查终点 | 1 天，bridge 复用 `bufferForKey:` + reflection / hex dump |
| **R7.5（R8 Sprint α 后接棒 P0）** | ❌ 横向新能力 | ShadowMap / SSS / stencil bit 类专项 + compute-heavy trace | 1–1.5 天，需新写 blit pass + 新 export 接口 |

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

### R7.6 子项 D：`shader-of-drawcall` 三件套合一（wrapper 联动收尾） — ✅ 已完成（2026-05-21）

**交付**：纯 wrapper 层胶水，bridge 二进制零变更。

- `shader-of-drawcall <trace> <draw_index> [--stage] [--with-ir] [--with-bindings] [--with-uniforms] [--output-dir]`
- `ShaderOfDrawcallResult` 加 `bindings: FrameDrawBindings | None` + `uniforms: list[DumpUniformsResult] | None`
- wrapper 内部 `frame-list` 调用按需附 `with_bindings=True` 一次性回收 binding 表（不再只取 `draw_to_rps_map` 浪费 R7.6-A 已经付的钱）；新增内部 helper `_dump_uniforms_for_resolved()` 跳过 `dump_uniforms()` draw 模式重跑 frame-list 的开销
- `with_uniforms=True` 隐含 `with_bindings`；对 `bindings.{stage}.buffers[]` 每个 slot 调一次 bridge `dump-uniforms`，per-slot 软错误（`reflection_not_captured` / `binding_not_a_buffer` / `offset_out_of_range`）落到 `uniforms[i].error` 不阻塞链路
- CLI payload 新增顶层 `with_bindings` / `bindings` / `with_uniforms` / `uniforms` / `uniforms_summary`（`{slot_count, slot_ok, slot_failed, errors[]}`）
- 默认无 flag 调用产物与 R7.6-C 完全一致（T7s-1 测试覆盖）

**核心设计决策**：

1. **`with_uniforms` 隐含 `with_bindings`**：`uniforms[]` 每个元素需要 `(rps_key, bind_slot, buffer_key, offset)`——前两个来自 frame-list 的 `draw_to_rps_map`，后两个来自 R7.6-A 的 `bindings.<stage>.buffers[i].{resource_id, offset}`。绕过 bindings 拿不到 buffer_key/offset。
2. **单次 frame-list 调用承载两份数据**：R7.6-C 旧实现已经在内部跑 `frame_list(with_draws=True)` 但调用方没传 `with_bindings`——意味着 wrapper 已付 binding 捕获代价却扔掉输出。R7.6-D 不增加新子进程调用，复用同一次 frame-list 输出 O(1) 增量代价回收 bindings。
3. **内部 helper `_dump_uniforms_for_resolved()` 避免重复 frame-list**：公共 `dump_uniforms(target_kind="draw")` 自己跑一次 frame-list 解析 `(rps_key, buffer_key, offset)`；在 `shader_of_drawcall` 上下文里所有解析信息都已在手，对 N=4 个 buffer slot 直调公共 API 会重复跑 4 次 frame-list（理论 ~6.8s 浪费）。helper 直接构造 bridge args（`target=rps_key, --buffer-key, --offset` 都已知），跳过 wrapper 层 frame-list。LYSK draw 0 fragment 4 slot 实测从理论 ~6.8s → 实际 ~1.7s（一次 frame-list + 4 次 ~50ms bridge dump-uniforms）。
4. **per-slot 软错误隔离**：bridge `dump-uniforms` 软失败（exit 11 + 结构化 error）由 `_run()` 已有的 exit 11/12 graceful 路径自然落到 `DumpUniformsResult.error` 字段；顶层 `result.error` 仍只反映 `shader-of-rps` 半边的错误（与 R7.6-C 行为一致）；`uniforms_summary.slot_failed` 让消费方一眼看到 per-slot 健康度；极少见 bridge 硬故障（exit 4–10）通过 try/except `BridgeError` 捕获，落伪 `DumpUniformsResult` 标 `error="bridge_error_exit_N"`。
5. **bindings 字段在 CLI payload 中的形态**：`FrameDrawBindings` dataclass 通过手写 `_bg()` 转成 dict（保留 `inline_bytes_size` 仅在 inline 形态出现，其余字段过滤 `None`），与 frame-list 子命令的 JSON 输出形态一致——让消费方对 `shader-of-drawcall --with-bindings` 输出可与同一 trace 的 `frame-list` 输出做字面比较（T7s-2 断言覆盖）。

**端到端验证（LYSK）**：

| 案例 | 期望 | 实测 |
|------|------|------|
| `shader-of-drawcall 0 --stage fragment --with-ir --with-uniforms` | rps_key=472；shader.ir_ll_path 存在；bindings.fragment.buffers ≥ 1；uniforms[slot=0] = `AsukaPerShader_PerCamera` 9 字段全有值 | rps_key=472；ir_ll_path 存在（SDI fallback）；bindings.fragment.buffers=4 / textures=16；uniforms 4 slot 全 decoded；`uniforms_summary={slot_count:4, slot_ok:4, slot_failed:0, errors:[]}` ✅ |
| `shader-of-drawcall 10 --stage vertex --with-ir --with-uniforms` | uniforms[slot=0] = `AsukaPerShader_ShadowParams._ShadowBias=(0.007,...)` 与 R7.6-B 字节级一致 | slot 0 binding_name=`AsukaPerShader_ShadowParams`，`_ShadowBias=(0.007,-0.000292,0,0)` 字节级一致 ✅ |

**版本与测试**：bridge 二进制零变更（仍 0.7.0）；wrapper 模块版本 patch +1；集成测试 136 → **148/148**（新增 T7s 系列 12 项断言：默认行为兼容 / `--with-bindings` 字段形态 / `--with-uniforms` 隐含 `--with-bindings` / `uniforms[]` 长度 = `bindings.<stage>.buffers` / per-slot 字节级与单调 `dump-uniforms` 一致 / vertex stage 独立 / 模块 API 契约）；compute-only trace 79/93 与基线一致（`[SKIP] draw_count=0` 自动守卫）。

**改动量**：仅 `Scripts/gputrace_replay_wrapper.py`（+ helper / dataclass 字段 / CLI flag）+ `Scripts/test_gputrace_replay_bridge.sh`（T7s 系列）+ `.codebuddy/skills/gpu-trace-analysis/` 同步副本与 SKILL/cli-reference/playbook 文档。

**不变量**：默认（无 flag）调用产物与 R7.6-C 完全相同（T7s-1）；`--with-bindings` 不改变 `shader_of_rps` 嵌入字段（同 RPS metallib/AIR/cacheKey 字节级一致；T7q-3 chain 兼容性测试覆盖）；各 stage 独立（`--stage vertex` 取 `bindings.vertex.buffers`，fragment 同理）；compute-only trace 上 OOR 行为不变（exit 12 + `draw_index_out_of_range`）。

**已知局限**：
- inline-bytes 形态 buffer slot（`setVertexBytes:length:atIndex:`）没有 `resource_id`；当前 R7.6-D 仍调 `dump-uniforms`（`buffer_key=None` 不传 `--buffer-key`），bridge 仅返回 layout，`decoded` 缺失（`error` 字段会有结构化标记如 `binding_not_a_buffer`）。LYSK 实测 inline_count=0，未触发；改进留给后续 chunk。
- `uniforms[]` 不包含 sampler / texture 反射；仅 buffer 类绑定走解码（与 `dump-uniforms` 子命令设计边界一致）。
- 同一 draw 多个 slot 解码不会互相覆盖文件（bridge 内部用 rps_key+slot 命名）；跨多次调用复用同一 `--output-dir` 需注意。
- 性能：LYSK draw 0 三件套 ≈ 1.9s（一次 frame-list ~1.6s + 一次 shader-of-rps ~0.2s + 4 次 dump-uniforms ~50ms 各）。批量循环建议用 `frame-list` 一次性 + per-draw `dump-uniforms` 直调（playbook 决策表已注明）。

---

### R7.6 子项 E：`find-draws` 按 label / shader 名反查 draw 列表 — **P0（R7.5 之前）**

> **优先级判断（2026-05-21 三次评估）**：原本 R7.6-D 落地后 R7.5 应直接接棒 P0。但回看用户实战目录 `LocalDocs/OfflineSourceRecovery/scripts/locate_shader.py` —— 用户在 LYSK 皮肤渲染调查中**绕过**了我们的 `shader-of-drawcall <draw_index>` 链路，自己写脚本扫 device-resources blob 来定位 shader。根本原因不是工具能力不足（R7.6-D 三件套已经能产出他要的全部数据），而是**入口阻抗**：用户在 Xcode GUI 看到 "shader 名 SkinMakeupNew / RPS at 0x7b...."，但我们的 CLI 入口要 `draw_index` 整数；用户**没有现成办法**从 GUI 视图实体跳到我们的 CLI 入口参数。这是"工具有但用户不会用"的可发现性问题。**0.3 天的纯 wrapper 收尾（bridge 零变更）**就能消除这个鸿沟，让 R7.6-A/B/C/D/R7.7 全栈能力对真实工作流可达；R7.5（depth/stencil + dispatch）是横向硬能力，落在 R7.6-E 之后承接更顺。

**交付**：wrapper-only 路径，bridge 二进制零变更。

- 新子命令 `find-draws <trace> [--by-label SUBSTR] [--by-shader-name SUBSTR] [--by-rps-key K] [--with-bindings] [--limit N] [--json]`
  - 模糊匹配（默认大小写不敏感子串），返回 `[{draw_index, encoder_index, draw_in_encoder, rps_key, rps_label, vertex_function_name, fragment_function_name}, ...]`
  - 单次 frame-list 调用承载所有过滤逻辑（不再多花子进程钱）
  - `--by-shader-name` 同时匹配 vertex/fragment function name；`--by-label` 仅匹配 `rps_label`
- wrapper API：`bridge.find_draws(trace, by_label=..., by_shader_name=..., by_rps_key=..., limit=20)` 返回 `list[FindDrawsHit]`
- 顶层 CLI 还提供 `--show-first` flag，等价于"找到第一条命中后直接联动 `shader-of-drawcall <draw_index> --with-uniforms`"——把 GUI → CLI 的"两步"压缩为一步

**核心设计决策**：
1. **不引入新 swizzle**：R7.6-A / R7.2 已经把 `rps_label` / vertex_function_name / fragment_function_name 注入到 frame-list 输出，find-draws 是纯 JSON 后处理，bridge 行为完全不变。
2. **wrapper-only**：与 R7.6-C / R7.6-D 同款收尾风格——保留"bridge 是数据源、wrapper 是工作流胶水"边界。
3. **不做 RPS_ptr → RPS_key 反向查找**：用户 GUI 看到的 RPS 指针（如 `0x7b137e000`）是**游戏运行时进程**的指针，与 replay 进程内 PSO 重新创建后的指针**不同地址空间**——这条桥铺不通（replay 框架已隔离）。可达的桥是 **shader 名 / RPS label**，全在 `frame-list` JSON 内。
4. **不抢占 R7.5 工时**：估 0.3 天（wrapper ~80 行 + 测试 ~60 行 + skill 文档同步 ~30 行）；落地后 R7.5 立即升回 P0。

**端到端目标用例（LYSK）**：
```bash
# 用户 GUI 看到 "draw 用 SkinMakeupNew shader"，想拿 IR + bindings + uniforms
$ python3 gputrace_replay_wrapper.py find-draws "$LYSK" --by-label SkinMakeupNew
[
  {"draw_index": 87,  "rps_key": 476, "rps_label": "Papegame/SkinMakeupNew", ...},
  {"draw_index": 142, "rps_key": 484, "rps_label": "Papegame/SkinMakeupNew", ...},
  ...
]

# 或一步到位：
$ python3 gputrace_replay_wrapper.py find-draws "$LYSK" --by-label SkinMakeupNew --show-first \
    -- --with-ir --with-uniforms
# → 等价于 find-draws + 用第一条命中的 draw_index 跑 shader-of-drawcall 三件套
```

**测试断言（计划，T7t 系列 ~6 项）**：
- `find-draws --by-label <RPS 不变量子串>` 命中数 = 已知该 label 的 draw 总数（LYSK 比如 SkinMakeupNew 4 个 RPS variant 命中所有相关 draw）
- `find-draws --by-shader-name <vertex fn 名>` 与 `--by-label` 在某 RPS 上交集非空
- `--limit` 截断生效
- `--show-first` 联动 `shader-of-drawcall` 输出与单独跑 `shader-of-drawcall <draw_index>` 字节级一致
- compute-only trace 上 `find-draws` exit=0 + 命中数=0 + 无报错（无 render encoder 自动空集）
- `--by-rps-key` 显式 RPS_key 查询返回该 RPS 的所有 draw

**已知局限 / 边界**：
- 不解决"GUI RPS 指针 0x... → replay RPS_key"反查（地址空间不同，技术不可达）；用户必须从 GUI 拿 shader 名 / label 字符串
- compute encoder 的 dispatch 不在 find-draws 输出内（合 R7.5-B 之后再加 `find-dispatches`，独立子项）
- 不做正则匹配，仅子串（YAGNI；如需要后补 `--regex` flag）

---

### R7.5：depth/stencil export + compute dispatch 计数补齐 — **P1（R8 Sprint α 之后）**

> **优先级演进**：多次让位 — 先 R7.7 → R7.6-A → R7.6-B → R7.6-D → R7.6-E → **R8 Sprint α**。每次都因为"对最终目标提升 > R7.5 横向硬能力 + 工时显著更小"。R8 Sprint α 落地后 R7.5 重新成为 P0。子项 A ≈ 1 天 + 子项 B ≈ 0.5 天，合计 1–1.5 天。

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

### R7.6 子项 B — `dump-uniforms <draw_index|rps_key> <bind_slot>` — ✅ 已完成（2026-05-21）

**交付**：bridge 第 9 子命令 `dump-uniforms` + wrapper `dump_uniforms()`。把 R7.6-A 已交付的 `bindings.{vertex|fragment}.buffers[bind_slot].{resource_id, offset}` 延伸到"buffer 字节按 cbuffer 布局解码成 JSON"。`shader-of-drawcall N` 系列已能给出 **shader IR + bindings + uniforms 三件套**——绝大多数渲染 bug（UV 错、矩阵错、光源错、材质参数错）的最终调查终点。

#### 5.6.1 反射来源（核心设计决策）

复用 R7.2 swizzle 拦截 `MTLDevice -newRenderPipelineStateWithDescriptor:[options:reflection:]error:`；R7.2 时给 reflection 出参传 `NULL`，本次改为接住并强引用到 file-scope `static id g_rps_reflections[]`：

| Selector | thunk | 反射来源 |
|----------|-------|---------|
| `WithDescriptor:options:reflection:error:` | `rps_swizzled_imp_opts` | 直接从 `*refl` 接（caller 传 NULL 时用 `__autoreleasing` 局部出参占位） |
| `WithDescriptor:error:` | `rps_swizzled_imp` | 原 selector 不带 reflection — thunk 内**额外发起一次** options 版本调用（带 `MTLPipelineOptionBindingInfo \| BufferTypeInfo`），让 OS PSO 缓存命中后直接拿到 reflection。多一次调用代价由 PSO 缓存吸收（同 descriptor → 命中），实测 LYSK replay 总耗时影响 < 5%。 |

**ARC 与 C 结构体冲突的解法**：ARC 不允许在 C struct 里放裸 `id` 字段。方案 = 平行数组：

```objc
typedef struct { /* ... */ int reflection_index; /* -1 if capture failed */ } RPSCaptureEntry;
static RPSCaptureEntry g_rps_captured[MAX_CAPTURED_RPS];
static id              g_rps_reflections[MAX_CAPTURED_RPS]; // file-scope __strong
```

#### 5.6.2 字节解码：递归走 `MTLStructType`

```
MTLStructType.members[]
  ├─ MTLStructMember.dataType = MTLDataTypeStruct → 递归 (depth ≤ 8)
  ├─ MTLStructMember.dataType = MTLDataTypeArray  → arrayType.{length, stride, elementType} 迭代 (cap 16 elem)
  └─ leaf (float/halfNxM/intN/uintN/bool/...)     → du_emit_leaf_value
```

每字段 emit `{"offset": N, "data_type": "...", "value": <decoded>}`：
- 标量 → JSON 数字；向量 → 一维数组；矩阵 → 二维数组（按 column-major 存储顺序读、呈 row-major 形态）；struct → 递归对象；array → `{length, stride, element_type, elements, truncated, truncated_at}`
- NaN/±Inf → 字符串哨兵 `"NaN" / "Infinity" / "-Infinity"` 保证 JSON 可解析
- 递归深度 cap 8（`DU_MAX_DECODE_DEPTH`）、数组 cap 16（`DU_MAX_ARRAY_ELEMS`）

#### 5.6.3 三种入口

| 入口 | 形式 | 适用场景 |
|------|------|---------|
| `bridge dump-uniforms <trace> <rps> <slot>` | layout-only | "shader 期望什么 cbuffer？"静态查询 |
| `bridge dump-uniforms <trace> <rps> <slot> --buffer-key K --offset N` | layout + decoded | 已知 RPS + buffer 地址（批量回归） |
| `wrapper.dump_uniforms(trace, draw_index, slot)` | draw 模式自动化 | "draw N 在 slot S 看到的 cbuffer 实际值" — 99% 调试场景 |

wrapper draw mode 内部串 `frame_list(--with-bindings) → draw_to_rps_map[N] + bindings → bridge dump-uniforms`，与 R7.6-C `shader-of-drawcall` 同款 wrapper-only 风格。

#### 5.6.4 LYSK 主基线实测

- 65/65 RPS 全部捕获 reflection（reflection_captured ratio = 65/65，无 `reflection_not_captured`）
- draw 0 fragment slot 0：`AsukaPerShader_PerCamera` 9 字段（`hlslcc_mtx4x4_WorldToLight[4]` / `_MainLightPosition` / `_MainLightColor` / `_ScaledScreenParams` / `_GridInfo` / `_AuroraGridInfo` / `_MainLightRealtime` / `_DOFEnable` / `_GlobalMipBias`）字段名/offset/dataType 与 LYSK shader 源码（`Papegame/Cloth/ClothStandard` 主 pass fragment cbuffer）完全一致
- draw 10 vertex slot 0：`AsukaPerShader_ShadowParams` 2 字段：`_ShadowBias=(0.007, -0.000292, 0, 0)` ≈ kHairCharShadowBias、`_ShadowLightDirection ≈ (0.292, 0.274, 0.916)` 单位向量；hex dump `0x42 0x60 0xe5 0x3b` little-endian float ≈ 0.00699997 与 `_ShadowBias.x = 0.007` 字节级一致 ✅

#### 5.6.5 错误模型（与 R7.4/R7.6-C/R7.7 同款"软错误结构化"）

| 错误 | exit | 触发 |
|------|------|------|
| `rps_not_found` | 11 | `objectMap.renderPipelineStateForKey:` nil |
| `descriptor_not_captured` | 11 | swizzle 未触发该 RPS（极罕见） |
| `reflection_not_captured` | 11 | RPS 已捕获但 reflection 出参为 nil（设备拒绝 BindingInfo+BufferTypeInfo 选项；可 `--with-hex --buffer-key K` 退到 hex） |
| `bind_slot_not_in_reflection` | 11 | shader 不在该 slot 绑 buffer |
| `binding_not_a_buffer` | 11 | slot 是 texture/sampler/threadgroup |
| `buffer_not_found` / `buffer_contents_unavailable` / `offset_out_of_range` | 11 | buffer 端各类异常（GPU-private 存储 等） |
| `draw_index_out_of_range` | 12 | wrapper 端 draw mode + `draw_index ≥ draw_count`（与 R7.6-C 一致） |

所有 11 路径 stdout 仍输出完整 JSON（含 `error` / `hint`）。

#### 5.6.6 测试矩阵（T7r 系列 6 组 20 断言）

| ID | 断言 | LYSK |
|----|------|------|
| T7r-1 | bridge layout-only `exit=0` + `layout` + `layout_source=metallib_reflection` + `binding_name` + 无 `decoded` | ✅ 5/5 |
| T7r-2 | bridge with buffer `exit=0` + `decoded` + `decoded_ok=true` | ✅ 3/3 |
| T7r-3 | wrapper draw mode `exit=0` + 自动注入 `draw_index=0` + `rps_key` 等于 frame-list 推算值 + `decoded` 自动产出 | ✅ 4/4 |
| T7r-4 | bridge `bind_slot` OOR `exit=11` + `error="bind_slot_not_in_reflection"` | ✅ 2/2 |
| T7r-5 | bridge rps OOR `exit=11` + `error="rps_not_found"` | ✅ 2/2 |
| T7r-6 | wrapper draw OOR `exit=12` + `error="draw_index_out_of_range"` | ✅ 2/2 |

#### 5.6.7 版本与测试基线

bridge 0.6.0 → **0.7.0**；集成测试 116 → **136/136**（LYSK 主基线，含 T7r 6 组 20 断言）；compute-only `reference_test_inject` trace 上 T7r 因 `draw_count=0` 自动 SKIP，79/93 不变（14 个 R7.3 已知盲点不变）。

#### 5.6.8 改动量速览

| 文件 | 改动 |
|------|------|
| `Scripts/gputrace_replay_bridge.m` | +`#import <math.h>`；`RPSCaptureEntry +reflection_index`；新增 `static id g_rps_reflections[]`；两条 swizzle thunk 注入 reflection 强引用；新增 `cmd_dump_uniforms` + 一组 `du_*` 解码 helper（`du_data_type_name` / `du_emit_scalar_value` / `du_emit_struct` / `du_emit_hex` / `du_find_binding` / `du_buffer_for_key` / `du_half_to_double` 等）；version `0.6.0 → 0.7.0` (~+600 行) |
| `Scripts/gputrace_replay_wrapper.py` | 新增 dataclass `DumpUniformsResult`；新增 `ReplayBridge.dump_uniforms()`（draw / rps 两种模式 + 自动 frame-list 解析）；CLI subparser `dump-uniforms` (~+230 行) |
| `Scripts/test_gputrace_replay_bridge.sh` | T2/T4 命令循环加 `dump-uniforms`；新增 T7r 系列 6 组 20 断言 (~+110 行) |
| `.codebuddy/skills/gpu-trace-analysis/` | scripts/源码 + bridge binary + SKILL.md（capability 7 → 8）+ cli-reference.md（subcommand 9）+ investigation-playbook.md（"What did the cbuffer at draw N actually contain?" 段） 全镜像同步 |

#### 5.6.9 已知局限（移交 R7.5）

1. **Argument buffer 二级 indirect resources**：`bufferStructType` 描述 argument buffer 布局，但内部 GPU resource 句柄需要 `MTLArgumentEncoder.argumentBuffer` 二次查找。当前直接打印 64-bit handles；后续如需要 v2 展开（≤ 0.5 天）。
2. **`setVertexBytes` inline buffers**：R7.6-A 仅记 `inline_bytes_size`，R7.6-B 因此对 inline-only 绑定无 decoded（layout 仍可用）。如需要可在 R7.6-A swizzle 加 `--with-inline-bytes` flag。
3. **无 reflection 的 PSO**：极罕见（M-series 均通过）；如设备拒绝 `BindingInfo|BufferTypeInfo` 选项 → entry `reflection_index = -1` → `dump-uniforms` 返回 `reflection_not_captured`。`--with-hex --buffer-key K --offset N` 仍可拿到 hex。
4. **Compute encoder cbuffer**：R7.6-B 仅覆盖 render PSO；compute 反射（`MTLComputePipelineReflection`）未接，留 R7.5-B 顺手。
5. **超大 cbuffer 数组**：解码 cap 在 16 元素 / 8 层嵌套。超出标 `truncated:true,truncated_at:16` 与递归深度静默截断（leaf 输出 `null`），保证 JSON 体积可控。

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
| Uniform Inspector | `dump-uniforms` | ✅ R7.6-B |
| Depth/Stencil 可视化 | `--export` 内置 blit | ⏳ R7.5-A |
| Per-encoder GPU timing | `frame-list --with-timing` | ⚠️ R7.3 部分（replay-internal cb 不 commit） |
| Compute encoder 在 frame-list 中明确化 | `frame-list` 含 type=compute | ✅ R7.3（dispatch 计数留 R7.5-B） |
| RPS → shader 反查 | `pipeline` 输出 function/library key | ✅ R7.2 |
| RPS_key → shader IR 一行命令 | `shader-of-rps --with-ir` | ✅ R7.4 + R7.7 |
| Draw call → RPS_key 反查 | `frame-list draw_to_rps_map` | ✅ R7.3 |
| Draw call → shader IR 一行命令 | `shader-of-drawcall <draw_index>` | ✅ R7.6-C + R7.7 |
| Draw call → bindings 表 | `frame-list --with-bindings` 内建 | ✅ R7.6-A |
| Shader 反编译（覆盖无 AIR 的 library） | `disasm <library_key>` SDI module.bc 路径 | ✅ R7.7（LYSK 96/96） |
| **Draw call → "shader IR + bindings + uniforms" 三件套一行命令** | `shader-of-drawcall <draw_index> --with-ir --with-uniforms` | ✅ R7.6-D（wrapper 联动） |
| **GUI shader 名 / RPS label → draw_index 反查** | `find-draws --by-label / --by-shader-name`（消除 GUI↔CLI 入口阻抗） | ⏳ R7.6-E |
| **Per-draw binding 表自动注入 IR `arg_name` / `size_check` / value health** | `frame-list` / `shader-of-drawcall` schema + wrapper `draw-info` | ⏳ R8.1+R8.2（详见 `20260522-R8-skill-usability-backlog.md`） |
| **按 IR `arg_name` 反查 cbuffer 字段（绕过 bind_slot）** | `dump-uniforms --by-name <BINDING_NAME> --field <FIELD>` | ⏳ R8.3 |

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

R7.1~R7.7 + R7.6-A/B/C 落地时均已同步过这三处。R7.5 落地时按相同惯例。

---

## 10. 一句话总结

draw call → shader IR + bindings + uniforms 的端到端链在 macOS Metal replay 框架下技术可达且 R7.1~R7.7 + R7.6-A/B/C/D 全部走通。**R7.6-D（2026-05-21 落地，纯 wrapper 胶水，bridge 零变更）把"draw → 三件套"承诺真正落实到一行命令**：`shader_of_drawcall(draw_index, with_uniforms=True)` 一次调用产出 IR + bindings + 每个 buffer slot 的 cbuffer 字段树。LYSK 主基线集成测试 **148/148**，compute-only `reference_test_inject` 79/93。剩余主线工作（R7.6-E / R8 Sprint α / R7.5）的状态以主 dashboard `README.md` 为准。
