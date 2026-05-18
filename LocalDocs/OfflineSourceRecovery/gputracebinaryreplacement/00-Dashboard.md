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

### Xcode 的源码显示机制（已验证 2026-05-18 17:04）

**核心发现：Xcode 从 metallib 的 bitcode 反编译源码，不是从 sidecar 文件读取！**

#### 对于 `makeLibrary(source:)` 路径：
1. 编译时源码被嵌入 metallib 的 bitcode section（AIR bitcode）
2. Xcode 截帧引擎将 metallib 保存到 gputrace bundle
3. Xcode 打开时从 metallib bitcode **反编译**回 Metal 源码（变量名如 `u_xlat0` 是自动生成的）
4. Sidecar 文件（hex ID 命名的 .metal 文件）可能只是辅助/备份，**不是主要源码来源**
5. `CU<b>Ut` 和 `CiUul` 记录建立 pipeline → library → stats 的关联

#### 对于 `makeLibrary(data:)` 路径：
- metallib 是预编译的，可能**不包含可反编译的 bitcode**
- 因此 Xcode 无法恢复源码 → 显示 "Shader source not found"

#### 实验证据：
- 替换 sidecar 文件内容 → Xcode 仍显示原始源码（从 metallib 反编译的）
- 清除所有 GPU Tools 缓存后 → Xcode 仍显示原始源码
- 修改 MTSP 中 CU<b>Ut 的 source_id → Xcode 仍显示原始源码
- 追加新的 CU<b>Ut 记录 → 不被 Xcode 识别
- `CalcLighting.CSMain` 显示的源码含 `u_xlat0` 等自动生成的变量名，证实是反编译产物

#### GPU Tools 缓存位置：
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
├── device-resources-0x7991e1800          # MTSP 流，设备初始化状态（含 MTLB 引用）
├── unused-device-resources-0x7991e1800   # MTSP 流，未使用的资源（makeLibrary(source:) 的记录在此）
├── delta-device-resources-0x7991e1800    # MTSP 流，增量资源
├── index                                 # xdic 格式，pipeline ID 索引
├── store0                                # zlib 压缩数据
├── startup-*-platform                    # 平台启动数据
├── <HEX_ID>                              # sidecar 文件（源码文本或 bplist 编译统计）
├── MTLBuffer-*                           # 缓冲区数据快照
├── MTLTexture-*                          # 纹理数据快照
└── CAMetalLayer-*                        # drawable 索引
```

**关键 sidecar 文件统计**：
- 23 个纯文本 .metal 源码（`#include <metal_stdlib>` 开头）— 来自 `makeLibrary(source:)` 的 compute shader
- 8 个 bplist 编译统计（NSKeyedArchiver 格式）— 包含指令计数、寄存器使用、LLVM Remarks
- 所有 31 个文件的 hex ID 仅在 `unused-device-resources` 和 `index` 中被引用

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
| `Ct\0\0` | Ct | Pipeline state 设置 | 含 pipeline addr + function addr + buffer bindings |
| `Ctt\0` | Ctt | Pipeline 创建 | 映射 pipeline addr → function addr |
| `CiSululuiululululbb` | CiS | Buffer 绑定定义 | 含 pipeline addr + buffer name + binding info |
| `CiUul` | CiUul | 编译统计关联 | bplist 文件的引用 |
| `C\0\0\0` | C | 通用命令 | PopDebugGroup 等 |
| `Culul` | Culul | 命令缓冲区标记 | ICB addr + payload |
| `Cuw` | Cuw | Buffer write/update | |

### `CSuwuw` + `CU<b>Ut` 记录对（关联源码的完整模板）

一个成功关联源码的 library 由两条连续记录组成：

**记录 1: CSuwuw "library"（70 字节 data）**
```
offset 0: 46 00 00 00          record_size = 70
offset 4: 43 53 75 77 75 77 00 00 00   "CSuwuw\0\0\0" (9 bytes tag)
offset 13: xx xx xx xx xx xx xx xx      device_ptr (8 bytes LE, e.g. 0x7991e1800)
offset 21: 6c 69 62 72 61 72 79 00     "library\0" (8 bytes)
offset 29: xx xx xx xx xx xx xx xx      library_ptr (8 bytes LE)
offset 37: 00 00 00 00 00 00 00 00     zeros (8 bytes)
offset 45: 6c 00 00 00                  footer value
offset 49: 4f c0 ff ff                  footer value
offset 53: 00 * 17 bytes               zeros padding
```

**记录 2: CU<b>Ut（源码+编译统计关联）**
```
offset 0: 01 00 00 00                  type/flag = 1
offset 4: 43 55 3c 62 3e 55 74 00     "CU<b>Ut\0" (8 bytes tag)  
offset 12: xx xx xx xx xx xx xx xx     device_ptr (8 bytes LE, same as above)
offset 20: <source_hex_id>\0           源码文件名 (17 bytes, 16 char hex + null)
offset 37: <stats_hex_id>\0            编译统计文件名 (17 bytes, 16 char hex + null)
offset 54: 00 * 6 bytes               zeros padding
offset 60: 74 00 00 00                 footer value
offset 64: xx xx xx xx xx xx xx xx     library_ptr (8 bytes LE)
offset 72: 3c 00 00 00                 footer value
offset 76: 39 d8 ff ff                 footer value
offset 80: 00 * 10+ bytes             zeros padding
```

后续还有其他尾随记录（C 通用命令、CS 函数名等）。

### CUt 记录（device-resources 中，仅标识符）

SkinMakeupNew pipeline 在 `device-resources` 中的记录：

```
offset 0x123be0:
  01 10 00 00              type/flag = 0x1001 (不同于 CU<b>Ut 的 0x01!)
  43 55 74 00              "CUt\0" (4 bytes tag)
  00 18 1e 99 07 00 00 00  device_ptr = 0x7991e1800
  43 38 42 44 39 30 43 45  "C8BD90CE2E67E660"
  32 45 36 37 45 36 36 30
  00                       null terminator
  00 * padding
  74 00 00 00              footer
  00 60 2d b1 07 00 00 00  pipeline_ptr = 0x7b12d6000
  8c 00 00 00 10 d0 ff ff  more footer data
  ...
```

**关键差异**：
- `CUt` prefix 是 `01 10 00 00`，`CU<b>Ut` prefix 是 `01 00 00 00`
- `CUt` 只有 1 个 hex ID（pipeline 标识符），`CU<b>Ut` 有 2 个（源码 + 编译统计）
- `CUt` tag 是 4 字节，`CU<b>Ut` tag 是 8 字节

---

## 已尝试的方案及结果

### 方案 1: 直接放 sidecar 文件（❌ 不生效）

**操作**：在 gputrace bundle 中创建 `C8BD90CE2E67E660` 文件，内容为 IR 注释增强的 .metal 源码。

**结果**：Xcode 仍显示 "Shader source not found"。文件存在但 Xcode 不读取它。

**原因**：Xcode 不是通过文件名查找源码，而是通过 MTSP 流中的 `CU<b>Ut` 记录。`makeLibrary(data:)` 路径没有生成 `CU<b>Ut` 记录。

### 方案 2: 追加 `CU<b>Ut` 记录到 `unused-device-resources`（❌ 不生效）

**操作**：从已有工作记录对克隆一份 CSuwuw + CU<b>Ut 字节，替换 hex ID 为 `C8BD90CE2E67E660`，追加到 `unused-device-resources` 文件末尾。

**结果**：Xcode 打开 gputrace 正常，但 SkinMakeupNew 仍无源码。

**原因分析**：
1. 追加到文件末尾可能超出了 MTSP header 中声明的 size/offset 范围，Xcode 不解析超出部分
2. library 指针（`0x79e46f680`）复制自另一个 library，和 SkinMakeupNew pipeline 实际使用的 library 不匹配
3. `unused-device-resources` 中的记录可能只对 `makeLibrary(source:)` 路径的 library 生效

### 方案 3: 原地替换 `device-resources` 中的 `CUt` 为 `CU<b>Ut`（❌ 导致 gputrace 损坏）

**操作**：在 `device-resources` offset `0x123be0` 处，将 92 字节的 `CUt` 记录原地替换为 `CU<b>Ut` 格式（tag 从 3 字节变成 6 字节，增加第二个 hex ID）。

**结果**：Xcode 卡在加载页面，replay 按钮灰色不可用，gputrace 完全无法解析。

**原因**：
1. `CUt` tag 是 4 字节（`CUt\0`），`CU<b>Ut` tag 是 8 字节（`CU<b>Ut\0`）。虽然总空间足够，但**内部字段偏移全部变了**
2. 记录的 prefix 从 `01 10 00 00` 改为 `01 00 00 00`，含义可能不同
3. footer 中的偏移/指针值被打乱，导致后续所有记录解析失败
4. **恢复方法**：从 `.bak` 备份复制回原文件即可

---

## ❌ 方案 4: 追加/修改 MTSP 记录 + sidecar 文件（2026-05-18，失败）

### 结论：Xcode 不从 sidecar 文件读取源码

**实验**：
1. 追加 CSuwuw + CU<b>Ut 到 unused-device-resources → Xcode 不识别
2. 原地替换 CU<b>Ut 的 source_id → Xcode 仍显示旧源码
3. 直接替换已有 sidecar 文件内容（AED3C8F89AA20821）→ Xcode 仍显示原始源码
4. 清除所有已知 GPU Tools 缓存后重试 → 仍然无效

**决定性证据**：`AED3C8F89AA20821` 当前内容为 694 字节的注入测试文件（含 `★ INJECTION SUCCESS ★` 标记），但 Xcode 显示的是完全不同的、含 `_LightBoxs[50]` 的长源码。该长源码**不存在于任何 sidecar 文件中**。

**真正的源码显示机制**：Xcode 从 metallib 内嵌的 LLVM bitcode 反编译出源码，sidecar 文件只是辅助/导出用途。
- `makeLibrary(source:)` 编译时将源码嵌入 bitcode → Xcode 能反编译 → 显示源码
- `makeLibrary(data:)` 的 metallib 也可能含 bitcode（ShaderDebugInfo 证实），但 gputrace 截帧时保存的 MTLB 被剥离了 bitcode

---

## 新的攻坚方向

### 方向 F: 替换 device-resources 中 MTLB 的 GPU binary 为含 bitcode 的版本

**核心思路**：既然 Xcode 从 metallib bitcode 反编译源码，那在 gputrace 中**替换 stripped MTLB 为含 bitcode 的完整 MTLB** 应该能让 Xcode 反编译出源码。

**已有条件**：
- ShaderDebugInfo 中有 154 个含 LLVM bitcode 的完整 metallib
- gputrace 的 device-resources 中有 137 个 stripped MTLB
- 需要建立 gputrace MTLB → ShaderDebugInfo metallib 的映射

**挑战**：
1. MTLB 在 MTSP 流中的嵌入方式需要理解（大小变化会破坏偏移）
2. 需要找到 MTLB → ShaderDebugInfo entry 的精确对应关系
3. MTLB 大小变化后可能需要重建整个 MTSP 流

### 方向 G: 运行时 hook makeLibrary(data:) 附加 bitcode

**核心思路**：在截帧前，hook `makeLibrary(data:)` 使其在创建 library 时附加 bitcode 信息，让 Xcode 截帧引擎认为这是有源码的 library。

**优势**：不需要修改 gputrace 文件
**挑战**：需要在运行时修改 Metal API 行为

### 方向 H: 利用 "Import Sources" 按钮

**核心思路**：Xcode 的 "Shader source not found" 对话框有 "Import Sources" 按钮。研究这个功能的工作方式，可能可以通过它直接导入我们准备的源码。

- `size` 字段（76, 60, 180）远小于文件实际大小（3.4MB, 1.4MB, 623KB）
- `offset` 是负数（补码），可能是某种结构偏移而非数据范围
- **结论：追加数据到文件末尾不需要修改 header**

**关键发现 3: CU<b>Ut 完整记录布局（Format A, 108 bytes）**

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

**关键发现 4: CSuwuw "library" 完整记录布局（Format A, 76 bytes）**

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

**关键发现 5: Go 解析器验证**

Go 的 `ParseMTSPFromData()` 使用 `record_size` 做顺序扫描，成功识别了 `unused-device-resources` 中的：
- 244 个 CU<b>Ut 记录
- 2958 个 CSuwuw 记录
- 追加的新记录能被正确扫描

### 注入方案实现

**操作步骤**：
1. 构造 76 字节 CSuwuw "library" 记录（Format A）
2. 构造 108 字节 CU<b>Ut 记录（Format A）
3. 追加到 `unused-device-resources` 文件末尾
4. 在 gputrace bundle 中创建 sidecar 源码文件（文件名 = source_hex_id）
5. 无需修改 MTSP header 或 index 文件

**注入脚本**: `scripts/inject_source_records.py`

**已执行测试**：
- ✅ 参考 gputrace: 为 `reference_data_kernel` 注入源码 → 文件格式正确
- ✅ 恋与深空 gputrace: 为 SkinMakeupNew (library 0x7b12cd8c0) 注入源码
- 🔬 等待 Xcode 验证: gputrace 是否正常加载 + 源码是否显示

### 当前状态

- 96 个无源码的 library 已识别（from `device-resources` but not in `unused-device-resources`）
- 注入工具完成，支持单条和批量模式
- **待验证**: Xcode 是否在注入后显示源码

### 如果方案 4 失败，备选分析方向

可能的失败原因及应对：
1. **library_ptr 不匹配**: CU<b>Ut 中的 library_ptr 需要精确匹配创建该 shader 的 library → 需要找到 pipeline→library 的映射
2. **记录顺序问题**: CU<b>Ut 必须出现在特定位置（如 library 注册之后）→ 尝试在现有 CU<b>Ut 之间插入而非追加
3. **index 文件缓存**: `index`(xdic) 可能缓存了 sidecar 文件列表 → 需要更新 index
4. **flags 值不对**: 0xffffc04f 可能包含偏移信息 → 分析更多样本确认 flags 的语义

---

## 下一步（如果方案 4 验证通过）

1. **批量注入**: 为所有 96 个无源码 library 注入 IR 增强的 .metal stub
2. **精确映射**: 建立 library_ptr → ShaderDebugInfo entry 的精确对应关系
3. **集成到 inject_shader_debug_info.py**: 合并文件创建 + 二进制注入为一步
4. **自动化**: 截帧后自动注入离线准备的源码

---

## 关键参考文件

| 文件 | 位置 | 说明 |
|------|------|------|
| MTSP 解析器 | `External/gputrace/internal/trace/mtsp.go` | 完整的 MTSP 记录解析实现 |
| Trace 解析入口 | `External/gputrace/internal/trace/trace.go` | gputrace bundle 加载逻辑 |
| Index 解析 | `External/gputrace/internal/trace/index.go` | xdic 索引文件格式 |
| **二进制注入工具** | `LocalDocs/OfflineSourceRecovery/scripts/inject_source_records.py` | **核心：构造 CSuwuw+CU<b>Ut 记录并追加** |
| MTSP 分析工具 | `LocalDocs/OfflineSourceRecovery/scripts/analyze_reference_gputrace.py` | 逐字节分析 MTSP 记录结构 |
| 截帧生成器 | `LocalDocs/OfflineSourceRecovery/scripts/generate_reference_gputrace.swift` | 生成带源码的参考 gputrace |
| 注入目标列表 | `LocalDocs/OfflineSourceRecovery/scripts/injection_targets.json` | 96 个无源码 library 地址 |
| Stub 源码生成 | `LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py` | 生成 IR 增强 stub 源码 |
| ShaderDebugInfo | `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/` | 运行时提取的 metallib + bitcode |
| MetallibParser | `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift` | metallib 格式解析器 |

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

### 已有源码的记录位置（参考模板）

| 记录 | 文件 | 偏移 | 说明 |
|------|------|------|------|
| CSuwuw "library" | unused-device-resources | 0x166c78 | 源码文件 256C806324F831E3 的 library 注册 |
| CU<b>Ut | unused-device-resources | 0x166cb4 | 关联 source=256C806324F831E3 + stats=85632282FAEE4691 |
| CSuwuw "render-pipeline-state" | device-resources | 0x123b84 | SkinMakeupNew pipeline 注册 |
| CUt | device-resources | 0x123be0 | SkinMakeupNew 的 pipeline ID C8BD90CE2E67E660 |
