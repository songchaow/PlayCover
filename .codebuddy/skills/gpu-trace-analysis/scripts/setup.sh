#!/bin/bash
# setup.sh — Build & sign the gputrace_replay_bridge binary if needed.
#
# Idempotent: re-running is cheap. The script will only rebuild if
# the source is newer than the binary, or if the binary is missing.
#
# Output: prints the absolute path of the resulting binary on stdout
# (so callers can do BRIDGE=$(./setup.sh) and use it directly).
# All progress/status lines go to stderr.
#
# Exit codes:
#   0 — binary is ready and signed
#   1 — build failed (clang error, codesign error, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BINARY="$SCRIPT_DIR/gputrace_replay_bridge"
SOURCE="$SCRIPT_DIR/gputrace_replay_bridge.m"

if [ ! -f "$SOURCE" ]; then
    echo "[ERROR] Source missing: $SOURCE" >&2
    exit 1
fi

needs_build=0
if [ ! -x "$BINARY" ]; then
    needs_build=1
    echo "[setup] Binary not found, will build." >&2
elif [ "$SOURCE" -nt "$BINARY" ]; then
    needs_build=1
    echo "[setup] Source newer than binary, will rebuild." >&2
fi

if [ "$needs_build" -eq 1 ]; then
    echo "[setup] Building bridge..." >&2
    make -C "$SCRIPT_DIR" all >&2
fi

# Sanity check: codesign must validate
if ! codesign -v "$BINARY" 2>/dev/null; then
    echo "[setup] Re-signing (validation failed)..." >&2
    codesign --force --sign "-" "$BINARY" >&2
fi

# Final smoke test — help should always succeed
if ! "$BINARY" help >/dev/null 2>&1; then
    echo "[ERROR] Bridge binary fails the basic 'help' smoke test." >&2
    exit 1
fi

echo "$BINARY"
