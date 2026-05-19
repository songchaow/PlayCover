# gputrace 二进制流修改：注入 Shader 源码信息

## 任务目标

修改 `.gputrace` bundle 中的二进制流（MTSP 格式），使 Xcode 在打开 gputrace 时能够显示我们离线准备的 shader 源码（LLVM IR 注释增强的 .metal 文件），**无需运行时干预**。

---

## 背景

### 问题

恋与深空（`com.papegames.lysk`）的大部分 shader 通过 `makeLibrary(data:)` 创建（从预编译的 metallib 加载），Xcode 截帧时**不会为这些 shader 保存源码**。打开 gputrace 后点击 shader 显示 "Shader source not found"。

### 已有成果

1. **运行时 extraction 模式**已实现：能够在 `makeLibrary(data:)` 调用时提取 metallib + bitcode 到 `ShaderDebugInfo/` 目录（154 个 metallib，包含完整的 LLVM bitcode）
2. **离线 IR 反汇编**可用：`llvm-dis` 能将 bitcode 反汇编为可读的 LLVM IR 文本
3. **注入脚本** `scripts/inject_shader_debug_info.py` 能生成 IR 注释增强的 .metal stub 文件并放入 gputrace bundle
4. **gputrace 逆向工程工具** `External/gputrace`（Go 实现）提供了 MTSP 格式的解析能力

### Xcode 的源码显示机制（2026-05-19 验证确认）

#### 核心结论

**Xcode 从 store0 中与 metallib 相邻存储的独立源码文本 blob 读取源码。** 源码不是嵌入在 metallib 二进制内部，也不是 Xcode 从 bitcode 反编译的。

#### store0 数据结构

`store0` 是多段 zlib 压缩流（每段 16KB），解压后 ~50MB。其中存储了：
- **151 个 metallib 二进制**（全部含 LLVM bitcode，入口点均为 `xlatMtlMain`）
- **7 个 metallib 后紧跟独立的源码文本 blob**（不在 metallib file_size 范围内，而是相邻存储的独立数据）
- **144 个 metallib 后无源码 blob**

#### `makeLibrary(source:)` vs `makeLibrary(data:)` 的差异

| 路径 | 截帧时 Xcode 行为 | store0 中的存储 | 源码显示 |
|------|-------------------|-----------------|----------|
| `makeLibrary(source:)` | 保存 metallib + 源码文本 | metallib 后紧跟源码 blob | ✅ 显示源码 |
| `makeLibrary(data:)` | 仅保存 metallib | metallib 后无额外数据 | ❌ "Source not found" |

#### 实验证据

- 替换 sidecar 文件（hex ID 文件）内容 → Xcode 仍显示原始源码 → sidecar 不是源码来源
- 清除所有 GPU Tools 缓存后 → 仍显示源码 → 非缓存问题
- store0 中 metallib `file_size` 字段之后紧跟源码文本，间隔 0 字节 → 源码是独立的附属 blob
- 所有 151 个 metallib 都含 LLVM bitcode，但只有 7 个有源码显示 → Xcode **不从 bitcode 反编译**源码

#### 那 7 个有源码的 shader 是什么

全部是 **Unity 引擎自身通过 `makeLibrary(source:)` 动态编译的 shader**（非 PlayCover 替换生成），包含：
- 2 个 Unity compute shader metallib（Probe/GI 相关，共 ~211 个 `computeMain` 变体）
- 1 个 Unity 内部 clear shader（`clear_vprog` + `clear_fshader`）
- 4 个 Unity HLSLcc 翻译的简单渲染 shader（vertex + fragment）

特征：源码含 `u_xlat0` 等 HLSLcc 变量名（这是 Unity 翻译器的命名风格，不是反编译产物）。

#### 关于 `u_xlat` 变量名

`u_xlat0`、`u_xlati1` 等变量名是 **Unity 的 HLSLcc/SPIRV-Cross 翻译器**将 HLSL 转为 MSL 时自动生成的。它们出现在 `makeLibrary(source:)` 传入的源码中，是 Unity 翻译器的产物，不是 Xcode 反编译的证据。

#### GPU Tools 缓存位置

- `/private/var/folders/.../T/com.apple.gputools.replay/` — replay packets
- `/private/var/folders/.../T/GPUSourceIndexer-*` — source index
- `/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/` — compiled shader cache

---

## 测试样品

- **gputrace**: `/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
- **目标 shader**: `Papegame/SkinMakeupNew`（draw call #863），pipeline address `0x7b12d6000`，hex ID `C8BD90CE2E67E660`
- **对应的 ShaderDebugInfo 条目**: `61F4807E5636D024_28097`（包含 `_MakeupColor1-6`, `_EyebrowColor` 等化妆参数）

---

## gputrace bundle 结构

```
capture_20260518_110050.gputrace/
├── metadata                              # bplist，UUID/设备信息
├── capture                               # MTSP 流，命令录制
├── unsorted-capture                      # capture 的回退版本
├── device-resources-0x7991e1800          # MTSP 流，设备初始化状态
├── unused-device-resources-0x7991e1800   # MTSP 流，未使用的资源（makeLibrary(source:) 的记录在此）
├── delta-device-resources-0x7991e1800    # MTSP 流，增量资源
├── index                                 # xdic 格式，pipeline ID 索引
├── store0                                # 多段 zlib 压缩，含 metallib + 源码 blob
├── startup-*-platform                    # 平台启动数据
├── <HEX_ID>                              # sidecar 文件（辅助/冗余的源码文本或 bplist 编译统计）
├── MTLBuffer-*                           # 缓冲区数据快照
├── MTLTexture-*                          # 纹理数据快照
└── CAMetalLayer-*                        # drawable 索引
```

**store0 内部结构**（解压后 ~50MB）：
- 151 个 metallib 二进制（全部含 LLVM bitcode）
- 其中 7 个 metallib 后紧跟源码文本 blob（来自 `makeLibrary(source:)` 路径）
- metallib 和源码 blob 通过 MTSP 记录中的偏移被引用

**sidecar 文件**（hex ID 命名）：
- 存在约 25 个文本文件和 8 个 bplist 文件
- 它们**不是** Xcode 显示源码的来源（实验证实替换其内容不影响 Xcode 显示）
- 可能是截帧引擎的冗余备份或供"Export Sources"功能使用

---

## MTSP 二进制格式

### 文件头（16 字节）

```
offset 0:  magic     "MTSP" (4 bytes)
offset 4:  version   uint32 LE
offset 8:  size      uint32 LE
offset 12: offset    uint32 LE
```

### 记录流

头部之后是连续的记录。每条记录的结构：

```
[record_size: uint32 LE] [record_data: record_size bytes]
```

`record_data` 内部通过标记字符串区分类型，标记位于数据的前 128 字节内。

### 关键记录类型

| 标记 | 类型 | 含义 | 备注 |
|------|------|------|------|
| `CS\0\0` | CS | 内核提交/函数名 | 含 function address + label 字符串 |
| `CSuwuw` | CSuwuw | 资源创建/设备标签 | 含 device ptr + label (如 "library", "render-pipeline-state") |
| `CUt` | CUt | Pipeline 标识符 | 含 1 个 hex ID（pipeline state 的标识符） |
| `CU<b>Ut` | CU<b>Ut | Library 源码关联 | 含 2 个 hex ID：源码文件名 + 编译统计文件名 |
| `CU<b>t` | CU<b>t | Library 无源码标记 | 含 1 个 hex ID，flags 末位=0 |
| `Ct\0\0` | Ct | Pipeline state 设置 | 含 pipeline addr + function addr + buffer bindings |
| `Ctt\0` | Ctt | Pipeline 创建 | 映射 pipeline addr → function addr |
| `CiSululuiululululbb` | CiS | Buffer 绑定定义 | 含 pipeline addr + buffer name + binding info |
| `CiUul` | CiUul | 编译统计关联 | bplist 文件的引用 |
| `C\0\0\0` | C | 通用命令 | PopDebugGroup 等 |
| `Culul` | Culul | 命令缓冲区标记 | ICB addr + payload |
| `Cuw` | Cuw | Buffer write/update | |

### `CU<b>t` vs `CU<b>Ut` 的差异

| 字段 | CU<b>t（无源码） | CU<b>Ut（有源码） |
|------|-------------------|---------------------|
| record_size | 92 | 108 |
| flags | `0xffffc04e`（bit 0 = 0） | `0xffffc04f`（bit 0 = 1） |
| tag | `CU<b>t\x00\x00` (8 bytes) | `CU<b>Ut\0` (8 bytes) |
| hex IDs | 1 个（pipeline ID） | 2 个（source ID + stats ID） |

### `CSuwuw` + `CU<b>Ut` 记录对（关联源码的完整模板）

**记录 1: CSuwuw "library"（76 字节）**
```
+0x00: record_size = 76 (uint32, 0x4c)
+0x04: flags = 0xffffd007 (uint32)
+0x08: zeros (24 bytes)
+0x20: inner_size = 70 (uint32, 0x46)
+0x24: "CSuwuw\0\0" (8 bytes tag)
+0x2c: device_ptr (uint64)
+0x34: "library\0" (8 bytes label)
+0x3c: library_ptr (uint64)
+0x44: zeros (8 bytes)
+0x4c: END
```

**记录 2: CU<b>Ut（108 字节）**
```
+0x00: record_size = 108 (uint32, 0x6c)
+0x04: flags = 0xffffc04f (uint32)
+0x08: zeros (24 bytes)
+0x20: prefix = 1 (uint32)
+0x24: "CU<b>Ut\0" (8 bytes tag)
+0x2c: device_ptr (uint64)
+0x34: source_hex_id (17 bytes = 16 hex chars + null)
+0x45: stats_hex_id (17 bytes = 16 hex chars + null)
+0x56: zeros (10 bytes)
+0x60: footer_magic = 0x74 (uint32)
+0x64: library_ptr (uint64)
+0x6c: END
```

### CU<b>t 记录布局（92 字节）

```
+0x00: record_size = 92 (uint32, 0x5c)
+0x04: flags = 0xffffc04e (uint32)
+0x08: zeros (24 bytes)
+0x20: prefix = 1 (uint32)
+0x24: "CU<b>t\x00\x00" (8 bytes tag)
+0x2c: device_ptr (uint64)
+0x34: hex_id (16 chars ASCII)
+0x44: null + zeros (12 bytes)
+0x50: footer_magic = 0x74 (uint32)
+0x54: library_ptr (uint64)
+0x5c: END
```

---

## 已尝试的注入方案及结果

所有离线注入方案均**失败**。根本原因是 Xcode 从 store0 中 metallib 旁的源码 blob 读取源码，而非从 sidecar 文件或 MTSP 记录推导。

### 方案 1: 放 sidecar 文件 ❌

在 gputrace bundle 中创建对应 hex ID 的 .metal 文件 → Xcode 不读取。

### 方案 2: 追加 CU<b>Ut 记录 + sidecar ❌

追加 CSuwuw + CU<b>Ut 记录到 `unused-device-resources` + 创建 sidecar → Xcode 不识别追加的记录。

### 方案 3: 原地替换 CUt → CU<b>Ut ❌

记录大小不同（92 vs 108），导致后续偏移错乱，gputrace 损坏。

### 方案 4: Flags bit flip (0x4e → 0x4f) ❌

修改 CU<b>t 的 flags bit 0 → Xcode 行为无变化。

### 方案 5: 尝试修改 store0 中的 metallib（方向已否定）

store0 中的 metallib 已经是完整含 bitcode 版本。Xcode 即使有完整的 bitcode 也不会自动反编译显示源码，它只读取 `makeLibrary(source:)` 路径下截帧引擎保存的源码 blob。

---

## 可行方向（待探索）

### 方向 A: 运行时 hook — 让截帧引擎认为 shader 来自 source 路径

**核心思路**：在截帧前，hook `makeLibrary(data:)` 使其内部通过 `makeLibrary(source:)` 重新编译。这样 Xcode 截帧引擎会同时保存 metallib 和源码到 store0，生成 `CU<b>Ut` 记录。

**本质**：PlayCover 已有的 `shaderSourceReplacementEnabled` 模式已经实现了这个机制——拦截 `makeLibrary(data:)` → 反编译 bitcode → 通过 `makeLibrary(source:)` 重新编译。只要在截帧时启用此模式，Xcode 就能保存源码。

**优势**：从根源解决，Xcode 原生支持。
**挑战**：需要在截帧运行时同时启用替换模式，可能影响渲染稳定性和性能。

### 方向 B: 修改 store0 注入源码 blob

**核心思路**：离线解压 store0，在每个 metallib 后插入对应的源码文本 blob，重新压缩写回。同时更新 MTSP 记录（将 `CU<b>t` 改为 `CU<b>Ut`）。

**挑战**：
1. store0 内部的 blob 偏移被 MTSP 记录引用，插入数据后所有偏移都要更新
2. 需要理解 store0 的 blob 索引/引用机制
3. MTSP 记录的修改需要保持大小不变或更新所有后续偏移

### 方向 C: 利用 Xcode "Import Sources" 功能

**核心思路**：Xcode 的 "Shader source not found" 对话框有 "Import Sources" 按钮。研究这个功能的具体工作方式。

---

## 关键参考文件

| 文件 | 位置 | 说明 |
|------|------|------|
| MTSP 解析器 | `External/gputrace/internal/trace/mtsp.go` | 完整的 MTSP 记录解析实现 |
| Trace 解析入口 | `External/gputrace/internal/trace/trace.go` | gputrace bundle 加载逻辑 |
| Index 解析 | `External/gputrace/internal/trace/index.go` | xdic 索引文件格式 |
| 二进制注入工具 | `scripts/inject_source_records.py` | 构造 CSuwuw+CU<b>Ut 记录并追加 |
| MTSP 分析工具 | `scripts/analyze_reference_gputrace.py` | 逐字节分析 MTSP 记录结构 |
| Stub 源码生成 | `scripts/inject_shader_debug_info.py` | 生成 IR 增强 stub 源码 |
| ShaderDebugInfo | `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/` | 运行时提取的 metallib + bitcode |
| MetallibParser | `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift` | metallib 格式解析器 |
| Shader 提取 | `scripts/extract_shader_raw.py` | 从 store0 中按 library 地址提取 IR |

---

## 数据索引

### SkinMakeupNew shader 的所有已知标识符

| 标识符 | 类型 | 来源 |
|--------|------|------|
| `0x7b12d6000` | Pipeline address | device-resources 中 254 次引用 |
| `C8BD90CE2E67E660` | Pipeline hex ID | device-resources CUt 记录 |
| `61F4807E5636D024_28097` | ShaderDebugInfo cacheKey | extraction 模式提取 |
| `xlatMtlMain` | 函数名（vertex + fragment） | 所有 Unity shader 共用 |
| `_MakeupColor1-6` 等 | Uniform 参数 | IR 中的 metadata |
| `0x7b12cd8c0` | Library pointer | device-resources CU<b>t 记录 |

### device-resources 中的记录统计

| 记录类型 | 数量 | flags | 含义 |
|----------|------|-------|------|
| `CU<b>Ut` (8字节tag) | 3 | `0xffffc04f` | 有源码的 library |
| `CU<b>t` (8字节tag) | 93 | `0xffffc04e` | 无源码的 library |
| `CUt` (4字节tag) | 66 | `0x1001` prefix | pipeline 标识符 |
