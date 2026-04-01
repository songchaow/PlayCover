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
| E-001 | **可行性 PoC：手动 `-frecord-sources` 重编译单个 metallib 并验证 Xcode 能显示源码** | TODO | |
|  | 从 QQ飞车 app 包中提取一个 metallib → 用 `xcrun metal` 工具链反编译得到 MSL/IR → 用 `-frecord-sources` 重编译 → 替换回 gputrace → 打开 Xcode 验证 | | |
| E-002 | **调研 `MTLDevice` 创建 Library 的全部 API 入口** | TODO | |
|  | 枚举所有需要 hook 的 ObjC selector（`newLibraryWithData:error:`, `newLibraryWithSource:options:error:`, `newLibraryWithURL:error:` 等），确认运行时类名 | | |
| E-003 | **在 PlayTools 中实现 makeLibrary swizzle 骨架** | TODO | |
|  | 参考 `CommandQueueDiscoverySwizzles` 模式，添加 `LibrarySourceInjectionSwizzles` 类，拦截并记录每次 makeLibrary 调用（先 log-only，不修改返回） | | |
| E-004 | **实现 metallib → MSL 源码提取** | TODO | |
|  | 在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode（参考 MetalLibraryArchive 格式），生成可读 IR 文本或 MSL 伪源码 | | |
| E-005 | **实现 MSL 重编译为带源码的 metallib** | TODO | |
|  | 用提取的源码 + `MTLDevice.makeLibrary(source:options:)` 在运行时重编译，生成自带调试信息的 library 并替换返回 | | |
| E-006 | **端到端验证** | TODO | |
|  | 对 QQ飞车 / 原神 启用功能 → 截帧 → Xcode 打开 gputrace → 确认 shader 源码可见 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView | | |

## 踩坑与经验

（由 agent 不断维护，保持简要，详情写子文档）

_暂无_

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
