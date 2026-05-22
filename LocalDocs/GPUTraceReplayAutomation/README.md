## 最终目标

**使 CLI 模式下的 GPU 截帧 replay 在功能上尽可能等价于 Xcode GUI 窗口内的 replay 以及分析调试等操作。**

等价性定义 — Xcode GUI replay 窗口内能做的事，CLI 下均应能以编程方式完成：

| 能力维度 | CLI 等价目标 | 状态 |
|----------|-------------|------|
| Replay 执行 | headless 重放任意 .gputrace | ✅ |
| 帧/draw call 导航 | `playTo(controller, targetCallIndex)` | ✅ |
| 纹理/Buffer 查看 | ObjectMap → getBytes/contents 导出 | ✅ |
| Pipeline 查看 | libraryDataContents/bitcodeData 导出 | ✅ |
| Shader 热替换 | setLibrary:forKey: + rewind+playAll | ✅ |
| Shader Debug | instrumented debug 替代方案 | ⚠️ 部分 |
| Configuration 修改 | 调用链控制 + 全局变量 | ✅ |
| 输出自动化 | bridge JSON/bin 导出 | ✅ |
| **Encoder/Pass/Draw 时间序枚举** | `frame-list` 子命令 | ✅ R7.3 |
| **RPS↔shader 关联** | `pipeline` 输出 vertex/fragment function/lib key + attachment | ✅ R7.2 |
| **RPS → shader IR 反查** | `shader-of-rps` 子命令（含 `--with-ir`） | ✅ R7.4 |
| **Draw call → RPS_key 反查** | `frame-list` 输出 `draw_to_rps_map[]` | ✅ R7.3 |
| **Draw call → shader IR 反查** | `shader-of-drawcall` 子命令（薄封装：frame-list → shader-of-rps） | ✅ R7.6-C |
| **Per-draw vertex/fragment binding 表** | `frame-list --with-bindings`（默认 ON） | ✅ R7.6-A |
| **Draw call → "IR + bindings + uniforms" 三件套一行命令** | `shader-of-drawcall --with-uniforms`（wrapper 联动） | ✅ R7.6-D |
| **GUI shader 名 / RPS label → draw_index 反查** | `find-draws --by-label / --by-shader-name` | ✅ R7.6-E |
| **Per-draw binding 表自动注入 IR `arg_name` / `size_check`** | `draw-info` 子命令 + `_enrich_stage_bindings()` | ✅ R8.1 |
| **NaN/inf/denormal + binding size 不匹配自动告警** | `value_health_summary` + `size_check` | ✅ R8.2 |
| **按 IR `arg_name` 反查 cbuffer 字段（不经 bind_slot）** | `dump-uniforms --by-name` | ✅ R8.3 |
| **Depth/Stencil 可视化** | bridge 内置 blit + export | ⏳ R7.5 |
| **Uniform / cbuffer 内容查看** | `dump-uniforms` 子命令 | ✅ R7.6-B |
| **Shader 反编译（IR 直接产出）** | `disasm` 子命令集成 cacheKey + llvm-dis | ✅ R7.7 |
| GPU Counters / Profiler / Derived | 需 Apple 私有 entitlement + SIP 关闭 | ⛔ 跳过 |

**完成度**：R0~R6 已完成（基础能力 + bridge + Python wrapper + skill 打包）；R7.1 / R7.2 / R7.3 / R7.4 / R7.6-A / R7.6-B / R7.6-C / R7.6-D / R7.6-E / R7.7 已完成（bridge 9 子命令 + wrapper 12 子命令 / 集成测试 LYSK 主基线 **148/148**）；**R8 Sprint α 全部完成**（R8.1 draw-info + R8.2 value_health_summary + R8.3 --by-name，agent 多数据源 join 错误结构性消除）；**R7.5 是当前 P0**（depth/stencil blit export + compute dispatch 计数，1–1.5 天）作为独立横向硬能力收尾。skill 文档已于 2026-05-22 同步 `find-draws` 为推荐入口。

最终交付物：
1. **统一 ObjC bridge CLI**（`Scripts/gputrace_replay_bridge.m`）— ✅ 9 子命令（help / replay / pipeline / shader / config / frame-list / shader-of-rps / disasm / dump-uniforms），Makefile 构建，LYSK 集成测试 148/148
2. **Python CLI wrapper**（`Scripts/gputrace_replay_wrapper.py`）— ✅ CLI + 模块双接口，dataclass 返回值（含 `FrameDrawBindings` / `DisasmResult` + `ir_source` / `ShaderOfDrawcallResult` + `bindings` / `uniforms` / `DumpUniformsResult` / `FindDrawsResult` / `DrawInfoResult` 等）
3. **端到端验证链路** — ✅ LYSK 65/65 RPS 反查 + 244/244 draw→RPS 映射 + 244/244 draw vertex/fragment binding 表 + 65/65 RPS reflection 捕获 + AIR ∪ SDI = 96/96 IR 命中率 100% + draw N 上 cbuffer 字段名/offset/dataType 与 shader 源码字节级一致 + **draw N → IR + bindings + uniforms 三件套一行命令 (R7.6-D)** + **draw N → merged binding view with auto-injected IR arg_name (R8.1)**
4. **GPU Trace 分析 skill**（`.codebuddy/skills/gpu-trace-analysis/`）— ✅ 自包含，含 SKILL.md + scripts/ + references/，从任意目录可独立运行
5. **R7：Frame-Inspection 能力补全** — ✅ 主线全部收尾（R7.1/R7.2/R7.3/R7.4/R7.6-A/B/C/D/E/R7.7 全部完成）；剩余工作 R8 Sprint α + R7.5 见下文"下一步"与 TODO 段。详见 `subdocs/20260521-R7-frame-inspection-gap.md` + `subdocs/20260522-R8-skill-usability-backlog.md`
6. **R8 Sprint α：agent 多数据源 join 错误结构性消除** — ✅ R8.1（`draw-info` + AIR metadata 自动注入 + `size_check`）+ R8.2（`value_health_summary` NaN/inf/denormal 告警）+ R8.3（`dump-uniforms --by-name` 按名反查）。详见 `subdocs/20260522-R8-skill-usability-backlog.md`

## 样本 trace 路径（回归基线）

| 样本 | 路径 | 形态 | 用途 |
|------|------|------|------|
| **LYSK**（主基线） | `/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace` | 4 cb / 62 enc / 244 draws / 65 RPS / 96 lib / 3425 calls / **244 draws × ~280 bytes binding snapshot** | R7.2/R7.3/R7.4/R7.6-A/R7.6-C 主回归（端到端 IR 链 + bindings） |
| reference_test_inject | `~/Desktop/reference_test_inject.gputrace` | 2 cb / 2 enc / 0 draws / 0 RPS / 3 compute PSO / 27 calls | R7.6-C compute-only 回归（OOR / `draw_count=0` / `rps_not_found` / R7.6-A 自动跳过 draw 类断言） |
| reference_144316 | `~/Desktop/reference_144316.gputrace` | compute-only (与 inject 同形态) | 备用 compute-only 样本 |

设置 `GPUTRACE_PATH` 即可让 `Scripts/test_gputrace_replay_bridge.sh` 跑 live-trace 断言：

```bash
GPUTRACE_PATH="/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace" \
    bash Scripts/test_gputrace_replay_bridge.sh
# → 148 passed, 0 failed, 148 total

GPUTRACE_PATH="$HOME/Desktop/reference_test_inject.gputrace" \
    bash Scripts/test_gputrace_replay_bridge.sh
# → 79 passed, 14 failed, 93 total（14 failed 属 R7.3 trace-shape 假设盲点，由 R7.5-B 修复 — 见 R7 子文档 §5 R7.5 段；R7.6-A/C/D / R7.7 自身断言全自动 SKIP 通过）
```

## 全局约束

- 只做与**当前最高优先级**任务直接相关的工作；禁止顺手推进次级任务。
- 不得把用户现有未提交改动纳入 commit；提交仅包含本任务新增或必要修改文件。
- 优先使用**只读、低侵入**方法：静态扫描 > 动态观察 > 最小调用验证 > attach / 注入 / 替换。
- 未经用户确认，不做会明显干扰当前 Xcode replay 或系统稳定性的动作。
- 新增 bridge 或脚本必须优先满足：**headless、可重复执行、失败可诊断、输出 JSON**。
- 主文档保持简洁；详细发现写入子文档。

## 主线任务

### 已建立的核心知识

R7 各 chunk 的实现细节、设计决策、回归基线一律落在 R7 子文档 §5；本段只列对后续工作仍有重用价值的"一句话要点"。

- **主线模块链**：`GPUDebugger.ideplugin` → `GPUToolsServices`(76 类) → XPC Services → `GPUToolsReplay.framework`(C API)
- **主力路径 — Controller 路径**（R4.2）：`makeDataSource → makeController → playAll/playTo` — 完整 replay + 对象访问 + 定向 replay，无 XPC/entitlement 依赖。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
- **Pipeline Binary 导出**：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 偶数=Library，奇数=Function，规则：`library_key = function_key - 1`
- **Shader 热替换**：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Configuration**：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **Call-index 边界**（R7.1）：`*(uint32_t *)(controller + 0x5810)` = last played call index；`playAll` 完成后 = trace 总 call 数。OOR 结构化错误（exit 12）+ SIGSEGV 兜底已合入 bridge。系统升级后偏移可能变化 → 回归脚本 `Scripts/call_count_probe.m`
- **Swizzle-first 框架**（R7.2/R7.3/R7.6-A）：所有 swizzle 必须在 `replay_context_init` 之前安装；render encoder 类延迟到首次实例化时安装；capture gate 仅在 `playAll` 期间打开。涵盖 RPS 创建、commandQueue/commandBuffer/encoder 创建、setRenderPipelineState/drawXXX/endEncoding、12 个 set\* binding 方法。健康度指标：`rps_correlated_count` / `rps_captured_count` 应 = `render_pipeline_states_count`
- **draw → IR + bindings + uniforms 三件套**（R7.6-D）：`shader_of_drawcall(draw_index, with_uniforms=True)` 一行命令产出三件套，内部链路 = R7.3 frame-list（含 R7.6-A bindings）→ R7.6-B dump-uniforms（per buffer slot）→ R7.4 + R7.7 IR 路径（AIR + SDI module.bc fallback，LYSK 96/96 命中率 100%）
- **统一 Bridge + Python wrapper + skill 打包**（R6.1 + R6.2）：`Scripts/gputrace_replay_bridge.m` 9 子命令 + `Scripts/gputrace_replay_wrapper.py` 10 子命令 + `.codebuddy/skills/gpu-trace-analysis/`。详见 `subdocs/20260520-R6.1-bridge-implementation.md` + `subdocs/20260521-R6.2-wrapper-and-skill.md`

### 当前卡点

无。R8 Sprint α 全部落地（2026-05-22），R8.1 + R8.2 + R8.3 三项合计结构性消除了 §1.1~§1.4 复盘出的 ~80% agent 错误。下一步 R7.5（depth/stencil + compute dispatch）为独立横向硬能力收尾。

### 下一步（当前最高优先级）

**R7.5（depth/stencil export + compute dispatch 计数补齐，1–1.5 天）**

- 子项 A：bridge 内部跑一次最小 RPS / blit pass，把 depth 复制到临时 R32Float、stencil 复制到 R8Unorm，再 `getBytes` 落盘（Apple sample code 标准做法，无需私有 API）
- 子项 B：把 `MTLComputeCommandEncoder.setComputePipelineState:` / `dispatchThreadgroups:*` / `dispatchThreads:*` 接入 R7.3 的 swizzle 集合，记录 dispatch 计数 + compute pipeline pointer；顺手处理 R7.6-C 暴露的 R7.3 trace-shape 假设盲点（compute-only trace 上 14 个健康路径断言失败 — 改为"draw 类断言仅在有 render encoder 时启用"）

主要服务 ShadowMap / SSS / stencil bit 类问题（与用户当前 SSS 实战直接相关）；同时让 compute-heavy trace 的 dispatch 信息真正可见。详见 R7 子文档 §5（R7.5 段）。

## 构建与验证的方法

- **构建**：`cd Scripts/ && make`（编译 + ad-hoc 签名）；`make test`（集成测试 25 项离线 + 123 项需 GPUTRACE_PATH 的 LYSK live trace 断言，合计 148）；`make clean`
- **验证分级**：V1 静态扫描 → V2 动态观察 → V3 bridge 干跑 → V4 最小样本测试
- **平时原则**：优先利用当前正在 replay 的 Xcode 做动态观察；无活动 replay 时退回静态/离线样本
- **须用户确认**：写 workspace 外目录 / attach / 注入 / 提权 / 修改系统文件 / 需要 UI 手操

## agent的工作流程介绍
1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。手头所有工作都搁置，不要进行收尾、git commit。等待用户指示
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的executions文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

- **[DONE] R0~R5**：基线扫描 → API 提取 → bridge 原型 → headless replay → 数据获取 → 操作等价
- **[DONE] R6**：客户端封装与可用性收尾
  - **[DONE] R6.1**：统一 ObjC bridge binary — 5 子命令 + Makefile + 集成测试 17/17
  - **[DONE] R6.2a**：端到端动态验证（2 样本 × 5 子命令，29/29 集成测试通过）
  - **[DONE] R6.2b**：Python CLI wrapper（CLI + 模块双接口，dataclass 返回值）
  - **[DONE] R6.2c**：skill 打包（`.codebuddy/skills/gpu-trace-analysis/`，自包含 + 17/17 通过）
- **[CANCELLED] R6.3**：自动化流水线集成（CI/CD + 样本库管理）— 不做
- **[IN-PROGRESS][P0] R7**：Frame-Inspection 能力补全（详细交付摘要、关键技术决策、回归基线一律见 `subdocs/20260521-R7-frame-inspection-gap.md` §5）
  - **[DONE] R7.1**：bridge 越界保护 + 资源元数据补齐（call-index 边界 / `--bounds` / OOR exit 12 / SIGSEGV 兜底）
  - **[DONE] R7.2**：`pipeline` 输出加 RPS↔shader 关联（bridge 内置 swizzle，LYSK 65/65 通过）
  - **[DONE] R7.3**：`frame-list` 子命令 swizzle-first 路径（encoder 列表 + draw→RPS 映射，LYSK 244/244 → 65/65）
  - **[DONE] R7.4**：`shader-of-rps` 子命令（语义级反查 + `--with-ir` llvm-dis）
  - **[DONE] R7.6 子项 C**（2026-05-21）：`shader-of-drawcall` 薄封装（wrapper-only：frame-list → draw_to_rps_map → shader-of-rps）
  - **[DONE] R7.7**（2026-05-21）：`disasm` 子命令 + SDI module.bc fallback（IR 命中率 LYSK 96/96 = 100%）
  - **[DONE] R7.6 子项 A**（2026-05-21）：`frame-list --with-bindings`（默认 ON，12 个 binding swizzle，LYSK 244/244 全捕获）
  - **[DONE] R7.6 子项 B**（2026-05-21）：`dump-uniforms <draw_index|rps_key> <bind_slot>`（reflection 解码，LYSK 65/65 RPS 全捕获）
  - **[DONE] R7.6 子项 D**（2026-05-21）：`shader-of-drawcall --with-uniforms` 三件套合一（wrapper 联动，bridge 零变更）
  - **[DONE] R7.6 子项 E**（2026-05-22）：`find-draws` 按 label / shader 名 / rps_key 反查 draw 列表 — wrapper-only，bridge 零变更。消除 GUI 看到 shader 名 ↔ CLI 要 draw_index 的入口阻抗；`--show-first` 一步联动 `shader-of-drawcall --with-ir --with-uniforms`。LYSK 验证通过（by-label SkinMakeupNew 14 命中 / by-rps-key 476 8 命中 / by-shader-name xlatMtl 242 命中 / compute-only 0 命中无报错）
  - **[P1] R7.5（R8 Sprint α 后接棒 P0）**：depth/stencil export（bridge 内置 blit）+ compute encoder dispatch 计数补齐 — 1–1.5 天合计。独立横向能力，无前置依赖；主要服务 ShadowMap / SSS / stencil bit 类问题；同时顺手处理 R7.3 在 compute-only trace 上的 trace-shape 假设盲点（14 个健康路径断言失败）
- **[DONE] R8 Sprint α**（2026-05-22）：agent 多数据源 join 错误的结构性消除。详见 `subdocs/20260522-R8-skill-usability-backlog.md`
  - **[DONE] R8.1**（2026-05-22）：per-draw merged binding view — `draw-info <trace> <draw_index>` 子命令（wrapper-only），AIR metadata parser + `_enrich_stage_bindings()` + library_key 缓存。LYSK draw 69 验证通过
  - **[DONE] R8.2**（2026-05-22）：`value_health_summary`（NaN/inf/denormal 计数 + 字段定位），注入 dump-uniforms / shader-of-drawcall --with-uniforms / draw-info --with-uniforms
  - **[DONE] R8.3**（2026-05-22）：`dump-uniforms --by-name <BINDING_NAME> [--field <FIELD>]`，按 IR arg_name 直接查值，绕过 bind_slot 心算
- **[BACKLOG][P2] R8 Sprint β**：`dump-diff` 双 dump 自动比对 + `metadata.skill_version` 字段（解决"已存档 dump 与新 dump 冲突未及时校对"）。0.3 天
- **[BACKLOG][P2] R8 Sprint γ**：`resource-trace <rid>` 资源 provenance（writers / readers / inferred_role），解决"非主流 RT/buffer 没 label，agent 只能猜"。1 天
- **[WISHLIST][P3] R8.6**：host-side shader function evaluator（白名单 IR 子表达式 JIT），让 agent "把 cbuffer 实测值代入公式 sanity check" 不再手算错。等到 lighting/material 自动校验有第二个明确需求再启动
- **每个 R7 chunk 落地后必须同步**：SKILL.md（"Exploring an unknown trace's pipeline" 工作流 / 已知盲点） + `references/investigation-playbook.md`（frame-overview worked example） + `references/cli-reference.md`（新子命令 schema）。R7.1/R7.2/R7.3/R7.4/R7.6-A/R7.6-C/R7.6-D/R7.6-E/R7.7 落地时已同步。

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 看进程读哪些 gputrace/缓存文件
- **最高信号静态锚点**：`GPUToolsReplay`、`GPUToolsServices` 上的 `strings` / `nm -m`
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)
- **探针编译模板**：`clang -framework Foundation -framework Metal -ldl -lobjc -o <probe> <probe>.m`
- **PSO→Function 关联拦截**：method swizzling `MTLDevice -newRenderPipelineStateWithDescriptor:[options:reflection:]error:`，必须在 `init_replay()` 之前装；类要找具体实现类（如 `AGXG16SDevice`）— 已合入 bridge 的 `rps_install_swizzles()`，`Scripts/gputrace_replay_bridge.m` 里参考实现

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260521-R7-frame-inspection-gap.md` | **总是建议读取** — R7 是当前主线，本文档是入口 | 14 处卡点（已解决/未解决标注）/ 7 段 draw→IR 反查 / 改进矩阵（含 R7.1~R7.7 + R7.6-A/B/C/D 完整交付摘要 + 设计决策 + 已知局限）/ LYSK 65 RPS 回归基线 / compute-only 回归断言表 |
| `subdocs/20260522-R8-skill-usability-backlog.md` | **总是建议读取** — R8 是 skill 可用性核心 | 6 类 agent 错误案例复盘 / Sprint α 实现详情（R8.1 draw-info + R8.2 health + R8.3 by-name）/ R8.4~R8.6 BACKLOG / R7↔R8 边界 |
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是所有任务的基础 | 完整调用链、偏移表、ObjectMap、playTo、Pipeline 导出 |
| `subdocs/20260521-R7.6-A-frame-list-bindings.md` | 在改 binding 表实现 / 加 compute encoder bindings / inline buffer 字节复制 / 实施 R8.1 metadata 注入时按需读取 | 12 swizzle 集合、per-encoder rolling slot 表、emit 阶段 (ptr→id) 反向字典、JSON schema、LYSK 数据基线、已知局限 |
| `subdocs/20260520-R6.1-bridge-implementation.md` | 在改 bridge 子命令实现 / 加新子命令时按需读取 | 子命令架构、JSON schema、构建方法、测试覆盖 |
| `subdocs/20260521-R6.2-wrapper-and-skill.md` | 在使用 Python wrapper / 改造 skill 时按需读取 | wrapper API、skill 目录结构、自包含验证、设计决策 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在扩展 shader 替换功能时按需读取 | 替换路径对比、Xcode UI 能力缺口 |
| `subdocs/20260520-R5.3-shader-debug.md` | 在探索 IPC/debug 后续方向时按需读取 | ShaderDebug 类族、instrumented debug、IPC 探索结论 |
| `subdocs/20260520-R5.4-configuration.md` | 在扩展 config 功能时按需读取 | 13 属性映射、Service 路径 |
| `subdocs/20260520-R1.1-api-inventory.md` | 一般无需读取（仅在查 GPUToolsReplay 导出符号 / 76 类清单时按需） | 二进制导出符号、GPUToolsServices 类清单、Harvester blob 格式 |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | 一般无需读取（XPC 路径不使用） | Fetch/Query/Profile/ShaderDebug/Update 类族接口 |
| `subdocs/20260520-R3-headless-replay.md` | 一般无需读取（已被 Controller 路径取代，仅 APR/Options 偏移表查阅时用） | APR bootstrap、Options 布局、CLI 能力边界 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取（已被 R3 取代） | CLI 函数签名 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取（headless 路径不依赖字典） | XPC 三层字典字段 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（已被 R6.1 ObjC bridge 取代） | 早期 Python bridge CLI schema |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取 | R0 基线：模块/进程/符号 |
| `LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` | 一般无需读取（核心算法已合入 bridge）；仅在 `rps_correlated_count` 异常时作回归对照 | ~200 行 ObjC 探针，已在 LYSK trace 验证 65 RPS 反查 |
