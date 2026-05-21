#!/bin/bash
# test_gputrace_replay_bridge.sh — R6.1f 集成测试
#
# 验证编译后的 bridge 各子命令基本功能：
#   1. help 子命令输出正确 JSON
#   2. 无参数时退出码 = 1
#   3. 各子命令无参数时退出码 = 1 (usage)
#   4. (可选) 若提供 GPUTRACE_PATH 环境变量，执行 replay/pipeline/config 最小样本测试
#
# 用法：
#   ./test_gputrace_replay_bridge.sh                    # 仅离线测试
#   GPUTRACE_PATH=/path/to/sample.gputrace ./test_gputrace_replay_bridge.sh  # 含实际 trace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$SCRIPT_DIR/gputrace_replay_bridge"

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  [FAIL] $1"; }

echo "=== gputrace_replay_bridge Integration Tests ==="
echo ""

# --- Pre-check: binary exists ---
if [ ! -x "$BRIDGE" ]; then
    echo "[ERROR] Binary not found or not executable: $BRIDGE"
    echo "        Run 'make' in Scripts/ first."
    exit 1
fi

# --- Test 1: No arguments → exit code 1 ---
echo "[T1] No arguments → exit code 1"
set +e
"$BRIDGE" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then pass "exit code = 1"; else fail "exit code = $rc (expected 1)"; fi

# --- Test 2: help → exit code 0 + valid JSON ---
echo "[T2] help subcommand"
set +e
OUTPUT=$("$BRIDGE" help 2>/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then pass "exit code = 0"; else fail "exit code = $rc (expected 0)"; fi

# Check JSON has expected fields
if echo "$OUTPUT" | grep -q '"tool"'; then pass "JSON has 'tool' field"; else fail "missing 'tool' field"; fi
if echo "$OUTPUT" | grep -q '"commands"'; then pass "JSON has 'commands' array"; else fail "missing 'commands'"; fi
if echo "$OUTPUT" | grep -q '"version"'; then pass "JSON has 'version' field"; else fail "missing 'version'"; fi

# Check all 6 commands listed
for cmd in help replay pipeline shader shader-of-rps config; do
    if echo "$OUTPUT" | grep -q "\"$cmd\""; then
        pass "commands contains '$cmd'"
    else
        fail "commands missing '$cmd'"
    fi
done

# --- Test 3: Unknown command → exit code 1 ---
echo "[T3] Unknown command → exit code 1"
set +e
"$BRIDGE" nonexistent_cmd >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then pass "exit code = 1"; else fail "exit code = $rc (expected 1)"; fi

# --- Test 4: Subcommands without required args → exit code 1 ---
echo "[T4] Subcommands without required args → exit code 1"
for cmd in replay pipeline shader shader-of-rps config; do
    set +e
    "$BRIDGE" "$cmd" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 1 ]; then pass "$cmd no-args → exit 1"; else fail "$cmd no-args → exit $rc (expected 1)"; fi
done

# --- Test 5: replay with invalid path → exit code 2 ---
echo "[T5] replay with invalid path → exit code 2"
set +e
"$BRIDGE" replay /nonexistent/path.gputrace >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then pass "exit code = 2 (bad input)"; else fail "exit code = $rc (expected 2)"; fi

# --- Test 6: codesign verification ---
echo "[T6] codesign verification"
set +e
codesign -v "$BRIDGE" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ]; then pass "codesign valid"; else fail "codesign invalid (rc=$rc)"; fi

# --- Test 7+ (Optional): Live trace tests ---
if [ -n "${GPUTRACE_PATH:-}" ] && [ -d "$GPUTRACE_PATH" ]; then
    echo ""
    echo "[T7] Live trace tests (GPUTRACE_PATH=$GPUTRACE_PATH)"

    # T7a: replay
    echo "  [T7a] replay subcommand"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "replay exit code = 0"; else fail "replay exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"success":true'; then pass "replay success=true"; else fail "replay success!=true"; fi
    if echo "$OUTPUT" | grep -q '"resource_count"'; then pass "replay has resource_count"; else fail "missing resource_count"; fi
    if echo "$OUTPUT" | grep -q '"elapsed_ms"'; then pass "replay has elapsed_ms"; else fail "missing elapsed_ms"; fi

    # T7b: replay --list-resources
    echo "  [T7b] replay --list-resources"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" --list-resources 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "list-resources exit code = 0"; else fail "exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"resources"'; then pass "has resources array"; else fail "missing resources"; fi

    # T7c: pipeline
    echo "  [T7c] pipeline subcommand"
    TMPDIR_PIPE=$(mktemp -d)
    set +e
    OUTPUT=$("$BRIDGE" pipeline "$GPUTRACE_PATH" "$TMPDIR_PIPE" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "pipeline exit code = 0"; else fail "pipeline exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"libraries_count"'; then pass "has libraries_count"; else fail "missing libraries_count"; fi
    METALLIB_COUNT=$(ls "$TMPDIR_PIPE"/*.metallib 2>/dev/null | wc -l | tr -d ' ')
    if [ "$METALLIB_COUNT" -gt 0 ]; then pass "exported $METALLIB_COUNT metallib(s)"; else fail "no metallibs exported"; fi
    rm -rf "$TMPDIR_PIPE"

    # T7d: config (default)
    echo "  [T7d] config subcommand (defaults)"
    set +e
    OUTPUT=$("$BRIDGE" config "$GPUTRACE_PATH" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "config exit code = 0"; else fail "config exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"config"'; then pass "has config object"; else fail "missing config object"; fi
    if echo "$OUTPUT" | grep -q '"success":true'; then pass "config success=true"; else fail "config success!=true"; fi

    # T7e: R7.1 — replay --bounds emits total_call_count
    echo "  [T7e] replay --bounds (R7.1)"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" --bounds 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "bounds exit code = 0"; else fail "bounds exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"bounds_only":true'; then pass "bounds_only flag emitted"; else fail "missing bounds_only"; fi
    if echo "$OUTPUT" | grep -q '"total_call_count"'; then pass "bounds has total_call_count"; else fail "missing total_call_count"; fi

    # T7f: R7.1 — replay always reports total_call_count + last_call_index
    echo "  [T7f] replay total_call_count/last_call_index always present"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" 2>/dev/null)
    set -e
    if echo "$OUTPUT" | grep -q '"total_call_count"'; then pass "default replay has total_call_count"; else fail "missing total_call_count"; fi
    if echo "$OUTPUT" | grep -q '"last_call_index"'; then pass "default replay has last_call_index"; else fail "missing last_call_index"; fi

    # T7g: R7.1 — playTo out-of-range returns structured error, exit 12
    echo "  [T7g] replay --playto out-of-range (R7.1 graceful)"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" --playto 99999999 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 12 ]; then pass "OOR exit code = 12 (EXIT_PLAYTO_OOR)"; else fail "OOR exit = $rc (expected 12)"; fi
    if echo "$OUTPUT" | grep -q '"error":"playto_out_of_range"'; then pass "OOR has error string"; else fail "missing playto_out_of_range error"; fi
    if echo "$OUTPUT" | grep -q '"max":'; then pass "OOR reports max"; else fail "missing max field"; fi

    # T7h: R7.1 — list-resources includes new metadata fields on textures and buffers
    echo "  [T7h] resource enumeration includes R7.1 metadata fields"
    set +e
    OUTPUT=$("$BRIDGE" replay "$GPUTRACE_PATH" --list-resources 2>/dev/null)
    set -e
    if echo "$OUTPUT" | grep -q '"storageMode"'; then pass "resources have storageMode"; else fail "missing storageMode"; fi
    if echo "$OUTPUT" | grep -q '"hazardTrackingMode"'; then pass "resources have hazardTrackingMode"; else fail "missing hazardTrackingMode"; fi
    if echo "$OUTPUT" | grep -q '"usage":\['; then pass "textures have usage array"; else fail "missing texture usage array"; fi
    if echo "$OUTPUT" | grep -q '"framebufferOnly"'; then pass "textures have framebufferOnly"; else fail "missing framebufferOnly"; fi
    if echo "$OUTPUT" | grep -q '"sampleCount"'; then pass "textures have sampleCount"; else fail "missing sampleCount"; fi
    if echo "$OUTPUT" | grep -q '"arrayLength"'; then pass "textures have arrayLength"; else fail "missing arrayLength"; fi

    # T7i: R7.2 — pipeline emits RPS↔shader correlation (function/library keys + attachments)
    echo "  [T7i] pipeline RPS↔shader correlation (R7.2)"
    TMPDIR_R72=$(mktemp -d)
    set +e
    OUTPUT=$("$BRIDGE" pipeline "$GPUTRACE_PATH" "$TMPDIR_R72" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "pipeline R7.2 exit code = 0"; else fail "pipeline R7.2 exit code = $rc"; fi
    if echo "$OUTPUT" | grep -q '"rps_correlated_count"'; then pass "has rps_correlated_count"; else fail "missing rps_correlated_count"; fi
    if echo "$OUTPUT" | grep -q '"rps_captured_count"'; then pass "has rps_captured_count"; else fail "missing rps_captured_count"; fi
    if echo "$OUTPUT" | grep -q '"vertex_function_key"'; then pass "RPS has vertex_function_key"; else fail "missing vertex_function_key"; fi
    if echo "$OUTPUT" | grep -q '"fragment_function_key"'; then pass "RPS has fragment_function_key"; else fail "missing fragment_function_key"; fi
    if echo "$OUTPUT" | grep -q '"vertex_library_key"'; then pass "RPS has vertex_library_key"; else fail "missing vertex_library_key"; fi
    if echo "$OUTPUT" | grep -q '"fragment_library_key"'; then pass "RPS has fragment_library_key"; else fail "missing fragment_library_key"; fi
    if echo "$OUTPUT" | grep -q '"color_attachment_count"'; then pass "RPS has color_attachment_count"; else fail "missing color_attachment_count"; fi
    if echo "$OUTPUT" | grep -q '"depth_format"'; then pass "RPS has depth_format"; else fail "missing depth_format"; fi
    if echo "$OUTPUT" | grep -q '"stencil_format"'; then pass "RPS has stencil_format"; else fail "missing stencil_format"; fi
    rm -rf "$TMPDIR_R72"

    # T7j: R7.4 — shader-of-rps reverse lookup
    echo "  [T7j] shader-of-rps reverse lookup (R7.4)"
    # Pick the first RPS key from the live trace dynamically.
    PIPELINE_TMP=$(mktemp -d)
    PIPELINE_JSON=$("$BRIDGE" pipeline "$GPUTRACE_PATH" "$PIPELINE_TMP" 2>/dev/null)
    rm -rf "$PIPELINE_TMP"
    FIRST_RPS_KEY=$(echo "$PIPELINE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); rs=d.get('render_pipeline_states',[]); print(rs[0]['key']) if rs else exit(1)" 2>/dev/null || echo "")
    if [ -n "$FIRST_RPS_KEY" ]; then
        TMPDIR_R74=$(mktemp -d)
        set +e
        OUTPUT=$("$BRIDGE" shader-of-rps "$GPUTRACE_PATH" "$FIRST_RPS_KEY" --output-dir "$TMPDIR_R74" 2>/dev/null)
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "shader-of-rps exit code = 0"; else fail "shader-of-rps exit code = $rc"; fi
        if echo "$OUTPUT" | grep -q "\"rps_key\":$FIRST_RPS_KEY"; then pass "echoes rps_key"; else fail "missing rps_key echo"; fi
        if echo "$OUTPUT" | grep -q '"function_key"'; then pass "has function_key"; else fail "missing function_key"; fi
        if echo "$OUTPUT" | grep -q '"library_key"'; then pass "has library_key"; else fail "missing library_key"; fi
        if echo "$OUTPUT" | grep -q '"library_metallib_path"'; then pass "exported metallib"; else fail "missing metallib export"; fi
        if echo "$OUTPUT" | grep -q '"cache_key_metallib"'; then pass "computed PlayTools cacheKey"; else fail "missing cache_key_metallib"; fi
        rm -rf "$TMPDIR_R74"
    else
        fail "could not derive a sample RPS key from pipeline output for shader-of-rps test"
    fi

    # T7k: R7.4 — shader-of-rps with nonexistent rps_key returns structured error, exit 11
    echo "  [T7k] shader-of-rps rps_not_found graceful (R7.4)"
    set +e
    OUTPUT=$("$BRIDGE" shader-of-rps "$GPUTRACE_PATH" 99999999 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 11 ]; then pass "missing-rps exit = 11 (EXIT_SUBCMD_FAIL)"; else fail "missing-rps exit = $rc (expected 11)"; fi
    if echo "$OUTPUT" | grep -q '"error":"rps_not_found"'; then pass "structured rps_not_found error"; else fail "missing rps_not_found error"; fi
else
    echo ""
    echo "[INFO] Skipping live trace tests (set GPUTRACE_PATH to enable)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
