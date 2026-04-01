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

### 最优策略（运行时 hook）

```
App 调用 makeLibrary(data: metallib_data)
    ↓ hook 拦截
从 metallib_data 的 LLVM Bitcode 恢复 MSL 源码
    ↓
调用 makeLibrary(source: msl_source, options: ...)
    ↓ 替换原始返回值
App 得到包含源码信息的 library
    ↓ 后续截帧
Xcode 自动获取源码 ✅
```

### 关键挑战

**从 metallib 的 LLVM Bitcode → MSL 反编译**（E-004 任务）：
- metallib 的 MODULE_LIST section 包含 LLVM Bitcode
- 需要解析 MTLB 格式提取 bitcode
- 需要将 LLVM IR（含 Metal 地址空间标注）还原为可编译的 MSL
- 这是整个方案最难的部分

### 备选策略

如果 bitcode → MSL 反编译过于困难，可以：
- 直接将 LLVM IR 文本作为"伪源码"传给 Xcode（可读性不如 MSL 但足以调试）
- 在 metallib 二进制中直接注入 SOURCES section（修改 MTLB 格式）
