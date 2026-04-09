## Semantics Validation Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 当前主线

> 当前只做 `SV-003F`：现有测试已跑绿，`ShaderCorpus` 与 `ShaderSourceDiagnostics` 两条 full-batch 批量入口都已完成零 replay / compile / llvm-dis 失败的批量复跑；当前剩余收口点是如何看待两条 full-batch 仍报出的 generic `L2/L3` 风险债务，以及运行时 bridge 注册信号未稳定时是否直接宣告主线完成。

### 当前卡在哪里

- `c66b9d4a60df030991dd90f8ed9e58368df846eeed70022fb8a0f402b4bbcd7b` 的 `int -> uint` compile blocker 已修复，当前离线闭环不再卡在这条编译失败上
- `ShaderCorpus` 是 success-path 主入口，`ShaderSourceDiagnostics` 是 failure-path 补充入口；两条 full-batch 现已完成零 replay / compile / llvm-dis 失败复跑，但 generic gate 仍报告已有 `L2/L3` 风险债务
- `QQ飞车手游` 已按标准 `build_and_install.sh` 后补做启动 smoke：alias app 可拉起、进程在 settle 窗口内存活，当前未观察到“启动即崩”；但 host bridge registration acknowledgement 在本机仍未稳定，暂不能把 `create_session` ready 当作这轮自动化证据
- 默认流程仍必须保持 agent 可独立完成；若某步必须人工介入，需要先明确阻塞

## TODO

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `SV-003F` | DOING | 当前现有测试全部通过：`test_ir_canonical_compare.py`、`test_ir_semantics_roundtrip_runner.py`、`test-data-representatives` 不回退，且 `ShaderCorpus` / `ShaderSourceDiagnostics` 两条批量入口通过，同时 `QQ飞车手游` 启动不崩 | `03-L1-IR-RoundTrip.md` / `06-L4-真实场景验证.md` |
| `SV-003F.1` | DONE | compile blocker 已不再是当前主矛盾，问题已收敛到 full-batch 批量入口与启动稳定性 | 同上 |
| `SV-003F.2` | DONE | `test_ir_canonical_compare.py`、`test_ir_semantics_roundtrip_runner.py` 与 `test-data-representatives` 已复跑通过，代表集 gate 仍保持 `WARN` / known debt 口径 | 同上 |
| `SV-003F.3` | DONE | `ShaderCorpus` full-batch 已复跑完成，`380 / 380` job round-trip 成功，`replay / compile / llvm-dis` 三段零失败 | 同上 |
| `SV-003F.4` | DONE | `ShaderSourceDiagnostics` full-batch 已复跑完成，`153 / 153` job round-trip 成功，`replay / compile / llvm-dis` 三段零失败；原 `c66b9d4...` compile blocker 已降级为 `L2` compare 风险 | 同上 |
| `SV-003F.5` | DONE | 已执行 `./BuildScripts/build_and_install.sh` 后补做 `QQ飞车手游` alias 启动 smoke；当前观察到 app 进程在 settle 窗口内存活、未出现“启动即崩”，但 host bridge ack 仍未稳定 | 同上 |

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：当前主线 `SV-003F` 相关改动，包括文档、离线脚本、`IRToMSLConverter`、`LLVMDisassembler`、canonical compare / gate 逻辑，以及 `ShaderCorpus` / `ShaderSourceDiagnostics` 的样本纳入路径。

**当前要求**：只要本轮修改触及上述范围，agent 在收尾测试时默认按下面顺序执行所有**适用**步骤；不要只跑其中一条就结束。

1. **必要时先做 PlayTools 构建守门**（仅当改动涉及 `IRToMSLConverter` / PlayTools 构建产物时执行；文档整理或纯 compare/gate 调整不必附带重建；若脚本失败，应先停下汇报，不要改成手写 `xcodebuild`、手工复制产物或其它需要人工介入的替代流程）：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

2. **跨机器硬默认 gate**（每次当前主线改动后都应优先执行，确保 fresh workspace 最小闭环不回退）：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

3. **当前最高优先级的本机离线主线：`ShaderCorpus` 全量批量验证**（当前完成判定必须包含此项；只复用已存在样本，不引入人工准备；若本机没有现成 `ShaderCorpus`，直接退回第 2 步，并在结果里明确说明“本轮未执行 corpus 全量批量验证”）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

4. **当前同样必须覆盖的 full-batch 入口：`ShaderSourceDiagnostics`**（它仍是 failure-path 补充入口，不替代默认 gate，但当前完成判定同样要求这条 full-batch 路径跑通；若本机已有这批样本，默认应在收尾测试里一起跑一遍，而不是只看 success-path）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

5. **定向 blocker 复现 / 单样本 smoke**（仅在修复明确 blocker 时追加，用于更快复现，不替代前面第 2-4 步的批量验证）：

```bash
python3 Scripts/corpus_replay_runner.py --compile --ll <sample.ll>
python3 Scripts/ir_semantics_roundtrip_runner.py --ll <path_to_failure_module.ll> --allow-failures
```

- **当前不纳入日常默认验证**：automation / nightly、`L3` 最小行为验证、重型 live / `.gputrace` 验证；不要再把它们新增为当前收口 gate
- 其它 preset 变体、baseline snapshot 保存/复用、固定输出目录约定，以及“哪些入口只是参考、哪些入口仍不能写成默认 gate”的细节，统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`；主文档只保留当前硬默认入口与最高优先级执行面，避免把旧代表集口径重新暴露回控制面

### 运行时启动验证（`QQ飞车手游`）

若当前改动涉及 runtime replacement 主链路、PlayTools 构建产物，或本轮准备宣称 `SV-003F` 完成，**默认补做本节**。

当前口径：

- 标准构建/安装方式仍是 `./BuildScripts/build_and_install.sh`
- **禁止**手写 `xcodebuild` 替代标准脚本
- 当前目标是确认 `QQ飞车手游` 至少可以启动且不崩溃，不把更重的 live / `.gputrace` 流程写成新的完成 gate
- 若本机缺少可直接复用的 app / 环境，应如实汇报阻塞；不要把人工摆场景、人工登录或额外环境准备写回默认流程

### 真实场景验证（仅资料参考）

仅当用户后续明确要求更重的 live / `.gputrace` 验证时才启用；它不是当前默认 gate，也不是当前完工标准。

当前口径：

- 具体工具、顺序与确认规则统一见 `06-L4-真实场景验证.md`
- 若需要 GUI / Accessibility / 人工登录 / 工作区外修改，**必须先得到用户确认**

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的一个未完成任务执行。每次只允许取一个任务执行。
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新子任务追加到 TODO，再只完成其中**最关键**的一个。单个TODO不宜过长。
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**，禁止擅自在主线新增新的章节。
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## 踩坑与经验

- **compile green 不等于语义等价**
- **不要把“文本完全一样”误当成“语义一样”**；当前默认应以 canonical summary + 风险分级为主
- **先做离线，再做 live**；在当前阶段，live 不是默认主战场
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **当前最重要的是把已采集真实样本尽可能纳入 L1/L2**；只要 `ShaderCorpus` / failure-path 样本还没有被尽可能吃进离线主回路，就不应把主文档继续写成后置行为样本维护
- **主文档不要直接暴露会漂移的本机快照**：本机增强入口、历史批量快照、manifest 描述文字与局部样本数量都应下沉到参考文档，主文档只保留当前主线真正依赖的控制面事实
- **非 preset 的默认输出目录必须避免碰撞**：当前离线路径允许 agent 近同时发起 corpus / diagnostics 等批量运行；默认输出目录若只按秒命名，会导致报告互相覆盖，因此默认目录需要追加唯一后缀
- **L2 compare 需要主动降噪**；更细的降噪对象与风险口径统一见 `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考，当前主线推进**不必须读取**）

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“为什么当前目标收口为现有测试通过，重点是 corpus + diagnostics full-batch 跑绿，并补一个 `QQ飞车手游` 启动不崩 smoke”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；分层模型与止损边界的背景参考，不再代表要继续推进的 `L2/L3 gate` 规划）
- `03-L1-IR-RoundTrip.md`（**建议读取**；当前主线 `SV-003F` 的详细执行参考）
- `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考；保留 compare / risk / gate 报告语义说明，但当前**不再单独作为后续收口里程碑**）
- `05-L3-最小行为测试.md`（资料参考，当前**不纳入规划**）
- `06-L4-真实场景验证.md`（资料参考；仅在需要更重 live / `.gputrace` 验证时再读；当前主线只要求启动 smoke）
- `07-首轮基线与历史进展归档.md`（历史归档与样本名单参考，**不必须读取**）
- `08-当前代表集与Gate契约参考.md`（维护 preset / gate / manifest 细节，或排查 `gate-summary.json` / `preset-manifest.json` 口径不一致时再读；当前主线推进**不必须读取**）

### 背景参考

- `../RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-004-MetallibSourceExtraction.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-005-OfflineReplayBatchCompileDiff.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006d-GenshinRenderingNondeterminism.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006d-RenderingPathDiffReference.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md`（背景参考，**不必须读取**）

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift`
- `Scripts/corpus_replay_runner.py`
- `Scripts/ir_semantics_roundtrip_runner.py`
- `Scripts/ir_canonical_compare.py`
- `Scripts/test_ir_canonical_compare.py`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
- `Scripts/ir_semantics_behavior_runner.py`
- `Scripts/test_ir_semantics_behavior_runner.py`
- `Scripts/metal_compute_behavior_runner.swift`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- `Scripts/runtime_launch_diagnostics_summary.py`
