# E-004: 实现 metallib → MSL 源码提取

## 状态：🔄 IN PROGRESS（已拆分）

## 目标

在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR 文本，再**逐指令翻译为语义等价的 MSL 源码**，使其能通过 `makeLibrary(source:)` 编译。

**翻译策略（方案 A：机械翻译）**：每条 IR 指令对应一个 MSL 临时变量赋值语句。不追求还原原始代码风格，但保证语义等价。函数签名由 IR metadata 精确还原。

## 任务拆分

由于工作量较大，E-004 拆分为五个子任务：

| # | 子任务 | 状态 | 说明 |
|---|--------|------|------|
| E-004a | **metallib 二进制格式解析器** | ✅ DONE | 解析 MTLB header + section 信息 + 函数 tag 元数据 |
| E-004b | **从 MODULE_LIST 提取函数级 LLVM Bitcode** | ✅ DONE | 利用解析器定位每个函数的 bitcode 数据并提取为独立 Data |
| E-004c | **LLVM 工具链管理：下载并部署 `llvm-dis`** | ✅ DONE | PlayCover 主应用中实现 LLVMToolManager，下载 LLVM 预编译包并提取 `llvm-dis` |
| E-004d | **PlayTools 中调用 `llvm-dis` 转换 bitcode → IR** | ✅ DONE | 新增 LLVMDisassembler 类，使用 posix_spawn 调用 llvm-dis，支持路径自动发现、超时、批量处理 |
| E-004e | **LLVM IR → MSL 转换器** | 🔄 IN PROGRESS | 已拆分为 E-004e1–e4 |

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

**核心技术挑战（E-004e）**：这是一个公开领域中没有先例的 Metal AIR → MSL 反编译器。LLVM 生态没有 IR→源码 的通用工具，Apple 也没有公开 AIR 规范。采用逐指令机械翻译——每条 IR 指令都有语义等价的 MSL 写法（`fadd`→`+`、`air.fast_sin`→`sin()`、`shufflevector`→swizzle），因为 MSL 本身就是编译到这些 IR 的源语言。函数签名由 IR metadata（`!air.vertex`/`!air.fragment`/`!air.kernel`）精确还原。

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

## E-004e 实现（已拆分）

E-004e 工作量较大，拆分为子任务：

| # | 子任务 | 状态 | 说明 |
|---|--------|------|------|
| E-004e1 | **IRToMSLConverter 骨架 + stub MSL 生成** | ✅ DONE | 解析 IR 函数定义，生成 stub MSL 源码 |
| E-004e2 | addrspace → MSL 地址空间限定符完整映射 | ✅ DONE | IR metadata 精确还原函数签名 |
| E-004e3 | air.* 内建 → MSL 等效调用映射 | ✅ DONE | 84+ 个 air.* 内建到 MSL 的映射 |
| E-004e4 | **完整函数体转换（逐指令语义等价翻译）** | 🔄 IN PROGRESS | 已拆分为 e4a–e4c |
| E-004e4a | ↳ SSA→MSL 翻译框架 + 基础指令集 | ✅ DONE | 20+ 种 IR 指令翻译，generateFunction 升级 |
| E-004e4b | ↳ phi 节点 + 多基本块控制流 | TODO | **语义等价关键缺陷**，phi/br 需修复 |
| E-004e4c | ↳ extractvalue/insertvalue + GEP 结构体路径 | TODO | **可编译性关键缺陷**，air.sample 返回值拆解 |

### E-004e1: IRToMSLConverter 骨架

#### 新增文件

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` | LLVM IR → MSL 转换器骨架 |

#### IRToMSLConverter 架构

`IRToMSLConverter` 是纯 Swift `struct`，将 LLVM IR 文本转换为可编译的 MSL 源码：

1. **IR 解析**：`parseIRFunctions()` 逐行扫描 `define` 语句，提取：
   - 函数名（支持 `@"quoted.name"` 和 `@plain_name`）
   - 返回类型（处理 linkage/visibility/calling convention 前缀）
   - 参数列表（保持尖括号嵌套平衡的逗号分割）
   - 属性字符串

2. **Shader 类型识别**：`identifyShaderFunctions()` 两阶段策略：
   - 优先使用 MetallibParser 提供的 `functionTypes`（从 metallib TYPE tag 获取）
   - 回退到启发式推断：calling convention（cc75=vertex, cc76=kernel, cc77=fragment）、返回类型特征、函数名关键词
   - 过滤 `llvm.*` 和 `air.*` 内部函数

3. **参数分析**：`parseParameters()` 从 IR 参数中提取：
   - `addrspace(N)` → `AddressSpace` 枚举（device=1, constant=2, threadgroup=3）
   - 参数名（`%name` 或 `%N`）
   - buffer 绑定索引

4. **IR→MSL 类型映射**：`irTypeToMSL()` 处理：
   - 标量：`void`, `float`, `half`, `i32`→`int`, `i1`→`bool` 等
   - 向量：`<4 x float>` → `float4`
   - 结构体和指针 → 退回 shader 类型的默认返回类型

5. **MSL 生成**：`generateMSL()` 为每个 shader 函数生成：
   - vertex: 带 `[[vertex_id]]` 和 buffer 参数
   - fragment: 带 `[[position]]` 输入
   - kernel: 带 `[[thread_position_in_grid]]`
   - 函数体为简单默认返回值（`float4(0.0)` / `void`）
   - 函数名清理为合法 MSL 标识符

6. **安全包装**：`safeConvert()` 失败不中断，返回 nil 并记录日志

#### 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- pbxproj 格式验证通过（`plutil -lint`）
- 文件已正确添加到 PlayTools target 的 Sources build phase

#### 已知限制（后续子任务解决）

- 函数体为 stub（默认返回值），非真实 IR 指令转换
- ~~buffer 参数类型统一为 `device float*`，未从 IR 中精确推断~~ → E-004e2 已解决
- 未处理 `air.*` 内建函数的 MSL 映射
- 未处理复杂结构体返回类型的 MSL 声明

### E-004e2: addrspace → MSL 地址空间限定符完整映射

#### 修改文件

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` | 增强地址空间映射、IR metadata 解析和参数类型推断 |

#### 改进内容

1. **扩展 `AddressSpace` 枚举**：覆盖 Metal AIR 的全部 7 个地址空间（0-6）：
   - `thread`(0)、`device`(1)、`constant`(2)、`threadgroup`(3)
   - `threadgroup_imageblock`(4)、`ray_data`(5)、`object_data`(6)
   - 新增 `isBufferAddressSpace`、`isReadOnly`、`isThreadgroupAddressSpace` 辅助属性

2. **新增 IR Metadata 解析器**（关键改进）：
   - 解析 `!air.vertex`/`!air.fragment`/`!air.kernel` named metadata
   - 从 metadata 中提取精确的参数信息：`air.arg_type_name`（MSL 类型名）、`air.arg_name`（参数名）、`air.location_index`（绑定索引）、`air.address_space`（地址空间）、`air.read`/`air.read_write`（读写属性）
   - 新增 `MetadataArgInfo` / `MetadataFuncInfo` 类型
   - 新增 `parseIRMetadata()` / `parseMetadataFuncNode()` / `parseMetadataArgNode()` 等解析方法

3. **新增 `buildParametersFromMetadata()`**：从 metadata 信息构建精确的 `ParsedParameter` 列表，支持 buffer、texture、sampler、stage_in、内置属性等全部参数种类

4. **新增 `generateAllParams()`**：替代原 `generateBufferParams()`，生成包含所有参数类型的完整声明：
   - buffer: `device T* name [[buffer(N)]]` / `const constant T& name [[buffer(N)]]`
   - threadgroup: `threadgroup T* name [[threadgroup(N)]]`
   - texture: `texture2d<float> name [[texture(N)]]`
   - sampler: `sampler name [[sampler(N)]]`
   - 内置属性: `uint vid [[vertex_id]]`, `uint tid [[thread_position_in_grid]]` 等
   - 结构体引用自动检测: 大写开头类型名用 `&` 引用而非 `*` 指针

5. **其他改进**：
   - `irScalarTypeToMSL()` 公共方法：精确 IR→MSL 标量/向量类型映射
   - `PointerInfo` 结构 + `extractPointerInfo()` 方法：opaque pointer 和 typed pointer 支持
   - `isFullyParsed` 标志：有 metadata 信息的函数标记为 fully parsed
   - `isStructTypeName()` / `cleanTextureTypeName()` 辅助方法

#### 验证

- 编写 5 个测试 MSL shader（vertex/fragment/kernel/多类型/简单 vertex）
- 编译为 AIR 后用 llvm-dis 反汇编为 LLVM IR 文本（309 行）
- 确认地址空间映射正确：addrspace(1)=device, addrspace(2)=constant, addrspace(3)=threadgroup ✅
- 确认 metadata 中包含完整的类型信息：arg_type_name, arg_name, location_index, address_space ✅
- 发现关键事实：Xcode 16 Metal 编译器使用 100% opaque pointer，类型信息仅在 metadata 中
- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- 无 linter 错误

### E-004e3: air.* 内建 → MSL 等效调用映射

#### 修改/新增文件

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` | 新增 air.* 映射表和查询逻辑 |
| `LocalDocs/.../test-data/test_builtins.metal` | 覆盖各类 MSL 内建的测试 shader（9 组） |
| `LocalDocs/.../test-data/test_builtins.ll` | 上述 shader 编译后的完整 LLVM IR（729 行） |
| `LocalDocs/.../test-data/air_declarations.txt` | 从 IR 中提取的 84 个 air.* 声明列表 |

#### 方法论

直接从 Metal 编译器的实际输出逆向提取 air.* 模式，而非依赖（不存在的）公开文档：
1. 编写覆盖 9 大类 MSL 内建函数的测试 shader（纹理采样/读写、同步屏障、数学运算、整数位操作、类型转换、SIMD group、原子操作、片段导数、pack/unpack）
2. 用 `xcrun --sdk macosx metal -c` 编译为 AIR
3. 用 `llvm-dis` 反汇编为 LLVM IR 文本
4. 用 `grep '^declare.*@air\.'` 提取所有 air 内建声明（84 个）
5. 分析命名规则，建立 air→MSL 映射表

#### 新增类型和方法

1. **`AirBuiltinCategory` 枚举**：10 种分类
   - `texture`, `synchronization`, `conversion`, `math`, `integerMath`,
   - `simd`, `atomic`, `fragmentDerivative`, `packUnpack`, `misc`

2. **`AirBuiltinMapping` 结构**：映射条目
   - `airPattern`：air 函数前缀（去掉类型后缀）
   - `mslFunction`：对应的 MSL 函数名
   - `category`、`paramCount`、`isMethodCall`、`description`

3. **`AirBuiltinCall` 结构**：从 IR 提取的调用记录
   - `airFunctionName`（完整名）、`airBaseName`（去后缀名）
   - `mapping`（查到的映射）、`irArguments`（原始参数）、`resultSSA`

4. **`airBuiltinMappings` 静态映射表**：覆盖类别：
   - 数学函数（一元 20 组 fast/non-fast × 2 = 40、二元 16、三元 8、向量 10）
   - 整数位操作（10 个）
   - 类型转换（1 个通用模式 `air.convert`）
   - 同步屏障（2 个）
   - 纹理操作（14 个：sample 6 维度、read 2、write 2、query 4）
   - SIMD group（12 个）
   - 原子操作（22 个：global 11 + local 4）
   - 片段导数（3 个）
   - pack/unpack（8 个）

5. **工具方法**：
   - `airStripTypeSuffix()` — 去掉 `.v4f32`/`.i32` 等类型后缀，特殊处理 `air.convert.*` 和 `air.atomic.*`
   - `lookupAirBuiltin()` — 精确匹配 + 最长前缀匹配
   - `parseAirBuiltinCalls()` — 从 IR 中扫描 `call @air.*` 指令
   - `parseAirConvertTargetType()` — 从 `air.convert.f.v4f32.s.v4i32` 解析目标 MSL 类型 `float4`
   - `airTypeSuffixToMSL()` / `airScalarSuffixToMSL()` — 类型后缀→MSL 类型

6. **集成**：
   - `ParsedShaderFunction.airBuiltinCalls` 字段
   - `convert()` 中新增步骤 3 调用 `parseAirBuiltinCalls()`
   - `ConversionStats` 新增 `airBuiltinCalls`/`mappedAirCalls`/`unmappedAirCalls`
   - 生成的 MSL 中在函数注释中汇总 air 内建映射

#### air.* 命名规则发现

| 规则 | 示例 |
|------|------|
| 类型后缀编码参数类型 | `air.fast_sin.v4f32` → `<4 x float>` 参数 |
| fast-math 使用 `fast_` 前缀 | `air.fast_sin` vs `air.sin` |
| 纹理区分维度 | `air.sample_texture_2d` / `3d` / `cube` / `2d_array` |
| 原子区分 scope + sign | `air.atomic.global.add.u.i32` / `air.atomic.local.add.s.i32` |
| convert 全是类型编码 | `air.convert.f.v4f32.s.v4i32` = int4→float4 |
| 部分函数有额外 bool 参数 | `air.clz.i32(i32, i1)` — 第二个是 undef-on-zero 标志 |

#### 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- 无 linter 错误
- 测试数据：84 个 air 声明全部有对应 MSL 映射或已知模式
- 映射表在 `convert()` 流水线中已集成，统计信息在日志中输出
