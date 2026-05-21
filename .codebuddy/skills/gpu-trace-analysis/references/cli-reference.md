# CLI & API Reference

Complete surface for the bundled tools. Skim the table of contents and jump to what you need — you don't need to read top-to-bottom.

## Table of contents
1. [The bridge binary](#the-bridge-binary)
2. [Subcommand: replay](#subcommand-replay)
3. [Subcommand: pipeline](#subcommand-pipeline)
4. [Subcommand: shader](#subcommand-shader)
5. [Subcommand: shader-of-rps](#subcommand-shader-of-rps)
6. [Subcommand: frame-list](#subcommand-frame-list)
7. [Subcommand: shader-of-drawcall (wrapper-only)](#subcommand-shader-of-drawcall-wrapper-only)
8. [Subcommand: config](#subcommand-config)
9. [Exit codes](#exit-codes)
10. [Python wrapper — CLI mode](#python-wrapper--cli-mode)
11. [Python wrapper — module mode](#python-wrapper--module-mode)
12. [Pixel format helpers](#pixel-format-helpers)

---

## The bridge binary

`scripts/gputrace_replay_bridge` is a single ObjC binary built from `gputrace_replay_bridge.m`. After running `setup.sh`, invoke it with one of seven subcommands. Output is always one JSON object on stdout per invocation; diagnostic messages go to stderr.

```bash
gputrace_replay_bridge <command> [args...]
```

Available commands: `help`, `replay`, `pipeline`, `shader`, `shader-of-rps`, `frame-list`, `config`.

`help` prints the JSON schema of all commands:

```bash
gputrace_replay_bridge help
# → {"tool":"gputrace_replay_bridge","version":"0.4.0","commands":[...]}
```

---

## Subcommand: replay

Headless replay of a `.gputrace`. Returns timing, replay return code, and (optionally) a resource inventory or a single resource exported to a file.

```bash
gputrace_replay_bridge replay <path-to-.gputrace> [options]
```

Options:

| Flag | Semantics |
|---|---|
| `--bounds` | Probe the trace's `total_call_count` and exit. Internally runs a single `playAll` then reads the controller's last-played call index. Useful before issuing `--playto N` to know the valid range. (R7.1) |
| `--playto N` | Replay up to call index N instead of the full frame. Useful for bisecting which call introduces a defect. Default: `playAll`. **Bounds-checked since R7.1**: if N exceeds `total_call_count`, the bridge returns a structured `playto_out_of_range` error (exit 12) rather than crashing. |
| `--list-resources` | Append a `resources` array to the JSON output describing every texture and buffer in the post-replay ObjectMap. Each entry now includes full Metal property metadata (storage mode, hazard tracking, usage flags, etc.) — see resource entry schema below. (R7.1) |
| `--export ID PATH` | Dump resource with the given numeric ID to `PATH`. For 2D textures: pixel-perfect raw bytes via `getBytes:`. For buffers: `[buf contents]` memcpy'd to disk. Depth/stencil and non-2D texture types refuse to export and emit `export_error`. |

Output JSON (top-level fields):

| Field | Type | Notes |
|---|---|---|
| `command` | string | Always `"replay"` |
| `trace_path` | string | Echo of the input path |
| `device` | string | `MTLDevice.name`, e.g. `"Apple M4 Pro"` |
| `bounds_only` | bool? | Present (and `true`) iff `--bounds` was used (R7.1) |
| `playto_index` | int? | Present iff `--playto` was used |
| `replay_rc` | int | Underlying `playAll`/`playTo` return code; 0 = success |
| `replay_signal` | int? | Present if a SIGSEGV/SIGBUS was caught and recovered (R7.1) |
| `success` | bool | `replay_rc == 0` |
| `elapsed_ms` | float | Wall-clock host timing of the replay call |
| `resource_count` | int | Size of `objectMap.resources` after replay |
| `total_call_count` | int | The trace's total call count (last play index after `playAll`). **Always emitted** since R7.1. |
| `last_call_index` | int | The controller's last-played call index after the requested replay action — equals `total_call_count` after default `playAll`, equals N after a successful `--playto N`. (R7.1) |
| `resources` | array? | Present iff `--list-resources` |
| `export_id`, `export_path`, `export_bytes` | mixed? | Present on successful export |
| `export_error` | string? | Present on export failure with a human-readable cause |
| `error` | string? | Present iff a non-fatal structured error occurred (e.g. `"playto_out_of_range"`, `"bounds_probe_failed"`) (R7.1) |
| `max` | int? | Present alongside `error: "playto_out_of_range"`; equals `total_call_count` (R7.1) |

Resource entry shape (textures, R7.1 — full metadata):

```json
{
  "id": 17,
  "type": "texture",
  "width": 1024, "height": 1024, "depth": 1,
  "pixelFormat": 70, "pixelFormatName": "BGRA8Unorm",
  "textureType": "2D",
  "mipmapLevelCount": 1,
  "sampleCount": 1,
  "arrayLength": 1,
  "storageMode": "shared",
  "cpuCacheMode": "default",
  "hazardTrackingMode": "tracked",
  "usage": ["shaderRead", "renderTarget"],
  "framebufferOnly": false,
  "memoryless": false,
  "isDepthStencil": false,
  "label": "GBuffer.Albedo"
}
```

`storageMode` is one of `shared`/`managed`/`private`/`memoryless`/`other`. `cpuCacheMode` is `default`/`writeCombined`/`other`. `hazardTrackingMode` is `default`/`untracked`/`tracked`/`other`. `usage` is the decomposed `MTLTextureUsage` bitmask as a JSON string array; an empty array means `MTLTextureUsageUnknown`. `memoryless` is a convenience boolean (`storageMode == memoryless`). `isDepthStencil` mirrors the bridge's internal classification used by `--export` to refuse depth/stencil dumps.

Resource entry shape (buffers, R7.1 — full metadata):

```json
{
  "id": 3,
  "type": "buffer",
  "length": 1024,
  "storageMode": "shared",
  "cpuCacheMode": "default",
  "hazardTrackingMode": "tracked",
  "label": "ConstantBuffer"
}
```

### Bounds and out-of-range behavior (R7.1)

The bridge always knows `total_call_count` because every `replay` invocation begins with an internal `playAll` (which doubles as a sanity check that the trace replays cleanly).

- `replay <trace>` — defaults to that internal `playAll` and reports `total_call_count` and `last_call_index` (equal after `playAll`).
- `replay <trace> --bounds` — same probe but returns immediately afterward, no resource enumeration; cheap way to learn the range before scripting `--playto`.
- `replay <trace> --playto N` with `N <= total_call_count` — `rewind`s the controller and runs `playTo(N)`; `last_call_index == N` on success.
- `replay <trace> --playto N` with `N > total_call_count` — returns

```json
{
  "command": "replay",
  "trace_path": "...",
  "error": "playto_out_of_range",
  "playto_index": 99999999,
  "total_call_count": 3425,
  "max": 3425
}
```

with exit code 12 (`EXIT_PLAYTO_OOR`). Older bridge revisions would SIGSEGV in this scenario.

For defense in depth, both `playAll` and `playTo` invocations are wrapped in a `setjmp`/SIGSEGV/SIGBUS handler. If the framework ever does crash anyway, the bridge surfaces `replay_signal` in the JSON instead of letting the process die.

---

## Subcommand: pipeline

Enumerates every library, render pipeline state, compute pipeline state, and Metal function visible to the replay. For each library, exports `library_<key>.metallib` and (when available) `library_<key>.air` to the output directory.

```bash
gputrace_replay_bridge pipeline <path-to-.gputrace> [output_dir]
```

If `output_dir` is omitted the current working directory is used. The directory is created if needed.

Output JSON top-level fields (in addition to the obvious `trace_path` / `device` / `output_dir`):

| Field | Type | Description |
|---|---|---|
| `libraries` | array | Per-library record (see below) |
| `render_pipeline_states` | array | Per-RPS record (see below). Since R7.2 each entry includes RPS↔shader correlation when the bridge swizzle captured the descriptor. |
| `compute_pipeline_states` | array | `{key, class, label?}` |
| `functions` | array | `{key, class, name?, functionType, functionTypeStr}` |
| `libraries_count` | int | Total libraries discovered |
| `metallibs_exported` | int | How many `.metallib` files were written |
| `bitcodes_exported` | int | How many `.air` files were written (some libs lack AIR) |
| `render_pipeline_states_count`, `compute_pipeline_states_count`, `functions_count` | int | Totals matching their arrays |
| `rps_correlated_count` | int | R7.2 — how many enumerated RPS got their descriptor matched via the swizzle. Healthy traces should have this equal to `render_pipeline_states_count`. |
| `rps_captured_count` | int | R7.2 — how many `(descriptor, rps)` pairs the swizzle captured during replay. May be larger than `render_pipeline_states_count` when the trace creates RPS objects that don't end up keyed in the replay objectMap. **If this is `0` while `render_pipeline_states_count > 0`, the swizzle is broken** (e.g. macOS update changed the device class hierarchy). |

Per-library record:

```json
{
  "key": 248,
  "class": "_MTLLibrary",
  "function_count": 1,
  "functions": ["fragment_skin_subsurface"],
  "installName": "default.metallib",
  "label": null,
  "metallib_size": 4577,
  "metallib_magic": "0x424C544D",
  "metallib_file": "library_248.metallib",
  "bitcode_size": 3920,
  "bitcode_magic": "0x0B17C0DE",
  "bitcode_file": "library_248.air"
}
```

Per-render-pipeline-state record (R7.2 — extended with shader correlation when descriptor was captured):

```json
{
  "key": 484,
  "class": "AGXG16XFamilyRenderPipeline",
  "label": "Papegame/SkinMakeupNew",

  "vertex_function_key": 289,
  "fragment_function_key": 357,
  "vertex_library_key": 288,
  "fragment_library_key": 356,
  "vertex_function_name": "xlatMtlMain1",
  "fragment_function_name": "xlatMtlMain",

  "color_attachment_count": 2,
  "color_attachments": [
    {"index": 0, "format": "RGBA8Unorm", "pixelFormat": 70, "writeMask": "RGBA", "blendingEnabled": false},
    {"index": 1, "format": "RGBA8Unorm", "pixelFormat": 70, "writeMask": "RGBA", "blendingEnabled": false}
  ],
  "depth_format": "Depth32Float_Stencil8",
  "depth_format_value": 260,
  "stencil_format": "Depth32Float_Stencil8",
  "stencil_format_value": 260,
  "raster_sample_count": 1
}
```

The R7.2 fields are present **only** when the bridge's method swizzle on `MTLDevice newRenderPipelineStateWithDescriptor:*` captured this RPS at PSO-creation time. If a RPS is enumerable in the objectMap but absent from the swizzle table, only the basic three fields (`key`, `class`, `label`) appear.

Library-key convention: `library_key = function_key - 1` (validated empirically across ~100 LYSK trace shaders; a fallback even-key downward scan is used if the convention happens to be broken in a specific trace).

Magic-number sanity checks on exported library files:
- metallib: `0x424C544D` (`"BLTM"` little-endian, "Metal Library Binary")
- AIR bitcode: `0x0B17C0DE` (LLVM bitcode wrapper)

Verify exported files with `file <path>`:
```
library_248.metallib: MetalLib executable, version 1.2.6
library_248.air:      LLVM bitcode, wrapper
```

Library/function key relationship: libraries occupy even keys, the matching MTLFunction is at the next odd key (e.g. library 248 ↔ function 249). Pipeline states use a separate continuous key range that is typically larger than function keys; the bridge scans it with extra headroom (function-max + 250) to avoid silent truncation.

---

## Subcommand: shader

Hot-replaces a library in the in-memory ObjectMap with new bytecode or freshly compiled MSL source, then optionally re-runs the full replay to see the effect.

```bash
# Replace from a metallib binary on disk
gputrace_replay_bridge shader <trace> <lib_key> <metallib_path> [--verify]

# Replace by compiling MSL source at runtime
gputrace_replay_bridge shader <trace> <lib_key> --source <msl_path> [--verify]
```

The replacement only persists for the lifetime of this single bridge invocation — the original `.gputrace` on disk is never modified. To make a permanent change you'd need to rebuild the trace upstream; this skill is for investigation, not patching.

`--verify`: after `setLibrary:forKey:`, the bridge calls `rewind` then `playAll` again and reports whether the modified replay still succeeds.

Output JSON:

```json
{
  "command": "shader",
  "trace_path": "...",
  "library_key": 248,
  "replacement_done": true,
  "original": {
    "exists": true,
    "metallib_size": 4577,
    "functions": ["fragment_skin_subsurface"]
  },
  "replacement": {
    "metallib_size": 4577,
    "metallib_path": "/tmp/.../library_248.metallib",
    "functions": ["fragment_skin_subsurface"]
  },
  "verify": { "playAll_rc": 0, "success": true, "elapsed_ms": 7.2 }
}
```

Notes:
- The replacement library's function names should generally match the originals; if not, downstream `MTLFunction` lookups will fail at the next pipeline-state creation. Use `pipeline` first to confirm the original function name.
- For an MSL-source replacement, the bridge calls `newLibraryWithSource:options:error:` with default `MTLCompileOptions` — match the original target if you need feature parity.

---

## Subcommand: shader-of-rps

Reverse-lookup the fragment or vertex shader of a render pipeline state. This is the **R7.4** "one command, one IR file" entry point — the user gives a `rps_key` (from `pipeline` output) and the bridge produces metallib, AIR, and (optionally) LLVM IR `.ll`.

```bash
gputrace_replay_bridge shader-of-rps <.gputrace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
```

Internally this:
1. Installs the same swizzle as `pipeline` so descriptors are captured during replay.
2. Runs `playAll` once.
3. Looks up the RPS by key in the objectMap, then finds its captured descriptor.
4. Resolves the chosen stage's `MTLFunction` pointer to a function key via `objectMap.functionMap` reverse map.
5. Computes `library_key = function_key - 1` (with even-key fallback scan).
6. Dumps the library's `metallib` data via `libraryDataContents` (and `bitcodeData` AIR when available).
7. Computes the PlayTools `cacheKey` on the metallib bytes (matches the algorithm used by the offline `extract_shader_raw.py` tool — see [investigation playbook §3.1](./investigation-playbook.md) for the full reference).
8. With `--with-ir`: pipes the AIR through `llvm-dis` (auto-detected from Homebrew or `$PATH`) to produce a `.ll` file.

Defaults:
- `--stage fragment`
- `--output-dir` = system temp directory (e.g. `/var/folders/.../T/`)

Output JSON (success path):

```json
{
  "command": "shader-of-rps",
  "trace_path": "...",
  "rps_key": 484,
  "stage": "fragment",
  "output_dir": "/tmp/r74",
  "rps_label": "Papegame/SkinMakeupNew",
  "function_name": "xlatMtlMain",
  "function_key": 357,
  "library_key": 356,
  "library_metallib_path": "/tmp/r74/library_356.metallib",
  "library_metallib_size": 4593,
  "library_air_path": "/tmp/r74/library_356.air",
  "library_air_size": 3920,
  "cache_key_metallib": "636181106F7E31A0_4593",
  "ir_ll_path": "/tmp/r74/library_356.ll",
  "ir_ll_size": 3257,
  "ir_dis_path": "/opt/homebrew/opt/llvm/bin/llvm-dis"
}
```

Failure modes (all emit valid JSON; exit code is 11 = `SUBCMD_FAIL`):

| `error` | Meaning |
|---|---|
| `rps_not_found` | The given `rps_key` is not present in the trace's objectMap. Check `rps_captured_count` to see if the swizzle worked at all. |
| `descriptor_not_captured` | The RPS exists in the objectMap but the swizzle didn't capture it at PSO creation time (this should not happen on a healthy run; if it does, the swizzle install path is broken). |
| `stage_function_absent` | The descriptor has no function for the requested stage (e.g. `--stage fragment` on a depth-only / vertex-only RPS). |
| `function_key_unresolved` | The captured function pointer isn't present in `objectMap.functionMap` — usually a sign the trace is in an inconsistent state. |
| `library_key_unresolved` | `function_key=0` makes `library_key=-1`, an invalid case — should never happen for legitimate traces. |
| `library_not_found` | Neither the `function_key - 1` convention nor the even-key downward scan found a `MTLLibrary` for this RPS. |

`--with-ir` substitutes `ir_error` with one of:

| `ir_error` | Meaning | `ir_hint` |
|---|---|---|
| `no_air_bitcode` | Library doesn't expose `bitcodeData`. Many `_MTLLibrary` instances have only metallib, not AIR. | (none) |
| `llvm_dis_not_found` | Bridge couldn't locate `llvm-dis` on Homebrew or PATH. | `install via 'brew install llvm' (Apple toolchain lacks llvm-dis)` |
| `llvm_dis_failed` | `llvm-dis` ran but exited non-zero. `ir_dis_rc` and `ir_dis_stderr` are populated for debugging. | (none) |

The cacheKey can be used to find the corresponding ShaderDebugInfo directory under `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cache_key>/`, which holds the original compile-time `module.bc` for cross-referencing — see [investigation playbook §3](./investigation-playbook.md).

---

## Subcommand: frame-list

Replays the trace once with public-API method swizzling armed and emits the full `command_buffer → encoder → draw` timeline plus a flat `draw_to_rps_map[]`. This is the **R7.3** "frame inspector" entry point — the equivalent of expanding the encoder/draw tree in Xcode's Frame Debugger UI, but as a shell-pipe-able JSON document.

```bash
gputrace_replay_bridge frame-list <.gputrace> [--with-draws] [--no-draws] [--with-timing]
```

| Flag | Default | Meaning |
|---|---|---|
| `--with-draws` | on | Include per-encoder `draws[]` records and the top-level `draw_to_rps_map[]` view. The default; pass explicitly only for symmetry with `--no-draws`. |
| `--no-draws` | off | Suppress per-draw records (encoder list only). Useful for very high-draw-count traces or when you only need the encoder timeline. |
| `--with-timing` | off | Populate per-cb `gpu_start_ms` / `gpu_end_ms` / `gpu_duration_ms` from `MTLCommandBuffer.GPUStartTime/GPUEndTime`. Replay-internal CBs that never `commit` will surface `null` here. |

Output JSON top-level fields:

| Field | Type | Notes |
|---|---|---|
| `command` | string | Always `"frame-list"` |
| `trace_path`, `device` | string | Echo + `MTLDevice.name` |
| `replay_rc`, `success`, `elapsed_ms`, `total_call_count` | mixed | Same semantics as `replay` |
| `with_draws`, `with_timing` | bool | Echoes the requested mode |
| `command_buffer_count`, `encoder_count`, `draw_count` | int | Aggregate counts captured during this `playAll` |
| `rps_correlated_count` | int | How many RPS keys were resolvable from the captured RPS pointer table — used to validate R7.2 swizzle health |
| `command_buffers` | array | Tree, see below |
| `draw_to_rps_map` | array | Present iff `--with-draws`; flat `(draw_index_global → rps_key)` records for direct chaining into `shader-of-rps` |

`command_buffers[i]`:

```json
{
  "index": 1,
  "label": "Frame Render",
  "encoder_count": 30,
  "gpu_start_ms": 0.0,             // present iff --with-timing; may be 0/null
  "gpu_end_ms": 0.32,
  "gpu_duration_ms": 0.32,
  "encoders": [ ... ]
}
```

`encoders[j]` for `type == "render"`:

```json
{
  "index": 2,
  "type": "render",
  "label": "Shadows.Draw",
  "first_call_index": 125,
  "last_call_index": 451,
  "draw_count": 30,
  "color_attachment_count": 0,
  "color_attachments": [],
  "depth_attachment": {"texture_id": 225, "pixelFormat": 252, "format": "Depth32Float"},
  "stencil_attachment": null,
  "draws": [
    {
      "draw_index_global": 0,
      "draw_in_encoder": 0,
      "call_index": 131,
      "primitive_type": 3,
      "primitive_type_name": "triangle",
      "vertex_count": 0,
      "instance_count": 1,
      "indexed": true,
      "index_count": 6726,
      "rps_key": 472,
      "rps_label": "Papegame/Cloth/ClothStandard",
      "fragment_function_key": 375
    },
    ...
  ]
}
```

`encoders[j]` for `type == "compute"` adds `compute_dispatch_count` (current implementation records dispatches as future work; the encoder is still listed so downstream tools can branch on type without parsing the call index).

`encoders[j]` for `type == "blit"` carries no attachments and no draws — the call window (`first/last_call_index`) is enough to identify the blit's place in the timeline.

`draw_to_rps_map[k]`:

```json
{"draw_index_global": 0, "encoder_index": 2, "draw_in_encoder": 0, "call_index": 131, "rps_key": 472}
```

This array is the simplest entry point for the user-level question "which shader does draw N use?" — feed `rps_key` straight into `shader-of-rps`.

### Implementation notes

- Swizzles are installed on `MTLCommandQueue.commandBuffer*`, `MTLCommandBuffer.{render,compute,blit}CommandEncoder*`, and `MTLRenderCommandEncoder.{setRenderPipelineState:, drawPrimitives:*, drawIndexedPrimitives:*, endEncoding}`. The render-encoder swizzles are installed lazily on first encoder creation, since the concrete encoder class is not known up front.
- Capture is gated to the actual `playAll` traversal — a process-global flag is opened immediately before `playAll` and closed after. Throwaway CBs/encoders the framework creates during `makeController` are filtered out.
- `first_call_index` / `last_call_index` come from `*(uint32_t *)(controller + 0x5810)` (R7.1's controller offset), read synchronously inside each swizzle thunk.
- The render encoder's `color_attachments[]` / `depth_attachment` / `stencil_attachment` are snapshotted at encoder begin from the `MTLRenderPassDescriptor`. Attachment `texture_id` references match the IDs surfaced by `replay --list-resources`.
- `rps_key` for each draw is resolved by combining: (a) R7.3's `current_rps_ptr` tracked across `setRenderPipelineState:` and `drawXXX:` calls inside the encoder, with (b) a `(rps_ptr → rps_key)` map built post-replay by probing `objectMap.renderPipelineStateForKey:` over the same key range `pipeline` uses.

### Health checks / invariants

After `frame-list` completes, the following invariants hold on any healthy run:

- `sum(encoder.draw_count) == draw_count == len(draw_to_rps_map)`
- For every entry in `draw_to_rps_map[]`, `rps_key` is non-null when the trace's draws all hit pipeline states captured by the R7.2 swizzle (LYSK trace baseline: 244/244 = 100%).
- `rps_correlated_count` should equal the number of `render_pipeline_states` returned by `pipeline` — they share the same swizzle health gate.

If any of these fails, the swizzle install path is broken (likely a macOS update changed the implementation class hierarchy); inspect stderr and re-run `setup.sh`.

### Per-encoder GPU timing caveat

`--with-timing` reads `MTLCommandBuffer.GPUStartTime` and `GPUEndTime`. Replay-internal command buffers may never `commit`, in which case both properties remain 0 and the JSON reports `gpu_duration_ms: null`. For accurate host-side per-segment timing, prefer `replay --playto N` bisection (see investigation playbook Pattern 4). This flag is provided primarily so callers can check whether the replay framework happens to surface valid timing for a given trace — when it does, it's "free".

---

## Subcommand: shader-of-drawcall (wrapper-only)

**R7.6-C** thin封装 — symmetric counterpart of `shader-of-rps`. Mental model: "I know the **draw index**, give me its shader IR." Equivalent to `frame-list <trace> | jq '.draw_to_rps_map[N].rps_key'` piped into `shader-of-rps`, but as a single command with proper structured-error handling for the compute-only / out-of-range edge cases.

Lives in the Python wrapper only — the bridge binary is **unchanged**. Run via:

```bash
python3 scripts/gputrace_replay_wrapper.py shader-of-drawcall <.gputrace> <draw_index> \
    [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
```

Internally:

1. Calls `frame-list` (with `--with-draws`, no timing) to obtain `draw_to_rps_map[]`.
2. Reads `draw_to_rps_map[draw_index]` for the `(rps_key, encoder_index, draw_in_encoder, call_index)` tuple, plus walks the `command_buffers` tree to recover `rps_label`.
3. Calls `shader-of-rps <rps_key> --stage <stage> [--with-ir] [--output-dir DIR]` and embeds the full result.

Output JSON top-level fields:

| Field | Type | Notes |
|---|---|---|
| `command` | string | Always `"shader-of-drawcall"` |
| `trace_path`, `draw_index`, `stage`, `output_dir` | echo | Echo of inputs |
| `encoder_index`, `draw_in_encoder`, `call_index`, `rps_key`, `rps_label` | mixed | Resolved from `frame-list` |
| `shader_of_rps` | object | Full `shader-of-rps` JSON (metallib path/size, AIR path/size, cacheKey, IR `.ll` path/size, structured errors). May be `null` only if `error == "draw_has_no_rps_key"` (swizzle gap on this draw). |
| `error` | string? | Surfaces lookup failures uniformly: `"draw_has_no_rps_key"` (rare; swizzle health gap), or any `shader-of-rps` error string (`rps_not_found` / `descriptor_not_captured` / `stage_function_absent` / `no_air_bitcode` / `llvm_dis_not_found`) |
| `hint` | string? | Human-readable hint paired with `error` |

### Out-of-range / invalid-input handling

| Input | Behavior |
|---|---|
| `draw_index >= draw_count` (incl. compute-only traces with `draw_count == 0`) | exit **12** + structured `{"error":"draw_index_out_of_range","draw_index":N,"draw_count":K,"hint":"..."}` (with a special hint when `draw_count == 0` explaining the trace is compute-only). Module API raises `DrawIndexOutOfRange`. |
| `draw_index < 0` | Module API raises `ValueError` (CLI exit 2 via the wrapper's catch-all). |
| `--stage geometry` (or any non-`fragment`/`vertex`) | Module API raises `ValueError`; CLI argparse rejects before the call. |
| Soft failure on the `shader-of-rps` half (`rps_not_found` etc.) | The wrapper still prints the full payload (with `error` / `hint`) and exits **11**, mirroring `shader-of-rps` behavior. |
| Bridge subprocess error (exit 4–10) | Re-raised as `BridgeError`; CLI maps to that exit code. |

### Equivalence guarantee

For any `draw_index` where `frame-list`'s `draw_to_rps_map[draw_index].rps_key == K`, the produced `metallib`, `AIR`, and `cacheKey` are **byte-identical** to running `shader-of-rps <K>` directly. The disassembled `.ll` output differs only in the `; ModuleID = '...air'` header comment because `llvm-dis` writes the temporary input path; everything past that line is identical. (Verified via the LYSK regression baseline at `draw_index=103 → rps_key=444 → library_276`, `metallib`/`AIR`/`cacheKey` `cmp -s` clean; `.ll` diff limited to one comment line.)

### Sample call (LYSK trace)

```bash
TRACE=/Users/<you>/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
WRAPPER=$SKILL_DIR/scripts/gputrace_replay_wrapper.py
OUT=$(mktemp -d)

python3 "$WRAPPER" shader-of-drawcall "$TRACE" 0 --with-ir --output-dir "$OUT" --pretty
# → {"command":"shader-of-drawcall","draw_index":0,
#    "encoder_index":2,"draw_in_encoder":0,"call_index":144,
#    "rps_key":472,"rps_label":"Papegame/Cloth/ClothStandard",
#    "shader_of_rps":{ ...metallib_path, cache_key_metallib, ir_error?... }}

python3 "$WRAPPER" shader-of-drawcall "$TRACE" 99999999 --pretty
# → exit 12, {"error":"draw_index_out_of_range","draw_index":99999999,"draw_count":244,"hint":"..."}
```

---

## Subcommand: config

Runs a complete replay with one of three knobs flipped, isolating their individual effect. Each invocation creates a fresh replay context.

```bash
gputrace_replay_bridge config <path-to-.gputrace> [key=value ...]
```

| Key | Default | Effect when set to `1` |
|---|---|---|
| `disableOptimizeRestores` | `1` | Skip the call to `GTMTLReplayController_optimizeRestores`. Setting this to `0` enables restore optimization (typically 3–6× faster replays, useful for performance investigations). |
| `forceLoadUnusedResources` | `1` | Call `populateUnusedResources` so resources used only briefly still appear in `resources`. Setting to `0` reduces memory and lets you see only "live" resources. |
| `enableValidation` | `0` | Set the `g_runningValidationCI` global, enabling Metal's API validation layer for the replay. Setting to `1` will surface validation failures via stderr in the bridge process. |

Output JSON:

```json
{
  "command": "config",
  "trace_path": "...",
  "config": {
    "disableOptimizeRestores": false,
    "forceLoadUnusedResources": true,
    "enableValidation": true
  },
  "playAll_rc": 0,
  "success": true,
  "elapsed_ms": 8.2,
  "resource_count": 247
}
```

Use `config` to A/B different replay environments quickly — e.g. compare `enableValidation=0` vs `=1` to surface previously-silent Metal misuse.

---

## Exit codes

Both the bridge and the wrapper use the same numeric scheme:

| Code | Symbol | Meaning |
|---|---|---|
| 0 | OK | Success |
| 1 | USAGE_ERROR | Wrong CLI usage / unknown subcommand |
| 2 | BAD_INPUT | Invalid `.gputrace` path or missing/unreadable file |
| 3 | NO_METAL_DEVICE | `MTLCreateSystemDefaultDevice()` returned nil |
| 4 | DLOPEN_FAIL | Could not load `GPUToolsReplay.framework` |
| 5 | SYMBOL_RESOLVE_FAIL | Required private symbol not found (likely macOS update) |
| 6 | APR_FAIL | APR pool bootstrap failed |
| 7 | DATASOURCE_FAIL | `makeDataSource` returned NULL or threw |
| 8 | OBJECTMAP_FAIL | `GTMTLReplayObjectMap initWithDevice:` failed |
| 9 | CONTROLLER_FAIL | `makeController` returned NULL |
| 10 | REPLAY_FAIL | `playAll` / `playTo` returned non-zero |
| 11 | SUBCMD_FAIL | Subcommand-specific failure (shader compile, `shader-of-rps` lookup error, etc.) |
| 12 | PLAYTO_OOR | `--playto N` with N > `total_call_count` (graceful, structured error) |
| 124 | (wrapper only) | Subprocess timeout |

Codes 4–9 indicate the macOS or framework environment shifted under us — re-run `setup.sh` and consider checking for an OS update.

---

## Python wrapper — CLI mode

`scripts/gputrace_replay_wrapper.py` mirrors the bridge subcommand surface and adds pretty-printing.

```bash
python3 gputrace_replay_wrapper.py [global-opts] <command> [args]
```

Global options can appear before or after the subcommand thanks to the wrapper's parent-parser design:

| Flag | Default | Meaning |
|---|---|---|
| `--bridge PATH` | auto | Override binary lookup (otherwise the wrapper searches: same dir → `PATH`) |
| `--timeout N` | 300 | Subprocess timeout in seconds |
| `--pretty` / `-p` | off | 2-space indented JSON output |

Subcommands match the bridge 1-for-1:

```bash
python3 gputrace_replay_wrapper.py help --pretty
python3 gputrace_replay_wrapper.py replay <trace> --list-resources --pretty
python3 gputrace_replay_wrapper.py replay <trace> --playto 30
python3 gputrace_replay_wrapper.py replay <trace> --export 17 /tmp/tex.bin
python3 gputrace_replay_wrapper.py pipeline <trace> /tmp/out
python3 gputrace_replay_wrapper.py shader <trace> 248 /tmp/out/library_248.metallib --verify
python3 gputrace_replay_wrapper.py shader <trace> 248 --source /tmp/new.metal --verify
python3 gputrace_replay_wrapper.py shader-of-rps <trace> 484 --with-ir --output-dir /tmp/out
python3 gputrace_replay_wrapper.py frame-list <trace>
python3 gputrace_replay_wrapper.py frame-list <trace> --no-draws
python3 gputrace_replay_wrapper.py frame-list <trace> --with-timing --pretty
python3 gputrace_replay_wrapper.py shader-of-drawcall <trace> 0 --with-ir --output-dir /tmp/out
python3 gputrace_replay_wrapper.py config <trace> disableOptimizeRestores=0 enableValidation=1
```

On error, the wrapper prints a JSON diagnostic to stderr and uses an appropriate exit code.

For graceful structured failures (`shader-of-rps` rps_not_found / `replay --playto` out-of-range), the wrapper still prints the JSON payload to stdout and uses exit code 11/12 so callers see the diagnostic without needing to parse stderr.

---

## Python wrapper — module mode

For programmatic use, `import` the wrapper. All return values are typed dataclasses so you get IDE completion and avoid stringly-typed JSON juggling.

```python
import sys
sys.path.insert(0, "/path/to/skill/scripts")
from gputrace_replay_wrapper import ReplayBridge, BridgeError

bridge = ReplayBridge()           # auto-locates binary in same dir / PATH
# bridge = ReplayBridge("/explicit/path/gputrace_replay_bridge")

# replay
r = bridge.replay("/path/to/foo.gputrace", list_resources=True)
print(r.success, r.elapsed_ms, r.resource_count)
for res in r.resources:
    if res.type == "texture":
        print(res.id, res.pixel_format_name, f"{res.width}x{res.height}")

# pipeline + R7.2 RPS↔shader correlation
p = bridge.pipeline("/path/to/foo.gputrace", "/tmp/out")
print("RPS correlated:", p.rps_correlated_count, "/", p.rps_captured_count)
for ps in p.render_pipeline_states:
    if ps.fragment_function_key is not None:
        print(ps.key, ps.label, "frag=", ps.fragment_function_key,
              "lib=", ps.fragment_library_key, "depth=", ps.depth_format)

# R7.4 — RPS reverse-lookup → IR in one call
sor = bridge.shader_of_rps("/path/to/foo.gputrace", 484, with_ir=True, output_dir="/tmp/out")
if sor.error:
    print("lookup failed:", sor.error, sor.hint)
else:
    print(sor.function_name, "→", sor.library_metallib_path,
          "cacheKey=", sor.cache_key_metallib)
    if sor.ir_ll_path:
        print("LLVM IR:", sor.ir_ll_path, sor.ir_ll_size, "bytes")

# R7.3 — frame timeline + draw→RPS map
fl = bridge.frame_list("/path/to/foo.gputrace")
print("CBs:", fl.command_buffer_count, "encoders:", fl.encoder_count, "draws:", fl.draw_count)
for cb in fl.command_buffers:
    for enc in cb.encoders:
        if enc.type == "render" and enc.draw_count:
            first_draw = enc.draws[0]
            print(f"enc#{enc.index} {enc.label or ''} -> first draw rps_key={first_draw.rps_key}")
# Chain: pick the first draw's RPS, get its IR.
first = fl.draw_to_rps_map[0]
sor = bridge.shader_of_rps("/path/to/foo.gputrace", first.rps_key, with_ir=True, output_dir="/tmp/out")

# R7.6-C — same chain in one call (mirror of shader_of_rps for the "I know draw N" entry point)
from gputrace_replay_wrapper import DrawIndexOutOfRange
try:
    sod = bridge.shader_of_drawcall("/path/to/foo.gputrace", 0, with_ir=True, output_dir="/tmp/out")
    print(f"draw 0 → enc#{sod.encoder_index} rps={sod.rps_key} ({sod.rps_label})")
    if sod.shader and sod.shader.ir_ll_path:
        print("LLVM IR:", sod.shader.ir_ll_path, sod.shader.ir_ll_size, "bytes")
    elif sod.error:
        print("lookup failed:", sod.error, sod.hint)
except DrawIndexOutOfRange as e:
    print(f"trace only has {e.draw_count} draws; idx {e.draw_index} is out of range")

# shader hot-replace + verify
target = p.libraries[0]
s = bridge.shader("/path/to/foo.gputrace", target.key,
                  "/tmp/out/" + target.metallib_file, verify=True)
print("verify ok?", s.verify["success"], "elapsed", s.verify["elapsed_ms"])

# config
c = bridge.config("/path/to/foo.gputrace", enable_validation=True)
print(c.success, c.elapsed_ms)

# error handling
try:
    bridge.replay("/missing.gputrace")
except FileNotFoundError as e:
    print("user-side error:", e)
except BridgeError as e:
    print("bridge-side error:", e.exit_name, e.stderr)
```

Returned dataclasses (see `gputrace_replay_wrapper.py` for full field lists):

| Class | Notable fields |
|---|---|
| `HelpResult` | `tool`, `version`, `commands`, `raw` |
| `ReplayResult` | `success`, `elapsed_ms`, `resource_count`, `resources: list[Resource]`, `export_*` |
| `Resource` | `id`, `type`, `width/height/depth/pixel_format_name/texture_type` (texture) or `length` (buffer), `label` |
| `PipelineResult` | `libraries: list[Library]`, `render_pipeline_states`, `compute_pipeline_states`, `functions`, plus `*_count` totals; R7.2 adds `rps_correlated_count` / `rps_captured_count` |
| `Library` | `key`, `functions`, `metallib_size/file`, `bitcode_size/file`, `install_name`, `label` |
| `PipelineState` | `key`, `class_name`, `label`; R7.2 render-PSOs add `vertex_function_key` / `fragment_function_key` / `vertex_library_key` / `fragment_library_key` / `color_attachment_count` / `color_attachments: list[ColorAttachment]` / `depth_format` / `stencil_format` / `raster_sample_count` / `vertex_function_name` / `fragment_function_name` |
| `ColorAttachment` | `index`, `format`, `pixel_format`, `write_mask`, `blending_enabled` |
| `Function` | `key`, `name`, `function_type`, `function_type_str` |
| `ShaderResult` | `replacement_done`, `original`, `replacement`, `verify` |
| `ShaderOfRpsResult` (R7.4) | `rps_key`, `stage`, `function_key`, `function_name`, `library_key`, `library_metallib_path`, `library_air_path`, `cache_key_metallib`, `ir_ll_path`, `error?` (`rps_not_found` / `descriptor_not_captured` / `stage_function_absent` / ...) |
| `FrameListResult` (R7.3) | `command_buffer_count`, `encoder_count`, `draw_count`, `rps_correlated_count`, `total_call_count`, `with_draws`, `with_timing`, `command_buffers: list[FrameCommandBuffer]`, `draw_to_rps_map: list[FrameDrawToRps]` |
| `FrameCommandBuffer` | `index`, `label`, `encoder_count`, `gpu_start_ms?` / `gpu_end_ms?` / `gpu_duration_ms?`, `encoders: list[FrameEncoder]` |
| `FrameEncoder` | `index`, `type` (`render`/`compute`/`blit`), `label`, `first_call_index`, `last_call_index`, `draw_count`, `color_attachments: list[FrameAttachment]`, `depth_attachment?`, `stencil_attachment?`, `compute_dispatch_count?`, `draws: list[FrameDraw]` |
| `FrameDraw` | `draw_index_global`, `draw_in_encoder`, `call_index`, `primitive_type`, `primitive_type_name`, `vertex_count`, `instance_count`, `indexed`, `index_count?`, `rps_key?`, `rps_label?`, `fragment_function_key?` |
| `FrameAttachment` | `texture_id`, `pixel_format`, `format`, `index?` |
| `FrameDrawToRps` | `draw_index_global`, `encoder_index`, `draw_in_encoder`, `call_index`, `rps_key?` |
| `ShaderOfDrawcallResult` (R7.6-C) | `draw_index`, `stage`, `output_dir`, `encoder_index?`, `draw_in_encoder?`, `call_index?`, `rps_key?`, `rps_label?`, `shader: ShaderOfRpsResult?`, `error?` (`draw_has_no_rps_key` / forwarded from `shader-of-rps`), `hint?` |
| `DrawIndexOutOfRange(Exception)` (R7.6-C) | `draw_index`, `draw_count`, `trace_path` — raised by `shader_of_drawcall` when `draw_index >= draw_count` (incl. compute-only traces with `draw_count == 0`) |
| `ConfigResult` | `config: dict[str,bool]`, `success`, `elapsed_ms`, `resource_count` |
| `BridgeError(Exception)` | `exit_code`, `exit_name`, `stderr`, `command`, `args` |

Every dataclass also keeps the original parsed JSON in `.raw` for fields the wrapper doesn't surface explicitly.

---

## Pixel format helpers

When exporting a texture you need to know the bytes-per-pixel to interpret the dump. The bridge already computes this internally, but if you're slicing the binary in Python the conventions are:

| pixelFormat (numeric) | pixelFormatName | bytes/pixel |
|---|---|---|
| 1, 2, … | `R8Unorm`, `R8Snorm`, … | 1 |
| 25, 26, 30, 31, 70, 80 | `RG8Unorm`, `R16Float`, `R16Unorm`, `BGRA8Unorm`, … | 2 / 4 |
| 70, 71 | `BGRA8Unorm`, `BGRA8Unorm_sRGB` | 4 |
| 110, 111 | `RGBA16Float` | 8 |
| 125, 126 | `RGBA32Float` | 16 |

Depth/stencil formats (`Depth32Float`, `Stencil8`, `Depth32Float_Stencil8`, etc.) cannot be exported with the texture dump path — `getBytes:` is unsupported for these on Apple Silicon. The bridge will return `export_error: "depth/stencil format cannot be exported via getBytes"`. To inspect depth, sample it inside a shader and write to a color target, then export that.
