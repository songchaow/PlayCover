### 任务编号与标题

- **ID**：`R05`
- **标题**：GUI 设置界面 Metal Capture 开关

### Dashboard

- **状态**：`DONE`
- **优先级**：`P2`
- **预计工作量**：`S`（小型）
- **依赖任务**：`R01`
- **阻塞任务**：`R06`
- **建议执行顺序**：第 5 个（可与 R02-R04 并行）
- **预期提交数**：`1`

### 开工前必读

- `00-主文档.md`
- `R01-Host设置与安装管线改动.md`（确认已完成）
- 本文档

### 任务目标

在 PlayCover 的应用设置界面中添加 Metal Capture 的开关 Toggle，让用户可以为每个 app 开启/关闭 Metal 截帧功能。

### 范围内

1. **修改 `PlayCover/Views/AppSettingsView.swift`**
   - 在"调试"相关区域新增 Metal Capture 开关
2. **新增本地化字符串**
   - `PlayCover/en.lproj/Localizable.strings`
   - `PlayCover/zh-Hans.lproj/Localizable.strings`
   - `PlayCover/zh-Hant.lproj/Localizable.strings`
   - 其他已有语言的 `.strings` 文件
3. 文档更新

### 范围外

- 不实现截帧功能本身
- 不修改 MCP 工具
- 不修改 Bridge 协议

### 预期改动文件

- `PlayCover/Views/AppSettingsView.swift`
- `PlayCover/en.lproj/Localizable.strings`
- `PlayCover/zh-Hans.lproj/Localizable.strings`
- `PlayCover/zh-Hant.lproj/Localizable.strings`
- `LocalDocs/RenderCapture/` 相关文档

### 实施细节

#### 1. AppSettingsView 改动

参考现有 `metalHUD` 开关的实现模式。在 `AppSettingsView` 中：

**当前 Metal HUD 相关代码**（约第 706-710 行）：

```swift
Toggle("settings.toggle.hud", isOn: $settings.settings.metalHUD)
    .disabled(!isVenturaGreater())
    .help(!isVenturaGreater() ? "settings.unavailable.hud" : "")
```

在 Metal HUD 开关附近，添加 Metal Capture 开关：

```swift
Toggle("settings.toggle.metalCapture", isOn: $settings.settings.metalCaptureEnabled)
    .help("settings.help.metalCapture")
```

**注意**：
- Metal Capture 不需要 macOS 版本限制（`MTLCaptureManager` 在 macOS 10.15+ 可用）
- 设置修改会自动通过 `AppSettingsData` 的 `didSet` → `encode()` 保存到共享 plist
- PlayTools 在启动时读取该 plist，所以**设置变更在下次启动 app 时生效**

#### 2. 本地化字符串

```
// en.lproj/Localizable.strings
"settings.toggle.metalCapture" = "Metal Capture";
"settings.help.metalCapture" = "Enable Metal GPU frame capture. Allows programmatic capture of GPU frames for render analysis. Requires app restart.";

// zh-Hans.lproj/Localizable.strings
"settings.toggle.metalCapture" = "Metal 截帧";
"settings.help.metalCapture" = "启用 Metal GPU 帧截取。允许编程式截取 GPU 帧用于渲染分析。需要重启应用生效。";

// zh-Hant.lproj/Localizable.strings
"settings.toggle.metalCapture" = "Metal 截幀";
"settings.help.metalCapture" = "啟用 Metal GPU 幀截取。允許程式化截取 GPU 幀用於渲染分析。需要重啟應用生效。";
```

#### 3. UI 布局建议

将 Metal Capture 开关放在 Metal HUD 开关旁边或下方，因为它们都属于 Metal/GPU 相关的调试功能：

```
[ Metal HUD Toggle ]        (已有)
[ Metal Capture Toggle ]    (新增)
[ LLDB / Debugger ]         (已有)
```

### 验收标准

1. 设置界面中出现 Metal Capture 开关
2. 开关状态正确保存到 `AppSettingsData`
3. 本地化字符串正确显示（至少 en、zh-Hans、zh-Hant）
4. 项目编译通过

### 测试（参照统一测试策略）

**本 task 新增检查项**：C18 ~ C19

| # | 检查项 | 层级 |
|---|--------|------|
| C18 | GUI Metal Capture Toggle 存在 | L3 |
| C19 | 本地化字符串含 `metalCapture` | L3 |

**完成后验证范围**：C01 ~ C19（含 R01~R04 的 C01~C17 回归）

**执行方式**：`./Scripts/verify_render_capture.sh`

**人工验证**：
1. 运行 PlayCover，打开某个 app 的设置界面，确认 Metal Capture Toggle 可见
2. 切换开关，确认设置正确保存（检查对应的 `.plist` 文件）
3. 重启 PlayCover，确认设置状态保持

### 实施结果

- **实际改动文件**：
  - `PlayCover/Views/AppSettingsView.swift` — 在 MiscView 的 Metal HUD 区域下方新增 Metal Capture Toggle
  - `PlayCover/en.lproj/Localizable.strings` — 新增 `settings.toggle.metalCapture` 和 `settings.help.metalCapture`
  - `PlayCover/zh-Hans.lproj/Localizable.strings` — 新增中文简体本地化
  - `PlayCover/zh-Hant.lproj/Localizable.strings` — 新增中文繁体本地化
  - 其余 18 个语言的 `Localizable.strings` — 新增对应语言的本地化字符串
  - `LocalDocs/RenderCapture/00-主文档.md` — 更新任务看板状态
  - `LocalDocs/RenderCapture/R05-GUI设置界面.md` — 更新任务状态和实施结果
- **关键决策**：
  - Toggle 放置在 MiscView 中 Metal HUD 区域下方，与 Debugger 区域之间，符合"Metal/GPU 调试功能"的逻辑分组
  - 参考 `metalHUD` Toggle 的模式，使用 `$settings.settings.metalCaptureEnabled` 直接绑定 AppSettingsData
  - Metal Capture 不需要 macOS 版本限制（MTLCaptureManager 在 macOS 10.15+ 可用）
  - 为所有 21 个语言文件都添加了本地化，主要语言（en/zh-Hans/zh-Hant/ja/ko/de/fr/es/ru/it/da/id/vi/pt-br/tr/hi/uk）使用了对应语言的翻译
  - 次要语言（ar/ca/fa/ro）由于 Localizable.strings 中其他条目也多为英文占位，保持英文
- **已知问题**：无
- **Commit Hash**：`71cfeab7`
