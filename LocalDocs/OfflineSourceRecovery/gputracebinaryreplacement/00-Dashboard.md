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

### Xcode 的源码关联机制（已验证）

Xcode 只为通过 `makeLibrary(source:)` 创建的 library 显示源码。具体机制：

1. `makeLibrary(source:)` 被调用时，Xcode 截帧引擎捕获源码文本
2. 源码以 hex ID 为文件名保存在 gputrace bundle 中（纯文本 .metal 文件）
3. 在 `unused-device-resources-*` MTSP 流中写入 `CU<b>Ut` 记录，将 library 指针映射到源码文件
4. 编译统计（bplist 格式）通过 `CiUul` 记录关联
5. 查看时 Xcode 沿链路：pipeline → library → `CU<b>Ut` → 源码文件

对于 `makeLibrary(data:)` 路径，步骤 1-3 不发生，因此无源码。

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

## 下一步需要深挖的方向

### 方向 A: 精确理解 MTSP 记录的字段布局

**当前知识缺口**：我们通过 hex dump 逆向了大致的记录结构，但几个关键问题未解决：

1. **prefix 字段的含义**：`CUt` 的 `01 10 00 00` vs `CU<b>Ut` 的 `01 00 00 00`，第二个字节 `0x10` vs `0x00` 是什么？是子类型？是 flag？还是后续字段的偏移？
2. **footer 字段**：`74 00 00 00`、`8c 00 00 00`、`10 d0 ff ff`、`39 d8 ff ff` 等值是什么？可能是相对偏移（负数用补码）或大小字段
3. **record_size 和实际记录边界**：MTSP 记录的开头 4 字节是 record_size（如 `46 00 00 00` = 70），但 `CU<b>Ut` 记录的前缀是 `01 00 00 00`（=1），这显然不是 size。可能 CSuwuw 和 CU<b>Ut 是同一条大记录的两部分？

**建议做法**：
- 用 `External/gputrace` 的 `ParseMTSPRecords()` 函数作为参考，它已经实现了记录边界检测（`detectRecordType`）
- 对 `unused-device-resources` 做完整的记录解析 dump，逐条输出每条记录的偏移、大小、类型、payload
- 重点对比 CSuwuw "library" + CU<b>Ut 记录对 和 CSuwuw "render-pipeline-state" + CUt 记录对的完整字段差异

### 方向 B: 修改 MTSP header 使追加的记录生效

**假设**：方案 2 追加到 `unused-device-resources` 末尾没有生效，可能是因为 MTSP header 中的 size/offset 字段限制了解析范围。

**需要验证**：
1. MTSP header 的 `size` 和 `offset` 字段的确切含义
2. 如果 `size` 表示有效数据长度，则追加后需要更新 header
3. 如果有 `index` 文件引用偏移量，也需要同步更新

**建议做法**：
- 分别解析 `device-resources` 和 `unused-device-resources` 的 MTSP header
- 对比修改前后的文件大小和 header 值
- 尝试追加记录后同时更新 MTSP header 的 size 字段

### 方向 C: 在正确的位置插入记录（而非追加或原地替换）

**思路**：不是在文件末尾追加，也不是原地替换，而是在 SkinMakeupNew 的 CSuwuw "render-pipeline-state" 记录之后**插入**一条新的 `CU<b>Ut` 记录。

**挑战**：
1. 插入会改变所有后续记录的偏移，如果 MTSP 中有绝对偏移引用会失效
2. `index` 文件可能缓存了偏移量，需要重建
3. 需要精确控制插入点和记录大小

**建议做法**：
- 先确认 MTSP 是否使用绝对偏移（如果全是顺序扫描则插入是安全的）
- 在 `unused-device-resources` 中（而非 `device-resources` 中）尝试插入，因为 `unused-device-resources` 可能不被 Xcode 的 replay 引擎直接用于命令回放
- 对比两个 resources 文件的记录结构差异

### 方向 D: 利用 `External/gputrace` Go 工具进行精确修改

**优势**：`External/gputrace` 已经实现了完整的 MTSP 记录解析（`ParseMTSPRecords`、`detectRecordType`、各种 `Parse*Record` 函数），可以：

1. 完整解析 MTSP 流为记录列表
2. 在正确位置插入新记录
3. 重新序列化整个 MTSP 流
4. 更新 header

**需要新增的能力**：
- MTSP 序列化（目前只有反序列化）
- 记录构造器（目前只有解析器）
- 可能需要扩展 `CU<b>Ut` 记录的解析（当前工具可能不识别这种类型）

**建议做法**：
- 在 Go 工具中添加 `WriteMTSP` 功能
- 添加 `InjectSourceRecord` 命令
- 先用工具解析现有的 `unused-device-resources`，验证所有记录都能正确 round-trip

### 方向 E: 深入分析 Xcode 的源码查找逻辑

**思路**：通过逆向 Xcode 的 GPU Debugger 框架，理解它如何关联 shader 和源码。

**可能的切入点**：
- Hook Xcode 加载 gputrace 时的文件读取系统调用（`fs_usage` 或 `dtrace`）
- 在 Xcode 打开已有源码的 gputrace 时，观察它读取了哪些文件、以什么顺序
- 搜索 Xcode 框架中的 "source not found" 字符串，反向追踪源码查找逻辑
- 检查 `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/GPUTools/` 下的 dylib

---

## 关键参考文件

| 文件 | 位置 | 说明 |
|------|------|------|
| MTSP 解析器 | `External/gputrace/internal/trace/mtsp.go` | 完整的 MTSP 记录解析实现 |
| Trace 解析入口 | `External/gputrace/internal/trace/trace.go` | gputrace bundle 加载逻辑 |
| Index 解析 | `External/gputrace/internal/trace/index.go` | xdic 索引文件格式 |
| 注入脚本 | `LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py` | 生成 IR 增强 stub 源码 |
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
