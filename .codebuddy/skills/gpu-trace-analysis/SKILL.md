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
│  └─► dump-uniforms <draw_index> 0 --by-name <FIELD_NAME>
│       (Directly query a named uniform's value without knowing the slot number)
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
| 3 | `dump-uniforms <draw_index> <slot> --by-name <NAME>` | You need a specific uniform value by name |

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
