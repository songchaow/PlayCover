#!/bin/bash
# =============================================================================
# Metal Capture 环境探针 (转发)
# =============================================================================
#
# 用法:
#   ./BuildScripts/probe_metal_capture_env.sh
#
# 说明:
#   转发到 Scripts/probe_metal_capture_env.sh，统一从 BuildScripts 暴露入口。
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$REPO_ROOT/Scripts/probe_metal_capture_env.sh"
