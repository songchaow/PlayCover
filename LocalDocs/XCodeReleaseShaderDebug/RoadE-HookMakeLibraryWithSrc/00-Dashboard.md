# Road E: Hook makeLibrary 注入 Shader 源码

## 问题背景

外网 Release 包体截帧后，Xcode 打开 `.gputrace` 时大部分 shader 显示 "Shader source not found"，因为 metallib 编译时未嵌入调试信息。PlayCover 已具备对 iOS app 的运行时注入能力（PlayTools via `LC_LOAD_DYLIB`），且已有 `MTLDevice.newCommandQueue` 的 swizzle 先例。

## 最终目标

在 PlayTools 运行时中 hook `MTLDevice.makeLibrary(data:)` 系列 API，从 metallib 中提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR，再**转换为可编译的 MSL 源码**，通过 `makeLibrary(source:)` 重新编译并替换原始返回，使后续截帧的 gputrace 中自动携带可读的 shader 源码。

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
        ├── IRToMSLConverter: 将 LLVM IR 转换为可编译的 MSL 源码
        └── ShaderSourceRecompiler: 调 makeLibrary(source:) 编译 MSL, 替换原始 library
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
| E-004c | ↳ **LLVM 工具链管理：下载并部署 `llvm-dis`** | ✅ DONE | |
|  | `PlayCover/Utils/LLVMToolManager.swift` — 单例管理器，从 GitHub Releases 下载 LLVM 19.1.0 macOS ARM64 预编译包，用 `tar --strip-components=2` 提取 `bin/llvm-dis`，安装到 `~/Library/Containers/io.playcover.PlayCover/llvm-tools/`。支持版本记录、可执行权限设置、ad-hoc 签名、`--version` 验证、进度跟踪（ObservableObject）、卸载 | | |
| E-004d | ↳ **PlayTools 中调用 `llvm-dis` 将 bitcode → LLVM IR 文本** | ✅ DONE | |
|  | `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift` — 纯 Swift struct，使用 `posix_spawn` 调用 `llvm-dis` 将 bitcode 二进制转换为 LLVM IR 文本。支持路径自动发现（LLVMToolManager 安装位置 + Homebrew 路径）、超时控制（默认 30s）、bitcode magic 校验、stderr 捕获、批量处理（`disassembleBatch`）和安全包装（`safeDisassemble`/`safeDisassembleBatch`，失败不中断 hook 流程） | | |
| E-004e | ↳ **LLVM IR → MSL 转换器**（已拆分） | 🔄 IN PROGRESS | |
|  | 实现 IR→MSL 的关键转换：`addrspace` 标注→地址空间限定符（`device`/`constant`/`threadgroup`）、`air.*` 内建→MSL 等效调用、IR 函数签名→MSL 函数声明。前序步骤（E-004a–d）已具备提取 bitcode 并生成 LLVM IR 文本的完整能力，本步骤在此基础上实现 IR 文本到可通过 `makeLibrary(source:)` 编译的 MSL 源码的转换 | | |
| E-004e1 | ↳↳ IRToMSLConverter 骨架 + stub MSL 生成 | ✅ DONE | |
|  | `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` — 纯 Swift struct，从 LLVM IR 文本中解析函数定义（`define` 行）、提取函数名/返回类型/参数列表、识别 addrspace(N) 标注、推断 shader 类型（vertex/fragment/kernel，支持 metallib 元数据和启发式两种方式）。生成带正确 `[[attribute]]` 标注的 stub MSL 源码（函数体为默认返回值）。支持安全包装（`safeConvert`）。已通过 PlayTools xcframework 构建验证 | | |
| E-004e2 | ↳↳ addrspace → MSL 地址空间限定符完整映射 | ✅ DONE | |
| E-004e3 | ↳↳ air.* 内建 → MSL 等效调用映射 | TODO | |
| E-004e4 | ↳↳ 完整函数体转换（IR 指令→MSL 语句） | TODO | |
| E-005 | **运行时 library 替换：用带源码的 library 替换原始返回** | TODO | |
|  | 在 `pc_newLibraryWithData` hook 中，将 E-004e 生成的 MSL 经 `makeLibrary(source:)` 编译后替换原始返回值。需处理：函数签名一致性校验、编译失败 fallback（退回原始 library）、性能优化（缓存已处理的 metallib） | | |
| E-006 | **端到端验证** | TODO | |
|  | 对 QQ飞车 / 原神 启用功能 → 截帧 → Xcode 打开 gputrace → 确认 shader 源码可见 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载/状态 UI | | |

## 踩坑与经验

（由 agent 不断维护，保持简要，详情写子文档）

- **PlayTools 最低部署目标低于 iOS 16**：`Substring.split(separator: StringProtocol, maxSplits:)` 方法仅 iOS 16+ 可用，PlayTools 中需使用 `components(separatedBy:)` 替代
- **`-frecord-sources` 不适用于已有 bitcode**：该选项仅在 `metal -c`（MSL→.air）阶段有效，将 MSL 源码嵌入 .air 中。`metallib` 命令不接受此参数。从现有 metallib 提取的 bitcode 不含源码，无法通过重编译补回。因此**必须走 IR→MSL 转换路径**
- **Metal 编译器调用**：必须用 `xcrun --sdk macosx metal` 方式调用，SDK 选择通过 xcrun 的 `--sdk` 参数完成
- **SOURCES section**：`-frecord-sources` 在 metallib 中新增 `SOURCES` section（约占原体积的 90%+），包含完整 MSL 源码文本
- **运行时编译可行**：`MTLDevice.makeLibrary(source:options:)` 在 Apple M4 Pro 上验证通过，函数签名与从 metallib 加载完全一致
- **Metal AIR 地址空间映射**：Metal 使用 LLVM addrspace(0-6)：0=thread, 1=device, 2=constant, 3=threadgroup, 4=threadgroup_imageblock, 5=ray_data, 6=object_data。`constant` 地址空间在 MSL 中隐含只读语义
- **LLVM 15+ Opaque Pointer**：新版 LLVM 默认使用 `ptr addrspace(N)` 而非 `float addrspace(1)*`，丢失了指向的元素类型信息，需从上下文推断或使用通用字节指针 `uint8_t*`
- **MSL 不支持 double**：LLVM IR 中的 `double` 类型需降级为 MSL `float`
- **MTLDevice 运行时类**：Apple Silicon 上的实际类是 GPU family 层类（如 M4 Pro=`AGXG16SDevice`），swizzle 必须通过 `object_getClass(device)` 动态获取
- **`newLibraryWithData:error:` 参数类型**：ObjC 层实际参数类型是 `dispatch_data_t`（桥接为 `__DispatchData`），不是 `NSData`
- **metallib 格式（MTLB）**：文件头 56 或 88 字节，magic `MTLB`。四大 section：FunctionList、PublicMetadata、PrivateMetadata、Bitcode。函数 Tag 格式详见 E-004 文档
- **dispatch_data_t → Data 转换**：不能直接 `as? Data`，需通过 `DispatchData.enumerateBytes` 逐段拷贝
- **Bitcode 模块去重**：metallib 中多个函数可能共享同一个 bitcode 模块（相同 OFFT+MDSZ），按 (offset, size) 去重可大幅减少处理量
- **LLVM 工具链**：macOS/Xcode 不自带 `llvm-dis`。LLVM 19.1.0 macOS ARM64 预编译包已验证可用
- **PlayTools 是 iOS target**：不能使用 `Foundation.Process`，必须用 `posix_spawn`。`environ`/wait 宏等需特殊处理，详见 E-004d 文档

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
