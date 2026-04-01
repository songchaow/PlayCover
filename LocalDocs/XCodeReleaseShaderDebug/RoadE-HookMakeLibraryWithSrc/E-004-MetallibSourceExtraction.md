# E-004: 实现 metallib → MSL 源码提取

## 状态：🔄 IN PROGRESS（已拆分）

## 目标

在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR 文本，再转换为可通过 `makeLibrary(source:)` 编译的 MSL 源码。

## 任务拆分

由于工作量较大，E-004 拆分为五个子任务：

| # | 子任务 | 状态 | 说明 |
|---|--------|------|------|
| E-004a | **metallib 二进制格式解析器** | ✅ DONE | 解析 MTLB header + section 信息 + 函数 tag 元数据 |
| E-004b | **从 MODULE_LIST 提取函数级 LLVM Bitcode** | ✅ DONE | 利用解析器定位每个函数的 bitcode 数据并提取为独立 Data |
| E-004c | **LLVM 工具链管理：下载并部署 `llvm-dis`** | ✅ DONE | PlayCover 主应用中实现 LLVMToolManager，下载 LLVM 预编译包并提取 `llvm-dis` |
| E-004d | **PlayTools 中调用 `llvm-dis` 转换 bitcode → IR** | ✅ DONE | 新增 LLVMDisassembler 类，使用 posix_spawn 调用 llvm-dis，支持路径自动发现、超时、批量处理 |
| E-004e | **LLVM IR → MSL 转换器** | TODO | 实现 IR→MSL 关键转换（addrspace→地址空间限定符、air.*内建→MSL调用、IR函数签名→MSL声明），先做真实游戏 metallib 的 IR 样本分析 |

### 架构说明

原方案试图在 PlayTools 内部纯代码实现 bitcode 反编译（受限于运行时无 LLVM 库）。新方案改为**下载 LLVM 预编译工具链**，利用 `llvm-dis` 完成 bitcode → LLVM IR 文本的完整转换，再实现 IR→MSL 的关键转换：

```
E-004b 提取的 BitcodeModule.data (LLVM Bitcode 二进制)
    ↓ 写入临时 .bc 文件
llvm-dis input.bc -o output.ll  (外部进程调用)
    ↓ 读取 .ll 文件
LLVM IR 文本 (完整的人类可读 IR, 包含函数签名/指令/元数据)
    ↓ E-004e: IRToMSLConverter
可编译的 MSL 源码 (addrspace→device/constant, air.*→MSL内建, ...)
    ↓ E-005: makeLibrary(source:)
带源码信息的 MTLLibrary (替换原始返回值)
```

**核心技术挑战（E-004e）**：Metal LLVM IR 中的 `addrspace(N)` 标注需映射到 MSL 地址空间限定符，`air.*` 系列内建函数需映射到 MSL 等效调用。这是 IR→MSL 转换的关键。前序步骤 E-004a–d 已具备完整的 bitcode 提取和 IR 反汇编能力，为此奠定了基础。

## E-004a 实现

### 新增文件

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift` | metallib 二进制格式解析器 |
| `Carthage/Checkouts/PlayTools/PlayTools.xcodeproj/project.pbxproj` | 添加新文件引用 |
| `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift` | 在 `pc_newLibraryWithData` 中集成解析调用 |

### MetallibParser 架构

`MetallibParser` 是一个纯 Swift `struct`，无外部依赖：

1. **`Header`** — 解析 MTLB 文件头（88 字节），提取：
   - magic, platform, version, fileSize
   - 四大 section 的 offset + size：FunctionList, PublicMetadata, PrivateMetadata, Bitcode

2. **`FunctionEntry`** — 解析函数列表中的 tag group：
   - 每个函数由一系列 tag 组成（NAME, TYPE, HASH, MDSZ, OFFT, VERS...），以 ENDT 结束
   - 支持 SARC tag（4 字节大小字段）
   - 提取：函数名、类型、bitcode 偏移/大小、hash

3. **`ExtraSection`** — 检测 bitcode section 之后的额外 section（如 `-frecord-sources` 生成的 SOURCES section）

4. **`ParseResult`** — 聚合解析结果，提供：
   - `extractBitcode(for:)` — 提取指定函数的 bitcode 数据
   - `extractAllBitcode()` — 提取所有函数的 bitcode
   - `hasSources` — 是否包含 SOURCES section
   - `summary` — 人类可读的摘要

5. **安全集成** — `safeParseAndLog()` 方法确保解析失败不会中断 library 创建流程

### metallib 二进制格式参考

```
Offset  Size   Field
0x00    4      Magic: "MTLB" (0x4D544C42 LE)
0x04    4      Platform & Version
0x08    4      OS Version
0x0C    2      Header Size (常见: 0x38 或 0x58)
0x0E    1      File Type (0x00=executable, 0x02=dynamic)
0x0F    1      Target Platform
0x10    8      File Size
0x18    8      Function List Offset
0x20    8      Function List Size
0x28    8      Public Metadata Offset
0x30    8      Public Metadata Size
0x38    8      Private Metadata Offset (扩展 header)
0x40    8      Private Metadata Size (扩展 header)
0x48    8      Bitcode Offset (扩展 header)
0x50    8      Bitcode Size (扩展 header)
```

函数 Tag 格式：
```
[4B tag_name][2B payload_size][payload_size bytes payload]...
[ENDT]
```

常见 tag：NAME, TYPE, HASH, MDSZ (bitcode size), OFFT (bitcode offset), VERS, SARC (4B size)

### 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- pbxproj 格式验证通过（`plutil -lint`）
- 解析功能已集成到 `pc_newLibraryWithData` swizzle hook 中
- 运行时验证需在实际 app 上测试（下一个 agent 可完成）

## E-004b 实现

### 新增/修改文件

| 文件 | 变更 |
|------|------|
| `MetallibParser.swift` | 新增 `BitcodeModule` 类型、`extractBitcodeModules()` 方法、`safeExtractBitcodeModules()` 方法、`convertDispatchData()` 公共方法 |
| `LibrarySourceInjectionSwizzles.swift` | 在 `LibrarySourceInjectionService` 中新增 bitcode 缓存、`extractAndCacheBitcodeModules()` 方法；更新 `pc_newLibraryWithData` hook 调用提取逻辑 |

### BitcodeModule 设计

`BitcodeModule` 表示一个去重后的 LLVM bitcode 模块：

- **去重逻辑**：多个函数可能引用同一个 bitcode 模块（相同的 OFFT+MDSZ）。`extractBitcodeModules()` 按 `(offset, size)` 分组，合并引用同一模块的函数名，避免重复提取和后续重复处理。
- **LLVM 验证**：`isValidLLVMBitcode` 检查数据前缀是否为 LLVM bitcode wrapper magic (`DE C0 17 0B`) 或 raw bitstream magic (`42 43` = "BC")。
- **元数据**：每个模块记录相对偏移、大小、引用的函数名列表和函数类型列表。

### LibrarySourceInjectionService 缓存

- **缓存 key**：使用 metallib 数据前 32 字节 + 尾 16 字节 + 数据大小计算快速 hash，避免对大 metallib 进行完整 SHA256。
- **跳过已有 SOURCES**：如果 metallib 已包含 SOURCES section（已用 `-frecord-sources` 编译），自动跳过。
- **ExtractionStats**：记录处理统计（总 metallib 数、模块数、有效 LLVM 数、缓存命中数等），用于运行时诊断。

### 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- 无 lint 错误
- Hook 已从 log-only（`safeParseAndLog`）升级为实际提取（`extractAndCacheBitcodeModules`）
- 运行时验证需在实际 app 上测试

## E-004c 实现

### 新增文件

| 文件 | 说明 |
|------|------|
| `PlayCover/Utils/LLVMToolManager.swift` | LLVM 工具链下载/管理器（PlayCover 主应用 target） |

### LLVMToolManager 架构

`LLVMToolManager` 是 PlayCover 主应用中的单例 `ObservableObject`，负责下载和管理 `llvm-dis` 二进制：

1. **路径约定**：
   - 安装目录：`~/Library/Containers/io.playcover.PlayCover/llvm-tools/`
   - 二进制：`llvm-tools/llvm-dis`
   - 版本文件：`llvm-tools/.llvm-version`

2. **下载源**：LLVM GitHub Releases `LLVM-19.1.0-macOS-ARM64.tar.xz`（~1.4GB）

3. **提取策略**：使用 `tar xf --strip-components=2` 从压缩包中只提取 `bin/llvm-dis`，避免解压完整包

4. **安装流程**：
   ```
   下载 tar.xz → 解压提取 llvm-dis → 移动到目标路径 →
   设置 0o755 权限 → ad-hoc codesign → --version 验证 → 写入版本文件
   ```

5. **Published 状态**：`isInstalled`、`installedVersion`、`isDownloading`、`downloadProgress`、`statusMessage`、`lastError` — 供 UI 绑定

6. **API**：
   - `refreshInstallStatus()` — 检查 llvm-dis 是否已安装
   - `install(version:)` — 异步下载并安装
   - `uninstall()` — 删除工具目录

7. **错误处理**：`LLVMToolError` 枚举覆盖下载失败、超时、提取失败、二进制缺失、验证失败

### 验证

- PlayCover GUI 构建通过（`BUILD SUCCEEDED`）
- pbxproj 格式验证通过（`plutil -lint`）
- 文件已正确添加到 PlayCover target 的 Utils group 和 Sources build phase

## E-004d 实现

### 新增文件

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift` | LLVM bitcode → IR 文本反汇编器 |

### LLVMDisassembler 架构

`LLVMDisassembler` 是 PlayTools 运行时中的纯 Swift `struct`，负责将 LLVM Bitcode 二进制数据反汇编为 LLVM IR 文本：

1. **路径发现**：`findLLVMDis()` 按优先级搜索已知安装路径：
   - LLVMToolManager 安装位置：`~/Library/Containers/io.playcover.PlayCover/llvm-tools/llvm-dis`
   - Homebrew ARM: `/opt/homebrew/bin/llvm-dis`
   - Homebrew x86: `/usr/local/bin/llvm-dis`
   - 系统路径: `/usr/bin/llvm-dis`

2. **进程管理**：使用 `posix_spawn` + `waitpid`（非 `Foundation.Process`），因为 PlayTools 是 iOS target：
   - `posix_spawn` 启动子进程
   - `posix_spawn_file_actions_t` 重定向 stderr 到管道、stdout 到 /dev/null
   - `waitpid` + `WNOHANG` 轮询实现超时等待

3. **反汇编流程**：
   ```
   BitcodeModule.data
     ↓ 校验 LLVM bitcode magic (DE C0 17 0B / 42 43)
     ↓ 写入临时文件 /tmp/playtools-llvm-{uuid}/input.bc
     ↓ posix_spawn("llvm-dis", "input.bc", "-o", "output.ll")
     ↓ waitpid 超时等待 (默认 30s)
     ↓ 读取 output.ll
   DisassemblyResult { irText, functionNames, elapsed, inputSize, outputSize }
   ```

4. **批量处理**：`disassembleBatch()` 依次处理多个模块，单个失败不中断批次

5. **安全包装**：`safeDisassemble()` / `safeDisassembleBatch()` 将失败降级为日志，供 hook 流程中调用时不会中断 library 创建

6. **错误类型**：`DisassemblerError` 枚举覆盖：
   - `llvmDisNotFound` — 所有已知路径均未找到
   - `invalidBitcode` — bitcode magic 校验失败
   - `processLaunchFailed` — posix_spawn 失败
   - `processTimeout` — 等待超时
   - `processNonZeroExit` — llvm-dis 返回非零退出码（附 stderr）
   - `outputFileNotFound` / `outputReadFailed` — 输出文件问题

### 关键技术决策

- **为什么用 `posix_spawn` 而非 `Foundation.Process`**：PlayTools 编译为 iOS target（arm64-apple-ios），iOS SDK 不暴露 `NSTask`/`Process` 类。尽管运行时在 macOS 用户态，编译期受 SDK 约束
- **为什么用 `dlsym` 获取 `environ`**：iOS SDK 不直接将 C 全局变量 `environ` 暴露给 Swift，通过 `dlsym(RTLD_DEFAULT, "environ")` 动态获取是最可靠方式
- **为什么手动实现 wait 宏**：`WIFEXITED`/`WEXITSTATUS` 等是 C 宏，Swift 编译器不导入宏，需用等价位操作替代

### 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- pbxproj 格式验证通过（`plutil -lint`）
- 文件已正确添加到 PlayTools target 的 Sources build phase
- 运行时验证需在实际 app 上测试（需 llvm-dis 已安装）
