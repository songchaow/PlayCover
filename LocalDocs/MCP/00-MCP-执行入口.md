### PlayCover MCP 执行入口

## 文档目的

本文档用于给后续多个 agent 提供统一的执行入口，确保每次只完成一个边界清晰、工作量适中的子任务，避免超出工作范围、重复造轮子或跨任务修改过多代码。

本文档不是调研结论本身，而是 **任务编排与执行约定**。功能调研、代码入口、能力边界请优先参考：

- `PlayCover-MCP-调研结论.md`

---

## 阅读顺序

每次启动一个新的 agent 时，建议让其按以下顺序阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. 当前要执行的任务卡，例如：`LocalDocs/MCP/Tasks/T03-Host-安装与卸载.md`

如果 agent 只读一份任务卡而不读前两份总文档，通常会缺少：

- 全局能力边界
- 当前阶段不做的内容
- 任务间依赖关系
- 统一的命名 / 返回结构 / 验收原则

---

## 目录结构

当前 `LocalDocs/MCP` 目录建议按下面结构使用：

- `PlayCover-MCP-调研结论.md`
- `00-MCP-执行入口.md`
- `01-MCP-任务总表.md`
- `Tasks/`
  - `T01-Host-骨架与协议.md`
  - `T02-Host-应用查询与状态.md`
  - `T03-Host-安装与卸载.md`
  - `T04-Host-启动与调试启动.md`
  - `T05-Host-数据清理与容器重置.md`
  - `T06-Host-配置-签名-注入.md`
  - `T07-Host-Keymap与日志.md`
  - `T08-Session-Bridge与会话骨架.md`
  - `T09-Session-基础触控.md`
  - `T10-Session-高级手势与摇杆.md`
  - `T11-Session-模式-Keymap-Overlay-光标-日志.md`
  - `T12-Host-Session集成与验收.md`
  - `T13-预留-运行中进程Attach调试.md`

---

## 本轮总体目标

本轮目标不是一次性把所有高级自动化能力全部做完，而是先把 `PlayCover` 中适合 MCP 暴露的核心能力按两层落地：

- **Host MCP**：宿主进程中的应用管理与生命周期能力
- **Session MCP**：运行中 app 进程内的输入、模式和状态能力

本轮任务拆分将覆盖我此前建议的核心功能清单：

### Host MCP

- `list_apps()`
- `get_app_info(bundle_id)`
- `install_ipa(path)`
- `uninstall_app(bundle_id, options)`
- `launch_app(bundle_id, debug=false, terminal=false)`
- `app_status(bundle_id)`
- `clear_cache(bundle_id)`
- `clear_preferences(bundle_id)`
- `clear_playchain(bundle_id)`
- `reset_container(bundle_id)`
- `sign_app(bundle_id)`
- `inject_playtools(bundle_id)`
- `remove_playtools(bundle_id)`
- `get_app_settings(bundle_id)`
- `set_app_settings(bundle_id, patch)`
- `list_keymaps(bundle_id)`
- `create_keymap(bundle_id, name)`
- `rename_keymap(bundle_id, old_name, new_name)`
- `delete_keymap(bundle_id, name)`
- `host_logs_read()`
- `host_logs_clear()`

### Session MCP

- `session_status()`
- `session_get_mode()`
- `session_set_mode(mode)`
- `tap(x, y)`
- `pointer_down(id, x, y)`
- `pointer_move(id, x, y)`
- `pointer_up(id, x, y)`
- `drag(from, to, duration)`
- `swipe(path)`
- `pinch(center, scale)`
- `button(name, pressed)`
- `thumbstick(name, x, y)`
- `switch_keymap(name|next|prev)`
- `toggle_debug_overlay(enable)`
- `hide_cursor()`
- `unhide_cursor()`
- `center_cursor()`
- `touchlog_enable(enable)`
- `touchlog_mark(label)`
- `touchlog_read()`

### 暂缓项

以下能力会在文档中保留设计位，但**当前批次允许暂不实现**：

- `attach_debugger(pid|bundle_id)`

以下能力暂不进入本轮主任务拆分，只在后续需要时再单独拆：

- `stop_app(bundle_id)`
- `restart_app(bundle_id)`
- `type_text(...)`
- `screenshot()`
- `screen_recording()`

---

## 全局执行原则

## 1. 每次只执行一个任务卡

一个 agent 一次只做一个 `Txx` 文档中定义的任务。

不要在一次执行中顺手完成多个任务，除非任务卡里明确允许一并补齐非常小的收尾项。

## 2. 优先复用现有代码入口

能复用现有类 / 方法时，不要先做大重构。

本轮的主要目标是：

- 抽服务层
- 建统一协议层
- 暴露结构化 MCP 工具
- 消除 UI 弹窗对自动化路径的阻塞

而不是先全面改造 PlayCover 内部架构。

## 3. Host 与 Session 分层必须保持清楚

- 宿主层职责：安装、卸载、启动、配置、签名、文件级管理、日志读取
- injected 层职责：点击、拖拽、模式切换、overlay、光标、运行期 keymap、触摸日志

如果一个能力天然发生在目标 app 进程内部，不要强行把它绕回宿主层完成。

## 4. 尽量避免跨任务修改过多公共接口

如果当前任务需要公共类型扩展：

- 只增加当前任务必须的字段
- 不要提前把后续任务的所有字段一次性定义完
- 如需为后续预留扩展点，可以在文档中说明，但代码改动仍保持最小

## 5. 输出应尽量结构化

每个 MCP 工具都建议有稳定返回：

- `ok`
- `message`
- `data`
- `warnings`
- `debug`

即使当前只是内部工具，也建议在第一批任务里尽量统一风格。

---

## 每个任务卡中的 dashboard 字段说明

每个任务卡都会带一个 `dashboard`，用于帮助 agent 快速判断是否适合当前执行。字段定义如下：

- **任务编号**：唯一 ID，例如 `T04`
- **状态**：`未开始` / `进行中` / `已完成` / `暂缓`
- **工作量**：`XS` / `S` / `M` / `L`
- **推荐单次执行范围**：建议一次 agent 执行可覆盖的边界
- **依赖任务**：执行前最好已经完成的任务
- **主产物**：本任务应该交付的代码或文档成果
- **主要风险**：本任务最可能导致跑偏的点
- **不包含内容**：明确不在这次任务里做的东西

### 工作量参考

- **XS**：很小，通常只涉及单点补齐
- **S**：小到中等，一次 agent 执行可稳定完成
- **M**：中等，可能涉及多个文件但边界明确
- **L**：较大，建议做成一个收口或集成任务，不要顺带扩 scope

---

## 对 agent 的统一提示语建议

每次启动 agent 时，建议在任务指令中明确要求：

- 先阅读：
  - `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
  - `LocalDocs/MCP/00-MCP-执行入口.md`
  - `LocalDocs/MCP/01-MCP-任务总表.md`
  - 当前任务卡
- 严格遵守任务卡中的 `范围 / 非目标 / 完成标准`
- 如果中途发现需要依赖未完成任务，不要强行越界实现，应在结果中说明阻塞点
- 若当前任务只需完成一个最小可工作的垂直切片，应优先交付可工作的切片，而不是过度预实现

可直接复用的提示模板：

> 请先阅读 `LocalDocs/MCP/PlayCover-MCP-调研结论.md`、`LocalDocs/MCP/00-MCP-执行入口.md`、`LocalDocs/MCP/01-MCP-任务总表.md`，然后严格按照 `LocalDocs/MCP/Tasks/Txx-...md` 执行当前任务。不要超出任务文档边界；如发现前置未完成，请说明阻塞点并尽量只完成本任务范围内可落地的部分。

---

## 推荐执行策略

建议将任务分三批推进：

### 第一批：Host 基础能力

- `T01`
- `T02`
- `T03`
- `T04`
- `T05`
- `T06`
- `T07`

### 第二批：Session 能力

- `T08`
- `T09`
- `T10`
- `T11`

### 第三批：收口与保留项

- `T12`
- `T13`（设计保留，允许暂不实现）

---

## 当前建议

如果后续要多 agent 并行，建议优先并行这些组合：

- `T02` 与 `T05`
- `T03` 与 `T07`
- `T04` 与 `T06`
- `T09` 与 `T11`

但前提是：

- `T01` 已完成或至少完成最小协议骨架
- `T08` 已完成或至少完成 Session bridge 骨架

---

## 最终目标状态

当 `T01` 到 `T12` 完成后，应该形成：

- 宿主侧一组稳定的 MCP 工具
- 注入侧一组稳定的 Session 工具
- Host 能够启动 app，并在需要时进入 debug launch 模式
- Session 能够完成基础触控、手势、模式、overlay、keymap、日志等远程控制能力
- 文档足够支持后续继续拆 `attach_debugger` 等增强功能

`T13` 作为保留任务存在，用于避免后续重复调研 attach 问题。