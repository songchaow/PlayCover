## RIPC-010-A4 / Real iPad materializer probe follow-up

### Metadata

- **Synced at**: `2026-04-29 13:15 +0800`
- **Scope**: real iPad LLDB probe continuation, artifact cleanup, decoder fix, and execution lessons
- **Primary related scripts**:
  - [ripc_010a_materializer_probe.py](/Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_materializer_probe.py)
  - [ripc_010a_real_ipad_lldb_driver.py](/Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_real_ipad_lldb_driver.py)
- **Primary related artifacts**:
  - [ripc-010a-real-ipad-lldb-run-v3.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-run-v3.json)
  - [ripc-010a-real-ipad-lldb-run-v4.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-run-v4.json)
  - [ripc-010a-real-ipad-lldb-run-v5.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-run-v5.json)
  - [ripc-010a-ipad-materializer-args-v5.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-ipad-materializer-args-v5.json)
  - [ripc-010a-real-ipad-lldb-transcript-v3.log](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-transcript-v3.log)

### Executive summary

This round confirmed that the real iPad materializer path is **not** unreachable. The two actual blockers were:

- **Probe injection timing**: injecting immediately after attach frequently misses the useful runtime window.
- **`x1` decoding assumption**: the old probe assumed a 16-byte Pascal-style header, but real-device `x1` often points directly to a path string buffer.

After fixing both issues and rerunning with a delayed probe injection, the real device captured stable materializer data again.

### What changed in code

#### 1. Probe decoder and artifact metadata

[ripc_010a_materializer_probe.py](/Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_materializer_probe.py) was updated so that:

- `x1` decoding now **prefers direct string decoding** before falling back to the previous Pascal-style structure parsing.
- Direct decoding covers:
  - `direct-utf8`
  - `direct-utf16`
- The previous Pascal fallback is still kept for compatibility.
- Each record now preserves richer decode metadata:
  - `entry_x1_mode`
  - `entry_x1_encoding`
  - `x1_mode`
  - `x1_encoding`
- The saved JSON now includes top-level metadata such as:
  - `generatedAt`
  - `recordCount`
  - session/module metadata
- Probe artifact paths can now be overridden by environment variables so the caller can assign per-run output files.

#### 2. Driver artifact isolation and stale-output prevention

[ripc_010a_real_ipad_lldb_driver.py](/Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_real_ipad_lldb_driver.py) was added/updated so that:

- each `run-vN.json` automatically maps to its own probe outputs
- the driver clears old per-run probe files before each execution
- the driver passes probe output paths through environment variables into LLDB
- the run summary now records artifact timestamps such as:
  - `probeJsonModifiedAt`
  - `probeLogModifiedAt`

This removes the earlier confusion where different sessions could reuse the same default probe JSON path and make old results look like they belonged to the latest run.

### Verified execution timeline

#### A. `v3` report

From [ripc-010a-real-ipad-lldb-run-v3.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-run-v3.json):

- `recordCount = 0`
- `probeJsonExists = false`
- `probeLogExists = true`
- the log only shows successful breakpoint installation

At that stage, the run looked like a complete miss. Later investigation showed that part of the confusion came from probe artifacts being reused across sessions.

#### B. `v4` rerun after artifact isolation

After fixing per-run artifact mapping, `v4` was rerun with immediate injection behavior preserved.

Observed result:

- `preInjectDelay = 0`
- `recordCount = 0`

This confirmed that the `0-hit` result in this mode is **real**, not caused by stale JSON reuse.

#### C. `v5` rerun with delayed injection

The successful rerun was done with a delayed probe injection:

```bash
python3 Scripts/ripc_010a_real_ipad_lldb_driver.py \
  --pre-inject-delay 5 \
  --wait-seconds 60 \
  --output build/ripc-010a-real-ipad-lldb-run-v5.json \
  --transcript build/ripc-010a-real-ipad-lldb-transcript-v5.log
```

Observed result from [ripc-010a-real-ipad-lldb-run-v5.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-real-ipad-lldb-run-v5.json):

- `recordCount = 71`
- `probeJsonPath = /Users/songdogwang/Codes/PlayCover/build/ripc-010a-ipad-materializer-args-v5.json`
- `probeLogPath = /tmp/ripc-010a-materializer-log-v5.jsonl`
- `probeJsonModifiedAt = 2026-04-29T13:08:21+0800`

Observed result from [ripc-010a-ipad-materializer-args-v5.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-ipad-materializer-args-v5.json):

- `recordCount = 71`
- `materializer_complete = 15`
- `vcall complete where x8_target == 0x106766068 = 0`

### Real iPad paths successfully decoded from `entry_x1_text`

The updated decoder successfully recovered actual real-device arguments, including both absolute and relative paths:

- `/var/mobile/Containers/Data/Application/62B518C9-5AEB-430D-BC70-30ADD238D0F8/Library/NGR/Saved/Paks/1/1_0.db`
- `../../../NGR/Content/Paks/1/1_0.db`
- `../../../NGR/Content/Paks/1/1_12.db`
- `../../../NGR/Content/Paks/1/1_2.db`
- `../../../NGR/Content/Paks/1/1_8.db`
- `../../../NGR/Content/Paks/1/1_10.db`
- `../../../NGR/Content/Paks/1/1_13.db`
- `../../../NGR/Content/Paks/1/1_14.db`

This is the strongest confirmation from this round: on the real iPad, `x1` is frequently a **direct path string pointer**, not always a small Pascal-like object.

### Final conclusions from this round

#### 1. Real iPad materializer is capturable

The real iPad path is **not** fundamentally untraceable. A stable capture is possible once the injection timing is adjusted.

#### 2. Immediate probe injection is unreliable

`preInjectDelay = 0` repeatedly misses the useful runtime window on device. A delayed injection (`5s` in this round) is currently the practical default.

#### 3. Old `x1` decoding was wrong for the real-device case

The previous decoder model was too narrow. Direct UTF-8 / UTF-16 detection is required before attempting the older Pascal-structure interpretation.

#### 4. Per-run artifact isolation is mandatory

Without per-run JSON/log paths, it is easy to misread old captures as fresh results. This was a major source of confusion while interpreting the earlier `v3` session.

#### 5. The investigation can proceed to `RIPC-010-B`

The current state is sufficient to start or continue a structured real-device vs PlayCover comparison using the `v5` real-device capture.

### Important caveat

Although `v5` captured many materializer records, this specific rerun did **not** observe a `vcall complete` record where `x8_target == 0x106766068`.

So the correct interpretation is:

- the materializer side is now reliably capturable
- the real-device comparison dataset is much stronger than before
- but the full vcall-side correspondence still needs targeted follow-up rather than being treated as fully closed

### iPad real-device debugging lessons learned

#### 1. Delay the probe injection, do not assume the earliest stop is best

On real hardware, attaching and importing the probe immediately after launch can miss the interesting window. Letting the process run briefly and then interrupting for probe installation produced far better results in this case.

#### 2. Always isolate artifacts per run

A single shared probe JSON path is dangerous for long-lived investigations. Each run should have its own:

- run report
- transcript
- probe JSON
- probe log

Otherwise timestamps and content can silently drift apart.

#### 3. Check timestamps, not only presence/absence

When reading a run summary, verify:

- output file path
- modification time
- record count
- whether the JSON was actually regenerated in the latest run

This matters more than a simple `exists = true/false` check.

#### 4. Real-device memory layouts may differ from local assumptions

A decoder that works in one environment may fail on the device. For string-like pointers, prefer layered heuristics:

1. direct UTF-8
2. direct UTF-16
3. fallback structured decoding

#### 5. Keep the probe auto-continue and module-relative where possible

For unstable ASLR / device-side launches, module-relative breakpoint placement plus auto-continue behavior reduces operational friction and keeps the capture loop lightweight.

#### 6. Separate “no hit” from “bad instrumentation”

A zero-hit run can mean different things:

- the target code path did not execute
- the timing window was missed
- the decoder was wrong
- the outputs were stale

Those possibilities should be eliminated one by one before concluding that the target path is absent.

### Recommended next steps

- Use [ripc-010a-ipad-materializer-args-v5.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010a-ipad-materializer-args-v5.json) as the current real-device baseline for `RIPC-010-B`.
- Compare real-device `entry_x1_text`, return values, and sequence ordering against PlayCover-side captures.
- Keep `--pre-inject-delay 5` as the default starting point for the next real-device reruns.
- If vcall-side matching is required, add a more targeted rerun for the missing `x8_target == 0x106766068` path instead of reusing the broad conclusion from materializer-only success.
