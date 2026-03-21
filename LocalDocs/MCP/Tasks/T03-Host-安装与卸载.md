### T03 - Host 安装与卸载

## dashboard

- **任务编号**: `T03`
- **状态**: `未开始`
- **层级**: `Host MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成 IPA 安装与已安装 app 卸载的最小 MCP 闭环
- **依赖任务**: `T01`
- **主产物**:
  - `install_ipa(path)`
  - `uninstall_app(bundle_id, options)`
- **主要风险**:
  - 误把 IPA Source / Store / 下载逻辑也卷进来
  - UI 弹窗阻塞自动化路径
- **不包含内容**:
  - 不做 IPA 资源库
  - 不做下载 / 商店接入
  - 不做运行中 attach 调试

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T01-Host-骨架与协议.md`

---

## 背景与目标

`PlayCover` 已经有较完整的安装 / 卸载逻辑，本任务要做的是：

- 将这两类能力从 UI 入口抽成 Host MCP 可直接调用的工具
- 尽量绕开自动化路径中的确认弹窗
- 保持对现有安装链路的复用

---

## 范围（In Scope）

- 基于 `Installer.install(...)` 实现 `install_ipa(path)`
- 支持从本地 IPA 路径安装
- 基于 `Uninstaller.uninstall(...)` 实现 `uninstall_app(bundle_id, options)`
- 支持卸载选项：
  - remove app data
  - remove settings
  - remove keymap
  - remove playchain
  - remove entitlements
- 返回结构化安装 / 卸载结果
- 对典型失败给出清晰错误消息

---

## 明确不做（Out of Scope）

- 不接入 `Downloader` 或资源库下载链路
- 不实现远程 URL 安装
- 不实现安装后的自动运行
- 不处理 attach 调试
- 不顺手实现清缓存工具（那属于 `T05`）

---

## 主要代码入口

优先复用：

- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Utils/IPA.swift`
- `PlayCover/Utils/Macho.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Model/PlayApp.swift`

---

## 实现关注点

## 安装

重点关注：

- 本地 IPA 路径校验
- 自动化路径下的 UI 弹窗规避
- 返回已安装 app 的关键信息

建议返回：

- `bundle_id`
- `display_name`
- `installed_path`
- `has_playtools`
- `warnings`

## 卸载

重点关注：

- `bundle_id` -> `PlayApp` 的定位
- 卸载选项映射到现有逻辑
- 返回具体清理项结果

建议返回：

- `bundle_id`
- `removed_app`
- `removed_app_data`
- `removed_settings`
- `removed_keymap`
- `removed_playchain`
- `removed_entitlements`

---

## 完成标准

- Host MCP 可直接安装本地 IPA
- Host MCP 可直接卸载已安装 app
- 资源库 / 商店功能未被卷入实现范围
- 安装与卸载结果都有结构化返回
- 对自动化路径中可能的弹窗问题有明确处理或限制说明

---

## 给 agent 的执行提示

- 只做“本地 IPA -> 安装”，不要扩展成下载器
- 如果现有安装逻辑中某些弹窗很难完全移除，可以提供明确的 `non_interactive` 限制或 warning
- 卸载能力要尽量利用已有逻辑，不要另写一套删除流程

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
   - `T03: add install and uninstall tools`
   - `T03: expose local ipa install flow`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
