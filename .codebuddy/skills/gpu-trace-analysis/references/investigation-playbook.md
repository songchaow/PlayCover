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
# 1. Dump everything. Pipeline gives you names.
"$BRIDGE" pipeline "$TRACE" "$WORKDIR/pipelines" > "$WORKDIR/pipeline.json"
```

In `pipeline.json`, scan `libraries[*].functions` for names that match the user's description. Function names usually carry intent (`fragment_skin_subsurface`, `compute_blur_horizontal`, `vertex_water_caustic`).

```bash
# 2. Inspect the suspect shader's bytecode. AIR (LLVM bitcode) is more
#    diff-friendly than the metallib container.
ls "$WORKDIR/pipelines/library_<KEY>.air"
# If you have llvm-dis available system-wide:
xcrun llvm-dis "$WORKDIR/pipelines/library_<KEY>.air" -o "$WORKDIR/lib.ll"
head -50 "$WORKDIR/lib.ll"
```

```bash
# 3. Inspect the constant buffers feeding that shader. List buffers,
#    pick those whose size and label suggest "uniforms" or "params".
"$BRIDGE" replay "$TRACE" --list-resources \
  | python3 -c "import json,sys; [print(r) for r in json.load(sys.stdin)['resources'] if r['type']=='buffer' and r['length'] < 4096]"

# 4. Export and dump.
"$BRIDGE" replay "$TRACE" --export <BUFFER_ID> "$WORKDIR/uniforms.bin"
hexdump -C "$WORKDIR/uniforms.bin" | head -20
# Or interpret as floats:
python3 -c "
import struct; b=open('$WORKDIR/uniforms.bin','rb').read()
floats=struct.unpack(f'{len(b)//4}f', b[:4*(len(b)//4)])
for i in range(0, len(floats), 4): print(i, floats[i:i+4])
" | head -10
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

## When to stop

Stop and hand back to the user when:

- You've localized the issue to a specific shader / resource / call range, with the JSON evidence to support it.
- You've ruled out enough hypotheses that the next step requires source code or domain knowledge you don't have.
- You hit one of the explicit out-of-scope cases (HW counters, profiler-derived metrics, shader-step debugger).

In all cases, leave the user with: (a) the artifacts you wrote into `$WORKDIR`, (b) the exact commands to reproduce them, and (c) your best one-paragraph theory of the bug.
