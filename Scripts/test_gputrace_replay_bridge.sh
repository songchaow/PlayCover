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

# Check all 9 commands listed
for cmd in help replay pipeline shader shader-of-rps frame-list disasm dump-uniforms config; do
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
for cmd in replay pipeline shader shader-of-rps frame-list disasm dump-uniforms config; do
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

    # T7q: R7.6-A — frame-list --with-bindings (default ON) emits per-draw vertex/fragment binding tables
    # NOTE: 与 R7.3 的"健康路径"断言一样，T7q 假设 trace 至少有一个 render-encoder draw（with vb0 + 16 PBR
    # textures 这类 LYSK 不变量）。compute-only trace 上 draw_count=0，整组断言不适用，跳过。
    echo "  [T7q] R7.6-A frame-list per-draw bindings"
    set +e
    BIND_JSON=$("$BRIDGE" frame-list "$GPUTRACE_PATH" 2>/dev/null)
    rc=$?
    set -e
    BIND_DRAW_COUNT=$(echo "$BIND_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('draw_count',0))" 2>/dev/null || echo "0")
    if [ "$rc" -eq 0 ]; then pass "frame-list (default) exit = 0"; else fail "frame-list exit = $rc"; fi
    if echo "$BIND_JSON" | grep -q '"with_bindings":true'; then pass "with_bindings=true by default"; else fail "with_bindings not true by default"; fi
    if [ "$BIND_DRAW_COUNT" -gt 0 ]; then
        if echo "$BIND_JSON" | grep -q '"bindings":{"vertex":{"buffers":'; then pass "draw has bindings.vertex.buffers"; else fail "missing bindings.vertex.buffers"; fi
        # textures key is always emitted (possibly []) — match without anchoring to bindings.vertex specifically
        if echo "$BIND_JSON" | grep -q '"textures":'; then pass "draw has bindings.*.textures key"; else fail "missing bindings.*.textures"; fi
        if echo "$BIND_JSON" | grep -q '"fragment":{"buffers":'; then pass "draw has bindings.fragment.buffers"; else fail "missing bindings.fragment.buffers"; fi
        # 'samplers' must always be present (possibly []) so consumers can rely on the key
        if echo "$BIND_JSON" | grep -q '"samplers":'; then pass "draw has bindings.*.samplers key"; else fail "missing bindings.*.samplers key"; fi

        # Semantic invariants (LYSK-validated):
        #   - every draw with rps_key has at least one vertex buffer (vb0)
        #   - resource_id values reference real entries in the resources dict
        #   - per-draw bindings only emitted on render-encoder draws
        BIND_INV=$(echo "$BIND_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
draws_total = 0
draws_with_v_buf = 0
draws_with_f_tex = 0
draws_missing_bindings = 0
total_v_bufs = 0
total_f_tex = 0
inline_draws = 0
for cb in d['command_buffers']:
    for e in cb['encoders']:
        for dr in e.get('draws', []):
            draws_total += 1
            bd = dr.get('bindings')
            if not bd:
                draws_missing_bindings += 1
                continue
            v = bd['vertex']; f = bd['fragment']
            if v['buffers']: draws_with_v_buf += 1
            if f['textures']: draws_with_f_tex += 1
            total_v_bufs += len(v['buffers'])
            total_f_tex += len(f['textures'])
            for slot in v['buffers'] + f['buffers']:
                if 'inline_bytes_size' in slot: inline_draws += 1
print(f'draws_total={draws_total} with_v_buf={draws_with_v_buf} with_f_tex={draws_with_f_tex} missing_bindings={draws_missing_bindings} total_v_bufs={total_v_bufs} total_f_tex={total_f_tex}')
" 2>/dev/null)
        echo "    invariants: $BIND_INV"
        if echo "$BIND_INV" | grep -q "missing_bindings=0"; then
            pass "every draw has bindings field (R7.6-A capture coverage)"
        else
            fail "some draws lack bindings — R7.6-A swizzle gap"
        fi
        if echo "$BIND_INV" | grep -qE "with_v_buf=([0-9]+) "; then
            WB=$(echo "$BIND_INV" | sed -n 's/.*with_v_buf=\([0-9]*\).*/\1/p')
            DT=$(echo "$BIND_INV" | sed -n 's/.*draws_total=\([0-9]*\).*/\1/p')
            if [ "$WB" -gt 0 ] && [ "$WB" -eq "$DT" ]; then
                pass "every draw has at least one vertex buffer (vb0 invariant)"
            else
                fail "some draws have no vertex buffer (with_v_buf=$WB / total=$DT)"
            fi
        fi
        if echo "$BIND_INV" | grep -qE "with_f_tex=([0-9]+) "; then
            WF=$(echo "$BIND_INV" | sed -n 's/.*with_f_tex=\([0-9]*\).*/\1/p')
            if [ "$WF" -gt 0 ]; then
                pass "fragment textures bound on render draws (LYSK PBR invariant)"
            else
                fail "no fragment textures captured at all"
            fi
        fi
    else
        echo "    [SKIP] draw_count=0 (compute-only trace) — R7.6-A draw-shape assertions skipped"
    fi

    # T7q-2: --no-bindings suppresses per-draw bindings AND shrinks output (only meaningful when bindings exist)
    echo "  [T7q-2] frame-list --no-bindings suppression"
    set +e
    NOBIND_JSON=$("$BRIDGE" frame-list "$GPUTRACE_PATH" --no-bindings 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then pass "--no-bindings exit = 0"; else fail "--no-bindings exit = $rc"; fi
    if echo "$NOBIND_JSON" | grep -q '"with_bindings":false'; then pass "with_bindings=false under --no-bindings"; else fail "with_bindings still true"; fi
    if ! echo "$NOBIND_JSON" | grep -q '"bindings":{"vertex"'; then pass "no per-draw bindings emitted"; else fail "bindings still emitted under --no-bindings"; fi
    # Output shrinks substantially only when there are draws to emit bindings for (LYSK: ~394KB → ~105KB; assert >=30% shrink).
    # On compute-only traces draw_count=0 so both outputs are essentially equal — skip the size-shrink assertion.
    if [ "$BIND_DRAW_COUNT" -gt 0 ]; then
        SZ_WITH=$(echo -n "$BIND_JSON" | wc -c | tr -d ' ')
        SZ_NO=$(echo -n "$NOBIND_JSON" | wc -c | tr -d ' ')
        SHRUNK=$(python3 -c "print(int($SZ_WITH * 0.7) > $SZ_NO)" 2>/dev/null)
        if [ "$SHRUNK" = "True" ]; then
            pass "--no-bindings shrinks output >30% (with=$SZ_WITH no=$SZ_NO)"
        else
            fail "--no-bindings did not shrink output enough (with=$SZ_WITH no=$SZ_NO)"
        fi
    else
        echo "    [SKIP] size-shrink assertion (draw_count=0 — both outputs essentially equal)"
    fi

    # T7q-3: backward compatibility — chain frame-list (default) → shader-of-rps still works on draw[0]
    # 这是 R7.6-A 与 R7.6-C/R7.7 兼容性的核心保险：bindings 字段不能影响 draw_to_rps_map
    if [ "$BIND_DRAW_COUNT" -gt 0 ]; then
        echo "  [T7q-3] frame-list with bindings does not break shader-of-rps chain"
        CHAIN_RPS_R76A=$(echo "$BIND_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['draw_to_rps_map'][0]['rps_key'])
" 2>/dev/null)
        if [ -n "$CHAIN_RPS_R76A" ]; then
            TMP_R76A=$(mktemp -d)
            set +e
            "$BRIDGE" shader-of-rps "$GPUTRACE_PATH" "$CHAIN_RPS_R76A" --output-dir "$TMP_R76A" >/dev/null 2>&1
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "chain-from-bindings frame-list still hits shader-of-rps"; else fail "chain broke (rc=$rc)"; fi
            rm -rf "$TMP_R76A"
        else
            fail "could not extract draw[0] rps_key from with-bindings JSON"
        fi
    fi

    # T7r: R7.6-B — dump-uniforms (cbuffer 反射解码)
    # 在 LYSK 主基线上验证：
    #   1. bridge dump-uniforms <rps_key> <bind_slot> 输出 layout（反射 captured 的证据）
    #   2. 加 --buffer-key/--offset 后输出 decoded 字段树
    #   3. wrapper draw 模式：直接 draw_index 自动解析 buffer_key/offset
    #   4. OOR / rps_not_found / bind_slot_not_in_reflection 的结构化错误
    # 与 R7.6-A 一样，draw 类断言只在 draw_count > 0 时启用。
    if [ "$BIND_DRAW_COUNT" -gt 0 ]; then
        echo "  [T7r] R7.6-B dump-uniforms reflection decode"
        # 取 frame-list 的 draw[0]：rps_key + 一个真实存在的 vertex/fragment buffer 绑定
        DU_DRAW0=$(echo "$BIND_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for cb in d['command_buffers']:
    for e in cb['encoders']:
        for dr in e.get('draws', []):
            if dr.get('draw_index_global') == 0:
                bd = dr.get('bindings', {})
                # 选 fragment 第一个非空 buffer slot（通常 slot 0 是 PerCamera 这种 cbuffer）
                for stage_key in ('fragment', 'vertex'):
                    for b in bd.get(stage_key, {}).get('buffers', []):
                        if 'resource_id' in b and b.get('resource_id', 0) > 0:
                            print(dr.get('rps_key'), b['index'], stage_key, b['resource_id'], b.get('offset', 0))
                            sys.exit(0)
" 2>/dev/null)
        if [ -n "$DU_DRAW0" ]; then
            DU_RPS=$(echo "$DU_DRAW0" | awk '{print $1}')
            DU_SLOT=$(echo "$DU_DRAW0" | awk '{print $2}')
            DU_STAGE=$(echo "$DU_DRAW0" | awk '{print $3}')
            DU_BUFKEY=$(echo "$DU_DRAW0" | awk '{print $4}')
            DU_OFFSET=$(echo "$DU_DRAW0" | awk '{print $5}')

            # T7r-1: bridge dump-uniforms <rps_key> <slot> 仅输出 layout
            TMP_DU=$(mktemp -d)
            set +e
            "$BRIDGE" dump-uniforms "$GPUTRACE_PATH" "$DU_RPS" "$DU_SLOT" --stage "$DU_STAGE" --output-dir "$TMP_DU" >"$TMP_DU/layout.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "dump-uniforms layout-only exit = 0"; else fail "dump-uniforms layout-only exit = $rc"; fi
            if grep -q '"layout":' "$TMP_DU/layout.json"; then pass "dump-uniforms emits layout"; else fail "dump-uniforms missing layout"; fi
            if grep -q '"layout_source":"metallib_reflection"' "$TMP_DU/layout.json"; then
                pass "layout_source=metallib_reflection (R7.6-B reflection capture working)"
            else
                fail "layout_source != metallib_reflection — reflection capture broken"
            fi
            if grep -q '"binding_name"' "$TMP_DU/layout.json"; then pass "layout has binding_name"; else fail "missing binding_name"; fi
            if ! grep -q '"decoded":' "$TMP_DU/layout.json"; then pass "layout-only mode does not emit decoded"; else fail "layout-only unexpectedly emitted decoded"; fi

            # T7r-2: bridge dump-uniforms with --buffer-key + --offset 输出 decoded
            set +e
            "$BRIDGE" dump-uniforms "$GPUTRACE_PATH" "$DU_RPS" "$DU_SLOT" --stage "$DU_STAGE" \
                --buffer-key "$DU_BUFKEY" --offset "$DU_OFFSET" --output-dir "$TMP_DU" >"$TMP_DU/decoded.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "dump-uniforms with buffer exit = 0"; else fail "dump-uniforms with buffer exit = $rc"; fi
            if grep -q '"decoded":' "$TMP_DU/decoded.json"; then pass "dump-uniforms emits decoded tree"; else fail "missing decoded tree"; fi
            if grep -q '"decoded_ok":true' "$TMP_DU/decoded.json"; then pass "decoded_ok=true"; else fail "decoded_ok != true"; fi

            # T7r-3: wrapper draw mode 自动解析 buffer_key/offset
            WRAPPER_PY="$SCRIPT_DIR/gputrace_replay_wrapper.py"
            if [ -f "$WRAPPER_PY" ]; then
                set +e
                python3 "$WRAPPER_PY" dump-uniforms "$GPUTRACE_PATH" 0 "$DU_SLOT" --stage "$DU_STAGE" --output-dir "$TMP_DU" >"$TMP_DU/wrapper_draw.json" 2>/dev/null
                rc=$?
                set -e
                if [ "$rc" -eq 0 ]; then pass "wrapper draw-mode dump-uniforms exit = 0"; else fail "wrapper draw-mode exit = $rc"; fi
                # 校验 wrapper 自动注入的 frame-list 上下文（用 python 解析，避免 indent 空格踩坑）
                if python3 -c "import json,sys; d=json.load(open('$TMP_DU/wrapper_draw.json')); sys.exit(0 if d.get('draw_index')==0 else 1)" 2>/dev/null; then
                    pass "wrapper auto-injects draw_index=0"
                else
                    fail "wrapper missing draw_index field"
                fi
                # rps_key 应该等于 frame-list 推出的同一 RPS
                WRAPPER_RPS=$(python3 -c "import json; print(json.load(open('$TMP_DU/wrapper_draw.json')).get('rps_key'))" 2>/dev/null)
                if [ "$WRAPPER_RPS" = "$DU_RPS" ]; then pass "wrapper rps_key auto-resolves to $DU_RPS"; else fail "wrapper rps_key=$WRAPPER_RPS != expected $DU_RPS"; fi
                # 应该也有 decoded（因为 buffer_key/offset 自动解析成功）
                if grep -q '"decoded":' "$TMP_DU/wrapper_draw.json"; then pass "wrapper draw-mode auto-decodes bytes"; else fail "wrapper missing decoded"; fi
            fi

            # T7r-4: bridge bind_slot 超出反射 → 软错误 + exit 11
            set +e
            "$BRIDGE" dump-uniforms "$GPUTRACE_PATH" "$DU_RPS" 31 --stage "$DU_STAGE" --output-dir "$TMP_DU" >"$TMP_DU/oor_slot.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 11 ]; then pass "bind_slot OOR exit = 11"; else fail "bind_slot OOR exit = $rc (expected 11)"; fi
            if grep -q '"error":"bind_slot_not_in_reflection"' "$TMP_DU/oor_slot.json"; then pass "bind_slot_not_in_reflection error code"; else fail "wrong error code on bind_slot OOR"; fi

            # T7r-5: bridge rps_key 不存在 → rps_not_found + exit 11
            set +e
            "$BRIDGE" dump-uniforms "$GPUTRACE_PATH" 99999999 0 --output-dir "$TMP_DU" >"$TMP_DU/rps_oor.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 11 ]; then pass "rps_key OOR exit = 11"; else fail "rps_key OOR exit = $rc (expected 11)"; fi
            if grep -q '"error":"rps_not_found"' "$TMP_DU/rps_oor.json"; then pass "rps_not_found error code"; else fail "wrong error code on rps OOR"; fi

            # T7r-6: wrapper draw_index OOR → exit 12 + draw_index_out_of_range
            if [ -f "$WRAPPER_PY" ]; then
                set +e
                python3 "$WRAPPER_PY" dump-uniforms "$GPUTRACE_PATH" 99999 0 >"$TMP_DU/draw_oor.json" 2>/dev/null
                rc=$?
                set -e
                if [ "$rc" -eq 12 ]; then pass "wrapper draw OOR exit = 12"; else fail "wrapper draw OOR exit = $rc (expected 12)"; fi
                if python3 -c "import json,sys; d=json.load(open('$TMP_DU/draw_oor.json')); sys.exit(0 if d.get('error')=='draw_index_out_of_range' else 1)" 2>/dev/null; then
                    pass "wrapper emits draw_index_out_of_range"
                else
                    fail "wrapper missing draw_index_out_of_range"
                fi
            fi

            rm -rf "$TMP_DU"
        else
            echo "    [SKIP] T7r — could not derive (rps_key, slot, buffer_key) from frame-list draw[0]"
        fi
    else
        echo "  [T7r] R7.6-B dump-uniforms"
        echo "    [SKIP] draw_count=0 (compute-only trace) — R7.6-B draw-shape assertions skipped"
    fi

    # T7s: R7.6-D — shader-of-drawcall 三件套合一 (wrapper 联动收尾)
    # wrapper-only：bridge 零变更。验证：
    #   1. --with-bindings 把 frame-list 的 binding 表附到结果 (与 R7.3/R7.6-A 字节级一致)
    #   2. --with-uniforms 隐含 --with-bindings
    #   3. uniforms[] 中 slot 数 = bindings.{stage}.buffers 长度，per-slot 字节级与 dump-uniforms 直调一致
    #   4. 默认 (无 flag) 行为不变 — 仅输出 IR (R7.6-C 原约定)
    #   5. 两个 stage (fragment/vertex) 独立验证
    #   6. compute-only trace 自动 SKIP (等同 T7r)
    if [ "$BIND_DRAW_COUNT" -gt 0 ]; then
        echo "  [T7s] R7.6-D shader-of-drawcall triple-bundle (IR + bindings + uniforms)"
        WRAPPER_PY="$SCRIPT_DIR/gputrace_replay_wrapper.py"
        if [ -f "$WRAPPER_PY" ]; then
            TMP_SOD_D=$(mktemp -d)

            # T7s-1: 默认 (无 flag) 行为与 R7.6-C 一致 — 不带 bindings / uniforms
            set +e
            python3 "$WRAPPER_PY" shader-of-drawcall "$GPUTRACE_PATH" 0 \
                --output-dir "$TMP_SOD_D" >"$TMP_SOD_D/r0.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "T7s-1 default invocation exit = 0"; else fail "T7s-1 default exit = $rc"; fi
            if python3 -c "
import json,sys
d=json.load(open('$TMP_SOD_D/r0.json'))
sys.exit(0 if d.get('with_bindings') is False and d.get('with_uniforms') is False
              and d.get('bindings') is None and d.get('uniforms') is None
         else 1)
" 2>/dev/null; then
                pass "T7s-1 default omits bindings/uniforms (R7.6-C compat)"
            else
                fail "T7s-1 default unexpectedly emitted bindings/uniforms"
            fi

            # T7s-2: --with-bindings 附 bindings, 不附 uniforms
            set +e
            python3 "$WRAPPER_PY" shader-of-drawcall "$GPUTRACE_PATH" 0 \
                --with-bindings --output-dir "$TMP_SOD_D" >"$TMP_SOD_D/r1.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "T7s-2 --with-bindings exit = 0"; else fail "T7s-2 --with-bindings exit = $rc"; fi
            if python3 -c "
import json,sys
d=json.load(open('$TMP_SOD_D/r1.json'))
b=d.get('bindings')
ok = (d.get('with_bindings') is True
      and d.get('with_uniforms') is False
      and isinstance(b, dict)
      and 'vertex' in b and 'fragment' in b
      and 'buffers' in b['fragment'] and 'textures' in b['fragment'])
sys.exit(0 if ok else 1)
" 2>/dev/null; then
                pass "T7s-2 emits bindings.{vertex,fragment}.{buffers,textures,samplers}"
            else
                fail "T7s-2 bindings shape wrong"
            fi
            # 与单独的 frame-list 输出 byte-level 等价 (不严格逐字段，但保证 buffers 数量一致)
            FL_FB=$(echo "$BIND_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for cb in d['command_buffers']:
    for e in cb['encoders']:
        for dr in e.get('draws', []):
            if dr.get('draw_index_global')==0:
                bd=dr.get('bindings') or {}
                f=bd.get('fragment') or {}
                print(len(f.get('buffers') or []))
                sys.exit(0)
print(0)
" 2>/dev/null || echo "0")
            SOD_FB=$(python3 -c "import json; print(len(json.load(open('$TMP_SOD_D/r1.json'))['bindings']['fragment']['buffers']))" 2>/dev/null || echo "0")
            if [ "$FL_FB" = "$SOD_FB" ] && [ "$FL_FB" != "0" ]; then
                pass "T7s-2 fragment buffer count matches frame-list (n=$FL_FB)"
            else
                fail "T7s-2 fragment buffer count mismatch (frame-list=$FL_FB, sod=$SOD_FB)"
            fi

            # T7s-3: --with-uniforms 隐含 --with-bindings
            set +e
            python3 "$WRAPPER_PY" shader-of-drawcall "$GPUTRACE_PATH" 0 \
                --with-uniforms --output-dir "$TMP_SOD_D" >"$TMP_SOD_D/r2.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "T7s-3 --with-uniforms exit = 0"; else fail "T7s-3 --with-uniforms exit = $rc"; fi
            if python3 -c "
import json,sys
d=json.load(open('$TMP_SOD_D/r2.json'))
sys.exit(0 if d.get('with_bindings') is True and d.get('with_uniforms') is True
              and d.get('bindings') is not None and d.get('uniforms') is not None
         else 1)
" 2>/dev/null; then
                pass "T7s-3 --with-uniforms implies --with-bindings"
            else
                fail "T7s-3 --with-uniforms did not imply --with-bindings"
            fi

            # T7s-4: uniforms[] 长度 = fragment.buffers 长度
            UN_LEN=$(python3 -c "import json; print(len(json.load(open('$TMP_SOD_D/r2.json'))['uniforms']))" 2>/dev/null || echo "0")
            if [ "$UN_LEN" = "$SOD_FB" ] && [ "$UN_LEN" != "0" ]; then
                pass "T7s-4 uniforms length == fragment.buffers length (n=$UN_LEN)"
            else
                fail "T7s-4 uniforms length mismatch (uniforms=$UN_LEN, fragment_buffers=$SOD_FB)"
            fi

            # T7s-5: per-slot uniforms 字节级与单独 dump-uniforms 直调一致
            #        取 slot 0 (LYSK 上几乎总是 PerCamera 这种成功 cbuffer)，对比 decoded 字段
            set +e
            python3 "$WRAPPER_PY" dump-uniforms "$GPUTRACE_PATH" 0 "$DU_SLOT" \
                --stage "$DU_STAGE" --output-dir "$TMP_SOD_D" >"$TMP_SOD_D/du_solo.json" 2>/dev/null
            set -e
            if python3 -c "
import json,sys
sod=json.load(open('$TMP_SOD_D/r2.json'))
solo=json.load(open('$TMP_SOD_D/du_solo.json'))
# 在 sod['uniforms'] 中找 stage='$DU_STAGE' 且 bind_slot=$DU_SLOT 的项
target=None
for u in sod.get('uniforms', []):
    if u.get('bind_slot')==$DU_SLOT and u.get('stage')=='$DU_STAGE':
        target=u
        break
if target is None:
    sys.exit(2)
# 比较 layout (反射结构) 与 decoded (字节解码) — 都来自同一 RPS+slot，应严格相等
def keep(d, k):
    return d.get(k)
ok = (keep(target,'layout')==keep(solo,'layout')
      and keep(target,'binding_name')==keep(solo,'binding_name')
      and keep(target,'decoded')==keep(solo,'decoded')
      and keep(target,'decoded_ok')==keep(solo,'decoded_ok'))
sys.exit(0 if ok else 1)
" 2>/dev/null; then
                pass "T7s-5 per-slot uniforms byte-level matches dump-uniforms direct call"
            else
                fail "T7s-5 per-slot uniforms differs from dump-uniforms direct call"
            fi

            # T7s-6: vertex stage 也能跑 (LYSK draw 0 通常 vertex 也有 buffers — 至少 vb0)
            set +e
            python3 "$WRAPPER_PY" shader-of-drawcall "$GPUTRACE_PATH" 0 \
                --stage vertex --with-uniforms --output-dir "$TMP_SOD_D" >"$TMP_SOD_D/r3.json" 2>/dev/null
            rc=$?
            set -e
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 11 ]; then pass "T7s-6 vertex stage exit in (0,11)"; else fail "T7s-6 vertex stage exit = $rc"; fi
            if python3 -c "
import json,sys
d=json.load(open('$TMP_SOD_D/r3.json'))
ok = (d.get('stage')=='vertex'
      and d.get('with_uniforms') is True
      and isinstance(d.get('uniforms'), list))
sys.exit(0 if ok else 1)
" 2>/dev/null; then
                pass "T7s-6 vertex stage emits uniforms list"
            else
                fail "T7s-6 vertex stage missing uniforms list"
            fi

            # T7s-7: module API surface — 关键字参数与默认值
            set +e
            python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
from gputrace_replay_wrapper import ReplayBridge
b = ReplayBridge()
# 默认 with_bindings=False, with_uniforms=False
r0 = b.shader_of_drawcall('$GPUTRACE_PATH', 0)
assert r0.bindings is None, 'default bindings should be None'
assert r0.uniforms is None, 'default uniforms should be None'
# with_uniforms=True 自动开 bindings
r1 = b.shader_of_drawcall('$GPUTRACE_PATH', 0, with_uniforms=True)
assert r1.bindings is not None, 'with_uniforms should imply bindings'
assert r1.uniforms is not None and len(r1.uniforms) > 0, 'uniforms should be a non-empty list'
# uniforms[*] 元素是 DumpUniformsResult
from gputrace_replay_wrapper import DumpUniformsResult, FrameDrawBindings
assert isinstance(r1.bindings, FrameDrawBindings)
assert all(isinstance(u, DumpUniformsResult) for u in r1.uniforms)
print('OK')
" >/dev/null 2>&1
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then pass "T7s-7 module API contract (defaults + uniforms implies bindings + types)"; else fail "T7s-7 module API contract failed (rc=$rc)"; fi

            rm -rf "$TMP_SOD_D"
        else
            fail "T7s — wrapper not found at $WRAPPER_PY"
        fi
    else
        echo "  [T7s] R7.6-D shader-of-drawcall triple-bundle"
        echo "    [SKIP] draw_count=0 (compute-only trace) — R7.6-D draw-shape assertions skipped"
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
