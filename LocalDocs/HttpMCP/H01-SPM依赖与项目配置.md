# H01：SPM 依赖引入与项目配置

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | 无 |
| **预估工时** | 1-1.5 天 |
| **风险等级** | 中 |

## 目标

1. 通过 Swift Package Manager 引入 Hummingbird HTTP 服务器框架
2. 确保 SPM 与现有 Carthage 依赖共存
3. 确保三个 Target（PlayCover / PlayCoverMCP / PlayCoverMCPTests）的编译均不受影响
4. 验证 Hummingbird 在 GUI 进程内可以正常启动和停止 HTTP 服务器

## 背景

### 为什么选择 Hummingbird

- **轻量**：核心依赖仅 ~5 个 SPM 包（Hummingbird + SwiftNIO + swift-log + swift-service-lifecycle + swift-collections），远少于 Vapor
- **原生 Swift Concurrency**：使用 `async/await`，与 SwiftUI 和现代 Swift 生态契合
- **内置流式响应**：`ResponseBody` 支持 `AsyncSequence`，非常适合 SSE
- **SPM 原生**：不需要额外的构建工具

### SPM 与 Carthage 共存

PlayCover 当前使用 Carthage 管理 PlayTools 依赖。Xcode 原生支持同时使用 Carthage 和 SPM：

- Carthage 依赖通过 Build Phase 脚本复制 framework
- SPM 依赖通过 Xcode 的 Package 管理自动解析、构建、链接
- 两者互不干扰

## 实现步骤

### Step 1：添加 SPM 包依赖

在 `PlayCover.xcodeproj` 中通过命令行或 Xcode 添加 Hummingbird 包：

**方法 A（推荐）：修改 project.pbxproj**

通过脚本向 `project.pbxproj` 添加 SPM 包引用。需要在以下 section 中操作：

1. **XCRemoteSwiftPackageReference**：添加包远程引用
2. **XCSwiftPackageProductDependency**：添加产品依赖
3. **PBXFrameworksBuildPhase**：链接到 PlayCover target

Hummingbird 包信息：
- URL: `https://github.com/hummingbird-project/hummingbird.git`
- 版本要求: `from: "2.0.0"` (最新稳定大版本)
- 需要的产品: `Hummingbird`

**方法 B：通过 `xcodebuild` 命令**

```bash
# 如果方法 A 过于复杂，可以用 swift-package-manager CLI 配合 Xcode 项目
# 但更推荐方法 A（直接编辑 pbxproj）
```

### Step 2：配置 Target 链接

**仅将 Hummingbird 链接到 PlayCover GUI target**：

| Target | 链接 Hummingbird? | 原因 |
|--------|:-:|------|
| PlayCover (GUI) | ✅ | StreamableHTTPTransport 需要 |
| PlayCoverMCP (CLI) | ❌ | CLI 继续使用 StdioTransport |
| PlayCoverMCPTests | ❌ 或 ⚠️ 按需 | 如果 HTTP Transport 测试需要，可链接 |

> **注意**：如果 `StreamableHTTPTransport.swift` 只添加到 PlayCover GUI target（不加入 CLI 和 Tests），那么只需链接到 GUI target。
> 但如果 SSEEncoder 和 MCPSessionManager 需要在 Tests target 中测试（推荐），则 Tests target 可能也需要链接 Hummingbird（或者这些组件设计为不依赖 Hummingbird）。
>
> **推荐设计**：`SSEEncoder` 和 `MCPSessionManager` 不直接依赖 Hummingbird，仅使用 Foundation。这样它们可以在所有三个 target 中编译和测试，只有 `StreamableHTTPTransport` 依赖 Hummingbird。

### Step 3：创建验证文件

创建一个最小的测试文件，验证 Hummingbird 可以在 GUI 进程内编译和运行：

```swift
// PlayCoverMCP/Transport/HummingbirdProbe.swift (临时文件，验证后删除)
// 仅用于验证 SPM 依赖是否正确链接

#if canImport(Hummingbird)
import Hummingbird

/// 最小可行验证：Hummingbird HTTP 服务器可以创建和启动
enum HummingbirdProbe {
    static func verify() async throws {
        let router = Router()
        router.get("/health") { _, _ in
            return "ok"
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        // 不实际启动，只验证创建没问题
        _ = app
    }
}
#endif
```

### Step 4：编译验证

```bash
# Step 4a: 验证 pbxproj 语法
plutil -lint PlayCover.xcodeproj/project.pbxproj

# Step 4b: 清除 DerivedData（SPM 包首次解析需要从头开始）
rm -rf /tmp/PlayCover-DerivedData

# Step 4c: 解析 SPM 依赖
xcodebuild -resolvePackageDependencies -scheme PlayCover \
  -derivedDataPath /tmp/PlayCover-DerivedData 2>&1 | tail -20

# Step 4d: 编译 GUI target
xcodebuild -scheme PlayCover -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1 | tail -20

# Step 4e: 编译 CLI target（不应受影响）
xcodebuild -scheme PlayCoverMCP -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1 | tail -20

# Step 4f: 运行 MCP 全量测试（回归验证）
xcodebuild test -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1 | tail -30
```

### Step 5：清理临时验证文件

验证成功后删除 `HummingbirdProbe.swift`。

## 实施细节：修改 pbxproj 添加 SPM 包

### pbxproj 中 SPM 依赖的结构

SPM 包在 pbxproj 中涉及 3 个 section：

#### 1. XCRemoteSwiftPackageReference（项目级）

在 `/* Begin XCRemoteSwiftPackageReference section */` 中添加：

```
<ID> /* XCRemoteSwiftPackageReference "hummingbird" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/hummingbird-project/hummingbird.git";
    requirement = {
        kind = upToNextMajorVersion;
        minimumVersion = "2.0.0";
    };
};
```

#### 2. XCSwiftPackageProductDependency（target 级）

在 `/* Begin XCSwiftPackageProductDependency section */` 中添加：

```
<DEP_ID> /* Hummingbird */ = {
    isa = XCSwiftPackageProductDependency;
    package = <上面的包引用 ID>;
    productName = Hummingbird;
};
```

#### 3. PBXFrameworksBuildPhase（PlayCover GUI target）

在 PlayCover target 的 Frameworks build phase 中添加：

```
<BUILD_FILE_ID> /* Hummingbird in Frameworks */ = {
    isa = PBXBuildFile;
    productRef = <DEP_ID>;
};
```

#### 4. PBXProject packageReferences

在 project 对象的 `packageReferences` 数组中添加包引用 ID。

### 注意事项

1. **ID 生成**：所有 pbxproj ID 必须是唯一的 24 位十六进制字符串。可以使用 `uuidgen | tr -d '-' | head -c 24` 生成
2. **如果 pbxproj 中没有 XCRemoteSwiftPackageReference section**：这是首次添加 SPM，需要创建整个 section
3. **如果 pbxproj 中没有 packageReferences 字段**：需要在 PBXProject 对象中添加

> **推荐策略**：如果直接编辑 pbxproj 过于复杂（首次添加 SPM 包涉及创建多个新 section），可以考虑使用 Python 脚本自动化，或者创建一个临时的 Package.swift 来管理新依赖，然后通过 Xcode 界面操作。
>
> **最简方案**：如果 agent 有办法用 Xcode 命令行工具添加 SPM 包，优先使用。否则手动编辑 pbxproj。

## 替代方案：如果 Hummingbird 集成遇到困难

如果 Hummingbird 的 SPM 集成在 Xcode 项目配置中遇到难以解决的问题，可以退而使用以下替代方案：

### 替代方案 A：使用 Apple 的 Network.framework + 手写轻量 HTTP 解析

基于现有的 `NWListener` 基础设施（TCPTransport 已验证可用），在其上层实现 HTTP 请求解析和 SSE 响应格式化。

**优点**：零新依赖，pbxproj 改动最小
**缺点**：需要手写 HTTP 请求解析器和 SSE 编码

### 替代方案 B：使用 swift-nio-extras 的 HTTPServerHandler

直接使用 `swift-nio` + `swift-nio-http1`（比 Hummingbird 更底层但依赖更少）。

## 验收标准

- [ ] Hummingbird SPM 包成功添加到 Xcode 项目
- [ ] `xcodebuild -resolvePackageDependencies` 成功
- [ ] PlayCover GUI scheme 编译通过（包含 Hummingbird）
- [ ] PlayCoverMCP CLI scheme 编译通过（不包含 Hummingbird，不受影响）
- [ ] MCP 全量测试通过（回归无破坏）
- [ ] `plutil -lint project.pbxproj` → OK
- [ ] `git diff` 确认只改了预期内容

## 测试计划

1. **SPM 解析测试**：`xcodebuild -resolvePackageDependencies` 成功
2. **编译测试**：PlayCover 和 PlayCoverMCP 两个 scheme 都编译通过
3. **回归测试**：MCP 全量测试（579+ tests）通过
4. **pbxproj 语法**：`plutil -lint` OK

## 风险

| 风险 | 缓解措施 |
|------|---------|
| SPM 依赖解析慢（SwiftNIO 子包多） | 使用 `-derivedDataPath` 缓存；CI 可预拉取 |
| pbxproj 首次添加 SPM section 格式复杂 | 参考其他 SPM + Xcode 项目的 pbxproj；修改后立即 `plutil -lint` |
| Hummingbird 版本不兼容当前 Swift 版本 | 检查 PlayCover 的 Swift 版本（应为 5.9+），Hummingbird 2.x 需要 Swift 5.9+ |
| SPM 与 Carthage 的 PlayTools 冲突 | 理论上不冲突（不同包管理器，不同依赖），但编译时需验证 |
