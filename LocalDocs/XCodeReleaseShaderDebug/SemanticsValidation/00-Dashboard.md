## Semantics Validation Dashboard

## 问题背景

Road E 当前已经建立了比较完整的工程链路：

```text
metallib / wrapper payload
  ↓
BitcodeModule.data
  ↓
llvm-dis
  ↓
LLVM IR
  ↓
IRToMSLConverter
  ↓
MSL
  ↓
makeLibrary(source:) / metal -c
```

但现状更接近：

- **逐指令机械翻译 + compile 守门 + replay/diff 回归**
- 而不是 **已被严格证明的语义等价闭环**

当前缺口主要在：

- 没有离线 **IR round-trip** 验证
- 没有统一的 **canonical compare / 风险分级**
- 没有稳定的 **最小行为测试体系**
- 没有把 **真实场景验证** 收敛成自动化优先、低人工依赖的后置 gate

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

## 最终目标

建立一套尽可能完善的 **Semantics Validation** 测试体系，覆盖四层：

1. **L1：IR Round-trip 结构验证**
2. **L2：Canonical Compare + 风险分级**
3. **L3：最小行为测试**
4. **L4：真实场景验证**

总体原则：

- **offline-first**：优先离线验证，减少 live 成本
- **automation-first**：默认只采用 agent 可独立完成的脚本 / MCP / skill 路径
- **minimal-human**：若确实需要人工/外部协助，必须先把留给用户的步骤压到最少、最简单；并在执行前得到用户确认
- **分层止损**：最终做到哪一层，取决于当时的人力余量（包括 token 预算与实现成本）；但主路线始终按 L1 → L2 → L3 → L4 推进

## 当前主线

### 主线任务

**`SV-001`：先建立离线 `IR -> MSL -> AIR -> IR` round-trip harness，并在 `test-data/` 上产出第一版批量报告。**

这是当前最高优先级，因为它：

- 成本最低
- 自动化程度最高
- 对后续 L2/L3/L4 都是基础设施
- 最能直接回答“当前到底有没有语义闭环证据”

### 当前不该抢跑的事

在 `SV-001` 未完成前，默认**不要**把精力放到：

- 大规模 live `.gputrace` 验证
- 高成本 GUI/Accessibility 操作
- 需要用户频繁登录/摆场景/点按钮的流程
- 工作区外静态分析、外部二进制 patch、手动逆向

除非它们是为解除当前最高优先级阻塞所**绝对必要**的最小步骤，且已获得用户确认。

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：文档、离线脚本、`IRToMSLConverter`、compare 逻辑、最小样本。

- 已有离线 replay / compile：

```bash
python3 Scripts/corpus_replay_runner.py --compile --ll <sample.ll>
```

- 已有 PlayTools 构建守门：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

- 本专项新增后应优先使用的默认 gate（待 `SV-001` 落地）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py ...
```

### 运行时链路验证（只在必要时）

仅在修改以下内容时执行：

- `LibrarySourceInjectionSwizzles`
- `MetallibParser`
- `LLVMDisassembler`
- runtime 导出路径 / host bridge / 安装部署逻辑
- 必须依赖真实 app 或 `.gputrace` 才能验证的变更

标准构建/安装方式：

```bash
./BuildScripts/build_and_install.sh
```

**禁止**手写 `xcodebuild` 替代标准脚本。

### 真实场景验证（后置 gate）

仅当 L1/L2 已基本收敛，且需要确认“真实 shader / 真实场景下没有明显退化”时才启用。

优先使用：

- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- PlayCover MCP 能力（如 `launch_app` / `create_session` / `capture_metal_frame` 等）

若需要以下条件之一，**必须先得到用户确认**：

- GUI / Accessibility / `cliclick`
- 人工登录或手动摆场景
- 工作区外静态分析
- 工作区外文件或 app bundle 修改

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的 **一个** 未完成任务执行
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。确保留给人工手动操作的步骤是最少最简单的状态。如果已达到该状态，则立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分到 TODO，再只完成其中一个
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-000 | 现状调研与缺口梳理 | ✅ DONE | - | 已确认当前没有严格语义闭环，已形成总体路线 | `01-现状调研与缺口.md` |
| SV-001 | 离线 IR round-trip harness | TODO | P0 | 建立 `IR -> MSL -> AIR -> IR` 自动化主链路，先覆盖 `test-data/` | `03-L1-IR-RoundTrip.md` |
| SV-002 | Canonical compare + 风险分级 | TODO | P1 | 在 round-trip 基础上建立结构化 compare，而非只看文本 diff | `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-003 | 把 L1/L2 接入 `test-data/` 与 `ShaderCorpus` | TODO | P1 | 先跑最小样本，再扩到代表性 corpus，形成日常批量报告 | `02-总体技术路线.md` |
| SV-004 | 最小行为测试（compute-first） | TODO | P2 | 优先建立 compute 输出对比，再决定是否补离屏 render | `05-L3-最小行为测试.md` |
| SV-005 | 真实场景验证流程收口 | TODO | P3 | 把 `.gputrace` / render diff / MCP live 验证收口成后置 gate | `06-L4-真实场景验证.md` |
| SV-006 | 分层 gate 与止损策略 | TODO | P2 | 明确“做到哪一层就可以先停”的预算决策规则 | `02-总体技术路线.md` |

### 当前关键卡点

- **没有 round-trip runner**：当前没有脚本把 `generated.metal` 再编回 `.air` 并反汇编成 `regenerated.ll`
- **没有 canonical compare**：现有 replay / baseline diff 主要比较 generated MSL 和 compile 结果
- **没有行为级 oracle**：最小样本主要覆盖 lowering 与 compile，不覆盖行为输出
- **真实场景验证成本高**：应当严格后置，不能在 L1/L2 未收敛时抢跑

## 踩坑与经验

- **compile green 不等于语义等价**
- **`.gputrace` 可见源码不等于最终行为无差异**
- **先做离线，再做 live**；live 只用于阶段性确认，不做默认主战场
- **不要把“文本完全一样”误当成“语义一样”**；后续比较应以 canonical summary + 风险分级为主
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`
- `02-总体技术路线.md`
- `03-L1-IR-RoundTrip.md`
- `04-L2-CanonicalCompareAndRiskGrading.md`
- `05-L3-最小行为测试.md`
- `06-L4-真实场景验证.md`

### 上游 Road E 参考

- `../RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`
- `../RoadE-HookMakeLibraryWithSrc/E-004-MetallibSourceExtraction.md`
- `../RoadE-HookMakeLibraryWithSrc/E-005-OfflineReplayBatchCompileDiff.md`
- `../RoadE-HookMakeLibraryWithSrc/E-006d-GenshinRenderingNondeterminism.md`
- `../RoadE-HookMakeLibraryWithSrc/E-006d-RenderingPathDiffReference.md`

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Scripts/corpus_replay_runner.py`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
