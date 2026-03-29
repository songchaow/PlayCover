#!/bin/bash
# =============================================================================
# 构建 PlayCover GUI 并安装到 /Applications
# =============================================================================
#
# 用法:
#   ./BuildScripts/build_and_install.sh              # Release 构建 + 安装
#   ./BuildScripts/build_and_install.sh Debug        # Debug 构建 + 安装
#
# 说明:
#   1. 构建 PlayCover.app (PlayCover scheme)
#   2. 如果 /Applications/PlayCover.app 已存在，先删除旧版本
#   3. 将新构建的 .app 复制到 /Applications/
#   4. 对整个 .app 做 ad-hoc 重签名（解决内嵌 framework Team ID 不匹配）
#   需要管理员权限（会自动 sudo）
#
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-Release}"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="PlayCover.app"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"

# --- Step 1: 构建 ---
echo "=== [1/3] 构建 PlayCover GUI (${CONFIGURATION}) ==="
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
echo "✅ 构建完成"
echo ""

# --- 验证构建产物 ---
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 构建产物未找到: $APP_PATH"
    echo ""
    echo "尝试查找 .app 位置:"
    find "$BUILD_DIR" -name "PlayCover.app" -type d 2>/dev/null || true
    exit 1
fi

# --- Step 2: 安装到 /Applications ---
echo "=== [2/3] 安装到 $INSTALL_DIR ==="
echo ""

# 如果已存在，先关闭运行中的 PlayCover
if pgrep -x "PlayCover" > /dev/null 2>&1; then
    echo "  ⚠️  PlayCover 正在运行，正在关闭..."
    osascript -e 'quit app "PlayCover"' 2>/dev/null || true
    sleep 1
    # 如果还没退出，强制终止
    if pgrep -x "PlayCover" > /dev/null 2>&1; then
        killall "PlayCover" 2>/dev/null || true
        sleep 1
    fi
    echo "  ✅ 已关闭 PlayCover"
fi

# 删除旧版本 + 复制新版本
if [ -d "$INSTALL_PATH" ]; then
    echo "  🗑️  删除旧版本: $INSTALL_PATH"
    sudo rm -rf "$INSTALL_PATH"
fi

echo "  📦 安装新版本: $APP_PATH → $INSTALL_PATH"
sudo cp -R "$APP_PATH" "$INSTALL_PATH"

echo ""
echo "✅ 安装完成"
echo ""

# --- Step 3: ad-hoc 重签名 ---
# 主程序使用 ad-hoc 签名构建，但内嵌的第三方 framework（如 Sparkle）
# 保留了原始 Team ID 签名，导致 macOS 拒绝加载（Team ID 不匹配）。
# 需要对整个 .app bundle 做递归 ad-hoc 重签名使签名一致。
echo "=== [3/3] ad-hoc 重签名 ==="
echo ""

# 先对内嵌 framework 逐个签名
echo "  🔏 签名内嵌 Frameworks..."
if [ -d "$INSTALL_PATH/Contents/Frameworks" ]; then
    find "$INSTALL_PATH/Contents/Frameworks" -type d -name "*.framework" | while read -r fw; do
        echo "     → $(basename "$fw")"
        sudo codesign --force --sign - "$fw" 2>&1 || true
    done
    # 签名 dylib（如果有）
    find "$INSTALL_PATH/Contents/Frameworks" -type f -name "*.dylib" | while read -r lib; do
        echo "     → $(basename "$lib")"
        sudo codesign --force --sign - "$lib" 2>&1 || true
    done
fi

# 最后签名主程序（必须在 framework 之后）
echo "  🔏 签名主程序..."
sudo codesign --force --deep --sign - "$INSTALL_PATH"

# 验证签名
echo ""
echo "  🔍 验证签名..."
if codesign --verify --deep --strict "$INSTALL_PATH" 2>&1; then
    echo "  ✅ 签名验证通过"
else
    echo "  ⚠️  签名验证有警告（ad-hoc 签名下可能正常）"
fi

echo ""
echo "==========================================="
echo " 🎉 PlayCover 已安装到 $INSTALL_PATH"
echo "==========================================="
echo ""
echo "启动: open $INSTALL_PATH"
