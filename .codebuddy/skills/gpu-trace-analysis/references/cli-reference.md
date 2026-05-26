# CLI & API Reference

Complete surface for the bundled tools. **Start with the 3 Core Commands** — they cover 80%+ of investigations. Expand the remaining sections only when needed.

## Table of Contents

### Core Commands (full documentation)
1. [find-draws (wrapper-only)](#core-find-draws)
2. [draw-info (wrapper-only)](#core-draw-info)
3. [dump-uniforms](#core-dump-uniforms)

### Supporting Commands (concise reference)
4. [shader-of-drawcall (wrapper-only)](#shader-of-drawcall)
5. [replay](#replay)
6. [pipeline](#pipeline)
7. [frame-list](#frame-list)
8. [shader-of-rps](#shader-of-rps)
9. [disasm](#disasm)
10. [shader (hot-replace)](#shader)
11. [config](#config)
12. [diagnose (wrapper-only)](#diagnose)

### Reference
13. [Exit codes](#exit-codes)
14. [Python wrapper — CLI mode](#python-wrapper--cli-mode)
15. [Python wrapper — module mode](#python-wrapper--module-mode)

---

# Core Commands

These 3 commands cover the vast majority of rendering investigations. Master them first.

---

<a id="core-find-draws"></a>
## 1. find-draws (wrapper-only, recommended entry point)

**Purpose**: Bridge the gap between "I see shader name X in Xcode GUI" and "I need a draw_index for CLI tools". One command goes from a name to full draw context.

```bash
python3 "$WRAPPER" find-draws <trace> \
    --by-label <SUBSTR>          # case-insensitive substring on rps_label
    [--by-shader-name <SUBSTR>]  # match on vertex/fragment function name
    [--by-rps-key <KEY>]         # exact RPS key
    [--show-first]               # auto-run shader-of-drawcall on first hit
    [--with-ir]                  # include LLVM IR (with --show-first)
    [--with-uniforms]            # include decoded cbuffer (with --show-first)
    [--stage fragment|vertex]    # default: fragment
    [--limit N]                  # max hits (default: 50)
    [--output-dir DIR]
```

**Typical usage** (fastest path from name to full context):
```bash
python3 "$WRAPPER" find-draws "$TRACE" \
    --by-label "SkinMakeupNew" --show-first --with-ir --with-uniforms
```

**Output JSON**:
```json
{
  "command": "find-draws",
  "filter": {"by_label": "SkinMakeupNew", "by_shader_name": null, "by_rps_key": null},
  "hit_count": 14,
  "draw_count": 244,
  "hits": [
    {"draw_index": 4, "encoder_index": 2, "draw_in_encoder": 4,
     "call_index": 178, "rps_key": 476, "rps_label": "Papegame/SkinMakeupNew"}
  ],
  "show_first": { /* full shader-of-drawcall result with IR + uniforms */ }
}
```

**Notes**:
- Multiple filters are AND-combined.
- `vertex_function_name` / `fragment_function_name` populated only with `--by-shader-name` (avoids extra replay cost).
- At least one of `--by-label`, `--by-shader-name`, `--by-rps-key` required.

**Python module**:
```python
result = bridge.find_draws(trace, by_label="SkinMakeupNew",
                           show_first=True, show_first_with_ir=True)
for hit in result.hits:
    print(f"draw {hit.draw_index} → rps {hit.rps_key}")
```

---

<a id="core-draw-info"></a>
## 2. draw-info (wrapper-only, R8.1)

**Purpose**: Merged per-draw binding view with IR metadata automatically injected — eliminates the error-prone manual join between `frame-list` + `IR .ll` + `dump-uniforms`.

```bash
python3 "$WRAPPER" draw-info <trace> <draw_index> \
    [--with-uniforms]    # decode all buffer slots through reflection
    [--stage fragment|vertex]  # default: fragment
    [--output-dir DIR]
    [--pretty]
```

**What it does internally**:
1. `frame-list --with-bindings` → target draw's bindings + rps_key
2. `pipeline` → rps_key's vertex/fragment library_key
3. `disasm --with-ir` (per library, cached) → `.ll` IR files
4. `parse_air_metadata(.ll)` → per-slot `{arg_name, type_name, size}`
5. `enrich_stage_bindings()` → inject metadata into JSON + compute `size_check`

**Output JSON** (key fields):
```json
{
  "command": "draw-info",
  "draw_index": 69,
  "rps_key": 496, "rps_label": "Papegame/SkinMakeupNew",
  "bindings": {
    "fragment": {
      "buffers": [
        {"index": 0, "resource_id": 8, "offset": 0,
         "arg_name": "AsukaPerShader_PerCamera", "ir_arg_size": 144,
         "size_check": "ok", "buffer_label": "ConstantBuffer"},
        {"index": 5, "resource_id": 2, "offset": 110912,
         "arg_name": "UnityPerMaterial", "ir_arg_size": 336,
         "size_check": "ok"}
      ],
      "textures": [
        {"index": 0, "resource_id": 186, "arg_name": "_MainTex"},
        {"index": 1, "resource_id": 145, "arg_name": "_LightIndexMap"}
      ]
    }
  },
  "uniforms": [ /* when --with-uniforms */ ],
  "value_health_summary": {"nan_count": 1, "fields_with_nan": ["_FresnelColor"]}
}
```

**size_check values**: `"ok"` (available ≥ ir_size ≤ 4×) | `"under"` (true OOB) | `"over"` (borrows large section) | `null` (insufficient info).

**Why prefer this over manual join**:
- Automatically maps slot numbers to IR `arg_name` — no more slot mix-ups
- `size_check` flags OOB before you waste time on wrong hypotheses
- `value_health_summary` surfaces NaN/inf automatically

---

<a id="core-dump-uniforms"></a>
## 3. dump-uniforms

**Purpose**: Decode the actual bytes a shader saw at a specific buffer binding. Answers "what was `_MainLightPosition` at this draw?"

### By name (R8.3, recommended):
```bash
python3 "$WRAPPER" dump-uniforms <trace> <draw_index> 0 \
    --by-name <BINDING_NAME>    # e.g. "UnityPerMaterial"
    [--field <FIELD_SUBSTR>]    # filter decoded fields, e.g. "_FresnelColor"
    [--stage fragment|vertex]
```

### By slot (standard):
```bash
# Wrapper draw-mode (auto-resolves rps_key + buffer_key + offset):
python3 "$WRAPPER" dump-uniforms <trace> <draw_index> <bind_slot> \
    [--stage fragment|vertex]

# Bridge direct rps-mode (when you know the exact parameters):
"$BRIDGE" dump-uniforms <trace> <rps_key> <bind_slot> \
    [--stage fragment|vertex] \
    [--buffer-key K] [--offset N] \
    [--with-hex] [--max-hex-bytes N]
```

### Modes:
| Mode | Flags | Output |
|------|-------|--------|
| Layout-only | no `--buffer-key` (bridge-mode) | `layout` tree only — "what fields does the shader expect?" |
| Layout + decoded | with `--buffer-key K --offset N` | `layout` + `decoded` with actual values |
| Draw-mode (wrapper) | draw_index + slot | Auto-resolves everything, always decoded |
| By-name | `--by-name <NAME>` | Resolves name→slot via IR, then decodes |

### Output JSON:
```json
{
  "command": "dump-uniforms",
  "rps_key": 472, "stage": "fragment", "bind_slot": 0,
  "rps_label": "Papegame/Cloth/ClothStandard",
  "binding_name": "AsukaPerShader_PerCamera",
  "buffer_data_size": 144,
  "layout": {"_MainLightPosition": {"offset": 64, "data_type": "float4"}},
  "decoded": {"_MainLightPosition": {"offset": 64, "data_type": "float4",
              "value": [0.42, -0.85, 0.31, 0]}},
  "decoded_ok": true,
  "value_health_summary": {"nan_count": 0, "inf_count": 0, "denormal_count": 0}
}
```

### Data type conventions:
- Floats: `%.6g`; NaN → `"NaN"`, Infinity → `"Infinity"`
- Vectors: flat 1D array `[x, y, z, w]`
- Matrices: 2D array (row-major)
- Arrays: `{"length": L, "stride": S, "elements": [...]}` (truncated at 16 with `truncated: true`)
- Nested structs: recursive object

### Failure modes (exit 11):
| Error | Meaning |
|-------|---------|
| `rps_not_found` | Invalid rps_key |
| `reflection_not_captured` | Reflection unavailable; try `--with-hex --buffer-key K --offset N` as fallback |
| `bind_slot_not_in_reflection` | Shader has no binding at this (stage, slot) |
| `buffer_not_found` | Invalid buffer_key |
| `offset_out_of_range` | Offset exceeds buffer length |

---

# Supporting Commands

---

<a id="shader-of-drawcall"></a>
## 4. shader-of-drawcall (wrapper-only)

From draw index to shader IR + bindings + uniforms in one command.

```bash
python3 "$WRAPPER" shader-of-drawcall <trace> <draw_index> \
    [--stage fragment|vertex] [--with-ir] [--with-bindings] [--with-uniforms] \
    [--output-dir DIR]
```

- `--with-uniforms` implies `--with-bindings`.
- Internally: `frame-list` → `shader-of-rps` → (optional) `dump-uniforms` per slot.
- Out-of-range: exit 12 with `draw_index_out_of_range` (special hint for compute-only traces with `draw_count=0`).

Output includes: `shader_of_rps` (metallib/AIR/cacheKey/IR), `bindings`, `uniforms[]`, `uniforms_summary`.

---

<a id="replay"></a>
## 5. replay

Headless replay with resource inventory and export.

```bash
"$BRIDGE" replay <trace> [--bounds] [--playto N] [--list-resources] [--export ID PATH]
```

| Flag | Purpose |
|------|---------|
| `--bounds` | Probe `total_call_count` only (cheap) |
| `--playto N` | Replay up to call N (for bisecting). OOR → exit 12 |
| `--list-resources` | Append texture/buffer inventory |
| `--export ID PATH` | Dump one resource to disk (refuses depth/stencil). Auto-decompresses ASTC/BC/ETC via render pass. |

Key output fields: `success`, `elapsed_ms`, `resource_count`, `total_call_count`, `last_call_index`.

Resource entries include full Metal metadata: `storageMode`, `cpuCacheMode`, `hazardTrackingMode`, `usage[]`, `isDepthStencil`, `compressed`, `block_size`, `label`.

**R11 export output fields** (when `--export` succeeds):
- `export_id`, `export_path`, `export_bytes` — basic export info
- `export_verification` — auto-integrity check:
  - `all_zero` (bool): true means export is all zeros (decompression failure / empty texture)
  - `non_zero_pct` (float): percentage of non-zero bytes in sampled region
  - `size_match` (bool): file size == expected bytes
  - `warnings[]` (string array): structured alerts for common issues
- `export_meta_path` — path to the `.meta.json` sidecar file containing format metadata (width, height, bytes_per_pixel, bytes_per_row, original/output pixel format, was_decompressed, channel_order)

---

<a id="pipeline"></a>
## 6. pipeline

Enumerate all libraries, RPS, compute PSO, and functions. Exports `.metallib` + `.air` files.

```bash
"$BRIDGE" pipeline <trace> [output_dir]
```

Key output: `libraries[]`, `render_pipeline_states[]` (with R7.2 shader correlation: `vertex/fragment_function_key`, `vertex/fragment_library_key`, `color_attachments[]`, `depth_format`, `raster_sample_count`), `rps_correlated_count`.

Health check: `rps_correlated_count` should equal `render_pipeline_states_count`.

---

<a id="frame-list"></a>
## 7. frame-list

Full frame timeline: command buffers → encoders → draws + draw→RPS map + per-draw bindings.

```bash
"$BRIDGE" frame-list <trace> [--no-draws] [--no-bindings] [--with-timing]
```

Default: `--with-draws --with-bindings`. Per-draw bindings add ~3× JSON size (LYSK: 390KB vs 105KB); use `--no-bindings` when only the RPS map is needed.

Key output: `command_buffers[].encoders[].draws[]`, `draw_to_rps_map[]` (flat: draw_index → rps_key).

Each draw has `bindings.{vertex,fragment}.{buffers,textures,samplers}[]` with `resource_id`, `offset`, or `inline_bytes_size`.

---

<a id="shader-of-rps"></a>
## 8. shader-of-rps

Reverse-lookup: RPS key → fragment/vertex shader metallib + AIR + IR.

```bash
"$BRIDGE" shader-of-rps <trace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
```

R7.7: auto-fallback from `bitcodeData` to PlayCover `ShaderDebugInfo/module.bc` (LYSK 100% IR coverage). `ir_source` field reports which path was used.

---

<a id="disasm"></a>
## 9. disasm

Direct library_key → IR (skip the RPS detour). Same SDI fallback as `shader-of-rps`.

```bash
"$BRIDGE" disasm <trace> <key> [--key-type library|rps] [--with-ir] [--output-dir DIR]
```

`--key-type rps` forwards to `shader-of-rps` internally.

---

<a id="shader"></a>
## 10. shader (hot-replace)

Replace a library in-memory and optionally re-replay to verify.

```bash
"$BRIDGE" shader <trace> <lib_key> <metallib_path> [--verify]
"$BRIDGE" shader <trace> <lib_key> --source <msl_path> [--verify]
```

Replacement is in-memory only — `.gputrace` on disk is never modified. Function names must match originals.

---

<a id="config"></a>
## 11. config

Toggle replay configuration knobs (A/B testing).

```bash
"$BRIDGE" config <trace> [disableOptimizeRestores=0|1] [forceLoadUnusedResources=0|1] [enableValidation=0|1]
```

Typical use: `disableOptimizeRestores=0` for 3–6× faster replays; `enableValidation=1` to surface Metal API misuse.

---

<a id="diagnose"></a>
## 12. diagnose (wrapper-only, R12.2)

**Purpose**: One-command health check for bridge + trace. Run after Setup to confirm everything is operational, or when something goes wrong to identify the failure point.

```bash
python3 "$WRAPPER" diagnose <trace>
```

**Output JSON**:

```json
{
  "bridge_ok": true,
  "bridge_path": "/path/to/gputrace_replay_bridge",
  "bridge_version_hash": "a1b2c3d4e5f6g7h8",
  "bridge_help_ok": true,
  "trace_path": "/path/to/capture.gputrace",
  "trace_exists": true,
  "trace_is_bundle": true,
  "replay_ok": true,
  "replay_elapsed_ms": 8234.5,
  "resource_count": 247,
  "total_call_count": 3425,
  "errors": []
}
```

**Exit code**: 0 if all checks pass, 1 if any check fails (errors[] non-empty).

**Check sequence**: bridge binary exists → bridge `help` works → trace path valid → replay succeeds → resource count.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Wrong CLI usage |
| 2 | Invalid input (bad trace path) |
| 3–9 | Environment/framework failures (re-run `setup.sh`) |
| 10 | Replay failed |
| 11 | Subcommand-specific failure |
| 12 | Out-of-range (playto / draw_index) |
| 124 | Subprocess timeout (wrapper only) |

---

## Python Wrapper — CLI Mode

```bash
python3 gputrace_replay_wrapper.py [--bridge PATH] [--timeout N] [--pretty] <command> [args]
```

Subcommands: `help`, `replay`, `pipeline`, `shader`, `shader-of-rps`, `frame-list`, `shader-of-drawcall`, `disasm`, `dump-uniforms`, `draw-info`, `find-draws`, `config`, `diagnose`.

---

## Python Wrapper — Module Mode

```python
import sys; sys.path.insert(0, "$SKILL_DIR/scripts")
from gputrace_replay_wrapper import ReplayBridge, BridgeError, DrawIndexOutOfRange

bridge = ReplayBridge()  # auto-locates binary

# Key methods (all return typed dataclasses):
bridge.find_draws(trace, by_label="...", show_first=True, show_first_with_ir=True)
bridge.draw_info(trace, draw_index, with_uniforms=True)
bridge.dump_uniforms_by_name(trace, draw_index, name="UnityPerMaterial", field="_FresnelColor")
bridge.shader_of_drawcall(trace, draw_index, with_ir=True, with_uniforms=True)
bridge.replay(trace, list_resources=True)
bridge.pipeline(trace, output_dir)
bridge.frame_list(trace)
bridge.shader_of_rps(trace, rps_key, with_ir=True)
bridge.disasm(trace, library_key, with_ir=True)
bridge.shader(trace, lib_key, metallib_path, verify=True)
bridge.config(trace, enable_validation=True)
bridge.diagnose(trace)  # returns dict with bridge_ok, replay_ok, errors[]
```

Key dataclasses: `FindDrawsResult`, `DrawInfoResult`, `DumpUniformsResult`, `ShaderOfDrawcallResult`, `ReplayResult`, `PipelineResult`, `FrameListResult`, `ShaderOfRpsResult`, `ConfigResult`.

All dataclasses keep `.raw` for the original parsed JSON.
