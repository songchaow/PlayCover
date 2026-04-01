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

## TODO

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：手动 `-frecord-sources` 重编译单个 metallib 并验证 Xcode 能显示源码** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
|  | 从 QQ飞车 app 包中提取一个 metallib → 用 `xcrun metal` 工具链反编译得到 MSL/IR → 用 `-frecord-sources` 重编译 → 替换回 gputrace → 打开 Xcode 验证 | | |
| E-002 | **调研 `MTLDevice` 创建 Library 的全部 API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
|  | 枚举所有需要 hook 的 ObjC selector（`newLibraryWithData:error:`, `newLibraryWithSource:options:error:`, `newLibraryWithURL:error:` 等），确认运行时类名 | | |
| E-003 | **在 PlayTools 中实现 makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
|  | 参考 `CommandQueueDiscoverySwizzles` 模式，添加 `LibrarySourceInjectionSwizzles` 类，拦截并记录每次 makeLibrary 调用（先 log-only，不修改返回） | | |
| E-004 | **实现 metallib → MSL 源码提取**（已拆分） | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
|  | 在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode（参考 MetalLibraryArchive 格式），生成可读 IR 文本或 MSL 伪源码 | | |
| E-004a | ↳ metallib 二进制格式解析器（MTLB header + section + 函数 tag 解析） | ✅ DONE | |
| E-004b | ↳ 从 MODULE_LIST 提取函数级 LLVM Bitcode | TODO | |
| E-004c | ↳ LLVM Bitcode → 可读文本（MSL 伪源码或 IR） | TODO | |
| E-005 | **实现 MSL 重编译为带源码的 metallib** | TODO | |
|  | 用提取的源码 + `MTLDevice.makeLibrary(source:options:)` 在运行时重编译，生成自带调试信息的 library 并替换返回 | | |
| E-006 | **端到端验证** | TODO | |
|  | 对 QQ飞车 / 原神 启用功能 → 截帧 → Xcode 打开 gputrace → 确认 shader 源码可见 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView | | |

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
