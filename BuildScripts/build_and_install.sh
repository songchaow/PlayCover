#!/bin/bash
# =============================================================================
# 构建 PlayCover GUI，并优先安装到 /Applications，失败时回退到 ~/Applications
# =============================================================================
#
# 用法:
#   ./BuildScripts/build_and_install.sh              # Release 构建 + 自动选择安装目录
#   ./BuildScripts/build_and_install.sh Debug        # Debug 构建 + 自动选择安装目录
#
# 可选环境变量:
#   PLAYCOVER_INSTALL_MODE=auto|system|user          # 默认 auto
#
# 说明:
#   1. 构建 PlayCover.app (PlayCover scheme)
#   2. auto 模式下优先安装到 /Applications；若当前会话无写权限且无免密 sudo，则回退到 ~/Applications
#   3. 对安装后的 .app 做 ad-hoc 重签名（解决内嵌 framework Team ID 不匹配）
#
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-Release}"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="PlayCover.app"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
SYSTEM_INSTALL_DIR="/Applications"
USER_INSTALL_DIR="$HOME/Applications"
INSTALL_MODE="${PLAYCOVER_INSTALL_MODE:-auto}"
INSTALL_DIR=""
INSTALL_PATH=""
USE_SUDO=0

select_install_target() {
    case "$INSTALL_MODE" in
    auto)
        if [[ -w "$SYSTEM_INSTALL_DIR" ]]; then
            INSTALL_DIR="$SYSTEM_INSTALL_DIR"
            USE_SUDO=0
        elif sudo -n true >/dev/null 2>&1; then
            INSTALL_DIR="$SYSTEM_INSTALL_DIR"
            USE_SUDO=1
        else
            INSTALL_DIR="$USER_INSTALL_DIR"
            USE_SUDO=0
            echo "⚠️  无法无提示写入 /Applications，回退到 $USER_INSTALL_DIR"
        fi
        ;;
    system)
        INSTALL_DIR="$SYSTEM_INSTALL_DIR"
        if [[ -w "$SYSTEM_INSTALL_DIR" ]]; then
            USE_SUDO=0
        else
            USE_SUDO=1
        fi
        ;;
    user)
        INSTALL_DIR="$USER_INSTALL_DIR"
        USE_SUDO=0
        ;;
    *)
        echo "❌ 无效的 PLAYCOVER_INSTALL_MODE: $INSTALL_MODE"
        echo "   支持值: auto | system | user"
        exit 1
        ;;
    esac

    INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
}

run_install_cmd() {
    if [[ "$USE_SUDO" -eq 1 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

select_install_target

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

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 构建产物未找到: $APP_PATH"
    echo ""
    echo "尝试查找 .app 位置:"
    find "$BUILD_DIR" -name "PlayCover.app" -type d 2>/dev/null || true
    exit 1
fi

# --- Step 2: 安装到 Applications ---
echo "=== [2/3] 安装到 $INSTALL_DIR ==="
echo ""

if pgrep -x "PlayCover" > /dev/null 2>&1; then
    echo "  ⚠️  PlayCover 正在运行，正在关闭..."
    osascript -e 'quit app "PlayCover"' 2>/dev/null || true
    sleep 1
    if pgrep -x "PlayCover" > /dev/null 2>&1; then
        killall "PlayCover" 2>/dev/null || true
        sleep 1
    fi
    echo "  ✅ 已关闭 PlayCover"
fi

run_install_cmd mkdir -p "$INSTALL_DIR"

if [ -d "$INSTALL_PATH" ]; then
    echo "  🗑️  删除旧版本: $INSTALL_PATH"
    run_install_cmd rm -rf "$INSTALL_PATH"
fi

echo "  📦 安装新版本: $APP_PATH → $INSTALL_PATH"
run_install_cmd cp -R "$APP_PATH" "$INSTALL_PATH"

echo ""
echo "✅ 安装完成"
echo ""

# --- Step 3: ad-hoc 重签名 ---
echo "=== [3/3] ad-hoc 重签名 ==="
echo ""

echo "  🔏 签名内嵌 Frameworks..."
if [ -d "$INSTALL_PATH/Contents/Frameworks" ]; then
    find "$INSTALL_PATH/Contents/Frameworks" -type d -name "*.framework" | while read -r fw; do
        echo "     → $(basename "$fw")"
        run_install_cmd codesign --force --sign - "$fw" 2>&1 || true
    done
    find "$INSTALL_PATH/Contents/Frameworks" -type f -name "*.dylib" | while read -r lib; do
        echo "     → $(basename "$lib")"
        run_install_cmd codesign --force --sign - "$lib" 2>&1 || true
    done
fi

echo "  🔏 签名主程序..."
run_install_cmd codesign --force --deep --sign - "$INSTALL_PATH"

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
