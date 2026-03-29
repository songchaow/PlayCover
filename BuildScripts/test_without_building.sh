#!/bin/bash
# =============================================================================
# 分步测试 — 第二步: 不重新构建，直接运行测试 (test-without-building)
# =============================================================================
#
# 用法:
#   ./BuildScripts/test_without_building.sh                                         # 全量
#   ./BuildScripts/test_without_building.sh KeymapServiceTests                      # 指定类
#   ./BuildScripts/test_without_building.sh BridgeProtocolTests SessionRegistryTests # 多个类
#
# 前置条件:
#   必须先运行 ./BuildScripts/build_for_testing.sh 构建测试 target
#
# 说明:
#   - 跳过编译，直接使用上次 build-for-testing 的产物
#   - 适合快速反复运行测试（修改测试代码后需重新 build_for_testing）
#
# 对应文档: LocalDocs/MCP/08-经验教训与常见陷阱.md (§4.3)
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
    echo "=== 运行 MCP 指定测试 (无需重编译): $* ==="
else
    echo "=== 运行 MCP 全量测试 (无需重编译) ==="
fi
echo "    产物目录: $BUILD_DIR"
echo ""

xcodebuild test-without-building \
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
