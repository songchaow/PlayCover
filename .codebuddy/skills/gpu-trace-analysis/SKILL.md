---
name: gpu-trace-analysis
description: Investigates rendering bugs and performance issues in macOS Metal apps by replaying .gputrace captures headlessly via a bundled ObjC bridge. Use this skill whenever the user reports a rendering problem (black screen, missing geometry, wrong colors, broken material, flickering, shader issue, NaN output, validation error, GPU hang, performance regression) and provides or references a .gputrace file — even if they don't say "replay" explicitly. Also use it when the user wants to inspect Metal textures/buffers, dump shader binaries (metallib/AIR), hot-replace shaders to test fixes, enumerate pipeline states, or compare configurations on captured traces. Invoke this skill proactively whenever a .gputrace path appears in the conversation, or whenever the user mentions Xcode GPU capture, Metal frame debugger, AGX shaders, or asks to investigate "what the GPU did" in a captured frame.
---

# GPU Trace Analysis & Render-Bug Investigation

This skill turns headless `.gputrace` replay into a programmable workflow for investigating Metal rendering issues on macOS. Everything you need is bundled in `scripts/` and `references/` — no external workspace dependencies.

## What this skill gives you

A self-contained CLI (`gputrace_replay_bridge`) plus a Python wrapper (`gputrace_replay_wrapper.py`) that together expose seven capabilities matching what an engineer would otherwise do manually inside Xcode's GPU Frame Debugger:

| Capability | Tool | What you can find out |
|---|---|---|
| Headless replay | `replay` | Whether the trace itself reproduces; per-call timing; resource snapshot |
| Texture / buffer inspection | `replay --list-resources --export` | Are render targets blank? Is uniform data sane? Do values contain NaN? |
| Pipeline / shader dump + RPS↔shader correlation | `pipeline` | Which library compiled which function; metallib + AIR for offline inspection; **R7.2: each RPS now reports its vertex/fragment function keys, library keys, color/depth/stencil attachment formats, write masks, and raster sample count — without requiring an external swizzle probe** |
| RPS → shader IR reverse-lookup | `shader-of-rps` | **R7.4: one command from a render-pipeline-state key to its fragment/vertex `MTLFunction`, the owning metallib, the PlayTools cacheKey, and (with `--with-ir`) the disassembled LLVM IR `.ll` file. R7.7: when MTLLibrary lacks `bitcodeData`, transparently falls back to PlayCover ShaderDebugInfo `module.bc` — IR coverage on LYSK rises from ~3% (AIR-only) to ~100%.** |
| Frame timeline (encoder/draw) + draw→RPS map | `frame-list` | **R7.3: command buffers, render/compute/blit encoders with attachment summaries, every draw with primitive type / vertex / instance counts and its bound RPS_key. Pipe `draw_to_rps_map[].rps_key` directly into `shader-of-rps --with-ir` for "draw N → shader IR" in two commands. R7.6-A: each draw now also carries a full per-stage binding snapshot (`bindings.{vertex,fragment}.{buffers,textures,samplers}[]` with `resource_id` / `offset` / `inline_bytes_size`) — answers "what was bound when this draw executed".** |
| **draw_index → shader IR (one-shot)** | `shader-of-drawcall` (Python wrapper) | **R7.6-C: thin封装 — `frame-list → draw_to_rps_map[draw_index] → shader-of-rps`. Mirrors `shader-of-rps` for the "I know the draw index, give me the shader" mental model. OOR draw_index returns structured `draw_index_out_of_range` (exit 12); compute-only traces gracefully report `draw_count=0`. Wrapper-only — bridge unchanged. Combined with R7.7 SDI fallback, `--with-ir` now produces a real `.ll` for ~100% of LYSK draws.** |
| **library_key → IR (direct)** | `disasm` | **R7.7: `disasm <trace> <lib_key> --with-ir` skips the RPS detour and goes straight library_key → metallib → cacheKey → bitcodeData/SDI module.bc → llvm-dis. Optional `--key-type rps` forwards to `shader-of-rps`. Includes the same SDI fallback used by `shader-of-rps`.** |
| Shader hot-replace | `shader --verify` | Bisect: replace a suspect shader with a corrected/instrumented one and re-replay |
| Replay configuration | `config` | Toggle Metal validation, optimization, unused-resource loading to isolate causes |

Why this matters: Metal frame debugger is GUI-only and one-trace-at-a-time. With this skill you can scriptably narrow down a bug across many shaders, many configurations, and many traces.

## First step in every session: bring up the bridge

Run the setup script once at the start. It is idempotent (cheap to re-run) and prints the absolute path of the verified, ad-hoc-signed binary.

```bash
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")
```

Where `$SKILL_DIR` is the directory containing this `SKILL.md`. If `setup.sh` exits non-zero, stop and report — the rest of the skill cannot work until the binary builds. The build needs only the system `clang` and the always-present `/System/Library/PrivateFrameworks/GPUToolsReplay.framework`; no Xcode CLI tools or developer certificates are required.

After setup, you can call the bridge directly:

```bash
"$BRIDGE" help
"$BRIDGE" replay /path/to/foo.gputrace --list-resources
```

…or use the higher-level Python wrapper for structured results:

```bash
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" replay /path/to/foo.gputrace --list-resources --pretty
```

The Python wrapper is also importable as a module — see `references/cli-reference.md` for the full surface.

## Investigation workflow

When the user gives you a rendering problem and a `.gputrace`, follow this loop. Don't skip steps just because something looks obvious; the value of the skill is in the systematic narrowing.

### 1. Establish a baseline

Always start by confirming the trace itself replays cleanly. This rules out a corrupt trace and gives you a timing baseline.

```bash
"$BRIDGE" replay <trace>
```

Look at `replay_rc`, `success`, `elapsed_ms`, `resource_count`. If `success=false`, the trace is broken at the OS layer — escalate, don't keep digging.

### 2. Frame the question

Re-read the user's report and decide which capability is most likely to surface evidence first. Some heuristics:

- "Output is black / missing / corrupted" → start with `replay --list-resources` to inventory render targets, then `--export` the suspect texture and inspect it (size, format, raw bytes).
- "Specific material / effect looks wrong" → use `pipeline` to dump every library and look for the shader by `installName` / function name, then plan a shader swap.
- "It crashes / has validation errors" → run `config enableValidation=1` and compare to default.
- "It's slow / regressed" → compare `config disableOptimizeRestores=0` vs `=1` (typically 3–6× delta). Use `replay --playto N` to bisect which call range dominates.
- "I want to test a fix to shader X" → use `shader <key> <new.metallib> --verify` (see Shader Replacement section in `references/investigation-playbook.md`).

If you can't decide in 30 seconds, default to: `replay --list-resources` → `pipeline` (with output dir) → present what you found and ask the user to point.

### 3. Drill down with the right subcommand

Pick the matching subcommand and run it. Keep outputs organized:

```bash
WORKDIR=$(mktemp -d -t gputrace-XXXXXX)   # one workdir per investigation
"$BRIDGE" pipeline <trace> "$WORKDIR/pipelines"
"$BRIDGE" replay <trace> --export 17 "$WORKDIR/tex_17.bin"
```

Read `references/cli-reference.md` for the precise flag syntax and JSON schema of every subcommand. Read `references/investigation-playbook.md` for worked examples of common bug shapes (black screen, wrong color, NaN, slow frame, etc.).

### 4. Iterate — don't guess

Each subcommand emits structured JSON. Parse it (Python wrapper does this for you with dataclasses) and let the data drive the next step. If a hypothesis doesn't pan out, drop it and revisit step 2 — don't pile shader replacements onto a wrong assumption.

### 5. Report findings

When you've reached a conclusion (or a dead end), summarize:

- What was observed (concrete JSON fields, file sizes, magic numbers, timings).
- Which subcommand outputs back the conclusion.
- The minimal repro command(s) so the user can re-run.
- If a fix was tested via `shader --verify`, report verify_rc and the elapsed delta.

## Exploring an unknown trace's pipeline

Sometimes the user hands over a `.gputrace` and asks "what does this frame even do?" rather than reporting a specific bug. Use this workflow when there is no concrete bug yet — the goal is to map the trace's render passes to their shader code.

### Recommended minimal call sequence

1. **Bounds first** — `replay --bounds` for the maximum legal `--playto N`. Cheap (one playAll). Always do this before any `--playto`-based bisecting so the bridge can fail gracefully on out-of-range targets (exit 12 = `EXIT_PLAYTO_OOR`).
2. **Pipeline overview** — `pipeline <trace> <output_dir>`. Since R7.2 this also produces every render pipeline's vertex/fragment function/library key plus attachment summary. Read `rps_correlated_count` vs `render_pipeline_states_count`: they should match.
3. **Frame timeline (R7.3)** — `frame-list <trace>`. Lists every `command_buffer.encoders[]` (render / compute / blit) with the encoder's `[first_call_index, last_call_index]` window, plus per-encoder `draws[]` (primitive type, vertex/instance counts) and a flat `draw_to_rps_map[]`. Use this to answer "which RPS does draw N use?" without writing a swizzle probe yourself.
4. **Pick a RPS to investigate** — e.g. by `label` (often `Project/Pass`-style strings from Unity/UE), by attachment count (depth-only Z-prepasses are typically `color_attachment_count: 0`), or directly from `frame-list`'s `draw_to_rps_map[k].rps_key`.
5. **One-shot shader reverse lookup** — `shader-of-rps <trace> <rps_key> --with-ir --output-dir <dir>`. This returns the `metallib`, `AIR`, optionally the `.ll` IR, and the PlayTools `cache_key_metallib` for offline cross-reference.

### Worked example (LYSK trace)

```bash
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")

# Step 1 — bounds
"$BRIDGE" replay /tmp/foo.gputrace --bounds | jq .total_call_count
# → e.g. 3425

# Step 2 — pipeline + R7.2 correlation
"$BRIDGE" pipeline /tmp/foo.gputrace /tmp/foo-pipeline > /tmp/foo-pipeline.json
jq '.render_pipeline_states[] | select(.label | contains("SkinMakeupNew"))' /tmp/foo-pipeline.json
# → multiple RPS share label "Papegame/SkinMakeupNew" but distinguishable by:
#     color_attachment_count, fragment_library_key, depth_format
#   (RPS 476 = Z-prepass: 0 colors, fragment_library_key=252)
#   (RPS 484 = main pass: 2 colors RGBA8Unorm, fragment_library_key=356)

# Step 3 — frame timeline + draw→RPS map (R7.3) + per-draw bindings (R7.6-A)
"$BRIDGE" frame-list /tmp/foo.gputrace > /tmp/foo-frame.json
jq '{cb: .command_buffer_count, enc: .encoder_count, draws: .draw_count, with_bindings: .with_bindings}' /tmp/foo-frame.json
# → e.g. {cb:4, enc:62, draws:244, with_bindings:true}
# Pick the first draw's RPS:
jq '.draw_to_rps_map[0]' /tmp/foo-frame.json
# → {"draw_index_global":0,"encoder_index":2,"draw_in_encoder":0,"call_index":131,"rps_key":472}

# R7.6-A: each draw also carries a full per-stage binding snapshot. Use this
# to answer "what was bound when this draw executed" without writing a probe.
jq '.command_buffers[].encoders[].draws[0] | select(.bindings) | .bindings | {v_bufs: (.vertex.buffers|length), v_tex: (.vertex.textures|length), f_bufs: (.fragment.buffers|length), f_tex: (.fragment.textures|length)}' /tmp/foo-frame.json | head -5
# → e.g. {"v_bufs":10,"v_tex":1,"f_bufs":4,"f_tex":16}  (typical PBR draw)
#
# Pull buffer 0 / fragment texture 0 of draw 0 — links straight back to
# replay --list-resources / replay --export <id>:
jq '.draw_to_rps_map[0].draw_index_global as $i | .command_buffers[].encoders[].draws[] | select(.draw_index_global==$i) | {v_buf0: .bindings.vertex.buffers[0], f_tex0: .bindings.fragment.textures[0]}' /tmp/foo-frame.json
# → {"v_buf0":{"index":0,"resource_id":2,"offset":262144},"f_tex0":{"index":0,"resource_id":186}}
# Now you can `replay --export 186 /tmp/draw0_ftex0.bin` to inspect the actual texture.
#
# If output volume is a concern (LYSK: ~390KB with bindings vs ~105KB without),
# add `--no-bindings` to skip the per-draw binding snapshot.

# Step 4 — pick RPS 484 (main pass), get IR
"$BRIDGE" shader-of-rps /tmp/foo.gputrace 484 --with-ir --output-dir /tmp/foo-shaders
# Output JSON includes ir_ll_path; open it in any editor.

# Or: directly chain frame-list → shader-of-rps (the R7 final-mile).
RPS=$(jq -r '.draw_to_rps_map[0].rps_key' /tmp/foo-frame.json)
"$BRIDGE" shader-of-rps /tmp/foo.gputrace "$RPS" --with-ir --output-dir /tmp/foo-shaders

# Or: one-shot via the R7.6-C thin wrapper — same byte-level metallib/AIR output,
# but no manual jq plumbing. Best entry point when you know "I want draw N's shader".
# As of R7.7, this also produces .ll IR via SDI module.bc fallback when the
# library has no bitcodeData (LYSK: 3% AIR + 97% SDI = ~100% IR coverage).
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    shader-of-drawcall /tmp/foo.gputrace 0 --with-ir --output-dir /tmp/foo-shaders

# Or: directly disassemble a library_key (skip the RPS detour) — also tries
# bitcodeData first then PlayCover SDI module.bc fallback.
"$BRIDGE" disasm /tmp/foo.gputrace 374 --with-ir --output-dir /tmp/foo-shaders
```

If `--with-ir` returns `ir_error: "no_air_bitcode_and_no_sdi"` (R7.7), neither the in-trace `bitcodeData` nor PlayCover's `ShaderDebugInfo` cache could provide LLVM bitcode — usually because the SDI cache was never populated. Run the app once through PlayCover to populate it, or use the metallib directly. The legacy `no_air_bitcode` error is gone in R7.7 (replaced by the auto-fallback path).

The exported `cache_key_metallib` follows PlayCover's convention; the skill's IR-emission path will scan `~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundle>/<cache_key>/modules/<hash>/module.bc` automatically. See `references/investigation-playbook.md` §3 for the cacheKey algorithm and full SDI cross-reference path.

### Known blind spots (still on the R7 backlog)

These are limitations of the current skill — agents should not waste cycles trying to work around them with grep / zlib / unsorted-capture parsing.

- **Depth/stencil texture export** — `replay --export` refuses depth/stencil; sample inside a shader and write to a color target as a workaround. R7.5 (planned).
- **Uniform / cbuffer content inspection** — `frame-list --with-bindings` (R7.6-A) tells you which buffer is at which slot with what offset, but does NOT yet decode the bytes inside that buffer. R7.6 子项 B (planned, depends on R7.6-A binding tables).
- **Per-encoder GPU timing** — `frame-list --with-timing` reads `MTLCommandBuffer.GPUStartTime/GPUEndTime`, but on traces whose internal CBs never `commit` these properties remain 0 / null. The flag is provided for forward compatibility; for accurate host-side per-segment timing use `replay --playto N` bisection (see playbook Pattern 4).
- **Compute encoder dispatch counts** — R7.3 lists `type=compute` encoders in the timeline, but `compute_dispatch_count` remains 0; `setComputePipelineState:` / `dispatchThreadgroups:*` swizzles are not yet installed (R7.5 子项 B planned).
- **Indirect draws / mesh shaders** — `drawPrimitives:indirectBuffer:*` / `drawMeshThreadgroups:*` are not in the R7.3 swizzle set (LYSK doesn't use them; add when needed).

If a user asks for any of the above, explain the gap and offer the closest available substitute (typically: `pipeline` to find the suspect library, then `shader-of-rps --with-ir` for IR; or `replay --playto` for bisection).

## Operational guardrails

- **Read-only by default.** All subcommands operate on a copy of the trace's data inside the replay process — they do not mutate the `.gputrace` bundle on disk. The only thing that gets written outside the trace is files you explicitly request via `--export` / `pipeline <output_dir>` / shader replacement (which only affects the in-memory ObjectMap of that one replay).
- **Don't fight Xcode.** If the user is currently debugging the same trace inside Xcode, your headless replay still works (separate process), but heavy parallel replays can slow the system. Mention this if you kick off a long batch.
- **macOS only, Apple Silicon GPU verified.** The bridge uses M-series-specific pipeline classes (`AGXG16XFamily*`). It will run on Intel GPUs but pipeline-state class names will differ — note that in your report instead of asserting it's broken.
- **GPU counters / profiler / shader debugger are out of scope.** They require Apple-private entitlements and SIP off. Don't attempt them; if the user asks for raw HW counters, explain the boundary and offer host-timing via `--playto` per-segment as a substitute.

## Verifying the skill itself

If you suspect the bundled binary is misbehaving (compilation env changed, macOS update, etc.), run the bundled integration tests:

```bash
bash "$SKILL_DIR/scripts/test_bridge.sh"
# or with a real trace for end-to-end coverage:
GPUTRACE_PATH=/path/to/sample.gputrace bash "$SKILL_DIR/scripts/test_bridge.sh"
```

29 + 38 R7-specific assertions cover argument parsing, exit codes, JSON shape, codesign validity, R7.1 bounds checking + texture/buffer metadata, R7.2 RPS↔shader correlation, R7.3 frame-list timeline + draw_to_rps_map invariants + frame-list→shader-of-rps end-to-end chain, R7.4 `shader-of-rps` reverse lookup, R7.6-C `shader-of-drawcall` wrapper byte-level equivalence + OOR + module-API contract, **R7.7 `disasm` + SDI module.bc fallback (verifies `ir_source=sdi_module_bc`, deprecated `no_air_bitcode` is gone, lib & rps key-type both produce IR)**, **R7.6-A frame-list per-draw bindings (verifies `bindings.{vertex,fragment}.{buffers,textures,samplers}` schema, vb0 invariant on every render draw, `--no-bindings` size-shrink + suppression, plus chain-compatibility with `shader-of-rps`)**, and (when GPUTRACE_PATH is set) a live replay/pipeline/config/shader-of-rps/frame-list/shader-of-drawcall/disasm sextet — **116 total assertions** on a render-bearing trace.

For multi-sample regression (so the suite doesn't only validate against one trace shape), point `GPUTRACE_PATH` at a compute-only trace too — `shader-of-drawcall`'s OOR + `frame-list`'s `draw_count=0` paths and `disasm` SDI graceful "no_air_bitcode_and_no_sdi" branch all exercise that branch. Pre-existing R7.3 assertions that assume render draws will fail on compute-only traces, which is expected.

## Reference files

Read these on demand — don't load them eagerly.

| File | Read when |
|---|---|
| `references/cli-reference.md` | You need exact flags / JSON schema / Python API for any subcommand |
| `references/investigation-playbook.md` | You're stuck choosing a subcommand, or want a worked example for the bug shape in front of you |
| `references/architecture.md` | You hit unexpected behavior and need to reason about how the bridge works internally (Controller path, ObjectMap, BL offsets) |
