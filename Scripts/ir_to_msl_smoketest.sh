#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  Scripts/ir_to_msl_smoketest.sh <input.ll> [output.metal]

Examples:
  Scripts/ir_to_msl_smoketest.sh \
    LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
    build/test_addrspace.generated.metal

  xcrun --sdk macosx metal -c build/test_addrspace.generated.metal -o build/test_addrspace.generated.air
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT_DIR/Scripts/corpus_replay_runner.py"
INPUT_LL="$1"
OUTPUT_METAL="${2:-}"

if [[ ! -f "$RUNNER" ]]; then
  echo "error: replay runner not found: $RUNNER" >&2
  exit 1
fi

if [[ ! -f "$INPUT_LL" ]]; then
  echo "error: input IR file not found: $INPUT_LL" >&2
  exit 1
fi

if [[ -n "$OUTPUT_METAL" ]]; then
  mkdir -p "$(dirname "$OUTPUT_METAL")"
  python3 "$RUNNER" --ll "$INPUT_LL" --output-file "$OUTPUT_METAL" --quiet
else
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/playcover-ir-smoke.XXXXXX")"
  trap 'rm -rf "$TMP_DIR"' EXIT
  TMP_OUTPUT="$TMP_DIR/output.metal"
  TMP_REPORT="$TMP_DIR/replay.json"
  python3 "$RUNNER" --ll "$INPUT_LL" --output-file "$TMP_OUTPUT" --report-file "$TMP_REPORT" --quiet
  cat "$TMP_OUTPUT"
fi
