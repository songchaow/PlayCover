### T05 - Host 数据清理与容器重置

## dashboard

- **任务编号**: `T05`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `S-M`
- **推荐单次执行范围**: 一次 agent 执行完成所有数据清理相关 Host 工具
- **依赖任务**: `T01`, `T02`
- **主产物**:
  - `clear_cache(bundle_id)`
  - `clear_preferences(bundle_id)`
  - `clear_playchain(bundle_id)`
  - `reset_container(bundle_id)`
- **主要风险**:
  - 误把卸载逻辑混进来
  - 删除路径不清晰导致副作用扩大
- **不包含内容**:
  - 卸载 app
  - stop / restart
  - 运行期 Session 清理

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

PlayCover 已具备多种清理能力，但目前入口分散：

- 清缓存
- 清 Preferences
- 清 PlayChain
- 清整个容器

本任务的目标是把这些能力整理成稳定的 Host MCP 工具。

---

## 范围（In Scope）

- 基于现有逻辑暴露 `clear_cache(bundle_id)`
- 将 View 中的 `deletePreferences(app:)` 逻辑抽成可复用服务并暴露 `clear_preferences(bundle_id)`
- 暴露 `clear_playchain(bundle_id)`
- 暴露 `reset_container(bundle_id)`
- 每个工具返回明确的删除范围与结果

---

## 明确不做（Out of Scope）

- 不实现 uninstall
- 不把多个清理工具强行合并成一个巨大的“reset all”工具
- 不处理运行中 app 的强制结束
- 不改造 Session 层数据路径

---

## 主要代码入口

优先复用：

- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/AppContainer.swift`
- `PlayCover/Views/App Views/PlayAppView.swift`

特别关注：

- `Uninstaller.clearExternalCache(_:)`
- `PlayApp.clearAllCache()`
- `PlayApp.clearPlayChain()`
- `AppContainer.clear()`
- `deletePreferences(app:)`

---

## 推荐 API 结果字段

每个工具建议至少返回：

- `bundle_id`
- `performed`
- `paths_touched`
- `warnings`

对 `reset_container(bundle_id)`，建议额外返回：

- `container_path`
- `container_existed`

---

## 完成标准

- 四个清理工具都可独立调用
- `clear_preferences` 不再依赖 View 层直接调用
- 删除路径边界清晰、结果结构化
- 没有把任务扩展成卸载或停止逻辑

---

## 给 agent 的执行提示

- 删除能力必须非常保守，优先复用现有路径计算逻辑
- 若现有逻辑覆盖范围模糊，请在返回中加入 warning，而不是静默扩大删除范围
- `reset_container` 是本任务里的高价值点，因为当前代码虽然有基础能力，但未正式暴露

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
   - `T05: add data cleanup tools`
   - `T05: expose reset container tool`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
