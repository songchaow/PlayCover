#!/bin/bash
# =============================================================================
# 运行 MCP 全量单元测试 (构建 + 运行)
# =============================================================================
#
# 用法:
#   ./BuildScripts/test_mcp.sh                                         # 全量测试
#   ./BuildScripts/test_mcp.sh SigningServiceTests                     # 仅运行指定测试类
#   ./BuildScripts/test_mcp.sh BridgeProtocolTests SessionRegistryTests # 运行多个测试类
#
# 说明:
#   - 一步式：先构建再立即运行测试
#   - 如需分步执行（构建和测试分离），请使用 build_for_testing.sh + test_without_building.sh
#   - destination 使用 macOS,arch=arm64（Apple Silicon）
#
# 对应文档: LocalDocs/MCP/08-经验教训与常见陷阱.md, LocalDocs/MCPWithGUITask/00-主文档.md
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"

# 构建 -only-testing 参数
ONLY_TESTING_ARGS=""
if [ $# -gt 0 ]; then
    for TEST_CLASS in "$@"; do
        ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:PlayCoverMCPTests/$TEST_CLASS"
    done
    echo "=== 运行 MCP 指定测试: $* ==="
else
    echo "=== 运行 MCP 全量测试 ==="
fi
echo "    产物目录: $BUILD_DIR"
echo ""

xcodebuild test \
  -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1 \
  $ONLY_TESTING_ARGS

echo ""
echo "✅ MCP 测试完成"
