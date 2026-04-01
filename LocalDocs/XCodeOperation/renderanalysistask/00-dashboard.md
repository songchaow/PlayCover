# 渲染流程分析 — 任务 Dashboard

## 背景

当前 Xcode 打开了原神 (com.miHoYo.Yuanshen) 的 GPU Frame Capture 文件 `capture_20260401_011127.gputrace`。这是一个 **23 帧的多帧捕获**，每帧包含 **26 个 Render Encoder** + 1 个 presentDrawable，结构完全一致。每帧约 5,300 个 draw call，总计约 121,107 个 GPU 命令。我们通过 `xcode_gpu_ops.py` 工具库自动化操控 Xcode GUI 来提取和分析渲染流程。

## 最终目标

生成一份结构清晰的 **整帧渲染流程文档**，包含：
1. 每个 Command Buffer 的用途概述
2. 每个 Render Encoder (render pass) 的渲染目标、shader、绘制内容
3. 各 pass 之间的依赖关系（通过 attachment 读写推断）
4. 整体渲染管线的阶段划分（如 G-Buffer / Lighting / PostProcess / UI）

## 工作流程

每个 agent 执行以下循环：

1. **读取本文档**，了解当前进度和下一个优先任务
2. **执行任务**：用 `xcode_gpu_ops.py` 操控 Xcode 收集数据、分析
3. **写入子文档**：详细数据写入 `renderanalysistask/` 下的独立文件
4. **更新本文档**：整合新发现，更新 TODO 状态和经验，保持简洁

### 工具快速参考

```bash
OPS=/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeOperation
# 快速操作 (< 1s)
python3 $OPS/xcode_gpu_ops.py location        # 当前位置
python3 $OPS/xcode_gpu_ops.py breadcrumbs     # 面包屑详情
python3 $OPS/xcode_gpu_ops.py cbs             # Command Buffer 列表
python3 $OPS/xcode_gpu_ops.py step next       # 步进到下一个 draw call
python3 $OPS/xcode_gpu_ops.py filters         # Filter 状态
python3 $OPS/xcode_gpu_ops.py menu            # Debug 菜单状态
# 中速操作 (3-5s)
python3 $OPS/xcode_gpu_ops.py nav             # Navigator 树
python3 $OPS/xcode_gpu_ops.py select <index>  # 选中行
python3 $OPS/xcode_gpu_ops.py expand <index>  # 展开行 (需 cliclick)
python3 $OPS/xcode_gpu_ops.py mode pipeline   # 切换到 Pipeline State 模式
# 慢速操作 (25-30s)
python3 $OPS/xcode_gpu_ops.py editor          # 编辑器绑定表 (完整但慢)
python3 $OPS/xcode_gpu_ops.py summary         # 结构化摘要
```

**性能提醒**：`editor`/`summary` 每次约 30 秒。如果只需要 shader 名，用 `breadcrumbs`（0.3s）或 Pipeline State 模式的 `nav`（4s）代替。

## 任务 TODO

### P0 — 帧结构骨架
- [x] **T1: 收集 Command Buffer 概览** — ✅ 23 个 CB 结构一致，各含 26 RE + 1 presentDrawable
- [x] **T2: 收集 Render Pass 摘要** — ✅ Pipeline State 模式获取 50 个 shader pass 名称及执行顺序
- [x] **T3: 整理渲染管线阶段** — ✅ 划分为 7 大阶段：预处理 → G-Buffer → 光照 → 天空 → 运动矢量 → 后处理 → UI

### P1 — 关键 Pass 深入分析
- [x] **T4: 收集关键 pass 的完整绑定表** — ✅ 步进遍历完整一帧，收集所有 26 RE 的 attachment 信息
- [x] **T5: 分析 Attachment 依赖链** — ✅ 建立 InnerTarget / TempBuffer / Bloom 缓冲的依赖图

### P2 — 输出与优化
- [x] **T6: 生成最终渲染流程文档** — ✅ `06-final-render-pipeline.md`
- [x] **T7: 完善工具脚本** — ✅ 修复 3 个 bug + 整理脚本到 `XCodeOperation/` + 深度更新 README.md

## 当前状态

**全部任务已完成。** 最终渲染流程文档见 `06-final-render-pipeline.md`。工具脚本已整理到 `XCodeOperation/` 根目录，README.md 已深度更新。

## 踩坑与经验

### 基础操作
- **`editor` 操作耗时 30s**：逐 draw call 调用 editor 不现实。批量分析应优先用 `breadcrumbs`（0.3s）+ Pipeline State 模式 `nav`（4s）
- **展开节点需要 cliclick**：JXA `.click()` 对 disclosure triangle 无效，必须用 `cliclick c:x,y` 坐标点击
- **展开前必须 select**：cliclick 基于屏幕坐标，目标行不在可视区域时坐标指向错误位置。先 `select` 让行滚入视图
- **cliclick 需要 Xcode 在前台**：用 System Events `frontmost=true`（不要用 AppleScript `activate`，会挂起）
- **`disclosureTriangles()` 不兼容**：需要用 `uiElements.whose({role: "AXDisclosureTriangle"})` 替代
- **所有 CB 初始都是折叠的**：每个 CB 需要先 `expand` 才能看到 RE 子节点
- **Pipeline State 模式最快获取 shader 名**：`mode pipeline` + `nav` 在 4s 内获取 50 个 shader pass
- **select 后 breadcrumb 不一定更新**：需要 step 或点击 draw call 行才能刷新 editor
- **23 个 CB 代表 23 帧**：多帧捕获中每帧结构完全一致，分析任意一帧即代表所有
- **breadcrumb 不需要 entireContents**：通过精确 UI 路径 `edGroup > [0] > [0] > Jump Bar > popUpButtons` 读取，速度 0.25s
- **步进操作会跨 CB**：`step_next_draw_call()` 到达一个 CB 末尾时会自动跳到下一个 CB

### 全流程启动 (2026-04-01 新增)
- **打开 gputrace 后需要 Replay**：`open -a Xcode <file>` 打开文件后处于概览页，必须点击 "Replay" 按钮才能进入 GPU Debug Navigator
- **Replay 需要 10-15s**：23 帧 × 5300 draw call 的大文件，Replay 后才有 CB 列表
- **Navigator select draw call 不够**：在概览页选中 draw call 行不会切换编辑器到绑定表视图，必须**双击** Navigator 中的 draw call 行
- **双击 draw call 行后步进菜单才启用**：Step to Next/Previous Draw Call 菜单项在双击 draw call 前都是 disabled
- **Navigator 空行会导致 -1728 错误**：`list_navigator_rows` 中 `rows[i].uiElements[0]` 对空行（如 row 5 分隔符）会抛异常，需要整行 try/catch
- **面包屑 Jump Bar UI 路径不固定**：随 Navigator 展开/折叠，`splitterGroups` 嵌套层级会变化。改用递归搜索 `description === "Jump Bar"` 更健壮
- **Navigator mode popup 位置不固定在 row[5]**：Replay 后 row 结构可能变化，改为遍历前 10 行查找 popUpButton

## 数据文件

| 文件 | 说明 | 状态 |
|---|---|---|
| `00-dashboard.md` | 本文档 | 持续更新 |
| `01-command-buffer-overview.md` | CB 概览 (T1 输出) | ✅ 完成 |
| `02-render-pass-summary.md` | RE 摘要 (T2 输出) | ✅ 完成 |
| `03-pipeline-stages.md` | 管线阶段划分 (T3 输出) | ✅ 完成 |
| `04-key-pass-details.md` | 关键 pass 绑定详情 + 依赖链 (T4+T5 输出) | ✅ 完成 |
| `05-attachment-dependencies.md` | (合并到 04) | — |
| `06-final-render-pipeline.md` | 最终渲染流程 (T6 输出) | ✅ 完成 |
