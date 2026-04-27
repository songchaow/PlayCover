#!/usr/bin/env bash
# ripc_resign.sh — Re-sign com.tencent.ngr for iPad debug deployment (RIPC-002-A)
#
# Usage:
#   ./Scripts/ripc_resign.sh [--ipa <path>] [--source <path>] [--bundle-id <id>]
#                            [--profile <path>] [--identity <hash>] [--output <dir>]
#                            [--dry-run]
#
# By default, extracts the .app from the original IPA to get the native iOS
# binary (platform=2). The PlayCover installed copy has platform=6 (macCatalyst)
# and CANNOT be deployed to a real iPad (dyld will refuse to load system
# frameworks with "wrong platform").
#
# Defaults are tuned for the RIPC workflow documented in
# LocalDocs/HOKCrash/RealIPadCompare/00-Dashboard.md.

set -euo pipefail

# ── colour helpers (disabled when piped) ─────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

info()  { echo "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo "${RED}[FAIL]${RESET}  $*" >&2; exit 1; }

# ── defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_IPA="$HOME/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa"
DEFAULT_BUNDLE_ID="com.songdog.ripc.debug"
DEFAULT_PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision"
DEFAULT_IDENTITY="BB36AD6577F23F304F93A1A75A940DAE92559A7B"
DEFAULT_OUTPUT="$REPO_ROOT/build/ripc-resigned"

IPA_PATH="${DEFAULT_IPA}"
SOURCE_APP=""
BUNDLE_ID="${DEFAULT_BUNDLE_ID}"
PROFILE="${DEFAULT_PROFILE}"
IDENTITY="${DEFAULT_IDENTITY}"
OUTPUT_DIR="${DEFAULT_OUTPUT}"
DRY_RUN=0

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa)        IPA_PATH="$2"; SOURCE_APP=""; shift 2 ;;
    --source)     SOURCE_APP="$2"; IPA_PATH=""; shift 2 ;;
    --bundle-id)  BUNDLE_ID="$2";  shift 2 ;;
    --profile)    PROFILE="$2";    shift 2 ;;
    --identity)   IDENTITY="$2";   shift 2 ;;
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1;       shift   ;;
    -h|--help)
      sed -n '2,/^$/s/^# //p' "$0"; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

# ── pre-flight checks ───────────────────────────────────────────────────────
info "Pre-flight checks..."

[ -f "$PROFILE" ]    || die "Provisioning profile not found: $PROFILE"

# Verify signing identity is valid (not revoked)
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || die "Signing identity not found or revoked: $IDENTITY"

# Verify codesign & PlistBuddy are available
command -v codesign >/dev/null        || die "codesign not found"
command -v /usr/libexec/PlistBuddy >/dev/null || die "PlistBuddy not found"

ok "Pre-flight passed"

# ── resolve source .app (from IPA or direct path) ───────────────────────────
if [ -z "$SOURCE_APP" ]; then
  # Default: extract from IPA
  [ -f "$IPA_PATH" ] || die "IPA not found: $IPA_PATH (use --ipa or --source)"
  info "Extracting .app from IPA: $IPA_PATH"
  IPA_EXTRACT_DIR="$REPO_ROOT/build/ripc-ipa-extract"
  mkdir -p "$IPA_EXTRACT_DIR"

  # Find the .app directory name inside the IPA.
  # First check if we already extracted it (avoids slow unzip -l on 3GB IPA).
  EXISTING_APP=$(find "$IPA_EXTRACT_DIR/Payload" -maxdepth 1 -name "*.app" -type d 2>/dev/null | head -1)
  if [ -n "$EXISTING_APP" ]; then
    APP_BASENAME=$(basename "$EXISTING_APP")
    info "IPA already extracted at $EXISTING_APP, reusing"
  else
    # Scan IPA listing to find the .app name
    APP_DIR_IN_IPA=$(unzip -Z1 "$IPA_PATH" 2>/dev/null | grep -oE '^Payload/[^/]+\.app' | sort -u | head -1 || true)
    [ -n "$APP_DIR_IN_IPA" ] || die "No .app found inside IPA"
    APP_BASENAME=$(basename "$APP_DIR_IN_IPA")
    info "Found in IPA: $APP_DIR_IN_IPA"
    info "Extracting (this may take a while for a 3 GB IPA)..."
    unzip -o "$IPA_PATH" "Payload/$APP_BASENAME/*" -d "$IPA_EXTRACT_DIR/" >/dev/null 2>&1 \
      || die "Failed to extract IPA"
    ok "IPA extracted"
  fi
  SOURCE_APP="$IPA_EXTRACT_DIR/Payload/$APP_BASENAME"
fi

[ -d "$SOURCE_APP" ] || die "Source .app not found: $SOURCE_APP"

# ── platform safety check ───────────────────────────────────────────────────
# Detect the main executable and verify it's a native iOS binary (platform 2).
# PlayCover installed copies are macCatalyst (platform 6) and will fail on
# real iPad with: "wrong platform to load into process".
MAIN_EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$SOURCE_APP/Info.plist" 2>/dev/null)
[ -n "$MAIN_EXEC_NAME" ] || MAIN_EXEC_NAME="NGR"
MAIN_EXEC="$SOURCE_APP/$MAIN_EXEC_NAME"

if [ -f "$MAIN_EXEC" ]; then
  PLATFORM=$(otool -l "$MAIN_EXEC" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}')
  case "$PLATFORM" in
    2)
      ok "Binary platform: iOS (platform 2) — correct for iPad deployment" ;;
    6)
      die "Binary platform: macCatalyst (platform 6) — this is a PlayCover-modified copy.
  PlayCover rewrites LC_BUILD_VERSION to macCatalyst for macOS execution.
  Real iPad requires the original iOS binary (platform 2).
  Use --ipa to extract from the original IPA instead of --source." ;;
    *)
      warn "Binary platform: $PLATFORM (unexpected). Proceeding, but verify deployment works." ;;
  esac
else
  warn "Main executable not found at $MAIN_EXEC, skipping platform check"
fi

# ── extract entitlements from provisioning profile ───────────────────────────
info "Extracting entitlements from profile..."

WORK_DIR="$(mktemp -d /tmp/ripc_resign.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

PROFILE_PLIST="$WORK_DIR/profile.plist"
ENTITLEMENTS="$WORK_DIR/entitlements.plist"

security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
  || die "Failed to decode provisioning profile"

# Extract the Entitlements dict, then override application-identifier
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$PROFILE_PLIST" > "$ENTITLEMENTS" \
  || die "Failed to extract entitlements"

# Read team ID from profile
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PROFILE_PLIST")
info "Team ID: $TEAM_ID"

# Ensure application-identifier matches our bundle ID
/usr/libexec/PlistBuddy -c "Set :application-identifier ${TEAM_ID}.${BUNDLE_ID}" "$ENTITLEMENTS" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :application-identifier string ${TEAM_ID}.${BUNDLE_ID}" "$ENTITLEMENTS"

ok "Entitlements ready (get-task-allow=$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$ENTITLEMENTS"))"

# ── dry-run bail-out ─────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  info "[DRY-RUN] Would copy $SOURCE_APP → $OUTPUT_DIR/$(basename "$SOURCE_APP")"
  info "[DRY-RUN] Would change bundle ID → $BUNDLE_ID"
  info "[DRY-RUN] Would inject profile → embedded.mobileprovision"
  FW_COUNT=$(find "$SOURCE_APP/Frameworks" -maxdepth 1 -name "*.framework" -type d 2>/dev/null | wc -l | tr -d ' ')
  BUNDLE_COUNT=$(find "$SOURCE_APP" -maxdepth 1 -name "*.bundle" -type d 2>/dev/null | wc -l | tr -d ' ')
  info "[DRY-RUN] Would sign ${FW_COUNT} frameworks + ${BUNDLE_COUNT} resource bundles + main binary"
  info "[DRY-RUN] Entitlements:"
  cat "$ENTITLEMENTS"
  ok "Dry run complete"
  exit 0
fi

# ── copy .app to output ─────────────────────────────────────────────────────
info "Copying .app to output directory..."
info "Source: $SOURCE_APP"
info "Output: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"
APP_NAME="$(basename "$SOURCE_APP")"
DEST_APP="$OUTPUT_DIR/$APP_NAME"

if [ -d "$DEST_APP" ]; then
  warn "Destination already exists, removing: $DEST_APP"
  rm -rf "$DEST_APP"
fi

# Use cp -a to preserve structure; this is a ~3 GB copy
info "Copying (this may take a while for a 3 GB app)..."
cp -a "$SOURCE_APP" "$DEST_APP"
ok "Copy complete"

# ── modify bundle ID ────────────────────────────────────────────────────────
info "Changing bundle ID: com.tencent.ngr → $BUNDLE_ID"

INFO_PLIST="$DEST_APP/Info.plist"
[ -f "$INFO_PLIST" ] || die "Info.plist not found at $INFO_PLIST"

ORIG_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
info "Original bundle ID: $ORIG_BUNDLE_ID"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
ok "Bundle ID updated to $BUNDLE_ID"

# ── inject provisioning profile ─────────────────────────────────────────────
info "Injecting provisioning profile..."
cp "$PROFILE" "$DEST_APP/embedded.mobileprovision"
ok "Profile injected"

# ── remove existing code signatures ─────────────────────────────────────────
info "Removing existing code signatures..."
find "$DEST_APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
ok "Old signatures removed"

# ── sign frameworks ──────────────────────────────────────────────────────────
info "Signing embedded frameworks..."
FW_DIR="$DEST_APP/Frameworks"
FW_SIGNED=0
FW_FAILED=0

if [ -d "$FW_DIR" ]; then
  while IFS= read -r -d '' fw; do
    fw_name="$(basename "$fw")"
    if codesign --force --sign "$IDENTITY" --timestamp=none "$fw" 2>/dev/null; then
      FW_SIGNED=$((FW_SIGNED + 1))
    else
      warn "Failed to sign framework: $fw_name"
      FW_FAILED=$((FW_FAILED + 1))
    fi
  done < <(find "$FW_DIR" -maxdepth 1 -name "*.framework" -type d -print0 | sort -z)
fi

if [ "$FW_FAILED" -gt 0 ]; then
  warn "Frameworks: $FW_SIGNED signed, $FW_FAILED failed"
else
  ok "Frameworks: $FW_SIGNED signed"
fi

# ── sign resource bundles ────────────────────────────────────────────────────
info "Signing resource bundles..."
RB_SIGNED=0

while IFS= read -r -d '' rb; do
  rb_name="$(basename "$rb")"
  if codesign --force --sign "$IDENTITY" --timestamp=none "$rb" 2>/dev/null; then
    RB_SIGNED=$((RB_SIGNED + 1))
  else
    # Resource bundles without executables may not need signing — that's OK
    :
  fi
done < <(find "$DEST_APP" -maxdepth 1 -name "*.bundle" -type d -print0 | sort -z)

ok "Resource bundles: $RB_SIGNED signed"

# ── sign main app bundle ────────────────────────────────────────────────────
info "Signing main app bundle with entitlements..."
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$DEST_APP" \
  || die "Failed to sign main app bundle"

ok "Main app bundle signed"

# ── verification ─────────────────────────────────────────────────────────────
info "Verifying signature..."
codesign --verify --deep --strict "$DEST_APP" 2>&1 \
  && ok "Signature verification passed" \
  || warn "Signature verification reported issues (may be acceptable for debug deploy)"

# Report final entitlements
info "Final entitlements:"
codesign -d --entitlements - "$DEST_APP" 2>/dev/null | head -20

# Report key info
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Re-signed app ready for iPad deployment"
echo "  Path:      $DEST_APP"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Team ID:   $TEAM_ID"
echo "  Identity:  $IDENTITY"
echo ""
echo "  Next steps:"
echo "    ios-deploy --bundle \"$DEST_APP\""
echo "    # or use Xcode > Devices and Simulators"
echo "═══════════════════════════════════════════════════"
echo ""
ok "RIPC resign complete"
