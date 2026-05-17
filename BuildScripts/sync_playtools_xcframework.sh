#!/bin/bash
# =============================================================================
# 同步 PlayTools 预构建 xcframework slice
# =============================================================================
#
# 用途:
#   当 PlayTools 源码有变更时，重建 iOS PlayTools.framework，
#   并回写到 Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework。
#
# 说明:
#   - PlayTools 源码位于 Carthage/Checkouts/PlayTools/，作为主仓库的一部分
#     直接被 git 跟踪（不依赖 Carthage 包管理器）。
#   - PlayCover GUI 打包时实际复制的是 Carthage/Build 下的预构建产物，
#     而不是直接编译源码目录。
#   - 如果只改源码、不刷新该 xcframework slice，真实 app 仍会加载旧 runtime。
#
# 用法:
#   ./BuildScripts/sync_playtools_xcframework.sh              # 默认 Release
#   ./BuildScripts/sync_playtools_xcframework.sh Debug        # Debug
#
# 可选环境变量:
#   FORCE_PLAYTOOLS_REBUILD=1    强制重建，即使预构建产物看起来是最新的
#
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-Release}"
DERIVED_DATA_PATH="$REPO_ROOT/build/playtools-deriveddata"
PLAYTOOLS_SOURCE_ROOT="$REPO_ROOT/Carthage/Checkouts/PlayTools"
PLAYTOOLS_PROJECT="$PLAYTOOLS_SOURCE_ROOT/PlayTools.xcodeproj"
OUTPUT_SLICE_DIR="$REPO_ROOT/Carthage/Build/PlayTools.xcframework/ios-arm64"
OUTPUT_FRAMEWORK="$OUTPUT_SLICE_DIR/PlayTools.framework"
OUTPUT_BINARY="$OUTPUT_FRAMEWORK/PlayTools"
OUTPUT_DSYM_DIR="$OUTPUT_SLICE_DIR/dSYMs"
BUILT_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos"
BUILT_FRAMEWORK="$BUILT_PRODUCTS_DIR/PlayTools.framework"
BUILT_DSYM="$BUILT_PRODUCTS_DIR/PlayTools.framework.dSYM"
FORCE_REBUILD="${FORCE_PLAYTOOLS_REBUILD:-0}"

if [[ ! -d "$PLAYTOOLS_SOURCE_ROOT" ]]; then
    echo "❌ 未找到 PlayTools 源码目录: $PLAYTOOLS_SOURCE_ROOT"
    exit 1
fi

if [[ ! -f "$PLAYTOOLS_PROJECT/project.pbxproj" ]]; then
    echo "❌ 未找到 PlayTools 工程文件: $PLAYTOOLS_PROJECT"
    exit 1
fi

should_rebuild() {
    if [[ "$FORCE_REBUILD" == "1" ]]; then
        return 0
    fi

    if [[ ! -f "$OUTPUT_BINARY" ]]; then
        return 0
    fi

    if find "$PLAYTOOLS_SOURCE_ROOT" \
        \( -name .git -o -name build -o -name DerivedData -o -name .build \) -prune -o \
        -type f \
        \( -name '*.swift' -o -name '*.m' -o -name '*.h' -o -name '*.plist' -o -name '*.strings' -o -name '*.pbxproj' -o -name '*.xcscheme' \) \
        -newer "$OUTPUT_BINARY" -print -quit | grep -q .; then
        return 0
    fi

    return 1
}

if ! should_rebuild; then
    echo "=== PlayTools xcframework 已是最新，跳过重建 (${CONFIGURATION}) ==="
    echo "    输出: $OUTPUT_FRAMEWORK"
    echo ""
    exit 0
fi

echo "=== 同步 PlayTools xcframework (${CONFIGURATION}) ==="
echo "    源码目录: $PLAYTOOLS_SOURCE_ROOT"
echo "    输出目录: $OUTPUT_SLICE_DIR"
echo ""

echo "--- [1/2] 重建 PlayTools.framework ---"
xcodebuild -project "$PLAYTOOLS_PROJECT" \
  -scheme PlayTools \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  FASTLANE=1

echo ""

echo "--- [2/2] 回写预构建产物 ---"
if [[ ! -d "$BUILT_FRAMEWORK" ]]; then
    echo "❌ 未找到重建后的 PlayTools.framework: $BUILT_FRAMEWORK"
    exit 1
fi

mkdir -p "$OUTPUT_SLICE_DIR"
rm -rf "$OUTPUT_FRAMEWORK"
cp -R "$BUILT_FRAMEWORK" "$OUTPUT_FRAMEWORK"

if [[ -d "$BUILT_DSYM" ]]; then
    mkdir -p "$OUTPUT_DSYM_DIR"
    rm -rf "$OUTPUT_DSYM_DIR/PlayTools.framework.dSYM"
    cp -R "$BUILT_DSYM" "$OUTPUT_DSYM_DIR/PlayTools.framework.dSYM"
fi

echo ""
echo "✅ PlayTools xcframework 已同步"
echo "    Framework: $OUTPUT_FRAMEWORK"
if [[ -d "$OUTPUT_DSYM_DIR/PlayTools.framework.dSYM" ]]; then
    echo "    dSYM: $OUTPUT_DSYM_DIR/PlayTools.framework.dSYM"
fi
echo ""
