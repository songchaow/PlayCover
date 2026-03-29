# BuildScripts

PlayCover 项目的标准化构建与测试脚本，封装了 ad-hoc 签名参数和环境配置。

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `build_gui.sh` | 构建 PlayCover GUI app (PlayCover scheme) |
| `build_mcp.sh` | 构建 PlayCoverMCP CLI (PlayCoverMCP scheme) |
| `test_mcp.sh` | 运行 MCP 单元测试 (构建+运行，支持指定测试类) |
| `build_for_testing.sh` | 分步: 仅构建测试 target |
| `test_without_building.sh` | 分步: 不重编译直接运行测试 (支持指定测试类) |
| `build_and_install.sh` | 构建 GUI + 安装到 /Applications（需 sudo） |
| `build_all.sh` | 全量: 构建 GUI + CLI + 跑全量测试 |
| `verify_render_capture.sh` | RenderCapture 22 项验证 (C01-C22) |
| `lint_pbxproj.sh` | 验证 pbxproj 格式 (plutil -lint) |

## 常用工作流

### 日常开发

    ./BuildScripts/build_mcp.sh          # MCP CLI
    ./BuildScripts/build_gui.sh          # GUI app

### 测试 (一步式)

    ./BuildScripts/test_mcp.sh                              # 全量
    ./BuildScripts/test_mcp.sh SigningServiceTests           # 指定类

### 测试 (分步式，推荐反复调试)

    ./BuildScripts/build_for_testing.sh                      # 构建一次
    ./BuildScripts/test_without_building.sh                  # 运行多次
    ./BuildScripts/test_without_building.sh KeymapServiceTests

### 构建并安装到 /Applications

    ./BuildScripts/build_and_install.sh              # Release 构建 + 安装
    ./BuildScripts/build_and_install.sh Debug        # Debug 构建 + 安装

### PR 合入前完整回归

    ./BuildScripts/build_all.sh

### 修改 pbxproj 后验证

    ./BuildScripts/lint_pbxproj.sh

## 构建产物目录

所有构建产物统一输出到项目根目录的 `build/` 文件夹（已在 `.gitignore` 中），不会污染全局 `~/Library/Developer/Xcode/DerivedData/`。

    build/
    ├── Build/Products/Release/    # 编译产物（.app, CLI 二进制）
    ├── Build/Intermediates.noindex/
    └── Logs/

清理构建缓存：`rm -rf build/`

## 通用构建参数

| 参数 | 作用 |
|------|------|
| `-derivedDataPath build/` | 构建产物输出到项目本地 `build/` 目录 |
| `CODE_SIGN_IDENTITY="-"` | ad-hoc 签名，无需开发者证书 |
| `CODE_SIGNING_REQUIRED=NO` | 跳过签名强制要求 |
| `CODE_SIGNING_ALLOWED=YES` | 允许 ad-hoc 签名 |
| `FASTLANE=1` | 跳过 Carthage Bootstrap 和 SwiftLint |
| `-destination 'platform=macOS,arch=arm64'` | macOS ARM64 测试平台 |

## 对应文档

- LocalDocs/MCP/03-共享前置信息.md
- LocalDocs/MCP/08-经验教训与常见陷阱.md (4.3 节)
- LocalDocs/MCPWithGUITask/00-主文档.md (6.6 节)
- LocalDocs/RenderCapture/00-主文档.md
- LocalDocs/RenderCapture/99-经验教训.md (4.2 节)
