### PlayCover MCP 调研结论

## 文档目的

本文用于完整记录对 `PlayCover` 项目的 MCP 暴露能力调研结果，重点关注：

- 已安装 app 的管理能力
- 运行中的 app 的远程控制能力
- 调试、日志、进程状态相关能力
- 适合暴露为 MCP API 的现有入口
- 当前缺失但值得补充的能力

本次调研**明确不关注**“IPA 资源库 / IPA Source / 商店类附属功能”。

---

## 一句话结论

`PlayCover` 很适合拆成两层 MCP：

- **Host MCP**：运行在 PlayCover 宿主进程内，负责安装、卸载、启动、配置、签名、清理、keymap 管理、调试启动等。
- **Session MCP**：运行在被注入 `PlayTools` 的目标 app 进程内，负责点击、拖拽、滑动、缩放、摇杆、模式切换、debug overlay、触摸日志等运行期控制。

当前代码里，**Host 能力已经比较完整**；**Session 能力很强，但缺少一个正式的远程桥接层**；**debugger attach 到已运行进程**目前没有现成实现。

---

## 项目能力分层

## 1. 宿主层（PlayCover App）

主要目录：`PlayCover/`

职责：

- 安装 / 导入 IPA
- 卸载 app
- 启动 app
- 扫描已安装 app
- 读取 app 元数据
- 配置每个 app 的运行参数
- 注入 / 移除 `PlayTools`
- 签名 / 重签名
- 清理缓存、偏好、PlayChain、容器
- 管理 keymap 文件
- 以 LLDB 启动 app

关键文件：

- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/ViewModel/AppsVM.swift`
- `PlayCover/Model/AppInfo.swift`
- `PlayCover/Model/AppSettings.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Utils/Keymapping.swift`
- `PlayCover/Utils/KeyCover.swift`

## 2. 运行期注入层（PlayTools）

主要目录：`Carthage/Checkouts/PlayTools/PlayTools/`

职责：

- 伪装 iOS / iPad 运行环境
- 读取宿主保存的 per-app 配置
- 接管 macOS 鼠标 / 键盘 / 滚轮 / 手柄输入
- 将输入翻译为 UIKit 触摸 / 拖拽 / 缩放 / 摇杆动作
- 管理运行期模式机
- 管理 debug overlay
- 管理运行期 keymap 切换
- 模拟 PlayChain / Keychain 行为

关键文件：

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayScreen.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PlayInput.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ControlMode.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/ActionDispatcher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Action/PlayAction.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`

## 3. macOS 原生桥接层

关键文件：

- `Carthage/Checkouts/PlayTools/AKPlugin.swift`
- `Carthage/Checkouts/PlayTools/Plugin.swift`

职责：

- 将 `NSWindow` / `NSEvent` / `NSCursor` 能力桥接给 injected 运行时
- 注册键盘、鼠标、滚轮、窗口关闭等回调
- 执行光标隐藏 / 显示 / warp 等操作
- 终止当前应用

---

## 核心结论总览

## 1. 已经非常适合暴露成 API 的能力

- 安装 app
- 卸载 app
- 列出已安装 app
- 读取 app 元数据
- 启动 app
- 以 LLDB 启动 app
- 清缓存 / 清偏好 / 清 PlayChain / 清容器
- 注入 / 移除 `PlayTools`
- 签名 / 重签名
- 修改运行参数
- keymap 管理
- 运行期点击 / 拖拽 / 滑动 / 缩放 / 摇杆 / 模式切换 / overlay / 触摸日志

## 2. 现有但不完整的能力

- 进程状态感知：有 `isActive` / `isTerminated`，但没有标准会话层
- 调试：可以“启动时走 LLDB”，但不能 attach 到已运行进程
- 整容器重置：底层有 `AppContainer.clear()`，但当前未正式暴露

## 3. 当前未发现或明显缺失的能力

- 正式的 `stop app` API
- 正式的 `restart app` API
- 已运行进程的 PID 管理
- `lldb -p <pid>` attach 流程
- 通用文本输入注入
- 运行中画面截图 / 录屏能力
- Session 级远程桥接层

---

## 宿主侧可暴露能力清单（Host MCP）

## 1. 安装 / 导入 IPA

### 核心入口

- `Installer.install(ipaUrl:export:returnCompletion:)`
- `IPA.unzip()`
- `Installer.resolveValidMachOs(_:)`
- `PlayTools.installInIPA(_:)`
- `PlayTools.injectInIPA(_:payload:)`
- `Installer.wrap(_:)`
- `PlayApp.sign()`

### 关键文件

- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Utils/IPA.swift`
- `PlayCover/Utils/Macho.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Shell.swift`

### 能力说明

该链路负责：

- 解压 IPA
- 检查官方支持 macOS 的 App Store 包冲突
- 提取 entitlements
- 处理 Mach-O
- 注入 `PlayTools`
- 重新签名
- 生成 PlayCover 侧可管理的 app

### 适合的 MCP API

- `install_ipa(ipa_path)`
- `install_ipa(ipa_path, inject_playtools=true)`

### 备注

默认流程中某些条件下会出现 `NSAlert` 弹窗，因此如果走自动化 API，建议额外做“无 UI 安装模式”开关。

---

## 2. 卸载 app

### 核心入口

- `Uninstaller.uninstall(_:)`
- `PlayApp.deleteApp()`
- `PlayApp.removeAlias()`

### 关键文件

- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Extensions/PlayAppExtensions.swift`

### 能力说明

卸载时可选清理：

- app 本体
- keymap
- app settings
- entitlements
- PlayChain
- app data / 外部缓存

### 适合的 MCP API

- `uninstall_app(bundle_id, remove_app_data=true, remove_settings=true, remove_keymap=true, remove_playchain=true)`

### 备注

目前没看到“卸载前先结束目标 app”的逻辑。

---

## 3. 列出已安装 app

### 核心入口

- `AppsVM.fetchApps()`

### 关键文件

- `PlayCover/ViewModel/AppsVM.swift`

### 能力说明

扫描 PlayCover 自己的 Applications 目录，构建 `PlayApp` 列表。

### 适合的 MCP API

- `list_apps()`
- `get_app(bundle_id)`

---

## 4. 读取 app 元数据

### 核心入口

- `AppInfo(contentsOf:)`
- `BaseApp.init(appUrl:)`
- `PlayApp.hasPlayTools()`

### 关键文件

- `PlayCover/Model/AppInfo.swift`
- `PlayCover/Model/BaseApp.swift`
- `PlayCover/Model/PlayApp.swift`

### 可读取内容

- `bundleIdentifier`
- `displayName`
- `bundleVersion`
- `executableName`
- `minimumOSVersion`
- `applicationCategoryType`
- 主图标信息
- 当前是否注入了 `PlayTools`

### 适合的 MCP API

- `get_app_info(bundle_id)`

---

## 5. 启动 app

### 核心入口

- `PlayApp.launch()`
- `PlayApp.runAppExec()`

### 关键文件

- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Extensions/PlayAppExtensions.swift`

### 能力说明

启动前会执行多项准备：

- 同步 app settings
- 校验 entitlements
- 必要时重签
- 处理 KeyCover / PlayChain
- 清理会影响子进程的调试环境变量
- 根据配置决定是否用 LLDB 启动

### 适合的 MCP API

- `launch_app(bundle_id)`
- `launch_app(bundle_id, debug=false)`

### 备注

当前本质上仍依赖 macOS 图形会话，因为最终通过 `NSWorkspace.openApplication(...)` 打开目标 app。

---

## 6. 停止 app

### 结论

**当前没有正式宿主 API。**

### 相关代码

- `PlayTools/PlayCover.swift` 中的 `quitWhenClose()`
- `AKPlugin.terminateApplication()`

### 现状说明

当前更像是：

- 目标 app 关窗
- 注入层模拟 iOS 生命周期事件
- 最终由 injected 侧终止当前进程

### API 化判断

- 不适合直接暴露为现成 MCP API
- 需要新增宿主侧进程会话管理与显式 terminate 逻辑

---

## 7. 重启 app

### 结论

**当前未发现专门实现。**

### API 化判断

若后续补齐：

- 需要先补 `stop_app`
- 再复用 `launch_app`

---

## 8. 清理数据 / 重置容器

## 8.1 清缓存 / 清外部数据

### 核心入口

- `Uninstaller.clearCache(of:)`
- `Uninstaller.clearExternalCache(_:)`
- `PlayApp.clearAllCache()`

### 关键文件

- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Model/PlayApp.swift`

### 覆盖目录

- `~/Library/Containers`
- `~/Library/Application Scripts`
- `~/Library/Caches`
- `~/Library/HTTPStorages`
- `~/Library/Saved Application State`

### 适合的 MCP API

- `clear_cache(bundle_id)`

## 8.2 清 Preferences

### 核心入口

- `deletePreferences(app:)`

### 关键文件

- `PlayCover/Views/App Views/PlayAppView.swift`

### 说明

当前实现位置在 View 内，但逻辑简单，适合抽成服务层。

### 适合的 MCP API

- `clear_preferences(bundle_id)`

## 8.3 清 PlayChain

### 核心入口

- `PlayApp.clearPlayChain()`

### 关键文件

- `PlayCover/Model/PlayApp.swift`

### 适合的 MCP API

- `clear_playchain(bundle_id)`

## 8.4 清整个容器

### 核心入口

- `AppContainer.clear()`

### 关键文件

- `PlayCover/Model/AppContainer.swift`

### 说明

这是非常适合 API 化的能力，但当前未被正式接到 UI 或业务流程中。

### 适合的 MCP API

- `reset_container(bundle_id)`

---

## 9. 签名 / 重签名

### 核心入口

- `Shell.signMacho(_:)`
- `Shell.signApp(_:)`
- `Shell.signAppWith(_:entitlements:)`
- `PlayApp.sign()`
- `Entitlements.composeEntitlements(_:)`

### 关键文件

- `PlayCover/Utils/Shell.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Entitlements.swift`

### 适合的 MCP API

- `sign_app(bundle_id)`
- `resign_app(bundle_id)`

---

## 10. 注入 / 移除 PlayTools

### 核心入口

- `PlayTools.installInIPA(_:)`
- `PlayTools.removeFromApp(_:)`
- `PlayTools.installPluginInIPA(_:)`

### 关键文件

- `PlayCover/Utils/PlayTools.swift`

### 适合的 MCP API

- `inject_playtools(bundle_id)`
- `remove_playtools(bundle_id)`
- `has_playtools(bundle_id)`

---

## 11. 设置运行参数

### 核心入口

- `AppSettings`
- `AppSettingsData`
- `PlayApp.changeDyldLibraryPath(set:path:)`
- `AppInfo.applicationCategoryType`

### 关键文件

- `PlayCover/Model/AppSettings.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/AppInfo.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`

### 已有配置项

包括但不限于：

- `iosDeviceModel`
- `windowWidth`
- `windowHeight`
- `customScaler`
- `resolution`
- `aspectRatio`
- `playChain`
- `playChainDebugging`
- `rootWorkDir`
- `enableScrollWheel`
- `disableBuiltinMouse`
- `hideTitleBar`
- `floatingWindow`
- `limitMotionUpdateFrequency`
- `blockSleepSpamming`
- `checkMicPermissionSync`
- `resizableAspectRatioType`
- `resizableAspectRatioWidth`
- `resizableAspectRatioHeight`

### 适合的 MCP API

- `get_app_settings(bundle_id)`
- `set_app_settings(bundle_id, patch)`
- `set_launch_env(bundle_id, introspection=true, ios_frameworks=true)`

### 备注

`openWithLLDB` / `openLLDBWithTerminal` 的持久化路径不如其他设置明确，若要 API 化，建议补齐。

---

## 12. keymap 管理

### 核心入口

宿主侧：

- `Keymapping.create...`
- `Keymapping.rename...`
- `Keymapping.delete...`
- `Keymapping.import...`
- `Keymapping.export...`
- `Keymapping.reloadKeymapCache()`

运行期：

- `Keymapping.nextKeymap()`
- `Keymapping.previousKeymap()`

### 关键文件

- `PlayCover/Utils/Keymapping.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Keymap/Keymapping.swift`

### 适合的 MCP API

- `list_keymaps(bundle_id)`
- `create_keymap(bundle_id, name)`
- `rename_keymap(bundle_id, old_name, new_name)`
- `delete_keymap(bundle_id, name)`
- `import_keymap(bundle_id, path)`
- `export_keymap(bundle_id, name, path)`
- `switch_keymap(bundle_id, name)`

---

## 运行期远程控制能力清单（Session MCP）

## 1. 注入与运行期入口

### 核心入口

- `PlayTools.installInIPA(_:)`
- `PlayLoader` constructor
- `PlayCover.launch()`

### 关键文件

- `PlayCover/Utils/PlayTools.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`

### 说明

目标 app 启动后，`PlayTools` 会在目标进程内初始化自身运行时，因此具备直接操作 UIKit 事件的基础条件。

---

## 2. 输入采集能力

### 核心入口

- `AKPlugin.setupKeyboard(...)`
- `AKPlugin.setupMouseMoved(...)`
- `AKPlugin.setupMouseButton(...)`
- `AKPlugin.setupScrollWheel(...)`
- `ControlMode.setupGameController()`
- `PlayInput.initialize()`

### 关键文件

- `Carthage/Checkouts/PlayTools/AKPlugin.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PlayInput.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ControlMode.swift`

### 已支持输入种类

- 键盘按下 / 抬起 / modifier 改变
- 鼠标移动
- 鼠标左 / 右 / 其他按键按下抬起
- 滚轮
- 手柄按钮
- 手柄摇杆

### 结论

运行期控制的强项不是“接收原生键盘文本输入”，而是把多种输入统一翻译为 iOS 触摸 / 手势。

---

## 3. 模式机能力

### 核心入口

- `ControlMode.set(_:)`
- `ModeAutomaton.onOption()`
- `ModeAutomaton.onCmdK()`
- `ModeAutomaton.onUITextInputBeginEdit()`
- `ModeAutomaton.onUITextInputEndEdit()`

### 关键文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ControlMode.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ModeAutomaton.swift`

### 运行模式

- `off`
- `textInput`
- `cameraRotate`
- `arbitraryClick`
- `editor`

### 适合的 MCP API

- `session_get_mode()`
- `session_set_mode(mode)`

---

## 4. 触摸注入能力

### 核心入口

- `Toucher.touchcam(point:phase:tid:actionName:keyName:)`
- `PTFakeMetaTouch.fakeTouchId(...)`

### 关键文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.m`

### 关键事实

这里不是简单调用按钮 action，而是：

- 构造 `UITouch`
- 构造 `IOHIDEvent`
- 关联到 `UITouch`
- 通过 `UIApplication` 生成 touch event
- 最终 `sendEvent:` 送进 UIKit

### 结论

已经具备直接做 Session 输入 API 的底层能力。

### 适合的 MCP API

- `tap(x, y)`
- `pointer_down(id, x, y)`
- `pointer_move(id, x, y)`
- `pointer_up(id, x, y)`

---

## 5. 已有动作模型

### 核心入口

- `ActionDispatcher.dispatch(...)`
- 各类 `PlayAction`

### 关键文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/ActionDispatcher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Action/PlayAction.swift`

### 现有动作类型

- `ButtonAction`
- `DraggableButtonAction`
- `ContinuousJoystickAction`
- `JoystickAction`
- `CameraAction`
- `SwipeAction`
- `FakeMouseAction`

### 能力映射

- 固定点触摸
- 拖拽
- 滑动
- 缩放 / camera 类操作
- 虚拟摇杆
- 当前鼠标坐标转触点

### 适合的 MCP API

- `drag(from, to, duration)`
- `swipe(path)`
- `pinch(center, scale)`
- `button(name, pressed)`
- `thumbstick(name, x, y)`

---

## 6. 运行期菜单 / overlay / cursor / display

### 核心入口

- `MenuController.switchEditorMode(...)`
- `MenuController.rotateView(...)`
- `MenuController.toggleDebugOverlay(...)`
- `MenuController.hideCursor(...)`
- `MenuController.nextKeymap(...)`
- `MenuController.previousKeymap(...)`
- `AKPlugin.hideCursor()`
- `AKPlugin.hideCursorMove()`
- `AKPlugin.unhideCursor()`
- `AKPlugin.warpCursor()`
- `PlayScreen.switchDock(_:)`

### 关键文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/MenuController.swift`
- `Carthage/Checkouts/PlayTools/AKPlugin.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayScreen.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugController.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugModel.swift`

### 适合的 MCP API

- `toggle_debug_overlay(enable)`
- `rotate_display()`
- `hide_cursor()`
- `unhide_cursor()`
- `center_cursor()`
- `switch_keymap(next|prev|name)`

---

## 7. 触摸日志 / 调试日志

### 触摸日志

#### 核心入口

- `Toucher.setupLogfile()`
- `Toucher.writeLog(logMessage:)`
- `MenuController.markToucherLog(...)`

#### 关键文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/MenuController.swift`

#### 适合的 MCP API

- `touchlog_enable(enable)`
- `touchlog_mark(label)`
- `touchlog_read()`

### PlayChain 调试日志

#### 核心入口

- `playChainDebugging` 配置
- `PlayLoader.m` 中相关 `NSLog("PC-DEBUG: ...")`

#### 适合的 MCP API

- `playchain_debug(enable)`
- `session_logs(scope="playchain")`

---

## 调试与进程能力调研结论

## 1. 启动时使用 LLDB

### 核心入口

- `PlayApp.launch()`
- `Shell.lldb(_:, withTerminalWindow:)`

### 关键文件

- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Views/AppSettingsView.swift`

### 现有行为

- 可选择 `openWithLLDB`
- 可选择 `openLLDBWithTerminal`
- 实际命令为 `/usr/bin/lldb -o run <executable> -o exit`

### 适合的 MCP API

- `launch_app(bundle_id, debug=true)`
- `launch_app(bundle_id, debug=true, terminal=true)`

### 结论

这是当前最成熟、最容易直接暴露的调试能力。

---

## 2. attach 到已运行进程

### 调研结论

**当前没有现成实现。**

### 未发现内容

- `lldb -p <pid>`
- `process attach`
- `task_for_pid`
- `ptrace`
- `debugserver`
- 显式 `processIdentifier`
- 进程 PID 会话管理

### 结论

如果要暴露：

- `attach_debugger(bundle_id)`
- `attach_debugger(pid)`

则需要先新增：

- 启动后记录 `NSRunningApplication`
- 暴露 PID
- 新增 attach 命令封装

---

## 3. 进程状态感知

### 核心入口

- `NSWorkspace.shared.openApplication(... completionHandler: { runningApp, error in ... })`
- `runningApp.isActive`
- `runningApp.isTerminated`

### 关键文件

- `PlayCover/Model/PlayApp.swift`

### 现状说明

已有最小状态检测，但没有标准 Session 抽象。

### 适合的 MCP API

- `app_status(bundle_id)`
- `session_status(session_id)`

### 推荐返回字段

- `installed`
- `launching`
- `running`
- `active`
- `terminated`
- `debug_mode`
- `pid`（待补）

---

## 4. 宿主日志

### 核心入口

- `Log.shared.log(...)`
- `Log.shared.error(...)`
- `Log.shared.msg(...)`

### 关键文件

- `PlayCover/ViewModel/Log.swift`

### 适合的 MCP API

- `host_logs_read()`
- `host_logs_clear()`

---

## 5. 崩溃与终止相关行为

### 相关文件

- `PlayCover/Views/PlayCoverApp.swift`
- `PlayCover/Views/MenuBarView.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`

### 观察

- 宿主会设置 `NSApplicationCrashOnExceptions`
- Debug 菜单里存在人工触发 crash 的入口
- injected app 在关窗时会模拟 iOS 生命周期并 terminate

### 结论

有一定调试辅助价值，但还不是完整的调试会话能力。

---

## 运行期能力矩阵

| 能力 | 是否存在 | 主要入口 | 适合 API 化 |
|---|---|---|---|
| 点击屏幕坐标 | 是 | `Toucher` / `PTFakeMetaTouch` | 是 |
| 按下 / 移动 / 抬起 | 是 | `Toucher` | 是 |
| 拖拽 | 是 | `DraggableButtonAction` / `SwipeAction` | 是 |
| 滑动 | 是 | `SwipeAction` | 是 |
| 缩放 / pinch 类操作 | 是 | `CameraAction` | 是 |
| 摇杆 | 是 | `JoystickAction` / `ContinuousJoystickAction` | 是 |
| 鼠标滚轮映射 | 是 | `setupScrollWheel` / `CameraAction` | 是 |
| 键盘映射触控 | 是 | `TouchscreenKeyboardEventAdapter` | 是 |
| 手柄映射触控 | 是 | `TouchscreenControllerEventAdapter` | 是 |
| 模式切换 | 是 | `ControlMode` / `ModeAutomaton` | 是 |
| 切换 keymap | 是 | 运行期 `Keymapping` | 是 |
| debug overlay | 是 | `MenuController.toggleDebugOverlay` | 是 |
| 光标控制 | 是 | `AKPlugin` | 是 |
| 进程状态感知 | 部分存在 | `runningApp.isActive/isTerminated` | 是 |
| LLDB 启动 | 是 | `Shell.lldb` | 是 |
| attach 到已运行进程 | 未发现 | 无 | 否，需补代码 |
| stop app | 未发现正式 API | 无 | 否，需补代码 |
| restart app | 未发现 | 无 | 否，需补代码 |
| 文本输入注入 | 未发现成熟实现 | 无 | 否，需补代码 |
| 截图 / 录屏 | 未发现 | 无 | 否，需补代码 |

---

## 推荐的 MCP 设计

## 一、推荐拆分为两层

## 1. Host MCP

负责：

- app 管理
- 生命周期管理
- 配置管理
- 安装 / 卸载 / 签名 / 注入
- keymap 文件管理
- 调试启动
- 日志读取

### 推荐 API

- `list_apps()`
- `get_app_info(bundle_id)`
- `install_ipa(path)`
- `uninstall_app(bundle_id, options)`
- `launch_app(bundle_id, debug=false, terminal=false)`
- `app_status(bundle_id)`
- `clear_cache(bundle_id)`
- `clear_preferences(bundle_id)`
- `clear_playchain(bundle_id)`
- `reset_container(bundle_id)`
- `sign_app(bundle_id)`
- `inject_playtools(bundle_id)`
- `remove_playtools(bundle_id)`
- `get_app_settings(bundle_id)`
- `set_app_settings(bundle_id, patch)`
- `list_keymaps(bundle_id)`
- `create_keymap(bundle_id, name)`
- `rename_keymap(bundle_id, old_name, new_name)`
- `delete_keymap(bundle_id, name)`
- `host_logs_read()`

## 2. Session MCP

负责：

- 运行中 app 的输入与状态控制
- 运行期模式切换
- keymap 切换
- overlay / 光标 / 画面相关控制
- 触摸日志 / session 级日志

### 推荐 API

- `session_status()`
- `session_get_mode()`
- `session_set_mode(mode)`
- `tap(x, y)`
- `pointer_down(id, x, y)`
- `pointer_move(id, x, y)`
- `pointer_up(id, x, y)`
- `drag(from, to, duration)`
- `swipe(path)`
- `pinch(center, scale)`
- `button(name, pressed)`
- `thumbstick(name, x, y)`
- `switch_keymap(name|next|prev)`
- `toggle_debug_overlay(enable)`
- `hide_cursor()`
- `unhide_cursor()`
- `center_cursor()`
- `touchlog_enable(enable)`
- `touchlog_mark(label)`
- `touchlog_read()`

---

## 二、为什么不建议只做单层 MCP

原因如下：

- 宿主层和 injected 层职责天然不同
- 运行期触摸注入发生在目标 app 进程内部
- 如果只在宿主进程做 MCP，很多运行期能力最终仍需要跨进程桥接
- 与其绕远路，不如直接在 injected 侧建立 Session Bridge

推荐做法：

- Host MCP 负责 app 生命周期
- 启动 app 后，创建或发现对应 Session
- Session MCP 在 injected 层直接调用 `Toucher` / `ActionDispatcher` / `ControlMode`

---

## 三、最小改造建议

## 第一阶段：直接复用现有代码

优先暴露：

- `list_apps`
- `install_ipa`
- `uninstall_app`
- `launch_app`
- `launch_app(debug=true)`
- `get_app_info`
- `get_app_settings`
- `set_app_settings`
- `clear_cache`
- `clear_preferences`
- `clear_playchain`
- `reset_container`
- `sign_app`
- `inject_playtools`

这些大多只需要：

- 提取一层 service
- 避免 UI 弹窗路径
- 增加结构化返回值

## 第二阶段：增加 Session Bridge

在 injected `PlayTools` 侧补一个轻量远程桥接层，用于直接调用：

- `Toucher`
- `ActionDispatcher`
- `ControlMode`
- `MenuController`
- 运行期 `Keymapping`

完成后即可暴露：

- `tap`
- `drag`
- `swipe`
- `pinch`
- `thumbstick`
- `set_mode`
- `switch_keymap`
- `toggle_debug_overlay`
- `touchlog_read`

## 第三阶段：补齐调试 / 进程会话

建议新增：

- 保存 `NSRunningApplication` 引用
- 暴露 `pid`
- 新增 `Shell.lldbAttach(pid)`
- 补 `stop_app`
- 补 `restart_app`

完成后可提供：

- `attach_debugger(pid)`
- `stop_app(bundle_id)`
- `restart_app(bundle_id)`
- `session_status()` 中返回 `pid`

---

## 关键限制与风险

## 1. 弹窗路径会影响自动化

例如：

- 安装 `PlayTools` 确认
- 某些版本 / 官方包检查
- 部分错误提示

如果要做稳定 MCP，需要将这些逻辑改为：

- 可配置跳过 UI
- 统一返回结构化错误

## 2. 运行期强依赖 injected 层

当前点击、拖拽、滑动等能力之所以强，是因为 `PlayTools` 已经运行在目标 app 内。  
因此远程控制如果脱离 injected 层，就会绕很多弯路。

## 3. 文本输入不是当前强项

当前重点是触摸 / 手势模拟，不是完整键盘文本注入。  
如果后续要做自动化输入法 / 聊天输入，需要额外设计。

## 4. 截图 / 录屏闭环未建立

如果后续目标是完整自动化测试平台，则还需要补：

- screenshot
- screen recording
- 画面分析接口

---

## 最推荐优先暴露的 API 清单

## 第一优先级

- `list_apps`
- `install_ipa`
- `uninstall_app`
- `launch_app`
- `launch_app(debug=true)`
- `get_app_info`
- `get_app_settings`
- `set_app_settings`
- `clear_cache`
- `clear_preferences`
- `clear_playchain`
- `reset_container`

## 第二优先级

- `tap`
- `drag`
- `swipe`
- `pinch`
- `thumbstick`
- `session_set_mode`
- `switch_keymap`
- `toggle_debug_overlay`
- `touchlog_read`
- `host_logs_read`

## 第三优先级

- `attach_debugger`
- `stop_app`
- `restart_app`
- `type_text`
- `screenshot`

---

## 本次调研涉及的最关键文件索引

## 宿主层

- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/BaseApp.swift`
- `PlayCover/Model/AppInfo.swift`
- `PlayCover/Model/AppSettings.swift`
- `PlayCover/Model/AppContainer.swift`
- `PlayCover/ViewModel/AppsVM.swift`
- `PlayCover/ViewModel/Log.swift`
- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Views/App Views/PlayAppView.swift`
- `PlayCover/Views/AppSettingsView.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Shell.swift`
- `PlayCover/Utils/IPA.swift`
- `PlayCover/Utils/Macho.swift`
- `PlayCover/Utils/Entitlements.swift`
- `PlayCover/Utils/Keymapping.swift`
- `PlayCover/Utils/KeyCover.swift`
- `PlayCover/Utils/URLHandler.swift`

## 注入运行期

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayScreen.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PlayInput.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ControlMode.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Frontend/ModeAutomaton.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/ActionDispatcher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Action/PlayAction.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugController.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugModel.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugView.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Keymap/Keymapping.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MysticRunes/PlayedApple.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MysticRunes/PlayedAppleDB.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.m`

## macOS 桥接层

- `Carthage/Checkouts/PlayTools/AKPlugin.swift`
- `Carthage/Checkouts/PlayTools/Plugin.swift`

---

## 最终结论

从现有代码基础看，`PlayCover` 并不是“需要从零设计 MCP 能力”的项目，而是一个**已经具备大量可 API 化能力**、只是还缺少正式服务边界的项目。

最现实的演进路径是：

1. 先把宿主层已有逻辑整理为 `Host MCP`
2. 再在 injected `PlayTools` 中补一个 `Session Bridge`
3. 最后补齐 PID / attach / stop / restart / screenshot / text input 等高级能力

如果后续继续推进实现，建议下一份文档直接进入“API 设计稿 + 代码落点 + 改造任务拆分”阶段。