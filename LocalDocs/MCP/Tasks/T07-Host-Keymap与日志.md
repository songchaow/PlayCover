### T07 - Host Keymap 与日志

## dashboard

- **任务编号**: `T07`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成宿主侧 keymap 管理与日志读取工具
- **依赖任务**: `T01`, `T02`
- **主产物**:
  - `list_keymaps(bundle_id)`
  - `create_keymap(bundle_id, name)`
  - `rename_keymap(bundle_id, old_name, new_name)`
  - `delete_keymap(bundle_id, name)`
  - `import_keymap(bundle_id, path)`
  - `export_keymap(bundle_id, name, path)`
  - `host_logs_read()`
  - `host_logs_clear()`
- **主要风险**:
  - 把运行期 keymap 切换逻辑也做进来
  - 误触及编辑器 UI 或 keymap 可视化编辑器范围
- **不包含内容**:
  - Session 运行期 `switch_keymap`
  - Session editor 模式
  - 触摸日志

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

宿主层已经具备 keymap 文件管理和日志缓存能力，但入口分散在工具类与 UI 逻辑中。  
本任务要将这类“宿主文件管理能力”整理成稳定的 Host MCP 工具。

---

## 范围（In Scope）

- 暴露宿主侧 keymap 的列出、创建、改名、删除
- 暴露 keymap 导入 / 导出
- 暴露宿主日志读取
- 暴露宿主日志清空
- 保持结果结构化，便于后续自动化调用

---

## 明确不做（Out of Scope）

- 不实现运行中 app 的 `switch_keymap`
- 不实现 editor 模式的 UI 操作
- 不实现触摸日志读取（属于 `T11`）
- 不实现日志流式订阅

---

## 主要代码入口

优先复用：

- `PlayCover/Utils/Keymapping.swift`
- `PlayCover/Model/KeymapData.swift`
- `PlayCover/ViewModel/Log.swift`

如果需要 app 维度映射，可复用：

- `PlayApp`
- `AppInfo`

---

## 推荐 API 划分

### Keymap

- `list_keymaps(bundle_id)`
- `create_keymap(bundle_id, name)`
- `rename_keymap(bundle_id, old_name, new_name)`
- `delete_keymap(bundle_id, name)`
- `import_keymap(bundle_id, path)`
- `export_keymap(bundle_id, name, path)`

### 日志

- `host_logs_read()`
- `host_logs_clear()`

建议 `host_logs_read()` 支持：

- 全量文本
- 或最近 N 行 / N 字符的可选参数

但不要在本任务中做复杂分页系统。

---

## 完成标准

- Host 可完成宿主层 keymap CRUD 与导入导出
- Host 可读取和清空日志缓存
- 运行期 keymap 切换未被卷入本任务
- 日志工具不会依赖 UI 层操作

---

## 给 agent 的执行提示

- 本任务只做“宿主静态资源管理”，不要混到 injected 运行期
- 如果导入 / 导出能力已有现成 helper，优先直接复用
- 日志读取能力尽量保持无副作用；`clear` 单独作为显式工具

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
   - `T07: add host keymap tools`
   - `T07: expose host log tools`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
