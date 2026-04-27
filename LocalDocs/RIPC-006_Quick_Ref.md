# RIPC-006 Direction A - Quick Reference Guide

## 🎯 What is RIPC-006?

Path normalization fix that intercepts `/Users/.../Saved/Paks/` paths at the UE4 `ConvertToPlatformPath` function and converts them to `../../../NGR/Content/Paks/` format.

**Status**: Implemented in `PlayLoader.m` lines 2420-2566

---

## 🔨 Build Commands

### Quick Build (Development)
```bash
# Rebuild PlayTools framework (REQUIRED after PlayLoader.m changes)
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release

# Rebuild GUI app
./BuildScripts/build_gui.sh Release

# Or: Full build (GUI + CLI + tests)
./BuildScripts/build_all.sh Release
```

### For Testing
```bash
# Build + run all tests
./BuildScripts/test_mcp.sh

# Build once, run tests multiple times (faster iteration)
./BuildScripts/build_for_testing.sh
./BuildScripts/test_without_building.sh
./BuildScripts/test_without_building.sh MyTestClass  # Specific test
```

---

## 🚀 Launch & Verification

### Launch NGR App
```bash
# Via PlayCoverMCP CLI (headless)
launch_app bundleId=com.tencent.ngr

# Via PlayCoverMCP with LLDB (for debugging)
launch_app_with_lldb bundleId=com.tencent.ngr timeoutSeconds=10
```

### Check Diagnostics
```bash
# Read launch-events.jsonl
cat ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl

# Filter for RIPC-006 normalization events
grep "ripc006_pak_path_normalize" ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl

# Pretty-print JSONL
cat ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl | jq .

# Count normalization events
grep -c "ripc006_pak_path_normalize" ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
```

### Using Python Diagnostic Summary
```bash
python3 Scripts/runtime_launch_diagnostics_summary.py com.tencent.ngr
```

---

## 📂 Key File Locations

| Item | Path |
|------|------|
| **RIPC-006 Implementation** | `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` (lines 2420-2566) |
| **Diagnostics Writer** | `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift` |
| **Launch Tools** | `PlayCoverMCP/Tools/Host/LaunchTools.swift` |
| **Launch Events** | `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl` |
| **Dashboard** | `LocalDocs/HOKCrash/00-Dashboard.md` |
| **Build Scripts** | `BuildScripts/` directory |

---

## 🔍 Expected Diagnostic Events

### Successful RIPC-006 Normalization

**Event Name**: `ripc006_pak_path_normalize`

```json
{
  "event": "ripc006_pak_path_normalize",
  "action": "normalize",
  "original": "/Users/user/Library/Containers/.../Saved/Paks/1/1.db",
  "normalized": "../../../NGR/Content/Paks/1/1.db",
  "bundleId": "com.tencent.ngr",
  "timestamp": "2026-04-27T17:15:30.123Z",
  "pid": 12345,
  "processLaunchId": "launch-12345-uuid"
}
```

### Patch Installation

**Event Name**: `playcover_pdt006_convert_patch`

```json
{
  "event": "playcover_pdt006_convert_patch",
  "status": "installed",
  "detail": "ConvertToPlatformPath patched for /Users/ pass-through",
  "patchAddr": "0x1001a5014",
  "slide": "0x100000000"
}
```

---

## ✅ Verification Checklist

- [ ] Build completes without errors
- [ ] PlayTools framework rebuilt (check with `FORCE_PLAYTOOLS_REBUILD=1`)
- [ ] `launch_app bundleId=com.tencent.ngr` launches successfully
- [ ] `launch-events.jsonl` exists and contains entries
- [ ] At least one `ripc006_pak_path_normalize` event present
- [ ] Original paths follow `/Users/.*Saved/Paks/` pattern
- [ ] Normalized paths follow `../../../NGR/Content/Paks/.*` pattern
- [ ] Process remains stable (no crashes within 30 seconds)
- [ ] No `Fatal error` entries in diagnostics
- [ ] No `UIAlertController` suppression events (`hok014_ngr_alert_suppressed`)

---

## 🐛 Troubleshooting

### No RIPC-006 Events in Diagnostics

**Possible Causes**:
1. PlayTools not rebuilt → use `FORCE_PLAYTOOLS_REBUILD=1`
2. NGR not using `/Users/` paths → check actual launch environment
3. Patch not installing → check `playcover_pdt006_convert_patch` status event

**Solution**:
```bash
# Full rebuild
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release
./BuildScripts/build_gui.sh Release
./BuildScripts/build_and_install.sh Release
launch_app bundleId=com.tencent.ngr
```

### Malformed Normalized Paths

**Possible Causes**:
1. Bug in `ripc006_try_normalize_pak_path()` path parsing
2. Static buffer overflow (1024 byte limit)
3. Incorrect suffix extraction

**Debug**: Read the `original` field from event and manually check path parsing logic

### Process Crashes After Patch

**Possible Causes**:
1. Patch address calculation error
2. Memory protection issue
3. Trampoline malformed

**Debug**: Enable LLDB and check patch installation event, verify addresses match binary

---

## 📊 Quick Stats

| Metric | Value |
|--------|-------|
| Implementation lines | 147 (2420-2566 in PlayLoader.m) |
| Core functions | 3 (`ripc006_try_normalize_pak_path`, `pdt006_convert_replacement`, `ripc006_log_normalize_event`) |
| Patch size | 16 bytes (ARM64 trampoline) |
| Static buffer | 1024 bytes |
| Build time impact | ~0 (only rebuilds PlayTools) |

---

## 🎓 Related Documentation

- **Full Reference**: `LocalDocs/RIPC-006_Complete_Reference.md`
- **HOKCrash Dashboard**: `LocalDocs/HOKCrash/00-Dashboard.md`
- **PathDifferenceTrial**: `LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md`
- **Build Guide**: `BuildScripts/README.md`

---

## 💡 Tips

1. **Always rebuild PlayTools after PlayLoader.m changes**: `FORCE_PLAYTOOLS_REBUILD=1`
2. **Use LLDB for debugging**: `launch_app_with_lldb` with watchpoints if needed
3. **Check events immediately after launch**: Events written during app startup
4. **Multiple runs are expected**: Same paths may be normalized multiple times
5. **Validate patch addresses**: Verify `patchAddr` and `slide` in diagnostic events match expected values

