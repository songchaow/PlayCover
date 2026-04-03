# E-004 历史实现归档：metallib → MSL 源码提取

## 作用

本文档用于承接从 `E-004-MetallibSourceExtraction.md` 主体下沉的历史实现细节：早期架构、阶段性实现说明、已完成子任务的方法论与当时的验证记录。主文档只保留当前能力、当前 blocker 与当前交接点。

> ⚠️ **本文档是 E-004 的历史归档。** 当前 E-004 的日常推进方式已经切换为 **成功路径导出 `ShaderCorpus/` + 离线 replay**；这里保留的是转型前后的实现脉络，用于回看演进过程。

## 历史架构摘要

E-004 的总体链路是：

```text
metallib / wrapper payload
  ↓ 解析与提取
LLVM Bitcode
  ↓ llvm-dis
LLVM IR
  ↓ IRToMSLConverter
MSL
```

随着 Road E 推进，E-004 的关键主线依次发生过两次前移：

1. **从“如何拿到 bitcode / IR”前移到“如何稳定在宿主执行 `llvm-dis`”**
2. **从“如何执行 `llvm-dis`”前移到“如何修正 IR→MSL lowering”**

因此，很多早期在 E-004 中属于主线的实现，今天已经变成了稳定底座。

## E-004a 历史实现要点

### MetallibParser 架构

- `MetallibParser` 作为纯 Swift `struct` 落地，无外部依赖。
- 早期关注点包括：
  - `Header`：解析 MTLB 文件头、平台/版本、四大 section 的 offset/size
  - `FunctionEntry`：解析函数列表中的 tag group，包括 `NAME`、`TYPE`、`HASH`、`MDSZ`、`OFFT`、`VERS`、`SARC`
  - `ExtraSection`：检测 bitcode 之后的额外 section（例如 `SOURCES`）
  - `ParseResult`：统一暴露 `extractBitcode(for:)`、`extractAllBitcode()`、`hasSources` 等能力
- 早期验证主要是：PlayTools xcframework 构建通过、pbxproj 校验通过、解析逻辑能接入 `pc_newLibraryWithData`。

### 真实样本驱动后的补强

- `headerSize=15` 样本证明：`MTLB` magic 并不意味着一定是标准 raw metallib，兼容解析分支是必须的。
- `OFFT` 最终确认不是单个偏移，而是 `(publicMetaOffset, privateMetaOffset, bitcodeOffset)` 三元组。
- `functionList` section 也不是简单的 tag 流，开头先有 `4-byte entryCount`，每个 entry 再以 `4-byte tagGroupSize` 起始。
- 对 `OFFT` / `MDSZ` 等字段，后续统一改成按字节拼装的 `UInt16/32/64` helper，避免未对齐访问崩溃。

## E-004b 历史实现要点

### BitcodeModule 设计

- `BitcodeModule` 的核心价值在于去重：多个函数可能引用同一模块，因此按 `(offset, size)` 分组能避免重复提取、重复反汇编和重复转换。
- 早期引入了 LLVM bitcode magic 校验，支持 wrapper magic `DE C0 17 0B` 与 raw bitstream magic `42 43`。
- `LibrarySourceInjectionService` 侧同时补了 bitcode 缓存与 `ExtractionStats`，用于运行时诊断。

### 为什么后来这部分不再是主线

- 当前已知 wrapper 样本都已能恢复到 `valid_llvm`，提取阶段的基础能力已经足够支撑主线路径。
- 因此对 E-004 来说，bitcode 提取今天更像“稳定底座”，而不是需要继续大幅扩张的工作面。

## E-004c 历史实现要点

### LLVMToolManager 架构

- `LLVMToolManager` 作为 PlayCover 主应用内的单例 `ObservableObject` 落地，负责下载和管理 `llvm-dis`。
- 其设计关注点包括：
  - 固定安装目录：`~/Library/Containers/io.playcover.PlayCover/llvm-tools/`
  - 版本文件与安装状态检测
  - 从 LLVM GitHub Releases 中提取 `llvm-dis`
  - 安装后的可执行权限、ad-hoc codesign 与 `--version` 验证
  - 面向 UI 的状态字段：`isInstalled`、`isDownloading`、`downloadProgress`、`lastError` 等

### 这部分留下来的核心价值

- 它为宿主执行 `llvm-dis` 提供了可控、可验证的工具来源。
- 后续即使 `llvm-dis` 的调用路径从 runtime 转到 host bridge，这部分仍然是 bridge 可用性的前提。

## E-004d 历史实现要点

### LLVMDisassembler 架构

- `LLVMDisassembler` 早期是 PlayTools runtime 中的纯 Swift 反汇编器包装，支持：
  - `findLLVMDis()` 多路径查找 `llvm-dis`
  - bitcode magic 校验
  - `posix_spawn + waitpid` 执行模型
  - batch 反汇编
  - `safeDisassemble()` / `safeDisassembleBatch()` 安全包装
- 错误枚举涵盖 `llvmDisNotFound`、`invalidBitcode`、`processLaunchFailed`、`processTimeout`、`processNonZeroExit` 等。

### 为什么主路径后来切到 host bridge

- PlayTools 是 iOS target，目标 app 又运行在 PlayCover 注入后的 macOS sandbox 中；即使路径正确，runtime 内的 `posix_spawn` 仍会被 `(deny process-fork)` 打回 `Operation not permitted`。
- 因此后来将主路径切换为：PlayTools runtime 发命令 → 宿主 PlayCover 执行 `llvm-dis` → 返回 IR 文本。
- runtime 内的 `posix_spawn` 保留为兼容旧宿主版本或离线诊断 fallback，不再承担 live 主路径责任。

## E-004e 历史实现要点

## E-004e1：IRToMSLConverter 骨架

- 早期 `IRToMSLConverter` 先完成了：
  - `define` 解析
  - shader 类型识别
  - 基础参数列表解析
  - 标量/向量类型映射
  - vertex / fragment / kernel 的 stub MSL 生成
- 当时函数体仍然是默认返回值 stub，主要目标是先把“可落成 MSL 函数签名”的能力建起来。

## E-004e2：addrspace → MSL 地址空间限定符完整映射

- 这一阶段的关键突破是：确认 **Xcode 16 Metal 编译器已 100% 使用 opaque pointer**，精确类型信息必须从 metadata 恢复。
- 因此随后补入：
  - `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 解析
  - `MetadataArgInfo` / `MetadataFuncInfo`
  - `buildParametersFromMetadata()`
  - `generateAllParams()`
  - `PointerInfo` 与结构体 / texture / sampler / builtins 参数发射能力

## E-004e3：`air.*` 内建 → MSL 等效调用映射

- 方法论是：直接从 Metal 编译器实际输出逆向提取 air builtin，而非依赖不存在的公开文档。
- 过程包括：
  - 编写覆盖多个类别 MSL 内建的测试 shader
  - 编译为 AIR
  - 用 `llvm-dis` 反汇编为 IR
  - 提取 `declare @air.*` 声明并归纳命名规律
- 最终沉淀出 air builtin 映射表、分类枚举、查找与解析工具方法，并接入 `convert()` 流水线。

## 历史 E-004e4 拆分为何不再保留在主文档

E-004e4 早期曾按实现形态拆为：

- `e4a`：SSA→MSL 翻译框架 + 基础指令集
- `e4b`：phi 节点 + 多基本块控制流
- `e4c`：`extractvalue` / `insertvalue` + GEP 结构体路径

但 Road E 进入真实 live 样本驱动阶段后，主线不再按这组理论拆分推进，而是按 **diagnostics 暴露出来的 blocker 前移顺序** 演进：

- packed return 误判
- metadata / 参数映射错位
- texture / sampler 形参发射
- struct 字段定义缺失
- vertex aggregate return
- vector 维度收敛
- vertex `stage_in` 映射
- pointer-like SSA 发射
- `undef` / half immediate lowering

因此，旧的 `e4a/e4b/e4c` 划分已经不再适合作为今日主文档的 TODO 结构，只保留在归档里帮助理解演进路径。

## 历史验证记录（归档级别）

E-004 早期与中期阶段曾反复使用以下验证方式：

- `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- `./BuildScripts/build_gui.sh`
- `./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests`
- 离线最小样本：`test_fragment_packed_return`、`test_fast_math_binary`、`test_extractvalue`、`test_addrspace`
- `xcrun --sdk macosx metal -c` 对生成 MSL 做编译验证

这些验证方式今天仍有效，但它们已经从“证明能力是否存在”转为“回归验证当前 lowering 修复是否破坏已有能力”。

## 参考跳转

- 当前主文档：`E-004-MetallibSourceExtraction.md`
- 当前跨任务主线：`00-Dashboard.md`
- 当前跨任务历史归档：`00-Dashboard-Archive.md`
