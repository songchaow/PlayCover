## 方案 D：URL 直装

### 一、核心设计

扩展 `install_ipa` 和 `export_patched_ipa` 工具，新增可选的 `ipaURL` 参数。当提供 URL 时，MCP 自行下载文件到本地临时目录，然后走现有安装/导出流程。

### 二、参数变更

#### `install_ipa`

| 参数 | 类型 | 必需 | 变更 |
|---|---|---|---|
| `ipaPath` | string | 二选一 | 原有，保持不变 |
| `ipaURL` | string | 二选一 | **新增**，HTTP/HTTPS URL |
| `injectPlayTools` | boolean | 否 | 原有，保持不变 |
| `applicationCategory` | string | 否 | 原有，保持不变 |

**参数互斥规则**：
- `ipaPath` 和 `ipaURL` 必须提供其中一个
- 如果同时提供，优先使用 `ipaURL`（以 URL 为准）
- 两个都不提供 → 返回 `invalidParams` 错误

#### `export_patched_ipa`

| 参数 | 类型 | 必需 | 变更 |
|---|---|---|---|
| `ipaPath` | string | 二选一 | 原有，保持不变 |
| `ipaURL` | string | 二选一 | **新增**，HTTP/HTTPS URL |
| `outputDirectory` | string | 否 | 原有，保持不变 |
| `applicationCategory` | string | 否 | 原有，保持不变 |

同样的互斥规则。

### 三、下载流程

```text
Agent ──tools/call install_ipa(ipaURL="https://...")──▶ MCP Server
                                                          │
                                                          ├── 1. 创建 TaskManager 任务
                                                          ├── 2. 下载文件到暂存目录
                                                          │      ├── 进度: "downloading (30 MB / 100 MB)"
                                                          │      └── 下载完成 → 本地临时路径
                                                          ├── 3. 调用 InstallerService.install(ipaPath: 本地路径)
                                                          │      ├── 进度: "unzip"
                                                          │      ├── 进度: "converting"
                                                          │      └── 进度: "signing"
                                                          ├── 4. 清理临时下载文件
                                                          └── 5. 完成任务，返回结果
```

### 四、下载实现

#### 下载器设计

新文件：`PlayCoverMCP/HostServices/Install/IPADownloader.swift`

```swift
public final class IPADownloader {

    /// 下载超时（秒）
    let timeout: TimeInterval  // 默认 600（10 分钟）

    /// 最大下载大小（字节）
    let maxSize: Int  // 默认 2 GB

    /// 暂存目录
    let downloadDirectory: URL

    /// 下载 IPA 到本地暂存目录
    /// - Parameters:
    ///   - url: 远端 IPA 的 HTTP/HTTPS URL
    ///   - progress: 下载进度回调 (totalBytes, downloadedBytes, message)
    /// - Returns: 本地文件路径
    func download(
        url: URL,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)?
    ) async throws -> URL
}
```

#### 使用 URLSession

- 使用 `URLSession` 的 `download(from:)` API
- 支持 HTTP 和 HTTPS
- 通过 `URLSessionDownloadDelegate` 报告进度
- 下载到临时文件后移到暂存目录

#### 暂存目录

复用方案 C 的暂存目录基础设施：

```text
~/Library/Containers/io.playcover.PlayCover/tmp/mcp-downloads/
```

或者如果方案 C 的 `UploadManager` 已经实现，可以直接复用其目录：

```text
~/Library/Containers/io.playcover.PlayCover/tmp/mcp-uploads/<session-id>/
```

方案 D 的下载文件同样按 session 隔离，同样受 TTL 和 session 清理管控。

但因为方案 D 的下载是 MCP 服务端自己发起的，生命周期更短（安装完即可删除），所以实际上可以在安装完成后立即清理，不依赖 TTL。

#### 文件名

下载后的本地文件名：

```text
download-<8位UUID>-<url最后一段路径>
```

示例：

```text
download-f3a8b2c1-game.ipa
```

如果 URL 没有明确的文件名（如 `https://example.com/download?id=123`），则使用：

```text
download-f3a8b2c1-downloaded.ipa
```

### 五、URL 校验

| 校验项 | 规则 |
|---|---|
| scheme | 只允许 `http` 和 `https` |
| 后缀 | 不强制 `.ipa` 后缀（有些下载链接是动态的） |
| 大小 | 如果 server 返回 `Content-Length`，预检大小限制 |
| 重定向 | 允许，最多跟随 5 次 |

### 六、进度整合

下载和安装是一个长任务的两个阶段，应合并到同一个 TaskManager 任务中：

| 进度区间 | 阶段 |
|---|---|
| 0% – 40% | 下载 |
| 40% – 100% | 安装（与原有进度对齐） |

具体映射：

```text
下载进度:
  total=100, current=0~40, message="downloading (X MB / Y MB)"

安装进度（原有的 0~100 映射到 40~100）:
  total=100, current=40, message="unzip"
  total=100, current=52, message="reading Info.plist"
  total=100, current=58, message="checking MachO binaries"
  ...
  total=100, current=100, message="finish"
```

### 七、错误处理

| 错误场景 | 行为 |
|---|---|
| URL 无效 | 立即返回 `invalidParams` 错误（同步，不创建任务） |
| 下载失败（网络错误） | 任务标记为 failed，错误信息包含 HTTP 状态码或网络错误 |
| 下载超时 | 任务标记为 failed，"Download timed out after N seconds" |
| 文件过大 | 任务标记为 failed，"File exceeds maximum size of N MB" |
| 下载成功但安装失败 | 清理下载文件，任务标记为 failed，错误信息来自 InstallerService |
| 任务被取消 | 取消下载，清理临时文件 |

### 八、InstallerTools 改动

#### install_ipa handler 改动

```swift
server.registerTool(name: "install_ipa") { arguments, context in
    let args = arguments?.dictionary ?? [:]

    let ipaURL = args["ipaURL"] as? String
    let ipaPath = args["ipaPath"] as? String

    // 互斥校验
    guard ipaURL != nil || ipaPath != nil else {
        throw PlayCoverMCPError(
            code: JSONRPCError.invalidParams,
            message: "install_ipa requires either 'ipaPath' or 'ipaURL'"
        )
    }

    // 创建任务
    let taskId = taskManager.createTask(title: "Installing IPA: ...").id

    DispatchQueue.global(qos: .userInitiated).async {
        taskManager.startTask(taskId)

        do {
            // 如果有 URL，先下载
            let resolvedPath: String
            if let urlString = ipaURL {
                guard let url = URL(string: urlString),
                      ["http", "https"].contains(url.scheme?.lowercased()) else {
                    throw PlayCoverMCPError(
                        code: JSONRPCError.invalidParams,
                        message: "ipaURL must be a valid HTTP or HTTPS URL"
                    )
                }

                let localURL = try await downloader.download(
                    url: url,
                    progress: { total, current, message in
                        // 映射到 0~40% 区间
                        let mapped = Int(Double(current) / Double(max(total, 1)) * 40)
                        taskManager.updateProgress(taskId, progress: TaskProgress(
                            total: 100, current: mapped, message: message
                        ))
                    }
                )
                resolvedPath = localURL.path
            } else if let path = ipaPath {
                // 支持 @filename 引用（方案 C）
                resolvedPath = try uploadManager?.resolveReference(path, sessionId: ...) ?? path
            }

            // 调用现有安装逻辑
            let result = try installerService.install(
                ipaPath: resolvedPath,
                injectPlayTools: injectPlayTools,
                applicationCategory: applicationCategory,
                progress: { total, current, message in
                    // 映射到 40~100% 区间
                    let mapped = 40 + Int(Double(current) / Double(max(total, 1)) * 60)
                    taskManager.updateProgress(taskId, progress: TaskProgress(
                        total: 100, current: mapped, message: message
                    ))
                }
            )

            // 清理下载的临时文件
            if ipaURL != nil {
                try? FileManager.default.removeItem(atPath: resolvedPath)
            }

            taskManager.completeTask(taskId, result: ...)
        } catch {
            taskManager.failTask(taskId, error: ...)
        }
    }

    return CallToolResult(content: [.text(content: ...)])
}
```

#### tool schema 更新

```swift
let tool = Tool(
    name: "install_ipa",
    inputSchema: InputSchema(
        type: "object",
        properties: [
            "ipaPath": AnyCodable([
                "type": "string",
                "description": "Absolute path to the .ipa file to install. Supports @filename references from uploaded files. Either ipaPath or ipaURL is required."
            ] as Any),
            "ipaURL": AnyCodable([
                "type": "string",
                "description": "HTTP or HTTPS URL to download the .ipa file from. The server will download and install it. Either ipaPath or ipaURL is required."
            ] as Any),
            "injectPlayTools": AnyCodable([
                "type": "boolean",
                "description": "Whether to inject PlayTools into the app (default: true)"
            ] as Any),
            "applicationCategory": AnyCodable([
                "type": "string",
                "description": "LSApplicationCategoryType value (e.g., 'public.app-category.games')"
            ] as Any)
        ],
        required: []  // 不再 required ipaPath，改为运行时互斥校验
    ),
    description: "Install an IPA file into PlayCover. Accepts either a local file path (ipaPath) or a remote URL (ipaURL). This is a long-running operation; use the returned task ID with the get_task tool to track progress.",
    title: "Install IPA"
)
```

### 九、对 CLI 的影响

CLI（stdio transport）同样支持 `ipaURL` 参数，因为下载逻辑在 service 层，不依赖 HTTP transport。

这是方案 D 与方案 C 的关键区别：
- 方案 C（`/upload`）只在 HTTP transport 有效
- 方案 D（`ipaURL`）在 HTTP 和 CLI 都有效

### 十、方案 D 对方案 C 的依赖

方案 D **不强依赖**方案 C，可以独立实施。

但如果方案 C 已经实施，方案 D 可以复用：
- 暂存目录基础设施
- 文件清理逻辑
- `@filename` 引用的 `ipaPath` 解析（虽然方案 D 主要通过 `ipaURL` 工作，但 `ipaPath` 同时获得了 `@` 引用能力）

### 十一、改动范围汇总

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `PlayCoverMCP/HostServices/Install/IPADownloader.swift` | 新增 | URL 下载器 |
| `PlayCoverMCP/Tools/InstallerTools.swift` | 修改 | `ipaURL` 参数、互斥校验、下载+安装流程 |
| `PlayCover/Services/MCPManager.swift` | 修改 | 创建 / 传递 IPADownloader |
| `PlayCoverMCP/main.swift` | 修改 | CLI 入口也要传递 IPADownloader |
| `PlayCoverMCPTests/InstallerToolsTests.swift` | 修改 | 新增 URL 参数相关测试 |
| `PlayCoverMCPTests/IPADownloaderTests.swift` | 新增 | 下载器单元测试 |

### 十二、测试要点

| 层级 | 测试 |
|---|---|
| 单元测试 | URL 校验（合法 / 非法 scheme / 空 URL） |
| 单元测试 | 参数互斥逻辑（都不提供 / 都提供 / 只提供一个） |
| 单元测试 | 下载进度映射 |
| 单元测试 | 下载超时 / 大小限制 |
| 单元测试 | 下载后临时文件清理 |
| 集成测试 | 从本地 HTTP server 下载并安装 |
| 冒烟测试 | curl 调用 `install_ipa(ipaURL=...)` |

### 十三、curl 冒烟示例

```bash
SESSION_ID="<从 initialize 响应获取>"

# 通过 URL 安装
curl -X POST http://127.0.0.1:19820/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "install_ipa",
      "arguments": {
        "ipaURL": "https://example.com/path/to/game.ipa"
      }
    }
  }'

# 查看任务进度
curl -X POST http://127.0.0.1:19820/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "get_task",
      "arguments": {
        "taskId": "<从上一步返回获取>"
      }
    }
  }'
```

### 十四、未来扩展

当方案 C 和 D 都实施完毕后，Agent 有三种方式给 PlayCover 传 IPA：

| 方式 | 适用场景 |
|---|---|
| `ipaPath` (本地路径) | 文件已在本机 |
| `ipaPath` (`@filename` 引用) | 先通过 `/upload` 上传，再引用 |
| `ipaURL` (远端 URL) | 文件在 HTTP 可达的位置 |

覆盖了所有常见的跨机器自动化场景。
