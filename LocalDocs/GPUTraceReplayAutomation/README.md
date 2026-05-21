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
| **Depth/Stencil 可视化** | bridge 内置 blit + export | ⏳ R7.5 |
| **Uniform / cbuffer 内容查看** | `dump-uniforms` 子命令 | ⏳ R7.6 子项 B |
| **Shader 反编译（IR 直接产出）** | `disasm` 子命令集成 cacheKey + llvm-dis | ⏳ R7.7 |
| GPU Counters / Profiler / Derived | 需 Apple 私有 entitlement + SIP 关闭 | ⛔ 跳过 |

**完成度**：R0~R6 已完成（基础能力 + bridge + Python wrapper + skill 打包）；R7.1 + R7.2 + R7.3 + R7.4 + R7.6-C 已完成（bridge 7 子命令 + wrapper 8 子命令 / 88 集成测试 / 端到端 draw_index→IR 一行命令闭环）；R7.5/R7.6 子项 A·B/R7.7 为剩余主线（按依赖顺序进行）。

最终交付物：
1. **统一 ObjC bridge CLI**（`Scripts/gputrace_replay_bridge.m`）— ✅ 7 子命令，Makefile 构建，集成测试 88/88 通过
2. **Python CLI wrapper**（`Scripts/gputrace_replay_wrapper.py`）— ✅ CLI + 模块双接口，dataclass 返回值（含 R7.2 `ColorAttachment` / R7.4 `ShaderOfRpsResult` / R7.3 `FrameListResult` / **R7.6-C `ShaderOfDrawcallResult` + `DrawIndexOutOfRange` 异常** 等）
3. **端到端验证链路** — ✅ LYSK trace 65/65 RPS 反查 + 244/244 draw→RPS 映射 + frame-list → shader-of-rps 端到端取 metallib/IR + **R7.6-C `shader-of-drawcall 0/103 --with-ir` 与手工链字节级一致（metallib/AIR/cacheKey clean，.ll 仅差 ModuleID 路径注释）**
4. **GPU Trace 分析 skill**（`.codebuddy/skills/gpu-trace-analysis/`）— ✅ 自包含，含 SKILL.md + scripts/ + references/，从任意目录可独立运行
5. **R7：Frame-Inspection 能力补全** — ⏳ 进行中，剩余按"先解锁已交付能力 → 再加新能力"重排：**R7.7（disasm + SDI module.bc 覆盖，把 R7.6-C 的实际命中率从 ~3% 提升到 ~100%） → R7.5（depth/stencil blit + compute dispatch 计数） → R7.6 子项 A/B（bindings + uniforms）**。详见 TODO + `subdocs/20260521-R7-frame-inspection-gap.md`

## 样本 trace 路径（回归基线）

| 样本 | 路径 | 形态 | 用途 |
|------|------|------|------|
| **LYSK**（主基线） | `/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace` | 4 cb / 62 enc / 244 draws / 65 RPS / 96 lib / 3425 calls | R7.2/R7.3/R7.4/R7.6-C 主回归（端到端 IR 链） |
| reference_test_inject | `~/Desktop/reference_test_inject.gputrace` | 2 cb / 2 enc / 0 draws / 0 RPS / 3 compute PSO / 27 calls | R7.6-C compute-only 回归（OOR / `draw_count=0` / `rps_not_found`） |
| reference_144316 | `~/Desktop/reference_144316.gputrace` | compute-only (与 inject 同形态) | 备用 compute-only 样本 |

设置 `GPUTRACE_PATH` 即可让 `Scripts/test_gputrace_replay_bridge.sh` 跑 live-trace 断言：

```bash
GPUTRACE_PATH="/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace" \
    bash Scripts/test_gputrace_replay_bridge.sh
# → 88 passed, 0 failed, 88 total

GPUTRACE_PATH="$HOME/Desktop/reference_test_inject.gputrace" \
    bash Scripts/test_gputrace_replay_bridge.sh
# → R7.6-C 自身断言通过；R7.3 在 compute-only 上的 14 个"健康路径"断言失败属于已知盲点（trace-shape 假设错误，由 R7.3 而非 R7.6-C 负责）
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

- **主线模块链**：`GPUDebugger.ideplugin` → `GPUToolsServices`(76 类) → XPC Services → `GPUToolsReplay.framework`(C API)
- **主力路径 — Controller 路径**（R4.2）：`makeDataSource → makeController → playAll/playTo` — 完整 replay + 对象访问 + 定向 replay，无 XPC/entitlement 依赖。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
- **Pipeline Binary 导出**：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 偶数=Library，奇数=Function，规则：`library_key = function_key - 1`
- **Shader 热替换**：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Configuration**：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **Call-index 边界**（R7.1）：`*(uint32_t *)(controller + 0x5810)` = last played call index；`playAll` 完成后即 trace 总 call 数；bridge 已加 `--bounds` / OOR 结构化错误（exit 12） / SIGSEGV 兜底 / texture+buffer 元数据补齐。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.1
- **RPS↔shader 内置关联**（R7.2）：bridge 在 `replay_context_init` 之前装 method swizzling（`MTLDevice newRenderPipelineStateWithDescriptor:[options:reflection:]error:` 三变体），把每对 (descriptor, RPS) 落到 `g_rps_captured[]`；`pipeline` dump 时给每个 RPS 加 vertex/fragment function/library key + attachment 摘要 + raster sample count。`rps_correlated_count` / `rps_captured_count` 是 swizzle 健康度指标（应等于 `render_pipeline_states_count`）。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.2
- **`shader-of-rps` 子命令**（R7.4）：一行命令从 RPS_key 拿 fragment/vertex 的 metallib + AIR + `cache_key_metallib`；`--with-ir` 自动调 `llvm-dis` 产出 `.ll`。失败结构化（rps_not_found / descriptor_not_captured / stage_function_absent / no_air_bitcode / llvm_dis_not_found），exit 11 但 JSON 完整保留。AIR 覆盖率较低（LYSK 96 lib 中仅 3 个有 `bitcodeData`）— R7.7 通过 SDI module.bc 路径补足。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.4
- **`frame-list` 子命令（swizzle-first）**（R7.3）：在 `replay_context_init` 之前装一组 swizzle（`MTLCommandQueue.commandBuffer*` / `MTLCommandBuffer.{render,compute,blit}CommandEncoder*` / `MTLRenderCommandEncoder.{setRenderPipelineState:, drawXXX:*, endEncoding}`），`playAll` 期间打开 capture gate 把 (cb, encoder, draw, RPS) 落到进程级 `g_cb_captured / g_encoder_captured / g_draws_captured`。输出 `command_buffers[].encoders[].draws[]` 树 + 扁平 `draw_to_rps_map[]`。LYSK 实测：4 cb / 62 encoder（56 render / 2 compute / 4 blit）/ 244 draws 全部解析到 65/65 RPS。`first/last_call_index` 直接读 R7.1 的 controller offset。`--with-timing` 在 replay-internal cb 上常返 null（已文档说明）。`shader-of-drawcall` 退化为薄封装（R7.6 子项 C，0.5 天）。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.3
- **统一 Bridge**（R6.1+）：`Scripts/gputrace_replay_bridge.m` — 7 子命令（help/replay/pipeline/shader/shader-of-rps/frame-list/config），Makefile 构建 + ad-hoc 签名 + 集成测试 81/81 通过。详见 `subdocs/20260520-R6.1-bridge-implementation.md`
- **Python wrapper + skill 打包**（R6.2）：`Scripts/gputrace_replay_wrapper.py` + `.codebuddy/skills/gpu-trace-analysis/`。详见 `subdocs/20260521-R6.2-wrapper-and-skill.md`
- **R7 缺口诊断**：`pipeline` 缺 RPS↔shader 关联（→ ✅ R7.2）；无 encoder/draw 时间序（→ ✅ R7.3）；7 段 draw→IR 反查链已 7/7 通过（段 1 由 R7.3 swizzle-first 路径打通），用户最终目标"draw N → IR 一行命令"由 R7.6 子项 C 薄封装收尾（→ ✅ 2026-05-21）；depth/stencil 不能 export → ⏳ R7.5。详见 `subdocs/20260521-R7-frame-inspection-gap.md`
- **`shader-of-drawcall` 薄封装**（R7.6-C）：Python wrapper-only，bridge 不动。`bridge.shader_of_drawcall(trace, draw_index, stage, with_ir, output_dir)` = `frame_list → draw_to_rps_map[draw_index] → shader_of_rps`，输出嵌入完整 `shader_of_rps` 结果 + frame-list 上下文（`encoder_index` / `draw_in_encoder` / `call_index` / `rps_label`）。OOR 抛 `DrawIndexOutOfRange`（CLI exit 12，含 `draw_count=0` 的 compute-only 友好 hint）；`shader-of-rps` 软错误透传到顶层（CLI exit 11）；负 idx / 非法 stage → `ValueError`。LYSK draw[0]/draw[103] 的 metallib/AIR/cacheKey 与手工链字节级一致（`.ll` 仅差 ModuleID 路径注释，是 llvm-dis 行为）。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.6

### 当前卡点

无。R7.6-C 完成（2026-05-21）。

### 下一步（当前最高优先级）

**R7.7：`disasm` 子命令 + SDI module.bc 路径覆盖无 AIR 的 library — 1.5 天**

**抢占 R7.5 的理由**：R7.6-C 刚交付的 `shader-of-drawcall <draw_index> --with-ir` 是用户最直接、最高频的入口；但 LYSK 主样本 96 lib 中只有 3 个有 AIR bitcode（~3% 命中率），意味着 95%+ 的请求会得到 `no_air_bitcode`，刚交付的"一行命令拿 IR"承诺在主样本上几乎兑现不了。R7.7 通过探测 `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cacheKey>/modules/<hash>/module.bc`（cacheKey 已在 R7.4 算出），把命中率从 ~3% 提升到接近 100%，让 `shader-of-drawcall --with-ir` / `shader-of-rps --with-ir` 真正可用。R7.5（depth/stencil + compute dispatch）是新能力但相对独立，没有"刚交付能力被堵塞"的紧迫感，按"先解锁已交付能力，再加新能力"原则排在 R7.7 之后。

详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.7（R7.7）与 §3（7 段映射的最后一段）。R7.7 之后排序：R7.5（1–1.5 天） → R7.6 子项 A/B（bindings 1.5 天 + uniforms 1 天）。

## 构建与验证的方法

- **构建**：`cd Scripts/ && make`（编译 + ad-hoc 签名）；`make test`（集成测试 19 项离线 + 62 项需 GPUTRACE_PATH 的 live trace 断言）；`make clean`
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
- **[IN-PROGRESS][P0] R7**：Frame-Inspection 能力补全（详见 `subdocs/20260521-R7-frame-inspection-gap.md`）
  - **[DONE] R7.1**：bridge 越界保护 + 资源元数据补齐 — `total_call_count` / `last_call_index` / `--bounds` / `playto_out_of_range`(exit 12) / SIGSEGV 兜底 / texture+buffer storageMode/usage/hazardTracking 等
  - **[DONE] R7.2**：`pipeline` 输出加 RPS↔shader 关联（vertex/fragment function/library key + attachment 摘要 + raster sample count，bridge 内置 swizzle）。LYSK 65/65 RPS 反查通过
  - **[DONE] R7.3**：`frame-list` 子命令（swizzle-first 路径）— encoder 列表（含 compute/blit）+ draw→RPS 映射 + `--with-timing` flag 一次冲刺打通。LYSK trace 实测 244/244 draw 全部解析到 65/65 RPS；timing 字段在 replay-internal cb 上常返 null（已文档说明）
  - **[DONE] R7.4**：`shader-of-rps` 子命令（语义级反查 + `--with-ir` 调 `llvm-dis` 直出 `.ll` + `cache_key_metallib`），与 R7.2 同冲刺完成
  - **[DONE] R7.6 子项 C**（2026-05-21）：`shader-of-drawcall` 薄封装（wrapper-only：`frame-list → draw_to_rps_map → shader-of-rps`）+ LYSK draw_index=0/103 字节级一致回归 + reference_test_inject compute-only OOR/`draw_count=0` 回归。集成测试 88/88 通过。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.6
  - **[P0] R7.7（当前最高优先级）**：`disasm` 子命令 + SDI module.bc 路径 — 1.5 天。把 R7.6-C 的 `shader-of-drawcall --with-ir` 命中率从 ~3%（仅 `bitcodeData` 非空的 library）提升到 ~100%（探测 `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cacheKey>/modules/<hash>/module.bc`），让刚交付的"一行命令拿 IR"在 LYSK 主样本上真正可用。低风险（cacheKey 算法已落 bridge，SDI 路径解析是文件 I/O）。
  - **[P1] R7.5**：depth/stencil export（bridge 内置 blit）+ compute encoder dispatch 计数补齐 — 1–1.5 天合计。新能力但相对独立，没有"刚交付能力被堵塞"的紧迫感
  - **[P2] R7.6 子项 A/B**：`frame-list --with-bindings`（1.5 天）+ `dump-uniforms`（1 天，依赖子项 A 的 binding 表）
- **每个 R7 chunk 落地后必须同步**：SKILL.md（"Exploring an unknown trace's pipeline" 工作流 / 已知盲点） + `references/investigation-playbook.md`（frame-overview worked example） + `references/cli-reference.md`（新子命令 schema）。R7.1/R7.2/R7.3/R7.4/R7.6-C 落地时已同步。

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
| `subdocs/20260521-R7-frame-inspection-gap.md` | **总是建议读取** — R7 是当前主线，本文档是入口 | 14 处卡点（已解决/未解决标注） / 7 段 draw→IR 反查 / 改进矩阵 7 chunk（含 R7.1/R7.2/R7.3/R7.4 完整交付摘要 + 端到端实测） / LYSK 65 RPS 回归基线 |
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是所有任务的基础 | 完整调用链、偏移表、ObjectMap、playTo、Pipeline 导出 |
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
