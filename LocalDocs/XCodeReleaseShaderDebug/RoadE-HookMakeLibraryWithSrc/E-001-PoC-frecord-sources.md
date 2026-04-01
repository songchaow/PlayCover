# E-001: 可行性 PoC — `-frecord-sources` 重编译验证

## 状态：✅ DONE

## 目标

验证 `-frecord-sources` 重编译 metallib 后能嵌入 shader 源码，以及运行时 `makeLibrary(source:)` 的可行性。

## 验证脚本

```bash
bash Scripts/poc_e001_frecord_sources.sh
```

## 验证结果

### 1. `-frecord-sources` 确实嵌入源码

| metallib 版本 | 大小 | Sections |
|---|---|---|
| 普通（无 -frecord-sources） | 11,470 bytes | FUNCTION_LIST, PUBLIC_METADATA, PRIVATE_METADATA, MODULE_LIST |
| 带源码（-frecord-sources） | 26,407 bytes | 同上 + **SOURCES** |

- 带源码版本多出一个 **SOURCES** section（0x2975 = 10,613 bytes）
- `strings` 搜索确认嵌入了 `metal_stdlib`、函数名等完整 MSL 源码

### 2. Metal 命令行工具链

```bash
xcrun --sdk macosx metal -c -std=macos-metal2.4 [-frecord-sources -gline-tables-only] -o out.air input.metal
xcrun --sdk macosx metallib -o out.metallib out.air
xcrun --sdk macosx metal-objdump -h/-t/-d out.metallib
```

所有工具均可用，编译流程完整。

### 3. 运行时 API 验证（Apple M4 Pro）

| API | 结果 |
|---|---|
| `makeLibrary(data:)` 加载普通 metallib | ✅ 成功，函数: test_fragment, test_vertex, test_compute |
| `makeLibrary(source:options:)` 从 MSL 编译 | ✅ 成功，函数类型正确（vertex/fragment/kernel） |

### 4. metallib 二进制结构

MTLB header 前 88 字节包含：
- Magic: `MTLB` (offset 0x00)
- 版本、平台信息
- 各 section 的偏移和大小

带源码版本的 `PRIVATE_METADATA` section 也更大（0x027c vs 0x0018），包含源文件路径信息。

## 关键结论

1. **`-frecord-sources` 是有效的**：会在 metallib 中增加 SOURCES section，包含完整的 MSL 源码文本
2. **运行时 API 可行**：`makeLibrary(source:options:)` 可以在运行时从 MSL 源码编译出完整的 shader library
3. **函数签名一致**：无论是从 metallib 加载还是从源码编译，得到的函数名和类型完全相同

## 对 Road E 方案的启示

### 核心策略（运行时 hook + IR→MSL 转换）

```
App 调用 makeLibrary(data: metallib_data)
    ↓ hook 拦截
MetallibParser 提取 LLVM Bitcode
    ↓ llvm-dis
LLVM IR 文本
    ↓ IRToMSLConverter (E-004e)
可编译的 MSL 源码
    ↓ makeLibrary(source: msl_source, options: ...)
App 得到包含源码信息的 library
    ↓ 后续截帧
Xcode 自动获取源码 ✅
```

### 关键挑战

**LLVM IR → MSL 转换**（E-004e 任务）：
- Metal LLVM IR 包含 `addrspace(N)` 标注、`air.*` 系列内建函数等 Metal 特有语义
- 需要将这些映射为 MSL 地址空间限定符（`device`/`constant`/`threadgroup`）和 MSL 内建调用
- 这是整个方案最难的部分，前序步骤 E-004a–d 已为此做好准备

### 注意

- **`-frecord-sources` 不适用于此场景**：该选项仅在从 MSL 编译到 .air 时有效。从现有 metallib 提取的 bitcode 不含源码，无法通过重编译补回
- 必须走 IR→MSL 转换路径，不能绕过
