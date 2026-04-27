# RIPC-006 Direction A - Complete Documentation Index

## 📋 Overview

This index provides navigation to all RIPC-006 related documentation, implementation files, and verification workflows.

**RIPC-006** = Path normalization fix for PlayCover's runtime (PlayTools)  
**Direction A** = Normalization at the `ConvertToPlatformPath` interception point  
**Status**: ✅ Implemented in PlayLoader.m (lines 2420-2566)

---

## 📚 Documentation

### Quick Start
- **[RIPC-006_Quick_Ref.md](./RIPC-006_Quick_Ref.md)** ⭐ **START HERE**
  - Quick build commands
  - Launch verification steps
  - Troubleshooting guide
  - ~200 lines, 2-5 minute read

### Comprehensive Reference
- **[RIPC-006_Complete_Reference.md](./RIPC-006_Complete_Reference.md)** 🎓 **DEEP DIVE**
  - Full implementation details (all functions with code)
  - Build system architecture
  - Launch mechanism explained
  - Diagnostics format specification
  - Verification workflow
  - ~500 lines, 15-20 minute read

### HOKCrash Context
- **[HOKCrash/00-Dashboard.md](./HOKCrash/00-Dashboard.md)** 📊 **PROJECT STATUS**
  - Current main line (HOK-016-C.2.7)
  - Parallel lines (PDT-001-B-revised)
  - Fallback chain status
  - All TODO tasks
  - Evidence collection points

### PathDifference Trial
- **[HOKCrash/PathDifferenceTrial/00-Dashboard.md](./HOKCrash/PathDifferenceTrial/00-Dashboard.md)**
  - UE4 ConvertToPlatformPath differential analysis
  - Path transformation validation trials

---

## 💻 Implementation Files

### Core Implementation
```
Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m
├── Lines 2420-2426: Comments explaining fix approach
├── Lines 2428-2443: ripc006_try_normalize_pak_path()
│   ├── Pattern matching: /Users/...Saved/Paks/
│   ├── Fast path: 1/1.db special case
│   └── General case: construct normalized path
├── Lines 2448-2469: pdt006_convert_replacement()
│   ├── ARM64 parameter extraction
│   ├── Call ripc006_try_normalize_pak_path()
│   └── Fallback chain
├── Lines 2487-2496: ripc006_log_normalize_event()
│   └── Write to launch-events.jsonl
└── Lines 2498-2566: pdt006_install_convert_patch_once()
    ├── ARM64 ABI trampoline patching
    ├── Memory protection management
    └── Patch installation
```

### Related Implementation Files
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.h` - Header
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` - Swift diagnostics hooks
- `PlayCoverMCP/Tools/Host/LaunchTools.swift` - launch_app & launch_app_with_lldb
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift` - Launch service
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift` - Diagnostics writing

---

## 🔨 Build System

### Build Scripts
All scripts are in `BuildScripts/` directory:

| Script | Purpose | Command |
|--------|---------|---------|
| `build_gui.sh` | Build PlayCover GUI | `./BuildScripts/build_gui.sh [Release\|Debug]` |
| `build_mcp.sh` | Build PlayCoverMCP CLI | `./BuildScripts/build_mcp.sh [Release\|Debug]` |
| `build_all.sh` | GUI + CLI + tests | `./BuildScripts/build_all.sh [Release\|Debug]` |
| `sync_playtools_xcframework.sh` | Sync PlayTools | `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release` |
| `test_mcp.sh` | Run tests | `./BuildScripts/test_mcp.sh [TestClass]` |

### Key xcodebuild Parameters
```
-project PlayCover.xcodeproj
-scheme PlayCover                 # or PlayCoverMCP
-configuration Release            # or Debug
-derivedDataPath ./build
CODE_SIGN_IDENTITY="-"           # Ad-hoc signing
CODE_SIGNING_REQUIRED=NO
CODE_SIGNING_ALLOWED=YES
FASTLANE=1                       # Skip Carthage/SwiftLint
```

### PlayTools Rebuild (⚠️ CRITICAL for RIPC-006)
```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release
```

**Why**: Any changes to `PlayLoader.m` require framework rebuild to take effect

---

## 🚀 Launch Verification

### Quick Test
```bash
# 1. Rebuild PlayTools (CRITICAL!)
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release

# 2. Rebuild GUI
./BuildScripts/build_gui.sh Release

# 3. Launch app
launch_app bundleId=com.tencent.ngr

# 4. Check diagnostics (wait ~30 seconds)
grep "ripc006_pak_path_normalize" ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
```

### Full Diagnostics
```bash
cat ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl | jq .
```

### Python Summary
```bash
python3 Scripts/runtime_launch_diagnostics_summary.py com.tencent.ngr
```

---

## 📂 Diagnostics Files

### Location
```
~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/
└── com.tencent.ngr/
    └── launch-events.jsonl
```

### RIPC-006 Specific Events

**Event: `ripc006_pak_path_normalize`**
```json
{
  "event": "ripc006_pak_path_normalize",
  "action": "normalize",
  "original": "/Users/.../Saved/Paks/1/1.db",
  "normalized": "../../../NGR/Content/Paks/1/1.db"
}
```

**Event: `playcover_pdt006_convert_patch`**
```json
{
  "event": "playcover_pdt006_convert_patch",
  "status": "installed",
  "detail": "ConvertToPlatformPath patched for /Users/ pass-through"
}
```

---

## ✅ Verification Checklist

- [ ] PlayTools framework rebuilt with `FORCE_PLAYTOOLS_REBUILD=1`
- [ ] GUI rebuilt
- [ ] App launches successfully without immediate crash
- [ ] `launch-events.jsonl` file exists
- [ ] Contains `ripc006_pak_path_normalize` events
- [ ] Original paths match `/Users/.*Saved/Paks/` pattern
- [ ] Normalized paths match `../../../NGR/Content/Paks/.*` pattern
- [ ] No `Fatal error` entries in diagnostics
- [ ] Process remains stable for 30+ seconds
- [ ] No `hok014_ngr_alert_suppressed` events (ideal)

---

## 🔍 Key Functions Summary

### `ripc006_try_normalize_pak_path(const char *path)`
- **Input**: File path string
- **Output**: Normalized path or NULL
- **Logic**: Pattern match `/Users/...Saved/Paks/X` → `../../../NGR/Content/Paks/X`
- **Size**: 16 lines
- **Buffer**: Static 1024 bytes

### `pdt006_convert_replacement(uint64_t x0, uint64_t x1)`
- **Input**: x0=this pointer, x1=filename pointer (ARM64 ABI)
- **Output**: Path pointer (normalized or original)
- **Logic**: Call normalizer, log if successful, fallback to original
- **Size**: 21 lines
- **Context**: Replaces ConvertToPlatformPath at runtime

### `ripc006_log_normalize_event(const char *original, const char *normalized)`
- **Input**: Original and normalized path strings
- **Output**: JSONL line written to launch-events.jsonl + NSLog
- **Logic**: Construct JSON event with both paths + metadata
- **Size**: 10 lines

### `pdt006_install_convert_patch_once()`
- **Input**: None (called via dispatch_once at PlayTools initialization)
- **Output**: Patch installed in UE4 binary memory
- **Logic**: ARM64 ABI trampoline installation
- **Size**: 69 lines
- **Method**: Create exec page, install indirect jump, manage memory protection

---

## 🎯 Expected Behavior Flow

```
1. PlayCover launches NGR app
   ↓
2. PlayTools dyld constructor runs
   ↓
3. pdt006_install_convert_patch_once() installs patch
   ↓
4. UE4 runtime calls ConvertToPlatformPath
   ↓
5. pdt006_convert_replacement() intercepts
   ↓
6. Checks if path starts with /Users/
   ↓
7. If yes, tries ripc006_try_normalize_pak_path()
   ↓
8. If matches pattern, normalizes and logs event
   ↓
9. Returns normalized path or original
   ↓
10. Event written to launch-events.jsonl
```

---

## 🚨 Troubleshooting

### No Normalization Events

**Check**:
1. Is PlayTools rebuilt? → Use `FORCE_PLAYTOOLS_REBUILD=1`
2. Is GUI rebuilt? → Run `./BuildScripts/build_gui.sh Release`
3. Is app using `/Users/` paths? → Check `playcover_pdt006_convert_patch` event
4. Did app launch? → Check for crash logs in ~/Library/Logs/DiagnosticReports/

### Malformed Normalized Paths

**Debug**:
1. Extract `original` field from events
2. Manually trace through `ripc006_try_normalize_pak_path()` logic
3. Check for buffer overflow (>1024 bytes)
4. Verify suffix extraction after "/Saved/Paks/"

### Process Crashes After Patch

**Investigate**:
1. Check patch address: `patchAddr` in diagnostics
2. Verify VMADDR alignment in event
3. Check if `__DATA_CONST` write protection is issue (HOK-016-C.5)
4. Use LLDB to examine patch bytes

---

## 📞 Related Tasks

- **HOK-016-C.2.7**: Main line - LLDB materialize vcall breakpointing
- **PDT-001-B-revised**: Path transformation differential validation
- **HOK-013**: GLog slot preheat (prerequisite)
- **HOK-014**: UIAlertController suppressor (fallback)
- **HOK-015**: FCommandLine preseed (fallback)

---

## 🎓 Learning Path

**Recommended reading order**:

1. **Start here** → `RIPC-006_Quick_Ref.md` (2-5 min)
   - Get overview and build/test commands

2. **Understand implementation** → `RIPC-006_Complete_Reference.md` (15-20 min)
   - See full functions and architecture

3. **Understand context** → `HOKCrash/00-Dashboard.md` (10-15 min)
   - Understand where this fits in larger project

4. **Deep dive** → Read source files directly
   - `PlayLoader.m` lines 2420-2566
   - `LaunchTools.swift` (launch mechanism)
   - `BridgeListener.swift` (diagnostics)

---

## 📊 Statistics

- **Implementation**: 147 lines in PlayLoader.m
- **Functions**: 3 (normalize + replacement + logging)
- **Patch size**: 16 bytes (ARM64 trampoline)
- **Static buffer**: 1024 bytes
- **Documentation**: 692 lines (this folder)
- **Build scripts**: 10 scripts

---

## 🔗 External References

- **Xcode Project**: `PlayCover.xcodeproj`
- **BuildScripts README**: `BuildScripts/README.md`
- **Scheme Names**: PlayCover (GUI), PlayCoverMCP (CLI)
- **Test Suite**: PlayCoverMCPTests

---

## ✨ Quick Links

- 🎯 What is RIPC-006? → See "Overview" section above
- 🚀 How to build? → See "Build System" section
- 🧪 How to test? → See "Launch Verification" section
- 📋 What's the status? → See `HOKCrash/00-Dashboard.md`
- 🔍 Where's the code? → See "Implementation Files" section
- ❓ Something broken? → See "Troubleshooting" section

---

**Last Updated**: 2026-04-27  
**RIPC-006 Status**: ✅ Implemented  
**Current Phase**: RIPC-007 Verification

