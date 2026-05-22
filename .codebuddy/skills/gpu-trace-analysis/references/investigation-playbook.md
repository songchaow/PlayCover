# Investigation Playbook

Concrete recipes for common rendering bug shapes. Use these as starting points, not as rigid scripts — every trace is different. The unifying idea: replace guessing with structured evidence from the bridge.

## How to use this playbook

1. Match the user's report to one of the patterns below (or the closest neighbor).
2. Run the listed commands in order, looking at the JSON output before deciding the next step.
3. If two patterns seem to fit, run the cheaper one first (replay > config > pipeline > shader, roughly in cost order on small traces).
4. Stop when you have enough to either name the cause or hand back a sharper question to the user.

All examples assume:

```bash
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")
WORKDIR=$(mktemp -d -t gputrace-XXXXXX)
TRACE=/path/to/the.gputrace
```

---

## Pattern 1: "The output is black / blank / mostly empty"

Hypothesis space: missing draw, render target cleared but never written, all pixels alpha=0, depth-failed, wrong viewport, shader returns 0.

Recipe:

```bash
# 1. Sanity-replay to confirm the trace itself isn't broken.
"$BRIDGE" replay "$TRACE"

# 2. Inventory render targets.
"$BRIDGE" replay "$TRACE" --list-resources > "$WORKDIR/inventory.json"
```

Open `inventory.json`. Filter `type == "texture"` and look for likely framebuffers — labels containing `Color`, `GBuffer`, `Final`, `Backbuffer`, `Display`, or formats like `BGRA8Unorm`/`BGRA8Unorm_sRGB`/`RGBA16Float` at the screen resolution.

```bash
# 3. Export the suspected final color target.
"$BRIDGE" replay "$TRACE" --export <ID> "$WORKDIR/color.bin"

# 4. Check it's not all zero.
xxd "$WORKDIR/color.bin" | head -20
# Or, for a quick statistic:
python3 -c "
import sys; data=open('$WORKDIR/color.bin','rb').read()
nz = sum(1 for b in data if b)
print(f'non-zero bytes: {nz}/{len(data)} ({100*nz/len(data):.1f}%)')
"
```

If the target is all zeros, walk earlier in the frame to see when it diverges. Pick a draw-call index N (start with the midpoint, then bisect):

```bash
"$BRIDGE" replay "$TRACE" --playto <N> --export <ID> "$WORKDIR/color_at_N.bin"
```

Compare a series of `playto` values. The first index after which the target stops being all zero is your culprit's neighborhood.

If the target was non-zero but visually wrong, you have a coloring/material issue — switch to Pattern 3.

---

## Pattern 2: "It crashes / shows validation errors / GPU hang"

Hypothesis space: API misuse the production app suppressed (validation off in release), out-of-bounds buffer access, mismatched argument buffer layout.

Recipe:

```bash
# Replay with Metal validation. Watch stderr — validation messages
# emerge from the replay process, not the JSON.
"$BRIDGE" config "$TRACE" enableValidation=1 2> "$WORKDIR/validation.stderr"
cat "$WORKDIR/validation.stderr"
```

If validation prints messages, those are typically the smoking gun — Metal will name the offending API call and parameter. Pair with `pipeline` to find the shader involved:

```bash
"$BRIDGE" pipeline "$TRACE" "$WORKDIR/pipelines" > "$WORKDIR/pipeline.json"
```

Cross-reference the `functions` array against any function name that appeared in validation output.

If validation is silent but `replay` returns non-zero `replay_rc`, the failure happens deeper than the validation layer. Bisect with `--playto`:

```bash
# Binary-search the call index that flips replay_rc from 0 to nonzero.
for N in 50 100 150 200 250; do
  rc=$("$BRIDGE" replay "$TRACE" --playto $N | python3 -c "import json,sys;print(json.load(sys.stdin)['replay_rc'])")
  echo "playto=$N rc=$rc"
done
```

---

## Pattern 3: "A specific material / effect looks wrong"

Hypothesis space: shader is computing the wrong thing, wrong texture bound, wrong uniform value, wrong pipeline state selected.

Recipe:

```bash
# FASTEST PATH: if you know the shader/material name (from Xcode GUI or user report),
# jump directly to the full draw context in one command:
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    find-draws "$TRACE" --by-label "SkinMakeupNew" --show-first \
    --with-ir --with-uniforms --output-dir "$WORKDIR/shaders"
# → Finds all draws using that shader, auto-runs shader-of-drawcall on the first hit.
# Output includes: IR (.ll), per-stage binding tables, and every cbuffer slot decoded.
```

If `find-draws` returns multiple hits (common — same shader used in multiple passes), pick the one matching your investigation context by RPS_key or encoder_index.

```bash
# See all matching draws:
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    find-draws "$TRACE" --by-label "SkinMakeupNew"
# → JSON array with draw_index, rps_key, rps_label, encoder_index for each hit.
# Pick the one you want, then investigate it fully:
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    shader-of-drawcall "$TRACE" 87 --stage fragment --with-ir --with-uniforms \
    --output-dir "$WORKDIR/shaders"
```

**Fallback (when you don't know the shader name):**

```bash
# 1. Dump the full pipeline to search by function name or attachment count.
"$BRIDGE" pipeline "$TRACE" "$WORKDIR/pipelines" > "$WORKDIR/pipeline.json"
```

In `pipeline.json`, scan two views:

- `libraries[*].functions` for names that match the user's description (e.g. `fragment_skin_subsurface`, `compute_blur_horizontal`, `vertex_water_caustic`).
- `render_pipeline_states[*]` for `label`s that match, **then read the RPS↔shader fields directly** to find the right `fragment_function_key` / `fragment_library_key`:

```bash
jq '.render_pipeline_states[] | select(.label | test("Skin|Eye"; "i"))' "$WORKDIR/pipeline.json"
```

Common gotcha: the same `label` often appears on multiple RPSs (e.g. one Z-prepass variant + one main pass variant). Use `color_attachment_count`, `depth_format`, and the fragment_library_key to disambiguate before swapping shaders.

```bash
# 2. Once you've picked an RPS, get its shader code in one command.
"$BRIDGE" shader-of-rps "$TRACE" 484 --with-ir --output-dir "$WORKDIR/shaders"
```

If you instead already know the library key:

```bash
"$BRIDGE" disasm "$TRACE" 374 --with-ir --output-dir "$WORKDIR/shaders"
```

```bash
# 3. Inspect the constant buffers feeding that shader (R7.6-B automatic decode).
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    dump-uniforms "$TRACE" 87 0 --stage fragment
# → Full cbuffer decode: field names, offsets, types, actual values.
# No need to manually export+hexdump+struct.unpack anymore.
```

If a uniform is obviously bogus (NaN, huge number, suspiciously zero), the bug is upstream of the GPU — report it.

If uniforms look fine, suspect the shader itself and proceed to **Pattern 5: shader hot-replace** below.

---

## Pattern 4: "It's slow / regressed in performance"

Hypothesis space: too much work in a small range of calls, expensive validation/restore overhead, redundant resource loads.

Recipe:

```bash
# 1. Establish baseline timing under default config.
"$BRIDGE" config "$TRACE"
# elapsed_ms = X

# 2. Compare with restore optimization on (the typical expensive default off).
"$BRIDGE" config "$TRACE" disableOptimizeRestores=0
# elapsed_ms = Y. If Y << X, the cost is in restore handling.

# 3. Per-segment timing via playTo bisection.
for N in 25 50 75 100 150 200; do
  ms=$("$BRIDGE" replay "$TRACE" --playto $N | python3 -c "import json,sys;print(json.load(sys.stdin)['elapsed_ms'])")
  echo "playto=$N elapsed=${ms}ms"
done
# The largest delta between consecutive Ns localizes the costly call range.
```

Caveats:
- Wall-clock host timing only — for true GPU counters you need Apple's private entitlements (out of scope, see SKILL.md).
- The first replay invocation after a fresh process pays APR/ObjectMap setup cost; for fair comparisons, run each measurement twice and take the second.

---

## Pattern 5: Shader hot-replace — testing a suspected fix

Hypothesis: shader at lib_key K is doing the wrong math. We want to drop in a candidate fix and see if the visible output changes (for replay you can re-export the render target and compare).

Recipe (using a freshly compiled MSL):

```bash
# 1. Find the original shader's key and function name.
"$BRIDGE" pipeline "$TRACE" "$WORKDIR/pipelines" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for lib in d['libraries']:
    if 'skin' in (lib.get('functions') or [''])[0].lower():
        print(lib['key'], lib['functions'])
"

# 2. Author replacement MSL. CRITICAL: function names must match the originals.
cat > "$WORKDIR/fix.metal" <<'MSL'
#include <metal_stdlib>
using namespace metal;

fragment float4 fragment_skin_subsurface(
    /* parameters must match the original; see AIR dump for clues */
) {
    return float4(1, 0, 0, 1);   // crimson-red for visual confirmation
}
MSL

# 3. Apply and verify.
"$BRIDGE" shader "$TRACE" <KEY> --source "$WORKDIR/fix.metal" --verify

# 4. (Optional) Re-export the affected render target. Note: shader replace
#    only affects the in-memory replay; you'll need to combine the steps
#    in one process to export a post-replacement texture. For that, prefer
#    the Python wrapper:
python3 - <<'PY'
import sys; sys.path.insert(0, "$SKILL_DIR/scripts")
from gputrace_replay_wrapper import ReplayBridge
b = ReplayBridge()
# (current bridge does not yet combine shader+export in one call;
#  use --verify for a binary go/no-go and inspect host-side timing)
PY
```

Caveats and gotchas:
- The replacement library's exported function name(s) must exactly match the originals, or the next pipeline-state binding will fail.
- The bridge compiles MSL with default `MTLCompileOptions` — set explicit options if your original shader required a specific Metal language version or fast-math state.
- A successful `--verify` (verify.success=true, low elapsed_ms) means the swap didn't crash, not that the visual result is correct. Use this as a "doesn't blow up" gate, then look at exported textures for content.

Recipe (using an externally-built `.metallib`):

```bash
"$BRIDGE" shader "$TRACE" <KEY> /path/to/your_built.metallib --verify
```

---

## Pattern 6: Comparing two traces of "same" scene

Sometimes the user has a "good" trace and a "bad" trace and wants to know what changed. Run both through `pipeline` and diff the inventories:

```bash
"$BRIDGE" pipeline "$GOOD_TRACE" "$WORKDIR/good_pipes" > "$WORKDIR/good.json"
"$BRIDGE" pipeline "$BAD_TRACE"  "$WORKDIR/bad_pipes"  > "$WORKDIR/bad.json"

# Quick diff of the function name sets:
python3 - <<'PY'
import json
g = {f['name'] for f in json.load(open("$WORKDIR/good.json"))['functions']}
b = {f['name'] for f in json.load(open("$WORKDIR/bad.json"))['functions']}
print("only in good:", sorted(g - b)[:20])
print("only in bad:",  sorted(b - g)[:20])
PY

# Per-library bytecode sizes (changes hint at a recompiled shader):
python3 - <<'PY'
import json
for tag, path in [("good","$WORKDIR/good.json"),("bad","$WORKDIR/bad.json")]:
    d = json.load(open(path))
    sizes = sorted((lib.get('metallib_size',0), lib['key'], (lib.get('functions') or [''])[0]) for lib in d['libraries'])
    print(tag, sizes[:5], '...', sizes[-5:])
PY
```

---

## Pattern 7: Frame overview — exploring an unknown trace (R7.2 + R7.3 + R7.4)

**When to use**: the user hands over a `.gputrace` and asks "what does this frame even render?", "give me a high-level summary", or wants to map RPS labels to shader code without specifying a bug. Pre-R7 this required either Xcode's GUI or hand-rolled swizzle probes; with the bridge it's now four commands.

```bash
WORKDIR=$(mktemp -d -t frame-overview-XXXXXX)
TRACE=/path/to/foo.gputrace

# 1. Confirm trace replays cleanly + get total_call_count for any later --playto bisecting.
"$BRIDGE" replay "$TRACE" --bounds | jq '{success: (.bounds_only==true), total_call_count}'

# 2. Pipeline overview with R7.2 RPS↔shader correlation. The output is the
#    backbone of every subsequent step — keep it on disk.
"$BRIDGE" pipeline "$TRACE" "$WORKDIR/pipelines" > "$WORKDIR/pipeline.json"
jq '{rps_count: .render_pipeline_states_count,
     rps_correlated_count, rps_captured_count,
     libs: .libraries_count, fns: .functions_count}' "$WORKDIR/pipeline.json"
```

`rps_correlated_count` should equal `render_pipeline_states_count`; if it's `0`, the swizzle is broken (see SKILL.md).

```bash
# 3. R7.3 — Frame timeline. command_buffers / encoders / draws + draw_to_rps_map[].
"$BRIDGE" frame-list "$TRACE" > "$WORKDIR/frame.json"
jq '{cb: .command_buffer_count, enc: .encoder_count, draws: .draw_count, rps: .rps_correlated_count}' "$WORKDIR/frame.json"
# → e.g. {"cb":4, "enc":62, "draws":244, "rps":65} on the LYSK trace
```

Group draws by encoder for a "render pass timeline":

```bash
jq -r '.command_buffers[] | "CB \(.index): \(.encoder_count) encoders",
       (.encoders[] | "  enc#\(.index) [\(.type)] calls=\(.first_call_index)..\(.last_call_index) draws=\(.draw_count) label=\(.label // "")")' \
   "$WORKDIR/frame.json"
```

…or, for a flat "draw N → RPS" view (ready to pipe into `shader-of-rps`):

```bash
jq -r '.draw_to_rps_map[] | "draw#\(.draw_index_global)\trps=\(.rps_key)\tcall=\(.call_index)"' \
   "$WORKDIR/frame.json" | head -10
```

Cross-reference with `pipeline.json`:

```bash
jq -r '.render_pipeline_states[] | "\(.key)\t\(.label)\tcolors=\(.color_attachment_count // "?")\tdepth=\(.depth_format)\tf_lib=\(.fragment_library_key // "?")"' \
   "$WORKDIR/pipeline.json" | sort
```

You'll see patterns like:

```
474   Papegame/Teeth                colors=0  depth=Depth32Float           f_lib=252   ← Z-prepass cluster
475   Papegame/SkinSSS              colors=0  depth=Depth32Float           f_lib=252
476   Papegame/SkinMakeupNew        colors=0  depth=Depth32Float           f_lib=252
479   Papegame/EyeSpec              colors=0  depth=Depth32Float           f_lib=252
484   Papegame/SkinMakeupNew        colors=2  depth=Depth32Float_Stencil8  f_lib=356   ← main pass
491   Papegame/SkinMakeupNew        colors=2  depth=Depth32Float_Stencil8  f_lib=390   ← variant
```

This is the kind of "frame overview" Xcode's GPU debugger UI gives you, but as a shell-pipe-able stream.

```bash
# 4. Drill into any RPS in one command — produces metallib + AIR + .ll IR.
"$BRIDGE" shader-of-rps "$TRACE" 484 --with-ir --output-dir "$WORKDIR/shaders"
# Inspect the IR:
head -40 "$WORKDIR/shaders/library_356.ll"

# Or chain straight from frame-list output (the R7 final-mile):
RPS=$(jq -r '.draw_to_rps_map[0].rps_key' "$WORKDIR/frame.json")
"$BRIDGE" shader-of-rps "$TRACE" "$RPS" --with-ir --output-dir "$WORKDIR/shaders"
```

If `--with-ir` returns `ir_error: "no_air_bitcode"`, fall back to the metallib (use the `cache_key_metallib` field to find the corresponding PlayCover ShaderDebugInfo entry — see Reference §3.1 below).

### One-shot: `shader-of-drawcall` (R7.6-C薄封装)

When you already know the draw_index (e.g. from `frame-list` output, or from a user complaint phrased as "draw N looks wrong"), skip the manual `jq | shader-of-rps` plumbing and use the wrapper:

```bash
WRAPPER=$SKILL_DIR/scripts/gputrace_replay_wrapper.py
python3 "$WRAPPER" shader-of-drawcall "$TRACE" 0 --with-ir --output-dir "$WORKDIR/shaders"
# → JSON with frame-list metadata (encoder_index, draw_in_encoder, call_index, rps_key, rps_label)
#   plus the embedded shader_of_rps result (metallib_path, AIR, cacheKey, ir_ll_path, etc.).
```

Behavior summary:

| Scenario | Result |
|---|---|
| Valid draw_index in a render-bearing trace | exit 0; output mirrors `frame-list[draw_to_rps_map[N]] + shader-of-rps[rps_key]`; metallib/AIR/cacheKey are byte-identical to the chained call. |
| `draw_index >= draw_count` (incl. compute-only traces with `draw_count == 0`) | exit 12; structured `{"error":"draw_index_out_of_range","draw_count":K,"hint":"..."}`. Compute-only hint is explicit ("trace has no render draws"). |
| `shader-of-rps` half fails (e.g. `rps_not_found` for the resolved RPS_key, or `no_air_bitcode` with `--with-ir`) | exit 11; payload still printed in full so callers can inspect the embedded `shader_of_rps.error` / `ir_error`. |

The wrapper is symmetric to `shader-of-rps`: pick whichever entry point matches your mental model (RPS_key vs draw_index). Both produce the same artifacts on disk.

**When to stop here**: once the user can match user-visible symptoms (e.g. "the SkinMakeupNew layer is wrong") to a concrete shader IR file + the binding table at that draw, you've handed them everything the bridge currently exposes.

**R7.6-A: per-draw bindings (default ON)**: `frame-list` (with `--with-bindings`, the default) attaches `bindings.{vertex,fragment}.{buffers,textures,samplers}[]` to every render-encoder draw. Combined with `shader-of-drawcall`, the workflow "draw N → IR + bindings" is now a single-`jq`-pipe answer. Example for a "wrong-texture" hypothesis:

```bash
# Find draw 0's fragment textures (resource_id values reference replay --list-resources)
jq '.command_buffers[].encoders[].draws[] | select(.draw_index_global==0) | .bindings.fragment.textures' \
   /tmp/foo-frame.json
# → [{"index":0,"resource_id":186},{"index":3,"resource_id":211}, ...]

# Export texture bound at fragment slot 3 to inspect:
"$BRIDGE" replay /tmp/foo.gputrace --export 211 /tmp/draw0_ftex3.bin
```

What's still on the R7 backlog: **depth/stencil texture export** (R7.5-A), **compute encoder dispatch counts** (R7.5-B).

### Pattern: "What did the cbuffer at draw N actually contain?" (R7.6-B)

Once `frame-list --with-bindings` has told you that draw N has a buffer at fragment slot S, the next question is "what were the actual bytes — is `_MainLightDirection` zero? Is the projection matrix transposed? Is `_MipBias` NaN?". The `dump-uniforms` subcommand decodes those bytes by walking the captured `MTLRenderPipelineReflection`'s `MTLStructType` tree.

```bash
# Wrapper draw-mode is the simplest entry point. It auto-resolves
# rps_key + buffer_key + offset by running frame-list internally.
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    dump-uniforms /tmp/foo.gputrace 0 0 --stage fragment

# Output (abbreviated):
# {
#   "binding_name": "AsukaPerShader_PerCamera",
#   "buffer_data_size": 144,
#   "buffer_data_type": "struct",
#   "layout":  { "_MainLightPosition": {"offset": 64, "data_type": "float4", "value": null}, ... },
#   "decoded": { "_MainLightPosition": {"offset": 64, "data_type": "float4", "value": [0.42,-0.85,0.31,0]}, ... },
#   "decoded_ok": true
# }

# bridge-direct rps-mode is useful when you're looping over many RPS_keys
# (e.g. iterating over `pipeline` output) and want minimum overhead per call.
"$BRIDGE" dump-uniforms /tmp/foo.gputrace 472 0 \
    --stage vertex --buffer-key 2 --offset 262144

# Layout-only mode (no --buffer-key): see what fields the shader expects,
# without binding to a specific draw's bytes.
"$BRIDGE" dump-uniforms /tmp/foo.gputrace 472 0 --stage fragment
```

`layout` is always present (whenever reflection was captured). `decoded` only appears when `--buffer-key` was supplied. If reflection capture failed, the bridge returns `error: "reflection_not_captured"` (exit 11) — `--with-hex --buffer-key K` still gives a hex dump as a fallback.

### Pattern: "Show me draw N's full context — IR + bindings + uniforms — in one command" (R7.6-D)

Once you've localized the suspect to a specific draw (via `frame-list` or visual narrowing), the typical follow-up is "give me the shader source, what was bound to it, and the uniform values it actually saw" — i.e. exactly what an Xcode GUI selection would put on screen. R7.6-D collapses that into one wrapper call by reusing the already-shipped `frame-list` + `shader-of-rps` + `dump-uniforms` plumbing:

```bash
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    shader-of-drawcall /tmp/foo.gputrace 0 \
    --stage fragment --with-ir --with-uniforms --output-dir "$WORKDIR/draw0" --pretty
```

Output JSON contains:
- `shader_of_rps.ir_ll_path` — the disassembled `.ll` IR (via R7.7 SDI fallback when no AIR)
- `bindings.fragment.{buffers,textures,samplers}[]` — exact byte-level identical to a standalone `frame-list --with-bindings` for the same draw
- `uniforms[]` — one entry per `bindings.fragment.buffers[i]`, each with the `MTLStructType` `layout` and decoded field tree (`AsukaPerShader_PerCamera._MainLightPosition`, `_ProjectionMatrix`, …); per-slot soft errors land in `uniforms[i].error` without aborting the chain
- `uniforms_summary.{slot_count, slot_ok, slot_failed, errors}` — quick health view to skim before diving into individual slots

`--with-bindings` alone (no uniforms) is also useful when you only want the binding inventory but not the byte decode — same output shape, just no `uniforms[]`. `--with-uniforms` implies `--with-bindings`. Default invocation (no flags) preserves R7.6-C behavior — IR-only, smallest output.

When to prefer `shader-of-drawcall --with-uniforms` over hand-stitching `frame-list` + `dump-uniforms`:

| Scenario | Recommended path |
|---|---|
| Investigating one specific draw end-to-end | `shader-of-drawcall --with-uniforms` (one command, complete context) |
| Iterating over many draws (loop over draw_to_rps_map) | One `frame-list --with-bindings`, then per-draw `dump-uniforms --buffer-key K --offset N` (avoids re-running frame-list per draw) |
| Want only binding inventory across all draws | `frame-list --with-bindings`, no follow-up |
| Already know the RPS_key (not draw_index) | `dump-uniforms <rps_key> <slot> --target-kind rps` (skips frame-list) |

What's still on the R7 backlog: **depth/stencil texture export** (R7.5-A), **compute encoder dispatch counts** (R7.5-B).

---

## Reference §3.1: PlayTools cacheKey algorithm

The bridge's `shader-of-rps` and the offline `extract_shader_raw.py` tool both compute a "cacheKey" on a metallib's bytes. This key matches PlayCover's ShaderDebugInfo directory layout: `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cache_key>/modules/<hash>/module.bc`.

Algorithm (FNV-style 64-bit hash with a head/tail sample):

```python
def compute_cache_key(data: bytes) -> str:
    size = len(data)
    h = size
    for i in range(min(32, size)):
        h = (h * 31 + data[i]) & 0xFFFFFFFFFFFFFFFF
    if size > 32:
        for i in range(size - min(16, size - 32), size):
            h = (h * 31 + data[i]) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016X}_{size}"
```

Use this when you want to cross-reference a metallib produced by replay against the corresponding compile-time `module.bc` PlayCover persisted on first launch. The bridge already computes this and reports it as `cache_key_metallib` on every `shader-of-rps` invocation, so you typically don't need to run this Python yourself.

---

## When to stop

Stop and hand back to the user when:

- You've localized the issue to a specific shader / resource / call range, with the JSON evidence to support it.
- You've ruled out enough hypotheses that the next step requires source code or domain knowledge you don't have.
- You hit one of the explicit out-of-scope cases (HW counters, profiler-derived metrics, shader-step debugger).

In all cases, leave the user with: (a) the artifacts you wrote into `$WORKDIR`, (b) the exact commands to reproduce them, and (c) your best one-paragraph theory of the bug.
