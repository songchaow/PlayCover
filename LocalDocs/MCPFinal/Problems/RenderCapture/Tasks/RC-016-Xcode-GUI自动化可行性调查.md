## RC-016：Xcode GPU Frame Capture GUI 自动化可行性调查

### 一、背景

macOS 提供 Accessibility API（通过 `System Events`），可以用 AppleScript / JXA (JavaScript for Automation) 操控 GUI 应用。本任务调查通过该机制操控 Xcode GPU Frame Capture 窗口的可行范围。

**测试环境**：Xcode 打开了 `capture_20260401_011127.gputrace` 文件（原神截帧产物）。

**工具依赖**：`cliclick`（`brew install cliclick`）— 用于坐标级物理点击，解决 JXA `.click()` 对部分控件失效的问题。

### 二、结论总览

| 能力 | 可行性 | 方法 |
|---|---|---|
| **读取 Debug Navigator 树** | ✅ 完全可行 | JXA 读取 outline rows |
| **选择 Navigator 节点** | ✅ 完全可行 | `row.selected = true` |
| **展开/折叠 Navigator 节点** | ✅ 可行 | `cliclick c:x,y` 点击 disclosure triangle |
| **切换 GPU Navigator 模式** | ✅ 完全可行 | 点击 popup button |
| **读取编辑器 outline（GPU 绑定表）** | ✅ 完全可行 | JXA 读取 editor outline |
| **读取面包屑导航栏（当前位置）** | ✅ 完全可行 | 读取 breadcrumb popups 的 value |
| **通过面包屑跳转** | ✅ 完全可行 | 点击 breadcrumb popup 选菜单项 |
| **Step to Next/Prev Draw Call** | ✅ 完全可行 | Debug 菜单点击 |
| **Step to Next/Prev GPU Call** | ✅ 完全可行 | Debug 菜单点击 |
| **读取 Inspector 区域** | ✅ 可行 | Attachments (Color/Depth/Stencil) + 资源大小 |
| **切换 Inspector 显示模式** | ✅ 可行 | cliclick 点击 popup |
| **Debug Pixel 按钮** | ✅ 可行 | JXA click |
| **截取窗口截图** | ✅ 可行 | `screencapture -x` |
| **切换 Navigator 面板** | ✅ 完全可行 | View > Navigators 菜单 |
| **切换 Filter Toggles** | ✅ 可行 | Bound/Accessed/All/Vertex/Fragment 复选框 |
| **Release GPU Workload** | ✅ 可用 | Debug 菜单 (enabled=true) |
| **Import Metallib Debug Info** | ✅ 可用 | Debug 菜单 (enabled=true) |
| **Analyze GPU Performance** | ❌ 不可用 | 菜单项 disabled |
| **修改 Inspector 坐标 TextField** | ❌ 未成功 | JXA set value 失败 |

### 三、详细测试结果

#### 3.1 窗口结构

```
Window 1 (1728x994)  AXIdentifier: Xcode.WorkspaceWindow
├── Toolbar
│   ├── Button: Hide Navigator
│   ├── Group (中间)
│   ├── Button: Library
│   └── Button: Show Inspector
├── Group: navigator (描述: "navigator")
│   ├── RadioButton ×9: Project / Source Control / Bookmarks / Find / Issues / Tests / Debug / Breakpoints / Reports
│   └── ScrollArea
│       └── Outline: "Debug Navigator"
│           ├── Row 0: capture_20260401_011127 (根节点, disclosure=1 已展开)
│           ├── Row 1: Summary
│           ├── Row 2: Dependencies
│           ├── Row 3: Performance
│           ├── Row 4: Memory | 203.03 MiB
│           ├── Row 5: [PopUpButton: GPU Navigator Mode]
│           └── Row 6-28: Command Buffer 0-22 (各有 DisclosureTriangle)
│               └── (展开后) Render Encoder 0-N + presentDrawable
├── SplitterGroup (主编辑区)
│   ├── Tab Bar
│   │   └── PopUpButton (breadcrumb 面包屑): gputrace > CB > RE > drawCall
│   ├── PopUpButton: "Bound Resources" (编辑器模式选择)
│   ├── PopUpButton: "Automatic" (Inspector 模式)
│   ├── PopUpButton: "Attachments" (Inspector 子模式)
│   ├── CheckBox: Bound / Accessed / All / Vertex / Fragment
│   └── Outline (GPU 绑定表, 67+ 行)
│       ├── Render Pipeline State → shader 名
│       ├── Vertex → Index/Buffer/Texture/Sampler
│       ├── Fragment → Texture/Buffer/Sampler
│       └── Attachments → Color/Depth/Stencil
├── Inspector 区 (x > 1100)
│   ├── Grid: "Color 0" (382×214) — 渲染目标预览
│   ├── Grid: "Depth: InnerTarget of LoginCamera(Clone)"
│   ├── Grid: "Stencil: InnerTarget of LoginCamera(Clone)"
│   ├── TextField: X=448, Y=607 (像素坐标)
│   ├── Stepper: X/Y 微调
│   ├── Button: "Debug Pixel"
│   └── MenuButton: "16%" (缩放)
├── Debug Bar
│   ├── CheckBox: Breakpoints
│   ├── Button: Stop GPU workload
│   └── Button: hide debug area
└── Debug Area
    ├── TextArea: Console
    ├── TextArea: debug console
    └── TextField: Console Filter Field
```

#### 3.2 读取 Debug Navigator（Command Buffer 列表）

```javascript
const nav = win.groups.whose({description: "navigator"})[0];
const outline = nav.scrollAreas[0].outlines[0];
const rows = outline.rows();
// 每行的文本: rows[i].uiElements[0].staticTexts() → .value()
```

结果：成功读到 29 行（Summary/Dependencies/Performance/Memory + 23 个 Command Buffer）。

#### 3.3 选择节点

```javascript
outline.rows[1].selected = true; // 选中 Summary
outline.rows[6].selected = true; // 选中 Command Buffer 0
```

✅ 设置 `selected = true` 后 Xcode 界面同步更新，编辑器区显示对应内容。

#### 3.4 展开/折叠 Disclosure Triangle ✅（第二轮测试成功）

JXA 的 `.click()` 和 `AXPress` 对 Xcode outline 的 disclosure triangle **无效**，但 **`cliclick` 坐标点击可以成功展开**：

```bash
# 1. 用 JXA 获取 disclosure triangle 的精确坐标
osascript -l JavaScript -e '
let all = win.entireContents();
for (let i = 0; i < all.length; i++) {
    if (all[i].role() === "AXDisclosureTriangle" && all[i].value() === 0) {
        let pos = all[i].position();
        let sz = all[i].size();
        // 中心点
        console.log((pos[0] + sz[0]/2) + "," + (pos[1] + sz[1]/2));
    }
}
'

# 2. 用 cliclick 物理点击
cliclick c:33,307  # CB0 的 disclosure triangle 中心
```

**测试结果**：CB0 展开后 rows 从 29 增加到 56，可以看到所有 Render Encoder 子节点：
```
Row 7:  Render Encoder 0 0x3166961b0
Row 8:  Render Encoder 1 0x316696120
...
Row 32: Render Encoder 25 0x371d32fd0
Row 33: 5321 [presentDrawable:0x14fb9f5a0]
```

#### 3.5 GPU Navigator Mode 切换

```javascript
let popup = outline.rows[5].uiElements[0].popUpButtons[0];
popup.value(); // → "Group by API Call"
popup.click();
popup.menus[0].menuItems["Group by Pipeline State"].click();
```

可用选项：
- **Group by API Call**（默认）— 按 Command Buffer 分组
- **Group by Pipeline State** — 按 Pipeline State/Shader 名分组

Pipeline State 模式下可看到全部 56 个 shader pass：
```
miHoYo/Scene/Login Base (×8)
Hidden/Internal-MotionVectors (×3)
Hidden/PostProcessing/miHoYo/Bloom (×3)
Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter (×5)
Dynamic Sky/Cloud Particle_Login_New
Dynamic Sky/Cloud Layer
Dynamic Sky/Atmosphere Layer
Dynamic Sky/Stars Mesh / Moon Layer
Hidden/Internal-DeferredShading (×3)
Hidden/PostProcessing/TemporalAntialiasing
Hidden/PostProcessing/miHoYo/Motion Blur (×2)
Hidden/PostProcessing/Uber
UI/Default
... 等
```

#### 3.6 面包屑导航栏（Breadcrumb） ✅（第二轮新发现）

编辑器上方有 **4 层 breadcrumb popup**，可以读取当前位置和跳转：

| 层级 | 位置 | 示例值 |
|---|---|---|
| gputrace 文件 | (384,105) | `capture_20260401_011127.gputrace` |
| Command Buffer | (421,105) | `Command Buffer 4 0x316698e60` |
| Render Encoder | (453,105) | `Render Encoder 16 0x34d8f6480` |
| Draw Call | (485,105) | `25765 [drawIndexedPrimitives:Triangle indexCount:3 ...]` |

**面包屑 popup 内容极其丰富**：
- CB popup 列出所有 texture view 创建、nextDrawable、Command Buffer 等事件
- RE popup 列出 commandBuffer 创建、所有 Render Encoder、presentDrawable、commit 等
- 面包屑会随 Step Next/Prev 自动更新

额外 popup：
| Popup | 位置 | 值 | 说明 |
|---|---|---|---|
| Bound Resources | (927,105) | `Bound Resources` | 编辑器主模式 |
| Automatic | (1128,105) | `Automatic` | Inspector 模式 |
| Attachments | (1223,105) | `Attachments` | Inspector 子模式 |
| Auto | (388,1008) | `Auto` | 控制台过滤 |

#### 3.7 Inspector 模式选项（通过 cliclick 打开） ✅（第二轮成功）

Automatic popup 的完整选项树：
```
Automatic       ← 当前
Attachments
──────────
Attachments
Geometry
Bound Resources ──┬── All Resources
                  ├── (separator)
                  ├── Performance
                  └── Pipeline Statistics
```

#### 3.8 读取编辑器 GPU 绑定表

选中某个 draw call 后，编辑器 outline 展示完整的资源绑定信息（67 行），包含：

| 列 | 示例 |
|---|---|
| 资源名 | `ScratchBuffer2_2`, `Enviro_Sky_Gradient`, `InnerTarget of LoginCamera(Clone)` |
| 绑定点 | `Buffer 0`, `Texture 0`, `Sampler 1`, `Index`, `Visibility Buffer` |
| 类型 | `Buffer`, `Texture 2D`, `Texture 1D`, `Sampler`, `Function` |
| Uniform 名 | `VGlobals`, `UnityDrawCallInfo`, `FGlobals` |
| 访问模式 | `Read` |
| Insights | `63 insights` |
| 大小 | `768.00 KiB`, `12.06 MiB` |
| Attachment 行为 | `Load`, `Store`, `Clear`, `Don't Care` |

段落划分：
- **Render Pipeline State** → shader 名 + vertex/fragment function (`xlatMtlMain`)
- **Vertex** → vertex stage 资源 (Index, Buffer, Texture, Sampler)
- **Vertex Attributes / Post Vertex Transform** (几何信息)
- **Fragment** → fragment stage 资源
- **Attachments** → Color 0 / Depth / Stencil (含 load/store action)

#### 3.9 Inspector 区域（右侧）

| 元素 | 类型 | 内容 |
|---|---|---|
| Color 0 | Grid (382×214) | 渲染目标预览图 |
| Depth | Grid | `Depth: InnerTarget of LoginCamera(Clone)` |
| Stencil | Grid | `Stencil: InnerTarget of LoginCamera(Clone)` |
| X/Y 坐标 | TextField + Stepper | X=448, Y=607 |
| Debug Pixel | Button | ✅ 可点击 |
| 缩放 | MenuButton | `16%` |
| 资源大小列表 | StaticText | `2.21 KiB`, `12.06 MiB`, `3.09 MiB` 等 |

#### 3.10 Debug 菜单 GPU 操作

| 菜单项 | enabled | 测试结果 |
|---|---|---|
| Release GPU Workload | ✅ | 可点击 |
| Import Metallib Debug Info… | ✅ | 可点击（会弹对话框） |
| Analyze GPU Performance | ❌ | disabled |
| Reload Shaders | ❌ | disabled |
| Step to Previous Draw/Dispatch Call | ✅ | **成功** — 导航到上一个 draw call |
| Step to Next Draw/Dispatch Call | ✅ | **成功** — 导航到下一个 draw call |
| Step to Previous GPU Call | ✅ | **成功** — 更细粒度导航 |
| Step to Next GPU Call | ✅ | **成功** — 更细粒度导航 |

**连续步进测试**（5 步）：
```
Step 1: CB4 > RE14 > 25638 [drawIndexedPrimitives:Triangle indexCount:3 ...]
Step 2: CB4 > RE15 > 25640 [renderCommandEncoderWithDescriptor:<data>]
Step 3: CB4 > RE15 > 25702 [drawIndexedPrimitives:Triangle indexCount:3 ...]
Step 4: CB4 > RE16 > 25704 [renderCommandEncoderWithDescriptor:<data>]
Step 5: CB4 > RE16 > 25765 [drawIndexedPrimitives:Triangle indexCount:3 ...]
```

#### 3.11 截图

```bash
screencapture -x /tmp/xcode_gputrace.png
```

✅ 成功截取。

### 四、工具选择指南

| 工具 | 适用场景 | 注意事项 |
|---|---|---|
| **JXA** (`osascript -l JavaScript`) | 读取 UI 树、选择行、读取 value、菜单点击 | 主力工具，0-based 索引 |
| **cliclick** (`brew install cliclick`) | Disclosure triangle 展开、自定义 popup 点击 | JXA `.click()` 对某些控件无效时用 |
| **AppleScript** | 简单菜单操作 | 深层 UI 引用容易报错，不推荐 |
| **screencapture** | 截图 | `-x` 静音，`-l <id>` 指定窗口 |

### 五、已知限制

1. **渲染预览像素读取**：Inspector 中的 Color/Depth/Stencil 预览是 Metal 渲染的 Grid 控件，无法通过 Accessibility API 读取像素，只能截图。
2. **快捷键未暴露**：Debug 菜单的 GPU 步进操作没有分配快捷键（keystroke 为空）。
3. **TextField 写入**：Inspector 中的坐标 TextField（X/Y）无法通过 JXA `set value` 修改。
4. **部分 Popup 需要 cliclick**：Inspector 区的 Automatic/Attachments popup 用 JXA `.click()` 打开后无法获取菜单，需要用 `cliclick c:x,y` 物理点击。

### 六、可实现的自动化场景

基于以上测试，以下自动化场景是**完全可行**的：

1. **自动遍历所有 Command Buffer 和 Render Encoder** — 选择 row + cliclick 展开
2. **读取每个 draw call 的完整资源绑定** — 选择后读 editor outline
3. **按 Pipeline State 分组统计 shader 使用** — 切换 GPU Navigator Mode
4. **自动步进遍历所有 draw call** — 循环 "Step to Next Draw/Dispatch Call" + 读面包屑
5. **截图每个 draw call 的渲染状态** — 步进 + screencapture
6. **读取内存使用信息** — Memory row: `203.03 MiB`
7. **读取 texture/buffer 大小** — editor outline 或 inspector 中的 staticText
8. **统计 render pass 和 attachment 信息** — Attachments 段的 Color/Depth/Stencil
9. **切换 Inspector 到 Geometry/Performance/Pipeline Statistics 模式** — cliclick popup

### 七、参考代码片段

#### 读取所有 Command Buffer 名称
```javascript
osascript -l JavaScript -e '
const se = Application("System Events");
const xcode = se.processes["Xcode"];
const win = xcode.windows[0];
const nav = win.groups.whose({description: "navigator"})[0];
const outline = nav.scrollAreas[0].outlines[0];
const rows = outline.rows();
for (let i = 0; i < rows.length; i++) {
    let texts = rows[i].uiElements[0].staticTexts();
    let t = texts.map(s => s.value()).filter(v => v).join(" | ");
    console.log(i + ": " + t);
}
'
```

#### 展开 Command Buffer 节点
```bash
# 1. JXA 获取 disclosure triangle 坐标
osascript -l JavaScript -e '
const se = Application("System Events");
const win = se.processes["Xcode"].windows[0];
let all = win.entireContents();
for (let i = 0; i < all.length; i++) {
    try {
        if (all[i].role() === "AXDisclosureTriangle" && all[i].value() === 0) {
            let p = all[i].position(), s = all[i].size();
            console.log(Math.round(p[0]+s[0]/2) + "," + Math.round(p[1]+s[1]/2));
        }
    } catch(e) {}
}
'
# 2. cliclick 物理点击展开
cliclick c:33,307
```

#### 步进并读取面包屑
```javascript
osascript -l JavaScript -e '
const se = Application("System Events");
const xcode = se.processes["Xcode"];
const win = xcode.windows[0];
// Step
xcode.menuBars[0].menus["Debug"].menuItems["Step to Next Draw/Dispatch Call"].click();
delay(0.5);
// Read breadcrumbs
let all = win.entireContents();
let crumbs = [];
for (let i = 0; i < all.length; i++) {
    try {
        if (all[i].role() === "AXPopUpButton") {
            let pos = all[i].position();
            if (pos[1] > 95 && pos[1] < 115 && pos[0] > 380) {
                crumbs.push(all[i].value());
            }
        }
    } catch(e) {}
}
crumbs.join(" > ");
'
```

#### 切换 Inspector 模式（需要 cliclick）
```bash
# 点击 "Automatic" popup (1145, 105)
cliclick c:1145,105
sleep 0.3
# 然后用 JXA 读取菜单并选择
# 选项: Automatic, Attachments, Geometry, Bound Resources > (All/Performance/Pipeline Statistics)
```
