# Architecture Notes

Why the bridge looks the way it does, and what to do when the macOS environment shifts under you. Read this when something behaves unexpectedly and you need to reason about the implementation, not just use it.

## Table of contents
1. [Big picture](#big-picture)
2. [The Controller path](#the-controller-path)
3. [Function offset table (`GTMTLReplay_CLI` BL relocations)](#function-offset-table-gtmtlreplay_cli-bl-relocations)
4. [GTMTLReplayObjectMap](#gtmtlreplayobjectmap)
5. [Pipeline binary export](#pipeline-binary-export)
6. [Why the bridge avoids XPC](#why-the-bridge-avoids-xpc)
7. [Capability boundaries](#capability-boundaries)
8. [What can break across macOS updates](#what-can-break-across-macos-updates)

---

## Big picture

Xcode's GPU Frame Debugger is built on a stack of Apple-internal components:

```
GPUDebugger.ideplugin   (the IDE side)
    ↓
GPUToolsServices         (76 ObjC classes — capture-session bookkeeping)
    ↓
XPC Services             (GPUToolsAgentService, GPUToolsCompatService, GPUToolsReplayService)
    ↓
GPUToolsReplay.framework (C/ObjC API — actually replays the trace)
```

The bridge skips the top three layers. It links directly against `GPUToolsReplay.framework` and rebuilds, in-process, the same private state machine that `GPUToolsReplayService` would build. This is why the bridge needs no entitlements, no XPC permissions, and no Xcode running.

---

## The Controller path

The framework exposes two entry-point styles:

1. `GTMTLReplay_CLI` — a single-shot CLI used by Apple's own `GTMTLReplay_CLI` tool. Replays the whole trace and returns 0/non-zero. No introspection. **Not used** by this bridge.
2. The internal "controller" path — a sequence of functions that build up an APR pool, a data source, an ObjectMap, and a controller, then expose `playAll`/`playTo`/`rewind`. This is what Xcode actually uses, and what the bridge replicates.

Bridge initialization sequence (`replay_context_init` in `gputrace_replay_bridge.m`):

```
apr_pool_create_ex(&pool, NULL, NULL, NULL)
    ↓
GTMTLReplayController_makeDataSource(path, pool)        → dataSource (APR-based state machine)
    ↓
GTMTLReplaySupport_init(device)
    ↓
[[GTMTLReplayObjectMap alloc] initWithDevice:device]    → objectMap (302 methods, GPU-object registry)
    ↓
GTMTLReplayController_initializeArgumentBufferSupport(dataSource, device, objectMap)
    ↓
GTMTLReplayController_populateUnusedResources(dataSource, objectMap)
    ↓
GTMTLReplayController_makeController(dataSource, pool, device, objectMap, NULL, NULL)
    ↓ → controller
GTMTLReplayController_playAll(controller)        // or playTo(controller, N)
GTMTLReplayController_rewind(controller)         // resets so you can play again
```

The `optimizeRestores(controller)` step is optional — it speeds up subsequent replays at the cost of some restore-state fidelity. The bridge skips it by default; the `config disableOptimizeRestores=0` flag re-enables it.

---

## Function offset table (`GTMTLReplay_CLI` BL relocations)

`GPUToolsReplay.framework` does not export the internal helper functions as named symbols. The bridge resolves them by reading the BL (branch-and-link) instructions inside the exported `GTMTLReplay_CLI` function and decoding their 26-bit relative offsets to recover the absolute target addresses.

| Function | Offset in `GTMTLReplay_CLI` | Signature |
|---|---|---|
| `apr_pool_create_ex` | `+0x050` | `int (void **pool, void *parent, void *abort, void *alloc)` |
| `GTMTLReplayController_makeDataSource` | `+0x13c` | `void* (const char *path, void *pool)` |
| `GTMTLSMContext_getDevice` | `+0x230` | `void* (void *context)` |
| `GTMTLReplaySupport_init` | `+0x888` | `void (void *device)` |
| `initializeArgumentBufferSupport` | `+0x898` | `void (void *ds, void *device, void *objectMap)` |
| `populateUnusedResources` | `+0x8a4` | `void (void *ds, void *objectMap)` |
| `GTMTLReplayController_makeController` | `+0x954` | `void* (ds, pool, device, objectMap, NULL, NULL)` |
| `GTMTLReplayController_optimizeRestores` | `+0x96c` | `void (void *controller)` |

These three are exposed as named exports and reached via `dlsym`:

| Function | Signature |
|---|---|
| `GTMTLReplayController_playAll` | `int (void *controller)` |
| `GTMTLReplayController_playTo` | `int (void *controller, uint32_t targetCallIndex)` |
| `GTMTLReplayController_rewind` | `void (void *controller)` |

The BL-resolution helper in `gputrace_replay_bridge.m`:

```c
static void* resolve_bl(void *cli_fn, int byte_offset) {
    uint32_t *cli = (uint32_t *)cli_fn;
    int idx = byte_offset / 4;
    uint32_t inst = cli[idx];
    if ((inst & 0xFC000000) != 0x94000000) return NULL;  // not a BL
    int32_t imm26 = (int32_t)(inst << 6) >> 6;
    return (void*)((uint64_t)cli_fn + idx * 4 + (int64_t)imm26 * 4);
}
```

If the `EXIT_SYMBOL_FAIL` (code 5) starts appearing after a macOS update, the most likely cause is that the offsets shifted because Apple recompiled the framework with different inlining. Disassemble the new `GTMTLReplay_CLI` (e.g. with `otool -tV`) and update the offsets in `replay_context_init`.

The APR bootstrap is similarly delicate — see the `// APR Bootstrap` comment block in `replay_context_init` for the global pool layout (a `calloc(0x4000)` block carved into an allocator at offset 0 and a global pool at offset 0x100). Apple's APR code expects this exact shape.

---

## GTMTLReplayObjectMap

After replay, the ObjectMap holds every GPU object that the trace touched. It is a fully-formed NSObject subclass with 302 methods. The bridge uses these:

| Selector | Returns | Purpose |
|---|---|---|
| `resources` | `NSDictionary` | Map from numeric ID → `id<MTLTexture>` or `id<MTLBuffer>` |
| `bufferForKey:(uint64_t)` | `id<MTLBuffer>` | Single buffer by key |
| `textureForKey:(uint64_t)` | `id<MTLTexture>` | Single texture by key |
| `libraryForKey:(uint64_t)` | `id<MTLLibrary>` | Library lookup |
| `functionMap` | `NSDictionary` | Function table; keys are 64-bit ints |
| `setLibrary:forKey:` | — | Hot-replace a library (used by `shader` subcommand) |
| `renderPipelineStateForKey:(uint64_t)` | RPS | Render pipeline state |
| `computePipelineStateForKey:(uint64_t)` | CPS | Compute pipeline state |
| `defaultCommandQueue` | `id<MTLCommandQueue>` | Useful if you want to issue your own commands post-replay |

The numeric keys form an integer space shared between libraries (even keys), the matching MTLFunction (next odd key), and pipeline states (a separate continuous range). The bridge's `pipeline` subcommand scans this space up to `max(functionMap.keys) + 50`.

Important detail about `*ForKey:` selectors: they take a **`uint64_t`** (`Q` in ObjC type encoding), not an object. Passing them an `NSNumber` will silently misbehave. The bridge always casts through `objc_msgSend`:

```c
id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, @selector(libraryForKey:), key);
```

---

## Pipeline binary export

Two methods on each `id<MTLLibrary>` (and the underlying `_MTLLibrary` private subclass) yield the bytecode:

| Selector | Returns | Format | Magic |
|---|---|---|---|
| `libraryDataContents` | `NSData` | Apple metallib container | `0x424C544D` ("BLTM") |
| `bitcodeData` | `NSData` | LLVM bitcode wrapper (AIR) | `0x0B17C0DE` |

`metallib` is what `xcrun metal` produces; the binary contains AIR bitcode + metadata + reflection tables. `AIR` is the underlying LLVM bitcode that the on-device GPU compiler then specializes into an AGX-family ISA. Both can be diffed offline; AIR is more useful for tracking shader logic changes because it carries function-level structure, while metallib differences may reflect non-semantic things like reflection ordering.

Pipeline-state classes are device-specific:
- M4 / G16 family → `AGXG16XFamilyRenderPipeline`, `AGXG16XFamilyComputePipeline`
- Older Apple Silicon families have analogous `AGXG13X*` / `AGXG14X*` names.

---

## Why the bridge avoids XPC

The "obvious" path of attaching to `GPUToolsReplayService` and using its XPC interface was rejected because:

1. The XPC services declare entitlements like `com.apple.private.gputools.*` that we cannot carry on an ad-hoc-signed binary.
2. The XPC API is mostly request/response; introspection is bolted on the side and is incomplete relative to what `objectMap` exposes directly.
3. In-process replay is faster (no IPC marshalling) and easier to debug (one address space, no log split between processes).

The cost is that the bridge has to do the bootstrap dance manually (APR, dataSource, ObjectMap, controller). That's what `replay_context_init` is — the manual reproduction of what the XPC service does silently.

---

## Capability boundaries

Things this bridge does **not** do, and why:

| Capability | Why it's missing |
|---|---|
| Raw GPU performance counters (ALU utilization, cache stats, bandwidth) | Requires `com.apple.private.agx.performance-spi` entitlement and SIP off. Apple-internal only. |
| Profiler-derived metrics (Frame Capture's "GPU Time per Encoder" panel) | Computed inside the GUI from raw counters above. |
| Step-by-step shader debugger (Xcode's "Debug Shader" UI) | Requires a separate `GTLLVMHelper` subprocess + private IPC protocol that wasn't reverse-engineered. |
| Modify the .gputrace file on disk | Out of scope; this skill is for investigation. The bridge mutates only the in-memory ObjectMap during a single replay. |

For perf, a workable substitute is host-time `--playto` bisection (Pattern 4 in the playbook). For shader debugging, the substitute is shader hot-replace with instrumented versions (Pattern 5).

---

## What can break across macOS updates

When a macOS update lands, run `bash scripts/test_bridge.sh` first. The likely failure modes, in order:

1. **Symbol resolution (exit code 5)**: a previously named export was renamed or inlined. Check `nm -m /System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay | grep <name>`.
2. **Wrong BL offsets**: the framework was recompiled with different inlining; the offsets in `replay_context_init` don't point to BL instructions anymore. The error message ("Not a BL at CLI+0xNNN") will tell you which one. Re-disassemble `GTMTLReplay_CLI` and patch the offsets.
3. **APR bootstrap layout change**: the global pool struct shape moved. This presents as a NULL `pool` after `apr_pool_create_ex`. You'll need to re-derive the offsets by tracing what the framework's own initializer does.
4. **GPU family class rename**: Apple ships a new chip (G17, G18…) and the pipeline-state class becomes `AGXG17XFamilyRenderPipeline`. Not fatal — `pipeline` subcommand still enumerates them; the `class` field in JSON simply changes value.

The bridge is intentionally written as a single ObjC source file precisely so that recovering from these breakage modes is a small, focused edit.
