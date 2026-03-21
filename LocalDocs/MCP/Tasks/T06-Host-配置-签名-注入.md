### T06 - Host 配置、签名与注入

## dashboard

- **任务编号**: `T06`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成配置、签名与 `PlayTools` 注入能力的 Host 工具化
- **依赖任务**: `T01`, `T02`
- **主产物**:
  - `get_app_settings(bundle_id)`
  - `set_app_settings(bundle_id, patch)`
  - `sign_app(bundle_id)`
  - `inject_playtools(bundle_id)`
  - `remove_playtools(bundle_id)`
  - `set_launch_env(...)` 或等价能力
- **主要风险**:
  - 把配置字段一次性重构过头
  - 将运行期 Session 行为错误地放到 Host 层处理
- **不包含内容**:
  - 启动工具
  - Keymap 管理
  - Session 输入工具

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

PlayCover 的大量行为都依赖 per-app 配置、签名状态和 `PlayTools` 注入状态。  
本任务要做的是将这些“启动前准备能力”从 UI 配置页和零散 helper 中整理为 Host MCP 工具。

---

## 范围（In Scope）

- 暴露读取 app settings 的工具
- 暴露 patch 型修改 app settings 的工具
- 暴露签名 / 重签名工具
- 暴露安装 / 移除 `PlayTools` 工具
- 如有必要，补充对 `DYLD_LIBRARY_PATH` / introspection / iOS frameworks 相关启动环境配置的工具
- 返回结构化的配置变更结果

---

## 明确不做（Out of Scope）

- 不实现真正的启动动作
- 不实现运行期模式切换
- 不实现 keymap CRUD
- 不处理 attach 调试

---

## 主要代码入口

优先复用：

- `PlayCover/Model/AppSettings.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/AppInfo.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Entitlements.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`

特别关注：

- `PlayApp.sign()`
- `PlayApp.changeDyldLibraryPath(set:path:)`
- `PlayTools.installInIPA(_:)`
- `PlayTools.removeFromApp(_:)`

---

## 推荐 API 划分

- `get_app_settings(bundle_id)`
- `set_app_settings(bundle_id, patch)`
- `sign_app(bundle_id)`
- `inject_playtools(bundle_id)`
- `remove_playtools(bundle_id)`
- `has_playtools(bundle_id)`（若实现成本很低，可一并补齐）
- `set_launch_env(bundle_id, introspection, ios_frameworks)`

---

## 特别说明

对于 settings：

- 优先支持最稳定、已有明确存储路径的字段
- 如果 `openWithLLDB` / `openLLDBWithTerminal` 的持久化逻辑不清晰，可以：
  - 在本任务中只记录限制
  - 或做最小、清晰的补齐

对 patch 行为建议：

- 仅修改传入字段
- 返回修改前 / 修改后摘要或已应用字段列表

---

## 完成标准

- Host 能读取和修改 app settings
- Host 能触发签名 / 重签名
- Host 能安装 / 移除 `PlayTools`
- 配置与执行结果均为结构化返回
- 未将任务扩展到启动、Session 输入或 keymap 侧

---

## 给 agent 的执行提示

- 配置类任务最容易无限扩 scope，请坚持“patch 已知字段”思路
- 能复用现有 plist 模型就不要再做新模型
- 对签名和注入失败的错误信息要尽量具体，方便后续自动化排障

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
   - `T06: add settings and signing tools`
   - `T06: expose playtools injection tools`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
