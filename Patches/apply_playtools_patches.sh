#!/bin/bash
# apply_playtools_patches.sh
# 在 Carthage bootstrap/update 之后执行，将所有 PlayTools patch 应用到 checkout 目录。
# 用法: ./Patches/apply_playtools_patches.sh
# 从仓库根目录运行。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/Patches"
PLAYTOOLS_DIR="$REPO_ROOT/Carthage/Checkouts/PlayTools"

if [ ! -d "$PLAYTOOLS_DIR" ]; then
    echo "[apply_patches] PlayTools checkout not found at $PLAYTOOLS_DIR, skipping."
    exit 0
fi

APPLIED=0
FAILED=0

for patch_file in "$PATCHES_DIR"/playtools-*.patch; do
    [ -f "$patch_file" ] || continue

    patch_name="$(basename "$patch_file")"

    # --forward: skip already-applied patches (exit 0 if already applied)
    # -p1: strip leading a/ or b/ from paths
    if patch -d "$REPO_ROOT" -p1 --forward --dry-run < "$patch_file" > /dev/null 2>&1; then
        patch -d "$REPO_ROOT" -p1 --forward < "$patch_file"
        echo "[apply_patches] ✅ Applied: $patch_name"
        APPLIED=$((APPLIED + 1))
    else
        # Check if already applied (reverse test)
        if patch -d "$REPO_ROOT" -p1 --reverse --dry-run < "$patch_file" > /dev/null 2>&1; then
            echo "[apply_patches] ⏭ Already applied: $patch_name"
        else
            echo "[apply_patches] ❌ FAILED to apply: $patch_name"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo "[apply_patches] Done. Applied: $APPLIED, Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
