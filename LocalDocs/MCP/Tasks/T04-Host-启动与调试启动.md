### T04 - Host 启动与调试启动

## dashboard

- **任务编号**: `T04`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成普通启动与 LLDB 调试启动的 Host 闭环
- **依赖任务**: `T01`, `T02`
- **主产物**:
  - `launch_app(bundle_id, debug=false, terminal=false)`
  - 与启动相关的结构化返回
- **主要风险**:
  - 把 attach 调试误做进来
  - 为了追求完美状态回传而做出过大改造
- **不包含内容**:
  - `attach_debugger`
  - `stop_app`
  - `restart_app`

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T01-Host-骨架与协议.md`
5. `LocalDocs/MCP/Tasks/T02-Host-应用查询与状态.md`

---

## 背景与目标

当前 `PlayCover` 已经支持：

- 正常启动 app
- 以 LLDB 启动 app
- 选择是否在 Terminal 中打开 LLDB

本任务的目标是把这套能力以 Host MCP 工具形式暴露出来，并且明确区分：

- **launch under debugger**：本任务内实现
- **attach to running process**：本任务明确不做

---

## 范围（In Scope）

- 复用 `PlayApp.launch()` 暴露 `launch_app(bundle_id, debug=false, terminal=false)`
- 让调用方可以选择：
  - 普通启动
  - LLDB 启动
  - LLDB + Terminal 启动
- 将启动结果做结构化返回
- 在返回中说明当前是 normal launch 还是 debug launch
- 对显而易见的失败场景给出可读错误信息

---

## 明确不做（Out of Scope）

- 不实现 `attach_debugger`
- 不实现 PID 暴露
- 不实现停止 / 重启
- 不实现完整 session 状态系统
- 不实现运行后自动获取 injected session

---

## 主要代码入口

优先复用：

- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Views/AppSettingsView.swift`
- `PlayCover/Utils/Extensions/PlayAppExtensions.swift`

特别关注：

- `PlayApp.launch()`
- `PlayApp.runAppExec()`
- `Shell.lldb(_:, withTerminalWindow:)`

---

## 建议 API 语义

### `launch_app(bundle_id, debug=false, terminal=false)`

建议：

- `debug=false` 时走正常启动
- `debug=true` 时走 LLDB 启动
- `terminal=true` 仅在 `debug=true` 时生效

建议返回：

- `bundle_id`
- `launch_mode`（`normal` / `lldb` / `lldb_terminal`）
- `accepted`
- `message`
- `warnings`

如果当前无法同步确认“已经运行成功”，可明确返回“已发起启动请求”而不是伪造最终状态。

---

## 完成标准

- 可通过 MCP 正常启动指定 app
- 可通过 MCP 用 LLDB 启动指定 app
- 可通过 MCP 选择在 Terminal 中调起 LLDB
- 文档或返回值中明确说明：这不是 attach 调试
- 未越界实现 attach / stop / restart

---

## 给 agent 的执行提示

- 本任务最重要的是把“debug launch”和“attach”分清楚
- 如果 `PlayApp.launch()` 内部依赖某些 UI 状态，请尽量在服务层包一层，而不是改成新的启动流程
- 返回值允许是 best-effort，不必为了同步拿到完整运行状态引入大型会话管理

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
   - `T04: add app launch tools`
   - `T04: expose lldb launch mode`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
