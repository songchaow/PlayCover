### T10 - Session 高级手势与摇杆

## dashboard

- **任务编号**: `T10`
- **状态**: `已完成`
- **层级**: `Session MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成复合手势与摇杆类输入工具
- **依赖任务**: `T08`, `T09`
- **主产物**:
  - `drag(from, to, duration)`
  - `swipe(path)`
  - `pinch(center, scale)`
  - `button(name, pressed)`
  - `thumbstick(name, x, y)`
- **主要风险**:
  - 直接耦合 UI 编辑器或本地事件适配器
  - 手势语义定义过于复杂，超出单次执行范围
- **不包含内容**:
  - mode / keymap / overlay / cursor
  - attach 调试

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T08-Session-Bridge与会话骨架.md`
5. `LocalDocs/MCP/Tasks/T09-Session-基础触控.md`

---

## 背景与目标

PlayCover 的运行期输入不只支持单点点击，还已经有成熟的拖拽、滑动、缩放、摇杆和按钮动作模型。  
本任务的目标是将这些已有能力抽象成结构化 Session 工具。

---

## 范围（In Scope）

- 暴露 `drag(from, to, duration)`
- 暴露 `swipe(path)`
- 暴露 `pinch(center, scale)`
- 暴露 `button(name, pressed)`
- 暴露 `thumbstick(name, x, y)`
- 尽量复用现有动作模型或基础 pointer 原语

---

## 明确不做（Out of Scope）

- 不实现 mode 切换
- 不实现 keymap 切换
- 不实现 debug overlay
- 不实现 cursor / touchlog
- 不实现图像或文本输入能力

---

## 主要代码入口

优先复用：

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/ActionDispatcher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Action/PlayAction.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`

特别关注现有类型：

- `DraggableButtonAction`
- `SwipeAction`
- `CameraAction`
- `JoystickAction`
- `ContinuousJoystickAction`
- `FakeMouseAction`

---

## 设计建议

优先级建议：

1. `drag`
2. `swipe`
3. `button`
4. `thumbstick`
5. `pinch`

如果一次执行难以把五项都做到完全理想，优先把前四项做成可工作版本，`pinch` 可做最小闭环。

建议返回：

- 参数回显
- 是否 accepted
- 实际使用的内部动作路径或 warning

---

## 完成标准

- 能通过 Session bridge 执行高级手势或等价动作
- 至少 `drag` / `swipe` / `thumbstick` 可稳定工作
- 与 `T09` 的基础 pointer 语义保持一致
- 未将任务扩展到 mode / overlay / keymap 侧

---

## 给 agent 的执行提示

- 本任务是“输入动作层”，不是“UI 状态层”
- 能复用已有动作类时，不要绕回本地 `NSEvent` 模拟
- 若某一高级动作短期难做，请优先保证接口语义清楚，并交付最小工作版本

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
   - `T10: add advanced gesture tools`
   - `T10: expose thumbstick controls`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
