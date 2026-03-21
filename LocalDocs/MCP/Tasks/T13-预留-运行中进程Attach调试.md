### T13 - 预留：运行中进程 Attach 调试

## dashboard

- **任务编号**: `T13`
- **状态**: `暂缓`
- **层级**: `Backlog / 调试增强`
- **工作量**: `S`（仅设计） / `M`（若进入实现）
- **推荐单次执行范围**: 当前仅允许做设计澄清与前置条件整理，不要求实现
- **依赖任务**: `T04`, `T12`
- **主产物**:
  - attach 调试设计说明
  - 所需前置能力列表
  - 如果未来实现，推荐的最小路径
- **主要风险**:
  - 当前阶段硬做 attach，导致范围明显失控
- **不包含内容**:
  - 本轮默认不实现 `attach_debugger`

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T04-Host-启动与调试启动.md`
5. `LocalDocs/MCP/Tasks/T12-Host-Session集成与验收.md`

---

## 当前结论

本项目目前已有的是：

- **用 LLDB 启动 app 调试**

本项目目前未见现成实现的是：

- **attach 到一个已经运行中的 app 进程**

也就是说，当前具备的是：

- `launch under debugger`

而不是：

- `attach to running process`

---

## 本任务当前只做什么

当前阶段，本任务只需要：

- 把 attach 调试的设计边界写清楚
- 记录为什么当前不建议立即实现
- 列出未来实现所需前置能力

如果没有明确指示，不要在本任务中直接编码实现。

---

## 若未来进入实现，最小前置条件

建议先补齐：

- 启动后保存 `NSRunningApplication` 引用
- 统一进程 / session 状态记录
- 暴露 `pid`
- 新增 `Shell.lldbAttach(pid)` 或等价封装
- 明确按 `bundle_id` 找到目标运行实例的策略

---

## 未来可能的 API

- `attach_debugger(pid)`
- `attach_debugger(bundle_id)`

建议返回：

- `attached`
- `pid`
- `bundle_id`
- `debugger_mode = attach`
- `message`
- `warnings`

---

## 当前为什么暂缓

主要原因：

- 当前没有稳定 PID 管理
- 当前没有正式运行实例会话层
- 当前更高优先级的是先把 Host / Session 主能力闭环做好
- attach 能力很容易引入额外平台限制与调试权限问题

---

## 完成标准

如果当前只是设计阶段，则满足以下条件即可：

- 文档中已明确区分“debug launch”和“attach debug”
- 已列出未来实现所需的前置改造
- 已明确本轮默认不实现 attach

如果未来单独明确要求实现，再把此任务升级为正式实现任务。

---

## 给 agent 的执行提示

- 当前默认不要编码实现 attach
- 若被要求评估可行性，优先补设计文档而不是直接开工
- 任何 attach 实现都不应偷偷夹带进 `T04` 或 `T12`

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
   - `T13: document attach debugger backlog`
   - `T13: clarify attach design constraints`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
