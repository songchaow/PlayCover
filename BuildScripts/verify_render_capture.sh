#!/bin/bash
# =============================================================================
# RenderCapture 统一验证脚本 (转发)
# =============================================================================
#
# 用法:
#   ./BuildScripts/verify_render_capture.sh
#
# 说明:
#   转发到 Scripts/verify_render_capture.sh，该脚本包含 22 项检查 (C01-C22)，
#   覆盖 R01-R06 所有 task 的验证项。
#
# 对应文档: LocalDocs/RenderCapture/00-主文档.md (§统一测试策略)
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$REPO_ROOT/Scripts/verify_render_capture.sh"
