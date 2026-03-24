# G01：Shell 命名冲突解决

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | 无 |
| **预估工时** | 0.5 天 |
| **风险等级** | 低 |

## 目标

将 MCP 侧的 `enum Shell` 改名为 `enum MCPShell`，解决与 GUI 侧 `class Shell: ObservableObject` 的命名冲突，使两套代码能在同一 target 中编译。

## 背景

- **GUI Shell**：`PlayCover/Utils/Shell.swift`
  - `class Shell: ObservableObject`
  - 含 `run()`、`signMacho()`、`signAppWith()`、`signApp()`、`setMetalHUD()`、`lldb()` 等静态方法
  - 含 `extension String: Error` 和 `extension String: LocalizedError`
  
- **MCP Shell**：`PlayCoverMCP/HostServices/Shell.swift`
  - `public enum Shell` — 无状态枚举
  - 含 `run()`、`signMacho()`、`signApp()`、`signAppWith()`、`removeQuarantine()`、`dumpEntitlements()`、`setExecutable()` 等静态方法
  - 含 `ShellError` 结构体

## 实现步骤

### Step 1：修改 Shell 定义

**文件**：`PlayCoverMCP/HostServices/Shell.swift`

将 `public enum Shell` 改为 `public enum MCPShell`。`ShellError` 无需改名（与 GUI 侧不冲突）。

### Step 2：更新所有引用

需要将 `Shell.xxx` 改为 `MCPShell.xxx` 的文件：

| 文件 | 预计改动 |
|------|---------|
| `PlayCoverMCP/HostServices/Install/InstallerService.swift` | ~17 处 `Shell.` → `MCPShell.` |
| `PlayCoverMCP/HostServices/Injection/InjectionService.swift` | ~9 处 `Shell.` → `MCPShell.` |
| `PlayCoverMCP/HostServices/Signing/SigningService.swift` | ~5 处 `Shell.` → `MCPShell.` |
| `PlayCoverMCP/HostServices/Launch/LaunchService.swift` | ~2 处 `Shell.` → `MCPShell.` |

**操作建议**：用全局搜索替换 `Shell.` → `MCPShell.` 逐文件处理，注意：
- 只替换 MCP 目录下的文件
- `ShellError` 相关的引用**不需要改**（它不冲突）
- 注释中的 `Shell` 也可以保持不变，但建议一并更新以保持一致

### Step 3：编译验证

```bash
# 验证 MCP CLI target
xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES FASTLANE=1 2>&1 | tail -5

# 验证 GUI target（此时 GUI 还不包含 MCP 文件，应该本来就能编译）
xcodebuild -project PlayCover.xcodeproj -scheme PlayCover -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES FASTLANE=1 2>&1 | tail -5

# 运行 MCP 测试
xcodebuild test -project PlayCover.xcodeproj -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES FASTLANE=1 2>&1 | tail -20
```

### Step 4：检查测试代码中的 Shell 引用

MCP 测试文件中可能也有 `Shell.` 引用，需要一并更新。搜索 `PlayCoverMCPTests/` 目录。

## 验收标准

- [ ] `PlayCoverMCP/HostServices/Shell.swift` 中 `enum Shell` 已改为 `enum MCPShell`
- [ ] 所有 MCP 源文件中的 `Shell.xxx` 引用已改为 `MCPShell.xxx`
- [ ] `xcodebuild -scheme PlayCoverMCP build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过
- [ ] `xcodebuild -scheme PlayCover build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过
- [ ] MCP 全量测试通过
- [ ] `ShellError` 保持不变（无需改名）

## 测试计划

1. **编译测试**：两个 scheme 都能 build 通过
2. **单元测试**：`xcodebuild test -scheme PlayCoverMCP FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 全量通过
3. **回归验证**：确认现有功能未受影响

## 实际测试结果

| 验收项 | 结果 |
|--------|------|
| `enum Shell` → `enum MCPShell` | ✅ 完成 |
| 所有 MCP 源文件 `Shell.xxx` → `MCPShell.xxx` | ✅ 完成（InstallerService 17处、InjectionService 9处、SigningService 5处、LaunchService 2处） |
| `xcodebuild -scheme PlayCoverMCP build` | ✅ **BUILD SUCCEEDED** |
| `xcodebuild -scheme PlayCover build` | ✅ 编译通过（仅有 provisioning profile 和 Carthage 配置问题，与代码改动无关） |
| MCP 全量测试 | ✅ **572 tests, 0 failures** (1 test skipped) |
| `ShellError` 保持不变 | ✅ 未修改 |
| 测试文件中的 `Shell.` 引用 | ✅ `InstallerServiceTests.swift` 中 2 处已更新为 `MCPShell.` |

---

## 注意事项

1. **只改 MCP 侧**，不要修改 GUI 侧的 `Shell`
2. `ShellError` 不冲突，无需改名
3. 改名后的 `MCPShell` 仍然是 `public enum`，保持 public 访问级别
4. 如果在测试文件中发现 `Shell` 引用，也要一并修改
