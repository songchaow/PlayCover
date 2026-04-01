# 渲染流程分析 — 任务 Dashboard

## 背景

当前 Xcode 打开了原神 (com.miHoYo.Yuanshen) 的 GPU Frame Capture 文件 `capture_20260401_011127.gputrace`。该帧包含 **23 个 Command Buffer**、**50 个 shader pass** (Pipeline State 模式下)。我们通过 `xcode_gpu_ops.py` 工具库自动化操控 Xcode GUI 来提取和分析整帧的渲染流程。

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
- [ ] **T1: 收集 Command Buffer 概览** — 逐个展开 CB，记录每个 CB 下的 Render Encoder 数量和名称
- [ ] **T2: 收集 Render Pass 摘要** — 对每个 RE 读取 breadcrumb（shader 名 + draw call 描述），不需要完整 editor 数据
- [ ] **T3: 整理渲染管线阶段** — 根据 T1/T2 数据，按 shader 名和 attachment 推断各 pass 属于哪个渲染阶段

### P1 — 关键 Pass 深入分析
- [ ] **T4: 收集关键 pass 的完整绑定表** — 对主要渲染阶段的代表性 pass 使用 `editor` 获取完整资源绑定
- [ ] **T5: 分析 Attachment 依赖链** — 记录哪些 pass 写入了哪些 texture，哪些 pass 读取了它们

### P2 — 输出与优化
- [ ] **T6: 生成最终渲染流程文档** — 结合所有数据，输出人类可读的整帧渲染流程
- [ ] **T7: 完善工具脚本** — 根据分析过程中发现的需求，扩展 `xcode_gpu_ops.py`

## 当前最高优先级

**T1: 收集 Command Buffer 概览** — 这是所有后续分析的基础。需要逐个展开 23 个 CB，记录 RE 列表。

## 踩坑与经验

- **`editor` 操作耗时 30s**：逐 draw call 调用 editor 不现实。批量分析应优先用 `breadcrumbs`（0.3s）+ Pipeline State 模式 `nav`（4s）
- **展开节点需要 cliclick**：JXA `.click()` 对 disclosure triangle 无效，必须用 `cliclick c:x,y` 坐标点击
- **所有 CB 初始都是折叠的**：每个 CB 需要先 `expand` 才能看到 RE 子节点
- **breadcrumb 不需要 entireContents**：通过精确 UI 路径 `edGroup > [0] > [0] > Jump Bar > popUpButtons` 读取，速度 0.25s
- **步进操作会跨 CB**：`step_next_draw_call()` 到达一个 CB 末尾时会自动跳到下一个 CB

## 数据文件

| 文件 | 说明 | 状态 |
|---|---|---|
| `00-dashboard.md` | 本文档 | 持续更新 |
| `01-command-buffer-overview.md` | CB 概览 (T1 输出) | 待创建 |
| `02-render-pass-summary.md` | RE 摘要 (T2 输出) | 待创建 |
| `03-pipeline-stages.md` | 管线阶段划分 (T3 输出) | 待创建 |
| `04-key-pass-details.md` | 关键 pass 绑定详情 (T4 输出) | 待创建 |
| `05-attachment-dependencies.md` | Attachment 依赖链 (T5 输出) | 待创建 |
| `06-final-render-pipeline.md` | 最终渲染流程 (T6 输出) | 待创建 |
