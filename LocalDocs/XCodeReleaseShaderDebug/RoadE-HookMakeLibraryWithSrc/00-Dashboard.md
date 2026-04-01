# Road E: Hook makeLibrary 注入 Shader 源码

## 问题背景

外网 Release 包体截帧后，Xcode 打开 `.gputrace` 时大部分 shader 显示 "Shader source not found"，因为 metallib 编译时未嵌入调试信息。PlayCover 已具备对 iOS app 的运行时注入能力（PlayTools via `LC_LOAD_DYLIB`），且已有 `MTLDevice.newCommandQueue` 的 swizzle 先例。

## 最终目标

在 PlayTools 运行时中 hook `MTLDevice.makeLibrary(data:)` 系列 API，将 app 加载的每个 metallib **用 `-frecord-sources` 重新编译后替换返回**，使后续截帧的 gputrace 中自动携带可读的 shader 源码。

## Agent 工作流

1. 读取本文档
2. 从 **TODO** 中选取当前最高优先级的 **一个** 未完成任务执行
3. 若发现任务工作量过大或涉及较多子任务，**拆分到 TODO 并只完成其中一个**
4. 执行完毕后更新本文档（任务状态、踩坑经验、参考信息）

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

## 验证方式

**自动判断（脚本）**：gputrace 中 shader 源码以 `[0-9A-F]{16}` 命名的文本文件存在于根目录。统计数量和内容合法性即可判断覆盖率变化。

```bash
# 快速检查：
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神的 hash 文件是 bplist（shader 编译统计），须以 `valid_msl_files`（而非 `source_files`）为准。

**基线数据**：

| 截帧 | valid_msl | index 引用 |
|---|---|---|
| QQ飞车外网 | 3 | 1116 |
| 原神外网 | 0 | 851 |

**人工确认（最终）**：Xcode 打开 gputrace → 选 Draw Call → 查看 Shader 面板是否显示源码而非 "Shader source not found"。此步无法自动化。

## 整体架构

```
PlayCover 主应用 (macOS)
  ├── LLVMToolManager: 下载/管理 LLVM 预编译工具链 (llvm-dis)
  │     → 安装到 ~/Library/Containers/io.playcover.PlayCover/llvm-tools/
  └── PlayTools.framework (注入到 iOS app)
        ├── LibrarySourceInjectionSwizzles: hook makeLibrary 系列 API
        ├── MetallibParser: 解析 metallib, 提取 LLVM Bitcode
        ├── LLVMDisassembler: 调用 llvm-dis 将 bitcode → LLVM IR 文本
        └── ShaderSourceRecompiler: 用 IR 文本作为伪源码, 调 makeLibrary(source:) 重编译
```

**关键设计决策**：PlayCover 管理的 iOS app 运行在 macOS 用户态（非真正 iOS 沙盒），PlayTools 可以 fork/exec 本地二进制。因此 `llvm-dis` 可直接在 PlayTools 运行时中通过 `Process()` 调用。

## TODO

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 MTLDevice Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → 源码提取**（已拆分） | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
| E-004a | ↳ metallib 二进制格式解析器 | ✅ DONE | |
| E-004b | ↳ 提取函数级 LLVM Bitcode | ✅ DONE | |
| E-004c | ↳ **LLVM 工具链管理：下载并部署 `llvm-dis`** | TODO | |
|  | 在 PlayCover 主应用中实现 `LLVMToolManager`：从 GitHub Releases 下载 LLVM 预编译包（macOS ARM64），解压并提取 `llvm-dis` 到 `~/Library/Containers/io.playcover.PlayCover/llvm-tools/`。支持版本检查、断点续传、首次使用时自动提示下载 | | |
| E-004d | ↳ **PlayTools 中调用 `llvm-dis` 将 bitcode → LLVM IR 文本** | TODO | |
|  | 在 PlayTools 运行时中新增 `LLVMDisassembler` 类：将 E-004b 提取的 bitcode 模块写入临时文件，调用 `llvm-dis` 转换为 `.ll` 文本，读取结果。需处理路径发现（从已知安装位置查找 `llvm-dis`）、超时、错误恢复 | | |
| E-004e | ↳ **LLVM IR → 可编译 MSL 的转换/适配** | TODO | |
|  | LLVM IR 文本不能直接传给 `makeLibrary(source:)`。需要：(1) 验证 IR 文本能否直接作为"伪源码"注入 SOURCES section；(2) 若不行，实现 IR→MSL 的关键转换（`addrspace` 标注→地址空间限定符、`air.*` 内建→MSL 等效调用等）；(3) 或者绕过 `makeLibrary(source:)`，直接用 `xcrun metal` 从 IR 重编译为带 `-frecord-sources` 的 metallib | | |
| E-005 | **运行时 library 替换：用带源码的 library 替换原始返回** | TODO | |
|  | 在 `pc_newLibraryWithData` hook 中，将 E-004d/e 生成的带源码 library 替换原始返回值。需处理：函数签名一致性校验、编译失败 fallback（退回原始 library）、性能优化（缓存已处理的 metallib） | | |
| E-006 | **端到端验证** | TODO | |
|  | 对 QQ飞车 / 原神 启用功能 → 截帧 → Xcode 打开 gputrace → 确认 shader 源码可见 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载/状态 UI | | |

## 踩坑与经验

（由 agent 不断维护，保持简要，详情写子文档）

- **Metal 编译器调用**：必须用 `xcrun --sdk macosx metal` 方式调用，不能给 `metal` 传 `-sdk` 参数（它不认识），SDK 选择通过 xcrun 的 `--sdk` 参数完成
- **SOURCES section**：`-frecord-sources` 在 metallib 中新增 `SOURCES` section（约占原体积的 90%+），包含完整 MSL 源码文本
- **PRIVATE_METADATA 变化**：带源码版本的 PRIVATE_METADATA 大幅增长（0x18 → 0x27c），包含源文件路径等调试元数据
- **运行时编译可行**：`MTLDevice.makeLibrary(source:options:)` 在 Apple M4 Pro 上验证通过，函数签名与从 metallib 加载完全一致
- **PoC 脚本**：`Scripts/poc_e001_frecord_sources.sh` 可重复执行，含 Swift 运行时测试
- **MTLDevice 运行时类**：Apple Silicon 上的实际类不是 `MTLDevice`（协议），而是 GPU family 层类（如 M4 Pro=`AGXG16SDevice`），继承链 `AGXGxxSDevice → AGXGxxFamilyDevice → IOGPUMetalDevice → _MTLDevice → NSObject`。swizzle 必须通过 `object_getClass(device)` 动态获取，不能硬编码类名
- **Library 方法分布**：`newLibraryWithData:error:` 等定义在 GPU family 层（`AGXGxxFamilyDevice`），`newLibraryWithURL:error:` 等定义在框架层（`_MTLDevice`），但 `class_getInstanceMethod` 能沿继承链找到，统一用 `object_getClass(device)` 作为 swizzle 目标即可
- **完整 Library API 列表**：MTLDevice 协议共有 11 个 library 相关 required method（含 2 个 dynamic library），详见 [E-002](E-002-MTLDevice-Library-API.md)
- **Swizzle 骨架**：`LibrarySourceInjectionSwizzles` 采用与 `CommandQueueDiscoverySwizzles` 完全一致的模式——私有 `NSObject` 子类持有 `@objc dynamic` 替换方法，通过 `class_addMethod` + `method_exchangeImplementations` 安装到设备类上
- **异步 API 的 hook**：`newLibraryWithSource:options:completionHandler:` 通过包装 `completionHandler` block 记录日志，不阻塞原始回调
- **`newLibraryWithData:error:` 参数类型**：ObjC 层实际参数类型是 `dispatch_data_t`（桥接为 `__DispatchData`），不是 `NSData`；Swift swizzle 方法签名必须用 `__DispatchData` 才能正确交换
- **metallib 格式（MTLB）**：文件头通常 56 或 88 字节，magic 为 `MTLB` (0x4D544C42 LE)。四大 section：FunctionList（函数 tag 元数据）、PublicMetadata、PrivateMetadata、Bitcode（LLVM IR）
- **函数 Tag 格式**：每个函数由 `[4B tag_name][2B size][payload]...ENDT` 序列描述。关键 tag：NAME（函数名）、TYPE（vertex/fragment/kernel）、MDSZ（bitcode 大小）、OFFT（bitcode 偏移）、HASH（SHA256）。SARC tag 特殊，用 4B size
- **dispatch_data_t → Data 转换**：不能直接 `as? Data`，需通过 `DispatchData.enumerateBytes` 逐段拷贝收集，因为 dispatch_data 可能是不连续的内存区域
- **SOURCES section**：`-frecord-sources` 编译的 metallib 在四大 section 之后追加 SOURCES section，可能是 bzip2 压缩或纯文本 MSL 源码
- **Bitcode 模块去重**：metallib 中多个函数可能共享同一个 bitcode 模块（相同 OFFT+MDSZ），提取时按 (offset, size) 去重可大幅减少后续处理量
- **LLVM Bitcode magic**：提取的 bitcode 模块以 `DE C0 17 0B`（wrapper）或 `42 43`（"BC"，raw bitstream）开头即为有效 LLVM bitcode，可用此做快速校验
- **dispatch_data_t 转换**：从 `__DispatchData` 转换为 `Data` 的逻辑被抽取为 `MetallibParser.convertDispatchData()` 公共方法，消除了多处重复代码
- **LLVM 工具链**：macOS/Xcode 不自带 `llvm-dis`（Xcode 的 Metal 工具链只有 `air-*`/`metal-*` 系列）。需从 LLVM 官方 GitHub Releases 下载预编译包。已确认 LLVM 19.1.0 macOS ARM64 包可用：`LLVM-19.1.0-macOS-ARM64.tar.xz`（~1.4GB），包含完整工具链。只需解压提取 `bin/llvm-dis` 即可
- **PlayTools 可执行外部命令**：PlayCover 管理的 iOS app 运行在 macOS 用户态（翻译执行），不受 iOS 沙盒限制，PlayTools 中可以使用 `Process()` / `posix_spawn` 调用本地二进制

## 参考信息

| 主题 | 位置 |
|---|---|
| 前期调研（5条路线评估） | `../Research/05-可行性评估与路线图.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| gputrace 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| 现有逆向工具 | `../Research/04-现有逆向工具.md` |
| PlayTools swizzle 模板 | `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` — `CommandQueueDiscoverySwizzles` |
| PlayTools DYLD_INTERPOSE 模板 | `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` |
| PlaySettings 数据模型 | `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` — `AppSettingsData` |
| 已有 Metal hook | 仅 `newCommandQueue` / `newCommandQueueWithMaxCommandBufferCount:`，无 Library/Pipeline 相关 hook |
| MetalLibraryArchive（metallib 解析） | https://github.com/YuAo/MetalLibraryArchive |
| applegpu（GPU ISA 反汇编） | https://github.com/dougallj/applegpu |
| metallib 逆向分析 | https://worthdoingbadly.com/metalbitcode/ |
| Apple metallibdsym 文档 | https://developer.apple.com/documentation/metal/generating-and-loading-a-metal-library-symbol-file |
| LLVM 预编译下载 | https://github.com/llvm/llvm-project/releases （19.1.0 macOS ARM64 已验证可用） |
| PlayCover 外部命令封装 | `PlayCover/Utils/Shell.swift` — `Process()` 封装 |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` — 见 `PlayTools.swift` |
