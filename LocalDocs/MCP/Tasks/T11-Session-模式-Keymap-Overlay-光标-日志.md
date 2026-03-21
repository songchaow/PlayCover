### T11 - Session 模式、Keymap、Overlay、光标、日志

## dashboard

- **任务编号**: `T11`
- **状态**: `未开始`
- **层级**: `Session MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成运行期控制类工具，不处理复杂输入动作编排
- **依赖任务**: `T08`
- **主产物**:
  - `session_get_mode()`
  - `session_set_mode(mode)`
  - `switch_keymap(name|next|prev)`
  - `toggle_debug_overlay(enable)`
  - `hide_cursor()`
  - `unhide_cursor()`
  - `center_cursor()`
  - `touchlog_enable(enable)`
  - `touchlog_mark(label)`
  - `touchlog_read()`
- **主要风险**:
  - 把编辑器 UI 或复杂 keymap 编辑能力卷进来
  - 把宿主日志和触摸日志混为一谈
- **不包含内容**:
  - 高级手势
  - Host keymap CRUD
  - attach 调试

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T08-Session-Bridge与会话骨架.md`

---

## 背景与目标

除了输入动作外，PlayCover 的 injected 层还具备一组很适合远程控制的运行期操作：

- 切换控制模式
- 切换 keymap
- 打开 / 关闭 debug overlay
- 控制光标
- 读取或标记触摸日志

本任务要把这批“运行期控制状态能力”整理成 Session 工具。

---

## 范围（In Scope）

- 基于 `ControlMode` 暴露 `session_get_mode()` 与 `session_set_mode(mode)`
- 基于运行期 `Keymapping` 暴露 `switch_keymap(name|next|prev)`
- 基于 `MenuController` / `DebugController` 暴露 `toggle_debug_overlay(enable)`
- 基于 `AKPlugin` 暴露 `hide_cursor()` / `unhide_cursor()` / `center_cursor()`
- 基于 `Toucher` 暴露 `touchlog_enable(enable)` / `touchlog_mark(label)` / `touchlog_read()`

---

## 明确不做（Out of Scope）

- 不实现 keymap 编辑器 UI 的全部动作
- 不实现宿主侧 keymap CRUD
- 不实现高级手势
- 不实现截图或文本输入

---

## 主要代码入口

优先复用：

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ControlMode.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ModeAutomaton.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Keymap/Keymapping.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/MenuController.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugController.swift`
- `Carthage/Checkouts/PlayTools/AKPlugin.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`

---

## 推荐接口语义

### Mode

- `session_get_mode()` 返回当前 mode
- `session_set_mode(mode)` 对非法 mode 返回结构化错误

### Keymap

- `switch_keymap(next|prev|name)`
- 如果 `name` 当前不易直切，可先做 `next/prev` + 明确 limitation

### Overlay

- `toggle_debug_overlay(enable)`

### Cursor

- `hide_cursor()`
- `unhide_cursor()`
- `center_cursor()`

### Touch log

- `touchlog_enable(enable)`
- `touchlog_mark(label)`
- `touchlog_read()`

---

## 完成标准

- Session bridge 可控制 mode / keymap / overlay / cursor / touchlog
- 宿主 keymap CRUD 没被混入当前任务
- 返回结构与 `T08` 约定一致
- 每项工具边界清楚，错误结果可读

---

## 给 agent 的执行提示

- 本任务属于“运行期控制面板”，不是“输入动作面板”
- 若 `switch_keymap(name)` 一次难落地，可先保证 `next/prev` 成立，并在结果中写清限制
- `touchlog_read()` 只需做最小可用版本，不必实现复杂分页或 streaming

---

## 最后一步（必须执行）

在本任务相关修改完成后，最后必须补做一次提交收尾：

1. 检查本任务涉及的修改是否齐全
2. 将当前 task 的全部修改一起纳入本次提交，但不要混入其他 task 的无关变更：
   - 代码
   - 文档
   - 如有必要的配置 / 工程文件
3. 执行一次 `git commit`，为当前 task 形成独立提交
4. 提交信息建议包含任务编号，例如：
   - `T11: add session control tools`
   - `T11: expose touch log and mode APIs`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
