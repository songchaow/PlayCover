# G06：UI 状态指示（可选）

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | 🔲 待开始 |
| **前置依赖** | G04（MCPManager 已工作） |
| **预估工时** | 0.5 天 |
| **风险等级** | 低 |
| **优先级** | 可选（非必须） |

## 目标

在 GUI 界面中显示 MCP Server 的运行状态，包括：是否在运行、监听端口、连接的客户端数量。可选提供手动启停功能。

## 设计方案

### 信息来源

`MCPManager` 已暴露以下 `@Published` 属性：
- `isRunning: Bool`
- `connectedClients: Int`
- `port: UInt16`
- `lastError: String?`

### UI 位置建议

可以在以下位置之一显示 MCP 状态：

1. **Settings 页面**（推荐）：在 `PlayCoverSettingsView` 中添加一个 "MCP Server" 区域
2. **菜单栏**：在 PlayCover 的菜单中显示状态
3. **底部状态栏**：在主窗口底部显示小型状态指示

### 最小实现

```swift
// PlayCover/Views/Settings/MCPStatusView.swift

import SwiftUI

struct MCPStatusView: View {
    @ObservedObject var mcpManager = MCPManager.shared
    
    var body: some View {
        GroupBox("MCP Server") {
            HStack {
                Circle()
                    .fill(mcpManager.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(mcpManager.isRunning ? "Running" : "Stopped")
                Spacer()
                if mcpManager.isRunning {
                    Text("Port: \(mcpManager.port)")
                        .foregroundColor(.secondary)
                    Text("Clients: \(mcpManager.connectedClients)")
                        .foregroundColor(.secondary)
                }
            }
            if let error = mcpManager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }
}
```

## 实现步骤

### Step 1：确保 MCPManager 的状态正确更新

G04 中创建的 MCPManager 需要实时更新 `connectedClients` 属性。这可能需要在 TCPTransport 中添加连接数变化的回调：

```swift
// TCPTransport 中添加回调
var onClientCountChanged: ((Int) -> Void)?

// 连接/断开时调用
DispatchQueue.main.async { [weak self] in
    self?.onClientCountChanged?(self?.connections.count ?? 0)
}

// MCPManager 中绑定
transport.onClientCountChanged = { [weak self] count in
    self?.connectedClients = count
}
```

### Step 2：创建 MCPStatusView

新建 `PlayCover/Views/Settings/MCPStatusView.swift`。

### Step 3：集成到 Settings 页面

在 `PlayCoverSettingsView` 中添加 MCPStatusView。需要先了解 Settings 页面的当前结构。

### Step 4：添加到 Xcode 工程

将新文件添加到 PlayCover.app target。

## 验收标准

- [ ] GUI 中可以看到 MCP Server 运行状态
- [ ] 状态指示与实际状态一致
- [ ] Agent 连接/断开时客户端数字实时更新
- [ ] `xcodebuild -scheme PlayCover build` 通过
- [ ] MCP 全量测试通过

## 测试计划

1. **编译测试**：PlayCover scheme build 通过
2. **功能测试**：
   - 启动 GUI → 看到绿色 Running 指示
   - `nc localhost 19820` 连接 → 客户端数 +1
   - 断开连接 → 客户端数 -1
3. **回归测试**：MCP 全量测试通过

## 实际测试结果

> （由执行 agent 在完成后填写）

---

## 注意事项

1. 这是一个**可选任务**，如果时间不足可以跳过
2. `@Published` 属性更新必须在主线程
3. 不要在这个任务中修改 MCPManager 的核心逻辑，只添加 UI 绑定
