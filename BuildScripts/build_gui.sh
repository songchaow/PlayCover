#!/bin/bash
# =============================================================================
# 构建 PlayCover GUI (PlayCover scheme)
# =============================================================================
#
# 用法:
#   ./BuildScripts/build_gui.sh                  # Release 构建
#   ./BuildScripts/build_gui.sh Debug            # Debug 构建
#
# 参数说明:
#   CODE_SIGN_IDENTITY="-"         ad-hoc 签名，无需开发者证书
#   CODE_SIGNING_REQUIRED=NO       跳过严格签名检查
#   CODE_SIGNING_ALLOWED=YES       允许 ad-hoc 签名
#   FASTLANE=1                     跳过 Carthage Bootstrap 和 SwiftLint build phase
#
# 对应文档: LocalDocs/MCPWithGUITask/00-主文档.md, LocalDocs/RenderCapture/00-主文档.md
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-Release}"
BUILD_DIR="$REPO_ROOT/build"

echo "=== 构建 PlayCover GUI (${CONFIGURATION}) ==="
echo "    产物目录: $BUILD_DIR"
echo ""

xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCover \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1

echo ""
echo "✅ PlayCover GUI 构建完成 (${CONFIGURATION})"
