# Xcode GUI 自动化操作工具库

## 概述

本目录包含通过 macOS Accessibility API 操控 Xcode GUI 的 Python 工具库，主要面向 GPU Frame Capture 场景。

## 文件清单

| 文件 | 说明 |
|---|---|
| `xcode_gpu_ops.py` | **GPU Frame Capture 专用操作库** — Navigator/Editor/Inspector/步进/截图 |
| `xcode_general_ops.py` | **Xcode 通用操作库** — 窗口/菜单/Navigator切换/UI探查 |
| `README.md` | 本文档 |

## 环境要求

- macOS（需要授予终端/IDE 辅助功能权限: 系统设置 → 隐私与安全性 → 辅助功能）
- `cliclick`（部分操作需要）：`brew install cliclick`
- Python 3.10+（仅用标准库，无需 pip install）

## 快速上手

### 作为 Python 库使用

```python
from xcode_gpu_ops import XcodeGPU

gpu = XcodeGPU()

# 读取 Navigator
rows = gpu.list_command_buffers()
for r in rows:
    print(r["text"])

# 读取当前位置
print(gpu.read_current_location())
# → "Command Buffer 4 > Render Encoder 16 > #25765"

# 步进
gpu.step_next_draw_call()
print(gpu.read_current_location())

# 读取 GPU 绑定表
for row in gpu.read_editor_outline():
    print(" | ".join(row["columns"]))

# 结构化摘要
summary = gpu.read_editor_summary()
print(f"Pipeline: {summary['pipeline_state']}")
print(f"Vertex resources: {len(summary['vertex_resources'])}")
print(f"Fragment resources: {len(summary['fragment_resources'])}")
print(f"Attachments: {len(summary['attachments'])}")
```

### 作为命令行工具使用

```bash
# ═══ xcode_gpu_ops.py CLI ═══

# 列出所有 Command Buffer
python3 xcode_gpu_ops.py cbs

# 列出 Navigator 树 (含展开状态)
python3 xcode_gpu_ops.py nav

# 显示当前位置
python3 xcode_gpu_ops.py location

# 读取面包屑
python3 xcode_gpu_ops.py breadcrumbs

# 读取编辑器绑定表
python3 xcode_gpu_ops.py editor

# 结构化摘要
python3 xcode_gpu_ops.py summary

# 步进到下一个 draw call
python3 xcode_gpu_ops.py step next

# 步进到上一个 (细粒度)
python3 xcode_gpu_ops.py step prev --fine

# 选中 Navigator 第 6 行
python3 xcode_gpu_ops.py select 6

# 展开 Navigator 第 6 行
python3 xcode_gpu_ops.py expand 6

# 切换 Navigator 模式
python3 xcode_gpu_ops.py mode pipeline
python3 xcode_gpu_ops.py mode api

# 截图
python3 xcode_gpu_ops.py screenshot -o /tmp/shot.png

# 导出帧摘要
python3 xcode_gpu_ops.py dump -o /tmp/frame_dump

# 遍历所有 draw call 并截图
python3 xcode_gpu_ops.py walk -o /tmp/screenshots -n 50

# 查看 Debug 菜单
python3 xcode_gpu_ops.py menu

# 查看 Filter 状态
python3 xcode_gpu_ops.py filters

# 读取 Inspector 文本
python3 xcode_gpu_ops.py inspector


# ═══ xcode_general_ops.py CLI ═══

# 列出窗口
python3 xcode_general_ops.py windows

# 列出菜单栏
python3 xcode_general_ops.py menubar

# 查看指定菜单
python3 xcode_general_ops.py menu Debug

# 点击菜单项
python3 xcode_general_ops.py click Debug "Step to Next Draw/Dispatch Call"

# 当前 Navigator
python3 xcode_general_ops.py navigator

# 切换到 Debug Navigator
python3 xcode_general_ops.py show-nav Debug

# 当前文档路径
python3 xcode_general_ops.py doc

# 导出 UI 树 (调试用)
python3 xcode_general_ops.py uitree -n 300
```

## API 参考

### `XcodeGPU` 类 (xcode_gpu_ops.py)

#### Navigator 操作

| 方法 | 说明 |
|---|---|
| `list_navigator_rows()` | 读取所有行 → `[{index, text, selected, has_disclosure, expanded}]` |
| `list_command_buffers()` | 只列出 Command Buffer 行 |
| `select_navigator_row(index)` | 选中指定行 |
| `select_navigator_row_by_text(prefix)` | 按文本前缀选中 |
| `expand_navigator_row(index)` | 展开节点 (需要 cliclick) |
| `collapse_navigator_row(index)` | 折叠节点 (需要 cliclick) |
| `get_gpu_navigator_mode()` | 获取当前模式 |
| `set_gpu_navigator_mode(mode)` | 切换: `"Group by API Call"` / `"Group by Pipeline State"` |

#### Draw Call 步进

| 方法 | 说明 |
|---|---|
| `step_next_draw_call()` | 下一个 Draw/Dispatch Call |
| `step_prev_draw_call()` | 上一个 Draw/Dispatch Call |
| `step_next_gpu_call()` | 下一个 GPU Call (更细粒度) |
| `step_prev_gpu_call()` | 上一个 GPU Call (更细粒度) |

#### 面包屑导航

| 方法 | 说明 |
|---|---|
| `read_breadcrumbs()` | 读取所有面包屑 → `{gputrace, command_buffer, render_encoder, draw_call, ...}` |
| `read_current_location()` | 人类可读位置 → `"Command Buffer 4 > Render Encoder 16 > #25765"` |

#### 编辑器 (GPU 绑定表)

| 方法 | 说明 |
|---|---|
| `read_editor_outline()` | 原始数据 → `[{row_index, columns: [...]}]` |
| `read_editor_summary()` | 结构化摘要 → `{pipeline_state, vertex_function, fragment_function, vertex_resources, fragment_resources, attachments}` |

#### Inspector

| 方法 | 说明 |
|---|---|
| `read_inspector_texts(min_x=1100)` | Inspector 区文本 → `[{text, x, y}]` |
| `read_inspector_attachments()` | Attachment Grid → `[{description, x, y, width, height}]` |

#### Filter

| 方法 | 说明 |
|---|---|
| `read_filter_state()` | → `{Bound: bool, Accessed: bool, All: bool, Vertex: bool, Fragment: bool}` |
| `set_filter(name, enabled)` | 设置 filter, name: `Bound/Accessed/All/Vertex/Fragment` |

#### 截图

| 方法 | 说明 |
|---|---|
| `screenshot(output_path, silent=True)` | 截取全屏 |

#### 高级组合

| 方法 | 说明 |
|---|---|
| `walk_all_draw_calls(max_steps, callback)` | 遍历所有 draw call |
| `dump_frame_summary(output_dir)` | 导出帧的 Navigator 树/Pipeline 列表/内存信息 |
| `screenshot_each_draw_call(output_dir, max_steps)` | 逐步截图 |

### `XcodeGeneral` 类 (xcode_general_ops.py)

| 方法 | 说明 |
|---|---|
| `activate()` | 将 Xcode 置为前台 |
| `get_windows()` | 列出窗口 |
| `get_document_path()` | 当前文档路径 |
| `get_menu_bar_items()` | 菜单栏所有项 |
| `get_menu_items(menu)` | 指定菜单的所有项 |
| `click_menu(menu, item)` | 点击菜单项 |
| `click_submenu(menu, sub, item)` | 点击子菜单项 |
| `show_navigator(name)` | 切换 Navigator |
| `get_current_navigator()` | 当前 Navigator |
| `show_debug_area()` | 显示 Debug Area |
| `show_inspector()` | 显示 Inspector |
| `open_file(path)` | 在 Xcode 中打开文件 |
| `dump_ui_tree(max_elements)` | 导出 UI 元素树 (调试用) |

## 典型使用场景

### 场景 1: 快速定位 shader 信息

```python
from xcode_gpu_ops import XcodeGPU
gpu = XcodeGPU()

# 切到 Pipeline State 模式，查看所有 shader
gpu.set_gpu_navigator_mode("Group by Pipeline State")
for r in gpu.list_navigator_rows():
    if r["index"] >= 6:  # 跳过固定头部
        print(r["text"])
```

### 场景 2: 自动收集某 draw call 的完整信息

```python
gpu = XcodeGPU()
gpu.step_next_draw_call()

loc = gpu.read_current_location()
summary = gpu.read_editor_summary()
inspector = gpu.read_inspector_texts()

print(f"位置: {loc}")
print(f"Shader: {summary['pipeline_state']}")
print(f"Vertex 资源: {len(summary['vertex_resources'])}个")
for res in summary['vertex_resources']:
    print(f"  {res['name']} ({res.get('type','')}) {res.get('size','')}")
```

### 场景 3: AI Agent 自动化分析帧

```python
# 在 AI 对话中，agent 可以直接调用:
gpu = XcodeGPU()

# 1. 先看大局
gpu.set_gpu_navigator_mode("Group by API Call")
cbs = gpu.list_command_buffers()
print(f"共 {len(cbs)} 个 Command Buffer")

# 2. 检查某个 CB 的 draw call
gpu.select_navigator_row(cbs[0]["index"])
gpu.expand_navigator_row(cbs[0]["index"])

# 3. 步进分析
for i in range(5):
    gpu.step_next_draw_call()
    loc = gpu.read_current_location()
    summary = gpu.read_editor_summary()
    print(f"[{i}] {loc} — shader: {summary['pipeline_state']}")
```

## 技术细节

### JXA vs AppleScript

- 所有脚本统一使用 **JXA** (JavaScript for Automation)，通过 `osascript -l JavaScript` 执行
- JXA 优势：0-based 索引、try/catch、数组高阶函数、JSON 原生支持
- AppleScript 仅在个别简单菜单操作中用到（`click_submenu`）

### cliclick 的必要性

Xcode 的某些 UI 控件（特别是 outline 的 disclosure triangle 和 Inspector 区的 popup button）对 JXA 的 `.click()` / `AXPress` **无响应**。`cliclick` 通过 CGEvent 进行物理坐标级点击，可以解决这个问题。

需要 cliclick 的操作：
- `expand_navigator_row()` / `collapse_navigator_row()`

### 坐标依赖性

面包屑导航栏的 popup 识别依赖 **y 坐标范围** (95 < y < 115)。如果 Xcode 窗口移动或工具栏配置不同，可能需要调整。`read_breadcrumbs()` 方法通过排序和位置过滤实现了一定的鲁棒性。

### 性能

- 每次 `_jxa()` 调用约需 0.2-0.4s（启动 osascript 进程的开销）
- 快速操作（breadcrumbs/location/filters/menu/info）: **0.2-0.3s**
- Navigator 读取 (nav/cbs): **3-4s**（行数越多越慢）
- Editor outline 读取 (editor/summary): **25-30s**（67 行 × 多个 cell 的跨进程 IPC）
- 步进操作 (step): **0.5-1s**
- `walk_all_draw_calls()` 处理 100 步约需 1-2 分钟

**注意**: Editor outline 的读取速度受限于 Accessibility API 的 IPC 开销，这是系统限制，无法进一步优化。如果只需要当前位置和 shader 名称，用 `breadcrumbs` 代替 `editor` 会快 100 倍。
