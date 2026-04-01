# 03 - Metal Shader 编译流水线与二进制格式

## 一、编译阶段

```
.metal (MSL源码)
    │  metal -c -frecord-sources -gline-tables-only
    ▼
.air (LLVM Bitcode, 标准 LLVM IR)
    │  metal-ar / metallib
    ▼
.metallib (Metal Library Archive, 自定义容器)
    │  MTLDevice.newLibrary(data:)  ← App 运行时
    ▼
Metal IR (中间表示, GPU 无关)
    │  MTLDevice.makeRenderPipelineState()  ← App 运行时, GPU 驱动编译
    ▼
GPU Native Code (AGX ISA, GPU 特定)
```

## 二、各阶段的格式

### 2.1 `.air` — LLVM Bitcode

- 魔数: `DE C0 17 0B`（标准 LLVM Bitcode）
- 本质: 标准 LLVM IR 的二进制编码
- 可用 `llvm-dis` 反汇编为人类可读的 LLVM IR 文本
- 包含 Metal 特有的地址空间（`addrspace(2)` 等）和内置函数（`air.convert.f.*` 等）

### 2.2 `.metallib` — Metal Library Archive

- 魔数: `MTLB`
- 由 zhuowei、YuAo 等人逆向工程
- 结构:

```
[88字节 Header]
  - Magic: "MTLB"
  - 目标平台 (macOS/iOS)
  - 文件版本
  - 各 section 的偏移和大小

[Function List]      → NAME, TYPE, HASH, MDSZ, OFFT, VERS, ENDT
[Header Extension]   → 动态库信息、源码 section
[Public Metadata]    → 函数常量、返回值类型
[Private Metadata]   → 源文件路径、.air 文件路径
[Bitcode Section]    → 实际的 LLVM Bitcode
[Embedded Source]    → 压缩的源代码（可选，-frecord-sources）
```

### 2.3 GPU Native Code (AGX ISA)

- Apple 自研 GPU 的原生指令集，由 dougallj 逆向工程
- 变长编码：2-12 字节，2字节倍数
- SIMD-group = 32 线程
- 寄存器：r0-r127（通用）、u0-u255（统一/共享）

## 三、调试信息机制

### 3.1 内嵌模式（`-frecord-sources`）

源码直接嵌入 `.metallib` 的 Embedded Source section。
Xcode 截帧时会自动提取到 gputrace 中（即我们看到的 hash 命名文件）。

### 3.2 分离模式（`.metallibdsym`）

```
.metallibdsym/          ← 目录/Bundle 结构
├── Contents/
│   ├── Info.plist      ← UUID、源文件列表
│   └── Resources/
│       └── DWARF/
│           └── <binary>  ← Mach-O 格式，含 DWARF 调试段
└── <源文件>              ← 原始 .metal 源码
```

DWARF 段包含：
- `__DWARF/__debug_line`：**机器码地址 ↔ 源码行号映射**（核心！）
- `__DWARF/__debug_str`：字符串表
- `__DWARF/__debug_info`：编译单元信息

**关键**：映射的目标地址是 **Metal IR 地址**，不是 GPU native code 地址。

### 3.3 运行时加载流程

```
App 加载 .metallib
    → Metal 框架查找同名 .metallibdsym
    → 建立 Metal IR 地址 ↔ 源码行号映射
    → Xcode GPU Debugger 使用此映射显示源码
```

## 四、相关工具命令

```bash
# 提取 metallib 中的函数信息
xcrun metal-objdump -disassemble shader.metallib

# 反汇编 .air 为可读 LLVM IR
llvm-dis extracted.air -o output.ll

# 编译到 x86/ARM 汇编（仅供分析，不能直接在 GPU 运行）
llc -march=aarch64 extracted.air -o output_arm.s

# 查看 metallibdsym 的 DWARF 信息
xcrun dwarfdump --all shader.metallibdsym

# 提取嵌入的源码
xcrun metal-source -extract -o ./sources/ shader.metallibdsym

# 手动附加源码
xcrun metal-source -add-sources ./shader.metal -o shader.metallibdsym
```
