#!/bin/bash
# =============================================================================
# 全量构建 + 测试 (PlayCover GUI + MCP CLI + MCP 单元测试)
# =============================================================================
#
# 用法:
#   ./BuildScripts/build_all.sh              # 默认 Release
#   ./BuildScripts/build_all.sh Debug        # Debug 模式
#
# 说明:
#   依次执行:
#   1. 构建 PlayCover GUI (PlayCover scheme)
#   2. 构建 PlayCoverMCP CLI (PlayCoverMCP scheme)
#   3. 运行 MCP 全量单元测试
#
#   任何一步失败则立即终止。
#   适合 PR 合入前的完整回归验证。
#
# 对应文档: LocalDocs/MCPWithGUITask/00-主文档.md (§5.3 步骤 1)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-Release}"
BUILD_DIR="$REPO_ROOT/build"

echo "==========================================="
echo " PlayCover 全量构建 + 测试 (${CONFIGURATION})"
echo " 产物目录: $BUILD_DIR"
echo "==========================================="
echo ""

"$REPO_ROOT/BuildScripts/sync_playtools_xcframework.sh" "$CONFIGURATION"

# --- Step 1: 构建 PlayCover GUI ---
echo "--- [1/3] 构建 PlayCover GUI ---"
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCover \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1 \
  2>&1 | tail -5
echo "  ✅ PlayCover GUI 构建成功"
echo ""

# --- Step 2: 构建 PlayCoverMCP CLI ---
echo "--- [2/3] 构建 PlayCoverMCP CLI ---"
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1 \
  2>&1 | tail -5
echo "  ✅ PlayCoverMCP CLI 构建成功"
echo ""

# --- Step 3: 运行 MCP 全量测试 ---
echo "--- [3/3] 运行 MCP 全量测试 ---"
xcodebuild test \
  -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1 \
  2>&1 | tail -20
echo "  ✅ MCP 全量测试通过"
echo ""

echo "==========================================="
echo " 🎉 全量构建 + 测试完成"
echo "==========================================="
