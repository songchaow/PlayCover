# CLI & API Reference

Complete surface for the bundled tools. Skim the table of contents and jump to what you need — you don't need to read top-to-bottom.

## Table of contents
1. [The bridge binary](#the-bridge-binary)
2. [Subcommand: replay](#subcommand-replay)
3. [Subcommand: pipeline](#subcommand-pipeline)
4. [Subcommand: shader](#subcommand-shader)
5. [Subcommand: config](#subcommand-config)
6. [Exit codes](#exit-codes)
7. [Python wrapper — CLI mode](#python-wrapper--cli-mode)
8. [Python wrapper — module mode](#python-wrapper--module-mode)
9. [Pixel format helpers](#pixel-format-helpers)

---

## The bridge binary

`scripts/gputrace_replay_bridge` is a single ObjC binary built from `gputrace_replay_bridge.m`. After running `setup.sh`, invoke it with one of five subcommands. Output is always one JSON object on stdout per invocation; diagnostic messages go to stderr.

```bash
gputrace_replay_bridge <command> [args...]
```

Available commands: `help`, `replay`, `pipeline`, `shader`, `config`.

`help` prints the JSON schema of all commands:

```bash
gputrace_replay_bridge help
# → {"tool":"gputrace_replay_bridge","version":"0.2.0","commands":[...]}
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
| `--playto N` | Replay up to draw-call index N instead of the full frame. Useful for bisecting which call introduces a defect. Default: `playAll`. |
| `--list-resources` | Append a `resources` array to the JSON output describing every texture and buffer in the post-replay ObjectMap. |
| `--export ID PATH` | Dump resource with the given numeric ID to `PATH`. For 2D textures: pixel-perfect raw bytes via `getBytes:`. For buffers: `[buf contents]` memcpy'd to disk. Depth/stencil and non-2D texture types refuse to export and emit `export_error`. |

Output JSON (top-level fields):

| Field | Type | Notes |
|---|---|---|
| `command` | string | Always `"replay"` |
| `trace_path` | string | Echo of the input path |
| `device` | string | `MTLDevice.name`, e.g. `"Apple M4 Pro"` |
| `playto_index` | int? | Present iff `--playto` was used |
| `replay_rc` | int | Underlying `playAll`/`playTo` return code; 0 = success |
| `success` | bool | `replay_rc == 0` |
| `elapsed_ms` | float | Wall-clock host timing of the replay call |
| `resource_count` | int | Size of `objectMap.resources` after replay |
| `resources` | array? | Present iff `--list-resources` |
| `export_id`, `export_path`, `export_bytes` | mixed? | Present on successful export |
| `export_error` | string? | Present on export failure with a human-readable cause |

Resource entry shape (textures):

```json
{
  "id": 17,
  "type": "texture",
  "width": 1024, "height": 1024, "depth": 1,
  "pixelFormat": 70, "pixelFormatName": "BGRA8Unorm",
  "textureType": "2D",
  "mipmapLevelCount": 1,
  "label": "GBuffer.Albedo"
}
```

Resource entry shape (buffers):

```json
{ "id": 3, "type": "buffer", "length": 1024, "label": "ConstantBuffer" }
```

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
| `render_pipeline_states` | array | `{key, class, label?}` |
| `compute_pipeline_states` | array | `{key, class, label?}` |
| `functions` | array | `{key, class, name?, functionType, functionTypeStr}` |
| `libraries_count` | int | Total libraries discovered |
| `metallibs_exported` | int | How many `.metallib` files were written |
| `bitcodes_exported` | int | How many `.air` files were written (some libs lack AIR) |
| `render_pipeline_states_count`, `compute_pipeline_states_count`, `functions_count` | int | Totals matching their arrays |

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

Magic-number sanity checks:
- metallib: `0x424C544D` (`"BLTM"` little-endian, "Metal Library Binary")
- AIR bitcode: `0x0B17C0DE` (LLVM bitcode wrapper)

Verify exported files with `file <path>`:
```
library_248.metallib: MetalLib executable, version 1.2.6
library_248.air:      LLVM bitcode, wrapper
```

Library/function key relationship: libraries occupy even keys, the matching MTLFunction is at the next odd key (e.g. library 248 ↔ function 249). Pipeline states use a separate continuous key range.

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
| 11 | SUBCMD_FAIL | Subcommand-specific failure (shader compile, etc.) |
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
python3 gputrace_replay_wrapper.py config <trace> disableOptimizeRestores=0 enableValidation=1
```

On error, the wrapper prints a JSON diagnostic to stderr and uses an appropriate exit code.

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

# pipeline + export
p = bridge.pipeline("/path/to/foo.gputrace", "/tmp/out")
target = next(lib for lib in p.libraries if "skin" in (lib.functions or [None])[0].lower())
print("found suspect lib at key", target.key, "size", target.metallib_size)

# shader hot-replace + verify
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
| `PipelineResult` | `libraries: list[Library]`, `render_pipeline_states`, `compute_pipeline_states`, `functions`, plus `*_count` totals |
| `Library` | `key`, `functions`, `metallib_size/file`, `bitcode_size/file`, `install_name`, `label` |
| `PipelineState` | `key`, `class_name`, `label` |
| `Function` | `key`, `name`, `function_type`, `function_type_str` |
| `ShaderResult` | `replacement_done`, `original`, `replacement`, `verify` |
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
