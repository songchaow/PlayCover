# G05：GUI-MCP 状态联动

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | G04（MCPManager 已工作） |
| **预估工时** | 1-1.5 天 |
| **风险等级** | 中 |

## 目标

实现 MCP 操作完成后通过 `NotificationCenter` 通知 GUI 刷新，使 MCP 端的安装/卸载/设置修改等操作能实时反映到 GUI 界面上。

## 设计方案

### 通知定义

```swift
// 建议新建文件：PlayCover/Services/MCPNotifications.swift
// 或者放在 MCPManager.swift 中

import Foundation

extension Notification.Name {
    /// MCP 操作导致应用列表变化（安装/卸载/注入/清理等）
    static let mcpAppsChanged = Notification.Name("io.playcover.mcp.appsChanged")
    
    /// MCP 操作导致应用设置变化
    static let mcpSettingsChanged = Notification.Name("io.playcover.mcp.settingsChanged")
    
    /// MCP 操作导致键位映射变化
    static let mcpKeymapsChanged = Notification.Name("io.playcover.mcp.keymapsChanged")
}
```

### 发送端：MCP Service 层

在 MCP Service 的关键操作完成后发送通知：

```swift
// 示例：InstallerService.swift 安装完成后
// 在 install 方法的成功路径末尾添加：
NotificationCenter.default.post(name: .mcpAppsChanged, object: nil)
```

### 接收端：GUI ViewModel

在 `AppsVM` 中监听通知并刷新：

```swift
// AppsVM.swift 的 init() 中添加：
NotificationCenter.default.addObserver(
    forName: .mcpAppsChanged, object: nil, queue: .main
) { [weak self] _ in
    self?.fetchApps()
}
```

## 实现步骤

### Step 1：定义通知名

**新建文件**：`PlayCover/Services/MCPNotifications.swift`

这个文件需要同时被 MCP 代码和 GUI 代码访问。由于 G02 已经将 MCP 源文件编译到 GUI target 中，且通知名定义在 GUI 侧，MCP Service 可以直接引用。

> **注意**：通知名定义文件需要对 MCP 源文件可见。最简单的方式是将通知名定义在 MCP 目录下，或者在 GUI target 编译时确保 MCP 文件能看到这个定义。
>
> **推荐做法**：将通知名定义放在 MCP 源文件中（如 `PlayCoverMCP/Common/MCPNotifications.swift`），这样两个 target 都能编译到。

### Step 2：在 MCP Service 中添加通知发送

需要修改的文件和添加位置：

#### 2.1 InstallerService.swift

安装完成后发送 `mcpAppsChanged`：

```swift
// 在 install 方法成功返回前：
DispatchQueue.main.async {
    NotificationCenter.default.post(name: .mcpAppsChanged, object: nil)
}
```

> 使用 `DispatchQueue.main.async` 确保通知在主线程发送，因为 GUI ViewModel 监听在主线程。

#### 2.2 CleanupService.swift

以下操作完成后发送 `mcpAppsChanged`：
- `uninstall_app`（卸载应用）
- `clear_app_data`（清理数据）
- `clear_app_settings`（清理设置）

#### 2.3 InjectionService.swift

以下操作完成后发送 `mcpAppsChanged`：
- `inject_playtools`（注入 PlayTools）
- `remove_playtools`（移除 PlayTools）

#### 2.4 SettingsService.swift

设置修改后发送 `mcpSettingsChanged`：
- `update_app_settings`

#### 2.5 KeymapService.swift

键位映射操作后发送 `mcpKeymapsChanged`：
- `create_keymap`
- `delete_keymap`
- `rename_keymap`
- `update_keymap`（如果存在）
- `set_default_keymap`
- `import_keymap`（如果存在）

#### 2.6 SigningService.swift

重签名后可选发送 `mcpAppsChanged`（因为签名状态可能影响 app 显示）。

#### 2.7 LaunchService.swift

启动应用后可选通知（如果 GUI 需要显示运行状态）。

### Step 3：在 GUI ViewModel 中添加监听

#### 3.1 AppsVM.swift

```swift
// 在 init() 中添加：
private init() {
    try? AppsVM.ensureBaseDirectoriesExist()
    PlayTools.installOnSystem()
    fetchApps()
    
    // 新增：监听 MCP 操作引起的应用列表变化
    NotificationCenter.default.addObserver(
        forName: .mcpAppsChanged, object: nil, queue: .main
    ) { [weak self] _ in
        self?.fetchApps()
    }
}
```

#### 3.2 设置和键位映射的监听

需要调研 GUI 侧处理 settings 和 keymap 的 ViewModel 结构，找到合适的监听点。

可能需要监听的位置：
- `AppSettingsView` 或相关 ViewModel — 监听 `mcpSettingsChanged`
- Keymap 相关 View 或 ViewModel — 监听 `mcpKeymapsChanged`

> **注意**：settings 和 keymap 的 GUI 刷新可能比 apps 列表更复杂，因为它们可能与特定 app 绑定。通知的 `object` 参数可以携带 app bundleID 信息：
> ```swift
> NotificationCenter.default.post(
>     name: .mcpSettingsChanged,
>     object: nil,
>     userInfo: ["bundleID": bundleID]
> )
> ```

### Step 4：仅在 GUI 模式下发送通知

MCP Service 在 CLI 模式下运行时，不需要发送 GUI 通知（没有 GUI 在监听）。两种处理方式：

**方案 A**（简单，推荐）：直接发送，即使没人监听也不会出错（NotificationCenter 的通知如果没有 observer 就是 no-op）。

**方案 B**（可选优化）：通过条件标志控制：
```swift
// MCPManager 启动时设置标志
MCPManager.shared.isEmbeddedMode = true

// Service 中检查
if MCPManager.shared.isEmbeddedMode {
    NotificationCenter.default.post(...)
}
```

**建议用方案 A**，简单且无副作用。

### Step 5：编译和测试

```bash
# 编译验证
xcodebuild -scheme PlayCover -configuration Release build 2>&1 | tail -10
xcodebuild -scheme PlayCoverMCP -configuration Release build 2>&1 | tail -10

# MCP 测试
xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```

## 验收标准

- [ ] `mcpAppsChanged` / `mcpSettingsChanged` / `mcpKeymapsChanged` 通知名已定义
- [ ] MCP Service 在关键操作完成后发送对应通知
- [ ] `AppsVM` 监听 `mcpAppsChanged` 并调用 `fetchApps()`
- [ ] 通过 MCP 安装应用后，GUI 列表自动刷新（功能测试）
- [ ] 通过 MCP 卸载应用后，GUI 列表自动更新（功能测试）
- [ ] CLI 模式下 MCP 服务不受影响（通知发送无副作用）
- [ ] `xcodebuild -scheme PlayCover build` 通过
- [ ] `xcodebuild -scheme PlayCoverMCP build` 通过
- [ ] MCP 全量测试通过

## 测试计划

1. **编译测试**：两个 scheme build 通过
2. **单元测试**：MCP 全量测试通过
3. **集成测试**（需要 G04 已完成）：
   - 启动 GUI
   - 通过 TCP 发送 `install_ipa` 命令（如果有测试 IPA）
   - 观察 GUI 列表是否刷新
4. **回归测试**：
   - GUI 正常操作（手动安装/卸载）仍然正常
   - MCP CLI 模式功能不受影响

## 实际测试结果

**执行日期**：2026-03-24

### 编译测试
- ✅ `xcodebuild -scheme PlayCover -configuration Release build` — BUILD SUCCEEDED
- ✅ `xcodebuild -scheme PlayCoverMCP -configuration Release build` — BUILD SUCCEEDED
- ✅ `plutil -lint project.pbxproj` — OK

### 单元测试
- ✅ `xcodebuild test -scheme PlayCoverMCP` — 579 tests, 0 failures, 1 skipped — **TEST SUCCEEDED**

### 实现摘要

1. **新增文件**：`PlayCoverMCP/Common/MCPNotifications.swift`
   - 定义 3 个通知名：`mcpAppsChanged`、`mcpSettingsChanged`、`mcpKeymapsChanged`
   - 提供 `MCPNotificationPoster` 便捷类，确保通知在主线程发送

2. **MCP Service 修改**（通知发送端）：
   - `InstallerService.swift`：`install()` 成功后发送 `mcpAppsChanged`
   - `CleanupService.swift`：`uninstallApp()` 成功后发送 `mcpAppsChanged`
   - `InjectionService.swift`：`injectPlayTools()` / `removePlayTools()` 成功后发送 `mcpAppsChanged`
   - `SettingsService.swift`：`updateSettings()` / `resetSettings()` 成功后发送 `mcpSettingsChanged`
   - `KeymapService.swift`：`createKeymap()` / `renameKeymap()` / `deleteKeymap()` / `resetKeymap()` / `importKeymap()` 成功后发送 `mcpKeymapsChanged`

3. **GUI ViewModel 修改**（通知接收端）：
   - `AppsVM.swift`：在 `init()` 中添加 `mcpAppsChanged` 通知监听，自动调用 `fetchApps()`

4. **pbxproj 修改**：新文件添加到全部 3 个 target（PlayCover、PlayCoverMCP、PlayCoverMCPTests）

5. **采用方案 A**：直接在所有 Service 中无条件 post 通知，CLI 模式下也发送（NotificationCenter 无 observer 时是 no-op，零副作用）

---

## 注意事项

1. **通知必须在主线程发送或监听时切到主线程**：`AppsVM.fetchApps()` 在主线程执行（`Task { @MainActor in ... }`），监听 queue 设为 `.main`
2. **weak self 防止循环引用**：`NotificationCenter.addObserver(forName:)` 的闭包中使用 `[weak self]`
3. **不要过度通知**：只在操作**成功完成**后通知，失败时不通知
4. **方案 A 最简单**：直接在所有 Service 中无条件 post 通知，CLI 模式下也发（无副作用）
5. **settings/keymap 刷新可能需要更多调研**：GUI 侧这两部分的架构可能比 AppsVM 更复杂，需要执行 agent 自行调研
6. **通知名文件的位置很关键**：必须对两个 target 都可见，建议放在 MCP 源文件目录中
