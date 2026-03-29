#!/bin/bash
# =============================================================================
# 分步测试 — 第一步: 仅构建 (build-for-testing)
# =============================================================================
#
# 用法:
#   ./BuildScripts/build_for_testing.sh
#
# 说明:
#   - 仅构建测试 target，不运行测试
#   - 构建完成后使用 test_without_building.sh 运行测试
#   - 分步模式适合需要反复运行测试但不想每次重新编译的场景
#   - 推荐工作流: build_for_testing.sh → test_without_building.sh (可多次)
#
# 对应文档: LocalDocs/MCP/08-经验教训与常见陷阱.md (§4.3)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"

echo "=== 构建 MCP 测试 Target (build-for-testing) ==="
echo "    产物目录: $BUILD_DIR"
echo ""

xcodebuild build-for-testing \
  -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1

echo ""
echo "✅ 测试 Target 构建完成，可运行 ./BuildScripts/test_without_building.sh"
