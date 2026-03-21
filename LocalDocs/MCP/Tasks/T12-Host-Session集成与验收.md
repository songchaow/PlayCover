### T12 - Host-Session 集成与验收

## dashboard

- **任务编号**: `T12`
- **状态**: `未开始`
- **层级**: `Cross / 集成`
- **工作量**: `M-L`
- **推荐单次执行范围**: 一次 agent 执行完成 Host 与 Session 的最小闭环打通和文档收口
- **依赖任务**: `T02-T11`
- **主产物**:
  - Host 与 Session 的最小联通路径
  - 最小 smoke 验证流程
  - 文档更新与工具清单收口
- **主要风险**:
  - 顺手补太多新功能
  - 把收口任务做成第二轮架构重写
- **不包含内容**:
  - attach 调试实现
  - stop / restart / screenshot / text input

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. 所有已完成的 `T01-T11` 任务卡

---

## 背景与目标

前面各任务分别交付 Host 与 Session 的单点能力；本任务的目标不是新增功能，而是让它们形成一个清晰、最小的端到端闭环，并把边界再次写清楚，方便后续继续分发任务。

---

## 范围（In Scope）

- 检查 Host 与 Session 的工具命名、返回结构是否一致
- 打通最小链路，例如：
  - Host 查询 app
  - Host 启动 app
  - Session 可被发现或可用
  - Session 执行一次 `tap`
- 整理最小 smoke test 步骤
- 更新文档中实际已交付的工具清单
- 记录已知限制与下一步 backlog

---

## 明确不做（Out of Scope）

- 不在本任务内再新增大块新功能
- 不实现 attach 调试
- 不实现 stop / restart / screenshot / text input
- 不重写 Host / Session 协议层

---

## 推荐验收闭环

建议至少覆盖以下闭环：

1. `list_apps()`
2. `get_app_info(bundle_id)`
3. `launch_app(bundle_id, debug=false)`
4. `session_status()`
5. `tap(x, y)`
6. `session_get_mode()` / `session_set_mode(mode)`
7. `host_logs_read()` 或 `touchlog_read()` 至少一项

如果某些步骤依赖当前运行环境难以稳定自动验证，应在文档里明确标注为“手动 smoke step”。

---

## 结果文档建议

本任务完成后，建议至少补充：

- 已实现工具清单
- 尚未实现工具清单
- 运行依赖 / 已知限制
- 推荐下一轮任务起点

---

## 完成标准

- Host 与 Session 至少存在一条端到端最小可工作路径
- 已有工具命名和返回结构基本收口
- 文档已更新到可以继续指导下一轮 agent 工作
- 本任务未扩展成新一轮大开发

---

## 给 agent 的执行提示

- 这是收口任务，不是新功能主战场
- 如果发现前置任务有明显不兼容点，应优先做薄修正与文档说明，而不是整块返工
- 优先交付“可说明、可复现、可继续接力”的集成结果

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
   - `T12: integrate host and session MCP`
   - `T12: add end-to-end smoke coverage`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
