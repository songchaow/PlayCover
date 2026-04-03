# E-004: 实现 metallib → MSL 源码提取

## 状态：🔄 IN PROGRESS（已拆分）

## 目标

在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR 文本，再**逐指令翻译为语义等价的 MSL 源码**，使其能通过 `makeLibrary(source:)` 编译。

**翻译策略（方案 A：机械翻译）**：每条 IR 指令对应一个 MSL 临时变量赋值语句。不追求还原原始代码风格，但保证语义等价。函数签名由 IR metadata 精确还原。

## 任务拆分

由于工作量较大，E-004 拆分为五个子任务：

| # | 子任务 | 状态 | 说明 |
|---|--------|------|------|
| E-004a | **metallib 二进制格式解析器** | ✅ DONE | `MetallibParser` 已能解析已知 metallib / wrapper 样本并提取 section / function / bitcode 信息 |
| E-004b | **从 MODULE_LIST 提取函数级 LLVM Bitcode** | ✅ DONE | 已完成 bitcode module 提取、去重、缓存与有效性判断 |
| E-004c | **LLVM 工具链管理：下载并部署 `llvm-dis`** | ✅ DONE | 宿主 PlayCover 已具备 LLVM 工具链下载、安装、校验能力 |
| E-004d | **PlayTools 中调用 `llvm-dis` 转换 bitcode → IR** | ✅ DONE | 现以 runtime→host bridge 为主路径，runtime 内 `posix_spawn` 仅保留为兼容 / 诊断 fallback |
| E-004e | **LLVM IR → MSL 转换器** | 🔄 IN PROGRESS | 当前已收敛为真实 live diagnostics 驱动的 lowering 补洞；下一步见 `E-006a2e2` |

### 架构说明

当前主路径已经稳定为：

```text
metallib / wrapper payload
  ↓ E-004a / E-004b
BitcodeModule.data
  ↓ E-004d（主路径：runtime→host bridge）
宿主 PlayCover 执行 llvm-dis
  ↓
LLVM IR 文本
  ↓ E-004e（IRToMSLConverter）
可编译的 MSL 源码
  ↓ E-005
makeLibrary(source:) 重编译并替换原始返回
```

**当前关注点不再是 payload 恢复或 `llvm-dis` 执行权限**，而是 `IRToMSLConverter` 如何继续把 live diagnostics 中暴露出来的 lowering 缺口补齐。

> 详细实现过程、旧架构细节、阶段性验证记录与历史子任务说明已下沉到 [E-004-MetallibSourceExtraction-Archive](E-004-MetallibSourceExtraction-Archive.md)。

## E-004a 实现

- `MetallibParser` 已落地，并能解析 `MTLB` header、function list、public/private metadata 与 bitcode section。
- 对当前已知真实样本，`headerSize=15` 的兼容解析、`OFFT` 三元组语义修正，以及 raw `MTLB` / `xar` / `bplist_keyed_archive` recovered payload 提取均已打通。
- 这部分当前**不是主 blocker**；仅在出现新的未知 wrapper 样本时再回头扩展。

## E-004b 实现

- 已完成 bitcode module 提取与去重：按 `(offset, size)` 合并引用同一模块的函数，避免重复处理。
- 已具备 LLVM bitcode 有效性判断与基础缓存能力，供后续 `llvm-dis` 与聚合重编译复用。
- 当前阶段只需保证提取链路稳定，不再把精力投入到已知样本的重复恢复。

## E-004c 实现

- `LLVMToolManager` 已在宿主 PlayCover 中落地，负责下载、安装、校验和管理 `llvm-dis`。
- 当前对 Road E 的价值主要体现在：为 runtime→host bridge 提供稳定的宿主工具执行环境。
- 工具链管理本身当前已相对稳定，不是主线矛盾。

## E-004d 实现

- `LLVMDisassembler` 已完成，且**主路径已切换为 runtime→host bridge**：PlayTools runtime 发送 `host_disassemble_bitcode` 请求，由宿主进程执行 `llvm-dis`。
- runtime 内的 `posix_spawn` 路径仍保留，但仅用于兼容旧宿主版本或离线诊断，不再作为 live 主路径。
- 这一阶段的核心目标已经达成：主线不再卡在 injected runtime 的 `process-fork` / sandbox 限制上。

## E-004e 实现（持续中）

E-004e 仍是 E-004 的核心，也是当前仍在演进的部分。

| # | 当前结论 | 状态 |
|---|---|---|
| E-004e1–e3 | 骨架、metadata 驱动的类型恢复、`air.*` 内建映射均已完成 | ✅ DONE |
| E-004e4（历史拆分） | 早期的 `e4a/e4b/e4c` 划分已不再能准确反映当前推进方式 | ✅ 已由 live diagnostics 驱动模式替代 |
| 当前推进方式 | 以 `ShaderSourceDiagnostics` 和 live 样本为准，按 blocker 前移顺序逐个补 lowering 缺口 | 🔄 IN PROGRESS |

### 当前已完成能力

- **函数签名恢复**：已能基于 IR metadata 恢复 vertex / fragment / kernel 的参数与返回信息。
- **参数发射**：`buffer`、`texture`、`sampler`、`stage_in`、内置属性等路径已基本打通。
- **`air.*` 映射**：常见 `air.*` 内建到 MSL 的映射已建立并集成到转换流程。
- **返回值与结构体**：packed return、vertex aggregate return、自定义 struct 定义与字段名恢复均已具备基础能力。
- **SSA / pointer 发射**：`stage_in` 参数回接、pointer-like SSA 追踪、`*(&...)` 消除、`device T*` 访问收敛等关键问题已完成一轮 live 验证。

### 当前主 blocker

结合 `00-Dashboard.md` 中最新 `E-006a2e2` 修复，`undef` lowering 与 half immediate lowering 已完成。当前 E-004e 无已知离线 blocker，下一步等待 `E-006a2e3` live 复测后根据新 diagnostics 继续补洞。

### 当前交接方式

- **如果要继续做实现**：直接从 `IRToMSLConverter.swift` 入手，围绕 `undef` 与 half immediate 的 lowering 修复展开。
- **如果动了 IR→MSL 逻辑**：按 `00-Dashboard.md` 的要求补 `test-data/` 样本，并至少执行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`。
- **如果要回看历史修复脉络**：去读 [E-004-MetallibSourceExtraction-Archive](E-004-MetallibSourceExtraction-Archive.md) 与 `00-Dashboard-Archive.md`，不要再把那些历史细节堆回本文主体。

## 参考

- 当前主线、live 样本与跨任务 TODO：`00-Dashboard.md`
- dashboard 历史归档：`00-Dashboard-Archive.md`
- 本文历史实现细节归档：`E-004-MetallibSourceExtraction-Archive.md`
