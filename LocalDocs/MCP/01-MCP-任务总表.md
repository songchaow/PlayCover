### PlayCover MCP 任务总表

## 文档目的

本文档用于将 `PlayCover` 的 MCP 改造总体工作拆分为多个适合单次执行的子任务，并为后续多 agent 协作提供统一总览。

全局背景与代码调研请参考：

- `PlayCover-MCP-调研结论.md`
- `00-MCP-执行入口.md`

---

## 任务总览表

| 任务 | 标题 | 层级 | 主要能力 | 依赖 | 工作量 | 建议是否首批执行 |
|---|---|---|---|---|---|---|
| `T01` | Host 骨架与协议 | Host | MCP 服务骨架、工具注册、统一返回结构、错误模型 | 无 | `M` | 是 |
| `T02` | Host 应用查询与状态 | Host | `list_apps` / `get_app_info` / `app_status` | `T01` | `S-M` | 是 |
| `T03` | Host 安装与卸载 | Host | `install_ipa` / `uninstall_app` | `T01` | `M` | 是 |
| `T04` | Host 启动与调试启动 | Host | `launch_app` / debug launch / terminal launch | `T01`,`T02` | `M` | 是 |
| `T05` | Host 数据清理与容器重置 | Host | `clear_cache` / `clear_preferences` / `clear_playchain` / `reset_container` | `T01`,`T02` | `S-M` | 是 |
| `T06` | Host 配置、签名与注入 | Host | `get/set_app_settings` / `sign_app` / `inject_playtools` / `remove_playtools` | `T01`,`T02` | `M` | 是 |
| `T07` | Host Keymap 与日志 | Host | keymap 管理 / `host_logs_read` / `host_logs_clear` | `T01`,`T02` | `M` | 是 |
| `T08` | Session Bridge 与会话骨架 | Session | session bridge、会话识别、`session_status` 骨架 | `T01` | `M-L` | 是 |
| `T09` | Session 基础触控 | Session | `tap` / `pointer_down` / `pointer_move` / `pointer_up` | `T08` | `M` | 是 |
| `T10` | Session 高级手势与摇杆 | Session | `drag` / `swipe` / `pinch` / `button` / `thumbstick` | `T08`,`T09` | `M` | 是 |
| `T11` | Session 模式、Keymap、Overlay、光标、日志 | Session | `session_get_mode` / `session_set_mode` / `switch_keymap` / `toggle_debug_overlay` / cursor / touchlog | `T08` | `M` | 是 |
| `T12` | Host-Session 集成与验收 | Cross | 端到端打通、工具清单收口、文档对齐、最小验收脚本 | `T02-T11` | `M-L` | 最后执行 |
| `T13` | 预留：运行中进程 Attach 调试 | Backlog | `attach_debugger(pid|bundle_id)` 设计位 | `T04`,`T12` | `S`（设计）/ `M`（实现） | 暂缓 |

---

## 推荐分批执行顺序

## 第一批：Host 能力建立

建议顺序：

1. `T01-Host-骨架与协议`
2. `T02-Host-应用查询与状态`
3. `T03-Host-安装与卸载`
4. `T04-Host-启动与调试启动`
5. `T05-Host-数据清理与容器重置`
6. `T06-Host-配置-签名-注入`
7. `T07-Host-Keymap与日志`

### 这一批完成后应具备

- Host MCP 基础框架
- 可查询 app、读取信息、获取状态
- 可安装 / 卸载 / 启动 / debug 启动
- 可清数据、改配置、签名、注入 `PlayTools`
- 可管理 keymap 与读取宿主日志

---

## 第二批：Session 能力建立

建议顺序：

1. `T08-Session-Bridge与会话骨架`
2. `T09-Session-基础触控`
3. `T10-Session-高级手势与摇杆`
4. `T11-Session-模式-Keymap-Overlay-光标-日志`

### 这一批完成后应具备

- injected 层可接收结构化远程调用
- 可完成点击、拖拽、滑动、缩放、摇杆等控制
- 可切换模式和 keymap
- 可管理 overlay、光标和触摸日志

---

## 第三批：收口与暂缓项

建议顺序：

1. `T12-Host-Session集成与验收`
2. `T13-预留-运行中进程Attach调试`

### 这一批完成后应具备

- Host 与 Session 从启动到远程控制的最小闭环
- 一份对后续 agent 友好的最新说明
- attach 调试的设计位与约束清晰化

---

## 并行建议

## 可并行组 A（Host）

在 `T01` 最小完成后，可以并行：

- `T02`
- `T03`
- `T05`

## 可并行组 B（Host）

在 `T02` 完成后，可以并行：

- `T04`
- `T06`
- `T07`

## 可并行组 C（Session）

在 `T08` 最小完成后，可以并行：

- `T09`
- `T11`

`T10` 更适合在 `T09` 完成后执行，因为它复用基础 pointer / touch 语义更自然。

---

## 任务边界控制原则

为了适配“单次执行”的 agent 任务，每个任务卡都遵守以下控制原则：

- 一次只做一个主要能力簇
- 能形成“最小可工作闭环”即可，不强求一次把所有边角补齐
- 若当前任务碰到前置缺失：
  - 优先完成当前边界内能做的部分
  - 再在结果中明确记录阻塞点
- 如果某功能天然横跨 Host 与 Session，则尽量拆成：
  - 本任务先做一侧
  - `T12` 再做集成收口
- 每个任务在结束时，默认都要以一次独立的 `git commit` 收尾：
  - 提交当前 task 的全部相关修改
  - 包括代码、文档，以及必要的配置 / 工程文件
  - 不要混入其他 task 的无关变更
  - 除非上层明确要求不要提交，否则不要留在“已改未提交”状态交付

---

## 当前总 dashboard

| 任务 | 状态 | 推荐 owner 类型 | 备注 |
|---|---|---|---|
| `T01` | `未开始` | 架构 / 协议型 agent | 影响后续所有 Host 任务 |
| `T02` | `未开始` | Host 实现 agent | 较适合先做 |
| `T03` | `未开始` | Host 实现 agent | 与安装链路相关，注意 UI 弹窗路径 |
| `T04` | `未开始` | Host 实现 agent | 关键在复用 `PlayApp.launch()` 和 `Shell.lldb(...)` |
| `T05` | `未开始` | Host 实现 agent | 逻辑相对独立 |
| `T06` | `未开始` | Host 实现 agent | 文件较多，注意范围控制 |
| `T07` | `未开始` | Host 实现 agent | 容易跑到 UI 层，需保持服务化 |
| `T08` | `未开始` | Session / 注入层 agent | 是 Session 任务前置 |
| `T09` | `未开始` | Session / 输入链路 agent | 优先级高 |
| `T10` | `未开始` | Session / 输入链路 agent | 依赖基础触控语义 |
| `T11` | `未开始` | Session / 运行期控制 agent | 注意不要混入高级截图类需求 |
| `T12` | `未开始` | 集成 / 验收 agent | 最后做 |
| `T13` | `暂缓` | 设计型 agent | 当前允许不实现 |

---

## 每次给 agent 的最小材料包

建议每次至少提供给 agent：

- `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
- `LocalDocs/MCP/00-MCP-执行入口.md`
- `LocalDocs/MCP/01-MCP-任务总表.md`
- 当前目标任务卡

如果任务是 Session 相关，再额外提醒 agent 重点看：

- `PlayLoader.m`
- `PlayCover.swift`
- `PlayInput.swift`
- `ControlMode.swift`
- `Toucher.swift`
- `PTFakeMetaTouch.m`

如果任务是 Host 相关，再额外提醒 agent 重点看：

- `PlayApp.swift`
- `Installer.swift`
- `Uninstaller.swift`
- `AppInfo.swift`
- `AppSettings.swift`
- `PlayTools.swift`
- `Shell.swift`

---

## 使用方式建议

后续你每次启动一个 agent 时，可以直接指定任务编号，例如：

- “请按 `LocalDocs/MCP/Tasks/T03-Host-安装与卸载.md` 执行，不要越界”
- “请按 `LocalDocs/MCP/Tasks/T09-Session-基础触控.md` 执行，只实现任务卡中的最小闭环”

这样做的好处是：

- agent 的工作界限更清楚
- 任务之间冲突更少
- 更容易并行推进
- 更容易做阶段性合并和回归验证

---

## 当前建议的起步顺序

如果只准备先启动少量 agent，建议先做：

1. `T01`
2. `T02`
3. `T04`
4. `T08`
5. `T09`

这是最有利于尽快形成“从 Host 启动 app，到 Session 执行点击”的闭环路径。

---

## 备注

`T13` 会保留单独任务卡，但定位是：

- 记录 attach 调试的设计结论
- 避免未来重复调研
- 当前批次不强制实现

因此后续安排 agent 时，可优先忽略 `T13`，先完成 `T01-T12`。