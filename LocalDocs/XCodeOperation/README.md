# Xcode GUI 自动化操作工具库

## 概述

本目录包含通过 macOS Accessibility API (JXA) 操控 Xcode GUI 的 Python 工具库，主要面向 **GPU Frame Capture** 场景。工具分为两层：

- **底层操作库** (`xcode_gpu_ops.py` / `xcode_general_ops.py`) — 封装 Xcode UI 元素的读写操作
- **数据收集脚本** (`collect_cbs.py` / `collect_re_details.py`) — 基于操作库的自动化批量收集脚本

这套工具已在原神 (Genshin Impact) 的 23 帧 GPU 捕获文件上验证通过，成功提取了完整的单帧渲染流程文档（见 `renderanalysistask/06-final-render-pipeline.md`）。

## 目录结构

```
XCodeOperation/
├── xcode_gpu_ops.py         # GPU Frame Capture 专用操作库 (核心)
├── xcode_general_ops.py     # Xcode 通用操作库 (窗口/菜单/Navigator)
├── collect_cbs.py           # 批量收集 Command Buffer 子节点
├── collect_re_details.py    # 步进收集 Render Encoder GPU 绑定详情
├── README.md                # 本文档
└── renderanalysistask/      # 原神帧分析任务数据
    ├── 00-dashboard.md          # 任务看板
    ├── 01-command-buffer-overview.md
    ├── 02-render-pass-summary.md
    ├── 03-pipeline-stages.md
    ├── 04-key-pass-details.md
    ├── 06-final-render-pipeline.md  # ★ 最终输出
    ├── cb_data.json             # collect_cbs.py 输出
    ├── key_pass_details.json    # collect_re_details.py 输出
    ├── pipeline_passes.json     # Pipeline State 模式下的 shader 列表
    └── re_breadcrumbs.json      # 各 RE 的面包屑数据
```

## 环境要求

| 依赖 | 说明 | 安装 |
|------|------|------|
| macOS | 需授予辅助功能权限 | 系统设置 → 隐私与安全性 → 辅助功能 |
| Python 3.10+ | 仅用标准库 | 系统自带或 `brew install python` |
| cliclick | 展开/折叠节点需要 | `brew install cliclick` |
| Xcode | 需打开 GPU Frame Capture 窗口 | — |

> **辅助功能权限**：必须为执行脚本的终端（Terminal / iTerm / IDE 内置终端）授予辅助功能权限，否则所有 Accessibility API 调用会被系统拒绝。

---

## 脚本详解

### 1. `xcode_gpu_ops.py` — GPU Frame Capture 操作库

**核心脚本**，封装了 GPU Frame Capture 界面的全部可自动化操作。

#### 架构

```
┌─────────────────────────────────────────────────┐
│  XcodeGPU 类                                     │
│  ┌──────────────────────────────────────────────┐│
│  │ Navigator 操作    │ Draw Call 步进            ││
│  │ • list_navigator_rows()  • step_next/prev()  ││
│  │ • list_command_buffers() • step_next/prev_gpu││
│  │ • select/expand/collapse                     ││
│  │ • get/set_gpu_navigator_mode()               ││
│  ├──────────────────────────────────────────────┤│
│  │ 面包屑导航         │ 编辑器绑定表             ││
│  │ • read_breadcrumbs()    • read_editor_outline││
│  │ • read_current_location • read_editor_summary││
│  ├──────────────────────────────────────────────┤│
│  │ Inspector           │ Filter / 截图           ││
│  │ • read_inspector_texts  • read_filter_state  ││
│  │ • read_inspector_attach • set_filter         ││
│  │                         • screenshot         ││
│  ├──────────────────────────────────────────────┤│
│  │ 高级组合操作                                  ││
│  │ • walk_all_draw_calls()                      ││
│  │ • dump_frame_summary()                       ││
│  │ • screenshot_each_draw_call()                ││
│  └──────────────────────────────────────────────┘│
├─────────────────────────────────────────────────┤
│  底层: _jxa() / _activate_xcode() / _cliclick() │
└─────────────────────────────────────────────────┘
```

#### CLI 命令速查

```bash
OPS=/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeOperation

# ─── 一键启动 ───
python3 $OPS/xcode_gpu_ops.py open /path/to/capture.gputrace
python3 $OPS/xcode_gpu_ops.py open /path/to/capture.gputrace --no-analysis  # 只 Replay
python3 $OPS/xcode_gpu_ops.py status              # 检查 Xcode/GPU Debug 状态

# ─── 快速操作 (< 1s) ───
python3 $OPS/xcode_gpu_ops.py location        # 当前位置 (CB > RE > drawCall)
python3 $OPS/xcode_gpu_ops.py breadcrumbs     # 面包屑 JSON 详情
python3 $OPS/xcode_gpu_ops.py filters         # Filter checkbox 状态
python3 $OPS/xcode_gpu_ops.py menu            # Debug 菜单项及 enabled 状态
python3 $OPS/xcode_gpu_ops.py info            # 窗口标题/位置/大小/文档路径
python3 $OPS/xcode_gpu_ops.py step next       # 步进到下一个 draw call
python3 $OPS/xcode_gpu_ops.py step prev       # 步进到上一个
python3 $OPS/xcode_gpu_ops.py step next --fine # 细粒度 GPU Call 步进

# ─── 中速操作 (3-5s) ───
python3 $OPS/xcode_gpu_ops.py nav             # Navigator 树 (含展开状态 ▸/▾)
python3 $OPS/xcode_gpu_ops.py cbs             # 只列 Command Buffer 行
python3 $OPS/xcode_gpu_ops.py select 6        # 选中第 6 行 (0-based)
python3 $OPS/xcode_gpu_ops.py expand 6        # 展开第 6 行 (需 cliclick)
python3 $OPS/xcode_gpu_ops.py collapse 6      # 折叠第 6 行 (需 cliclick)
python3 $OPS/xcode_gpu_ops.py dclick 9        # 双击第 9 行 (进入绑定表视图)
python3 $OPS/xcode_gpu_ops.py mode pipeline   # 切换到 Pipeline State 模式
python3 $OPS/xcode_gpu_ops.py mode api        # 切换回 API Call 模式
python3 $OPS/xcode_gpu_ops.py inspector       # Inspector 区域文本

# ─── 慢速操作 (25-30s) ───
python3 $OPS/xcode_gpu_ops.py editor          # 编辑器完整绑定表
python3 $OPS/xcode_gpu_ops.py summary         # 结构化摘要 (JSON)

# ─── 批量操作 ───
python3 $OPS/xcode_gpu_ops.py screenshot -o /tmp/shot.png
python3 $OPS/xcode_gpu_ops.py dump -o /tmp/frame_dump
python3 $OPS/xcode_gpu_ops.py walk -o /tmp/screenshots -n 50
```

#### Python API 速查

| 类别 | 方法 | 耗时 | 说明 |
|------|------|------|------|
| **启动** | `open_gputrace(path)` | 20-40s | 一键打开 gputrace → Replay → 进入分析 |
| | `is_xcode_running()` | 0.1s | 检查 Xcode 是否运行 |
| | `wait_for_xcode(timeout)` | 0-30s | 等待 Xcode 启动就绪 |
| **Navigator** | `list_navigator_rows()` | 3-4s | 所有行 → `[{index, text, selected, has_disclosure, expanded}]` |
| | `list_command_buffers()` | 3-4s | 只列 CB 行 |
| | `select_navigator_row(index)` | 0.5s | 选中行 (同时滚动到可见区域) |
| | `select_navigator_row_by_text(prefix)` | 3-4s | 按文本前缀选中 |
| | `expand_navigator_row(index)` | 0.5s | 展开节点 (**需要 cliclick**) |
| | `collapse_navigator_row(index)` | 0.5s | 折叠节点 (**需要 cliclick**) |
| | `double_click_navigator_row(index)` | 0.8s | 双击行，进入绑定表视图 (**需要 cliclick**) |
| | `get_gpu_navigator_mode()` | 0.3s | `"Group by API Call"` / `"Group by Pipeline State"` |
| | `set_gpu_navigator_mode(mode)` | 0.8s | 切换模式 |
| **步进** | `step_next_draw_call()` | 0.5s | 下一个 Draw/Dispatch Call |
| | `step_prev_draw_call()` | 0.5s | 上一个 |
| | `step_next_gpu_call()` | 0.5s | 更细粒度步进 |
| | `step_prev_gpu_call()` | 0.5s | 更细粒度步进 |
| **面包屑** | `read_breadcrumbs()` | 0.25s | `{gputrace, command_buffer, render_encoder, draw_call, ...}` |
| | `read_current_location()` | 0.25s | 人类可读: `"CB 4 > RE 16 > #25765"` |
| **编辑器** | `read_editor_outline()` | 25-30s | 原始多列绑定表 |
| | `read_editor_summary()` | 25-30s | 结构化: `{pipeline_state, vertex/fragment_resources, attachments}` |
| **Inspector** | `read_inspector_texts(min_x)` | 5-10s | Inspector 区文本 |
| | `read_inspector_attachments()` | 5-10s | Attachment Grid 信息 |
| **Filter** | `read_filter_state()` | 0.3s | `{Bound, Accessed, All, Vertex, Fragment}` |
| | `set_filter(name, enabled)` | 0.5s | 切换 filter |
| **截图** | `screenshot(path, silent)` | 0.5s | 全屏截图 |
| **组合** | `walk_all_draw_calls(max, cb)` | 1-2min/100步 | 遍历所有 draw call |
| | `dump_frame_summary(dir)` | 10s | 导出 Navigator + Pipeline 列表 |
| | `screenshot_each_draw_call(dir, n)` | 2-3min | 逐步截图 |

---

### 2. `xcode_general_ops.py` — Xcode 通用操作库

不依赖 GPU Frame Capture 的通用 Xcode 操作，适用于任何 Xcode 窗口。

#### CLI 命令速查

```bash
python3 $OPS/xcode_general_ops.py windows     # 列出所有窗口
python3 $OPS/xcode_general_ops.py menubar      # 菜单栏所有项
python3 $OPS/xcode_general_ops.py menu Debug   # Debug 菜单详情
python3 $OPS/xcode_general_ops.py submenu Debug "Attach to Process"   # 子菜单详情
python3 $OPS/xcode_general_ops.py click Debug "Step to Next Draw/Dispatch Call"
python3 $OPS/xcode_general_ops.py click-submenu Debug "Attach to Process" "RIPCProfileBootstrap"  # 点击子菜单项
python3 $OPS/xcode_general_ops.py sheets       # 当前窗口的 sheet / alert 摘要
python3 $OPS/xcode_general_ops.py click-sheet Replace  # 点击 sheet 按钮
python3 $OPS/xcode_general_ops.py navigator    # 当前 Navigator 名称
python3 $OPS/xcode_general_ops.py show-nav Debug  # 切换 Navigator
python3 $OPS/xcode_general_ops.py toolbar      # 工具栏按钮
python3 $OPS/xcode_general_ops.py doc          # 当前文档路径
python3 $OPS/xcode_general_ops.py uitree -n 300  # UI 元素树 (调试)
```

#### Python API

| 方法 | 说明 |
|------|------|
| `activate()` | 将 Xcode 置为前台 |
| `get_windows()` | 列出窗口 → `[{index, title, x, y, width, height}]` |
| `get_document_path()` | 当前文档路径 |
| `get_menu_bar_items()` | 菜单栏所有项名称 |
| `get_menu_items(menu)` | 指定菜单的所有项 → `[{name, enabled}]` |
| `get_submenu_items(menu, submenu)` | 指定子菜单的所有项 → `[{name, enabled}]` |
| `click_menu(menu, item)` | 点击菜单项 (JXA) |
| `click_submenu(menu, sub, item)` | 点击子菜单项 (AppleScript) |
| `get_sheets()` | 当前窗口的 sheet / alert 摘要 |
| `click_sheet_button(name, sheet_index)` | 点击 sheet / alert 按钮 |
| `show_navigator(name)` | 切换 Navigator |
| `hide_navigator()` | 隐藏 Navigator |
| `get_current_navigator()` | 当前激活的 Navigator 名称 |
| `get_toolbar_buttons()` | 工具栏按钮信息 |
| `show_debug_area()` | 显示 Debug Area |
| `show_inspector()` | 显示 Inspector |
| `open_file(path)` | 在 Xcode 中打开文件 |
| `dump_ui_tree(max_elements)` | 导出 UI 元素树 (调试) |

---

### 3. `collect_cbs.py` — Command Buffer 批量收集

自动遍历所有 Command Buffer，展开每个 CB 并读取其子节点（Render Encoder、presentDrawable 等），输出结构化 JSON。

#### 核心特性

- **断点续传**: 读取已有 JSON，自动跳过已收集的 CB
- **增量保存**: 每收集完一个 CB 立即写入文件
- **自动折叠**: 展开读取后自动折叠，避免 outline 行数过多导致 index 偏移
- **展开前 select**: 确保目标行在可视区域内，避免 cliclick 坐标错误

#### 用法

```bash
python3 collect_cbs.py                     # 从头开始
python3 collect_cbs.py 5                   # 从第 5 个 CB 续传
python3 collect_cbs.py -o /tmp/cbs.json    # 指定输出路径
```

#### 输出格式 (cb_data.json)

```json
{
  "Command Buffer 0x...": [
    "Render Encoder 0 0x...",
    "Render Encoder 1 0x...",
    "...",
    "presentDrawable 0x..."
  ],
  "Command Buffer 1 0x...": ["..."]
}
```

---

### 4. `collect_re_details.py` — Render Encoder 详情收集

步进遍历 draw call，每检测到 Render Encoder 切换就收集一次完整的 editor summary（pipeline state、shader 函数名、vertex/fragment 资源、attachments），实现 **一帧内所有 render pass 的自动化分析**。

#### 核心特性

- **RE 变化检测**: 通过 breadcrumbs 快速判断是否进入新的 Render Encoder (0.25s)
- **按需收集 summary**: 只在 RE 变化时调用耗时的 `read_editor_summary()` (25-30s)
- **增量保存**: 每收集到新 RE 数据立即写入
- **自动停止**: 收集满指定数量的 RE 后停止（默认 26）
- **跨 CB 步进**: `step_next_draw_call()` 会自动跨越 Command Buffer 边界

#### 用法

```bash
python3 collect_re_details.py                # 默认 500 步、26 个 RE
python3 collect_re_details.py 200            # 限制 200 步
python3 collect_re_details.py -o out.json    # 指定输出
python3 collect_re_details.py --re-count 10  # 只收集 10 个 RE
```

#### 输出格式 (key_pass_details.json)

```json
[
  {
    "command_buffer": "Command Buffer 0 0x...",
    "render_encoder": "Render Encoder 0 0x...",
    "draw_call": "123 drawIndexedPrimitives...",
    "summary": {
      "pipeline_state": "miHoYo/Scene/Login Base",
      "vertex_function": "vert_login_base",
      "fragment_function": "frag_login_base",
      "vertex_resources": [{"name": "...", "binding": "...", "type": "..."}],
      "fragment_resources": [...],
      "attachments": [{"name": "InnerTarget", "slot": "Color 0", ...}]
    }
  }
]
```

#### 性能预估

| 参数 | 值 |
|------|-----|
| 每次步进 | 0.5-1s |
| RE 变化检测 (breadcrumbs) | 0.25s |
| 每次 summary 收集 | 25-30s |
| 一帧 26 个 RE 总耗时 | ~15-20 分钟 |
| 5300 draw call 的步进总耗时 | ~50-90 分钟 |

---

## 典型使用场景

### 场景 1: 快速定位所有 shader

```python
from xcode_gpu_ops import XcodeGPU
gpu = XcodeGPU()

# 切到 Pipeline State 模式，4s 内获取所有 shader 名
gpu.set_gpu_navigator_mode("Group by Pipeline State")
for r in gpu.list_navigator_rows():
    if r["index"] >= 6:  # 跳过固定头部行
        print(r["text"])
```

### 场景 2: 收集完整一帧的渲染流程

```bash
# Step 1: 收集所有 CB 的子节点结构
python3 collect_cbs.py

# Step 2: 步进收集每个 RE 的完整 GPU 绑定信息
python3 collect_re_details.py

# 数据输出到 renderanalysistask/ 下的 JSON 文件
```

### 场景 3: AI Agent 自动化分析

```python
from xcode_gpu_ops import XcodeGPU
gpu = XcodeGPU()

# 1. 概览
cbs = gpu.list_command_buffers()
print(f"共 {len(cbs)} 个 Command Buffer")

# 2. 展开某个 CB
gpu.select_navigator_row(cbs[0]["index"])
gpu.expand_navigator_row(cbs[0]["index"])

# 3. 步进分析前 5 个 draw call
for i in range(5):
    gpu.step_next_draw_call()
    loc = gpu.read_current_location()
    # 用 breadcrumbs 快速获取位置 (0.25s)，而不是 summary (30s)
    bc = gpu.read_breadcrumbs()
    print(f"[{i}] {loc}")
```

### 场景 4: 导出帧截图序列

```bash
# 步进遍历 draw call，每步截屏
python3 xcode_gpu_ops.py walk -o /tmp/screenshots -n 200

# 或者导出 Navigator + Pipeline 结构
python3 xcode_gpu_ops.py dump -o /tmp/frame_dump
```

---

## 技术细节

### JXA vs AppleScript

- 统一使用 **JXA** (JavaScript for Automation)，通过 `osascript -l JavaScript` 执行
- JXA 优势：0-based 索引、try/catch、数组高阶函数、JSON 原生支持
- AppleScript 仅在 `click_submenu` 中使用（多级子菜单 JXA 语法复杂）

### cliclick 的必要性

Xcode 的 outline disclosure triangle 对 JXA 的 `.click()` / `AXPress` **无响应**。`cliclick` 通过 CGEvent 进行物理坐标级点击解决此问题。

需要 cliclick 的操作：
- `expand_navigator_row()` / `collapse_navigator_row()`

### 前台要求

cliclick 基于屏幕坐标点击，**必须确保 Xcode 窗口在前台且目标行可见**。脚本通过 `System Events` 设置 `frontmost = true` 实现（不使用 `Application.activate()`，后者会导致 AppleScript 挂起）。

### 性能特征

| 操作 | 耗时 | 说明 |
|------|------|------|
| `_jxa()` 单次调用 | 0.2-0.4s | osascript 进程启动开销 |
| `breadcrumbs` / `location` | 0.25s | 精确 UI 路径读取，**不需要 `entireContents`** |
| `filters` / `menu` / `info` | 0.2-0.3s | 简单属性读取 |
| `nav` / `cbs` | 3-4s | 行数越多越慢 |
| `step` | 0.5-1s | 含菜单点击 + delay |
| `editor` / `summary` | **25-30s** | 67 行 × 多列跨进程 IPC，**系统瓶颈** |
| `inspector` | 5-10s | 使用 `entireContents` 遍历 |
| `walk` 100 步 | 1-2 min | |

> **性能提醒**: 如果只需要 shader 名称和当前位置，用 `breadcrumbs`（0.25s）或 Pipeline State 模式的 `nav`（4s）替代 `editor`（30s），快 **100 倍**。

---

## 踩坑经验 & 已修复 Bug

以下是开发和使用过程中积累的关键经验：

### Bug 修复记录

1. **`disclosureTriangles()` 不兼容** — Xcode 的 outline row 不支持 `disclosureTriangles()` 方法。改用 `uiElements.whose({role: "AXDisclosureTriangle"})` 查询。

2. **`Application.activate()` 导致挂起** — 使用 `Application("Xcode").activate()` 会导致 JXA 脚本永久挂起。改用 `System Events` 的 `frontmost = true` 属性设置。

3. **JXA 超时** — 默认 `osascript` 超时太短，editor outline 读取需要 30s+。将 `_jxa()` 的 timeout 从默认 15s 提升到 120s。

4. **`list_navigator_rows` 空行崩溃 (-1728)** — Navigator 中的分隔符空行（如 row 5）没有 `uiElements[0]`，`staticTexts()` 直接抛异常。将整行读取逻辑包裹在 try/catch 中，空行返回 `{text: ""}` 占位。

5. **`read_breadcrumbs` 路径不兼容** — 之前硬编码 `win.splitterGroups[0].splitterGroups[0].uiElements[0].uiElements[0].uiElements[0].uiElements[1]` 定位 Jump Bar，但 Navigator 展开/折叠后 splitterGroup 嵌套层级会变化。改为递归搜索 `description === "Jump Bar"` 的元素，按 popup 数量和内容区分左侧面包屑和右侧 Inspector 面包屑。

6. **Navigator mode popup 位置不固定** — 之前硬编码 `rows[5].uiElements[0].popUpButtons[0]` 读取 Navigator mode，但 Replay 后 row 结构可能变化。改为遍历前 10 行查找 popUpButton。

### 全流程启动经验

从零启动 Xcode 到进入 GPU 分析的完整步骤：

```bash
# 1. 打开 gputrace 文件
open -a Xcode /path/to/capture.gputrace

# 2. 等待 Xcode 启动 (8-10s)
sleep 10

# 3. 显示 Debug Navigator
python3 xcode_general_ops.py show-nav Debug

# 4. 在概览页点击 "Replay" 按钮 (需要 JXA 定位 + click)
# 5. 等待 Replay 完成 (10-15s, 视文件大小而定)
# 6. 展开 CB → 选中 RE → 双击 draw call 行 → 进入绑定表视图
# 7. 此时 Debug 菜单的 Step 系列功能才会启用
```

关键注意事项：
- **打开 gputrace 后需要 Replay** — `open -a Xcode` 打开文件后处于概览页，必须点击 "Replay" 按钮
- **Replay 后 Navigator 自动加载 CB 列表** — 23 帧 × 5300 draw call 的文件需要 10-15s
- **必须双击 draw call 行** — 在 Navigator 中 select 行不够，必须双击才能激活编辑器绑定表和步进功能
- **步进菜单在双击后才启用** — Step to Next/Previous Draw Call 在双击 draw call 前一直是 disabled

### 基础操作经验

- **展开前必须 select** — cliclick 基于屏幕坐标，目标行不在可视区域时坐标指向错误位置。先 `select_navigator_row()` 让行滚入视图
- **所有 CB 初始都是折叠的** — 每个 CB 需要先 `expand` 才能看到 RE 子节点
- **Pipeline State 模式最快获取 shader 名** — `mode pipeline` + `nav` 在 4s 内获取 50 个 shader pass
- **select 后 breadcrumb 不一定更新** — 需要 `step` 或点击 draw call 行才能刷新 editor
- **步进操作会跨 CB** — `step_next_draw_call()` 到达一个 CB 末尾时会自动跳到下一个 CB
- **breadcrumb 用递归搜索 Jump Bar** — 不依赖固定 UI 路径，适应多种窗口布局
- **23 个 CB 代表 23 帧** — 多帧捕获中每帧结构完全一致，分析任意一帧即代表所有
- **展开后 index 会变化** — 展开一个 CB 会插入子行导致后续行的 index 偏移，需要重新读取
- **`entireContents` 是性能杀手** — 遍历整个窗口的 UI 树非常慢，应尽量用精确路径替代
