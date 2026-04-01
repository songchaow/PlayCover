# E-004: 实现 metallib → MSL 源码提取

## 状态：🔄 IN PROGRESS（已拆分）

## 目标

在运行时拦截到 metallib `Data` 后，提取 LLVM Bitcode（参考 MetalLibraryArchive 格式），生成可读 IR 文本或 MSL 伪源码。

## 任务拆分

由于工作量较大，E-004 拆分为三个子任务：

| # | 子任务 | 状态 | 说明 |
|---|--------|------|------|
| E-004a | **metallib 二进制格式解析器** | ✅ DONE | 解析 MTLB header + section 信息 + 函数 tag 元数据 |
| E-004b | **从 MODULE_LIST 提取函数级 LLVM Bitcode** | ✅ DONE | 利用解析器定位每个函数的 bitcode 数据并提取为独立 Data |
| E-004c | **LLVM Bitcode → 可读文本（MSL 伪源码或 IR）** | TODO | 将 bitcode 转为文本形式供 E-005 重编译使用 |

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
