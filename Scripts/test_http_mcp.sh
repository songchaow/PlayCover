#!/bin/bash
# =============================================================================
# H06: PlayCover Streamable HTTP MCP 集成测试
# =============================================================================
#
# 用法:
#   ./Scripts/test_http_mcp.sh
#   PLAYCOVER_APP_PATH="/absolute/path/to/PlayCover.app" ./Scripts/test_http_mcp.sh
#   WITH_REGRESSION=1 ./Scripts/test_http_mcp.sh
#
# 环境变量:
#   MCP_BASE_URL        HTTP MCP 端点，默认 http://127.0.0.1:19820/mcp
#   PLAYCOVER_APP_PATH  可选；若提供则仅接受 /Applications/PlayCover.app，并在测试前尝试启动
#   WAIT_TIMEOUT        等待 HTTP 服务启动的秒数，默认 20
#   WITH_REGRESSION     设为 1 时，额外执行 GUI/CLI build、MCP 全量测试、CLI stdio 回归
#   DERIVED_DATA_PATH   回归模式使用的 DerivedData 路径，默认 <repo>/build/http-mcp-deriveddata
#
# 重要:
#   - 不要直接启动 build/.../PlayCover.app；PlayCover 会弹出“移到应用程序文件夹”提示。
#   - GUI 冒烟请先用 BuildScripts/build_and_install.sh（或等效流程）安装到 /Applications。
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MCP_BASE_URL="${MCP_BASE_URL:-http://127.0.0.1:19820/mcp}"
PLAYCOVER_APP_PATH="${PLAYCOVER_APP_PATH:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"
WITH_REGRESSION="${WITH_REGRESSION:-0}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/build/http-mcp-deriveddata}"
EXPECTED_PROTOCOL_VERSION="2025-11-25"
EXPECTED_SERVER_NAME="playcover-mcp-gui"
SYSTEM_APP_INSTALL_PATH="/Applications/PlayCover.app"
USER_APP_INSTALL_PATH="$HOME/Applications/PlayCover.app"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/playcover-http-mcp.XXXXXX")"
FAILED=0
SESSION_ID=""
NEGOTIATED_PROTOCOL_VERSION=""

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

info() {
    echo ""
    echo "=== $1 ==="
}

pass() {
    echo "✅ $1"
}

fail() {
    echo "❌ $1"
    FAILED=1
}

require_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "依赖已找到: $1"
    else
        fail "缺少依赖: $1"
        exit 1
    fi
}

is_allowed_app_install_path() {
    local candidate="$1"
    [[ "$candidate" == "$SYSTEM_APP_INSTALL_PATH" || "$candidate" == "$USER_APP_INSTALL_PATH" ]]
}

extract_header() {
    local file="$1"
    local header_name="$2"
    python3 - "$file" "$header_name" <<'PY'
import sys
path, target = sys.argv[1], sys.argv[2].lower()
with open(path, 'r', encoding='utf-8', errors='ignore') as f:
    for raw in f:
        if ':' not in raw:
            continue
        key, value = raw.split(':', 1)
        if key.strip().lower() == target:
            print(value.strip())
            break
PY
}

run_curl() {
    local header_file="$1"
    local body_file="$2"
    shift 2

    local status
    set +e
    status=$(curl -sS -D "$header_file" -o "$body_file" -w "%{http_code}" "$@")
    local curl_exit=$?
    set -e

    CURL_EXIT_CODE="$curl_exit"
    CURL_HTTP_STATUS="$status"
}

assert_http_status() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$description (HTTP $actual)"
    else
        fail "$description (expected HTTP $expected, got $actual)"
    fi
}

assert_header_contains() {
    local header_file="$1"
    local header_name="$2"
    local expected_substring="$3"
    local description="$4"
    local value
    value="$(extract_header "$header_file" "$header_name")"
    if [[ "$value" == *"$expected_substring"* ]]; then
        pass "$description"
    else
        fail "$description (got: ${value:-<missing>})"
    fi
}

assert_json_check() {
    local json_file="$1"
    local description="$2"
    local python_code="$3"

    if python3 - "$json_file" <<PY
import json
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
$python_code
PY
    then
        pass "$description"
    else
        echo "--- JSON payload ($description) ---"
        cat "$json_file"
        echo ""
        fail "$description"
    fi
}

wait_for_server() {
    info "等待 HTTP MCP 服务"

    if [[ -n "$PLAYCOVER_APP_PATH" ]]; then
        if ! is_allowed_app_install_path "$PLAYCOVER_APP_PATH"; then
            fail "PLAYCOVER_APP_PATH 必须是 $SYSTEM_APP_INSTALL_PATH 或 $USER_APP_INSTALL_PATH；直接启动 build 目录中的 PlayCover.app 会触发“移到应用程序文件夹”弹窗"
            echo "建议先执行: BuildScripts/build_and_install.sh"
            exit 1
        fi

        echo "尝试启动: $PLAYCOVER_APP_PATH"
        open "$PLAYCOVER_APP_PATH"
        sleep 1
    fi

    local attempt=0
    while (( attempt < WAIT_TIMEOUT * 2 )); do
        local probe_headers="$TMP_DIR/probe.headers"
        local probe_body="$TMP_DIR/probe.body"
        run_curl "$probe_headers" "$probe_body" \
            --connect-timeout 1 \
            -H "Accept: text/event-stream" \
            "$MCP_BASE_URL"

        if [[ "$CURL_HTTP_STATUS" != "000" ]]; then
            pass "HTTP 服务可达 (HTTP $CURL_HTTP_STATUS)"
            return
        fi

        sleep 0.5
        attempt=$((attempt + 1))
    done

    fail "HTTP 服务未在 ${WAIT_TIMEOUT}s 内就绪: $MCP_BASE_URL"
    echo "如需自动拉起 GUI，请先把 PlayCover 安装到 $SYSTEM_APP_INSTALL_PATH 或 $USER_APP_INSTALL_PATH 后再设置 PLAYCOVER_APP_PATH。"
    exit 1
}

initialize_session() {
    info "测试 1: initialize 握手"

    local headers="$TMP_DIR/init.headers"
    local body="$TMP_DIR/init.json"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"integration-test","version":"1.0"}}}'

    assert_http_status "$CURL_HTTP_STATUS" "200" "initialize 返回成功"
    assert_header_contains "$headers" "content-type" "application/json" "initialize 返回 application/json"

    SESSION_ID="$(extract_header "$headers" "Mcp-Session-Id")"
    NEGOTIATED_PROTOCOL_VERSION="$(extract_header "$headers" "Mcp-Protocol-Version")"

    if [[ -n "$SESSION_ID" ]]; then
        pass "initialize 返回 Mcp-Session-Id"
    else
        fail "initialize 缺少 Mcp-Session-Id"
    fi

    if [[ "$NEGOTIATED_PROTOCOL_VERSION" == "$EXPECTED_PROTOCOL_VERSION" ]]; then
        pass "initialize 返回协商后的 Mcp-Protocol-Version"
    else
        fail "initialize 协商协议版本不正确 (got: ${NEGOTIATED_PROTOCOL_VERSION:-<missing>})"
    fi

    assert_json_check "$body" "initialize 响应包含 serverInfo 与 protocolVersion" '
assert data["result"]["serverInfo"]["name"] == "playcover-mcp-gui"
assert data["result"]["protocolVersion"] == "2025-11-25"
'
}

send_initialized_notification() {
    info "测试 2: initialized 通知"

    local headers="$TMP_DIR/initialized.headers"
    local body="$TMP_DIR/initialized.body"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

    assert_http_status "$CURL_HTTP_STATUS" "202" "notifications/initialized 返回 202"
}

request_tools_list() {
    info "测试 3: tools/list"

    local headers="$TMP_DIR/tools.headers"
    local body="$TMP_DIR/tools.json"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

    assert_http_status "$CURL_HTTP_STATUS" "200" "tools/list 返回成功"
    assert_header_contains "$headers" "content-type" "application/json" "tools/list 默认返回 JSON"
    assert_json_check "$body" "tools/list 返回工具数组" '
assert isinstance(data["result"]["tools"], list)
assert len(data["result"]["tools"]) > 0
'
}

request_resources_list() {
    info "测试 4: resources/list"

    local headers="$TMP_DIR/resources.headers"
    local body="$TMP_DIR/resources.json"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","id":3,"method":"resources/list"}'

    assert_http_status "$CURL_HTTP_STATUS" "200" "resources/list 返回成功"
    assert_header_contains "$headers" "content-type" "application/json" "resources/list 默认返回 JSON"
    assert_json_check "$body" "resources/list 返回资源数组" '
assert isinstance(data["result"]["resources"], list)
assert len(data["result"]["resources"]) > 0
'
}

request_ping() {
    info "测试 5: ping"

    local headers="$TMP_DIR/ping.headers"
    local body="$TMP_DIR/ping.json"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","id":4,"method":"ping"}'

    assert_http_status "$CURL_HTTP_STATUS" "200" "ping 返回成功"
    assert_json_check "$body" "ping 返回 result" '
assert "result" in data
assert data["id"] == 4
'
}

verify_sse_stream() {
    info "测试 6: GET SSE primer event"

    local headers="$TMP_DIR/sse.headers"
    local body="$TMP_DIR/sse.txt"

    run_curl "$headers" "$body" \
        -N \
        --max-time 2 \
        -H "Accept: text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        "$MCP_BASE_URL"

    if [[ "$CURL_EXIT_CODE" == "0" || "$CURL_EXIT_CODE" == "28" ]]; then
        pass "GET SSE 请求成功建立（curl exit $CURL_EXIT_CODE）"
    else
        fail "GET SSE 请求失败（curl exit $CURL_EXIT_CODE）"
    fi

    assert_http_status "$CURL_HTTP_STATUS" "200" "GET SSE 返回 200"
    assert_header_contains "$headers" "content-type" "text/event-stream" "GET SSE 返回 text/event-stream"

    if grep -Eq '^id: .+$' "$body" && grep -Eq '^data: ?$' "$body"; then
        pass "SSE 收到 primer event"
    else
        echo "--- SSE body ---"
        cat "$body"
        echo ""
        fail "SSE 未收到 primer event"
    fi
}

verify_security_guards() {
    info "测试 7: 安全与协议校验"

    local headers body

    headers="$TMP_DIR/origin.headers"
    body="$TMP_DIR/origin.body"
    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Origin: http://evil.com" \
        -d '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"evil","version":"1.0"}}}'
    assert_http_status "$CURL_HTTP_STATUS" "403" "恶意 Origin 被拒绝"

    headers="$TMP_DIR/missing-session.headers"
    body="$TMP_DIR/missing-session.json"
    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","id":11,"method":"tools/list"}'
    assert_http_status "$CURL_HTTP_STATUS" "400" "缺少 session ID 被拒绝"

    headers="$TMP_DIR/missing-version.headers"
    body="$TMP_DIR/missing-version.json"
    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -d '{"jsonrpc":"2.0","id":12,"method":"ping"}'
    assert_http_status "$CURL_HTTP_STATUS" "400" "缺少 MCP-Protocol-Version 被拒绝"

    headers="$TMP_DIR/invalid-version.headers"
    body="$TMP_DIR/invalid-version.json"
    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: 2024-11-05" \
        -d '{"jsonrpc":"2.0","id":13,"method":"ping"}'
    assert_http_status "$CURL_HTTP_STATUS" "400" "无效 MCP-Protocol-Version 被拒绝"
}

delete_session() {
    info "测试 8: DELETE 终止会话"

    local headers="$TMP_DIR/delete.headers"
    local body="$TMP_DIR/delete.body"

    run_curl "$headers" "$body" \
        -X DELETE "$MCP_BASE_URL" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION"

    assert_http_status "$CURL_HTTP_STATUS" "200" "DELETE 成功终止会话"
}

verify_session_gone() {
    info "测试 9: 已删除会话不可复用"

    local headers="$TMP_DIR/dead-session.headers"
    local body="$TMP_DIR/dead-session.json"

    run_curl "$headers" "$body" \
        -X POST "$MCP_BASE_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Mcp-Session-Id: $SESSION_ID" \
        -H "Mcp-Protocol-Version: $NEGOTIATED_PROTOCOL_VERSION" \
        -d '{"jsonrpc":"2.0","id":14,"method":"ping"}'

    assert_http_status "$CURL_HTTP_STATUS" "404" "删除后的 session 返回 404"
}

run_regression() {
    info "测试 10: 可选回归验证"

    echo "DerivedData: $DERIVED_DATA_PATH"

    xcodebuild -project PlayCover.xcodeproj \
      -scheme PlayCover \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      build 2>&1 | tail -20
    pass "PlayCover GUI 构建通过"

    xcodebuild -project PlayCover.xcodeproj \
      -scheme PlayCoverMCP \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      build 2>&1 | tail -20
    pass "PlayCoverMCP CLI 构建通过"

    xcodebuild test -project PlayCover.xcodeproj \
      -scheme PlayCoverMCP \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      2>&1 | tail -30
    pass "PlayCoverMCP 全量测试通过"

    local cli_binary="$DERIVED_DATA_PATH/Build/Products/Release/PlayCoverMCP"
    local cli_output="$TMP_DIR/cli-init.json"

    if [[ ! -x "$cli_binary" ]]; then
        fail "未找到 CLI 二进制: $cli_binary"
        return
    fi

    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"cli-regression","version":"1.0"}}}' \
        | "$cli_binary" 2>/dev/null | head -1 > "$cli_output"

    assert_json_check "$cli_output" "CLI stdio initialize 正常" '
assert data["result"]["serverInfo"]["name"] == "playcover-mcp"
assert data["result"]["protocolVersion"] == "2025-11-25"
'
}

main() {
    require_cmd curl
    require_cmd python3
    require_cmd xcodebuild

    wait_for_server
    initialize_session
    send_initialized_notification
    request_tools_list
    request_resources_list
    request_ping
    verify_sse_stream
    verify_security_guards
    delete_session
    verify_session_gone

    if [[ "$WITH_REGRESSION" == "1" ]]; then
        run_regression
    else
        info "跳过可选回归验证"
        echo "设置 WITH_REGRESSION=1 可追加执行 GUI/CLI build、MCP 全量测试与 CLI stdio 回归。"
    fi

    echo ""
    if [[ "$FAILED" == "0" ]]; then
        echo "🎉 HTTP MCP 集成测试通过"
    else
        echo "⚠️ HTTP MCP 集成测试存在失败项"
        exit 1
    fi
}

main "$@"
