# extract_shader_raw.py 使用指南

从 ShaderDebugInfo 中提取 shader 的 metallib、bitcode 和 LLVM IR 到 ShaderRaw 目录。

## 快速开始

### 1. 按 shader 名称搜索（推荐）

在 Xcode GPU Debugger 中找到 shader 的任意特征 uniform/struct 名称，然后搜索：

```bash
python3 extract_shader_raw.py --search "MakeupColor"
python3 extract_shader_raw.py --search "EyebrowColor"
python3 extract_shader_raw.py --search "Character_Param"
```

输出会列出匹配的 cacheKey，按 vertex/fragment 分类。

### 2. 按 cacheKey 直接提取

用搜索结果中的 cacheKey 直接提取（无需映射表）：

```bash
python3 extract_shader_raw.py --cache-key 61F4807E5636D024_28097 --shader-name SkinMakeupNew
```

提取多个：

```bash
python3 extract_shader_raw.py \
    --cache-key C2F2D89403D39FBF_7593 \
    --cache-key 61F4807E5636D024_28097 \
    --shader-name SkinMakeupNew
```

### 3. 按 library 地址提取

如果你从 Xcode 中获取了 library 地址：

```bash
# 首次使用需绑定映射
python3 extract_shader_raw.py --add-map 0x7b12cf580 C2F2D89403D39FBF_7593 --shader-name "Papegame/SkinMakeupNew"
python3 extract_shader_raw.py --add-map 0x7b12cd4c0 61F4807E5636D024_28097 --shader-name "Papegame/SkinMakeupNew"

# 之后直接用地址提取
python3 extract_shader_raw.py --library 0x7b12cf580 --library 0x7b12cd4c0 --shader-name SkinMakeupNew
```

---

## 所有命令

| 命令 | 说明 |
|------|------|
| `--search <关键字>` | 在所有 metallib 中搜索 uniform/struct 名称 |
| `--cache-key <KEY>` | 按 cacheKey 直接提取 |
| `--library <ADDR>` | 按 library 地址提取（需先建映射） |
| `--add-map <ADDR> <KEY>` | 添加 library 地址 → cacheKey 映射 |
| `--build-map` | 全量扫描 store0 + SDI 构建映射表 |
| `--list` | 列出映射表中的所有条目 |

## 选项

| 选项 | 说明 |
|------|------|
| `--shader-name <NAME>` | 输出文件名前缀 |
| `--output-dir <DIR>` | 输出目录（默认 `ShaderRaw/`） |
| `--func-type vertex\|fragment\|kernel` | 指定函数类型（用于 `--add-map`） |
| `--no-ir` | 跳过 .ll 生成 |
| `--no-metallib` | 跳过 .metallib 复制 |
| `--no-bitcode` | 跳过 .bc 复制 |
| `-v` / `--verbose` | 详细输出 |

---

## 输出文件

每个 shader 生成 3 个文件：

```
ShaderRaw/
├── SkinMakeupNew_vertex_lib0x7b12cf580.metallib   # 原始 metallib
├── SkinMakeupNew_vertex_lib0x7b12cf580.bc         # LLVM bitcode
├── SkinMakeupNew_vertex_lib0x7b12cf580.ll         # LLVM IR (可读)
├── SkinMakeupNew_fragment_lib0x7b12cd4c0.metallib
├── SkinMakeupNew_fragment_lib0x7b12cd4c0.bc
└── SkinMakeupNew_fragment_lib0x7b12cd4c0.ll
```

命名格式：`{shaderName}_{functionType}[_lib{address}].{ext}`

---

## 如何从 Xcode 中获取信息

### 方法 A：shader 特征名称（最方便）

1. 在 GPU Debugger 中选中一个 draw call
2. 查看 **Bound Resources** 面板中的 buffer 名称
3. 找到有辨识度的 uniform 名（如 `_MakeupColor1`、`_EyebrowColor`）
4. 用 `--search` 搜索

### 方法 B：metallib 大小

如果能看到 metallib 的字节大小（如 28097），直接在 ShaderDebugInfo 目录中找 `*_28097` 的条目：

```bash
ls ~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/ | grep "_28097$"
```

### 方法 C：library 地址

在 Pipeline State 面板中找到 Library 的地址（形如 `0x7b12cf580`），首次需要和 cacheKey 绑定。

---

## 映射表

映射表保存在 `library_ptr_map.json`，格式：

```json
{
  "0x7b12cf580": {
    "cacheKey": "C2F2D89403D39FBF_7593",
    "functionType": "vertex",
    "shaderName": "Papegame/SkinMakeupNew",
    "note": ""
  }
}
```

首次使用 `--add-map` 添加后，后续 `--library` 自动查表。

---

## 依赖

- Python 3.8+
- `llvm-dis`（用于生成 .ll 文件，Homebrew: `brew install llvm`）
- ShaderDebugInfo 目录（由 PlayCover extraction 模式生成）

---

## 原理

1. **cacheKey 算法**：`hash = fold(metallib_size, head_32_bytes, tail_16_bytes)` → `"{hash:016X}_{size}"`
2. **搜索**：提取 metallib 中的 ASCII 字符串，匹配关键字
3. **提取**：从 ShaderDebugInfo 复制 metallib + bitcode，用 llvm-dis 生成 IR
