## 最终目标

**使 CLI 模式下的 GPU 截帧 replay 在功能上尽可能等价于 Xcode GUI 窗口内的 replay 以及分析调试等操作。**

当前重点：让 `gpu-trace-analysis` skill 变得**易用、好用、功能完善、防呆**——agent 使用过程中更不容易出错。

等价性定义 — Xcode GUI replay 窗口内能做的事，CLI 下均应能以编程方式完成：

| 能力维度 | CLI 等价目标 | 状态 |
|----------|-------------|------|
| Replay 执行 | headless 重放任意 .gputrace | ✅ |
| 帧/draw call 导航 | `playTo(controller, targetCallIndex)` | ✅ |
| 纹理/Buffer 查看 | ObjectMap → getBytes/contents 导出 | ✅ |
| 压缩纹理（ASTC/BC/ETC）导出 | render pass 解压 → RGBA8 导出 | ✅ R10 |
| Pipeline 查看 | libraryDataContents/bitcodeData 导出 | ✅ |
| Shader 热替换 | setLibrary:forKey: + rewind+playAll | ✅ |
| Shader Debug | instrumented debug 替代方案 | ⚠️ 部分 |
| Configuration 修改 | 调用链控制 + 全局变量 | ✅ |
| 输出自动化 | bridge JSON/bin 导出 | ✅ |
| Encoder/Pass/Draw 时间序枚举 | `frame-list` 子命令 | ✅ R7.3 |
| RPS↔shader 关联 | `pipeline` 输出 vertex/fragment function/lib key + attachment | ✅ R7.2 |
| RPS → shader IR 反查 | `shader-of-rps` 子命令（含 `--with-ir`） | ✅ R7.4 |
| Draw call → RPS_key 反查 | `frame-list` 输出 `draw_to_rps_map[]` | ✅ R7.3 |
| Draw call → shader IR 反查 | `shader-of-drawcall` 子命令 | ✅ R7.6-C |
| Per-draw vertex/fragment binding 表 | `frame-list --with-bindings`（默认 ON） | ✅ R7.6-A |
| Draw call → "IR + bindings + uniforms" 三件套 | `shader-of-drawcall --with-uniforms` | ✅ R7.6-D |
| GUI shader 名 / RPS label → draw_index 反查 | `find-draws --by-label / --by-shader-name` | ✅ R7.6-E |
| Per-draw binding 表自动注入 IR metadata + size_check | `draw-info` 子命令 | ✅ R8.1 |
| NaN/inf/denormal 自动告警 | `value_health_summary` + `size_check` | ✅ R8.2 |
| 按 IR arg_name 反查 cbuffer 字段 | `dump-uniforms --by-name` | ✅ R8.3 |
| 顶点数据通道查询与导出 | `vertex-info` 子命令（含 --export-channel） | ✅ R14 |
| Depth/Stencil 可视化 | bridge 内置 blit + export | ⏳ R7.5 |
| Uniform / cbuffer 内容查看 | `dump-uniforms` 子命令 | ✅ R7.6-B |
| Shader 反编译（IR 产出） | `disasm` 子命令 + SDI fallback | ✅ R7.7 |
| GPU Counters / Profiler | 需 Apple 私有 entitlement + SIP 关闭 | ⛔ 跳过 |

**完成度**：R0~R14 核心功能全部完成（bridge 9 子命令 + wrapper 14 子命令（含 find-draws / draw-info / diagnose / vertex-info） / 集成测试 LYSK 主基线 **148/148**）。R14 新增：`vertex-info` 一条命令查询 draw call 顶点通道 + 导出 channel 数据。

最终交付物：
1. **统一 ObjC bridge CLI**（`.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge.m`）— 9 子命令，Makefile 构建，支持压缩纹理解压导出
2. **Python CLI wrapper**（`.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py`）— CLI + 模块双接口，14 子命令（含 find-draws / draw-info / vertex-info），dataclass 返回值
3. **端到端验证链路** — LYSK 全覆盖（65 RPS / 244 draw / 96 IR / cbuffer 字节级一致）
4. **GPU Trace 分析 skill**（`.codebuddy/skills/gpu-trace-analysis/`）— 自包含，含 SKILL.md + scripts/ + references/

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

- **主线模块链**：`GPUDebugger.ideplugin` → `GPUToolsServices`(76 类) → XPC Services → `GPUToolsReplay.framework`(C API)
- **主力路径 — Controller 路径**（R4.2）：`makeDataSource → makeController → playAll/playTo`。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
- **Pipeline Binary 导出**：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 规则：`library_key = function_key - 1`
- **Shader 热替换**：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Configuration**：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **Call-index 边界**（R7.1）：`*(uint32_t *)(controller + 0x5810)` = last played call index。OOR 结构化错误（exit 12）+ SIGSEGV 兜底
- **Swizzle-first 框架**（R7.2/R7.3/R7.6-A）：所有 swizzle 在 `replay_context_init` 之前安装；render encoder 类延迟到首次实例化时安装；capture gate 仅在 `playAll` 期间打开
- **draw → IR + bindings + uniforms 三件套**（R7.6-D）：`shader_of_drawcall(draw_index, with_uniforms=True)` 一行命令，内部 = frame-list → dump-uniforms → IR 路径（100% 命中率）
- **压缩纹理导出**（R10）：ASTC/BC/ETC 纹理需通过 fullscreen triangle render pass 采样解压 → RGBA8 shared texture → getBytes。直接 getBytes 或 blit copy 均只得到原始压缩块
- **统一 Bridge + wrapper + skill**（R6）：bridge 9 子命令 + wrapper 12 子命令。详见 `subdocs/20260520-R6.1-bridge-implementation.md` + `subdocs/20260521-R6.2-wrapper-and-skill.md`

### 当前卡点

无。

### 下一步（当前最高优先级）

**[P2] BACKLOG: R7.5 / R8 Sprint β / R8 Sprint γ**

R12 已完成。当前无 P0/P1 任务。剩余均为 P2 BACKLOG：
- R7.5：depth/stencil export + compute dispatch 计数
- R8 Sprint β：`dump-diff` 双 dump 自动比对 + `metadata.skill_version`
- R8 Sprint γ：`resource-trace <rid>` 资源 provenance

等待用户确认下一个优先级。

剩余 BACKLOG/WISHLIST：
- **[BACKLOG][P2] R7.5**：depth/stencil export + compute dispatch 计数
- **[BACKLOG][P2] R8 Sprint β**：`dump-diff` 双 dump 自动比对 + `metadata.skill_version`
- **[BACKLOG][P2] R8 Sprint γ**：`resource-trace <rid>` 资源 provenance
- **[WISHLIST][P3] R8.6**：host-side shader function evaluator

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
- **[DONE] R6**：客户端封装与可用性收尾（bridge + wrapper + skill 打包）。详见 `subdocs/20260520-R6.1-bridge-implementation.md` + `subdocs/20260521-R6.2-wrapper-and-skill.md`
- **[DONE] R7**：Frame-Inspection 能力补全（主线 11 子项全完成，148/148 集成测试）。详见 `subdocs/20260521-R7-frame-inspection-gap.md`
- **[DONE] R8 Sprint α**：agent 多数据源 join 错误结构性消除（R8.1 draw-info + R8.2 health + R8.3 by-name）。详见 `subdocs/20260522-R8-skill-usability-backlog.md`
- **[DONE] R9**：Skill 引导层优化（决策树重构 + 5 bug pattern 模板 + cli-reference 层级化）— 纯文档改动
- **[DONE] R10**：ASTC 压缩纹理导出修复 — bridge 新增 render pass 解压路径，13 张纹理全部正确导出
- **[DONE] R11**：Skill 防呆与鲁棒性加固（R11.1 导出自动验证 + R11.2 `.meta.json` sidecar + R11.3 压缩格式标记 + R11.4 SKILL.md 更新）。详见 `subdocs/20260522-R8-skill-usability-backlog.md` §6
- **[DONE] R12**：错误恢复与 agent 自诊断能力（R12.1 Troubleshooting 章节 + R12.2 `diagnose` + R12.3 Pattern Pitfalls）。详见 `executions/20260526-R12-error-recovery-and-self-diagnosis.md`
- **[DONE] R13**：便捷查询命令实现（find-draws + draw-info + dump-uniforms --by-name CLI 入口）。详见 `executions/20260602-R13-convenience-commands.md`
- **[DONE] R14**：顶点数据通道查询与导出（`vertex-info` 一条命令查询 draw call 所有顶点通道 + 导出 channel 数据）。详见 `executions/20260602-R14-vertex-info.md`
- **[BACKLOG][P2] R7.5**：depth/stencil export + compute dispatch 计数
- **[BACKLOG][P2] R8 Sprint β**：`dump-diff` 双 dump 自动比对 + `metadata.skill_version`
- **[BACKLOG][P2] R8 Sprint γ**：`resource-trace <rid>` 资源 provenance
- **[WISHLIST][P3] R8.6**：host-side shader function evaluator
- **同步规则**：每个新 chunk 落地后必须同步 SKILL.md + cli-reference.md + investigation-playbook.md

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 看进程读哪些 gputrace/缓存文件
- **探针编译模板**：`clang -framework Foundation -framework Metal -ldl -lobjc -o <probe> <probe>.m`
- **压缩纹理导出要点**（R10）：Metal `getBytes` 对 ASTC/BC/ETC 返回原始压缩块而非 RGBA 像素；必须通过 render pass shader 采样解压；blit copy 不跨格式组转换；解压后字节序为 RGBA（非 BGRA）
- **PSO→Function 关联拦截**：method swizzling `MTLDevice -newRenderPipelineStateWithDescriptor:error:`，必须在 `init_replay()` 之前装

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260521-R7-frame-inspection-gap.md` | **总是建议读取** — R7 是功能主体 | 14 处卡点 / 7 段 draw→IR 映射 / R7.1~R7.7 全部实现细节 + 回归基线 |
| `subdocs/20260522-R8-skill-usability-backlog.md` | **总是建议读取** — R8 是防呆核心 | 6 类 agent 错误案例 / Sprint α 实现（draw-info + health + by-name）/ BACKLOG |
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是基础 | 调用链、偏移表、ObjectMap、playTo、Pipeline 导出 |
| `subdocs/20260521-R7.6-A-frame-list-bindings.md` | 在改 binding 实现时按需读取 | 12 swizzle、rolling slot 表、JSON schema |
| `subdocs/20260520-R6.1-bridge-implementation.md` | 在改 bridge 子命令时按需读取 | 子命令架构、JSON schema、构建测试 |
| `subdocs/20260521-R6.2-wrapper-and-skill.md` | 在改 wrapper / skill 打包时按需读取 | wrapper API、skill 目录结构 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在扩展 shader 替换时按需读取 | 替换路径对比 |
| `subdocs/20260520-R5.3-shader-debug.md` | 一般无需读取 | ShaderDebug 类族、instrumented debug |
| `subdocs/20260520-R5.4-configuration.md` | 一般无需读取 | 13 属性映射 |
| `subdocs/20260520-R1.1-api-inventory.md` | 一般无需读取 | GPUToolsReplay 导出符号 |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | 一般无需读取 | XPC 路径 Fetch/Query 类族 |
| `subdocs/20260520-R3-headless-replay.md` | 一般无需读取 | APR bootstrap、Options 布局 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取 | CLI 函数签名 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取 | XPC 三层字典 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取 | 早期 Python bridge |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取 | R0 基线 |
