---
name: gpu-trace-analysis
description: Investigates rendering bugs and performance issues in macOS Metal apps by replaying .gputrace captures headlessly via a bundled ObjC bridge. Use this skill whenever the user reports a rendering problem (black screen, missing geometry, wrong colors, broken material, flickering, shader issue, NaN output, validation error, GPU hang, performance regression) and provides or references a .gputrace file — even if they don't say "replay" explicitly. Also use it when the user wants to inspect Metal textures/buffers, dump shader binaries (metallib/AIR), hot-replace shaders to test fixes, enumerate pipeline states, or compare configurations on captured traces. Invoke this skill proactively whenever a .gputrace path appears in the conversation, or whenever the user mentions Xcode GPU capture, Metal frame debugger, AGX shaders, or asks to investigate "what the GPU did" in a captured frame. This skill should also trigger when the user asks about uniform/cbuffer values, pipeline state inspection, draw call analysis, render pass debugging, or wants to understand what a frame renders — even if they phrase it as "check the shader", "what's bound to this draw", "why is this material wrong", or "decode the constant buffer". If you see any path ending in .gputrace or any mention of Metal rendering investigation, load this skill immediately. Additionally trigger for: exporting textures from GPU traces (including ASTC/BC/ETC compressed textures with automatic decompression), verifying exported pixel data integrity, reading .meta.json sidecar files from previous exports, or any question about Metal pixel formats, texture compression, or GPU resource inspection.
---

# GPU Trace Analysis & Render-Bug Investigation

Headless `.gputrace` replay as a programmable workflow for Metal rendering issues on macOS.

## Setup (run once per session)

```bash
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")
WRAPPER="$SKILL_DIR/scripts/gputrace_replay_wrapper.py"
```

If `setup.sh` exits non-zero, stop — the skill cannot work. Needs only system `clang` + `/System/Library/PrivateFrameworks/GPUToolsReplay.framework`.

After setup, run a quick health check to confirm the bridge + trace are operational:

```bash
python3 "$WRAPPER" diagnose "$TRACE"
# → {"bridge_ok": true, "replay_ok": true, "resource_count": N, ...}
# If errors[] is non-empty, consult "Troubleshooting & Recovery" below.
```

---

## Decision Tree — "Which command do I run?"

Start here. Match the user's situation and follow the arrow.

```
User gives you a rendering problem + .gputrace
│
├─ You KNOW the shader/material name (from Xcode GUI, user report, label)?
│  │
│  └─► find-draws --by-label "<name>" --show-first --with-ir --with-uniforms
│       (One command → matching draws + IR + bindings + uniforms of first hit)
│
├─ You KNOW the draw index?
│  │
│  └─► shader-of-drawcall <draw_index> --with-ir --with-uniforms
│       (Full triple-bundle: shader IR + binding tables + decoded cbuffer fields)
│
├─ You KNOW a cbuffer field name (e.g. "_MainLightPosition")?
│  │
│  └─► dump-uniforms <draw_index> --by-name <FIELD_NAME>
│       (Directly query a named uniform's value — auto-scans all slots, no slot number needed)
│
├─ You DON'T KNOW what to look at yet?
│  │
│  ├─ "Output is black / blank" → Pattern 1 below
│  ├─ "Colors wrong / material broken" → Pattern 2 below
│  ├─ "Crash / validation error" → Pattern 3 below
│  ├─ "NaN / weird values in uniforms" → Pattern 4 below
│  ├─ "Missing texture / wrong texture bound" → Pattern 5 below
│  └─ "Unknown trace, explore it" → Full Exploration Sequence below
│
└─ You need MERGED per-draw context (IR + metadata + size-check)?
   │
   └─► draw-info <draw_index> --with-uniforms
        (Auto-joins IR arg_name + binding + size_check into one view)
```

**80%+ of investigations use only these 3 commands:**

| # | Command | When to use |
|---|---------|-------------|
| 1 | `find-draws --by-label <name> --show-first --with-ir --with-uniforms` | You have a name from Xcode GUI or user report |
| 2 | `draw-info <draw_index> --with-uniforms` | You need the merged binding view with IR metadata + size checks |
| 3 | `dump-uniforms <draw_index> --by-name <NAME>` | You need a specific uniform value by name (auto-scans all slots) |

---

## 5 Bug Pattern Quick-Reference

### Pattern 1: Black Screen / Blank Output

**Symptoms**: render target is all zeros, nothing visible.

```bash
# Step 1: confirm trace replays cleanly
"$BRIDGE" replay "$TRACE"
# Check: success=true

# Step 2: inventory render targets, find the final color buffer
"$BRIDGE" replay "$TRACE" --list-resources | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('resources',[]):
  if r['type']=='texture' and 'renderTarget' in r.get('usage',[]):
    print(f\"  id={r['id']} {r.get('pixelFormatName','')} {r.get('width','')}x{r.get('height','')} label={r.get('label','')}\")
"

# Step 3: export + check for all-zeros
"$BRIDGE" replay "$TRACE" --export <ID> /tmp/color.bin
python3 -c "data=open('/tmp/color.bin','rb').read(); nz=sum(1 for b in data if b); print(f'non-zero: {nz}/{len(data)} ({100*nz/len(data):.1f}%)')"

# Step 4: if all-zero, bisect with --playto to find when it goes wrong
"$BRIDGE" replay "$TRACE" --bounds  # get total_call_count
"$BRIDGE" replay "$TRACE" --playto <MID> --export <ID> /tmp/color_mid.bin
```

**判断标准**: non-zero% = 0 → draw never wrote; non-zero but wrong colors → Pattern 2.

> ⚠️ **Common Mistakes — Pattern 1**
> - **Not checking `export_verification` before analyzing**: The export may succeed (exit 0) but produce all-zero bytes (memoryless texture, empty render target). Always inspect `export_verification.all_zero` and `non_zero_pct` before drawing conclusions from the data.
> - **Exporting the wrong resource**: `--list-resources` may return hundreds of textures. Filter by resolution + pixel format + usage flags to find the actual final color buffer. Exporting a depth or stencil attachment by mistake will look "blank" (all near-zero values).
> - **Forgetting `--playto` for bisection**: If the final output is blank, don't just re-export the same resource — bisect with `--playto` to find *when* it went wrong.

### Pattern 2: Wrong Colors / Material Bug

**Symptoms**: specific material/effect renders incorrectly.

```bash
# ONE COMMAND — from shader name to full context:
python3 "$WRAPPER" find-draws "$TRACE" --by-label "<MaterialName>" \
    --show-first --with-ir --with-uniforms --output-dir /tmp/out
```

**判断标准**:
- Check `uniforms_summary.slot_failed` — any slots failing to decode?
- Check `value_health_summary` — any NaN/inf in uniform values?
- Open `ir_ll_path` — does the shader math match expectations?
- Compare `bindings.fragment.textures[]` resource_ids against expected assets.

If uniforms and textures look correct, the bug is in shader logic → Pattern 5 (hot-replace).

> ⚠️ **Common Mistakes — Pattern 2**
> - **Confusing slot index with IR location_index**: The `bind_slot` for `dump-uniforms` is the `MTLBinding.index` (from reflection), NOT the array position in `bindings.fragment.buffers[]`. Use `draw-info` which auto-joins these for you.
> - **Ignoring `value_health_summary`**: If `nan_count > 0` or `inf_count > 0`, the problem is upstream data, not shader logic. Report it as a CPU-side bug rather than investigating the shader IR.
> - **Skipping `uniforms_summary.slot_failed`**: Some slots may fail to decode (reflection not captured, inline bytes). Always check `slot_failed > 0` before concluding "uniforms look fine".

### Pattern 3: Crash / Validation Error / GPU Hang

**Symptoms**: replay fails, Metal validation fires, or GPU hangs.

```bash
# Run with validation enabled — watch stderr for Metal validation messages
"$BRIDGE" config "$TRACE" enableValidation=1 2>/tmp/validation.log
cat /tmp/validation.log

# If validation is silent but replay fails, bisect the crash point:
"$BRIDGE" replay "$TRACE" --bounds  # get max N
"$BRIDGE" replay "$TRACE" --playto <N/2>  # binary search for first-failing call
```

**判断标准**: validation messages name the offending call. Cross-reference with `pipeline` output.

### Pattern 4: NaN / Bad Uniform Values

**Symptoms**: shader output has artifacts caused by bad input data.

```bash
# Full draw context with automatic NaN/inf detection:
python3 "$WRAPPER" shader-of-drawcall "$TRACE" <draw_index> \
    --with-ir --with-uniforms --output-dir /tmp/out

# Check the output:
# - uniforms[].value_health_summary.nan_count > 0 → found NaN
# - uniforms[].value_health_summary.fields_with_nan → which fields

# Or query a specific field by name:
python3 "$WRAPPER" dump-uniforms "$TRACE" <draw_index> 0 \
    --by-name "_FresnelColor"
```

**判断标准**: `value_health_summary` reports NaN/inf → bug is upstream (CPU-side data).

### Pattern 5: Missing / Wrong Texture Bound

**Symptoms**: texture appears blank, uses wrong asset, or is entirely missing.

```bash
# Get the draw's full binding table:
python3 "$WRAPPER" draw-info "$TRACE" <draw_index> --with-uniforms --output-dir /tmp/out

# In output, check bindings.fragment.textures[]:
# - Each entry has {index, resource_id, arg_name (from IR), size_check}
# - arg_name tells you what the shader expects at that slot
# - resource_id links to replay --list-resources

# Export the suspect texture (auto-decompresses ASTC/BC/ETC):
"$BRIDGE" replay "$TRACE" --export <resource_id> /tmp/suspect_tex.bin
# → Check export_verification.all_zero and .warnings[] in output
# → Read /tmp/suspect_tex.bin.meta.json for width/height/format/bytes_per_row

# Check dimensions/format/compressed status:
"$BRIDGE" replay "$TRACE" --list-resources | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('resources',[]):
  if r['id']==<resource_id>:
    print(json.dumps(r,indent=2))
    if r.get('compressed'): print('⚠️  COMPRESSED texture — export auto-decompresses')
"
```

**判断标准**: resource_id mismatch, or exported texture is blank/wrong dimensions. If `export_verification.all_zero` is true, the texture was never written to (or is memoryless).

> ⚠️ **Common Mistakes — Pattern 5**
> - **Using `getBytes` directly on compressed textures**: Metal `getBytes` on ASTC/BC/ETC textures returns raw compressed blocks, NOT RGBA pixels. Always use `--export` which auto-decompresses. If you bypass the bridge and call `getBytes` yourself, the "texture data" will be garbage.
> - **Ignoring `.meta.json` sidecar**: After `--export`, always read the `.meta.json` file for `width`, `height`, `bytes_per_pixel`, `bytes_per_row`, `channel_order`. Do NOT guess dimensions from file size alone — padding and alignment can differ.
> - **Forgetting to check `compressed` flag**: Before exporting, use `--list-resources` and check `"compressed": true`. This changes the interpretation of file size and the expected output format (decompressed RGBA vs raw blocks).

---

## Full Exploration Sequence (unknown trace, no target)

When the user asks "what does this frame do?" with no specific bug:

```bash
# 1. Bounds probe (cheap)
"$BRIDGE" replay "$TRACE" --bounds

# 2. Pipeline overview (RPS↔shader correlation)
"$BRIDGE" pipeline "$TRACE" /tmp/pipelines > /tmp/pipeline.json

# 3. Frame timeline (encoder/draw tree + draw→RPS map + bindings)
"$BRIDGE" frame-list "$TRACE" > /tmp/frame.json

# 4. Pick a target:
#    - By label: find-draws --by-label <name>
#    - By attachment count: jq from pipeline.json
#    - By encoder position: jq from frame.json

# 5. Drill into the target:
python3 "$WRAPPER" shader-of-drawcall "$TRACE" <draw_index> \
    --with-ir --with-uniforms --output-dir /tmp/shaders
```

---

## Operational Guardrails

- **Read-only by default.** No mutation of `.gputrace` on disk.
- **macOS only, Apple Silicon GPU verified.** Intel GPUs may have different class names.
- **GPU counters / profiler / shader debugger out of scope** — require private entitlements + SIP off.
- Parallel replays are safe (separate processes) but heavy batches can slow the system.

---

## Reference Files (read on demand)

| File | Read when |
|---|---|
| `references/cli-reference.md` | You need exact flags, JSON schemas, Python module API, or edge-case behavior for any subcommand |
| `references/investigation-playbook.md` | You want full worked examples beyond the quick patterns above (frame overview, trace comparison, shader hot-replace) |
| `references/architecture.md` | You hit unexpected behavior and need to understand bridge internals (Controller path, ObjectMap, swizzle mechanics) |

---

## Verifying the Skill

```bash
bash "$SKILL_DIR/scripts/test_bridge.sh"
# With a live trace for full coverage:
GPUTRACE_PATH=/path/to/sample.gputrace bash "$SKILL_DIR/scripts/test_bridge.sh"
# → 148 assertions on render-bearing traces
```

---

## Troubleshooting & Recovery

When something goes wrong, use this section to diagnose and fix it. The `diagnose` subcommand (below) automates most checks.

### Quick health check (run after Setup)

```bash
python3 "$WRAPPER" diagnose "$TRACE"
# → {"bridge_ok": true, "replay_ok": true, "resource_count": 247, "bridge_version_hash": "..."}
```

If `diagnose` passes, the skill is operational. If any field is false, follow the relevant failure mode below.

### Failure Mode 1: Setup / Compilation Fails

**Symptoms**: `setup.sh` exits non-zero; `make` prints clang errors; bridge binary missing.

**Diagnose**:
```bash
# Check clang is available
which clang && clang --version

# Check GPUToolsReplay framework exists
ls /System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay
```

**Fix**:
- If clang missing → install Xcode Command Line Tools: `xcode-select --install`
- If GPUToolsReplay.framework missing → requires macOS with Xcode installed (not just CLT)
- If specific compile error → check that `gputrace_replay_bridge.m` is not corrupted; re-run `make clean && make`

**If unfixable**: Report: "Bridge compilation failed. clang={version}, macOS={version}, framework_exists={yes/no}. Error: {first 5 lines of stderr}."

### Failure Mode 2: Trace Path Not Found or Corrupted

**Symptoms**: `FileNotFoundError` or `ValueError("Path does not end with .gputrace")`.

**Diagnose**:
```bash
ls -la "$TRACE"
file "$TRACE"  # should say "directory"
ls "$TRACE/"   # should contain Metadata.plist, capture*.gputrace-internal, etc.
```

**Fix**:
- Verify the path is correct and accessible (no broken symlinks)
- `.gputrace` must be a directory bundle, not a zip/file
- If the user provided a partial path, try `find / -name "*.gputrace" -type d 2>/dev/null | head -5`

**If unfixable**: Report: "Trace path '{path}' is not a valid .gputrace bundle. Contents: {ls output}."

### Failure Mode 3: Replay Crashes or Times Out

**Symptoms**: bridge exits with code 10 (REPLAY_FAIL) or `TimeoutError` after 300s.

**Diagnose**:
```bash
# Try bounds-only (cheapest replay operation)
"$BRIDGE" replay "$TRACE" --bounds

# If bounds-only also fails, the trace itself may be corrupt
# Check system log for GPU fault
log show --predicate 'subsystem == "com.apple.gpu"' --last 30s
```

**Fix**:
- If `--bounds` works but full replay fails → try `--playto 1` (just first call). Some traces need `forceLoadUnusedResources=1`.
- If Metal device error → ensure no other GPU-heavy process is running; try after system restart.
- Timeout → increase `--timeout` value; LYSK trace takes ~8s on M1, but damaged traces can hang indefinitely.

**If unfixable**: Report: "Replay crashed (exit {code}) or timed out. bounds_ok={yes/no}, system={chip}, macOS={version}. Stderr: {first 5 lines}."

### Failure Mode 4: Export Returns All-Zero Data

**Symptoms**: `export_verification.all_zero == true`, or exported file is all 0x00 bytes.

**Diagnose**:
```bash
# Confirm the resource exists and has expected dimensions
python3 "$WRAPPER" replay "$TRACE" --list-resources | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('resources',[]):
  if r['id'] == <RESOURCE_ID>:
    print(json.dumps(r, indent=2))
"
```

**Fix**:
- Resource may be memoryless (no backing store) → cannot export, this is expected
- Resource may require `--playto N` (only written at a specific call index)
- For compressed textures: the bridge auto-decompresses, but if `was_decompressed: false` in `.meta.json`, something went wrong → try re-export

**If unfixable**: Report: "Export of resource {id} ({format}, {width}x{height}) produced all zeros. Resource type={type}, label={label}. Possible memoryless."

### Failure Mode 5: Non-Zero Exit Code from Bridge

**Symptoms**: `BridgeError(exit_code=N)` in wrapper; raw bridge stderr output.

**Diagnose**: Check the exit code mapping:
| Code | Name | Meaning |
|------|------|---------|
| 1 | USAGE_ERROR | Wrong arguments passed |
| 2 | BAD_INPUT | Invalid trace path / file |
| 3 | NO_METAL_DEVICE | No GPU available |
| 4 | DLOPEN_FAIL | GPUToolsReplay.framework not loadable |
| 5 | SYMBOL_RESOLVE_FAIL | Framework API changed |
| 6 | APR_FAIL | Archive/trace open failed |
| 7 | DATASOURCE_FAIL | DataSource creation failed |
| 8 | OBJECTMAP_FAIL | ObjectMap creation failed |
| 9 | CONTROLLER_FAIL | Controller creation failed |
| 10 | REPLAY_FAIL | playAll/playTo failed |
| 11 | SUBCMD_FAIL | Subcommand-level soft error (JSON still emitted) |
| 12 | PLAYTO_OOR | Call index out of range |

**Fix**:
- Codes 1-2: fix your arguments
- Codes 3-5: environment issue (no GPU, missing framework)
- Codes 6-9: trace may be corrupt or incompatible with current macOS
- Codes 11-12: structured errors with JSON payload — inspect the `error` and `hint` fields

### Failure Mode 6: Python Wrapper ImportError

**Symptoms**: `ImportError` or `ModuleNotFoundError` when importing `gputrace_replay_wrapper`.

**Diagnose**:
```bash
python3 --version  # must be 3.9+
python3 -c "from pathlib import Path; from dataclasses import dataclass; print('OK')"
```

**Fix**:
- Wrapper requires Python 3.9+ (uses `list[str]` type hints)
- No external dependencies needed — only stdlib
- If importing as module, ensure `sys.path` includes the scripts directory

---

## Known Blind Spots

- **Depth/stencil export**: `--export` refuses depth/stencil textures. Workaround: sample inside a shader → write to color target → export that.
- **Compute encoder dispatches**: listed in timeline but dispatch_count stays 0.
- **Indirect draws / mesh shaders**: not in swizzle set.
- **Inline buffer bytes**: `frame-list` records `inline_bytes_size` but not the raw bytes.

### Compressed Texture Export (R10/R11)

The bridge automatically detects ASTC/BC/ETC textures and decompresses them via a GPU render pass before export. Key points for the agent:

1. **Detection**: Use `--list-resources` — compressed textures now have `"compressed": true` and `"block_size": "4x4"` (R11.3). Always check this before export.
2. **Auto-decompression**: `--export` handles decompression transparently. Output is always raw RGBA pixels (RGBA8 for sRGB/LDR, RGBA16Float for HDR).
3. **Verification** (R11.1): Export output now includes `export_verification` with:
   - `all_zero`: if true → decompression failed silently; the texture was likely memoryless or empty
   - `non_zero_pct`: < 1% is suspicious
   - `warnings[]`: structured alerts for common failure modes
4. **Meta file** (R11.2): A `.meta.json` is auto-written alongside the export containing `width`, `height`, `bytes_per_pixel`, `bytes_per_row`, `original_pixel_format_name`, `output_pixel_format_name`, `was_decompressed`, `channel_order`. Feed this to any decode/visualization script instead of guessing format info.
5. **Common pitfall**: Metal `getBytes` on compressed textures returns raw compressed blocks, NOT pixels. The bridge handles this, but if you ever bypass the bridge and call `getBytes` directly, you'll get garbage. Always use `--export`.

If the user asks for any of these, explain the gap and offer the closest substitute.
