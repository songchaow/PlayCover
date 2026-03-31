#!/bin/bash
# =============================================================================
# Metal Capture 环境探针
# =============================================================================
#
# 用法:
#   ./Scripts/probe_metal_capture_env.sh
#
# 目的:
#   在普通 Swift 进程中直接探测 `MTLCaptureManager` 对
#   `.gpuTraceDocument` / `.developerTools` 的支持情况，辅助判断
#   Render Capture 阻塞点是 PlayCover session 链路问题，还是当前机器 /
#   Xcode / Apple Metal 运行时级限制。
# =============================================================================

set -euo pipefail

run_probe() {
    local label="$1"
    shift

    local tmp
    tmp=$(mktemp /tmp/mtlprobe.XXXX.swift)

    cat >"$tmp" <<'EOF'
import Metal

let manager = MTLCaptureManager.shared()
let defaultDeviceName = MTLCreateSystemDefaultDevice()?.name ?? "nil"

print("supports_gpu_trace=\(manager.supportsDestination(.gpuTraceDocument))")
print("supports_developer_tools=\(manager.supportsDestination(.developerTools))")
print("default_device=\(defaultDeviceName)")
EOF

    echo "--- $label ---"
    "$@" xcrun swift "$tmp"
    rm -f "$tmp"
    echo ""
}

echo "========================================="
echo " Metal Capture Environment Probe"
echo "========================================="
echo ""

echo "--- toolchain ---"
xcode-select -p || true
echo ""
xcodebuild -version || true
echo ""
xcrun xctrace version || true
echo ""
pkgutil --pkg-info=com.apple.pkg.CLTools_Executables || true
echo ""

run_probe "plain_process" env
run_probe "METAL_DEVICE_WRAPPER_TYPE=1" env METAL_DEVICE_WRAPPER_TYPE=1

echo "--- interpretation ---"
echo "If a plain Swift process can see a default Metal device but both support flags are still false,"
echo "the blocker is likely machine / toolchain / Apple Metal runtime policy, not PlayCover MCP session plumbing."
