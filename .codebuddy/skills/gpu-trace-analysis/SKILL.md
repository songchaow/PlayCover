---
name: gpu-trace-analysis
description: Investigates rendering bugs and performance issues in macOS Metal apps by replaying .gputrace captures headlessly via a bundled ObjC bridge. Use this skill whenever the user reports a rendering problem (black screen, missing geometry, wrong colors, broken material, flickering, shader issue, NaN output, validation error, GPU hang, performance regression) and provides or references a .gputrace file — even if they don't say "replay" explicitly. Also use it when the user wants to inspect Metal textures/buffers, dump shader binaries (metallib/AIR), hot-replace shaders to test fixes, enumerate pipeline states, or compare configurations on captured traces. Invoke this skill proactively whenever a .gputrace path appears in the conversation, or whenever the user mentions Xcode GPU capture, Metal frame debugger, AGX shaders, or asks to investigate "what the GPU did" in a captured frame.
---

# GPU Trace Analysis & Render-Bug Investigation

This skill turns headless `.gputrace` replay into a programmable workflow for investigating Metal rendering issues on macOS. Everything you need is bundled in `scripts/` and `references/` — no external workspace dependencies.

## What this skill gives you

A self-contained CLI (`gputrace_replay_bridge`) plus a Python wrapper (`gputrace_replay_wrapper.py`) that together expose 5 capabilities matching what an engineer would otherwise do manually inside Xcode's GPU Frame Debugger:

| Capability | Tool | What you can find out |
|---|---|---|
| Headless replay | `replay` | Whether the trace itself reproduces; per-call timing; resource snapshot |
| Texture / buffer inspection | `replay --list-resources --export` | Are render targets blank? Is uniform data sane? Do values contain NaN? |
| Pipeline / shader dump | `pipeline` | Which shader compiled into which library; metallib + AIR bitcode for offline inspection |
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

29 assertions cover argument parsing, exit codes, JSON shape, codesign validity, and (when GPUTRACE_PATH is set) a live replay/pipeline/config trio.

## Reference files

Read these on demand — don't load them eagerly.

| File | Read when |
|---|---|
| `references/cli-reference.md` | You need exact flags / JSON schema / Python API for any subcommand |
| `references/investigation-playbook.md` | You're stuck choosing a subcommand, or want a worked example for the bug shape in front of you |
| `references/architecture.md` | You hit unexpected behavior and need to reason about how the bridge works internally (Controller path, ObjectMap, BL offsets) |
