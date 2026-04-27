# RIPC-006 Direction A Fix Implementation - Complete Report

## Overview

**RIPC-006** is a fix for normalizing pak-path handling in PlayCover's runtime (`PlayTools`). It addresses the root cause of path mismatches between natural runs and the NGR (Next Generation Runtime) in PlayCover.

**Direction A** implements path normalization at the earliest point in the injection chain - at the `ConvertToPlatformPath` interception point, normalizing `/Users/.../Saved/Paks/<X>` paths to `../../../NGR/Content/Paks/<X>` format to ensure proper path ladder matching in the materializer.

---

## 1. Implementation Details

### Location
- **Primary Implementation**: `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- **Lines**: 2420-2566

### Core Functions

#### `ripc006_try_normalize_pak_path(const char *path)` (Lines 2428-2443)

```c
static const char *ripc006_try_normalize_pak_path(const char *path) {
    if (path == NULL || strncmp(path, "/Users/", 7) != 0) { return NULL; }
    const char *savedPaks = strstr(path, "/Saved/Paks/");
    if (savedPaks == NULL) { return NULL; }
    const char *suffix = savedPaks + strlen("/Saved/Paks/");
    if (suffix[0] == '\0') { return NULL; }
    // Fast path: 已知 RIPC-005 失败 case
    if (strcmp(suffix, "1/1.db") == 0) {
        return pt_ngr_c5_content_pak_path; // "../../../NGR/Content/Paks/1/1.db"
    }
    // General case: 其它 Saved/Paks/<X> → ../../../NGR/Content/Paks/<X>
    static char ripc006_buf[1024];
    snprintf(ripc006_buf, sizeof(ripc006_buf),
             "../../../NGR/Content/Paks/%s", suffix);
    return ripc006_buf;
}
```

**Purpose**:
- Detects `/Users/` paths containing `/Saved/Paks/`
- Extracts the suffix after `/Saved/Paks/`
- Returns a normalized relative path `../../../NGR/Content/Paks/<suffix>`
- Has a fast path for the known failure case `1/1.db`
- Returns `NULL` if path doesn't match pattern (allows fallback)

#### `pdt006_convert_replacement(uint64_t x0, uint64_t x1)` (Lines 2448-2469)

```c
static uint64_t pdt006_convert_replacement(uint64_t x0, uint64_t x1) {
    const char *path = (const char *)(uintptr_t)x1;

    // RIPC-006 Direction A: 对 /Users/ 开头路径优先尝试 Saved/Paks 归一化
    if (pdt006_should_pass_through(path)) {
        const char *normalized = ripc006_try_normalize_pak_path(path);
        if (normalized != NULL) {
            ripc006_log_normalize_event(path, normalized);
            return (uint64_t)(uintptr_t)normalized;
        }
        // PDT-006 原逻辑：非 Saved/Paks 的 /Users/ 路径直接透传
        return x1;
    }

    if (pdt006_original_exec_page != NULL) {
        typedef uint64_t (*orig_func_t)(uint64_t, uint64_t);
        orig_func_t orig = (orig_func_t)pdt006_original_exec_page;
        return orig(x0, x1);
    }

    return x1;
}
```

**Purpose** (ARM64 calling convention):
- `x0` = `this` pointer (FIOSPlatformFile*)
- `x1` = filename pointer (const TCHAR*)
- Returns: normalized path or original path
- Intercepts the `ConvertToPlatformPath` function in the UE4 runtime
- If path matches `/Users/...Saved/Paks/...`, normalize it
- Otherwise, pass through to original or return as-is

#### `ripc006_log_normalize_event(const char *original, const char *normalized)` (Lines 2487-2496)

Records normalization events to `launch-events.jsonl` with:
- `action`: `"normalize"`
- `original`: Original `/Users/...` path
- `normalized`: Converted relative path
- Also logs via NSLog for debugging

### Patch Installation

**Function**: `pdt006_install_convert_patch_once()` (Lines 2498-2566)

This uses ARM64 ABI trampoline patching:
1. Locates the main Mach-O image with correct VMADDR
2. Validates NGR slot preheating is enabled
3. Saves original 16 bytes at patch target
4. Creates an executable page via `mmap()` for the original code + trampoline
5. Sets up ARM64 indirect jump instruction:
   - `0x58000050` - LDR X16, [PC, #8]
   - `0xd61f0200` - BR X16
   - 8-byte literal with target address
6. Makes memory writable, applies patch, then restores read+execute protection
7. Stores exec page for fallback execution

**Key Addresses**:
- `PDT006_CONVERT_FUNC_UNSLID` = unslid address of ConvertToPlatformPath
- Validates unslid `__TEXT` vmaddr == `NGRSLOT_PREHEAT_TEXT_VMADDR`
- Slides address for runtime patching

---

## 2. Build System

### Project Structure
```
PlayCover/
├── PlayCover.xcodeproj/          # Main Xcode project
├── BuildScripts/                  # Build automation scripts
├── Carthage/                       # Dependency management
├── PlayCover/                      # GUI app target
├── PlayCoverMCP/                   # MCP CLI target
└── PlayCoverMCPTests/              # Test suite
```

### Build Commands

#### **Build PlayCover GUI**
```bash
./BuildScripts/build_gui.sh              # Release (default)
./BuildScripts/build_gui.sh Debug        # Debug variant
```

**Underlying xcodebuild**:
```bash
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCover \
  -configuration Release \
  -derivedDataPath ./build \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1
```

#### **Build PlayCoverMCP CLI**
```bash
./BuildScripts/build_mcp.sh               # Release
./BuildScripts/build_mcp.sh Debug         # Debug
```

**Underlying xcodebuild**:
```bash
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -configuration Release \
  -derivedDataPath ./build \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  FASTLANE=1
```

#### **Full Build + Test**
```bash
./BuildScripts/build_all.sh              # Release
./BuildScripts/build_all.sh Debug        # Debug
```

Steps:
1. Syncs PlayTools xcframework
2. Builds PlayCover GUI (PlayCover scheme)
3. Builds PlayCoverMCP CLI (PlayCoverMCP scheme)
4. Runs full test suite (PlayCoverMCP scheme)

#### **Run Tests Only**
```bash
./BuildScripts/test_mcp.sh                          # All tests
./BuildScripts/test_mcp.sh SigningServiceTests      # Specific class
```

### Build Parameters

| Parameter | Purpose |
|-----------|---------|
| `-derivedDataPath ./build` | Output products to local `build/` directory (ignored in `.gitignore`) |
| `CODE_SIGN_IDENTITY="-"` | Ad-hoc signing (no developer certificate required) |
| `CODE_SIGNING_REQUIRED=NO` | Skip strict signing enforcement |
| `CODE_SIGNING_ALLOWED=YES` | Allow ad-hoc signatures |
| `FASTLANE=1` | Skip Carthage bootstrap and SwiftLint build phases |
| `-destination 'platform=macOS,arch=arm64'` | Target macOS ARM64 (for tests) |

### Build Output Location
```
build/
├── Build/Products/Release/      # Compiled binaries (.app, CLI)
├── Build/Intermediates.noindex/ # Intermediate build artifacts
└── Logs/                         # Build logs
```

---

## 3. Launch Mechanism (launch_app)

### MCP Launch Tools

**Location**: `PlayCoverMCP/Tools/Host/LaunchTools.swift`

#### `launch_app` Tool
- **Name**: `launch_app`
- **Parameters**: 
  - `bundleId` (required, string): Bundle identifier of app to launch
- **Description**: "Launch a PlayCover-managed iOS application. The app is opened via NSWorkspace in headless mode."
- **Implementation**: Calls `launchService.launchApp(bundleId:)`

#### `launch_app_with_lldb` Tool
- **Name**: `launch_app_with_lldb`
- **Parameters**:
  - `bundleId` (required): Bundle identifier
  - `withTerminalWindow` (optional, bool): Open LLDB in Terminal window
  - `timeoutSeconds` (optional, number): Headless timeout (default: 5.0s)
  - `watchAddress` (optional, string): Data watchpoint target address (hex, e.g., `0x10e2146f8`)
  - `watchSize` (optional, number): Watchpoint region size in bytes (default: 8)
  - `preRunCommands` (optional, array): LLDB commands before launch
  - `dyldInitializersLogPath` (optional, string): Redirect child stderr to this path
  - `deferWatchpointInstall` (optional, bool): Don't auto-install watchpoint before run
  - `teardownTimeoutSeconds` (optional, number): Teardown window after timeout (default: 2.0s)
- **Description**: "Launch a PlayCover-managed iOS application under LLDB for debugging"

### Launch Service

**Location**: `PlayCoverMCP/HostServices/Launch/LaunchService.swift`

Provides:
- `launchApp(bundleId:)` → `LaunchResult`
- `launchAppWithLLDB(bundleId:, withTerminalWindow:, timeoutSeconds:, options:)` → `LaunchResult`

### LaunchResult Structure
```swift
struct LaunchResult {
    var bundleIdentifier: String
    var launched: Bool
    var method: String           // "app" or "lldb"
    var message: String
    var lldb: LLDBEvidence?      // Only when launched via LLDB
}
```

---

## 4. launch-events.jsonl File

### Location
```
~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/
└── <bundleId>/
    └── launch-events.jsonl
```

Example for NGR:
```
~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
```

### Writing Mechanism

**Location**: `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift` (Lines 9-86)

```swift
enum RuntimeLaunchDiagnostics {
    private static let schemaVersion = 1
    private static let writeQueue = DispatchQueue(label: "com.playtools.runtime-launch-diagnostics")
    static let processLaunchId = "launch-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"

    static func record(event: String, bundleId: String? = nil, details: [String: String] = [:]) {
        // Records diagnostics event to launch-events.jsonl
    }
}
```

### Event Format (JSONL)

Each line is a JSON object:
```json
{
  "schemaVersion": 1,
  "timestamp": "2026-04-27T17:15:30.123Z",
  "event": "ripc006_pak_path_normalize",
  "bundleId": "com.tencent.ngr",
  "pid": 12345,
  "processLaunchId": "launch-12345-uuid",
  "isMainThread": false,
  "action": "normalize",
  "original": "/Users/.../Saved/Paks/1/1.db",
  "normalized": "../../../NGR/Content/Paks/1/1.db"
}
```

### Key Events Related to RIPC-006

| Event | Source | Fields |
|-------|--------|--------|
| `ripc006_pak_path_normalize` | `ripc006_log_normalize_event()` | `action`, `original`, `normalized` |
| `playcover_pdt006_convert_patch` | `pdt006_log_event()` | `status`, `patchAddr`, `slide`, `detail` |
| `playcover_startup_compat_profile_applied` | PlayCover startup | Indicates compat gate applied |

### Verification Script

**Location**: `Scripts/runtime_launch_diagnostics_summary.py`

Reads and summarizes `launch-events.jsonl`:
```bash
Scripts/runtime_launch_diagnostics_summary.py <bundle_id>
```

---

## 5. HOKCrash Main Dashboard

### Location
`LocalDocs/HOKCrash/00-Dashboard.md`

### Current State Summary

**Purpose**: Tracks stabilization of `com.tencent.ngr` (Next Generation Runtime) launch crashes in PlayCover.

**Primary Goal**: Make NGR stable to launch and remain alive (not crash during startup)

**Current Status**:
- External crash boundaries fully stabilized (HOK-013/014/015/010 all applied)
- Process no longer crashes but remains in "zombie state" (GameThread exited)
- Root cause narrowed down to storage create-table chain failure
- **Critical discovery**: Natural run materialize vcall target (`0x100128c6c`) differs from dual-force analysis target
- C.5 blocked by `__DATA_CONST` write protection

**Main Line (HOK-016-C.2.7)**:
Use LLDB to directly breakpoint `0x100122f54` materialize vcall, collect statistics on:
- Hit count in natural run
- Actual target values per hit (`x8` register)
- Return values (`x0`)
- Timing correlation with `hok014_ngr_alert_suppressed`

**Parallel Line (PDT-001-B-revised)**:
Verify if UE4 `ConvertToPlatformPath` differential is root cause by swizzling path transformations

**Fallback Chain** (in order):
1. HOK-013: GLog slot preheat
2. HOK-015: FCommandLine preseed
3. HOK-010: rootWorkDir transparency + self-heal
4. HOK-014: UIAlertController suppressor

### Key Diagnostic Events

For RIPC-006 verification:
- `playcover_startup_compat_profile_applied` / `playcover_startup_compat_profile_skipped`
- `hok013_ngr_slot_preheat status=primed`
- `hok014_ngr_alert_suppressed`
- `hok015_ngr_cmdline_preseed status=primed`
- `ripc006_pak_path_normalize` ← **RIPC-006 specific**
- `playcover_pdt006_convert_patch status=installed`

### Evidence Collection Points

```
~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
~/Library/Logs/DiagnosticReports/NGR-*.ips
build/hok-*.json  (structured evidence storage)
build/hok-*.log
```

---

## 6. Build & Deployment Scripts

### Available Scripts in `BuildScripts/`

| Script | Purpose | Usage |
|--------|---------|-------|
| `build_gui.sh` | Build PlayCover GUI | `./BuildScripts/build_gui.sh [Debug/Release]` |
| `build_mcp.sh` | Build PlayCoverMCP CLI | `./BuildScripts/build_mcp.sh [Debug/Release]` |
| `build_all.sh` | GUI + CLI + tests | `./BuildScripts/build_all.sh [Debug/Release]` |
| `test_mcp.sh` | Run MCP tests | `./BuildScripts/test_mcp.sh [TestClass]` |
| `build_for_testing.sh` | Build test target only | `./BuildScripts/build_for_testing.sh` |
| `test_without_building.sh` | Run tests without rebuild | `./BuildScripts/test_without_building.sh [TestClass]` |
| `build_and_install.sh` | Build GUI + install to /Applications | `./BuildScripts/build_and_install.sh [Debug/Release]` |
| `sync_playtools_xcframework.sh` | Sync PlayTools framework | `./BuildScripts/sync_playtools_xcframework.sh [Config]` |
| `verify_render_capture.sh` | RenderCapture verification | `./BuildScripts/verify_render_capture.sh` |
| `lint_pbxproj.sh` | Validate pbxproj format | `./BuildScripts/lint_pbxproj.sh` |

### PlayTools Rebuilding

For changes to PlayLoader.m with RIPC-006 implementation:

```bash
# Force rebuild of PlayTools framework
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release

# Or for Debug
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Debug

# Then rebuild GUI
./BuildScripts/build_gui.sh Release
```

---

## 7. Key Files & Locations Reference

### RIPC-006 Implementation
- **Main**: `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` (lines 2420-2566)
- **Header**: `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.h`
- **Swift Diagnostics**: `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`

### Launch & Diagnostics
- **Launch Tools**: `PlayCoverMCP/Tools/Host/LaunchTools.swift`
- **Launch Service**: `PlayCoverMCP/HostServices/Launch/LaunchService.swift`
- **Diagnostics Writer**: `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`

### Build Configuration
- **Xcode Project**: `PlayCover.xcodeproj/project.pbxproj`
- **Build Scripts**: `BuildScripts/*.sh`
- **Schemes**: PlayCover (GUI), PlayCoverMCP (CLI)

### Documentation
- **Dashboard**: `LocalDocs/HOKCrash/00-Dashboard.md`
- **RIPC-006 Context**: `LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md`
- **Build Guide**: `BuildScripts/README.md`

---

## 8. Verification Workflow

### Build for Testing
```bash
# 1. Force rebuild PlayTools with RIPC-006 changes
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release

# 2. Rebuild GUI
./BuildScripts/build_gui.sh Release

# 3. Or do full build + test
./BuildScripts/build_all.sh Release
```

### Launch App & Verify
```bash
# 1. Launch the NGR app (via MCP CLI or directly)
launch_app bundleId=com.tencent.ngr

# OR with LLDB for detailed diagnostics
launch_app_with_lldb bundleId=com.tencent.ngr timeoutSeconds=10

# 2. Check launch-events.jsonl for RIPC-006 normalization events
cat "~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl" | \
  grep "ripc006_pak_path_normalize"

# 3. Verify event structure
# Expected format:
# {"event":"ripc006_pak_path_normalize","action":"normalize","original":"/Users/.../Saved/Paks/...","normalized":"../../../NGR/Content/Paks/..."}
```

### Key Success Indicators

✅ **RIPC-006 Working**:
1. `launch-events.jsonl` contains entries with `event: "ripc006_pak_path_normalize"`
2. Original paths match `/Users/.*Saved/Paks/` pattern
3. Normalized paths are in `../../../NGR/Content/Paks/` format
4. Process doesn't crash (session remains stable)
5. No `Fatal error` or `UIAlertController` entries in diagnostics

❌ **Issues**:
- No normalization events → patch not installing
- Normalized paths malformed → `ripc006_try_normalize_pak_path()` bug
- Process crashes after normalization → issue in application logic

---

## Summary

RIPC-006 Direction A is a clean, minimal fix that:

1. **Intercepts** at the highest point (`ConvertToPlatformPath` in UE4 runtime)
2. **Detects** `/Users/.../Saved/Paks/` paths via pattern matching
3. **Normalizes** to relative paths `../../../NGR/Content/Paks/`
4. **Logs** every normalization to `launch-events.jsonl` for verification
5. **Falls back** to pass-through for non-matching paths
6. **Patches** via ARM64 trampoline at load time (once per process)

The fix is **app-scoped** (only affects NGR via PlayTools), **reversible** (can be removed by reverting PlayLoader.m), and **diagnostically transparent** (full event logging).

