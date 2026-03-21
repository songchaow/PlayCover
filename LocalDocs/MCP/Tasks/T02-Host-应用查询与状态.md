### T02 - Host 应用查询与状态

## dashboard

- **任务编号**: `T02`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `S-M`
- **推荐单次执行范围**: 一次 agent 执行完成查询类 Host 工具的最小闭环
- **依赖任务**: `T01`
- **主产物**:
  - `list_apps()`
  - `get_app_info(bundle_id)`
  - `app_status(bundle_id)` 的首版实现
- **主要风险**:
  - 把“状态”做成进程级强一致会话系统，超出本任务边界
- **不包含内容**:
  - 启动、安装、卸载、attach 调试

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T01-Host-骨架与协议.md`

---

## 背景与目标

本任务负责把“只读查询类能力”先稳定下来，让后续安装、启动、配置类工具都能基于统一的 app 查询模型工作。

核心目标：

- 枚举 PlayCover 已安装 app
- 读取 app 元数据
- 给出一个首版 app 状态接口

---

## 范围（In Scope）

- 基于 `AppsVM.fetchApps()` 暴露 `list_apps()`
- 基于 `AppInfo` 暴露 `get_app_info(bundle_id)`
- 提供 `app_status(bundle_id)` 的首版结果
- 将返回结果统一为 `T01` 中约定的结构
- 尽量给出稳定字段，例如：
  - `installed`
  - `has_playtools`
  - `debug_capable`
  - `best_effort_running`
  - `best_effort_active`

---

## 明确不做（Out of Scope）

- 不在本任务内实现真正的会话管理
- 不要求返回 `pid`
- 不要求实现 attach 或 stop / restart
- 不要求为了 `app_status` 引入复杂后台轮询框架

---

## 主要代码入口

优先复用：

- `PlayCover/ViewModel/AppsVM.swift`
- `PlayCover/Model/AppInfo.swift`
- `PlayCover/Model/BaseApp.swift`
- `PlayCover/Model/PlayApp.swift`

如需判断 `PlayTools` 注入状态，可参考：

- `PlayApp.hasPlayTools()`

---

## 推荐 API 结果字段

### `list_apps()`

建议每个 app 至少返回：

- `bundle_id`
- `display_name`
- `version`
- `path`
- `has_playtools`

### `get_app_info(bundle_id)`

建议包含：

- `bundle_id`
- `display_name`
- `bundle_name`
- `version`
- `executable_name`
- `minimum_os_version`
- `category`
- `icon_name`（若方便）
- `has_playtools`

### `app_status(bundle_id)`

建议先做 best-effort：

- `installed`
- `launching`（如当前拿不到，可先不实现）
- `running`（best-effort）
- `active`（best-effort）
- `terminated`（如当前无会话，可不承诺）
- `debug_mode`（如能判断）

---

## 完成标准

- 能通过 Host MCP 调用列出 app
- 能通过 `bundle_id` 返回结构化 app 信息
- `app_status` 有首版定义，并明确哪些字段是 best-effort
- 结果结构与 `T01` 骨架一致
- 没有把本任务扩展成完整会话系统

---

## 给 agent 的执行提示

- 本任务最重要的是“统一查询视图”，不是“完美状态机”
- 如果发现状态字段做不强一致，请明确标为 best-effort，而不是硬凑
- 尽量保持查询类接口只读、无副作用

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
   - `T02: add host app query tools`
   - `T02: implement app status endpoints`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
