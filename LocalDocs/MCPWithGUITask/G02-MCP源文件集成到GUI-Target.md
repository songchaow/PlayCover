# G02：MCP 源文件集成到 GUI Target

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | G01（Shell 命名冲突已解决） |
| **预估工时** | 0.5-1 天 |
| **风险等级** | 高（涉及 pbxproj 修改） |

## 目标

让 MCP 的核心源文件能在 PlayCover.app GUI target 中编译，使 `MCPServer`、所有 Service、Protocol 类型等在 GUI 进程内可用。

## 方案选择

### 方案 A：直接 Target Membership（推荐首选）

将 MCP 源文件添加到 PlayCover.app target 的 Sources build phase。

**优点**：
- 改动量最小，只修改 pbxproj
- 不需要新增 framework target
- 不需要改造测试 target

**缺点**：
- 同一源文件出现在多个 target 的 Sources build phase 中（但这是 Xcode 支持的标准做法）
- 编译时间略增

**需要添加的文件**（约 39 个，排除 `main.swift` 和 `StdioTransport.swift`）：
- `PlayCoverMCP/Server/MCPServer.swift`
- `PlayCoverMCP/Protocol/MCPTypes.swift`
- `PlayCoverMCP/HostServices/Shell.swift`（已改名为 MCPShell）
- `PlayCoverMCP/HostServices/AppService.swift`
- `PlayCoverMCP/HostServices/Install/InstallerService.swift`
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`
- `PlayCoverMCP/HostServices/Cleanup/CleanupService.swift`
- `PlayCoverMCP/HostServices/Signing/SigningService.swift`
- `PlayCoverMCP/HostServices/Injection/InjectionService.swift`
- `PlayCoverMCP/HostServices/Keymap/KeymapService.swift`
- `PlayCoverMCP/HostServices/Settings/SettingsService.swift`
- `PlayCoverMCP/Tools/*.swift`（所有 Tools 注册文件）
- `PlayCoverMCP/Resources/*.swift`（所有 Resources 注册文件）
- `PlayCoverMCP/Session/*.swift`（SessionRegistry、SessionService、TouchService、InputService）
- `PlayCoverMCP/Registry/*.swift`（ToolRegistry、ResourceRegistry）
- `PlayCoverMCP/Logging/MCPLogger.swift`
- `PlayCoverMCP/Tasks/TaskManager.swift`
- 以及其他 Common / Protocol 下的辅助文件

### 方案 B：创建 PlayCoverMCPCore Framework

创建独立的 framework target，PlayCover.app 和 PlayCoverMCP 都链接它。

**优点**：
- 架构更清晰
- 编译缓存更好

**缺点**：
- pbxproj 改动量巨大（新 target + build phases + configurations + dependencies + embed frameworks）
- 需要同步改造 PlayCoverMCPTests
- 风险高

**建议**：优先尝试方案 A，如果遇到无法解决的编译问题再考虑方案 B。

## 实现步骤（方案 A）

### Step 1：列出所有需要添加的文件

先获取 PlayCoverMCP target 当前的 Sources build phase 文件列表：

```bash
# 从 pbxproj 中提取 PlayCoverMCP 的 Sources build phase 文件
grep -A 200 "PlayCoverMCP.*Sources" PlayCover.xcodeproj/project.pbxproj | head -80
```

排除以下文件（不加入 GUI target）：
- `main.swift` — GUI 有自己的 @main 入口
- `StdioTransport.swift` — GUI 使用 TCPTransport

### Step 2：编写 Python 集成脚本

**强烈建议**使用 Python 脚本修改 pbxproj，而非手动编辑。脚本要求：

1. 从 pbxproj 中**动态查找** PlayCover.app target 的 Sources build phase ID
2. 从 pbxproj 中查找每个 MCP 文件的 `PBXFileReference` ID
3. 为每个文件创建新的 `PBXBuildFile` 条目（新的唯一 ID）
4. 将新的 `PBXBuildFile` 添加到 PlayCover.app target 的 Sources build phase
5. 每步操作后验证

**脚本模板参考**（`Scripts/add_mcp_to_gui.py`）：

```python
#!/usr/bin/env python3
"""将 MCP 源文件添加到 PlayCover.app target 的 Sources build phase"""

import os
import re
import subprocess
import uuid

PBX = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", 
    "PlayCover.xcodeproj", "project.pbxproj"
))

# 需要排除的文件
EXCLUDE_FILES = {"main.swift", "StdioTransport.swift"}

def generate_id():
    """生成 24 字符的 Xcode 风格 ID"""
    return uuid.uuid4().hex[:24].upper()

def lint():
    """验证 pbxproj 格式"""
    result = subprocess.run(["plutil", "-lint", PBX], capture_output=True, text=True)
    return "OK" in result.stdout

# ... 具体实现由 agent 完成
```

### Step 3：运行脚本并验证

```bash
# 1. 确认当前状态
plutil -lint PlayCover.xcodeproj/project.pbxproj

# 2. 运行脚本
python3 Scripts/add_mcp_to_gui.py

# 3. 三步验证
plutil -lint PlayCover.xcodeproj/project.pbxproj
git diff PlayCover.xcodeproj/project.pbxproj | head -100

# 4. 编译验证
xcodebuild -scheme PlayCover -configuration Release build 2>&1 | tail -10
xcodebuild -scheme PlayCoverMCP -configuration Release build 2>&1 | tail -10
```

### Step 4：处理编译错误

可能遇到的编译问题：

1. **`String: Error` conformance 冲突**
   - GUI 的 `Shell.swift` 有 `extension String: Error`
   - 如果 MCP 代码中有 `throw someString` 或 `catch let error as String`，可能需要调整
   - 检查方法：编译后看错误信息

2. **重复符号**
   - 如果 MCP 和 GUI 都定义了相同名称的类型（除了已处理的 Shell 之外）
   - 目前已知不冲突：`AppInfo` vs `AppRecord`、`PlayApp` vs 无对应

3. **Log 冲突**
   - MCP 使用 `MCPLogger`，GUI 使用 `Log.shared`，两者不冲突
   - 但如果有全局 `log()` 函数名冲突，需要用完整限定名

4. **访问级别**
   - MCP 文件多数声明为 `public`，在同一 target 中 `public` 相当于 `internal`，不影响功能
   - 检查是否有 `internal` 限定符导致的访问问题

## 验收标准

- [ ] MCP 源文件（除 `main.swift` 和 `StdioTransport.swift`）已添加到 PlayCover.app target
- [ ] `plutil -lint` 通过
- [ ] `xcodebuild -scheme PlayCover build` 通过（GUI target 包含 MCP 代码）
- [ ] `xcodebuild -scheme PlayCoverMCP build` 通过（CLI target 不受影响）
- [ ] `xcodebuild test -scheme PlayCoverMCP` 全量测试通过
- [ ] 集成脚本 `Scripts/add_mcp_to_gui.py` 可重复运行或记录了修改方式

## 测试计划

1. **编译测试**：两个 scheme 都能 build 通过
2. **单元测试**：MCP 全量测试通过
3. **回归验证**：
   - GUI app 能正常启动（如果可以验证的话）
   - MCP CLI 能正常工作
4. **符号冲突检查**：编译输出中无 duplicate symbol 警告

## 实际测试结果

### 编译测试
- **PlayCover GUI (Nightly, CODE_SIGNING_ALLOWED=NO)**：Swift 编译 ✅ + 链接 ✅（生成 112 个 .o 文件，可执行文件 9.1MB）。BUILD FAILED 仅因 "Codesign sparkle" 脚本签名环境问题，非代码问题。
- **PlayCoverMCP CLI (Release)**：BUILD SUCCEEDED ✅
- **PlayCoverMCPTests**：572 tests, 1 skipped, 0 failures ✅ TEST SUCCEEDED

### 方案选择
- 采用**方案 A（直接 Target Membership）**，成功

### 关键修改清单
1. 使用 Python 脚本 `Scripts/add_mcp_to_gui.py` 将 39 个 MCP 源文件添加到 PlayCover.app target 的 Sources build phase（排除 `main.swift` 和 `StdioTransport.swift`）
2. 将 `PlayCoverMCP/HostServices/Shell.swift` 重命名为 `MCPShell.swift`（Swift WMO 不允许同 target 同名文件）
3. 更新 pbxproj 中 MCP Shell.swift 的 PBXFileReference 和 PBXBuildFile 引用为 MCPShell.swift
4. 修复 GUI target 的 `SYSTEM_FRAMEWORK_SEARCH_PATHS` → 改为 `FRAMEWORK_SEARCH_PATHS`（解决 Network.framework 与 PrivateFrameworks 路径冲突）

### 遇到的问题
1. **文件名冲突**：GUI `Shell.swift` 和 MCP `Shell.swift` 同名，WMO 编译器报错。解决：重命名 MCP 文件为 `MCPShell.swift`。
2. **Network.framework 导入失败**：`SYSTEM_FRAMEWORK_SEARCH_PATHS` 指向 PrivateFrameworks 导致系统 Network.framework 被错误地从 PrivateFrameworks 加载。解决：改为 `FRAMEWORK_SEARCH_PATHS`。
3. **Carthage 环境问题**：需安装 carthage 并设置 `FASTLANE=1` 跳过 bootstrap 脚本才能编译验证。

---

## 注意事项

1. **pbxproj 修改必须遵循三步验证**（见主文档 6.2 节）
2. 如果 `plutil -lint` 失败，立即 `git checkout -- PlayCover.xcodeproj/project.pbxproj`
3. 脚本中的 ID 必须**动态查找**，不要硬编码
4. 每个需要添加到 GUI target 的文件，都需要一个**新的 PBXBuildFile 条目**（不能复用 MCP target 的）
5. 注意 `extension String: Error` 的潜在影响——编译通过后要仔细检查警告
6. 如果方案 A 遇到无法解决的问题，记录问题详情并在经验教训中说明，然后尝试方案 B
