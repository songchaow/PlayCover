#!/bin/bash
# =============================================================================
# 验证 pbxproj 格式 (plutil -lint)
# =============================================================================
#
# 用法:
#   ./BuildScripts/lint_pbxproj.sh
#
# 说明:
#   验证 PlayCover.xcodeproj/project.pbxproj 格式是否合法。
#   任何修改 pbxproj 的操作后都应立即运行此脚本。
#   如果验证失败，应立即 git checkout 恢复。
#
# 对应文档:
#   - LocalDocs/MCP/08-经验教训与常见陷阱.md (§1.1)
#   - LocalDocs/MCPWithGUITask/00-主文档.md (§6.2)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$REPO_ROOT/PlayCover.xcodeproj/project.pbxproj"

echo "=== 验证 pbxproj 格式 ==="

if plutil -lint "$PBX"; then
    echo "✅ pbxproj 格式正确"
else
    echo ""
    echo "❌ pbxproj 格式错误！"
    echo ""
    echo "建议操作:"
    echo "  git checkout -- PlayCover.xcodeproj/project.pbxproj"
    exit 1
fi
