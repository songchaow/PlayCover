#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  Scripts/ir_to_msl_smoketest.sh <input.ll> [output.metal]

Examples:
  Scripts/ir_to_msl_smoketest.sh \
    LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
    /tmp/test_addrspace.generated.metal

  xcrun --sdk macosx metal -c /tmp/test_addrspace.generated.metal -o /tmp/test_addrspace.generated.air
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONVERTER_SWIFT="$ROOT_DIR/Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
INPUT_LL="$1"
OUTPUT_METAL="${2:-}"

if [[ ! -f "$CONVERTER_SWIFT" ]]; then
  echo "error: cannot find IRToMSLConverter.swift at: $CONVERTER_SWIFT" >&2
  exit 1
fi

if [[ ! -f "$INPUT_LL" ]]; then
  echo "error: input IR file not found: $INPUT_LL" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/playcover-ir-smoke.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

HARNESS_SWIFT="$TMP_DIR/IRToMSLSmokeMain.swift"
HARNESS_BIN="$TMP_DIR/ir_to_msl_smoketest"

cat > "$HARNESS_SWIFT" <<'SWIFT'
import Foundation

@main
struct IRToMSLSmokeMain {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: ir_to_msl_smoketest <path-to-ll> [output.metal]\n", stderr)
            exit(2)
        }

        let inputPath = CommandLine.arguments[1]
        let outputPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil

        do {
            let irText = try String(contentsOfFile: inputPath, encoding: .utf8)
            let result = try IRToMSLConverter.convert(irText: irText)

            if let outputPath {
                try result.mslSource.write(toFile: outputPath, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data("wrote generated MSL to: \(outputPath)\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data(result.mslSource.utf8))
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
SWIFT

swiftc "$CONVERTER_SWIFT" "$HARNESS_SWIFT" -o "$HARNESS_BIN"

if [[ -n "$OUTPUT_METAL" ]]; then
  mkdir -p "$(dirname "$OUTPUT_METAL")"
  "$HARNESS_BIN" "$INPUT_LL" "$OUTPUT_METAL"
else
  "$HARNESS_BIN" "$INPUT_LL"
fi
