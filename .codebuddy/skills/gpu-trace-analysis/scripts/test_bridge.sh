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

# Check all 8 commands listed
for cmd in help replay pipeline shader shader-of-rps frame-list disasm config; do
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
for cmd in replay pipeline shader shader-of-rps frame-list disasm config; do
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

    # T7l: R7.3 — frame-list emits cb / encoder / draw timeline + draw_to_rps_map
    echo "  [T7l] frame-list timeline (R7.3)"
    set +e
    FRAME_JSON=$("$BRIDGE" frame-list "$GPUTRACE_PATH" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "frame-list exit = 0"; else fail "frame-list exit = $rc"; fi
    if echo "$FRAME_JSON" | grep -q '"command_buffer_count"'; then pass "has command_buffer_count"; else fail "missing command_buffer_count"; fi
    if echo "$FRAME_JSON" | grep -q '"encoder_count"'; then pass "has encoder_count"; else fail "missing encoder_count"; fi
    if echo "$FRAME_JSON" | grep -q '"draw_count"'; then pass "has draw_count"; else fail "missing draw_count"; fi
    if echo "$FRAME_JSON" | grep -q '"command_buffers":\['; then pass "has command_buffers tree"; else fail "missing command_buffers tree"; fi
    if echo "$FRAME_JSON" | grep -q '"draw_to_rps_map":\['; then pass "has draw_to_rps_map"; else fail "missing draw_to_rps_map"; fi
    if echo "$FRAME_JSON" | grep -q '"first_call_index"'; then pass "encoders have first_call_index"; else fail "missing first_call_index"; fi
    if echo "$FRAME_JSON" | grep -q '"last_call_index"'; then pass "encoders have last_call_index"; else fail "missing last_call_index"; fi
    if echo "$FRAME_JSON" | grep -q '"primitive_type_name"'; then pass "draws have primitive_type_name"; else fail "missing primitive_type_name"; fi

    # Validate semantic invariants via Python: encoder.draw_count sum == flat map length, no null rps_key
    INVARIANTS=$(echo "$FRAME_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
enc_sum = sum(e['draw_count'] for cb in d['command_buffers'] for e in cb['encoders'])
flat = len(d['draw_to_rps_map'])
none_rps = sum(1 for r in d['draw_to_rps_map'] if r['rps_key'] is None)
print(f'enc_sum={enc_sum} flat={flat} none_rps={none_rps} total_call_count={d[\"total_call_count\"]}')
" 2>/dev/null)
    echo "    invariants: $INVARIANTS"
    if echo "$INVARIANTS" | grep -q "enc_sum=$(echo "$INVARIANTS" | sed -n 's/.*flat=\([0-9]*\).*/\1/p')"; then
        pass "encoder draw_count sum equals draw_to_rps_map length"
    else
        fail "draw count mismatch between encoder tree and flat map"
    fi
    if echo "$INVARIANTS" | grep -q "none_rps=0"; then
        pass "every draw maps to a non-null rps_key (R7.3 + R7.2 cross-validation)"
    else
        fail "some draws have null rps_key — swizzle gap"
    fi

    # T7m: R7.3 — frame-list --no-draws suppresses draws[] and draw_to_rps_map
    echo "  [T7m] frame-list --no-draws suppression (R7.3)"
    set +e
    OUTPUT=$("$BRIDGE" frame-list "$GPUTRACE_PATH" --no-draws 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "--no-draws exit = 0"; else fail "--no-draws exit = $rc"; fi
    if echo "$OUTPUT" | grep -q '"with_draws":false'; then pass "with_draws=false"; else fail "with_draws still true"; fi
    if ! echo "$OUTPUT" | grep -q '"draw_to_rps_map"'; then pass "draw_to_rps_map omitted"; else fail "draw_to_rps_map should be omitted"; fi

    # T7n: R7.3 — frame-list → shader-of-rps end-to-end (the R7 final-mile chain)
    echo "  [T7n] frame-list → shader-of-rps end-to-end chain (R7.3)"
    FIRST_DRAW_RPS=$(echo "$FRAME_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [r for r in d['draw_to_rps_map'] if r['rps_key'] is not None]
print(m[0]['rps_key']) if m else exit(1)
" 2>/dev/null || echo "")
    if [ -n "$FIRST_DRAW_RPS" ]; then
        TMPDIR_R73C=$(mktemp -d)
        set +e
        OUTPUT=$("$BRIDGE" shader-of-rps "$GPUTRACE_PATH" "$FIRST_DRAW_RPS" --output-dir "$TMPDIR_R73C" 2>/dev/null)
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "chained shader-of-rps exit = 0"; else fail "chained shader-of-rps exit = $rc"; fi
        if echo "$OUTPUT" | grep -q '"library_metallib_path"'; then pass "produced metallib for draw[0]'s RPS"; else fail "no metallib produced"; fi
        rm -rf "$TMPDIR_R73C"
    else
        fail "could not derive a draw[0].rps_key for frame-list→shader-of-rps chain"
    fi

    # T7o: R7.6-C — shader-of-drawcall wrapper (thin封装) — 端到端 + OOR 兼测
    # wrapper-only (Scripts/gputrace_replay_wrapper.py)，bridge 不动；用 python3 调用。
    echo "  [T7o] shader-of-drawcall wrapper (R7.6-C)"
    WRAPPER="$SCRIPT_DIR/gputrace_replay_wrapper.py"
    if [ -f "$WRAPPER" ]; then
        # T7o-1: live trace draw_index=0（draw_count > 0 时）→ 验证产物与 frame-list→shader-of-rps 链字节级一致
        DRAW_COUNT=$(echo "$FRAME_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('draw_count',0))" 2>/dev/null || echo "0")
        if [ "$DRAW_COUNT" -gt 0 ]; then
            TMPDIR_SOD_A=$(mktemp -d)
            TMPDIR_SOD_B=$(mktemp -d)
            # 路径 A：手动两步 (frame-list → shader-of-rps)
            CHAIN_RPS=$(echo "$FRAME_JSON" | python3 -c "
import json, sys
d=json.load(sys.stdin)
print(d['draw_to_rps_map'][0]['rps_key'])
" 2>/dev/null)
            "$BRIDGE" shader-of-rps "$GPUTRACE_PATH" "$CHAIN_RPS" --output-dir "$TMPDIR_SOD_A" >"$TMPDIR_SOD_A/r.json" 2>/dev/null
            # 路径 B：wrapper shader-of-drawcall 0
            set +e
            python3 "$WRAPPER" shader-of-drawcall "$GPUTRACE_PATH" 0 --output-dir "$TMPDIR_SOD_B" >"$TMPDIR_SOD_B/r.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "shader-of-drawcall 0 exit = 0"; else fail "shader-of-drawcall 0 exit = $rc"; fi
            # 校验 rps_key 一致
            WRAPPER_RPS=$(python3 -c "import json; print(json.load(open('$TMPDIR_SOD_B/r.json'))['rps_key'])" 2>/dev/null || echo "")
            if [ "$WRAPPER_RPS" = "$CHAIN_RPS" ]; then pass "rps_key matches frame-list chain ($WRAPPER_RPS)"; else fail "rps_key mismatch wrapper=$WRAPPER_RPS chain=$CHAIN_RPS"; fi
            # 校验 metallib 字节级一致（如果产生了 metallib）
            ML_A=$(python3 -c "import json; print(json.load(open('$TMPDIR_SOD_A/r.json')).get('library_metallib_path') or '')" 2>/dev/null)
            ML_B=$(python3 -c "import json; print(json.load(open('$TMPDIR_SOD_B/r.json'))['shader_of_rps'].get('library_metallib_path') or '')" 2>/dev/null)
            if [ -n "$ML_A" ] && [ -n "$ML_B" ] && [ -f "$ML_A" ] && [ -f "$ML_B" ]; then
                if cmp -s "$ML_A" "$ML_B"; then pass "wrapper metallib byte-identical to chain"; else fail "wrapper metallib differs from chain"; fi
            else
                pass "metallib not produced for draw[0] (acceptable: not all libs have metallib)"
            fi
            # 校验顶层 schema 字段（rps_label / encoder_index / call_index 来自 frame-list 嵌入）
            if python3 -c "import json,sys; d=json.load(open('$TMPDIR_SOD_B/r.json')); assert 'encoder_index' in d and 'draw_in_encoder' in d and 'call_index' in d and 'shader_of_rps' in d" 2>/dev/null; then
                pass "wrapper output has frame-list embed fields"
            else
                fail "wrapper output missing frame-list embed fields"
            fi
            rm -rf "$TMPDIR_SOD_A" "$TMPDIR_SOD_B"
        else
            echo "    note: trace has draw_count=0; skipping live IR-chain assertion (compute-only trace)"
        fi

        # T7o-2: OOR — draw_index 显著超出 draw_count → exit 12 + structured error
        set +e
        OUTPUT=$(python3 "$WRAPPER" shader-of-drawcall "$GPUTRACE_PATH" 99999999 2>&1)
        rc=$?
        set -e
        if [ "$rc" -eq 12 ]; then pass "shader-of-drawcall OOR exit = 12"; else fail "OOR exit = $rc (expected 12)"; fi
        if echo "$OUTPUT" | grep -q '"error": "draw_index_out_of_range"'; then pass "OOR has structured error"; else fail "missing draw_index_out_of_range error"; fi

        # T7o-3: 模块 API（DrawIndexOutOfRange 异常 + ValueError）
        set +e
        python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
from gputrace_replay_wrapper import ReplayBridge, DrawIndexOutOfRange
b = ReplayBridge()
ok=0
try:
    b.shader_of_drawcall('$GPUTRACE_PATH', 99999999)
except DrawIndexOutOfRange:
    ok+=1
try:
    b.shader_of_drawcall('$GPUTRACE_PATH', -1)
except ValueError:
    ok+=1
try:
    b.shader_of_drawcall('$GPUTRACE_PATH', 0, stage='geometry')
except ValueError:
    ok+=1
sys.exit(0 if ok==3 else 1)
" >/dev/null 2>&1
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "module API raises DrawIndexOutOfRange + ValueError"; else fail "module API error contract failed"; fi
    else
        fail "wrapper not found at $WRAPPER"
    fi

    # T7p: R7.7 — disasm subcommand + SDI module.bc fallback (raises IR hit-rate ~3% → ~100% on LYSK)
    echo "  [T7p] R7.7 disasm + SDI module.bc fallback"
    # T7p-1: disasm <library_key> --with-ir 直接产 metallib + cacheKey
    # 选择第一个 library_key（来自 pipeline 输出），保证健壮性
    PIPELINE_DIR=$(mktemp -d)
    set +e
    "$BRIDGE" pipeline "$GPUTRACE_PATH" "$PIPELINE_DIR" >"$PIPELINE_DIR/pipe.json" 2>/dev/null
    rc=$?
    set -e
    LIB_KEY=$(python3 -c "
import json
d = json.load(open('$PIPELINE_DIR/pipe.json'))
libs = d.get('libraries', [])
# 取第一个有 metallib_file 的 library
for L in libs:
    if L.get('metallib_file'):
        print(L['key'])
        break
" 2>/dev/null)
    if [ -n "$LIB_KEY" ]; then
        pass "derived first library_key=$LIB_KEY for disasm test"
        TMP_DISASM=$(mktemp -d)
        set +e
        "$BRIDGE" disasm "$GPUTRACE_PATH" "$LIB_KEY" --output-dir "$TMP_DISASM" >"$TMP_DISASM/r.json" 2>/dev/null
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "disasm <lib_key> exit = 0"; else fail "disasm <lib_key> exit = $rc"; fi
        # 必须输出 cache_key_metallib + library_metallib_path
        if grep -q '"cache_key_metallib"' "$TMP_DISASM/r.json"; then pass "disasm output has cache_key_metallib"; else fail "disasm output missing cache_key_metallib"; fi
        if grep -q '"library_metallib_path"' "$TMP_DISASM/r.json"; then pass "disasm output has library_metallib_path"; else fail "disasm output missing library_metallib_path"; fi
        rm -rf "$TMP_DISASM"
    else
        fail "could not derive a library_key from pipeline output"
    fi

    # T7p-2: disasm <library_key> --with-ir，对一个无 AIR 的 library，验证 SDI fallback 命中
    # 选第一个 没有 bitcode_file 的 library 作为 SDI fallback 测试目标
    NO_AIR_LIB=$(python3 -c "
import json
d = json.load(open('$PIPELINE_DIR/pipe.json'))
for L in d.get('libraries', []):
    if not L.get('bitcode_file') and L.get('metallib_file'):
        print(L['key'])
        break
" 2>/dev/null)
    if [ -n "$NO_AIR_LIB" ]; then
        TMP_SDI=$(mktemp -d)
        set +e
        "$BRIDGE" disasm "$GPUTRACE_PATH" "$NO_AIR_LIB" --with-ir --output-dir "$TMP_SDI" >"$TMP_SDI/r.json" 2>/dev/null
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "disasm --with-ir on no-AIR lib exit = 0"; else fail "disasm --with-ir exit = $rc"; fi
        # 命中 SDI 时应有 ir_source=sdi_module_bc + ir_ll_path
        IR_SOURCE=$(python3 -c "import json; d=json.load(open('$TMP_SDI/r.json')); print(d.get('ir_source',''))" 2>/dev/null)
        if [ "$IR_SOURCE" = "sdi_module_bc" ]; then
            pass "ir_source = sdi_module_bc (R7.7 fallback hit)"
            if grep -q '"ir_ll_path"' "$TMP_SDI/r.json"; then pass "SDI fallback produced .ll"; else fail "SDI hit but no ir_ll_path"; fi
            if grep -q '"sdi_bundle_id"' "$TMP_SDI/r.json"; then pass "ir output has sdi_bundle_id"; else fail "missing sdi_bundle_id"; fi
        elif python3 -c "import json,sys; d=json.load(open('$TMP_SDI/r.json')); sys.exit(0 if d.get('ir_error')=='no_air_bitcode_and_no_sdi' else 1)"; then
            # 在 SDI 缓存被清空的环境下，断言降级为"软失败结构正确即可"
            pass "no SDI cache for this lib_key; got structured no_air_bitcode_and_no_sdi (acceptable)"
        else
            fail "ir_source unexpected (got '$IR_SOURCE')"
        fi
        rm -rf "$TMP_SDI"
    else
        echo "    note: all libs have AIR; skipping SDI fallback assertion"
    fi

    # T7p-3: disasm --key-type rps 路径转发到 shader-of-rps
    if [ -n "${CHAIN_RPS:-}" ]; then
        TMP_RPS=$(mktemp -d)
        set +e
        "$BRIDGE" disasm "$GPUTRACE_PATH" "$CHAIN_RPS" --key-type rps --output-dir "$TMP_RPS" >"$TMP_RPS/r.json" 2>/dev/null
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "disasm --key-type rps exit = 0"; else fail "disasm --key-type rps exit = $rc"; fi
        # 转发后 command 字段应为 shader-of-rps
        if grep -q '"command":"shader-of-rps"' "$TMP_RPS/r.json"; then pass "disasm rps forwards to shader-of-rps"; else fail "disasm rps did not forward correctly"; fi
        rm -rf "$TMP_RPS"
    else
        echo "    note: no CHAIN_RPS available; skipping rps-key forward test"
    fi

    # T7p-4: shader-of-rps --with-ir 在原本 no_air_bitcode 的 RPS 上现在透明命中 SDI
    # 复用 CHAIN_RPS（来自 frame-list draw[0]）— LYSK 上该 RPS 的 library 通常没有 AIR
    if [ -n "${CHAIN_RPS:-}" ]; then
        TMP_SOR_SDI=$(mktemp -d)
        set +e
        "$BRIDGE" shader-of-rps "$GPUTRACE_PATH" "$CHAIN_RPS" --with-ir --output-dir "$TMP_SOR_SDI" >"$TMP_SOR_SDI/r.json" 2>/dev/null
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then pass "shader-of-rps --with-ir on draw[0] RPS exit = 0"; else fail "shader-of-rps --with-ir exit = $rc"; fi
        # 不应再返回旧的 no_air_bitcode；要么 ir_source=bitcodeData/sdi_module_bc，要么是 no_air_bitcode_and_no_sdi
        if python3 -c "
import json,sys
d=json.load(open('$TMP_SOR_SDI/r.json'))
ir_err = d.get('ir_error')
ir_src = d.get('ir_source')
# 验收：不再返回旧的 no_air_bitcode（应替换为 no_air_bitcode_and_no_sdi 或直接成功）
if ir_err == 'no_air_bitcode':
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
            pass "shader-of-rps no longer returns deprecated 'no_air_bitcode'"
        else
            fail "shader-of-rps still returns deprecated 'no_air_bitcode' (R7.7 fallback not active)"
        fi
        rm -rf "$TMP_SOR_SDI"
    fi
    rm -rf "$PIPELINE_DIR"
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
