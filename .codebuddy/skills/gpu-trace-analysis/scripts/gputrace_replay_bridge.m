/**
 * gputrace_replay_bridge.m — 统一 ObjC Bridge CLI
 *
 * 单一多子命令二进制，覆盖所有已验证的 GPU Trace Replay 能力，JSON 输出。
 *
 * 子命令：
 *   help           — 输出子命令列表
 *   replay         — headless replay（playAll），输出 JSON 摘要
 *   pipeline       — library 枚举 + metallib/AIR 导出 + RPS↔shader 关联（R7.2）
 *   shader         — setLibrary:forKey: 热替换 + 验证（R6.1d）
 *   shader-of-rps  — 通过 RPS_key 反查 fragment/vertex shader 并可选导出 IR（R7.4）
 *   frame-list     — encoder 时间序列 + draw→RPS 映射 + per-cb timing（R7.3）
 *   config         — 调用链控制 + validation 全局变量（R6.1e）
 *
 * 编译：
 *   clang -framework Foundation -framework Metal -ldl -lobjc \
 *         -o gputrace_replay_bridge gputrace_replay_bridge.m
 *
 * 用法：
 *   ./gputrace_replay_bridge help
 *   ./gputrace_replay_bridge replay <path-to-.gputrace>
 *   ./gputrace_replay_bridge pipeline <path-to-.gputrace> [output_dir]
 *   ./gputrace_replay_bridge shader <path-to-.gputrace> <library_key> <metallib_path>
 *   ./gputrace_replay_bridge shader-of-rps <path-to-.gputrace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
 *   ./gputrace_replay_bridge frame-list <path-to-.gputrace> [--with-draws] [--no-draws] [--with-timing]
 *   ./gputrace_replay_bridge config <path-to-.gputrace> [key=value ...]
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <mach/mach_time.h>
#import <signal.h>
#import <setjmp.h>

// ============================================================
#pragma mark - JSON Output Helpers
// ============================================================

// Usage:
//   JSON_BEGIN(); JSON_KV_STR("key", "val"); JSON_KV_INT("n", 42); JSON_END();
// Produces: {"key":"val","n":42}

static int g_json_first = 1;

#define JSON_BEGIN() do { printf("{"); g_json_first = 1; } while(0)
#define JSON_END()   do { printf("}\n"); } while(0)

#define JSON_SEP() do { if (!g_json_first) printf(","); g_json_first = 0; } while(0)

#define JSON_KV_STR(k, v) do { \
    JSON_SEP(); \
    printf("\"%s\":", (k)); \
    json_print_string((v)); \
} while(0)

#define JSON_KV_INT(k, v) do { \
    JSON_SEP(); \
    printf("\"%s\":%lld", (k), (long long)(v)); \
} while(0)

#define JSON_KV_UINT(k, v) do { \
    JSON_SEP(); \
    printf("\"%s\":%llu", (k), (unsigned long long)(v)); \
} while(0)

#define JSON_KV_DOUBLE(k, v) do { \
    JSON_SEP(); \
    printf("\"%s\":%.6f", (k), (double)(v)); \
} while(0)

#define JSON_KV_BOOL(k, v) do { \
    JSON_SEP(); \
    printf("\"%s\":%s", (k), (v) ? "true" : "false"); \
} while(0)

#define JSON_KV_NULL(k) do { \
    JSON_SEP(); \
    printf("\"%s\":null", (k)); \
} while(0)

// JSON-safe string printer (escapes control chars, quotes, backslashes)
static void json_print_string(const char *s) {
    if (!s) { printf("null"); return; }
    printf("\"");
    for (const char *p = s; *p; p++) {
        switch (*p) {
            case '"':  printf("\\\""); break;
            case '\\': printf("\\\\"); break;
            case '\n': printf("\\n");  break;
            case '\r': printf("\\r");  break;
            case '\t': printf("\\t");  break;
            default:
                if ((unsigned char)*p < 0x20)
                    printf("\\u%04x", (unsigned)*p);
                else
                    putchar(*p);
        }
    }
    printf("\"");
}

// ============================================================
#pragma mark - Exit Codes
// ============================================================

enum {
    EXIT_OK             = 0,
    EXIT_USAGE          = 1,
    EXIT_BAD_INPUT      = 2,
    EXIT_NO_METAL       = 3,
    EXIT_DLOPEN_FAIL    = 4,
    EXIT_SYMBOL_FAIL    = 5,
    EXIT_APR_FAIL       = 6,
    EXIT_DATASOURCE     = 7,
    EXIT_OBJECTMAP      = 8,
    EXIT_CONTROLLER     = 9,
    EXIT_REPLAY_FAIL    = 10,
    EXIT_SUBCMD_FAIL    = 11,
    EXIT_PLAYTO_OOR     = 12,  // R7.1 — playto target out of range (graceful)
};

// ============================================================
#pragma mark - SIGSEGV Safety Net (R7.1)
// ============================================================
//
// Replay APIs occasionally segfault on out-of-range / inconsistent state.
// We install handlers for SIGSEGV/SIGBUS *only around* the replay invocations,
// so the bridge can return a structured JSON error instead of crashing the
// caller (which previously made `--playto N` with a too-large N kill the
// process with no diagnostic).

static jmp_buf g_replay_jmp;
static volatile sig_atomic_t g_replay_signal = 0;

static struct sigaction g_prev_segv;
static struct sigaction g_prev_bus;
static int g_handlers_installed = 0;

static void replay_signal_handler(int sig) {
    g_replay_signal = sig;
    longjmp(g_replay_jmp, 1);
}

static void install_replay_signal_handlers(void) {
    if (g_handlers_installed) return;
    struct sigaction sa = {0};
    sa.sa_handler = replay_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;  // allow re-entry on same signal in same handler
    sigaction(SIGSEGV, &sa, &g_prev_segv);
    sigaction(SIGBUS,  &sa, &g_prev_bus);
    g_handlers_installed = 1;
}

static void restore_replay_signal_handlers(void) {
    if (!g_handlers_installed) return;
    sigaction(SIGSEGV, &g_prev_segv, NULL);
    sigaction(SIGBUS,  &g_prev_bus,  NULL);
    g_handlers_installed = 0;
}

// ============================================================
#pragma mark - Helper: resolve internal function via CLI BL offset
// ============================================================

static void* resolve_bl(void *cli_fn, int byte_offset) {
    uint32_t *cli = (uint32_t *)cli_fn;
    int idx = byte_offset / 4;
    uint32_t inst = cli[idx];
    if ((inst & 0xFC000000) != 0x94000000) {
        fprintf(stderr, "[ERROR] Not a BL at CLI+%04x (inst=0x%08x)\n", byte_offset, inst);
        return NULL;
    }
    int32_t imm26 = (int32_t)(inst << 6) >> 6;
    return (void*)((uint64_t)cli_fn + idx * 4 + (int64_t)imm26 * 4);
}

// ============================================================
#pragma mark - Helper: controller current/total call index (R7.1)
// ============================================================
//
// Reverse engineering (LYSK trace, GTMTLReplayController_playTo prologue):
//   +0x038: add  x23, x0, #0x5000          ; x23 = controller + 0x5000
//   +0x110: ldr  w8, [x23, #0x810]         ; w8 = *(controller + 0x5810)
//   +0x114: cmp  w8, w19                   ; w19 = target call index
// Empirically *(controller + 0x5810) holds the LAST PLAYED call index:
//   - Before any play call: 0
//   - After playTo(N)     : N
//   - After playAll       : the trace's total call count
// See Scripts/call_count_probe.m for the verification probe.

#define CONTROLLER_LAST_CALL_INDEX_OFFSET 0x5810

static uint32_t controller_last_call_index(void *controller) {
    if (!controller) return 0;
    return *(uint32_t *)((uint8_t *)controller + CONTROLLER_LAST_CALL_INDEX_OFFSET);
}

// ============================================================
#pragma mark - Function Signatures
// ============================================================

typedef int   (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void  (*supportInit_fn)(void *device);
typedef void  (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void  (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef void  (*optimizeRestores_fn)(void *controller);
typedef int   (*playAll_fn)(void *controller);
typedef int   (*playTo_fn)(void *controller, uint32_t targetCallIndex);
typedef void  (*rewind_fn)(void *controller);

// ============================================================
#pragma mark - Global Replay Context
// ============================================================

typedef struct {
    void *handle;           // dlopen handle
    void *cli_fn;           // GTMTLReplay_CLI base for BL resolution
    void *pool;             // APR pool
    void *dataSource;       // replay data source
    id    device;           // MTLDevice
    id    objectMap;        // GTMTLReplayObjectMap
    void *controller;       // replay controller

    // Resolved function pointers
    apr_pool_create_fn  fn_apr_pool_create;
    makeDataSource_fn   fn_makeDataSource;
    supportInit_fn      fn_supportInit;
    initArgBuf_fn       fn_initArgBuf;
    populateUnused_fn   fn_populateUnused;
    makeController_fn   fn_makeController;
    optimizeRestores_fn fn_optimizeRestores;
    playAll_fn          fn_playAll;
    playTo_fn           fn_playTo;
    rewind_fn           fn_rewind;
} ReplayContext;

static ReplayContext g_ctx = {0};

// ============================================================
#pragma mark - Public Initialization
// ============================================================

/// Initialize replay context: dlopen → resolve symbols → APR → dataSource → controller
/// Returns 0 on success, non-zero exit code on failure.
static int replay_context_init(const char *gputrace_path) {
    // Validate input
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) {
        fprintf(stderr, "[ERROR] Not a valid .gputrace bundle: %s\n", gputrace_path);
        return EXIT_BAD_INPUT;
    }

    // Metal device
    g_ctx.device = MTLCreateSystemDefaultDevice();
    if (!g_ctx.device) {
        fprintf(stderr, "[ERROR] No Metal device available\n");
        return EXIT_NO_METAL;
    }

    // dlopen GPUToolsReplay
    const char *fw_path = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
    g_ctx.handle = dlopen(fw_path, RTLD_NOW);
    if (!g_ctx.handle) {
        fprintf(stderr, "[ERROR] dlopen failed: %s\n", dlerror());
        return EXIT_DLOPEN_FAIL;
    }

    // Resolve symbols
    void *gt_env = dlsym(g_ctx.handle, "GT_ENV");
    g_ctx.cli_fn = dlsym(g_ctx.handle, "GTMTLReplay_CLI");
    if (!gt_env || !g_ctx.cli_fn) {
        fprintf(stderr, "[ERROR] Missing GT_ENV or GTMTLReplay_CLI\n");
        return EXIT_SYMBOL_FAIL;
    }

    g_ctx.fn_apr_pool_create = (apr_pool_create_fn)resolve_bl(g_ctx.cli_fn, 0x50);
    g_ctx.fn_makeDataSource  = (makeDataSource_fn)resolve_bl(g_ctx.cli_fn, 0x13c);
    g_ctx.fn_supportInit     = (supportInit_fn)resolve_bl(g_ctx.cli_fn, 0x888);
    g_ctx.fn_initArgBuf      = (initArgBuf_fn)resolve_bl(g_ctx.cli_fn, 0x898);
    g_ctx.fn_populateUnused  = (populateUnused_fn)resolve_bl(g_ctx.cli_fn, 0x8a4);
    g_ctx.fn_makeController  = (makeController_fn)resolve_bl(g_ctx.cli_fn, 0x954);
    g_ctx.fn_optimizeRestores = (optimizeRestores_fn)resolve_bl(g_ctx.cli_fn, 0x96c);
    g_ctx.fn_playAll         = (playAll_fn)dlsym(g_ctx.handle, "GTMTLReplayController_playAll");
    g_ctx.fn_playTo          = (playTo_fn)dlsym(g_ctx.handle, "GTMTLReplayController_playTo");
    g_ctx.fn_rewind          = (rewind_fn)dlsym(g_ctx.handle, "GTMTLReplayController_rewind");

    if (!g_ctx.fn_apr_pool_create || !g_ctx.fn_makeDataSource || !g_ctx.fn_makeController ||
        !g_ctx.fn_playAll || !g_ctx.fn_rewind) {
        fprintf(stderr, "[ERROR] Failed to resolve critical functions\n");
        return EXIT_SYMBOL_FAIL;
    }

    // APR Bootstrap
    void **global_pool_ptr = (void **)((uint8_t *)gt_env - 0x30);
    if (*global_pool_ptr == NULL) {
        void *block = calloc(1, 0x4000);
        void *allocator = block;
        void *global_pool = (uint8_t *)block + 0x100;
        *(uint64_t *)((uint8_t *)allocator + 0x00) = 20;  // max_index
        *(uint64_t *)((uint8_t *)allocator + 0x08) = 20;  // max_free_index
        *(void **)((uint8_t *)global_pool + 0x00) = allocator;
        *(void **)((uint8_t *)global_pool + 0x30) = allocator;
        *global_pool_ptr = global_pool;
    }

    // Create APR pool
    int rc = g_ctx.fn_apr_pool_create(&g_ctx.pool, NULL, NULL, NULL);
    if (rc != 0 || !g_ctx.pool) {
        fprintf(stderr, "[ERROR] APR pool creation failed (rc=%d)\n", rc);
        return EXIT_APR_FAIL;
    }

    // makeDataSource
    @try {
        g_ctx.dataSource = g_ctx.fn_makeDataSource(gputrace_path, g_ctx.pool);
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] makeDataSource exception: %s\n", [[ex reason] UTF8String]);
        return EXIT_DATASOURCE;
    }
    if (!g_ctx.dataSource) {
        fprintf(stderr, "[ERROR] makeDataSource returned NULL\n");
        return EXIT_DATASOURCE;
    }

    // GTMTLReplaySupport_init
    if (g_ctx.fn_supportInit) {
        @try { g_ctx.fn_supportInit((__bridge void *)g_ctx.device); } @catch (NSException *ex) {}
    }

    // GTMTLReplayObjectMap initWithDevice:
    Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
    if (!mapClass) {
        fprintf(stderr, "[ERROR] GTMTLReplayObjectMap class not found\n");
        return EXIT_OBJECTMAP;
    }
    @try {
        g_ctx.objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:g_ctx.device];
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] objectMap init exception: %s\n", [[ex reason] UTF8String]);
        return EXIT_OBJECTMAP;
    }
    if (!g_ctx.objectMap) {
        fprintf(stderr, "[ERROR] objectMap initialization failed\n");
        return EXIT_OBJECTMAP;
    }

    // initializeArgumentBufferSupport
    if (g_ctx.fn_initArgBuf) {
        @try {
            g_ctx.fn_initArgBuf(g_ctx.dataSource, (__bridge void *)g_ctx.device, (__bridge void *)g_ctx.objectMap);
        } @catch (NSException *ex) {}
    }

    // populateUnusedResources
    if (g_ctx.fn_populateUnused) {
        @try {
            g_ctx.fn_populateUnused(g_ctx.dataSource, (__bridge void *)g_ctx.objectMap);
        } @catch (NSException *ex) {}
    }

    // makeController
    @try {
        g_ctx.controller = g_ctx.fn_makeController(
            g_ctx.dataSource, g_ctx.pool,
            (__bridge void *)g_ctx.device,
            (__bridge void *)g_ctx.objectMap,
            NULL, NULL);
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] makeController exception: %s\n", [[ex reason] UTF8String]);
        return EXIT_CONTROLLER;
    }
    if (!g_ctx.controller) {
        fprintf(stderr, "[ERROR] makeController returned NULL\n");
        return EXIT_CONTROLLER;
    }

    return EXIT_OK;
}

static void replay_context_cleanup(void) {
    if (g_ctx.handle) {
        dlclose(g_ctx.handle);
        g_ctx.handle = NULL;
    }
}

// ============================================================
#pragma mark - Subcommand: help
// ============================================================

static int cmd_help(int argc, const char *argv[]) {
    JSON_BEGIN();
    JSON_KV_STR("tool", "gputrace_replay_bridge");
    JSON_KV_STR("version", "0.4.0");
    JSON_SEP();
    printf("\"commands\":[");
    printf("{\"name\":\"help\",\"description\":\"Show available commands\"}");
    printf(",{\"name\":\"replay\",\"description\":\"Headless replay with playAll/playTo + resource enumeration/export. Always reports total_call_count; --playto N is bounds-checked and returns error \\\"playto_out_of_range\\\" instead of crashing when N > total_call_count.\",\"usage\":\"replay <.gputrace> [--bounds] [--playto N] [--list-resources] [--export ID output_path]\"}");
    printf(",{\"name\":\"pipeline\",\"description\":\"Library enumeration + metallib/AIR export + RPS↔shader correlation (vertex/fragment function/library key + attachment summary captured via method swizzling).\",\"usage\":\"pipeline <.gputrace> [output_dir]\"}");
    printf(",{\"name\":\"shader\",\"description\":\"Hot-replace library via setLibrary:forKey:\",\"usage\":\"shader <.gputrace> <lib_key> <metallib_path>\"}");
    printf(",{\"name\":\"shader-of-rps\",\"description\":\"Reverse-lookup the fragment/vertex shader of a render pipeline state. Reuses the pipeline-subcommand swizzle to map RPS_key -> function_key -> library_key -> metallib + (optionally) llvm-dis to .ll IR.\",\"usage\":\"shader-of-rps <.gputrace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]\"}");
    printf(",{\"name\":\"frame-list\",\"description\":\"Enumerate command buffers / encoders / draw calls captured during replay and map each draw to its render pipeline state. Outputs a tree (command_buffers[].encoders[].draws[]) plus a flat draw_to_rps_map[] view. Optional per-cb GPU timing.\",\"usage\":\"frame-list <.gputrace> [--with-draws] [--no-draws] [--with-timing]\"}");
    printf(",{\"name\":\"config\",\"description\":\"Configuration control (call chain + validation)\",\"usage\":\"config <.gputrace> [key=value ...]\"}");
    printf("]");
    JSON_END();
    return EXIT_OK;
}

// ============================================================
#pragma mark - Pixel Format Helpers
// ============================================================

static NSUInteger bytes_per_pixel_for_format(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm:
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint:
        case MTLPixelFormatA8Unorm:
            return 1;
        case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm:
        case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm:
        case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
            return 2;
        case MTLPixelFormatR32Float: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint:
        case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm:
        case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint:
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm:
        case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float:
        case MTLPixelFormatDepth32Float:
            return 4;
        case MTLPixelFormatRG32Float: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint:
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm:
        case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint:
            return 8;
        case MTLPixelFormatRGBA32Float: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint:
            return 16;
        default:
            return 4; // conservative default
    }
}

static const char* pixel_format_name(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatRGBA8Unorm: return "RGBA8Unorm";
        case MTLPixelFormatRGBA8Unorm_sRGB: return "RGBA8Unorm_sRGB";
        case MTLPixelFormatBGRA8Unorm: return "BGRA8Unorm";
        case MTLPixelFormatBGRA8Unorm_sRGB: return "BGRA8Unorm_sRGB";
        case MTLPixelFormatRGBA16Float: return "RGBA16Float";
        case MTLPixelFormatRGBA32Float: return "RGBA32Float";
        case MTLPixelFormatR8Unorm: return "R8Unorm";
        case MTLPixelFormatR16Float: return "R16Float";
        case MTLPixelFormatR32Float: return "R32Float";
        case MTLPixelFormatRG8Unorm: return "RG8Unorm";
        case MTLPixelFormatRG16Float: return "RG16Float";
        case MTLPixelFormatRG32Float: return "RG32Float";
        case MTLPixelFormatRGB10A2Unorm: return "RGB10A2Unorm";
        case MTLPixelFormatRG11B10Float: return "RG11B10Float";
        case MTLPixelFormatRGB9E5Float: return "RGB9E5Float";
        case MTLPixelFormatDepth32Float: return "Depth32Float";
        case MTLPixelFormatDepth32Float_Stencil8: return "Depth32Float_Stencil8";
        default: return "Other";
    }
}

static const char* texture_type_name(MTLTextureType t) {
    switch (t) {
        case MTLTextureType1D: return "1D";
        case MTLTextureType2D: return "2D";
        case MTLTextureType2DMultisample: return "2DMultisample";
        case MTLTextureType3D: return "3D";
        case MTLTextureTypeCube: return "Cube";
        case MTLTextureType2DArray: return "2DArray";
        default: return "Other";
    }
}

static BOOL is_depth_stencil_format(MTLPixelFormat fmt) {
    return (fmt == MTLPixelFormatDepth16Unorm ||
            fmt == MTLPixelFormatDepth32Float ||
            fmt == MTLPixelFormatStencil8 ||
            fmt == MTLPixelFormatDepth32Float_Stencil8 ||
            fmt == MTLPixelFormatDepth24Unorm_Stencil8 ||
            (NSUInteger)fmt == 255 || (NSUInteger)fmt == 260);
}

// ============================================================
#pragma mark - Resource Metadata Helpers (R7.1 §B)
// ============================================================

static const char* storage_mode_name(MTLStorageMode m) {
    switch (m) {
        case MTLStorageModeShared:     return "shared";
        case MTLStorageModeManaged:    return "managed";
        case MTLStorageModePrivate:    return "private";
        case MTLStorageModeMemoryless: return "memoryless";
        default:                       return "other";
    }
}

static const char* cpu_cache_mode_name(MTLCPUCacheMode m) {
    switch (m) {
        case MTLCPUCacheModeDefaultCache:    return "default";
        case MTLCPUCacheModeWriteCombined:   return "writeCombined";
        default:                              return "other";
    }
}

static const char* hazard_tracking_mode_name(MTLHazardTrackingMode m) {
    switch (m) {
        case MTLHazardTrackingModeDefault:    return "default";
        case MTLHazardTrackingModeUntracked:  return "untracked";
        case MTLHazardTrackingModeTracked:    return "tracked";
        default:                              return "other";
    }
}

// Print MTLTextureUsage as JSON array of strings, e.g. ["shaderRead","renderTarget"].
// `usage` is a bitmask; "unknown" maps to []. Output lacks comma prefix; caller must
// emit the leading "key": before invocation.
static void print_texture_usage_array(MTLTextureUsage usage) {
    printf("[");
    BOOL first = YES;
    if (usage == MTLTextureUsageUnknown || usage == 0) {
        printf("]");
        return;
    }
    #define EMIT(flag, name) do { \
        if (usage & (flag)) { \
            if (!first) printf(","); first = NO; \
            printf("\"%s\"", name); \
        } \
    } while(0)
    EMIT(MTLTextureUsageShaderRead,   "shaderRead");
    EMIT(MTLTextureUsageShaderWrite,  "shaderWrite");
    EMIT(MTLTextureUsageRenderTarget, "renderTarget");
    EMIT(MTLTextureUsagePixelFormatView, "pixelFormatView");
    if (@available(macOS 14.0, *)) {
        EMIT(MTLTextureUsageShaderAtomic, "shaderAtomic");
    }
    #undef EMIT
    printf("]");
}

// ============================================================
#pragma mark - RPS Swizzle Capture (R7.2)
// ============================================================
//
// Background: GTMTLReplayObjectMap exposes RPS objects keyed by trace-internal
// keys, but does NOT expose the back-link from a RPS object to its source
// MTLRenderPipelineDescriptor (and thus to its vertex/fragmentFunction).
// `MTLDevice newRenderPipelineStateWithDescriptor:*` swallows the descriptor
// after compilation; once the PSO is built, that link is gone.
//
// Workaround (validated by LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m
// against LYSK trace, 65/65 RPS reverse-mapped successfully):
//   1. Before any replay invocation, swizzle the device's
//      newRenderPipelineStateWithDescriptor:error: AND
//      newRenderPipelineStateWithDescriptor:options:reflection:error:
//      so we capture each (descriptor, returned-RPS) pair.
//   2. From the captured descriptor, snapshot:
//        - vertexFunction / fragmentFunction (object pointers + names)
//        - color attachment formats / writeMasks
//        - depth/stencil attachment pixel formats
//   3. After replay, build an rps_ptr → rps_key map by probing
//      [objectMap renderPipelineStateForKey:] for k in [0, maxKey].
//   4. Build a fnPtr → fn_key map from objectMap.functionMap.
//   5. Cross-reference to produce {rps_key → vertex_fn_key, fragment_fn_key,
//      vertex_lib_key (= v_fn_key - 1), fragment_lib_key (= f_fn_key - 1),
//      color_attachments[], depth_format, stencil_format}.
//
// The swizzle MUST be installed before replay_context_init(), because
// makeController triggers the framework's PSO compilation pass.

#define MAX_CAPTURED_RPS 1024
#define RPS_LABEL_LEN     128
#define RPS_FN_NAME_LEN   128
#define RPS_FMT_NAME_LEN  48
#define RPS_MAX_COLOR_ATT 8

typedef struct {
    int      index;
    char     format_name[RPS_FMT_NAME_LEN];
    NSUInteger format_value;
    char     write_mask[8]; // "RGBA" / subset
    BOOL     blending_enabled;
} RPSColorAttachmentInfo;

typedef struct {
    void *rps_ptr;
    void *vfunc_ptr;
    void *ffunc_ptr;
    char  vfunc_name[RPS_FN_NAME_LEN];
    char  ffunc_name[RPS_FN_NAME_LEN];
    char  label[RPS_LABEL_LEN];
    int   color_attachment_count;
    RPSColorAttachmentInfo color[RPS_MAX_COLOR_ATT];
    char  depth_format[RPS_FMT_NAME_LEN];
    NSUInteger depth_format_value;
    char  stencil_format[RPS_FMT_NAME_LEN];
    NSUInteger stencil_format_value;
    NSUInteger raster_sample_count;
} RPSCaptureEntry;

static RPSCaptureEntry g_rps_captured[MAX_CAPTURED_RPS];
static int             g_rps_n_captured = 0;
static int             g_rps_swizzles_installed = 0;

// Original IMP storage
typedef id (*new_rps_with_desc_imp)(id self, SEL _cmd, id desc, NSError **err);
typedef id (*new_rps_with_desc_options_imp)(id self, SEL _cmd, id desc, NSUInteger options, id *reflection, NSError **err);

static new_rps_with_desc_imp         g_rps_orig_imp        = NULL;
static new_rps_with_desc_options_imp g_rps_orig_imp_opts   = NULL;

static const char* write_mask_string(MTLColorWriteMask m, char *out, size_t n) {
    size_t i = 0;
    if ((m & MTLColorWriteMaskRed)   && i + 1 < n) out[i++] = 'R';
    if ((m & MTLColorWriteMaskGreen) && i + 1 < n) out[i++] = 'G';
    if ((m & MTLColorWriteMaskBlue)  && i + 1 < n) out[i++] = 'B';
    if ((m & MTLColorWriteMaskAlpha) && i + 1 < n) out[i++] = 'A';
    out[i] = '\0';
    return out;
}

static void rps_capture_descriptor(id rps, id desc) {
    if (!rps || !desc) return;
    if (g_rps_n_captured >= MAX_CAPTURED_RPS) return;
    int idx = g_rps_n_captured++;
    RPSCaptureEntry *e = &g_rps_captured[idx];
    memset(e, 0, sizeof(*e));
    e->rps_ptr = (__bridge void *)rps;

    id vf = nil, ff = nil;
    NSString *label = nil;
    @try { vf = [desc valueForKey:@"vertexFunction"]; } @catch (NSException *ex) {}
    @try { ff = [desc valueForKey:@"fragmentFunction"]; } @catch (NSException *ex) {}
    @try { label = [desc valueForKey:@"label"]; } @catch (NSException *ex) {}

    e->vfunc_ptr = (__bridge void *)vf;
    e->ffunc_ptr = (__bridge void *)ff;
    if (vf) {
        NSString *n = nil;
        @try { n = [vf valueForKey:@"name"]; } @catch (NSException *ex) {}
        snprintf(e->vfunc_name, sizeof(e->vfunc_name), "%s", n ? [n UTF8String] : "");
    }
    if (ff) {
        NSString *n = nil;
        @try { n = [ff valueForKey:@"name"]; } @catch (NSException *ex) {}
        snprintf(e->ffunc_name, sizeof(e->ffunc_name), "%s", n ? [n UTF8String] : "");
    }
    if (label) {
        snprintf(e->label, sizeof(e->label), "%s", [label UTF8String]);
    }

    // Color attachments — MTLRenderPipelineDescriptor.colorAttachments is a
    // MTLRenderPipelineColorAttachmentDescriptorArray; we index it 0..7.
    id colorAttsArr = nil;
    @try { colorAttsArr = [desc valueForKey:@"colorAttachments"]; } @catch (NSException *ex) {}
    if (colorAttsArr) {
        SEL objAtIdx = @selector(objectAtIndexedSubscript:);
        for (int i = 0; i < RPS_MAX_COLOR_ATT; i++) {
            id att = nil;
            if ([colorAttsArr respondsToSelector:objAtIdx]) {
                @try {
                    att = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(colorAttsArr, objAtIdx, (NSUInteger)i);
                } @catch (NSException *ex) {}
            }
            if (!att) continue;
            NSUInteger pf = 0;
            @try { pf = [[att valueForKey:@"pixelFormat"] unsignedLongValue]; } @catch (NSException *ex) {}
            if (pf == 0) continue; // empty slot
            RPSColorAttachmentInfo *c = &e->color[e->color_attachment_count];
            c->index = i;
            c->format_value = pf;
            snprintf(c->format_name, sizeof(c->format_name), "%s", pixel_format_name((MTLPixelFormat)pf));
            MTLColorWriteMask wm = MTLColorWriteMaskAll;
            @try { wm = (MTLColorWriteMask)[[att valueForKey:@"writeMask"] unsignedLongValue]; } @catch (NSException *ex) {}
            write_mask_string(wm, c->write_mask, sizeof(c->write_mask));
            BOOL be = NO;
            @try { be = [[att valueForKey:@"isBlendingEnabled"] boolValue]; } @catch (NSException *ex) {}
            c->blending_enabled = be;
            e->color_attachment_count++;
        }
    }

    // Depth / stencil pixel formats live directly on the descriptor.
    NSUInteger dpf = 0, spf = 0;
    @try { dpf = [[desc valueForKey:@"depthAttachmentPixelFormat"] unsignedLongValue]; } @catch (NSException *ex) {}
    @try { spf = [[desc valueForKey:@"stencilAttachmentPixelFormat"] unsignedLongValue]; } @catch (NSException *ex) {}
    e->depth_format_value = dpf;
    e->stencil_format_value = spf;
    snprintf(e->depth_format,   sizeof(e->depth_format),   "%s", pixel_format_name((MTLPixelFormat)dpf));
    snprintf(e->stencil_format, sizeof(e->stencil_format), "%s", pixel_format_name((MTLPixelFormat)spf));

    // rasterSampleCount (older key on macOS: sampleCount; newer: rasterSampleCount).
    NSUInteger rsc = 1;
    @try { rsc = [[desc valueForKey:@"rasterSampleCount"] unsignedLongValue]; } @catch (NSException *ex) {}
    if (rsc == 0) {
        @try { rsc = [[desc valueForKey:@"sampleCount"] unsignedLongValue]; } @catch (NSException *ex) {}
    }
    e->raster_sample_count = rsc;
}

static id rps_swizzled_imp(id self, SEL _cmd, id desc, NSError **err) {
    id rps = g_rps_orig_imp(self, _cmd, desc, err);
    rps_capture_descriptor(rps, desc);
    return rps;
}

static id rps_swizzled_imp_opts(id self, SEL _cmd, id desc, NSUInteger options, id *refl, NSError **err) {
    id rps = g_rps_orig_imp_opts(self, _cmd, desc, options, refl, err);
    rps_capture_descriptor(rps, desc);
    return rps;
}

// Install the swizzles. Walks the device class hierarchy until it finds an
// implementation owner (e.g. AGXG16XDevice) and replaces the IMP. Idempotent.
static void rps_install_swizzles(void) {
    if (g_rps_swizzles_installed) return;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    Class deviceClass = object_getClass(dev);

    Class c = deviceClass;
    while (c && c != [NSObject class]) {
        Method m = class_getInstanceMethod(c, @selector(newRenderPipelineStateWithDescriptor:error:));
        if (m && method_getImplementation(m)) {
            g_rps_orig_imp = (new_rps_with_desc_imp)method_getImplementation(m);
            method_setImplementation(m, (IMP)rps_swizzled_imp);
            break;
        }
        c = class_getSuperclass(c);
    }
    c = deviceClass;
    while (c && c != [NSObject class]) {
        Method m = class_getInstanceMethod(c, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:));
        if (m && method_getImplementation(m)) {
            g_rps_orig_imp_opts = (new_rps_with_desc_options_imp)method_getImplementation(m);
            method_setImplementation(m, (IMP)rps_swizzled_imp_opts);
            break;
        }
        c = class_getSuperclass(c);
    }
    g_rps_swizzles_installed = 1;
}

// Build (rps_ptr → rps_key) by probing the objectMap for k in [0, maxKey].
// Currently unused by the bridge subcommands (they iterate per-key directly to
// avoid an extra pass), but kept here as documented infrastructure for future
// chunks (R7.3 frame-list correlation) and parity with rps_swizzle_probe.m.
__attribute__((unused))
static NSMutableDictionary *rps_build_ptr_to_key_map(id objectMap, uint64_t maxKey) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    if (!objectMap) return m;
    SEL sel = @selector(renderPipelineStateForKey:);
    for (uint64_t k = 0; k <= maxKey; k++) {
        id rps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, sel, k);
        if (rps) {
            [m setObject:@(k) forKey:[NSValue valueWithNonretainedObject:rps]];
        }
    }
    return m;
}

// Build (fn_ptr → fn_key) from objectMap.functionMap (NSDictionary key→fnObj).
static NSMutableDictionary *rps_build_fn_ptr_to_key_map(id objectMap) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    if (!objectMap) return m;
    id fnMap = nil;
    @try { fnMap = [objectMap performSelector:@selector(functionMap)]; } @catch (NSException *ex) {}
    if (![fnMap isKindOfClass:[NSDictionary class]]) return m;
    for (id key in (NSDictionary *)fnMap) {
        id fn = [(NSDictionary *)fnMap objectForKey:key];
        if (fn) {
            [m setObject:key forKey:[NSValue valueWithNonretainedObject:fn]];
        }
    }
    return m;
}

// Find the capture entry for a given rps_ptr; NULL if not found.
static const RPSCaptureEntry *rps_find_entry(void *rps_ptr) {
    for (int i = 0; i < g_rps_n_captured; i++) {
        if (g_rps_captured[i].rps_ptr == rps_ptr) return &g_rps_captured[i];
    }
    return NULL;
}

// ============================================================
#pragma mark - Frame Swizzle Capture (R7.3)
// ============================================================
//
// "Swizzle-first" approach to building an encoder/draw timeline equivalent to
// what Xcode's Frame Debugger shows. We hook the public Metal API surface so
// that during `playAll` every (commandBuffer, encoder, draw) triple is
// recorded into process-global tables.
//
// Hooks (installed in `frame_install_swizzles`, lazily for encoders):
//   - MTLCommandQueue (concrete impl class)
//       commandBuffer / commandBufferWithUnretainedReferences
//   - MTLCommandBuffer (concrete impl class)
//       renderCommandEncoderWithDescriptor:
//       computeCommandEncoder / computeCommandEncoderWithDispatchType:
//       blitCommandEncoder / blitCommandEncoderWithDescriptor:
//   - MTLRenderCommandEncoder (concrete impl class — discovered at first
//                             renderCommandEncoderWithDescriptor: invocation)
//       setRenderPipelineState:
//       drawPrimitives: variants (3)
//       drawIndexedPrimitives: variants (2)
//       endEncoding
//
// Why swizzle-first instead of reflecting the controller? Reflection of
// `controller.commandBuffers` requires undocumented offsets that may shift on
// every macOS update; the public Metal API is much more stable. The same
// mechanism (install BEFORE replay_context_init / makeController) used by
// R7.2's RPS swizzle also applies here — the framework's PSO compilation
// pass during makeController doesn't issue draw calls, so installing the
// frame swizzles at the same moment is safe.
//
// `controller + 0x5810` (R7.1) provides `last_played_call_index` synchronously,
// so each encoder/draw can record which call index it corresponds to without
// any additional plumbing.

#define MAX_CAPTURED_CB        256
#define MAX_CAPTURED_ENCODERS  1024
#define MAX_CAPTURED_DRAWS     16384
#define ENC_LABEL_LEN          128
#define ENC_TYPE_LEN           16

typedef enum {
    FRAME_ENC_TYPE_RENDER  = 0,
    FRAME_ENC_TYPE_COMPUTE = 1,
    FRAME_ENC_TYPE_BLIT    = 2,
} FrameEncoderType;

typedef struct {
    void   *cb_ptr;
    int     index;
    char    label[ENC_LABEL_LEN];
    int     encoder_first;       // index into g_encoder_captured[]
    int     encoder_count;
    double  gpu_start_ms;        // R7.3 --with-timing; -1 if unavailable
    double  gpu_end_ms;
    double  gpu_duration_ms;
} FrameCBEntry;

typedef struct {
    int     index;
    void   *cb_ptr;              // owning command buffer
    int     cb_index;
    void   *encoder_ptr;
    FrameEncoderType type;
    char    label[ENC_LABEL_LEN];

    // Render encoder snapshot (set when type == RENDER).
    int     color_attachment_count;
    uint64_t color_attachment_ids[RPS_MAX_COLOR_ATT];
    NSUInteger color_attachment_pf[RPS_MAX_COLOR_ATT];
    char    color_attachment_pf_name[RPS_MAX_COLOR_ATT][RPS_FMT_NAME_LEN];
    uint64_t depth_attachment_id;     // 0 if absent
    NSUInteger depth_attachment_pf;
    char    depth_attachment_pf_name[RPS_FMT_NAME_LEN];
    uint64_t stencil_attachment_id;   // 0 if absent
    NSUInteger stencil_attachment_pf;
    char    stencil_attachment_pf_name[RPS_FMT_NAME_LEN];

    uint32_t first_call_index;        // controller.last_call_index at begin
    uint32_t last_call_index;         // updated on endEncoding
    int      draw_first;              // index into g_draws_captured[]
    int      draw_count;

    // Compute encoder fast-path: just count dispatches.
    int      compute_dispatch_count;

    // Currently-bound RPS (for render encoders), used to attribute draws.
    void    *current_rps_ptr;
    BOOL     ended;
} FrameEncoderEntry;

typedef struct {
    int      draw_index_global;
    int      encoder_index;
    int      draw_in_encoder;
    void    *rps_ptr;             // captured at draw time (current encoder.RPS)
    uint32_t call_index;
    int      primitive_type;      // MTLPrimitiveType
    NSUInteger vertex_count;
    NSUInteger instance_count;
    NSUInteger index_count;       // 0 for non-indexed
    BOOL     indexed;
} FrameDrawEntry;

static FrameCBEntry      g_cb_captured[MAX_CAPTURED_CB];
static int               g_cb_n_captured = 0;
static FrameEncoderEntry g_encoder_captured[MAX_CAPTURED_ENCODERS];
static int               g_encoder_n_captured = 0;
static FrameDrawEntry    g_draws_captured[MAX_CAPTURED_DRAWS];
static int               g_draws_n_captured = 0;

static int               g_frame_swizzles_installed = 0;
static int               g_render_enc_swizzled = 0;

// "Capture armed" gate: even though the swizzles are installed early (before
// makeController), the framework's PSO compilation pass may construct
// throw-away command buffers / encoders. We only want draw timeline data from
// the actual `playAll` traversal. The gate is closed by default and toggled
// by `cmd_frame_list` around its `playAll` call.
static volatile int      g_frame_capture_armed = 0;

// Forward declarations.
static void frame_install_render_encoder_swizzles(Class encoderClass);

// --- Original IMP storage ---------------------------------------------------

typedef id   (*queue_cb_imp)(id self, SEL _cmd);
static queue_cb_imp g_orig_queue_cb        = NULL;
static queue_cb_imp g_orig_queue_cb_unret  = NULL;

typedef id   (*cb_render_imp)(id self, SEL _cmd, id desc);
typedef id   (*cb_compute_imp)(id self, SEL _cmd);
typedef id   (*cb_compute_dispatch_imp)(id self, SEL _cmd, NSUInteger dt);
typedef id   (*cb_blit_imp)(id self, SEL _cmd);
typedef id   (*cb_blit_desc_imp)(id self, SEL _cmd, id desc);
static cb_render_imp           g_orig_cb_render          = NULL;
static cb_compute_imp          g_orig_cb_compute         = NULL;
static cb_compute_dispatch_imp g_orig_cb_compute_dispatch = NULL;
static cb_blit_imp             g_orig_cb_blit            = NULL;
static cb_blit_desc_imp        g_orig_cb_blit_desc       = NULL;

typedef void (*enc_set_rps_imp)(id self, SEL _cmd, id rps);
typedef void (*enc_end_imp)(id self, SEL _cmd);
typedef void (*enc_draw_v_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc);
typedef void (*enc_draw_vi_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic);
typedef void (*enc_draw_vib_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic, NSUInteger bi);
typedef void (*enc_draw_idx_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo);
typedef void (*enc_draw_idxi_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo, NSUInteger inst);
typedef void (*enc_draw_idxib_imp)(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo, NSUInteger inst, NSInteger bv, NSUInteger bi);
static enc_set_rps_imp    g_orig_enc_set_rps    = NULL;
static enc_end_imp        g_orig_enc_end        = NULL;
static enc_draw_v_imp     g_orig_enc_draw_v     = NULL;
static enc_draw_vi_imp    g_orig_enc_draw_vi    = NULL;
static enc_draw_vib_imp   g_orig_enc_draw_vib   = NULL;
static enc_draw_idx_imp   g_orig_enc_draw_idx   = NULL;
static enc_draw_idxi_imp  g_orig_enc_draw_idxi  = NULL;
static enc_draw_idxib_imp g_orig_enc_draw_idxib = NULL;

// --- Lookup helpers ---------------------------------------------------------

static FrameCBEntry *frame_find_cb_entry(void *cb_ptr) {
    for (int i = g_cb_n_captured - 1; i >= 0; i--) {
        if (g_cb_captured[i].cb_ptr == cb_ptr) return &g_cb_captured[i];
    }
    return NULL;
}

static FrameEncoderEntry *frame_find_active_encoder(void *encoder_ptr) {
    // Reverse scan: most-recent encoder is most likely match.
    for (int i = g_encoder_n_captured - 1; i >= 0; i--) {
        if (g_encoder_captured[i].encoder_ptr == encoder_ptr &&
            !g_encoder_captured[i].ended) {
            return &g_encoder_captured[i];
        }
    }
    return NULL;
}

// Given a native MTLTexture instance, return its trace-internal resource id
// by linear-scanning the objectMap.resources dictionary. Used when snapshoting
// RenderPassDescriptor.attachments to express them as resource ids the caller
// already knows from `replay --list-resources`.
//
// Linear scan is acceptable here: this runs only at encoder begin (a few
// times per frame) and the resources dict is typically a few hundred entries.
static uint64_t frame_lookup_resource_id(id texture) {
    if (!texture || !g_ctx.objectMap) return 0;
    NSDictionary *res = nil;
    @try { res = [g_ctx.objectMap performSelector:@selector(resources)]; } @catch (NSException *ex) {}
    if (!res) return 0;
    for (id key in res) {
        if (res[key] == texture) {
            return [key unsignedLongLongValue];
        }
    }
    return 0;
}

// --- Capture entry creation -------------------------------------------------

static FrameCBEntry *frame_capture_cb(id cb) {
    if (!g_frame_capture_armed) return NULL;
    if (g_cb_n_captured >= MAX_CAPTURED_CB) return NULL;
    FrameCBEntry *e = &g_cb_captured[g_cb_n_captured];
    memset(e, 0, sizeof(*e));
    e->cb_ptr = (__bridge void *)cb;
    e->index = g_cb_n_captured;
    e->encoder_first = -1;
    e->gpu_start_ms = -1;
    e->gpu_end_ms = -1;
    e->gpu_duration_ms = -1;
    NSString *lbl = nil;
    @try { lbl = [cb performSelector:@selector(label)]; } @catch (NSException *ex) {}
    if (lbl) snprintf(e->label, sizeof(e->label), "%s", [lbl UTF8String]);
    g_cb_n_captured++;
    return e;
}

static void frame_snapshot_render_pass(FrameEncoderEntry *e, id desc) {
    if (!desc) return;
    // colorAttachments is a MTLRenderPassColorAttachmentDescriptorArray;
    // index it [0..7].
    id colorAttsArr = nil;
    @try { colorAttsArr = [desc valueForKey:@"colorAttachments"]; } @catch (NSException *ex) {}
    if (colorAttsArr) {
        SEL idxSel = @selector(objectAtIndexedSubscript:);
        for (int i = 0; i < RPS_MAX_COLOR_ATT; i++) {
            id att = nil;
            if ([colorAttsArr respondsToSelector:idxSel]) {
                @try {
                    att = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(colorAttsArr, idxSel, (NSUInteger)i);
                } @catch (NSException *ex) {}
            }
            if (!att) continue;
            id tex = nil;
            @try { tex = [att valueForKey:@"texture"]; } @catch (NSException *ex) {}
            if (!tex) continue;
            int slot = e->color_attachment_count++;
            if (slot >= RPS_MAX_COLOR_ATT) { e->color_attachment_count = RPS_MAX_COLOR_ATT; break; }
            e->color_attachment_ids[slot] = frame_lookup_resource_id(tex);
            NSUInteger pf = 0;
            @try { pf = [(id<MTLTexture>)tex pixelFormat]; } @catch (NSException *ex) {}
            e->color_attachment_pf[slot] = pf;
            snprintf(e->color_attachment_pf_name[slot],
                     sizeof(e->color_attachment_pf_name[slot]),
                     "%s", pixel_format_name((MTLPixelFormat)pf));
        }
    }
    id depthAtt = nil;
    @try { depthAtt = [desc valueForKey:@"depthAttachment"]; } @catch (NSException *ex) {}
    if (depthAtt) {
        id tex = nil;
        @try { tex = [depthAtt valueForKey:@"texture"]; } @catch (NSException *ex) {}
        if (tex) {
            e->depth_attachment_id = frame_lookup_resource_id(tex);
            NSUInteger pf = 0;
            @try { pf = [(id<MTLTexture>)tex pixelFormat]; } @catch (NSException *ex) {}
            e->depth_attachment_pf = pf;
            snprintf(e->depth_attachment_pf_name, sizeof(e->depth_attachment_pf_name),
                     "%s", pixel_format_name((MTLPixelFormat)pf));
        }
    }
    id stencilAtt = nil;
    @try { stencilAtt = [desc valueForKey:@"stencilAttachment"]; } @catch (NSException *ex) {}
    if (stencilAtt) {
        id tex = nil;
        @try { tex = [stencilAtt valueForKey:@"texture"]; } @catch (NSException *ex) {}
        if (tex) {
            e->stencil_attachment_id = frame_lookup_resource_id(tex);
            NSUInteger pf = 0;
            @try { pf = [(id<MTLTexture>)tex pixelFormat]; } @catch (NSException *ex) {}
            e->stencil_attachment_pf = pf;
            snprintf(e->stencil_attachment_pf_name, sizeof(e->stencil_attachment_pf_name),
                     "%s", pixel_format_name((MTLPixelFormat)pf));
        }
    }
}

static FrameEncoderEntry *frame_capture_encoder(id cb, id encoder, FrameEncoderType type, id passDesc) {
    if (!g_frame_capture_armed) return NULL;
    if (g_encoder_n_captured >= MAX_CAPTURED_ENCODERS) return NULL;
    FrameCBEntry *cbE = frame_find_cb_entry((__bridge void *)cb);
    // If the cb wasn't captured (cb_n_captured saturated), still record encoder
    // with a synthetic cb_index of -1 to keep ordering consistent.
    int cb_index = cbE ? cbE->index : -1;
    FrameEncoderEntry *e = &g_encoder_captured[g_encoder_n_captured];
    memset(e, 0, sizeof(*e));
    e->index = g_encoder_n_captured;
    e->cb_ptr = (__bridge void *)cb;
    e->cb_index = cb_index;
    e->encoder_ptr = (__bridge void *)encoder;
    e->type = type;
    e->draw_first = -1;
    e->depth_attachment_pf = 0;
    e->stencil_attachment_pf = 0;
    NSString *lbl = nil;
    @try { lbl = [encoder performSelector:@selector(label)]; } @catch (NSException *ex) {}
    if (lbl) snprintf(e->label, sizeof(e->label), "%s", [lbl UTF8String]);
    e->first_call_index = controller_last_call_index(g_ctx.controller);
    e->last_call_index = e->first_call_index;
    if (type == FRAME_ENC_TYPE_RENDER) {
        frame_snapshot_render_pass(e, passDesc);
    }
    if (cbE) {
        if (cbE->encoder_first < 0) cbE->encoder_first = e->index;
        cbE->encoder_count++;
    }
    g_encoder_n_captured++;
    return e;
}

// --- Swizzle thunks: MTLCommandQueue ---------------------------------------

static id swz_queue_cb(id self, SEL _cmd) {
    id cb = g_orig_queue_cb(self, _cmd);
    if (cb) frame_capture_cb(cb);
    return cb;
}

static id swz_queue_cb_unret(id self, SEL _cmd) {
    id cb = g_orig_queue_cb_unret(self, _cmd);
    if (cb) frame_capture_cb(cb);
    return cb;
}

// --- Swizzle thunks: MTLCommandBuffer --------------------------------------

static id swz_cb_render(id self, SEL _cmd, id desc) {
    id enc = g_orig_cb_render(self, _cmd, desc);
    if (enc) {
        // Lazily install render-encoder swizzles on the very first observed
        // encoder: only at this point do we know the concrete impl class.
        if (!g_render_enc_swizzled) {
            frame_install_render_encoder_swizzles(object_getClass(enc));
            g_render_enc_swizzled = 1;
        }
        frame_capture_encoder(self, enc, FRAME_ENC_TYPE_RENDER, desc);
    }
    return enc;
}

static id swz_cb_compute(id self, SEL _cmd) {
    id enc = g_orig_cb_compute(self, _cmd);
    if (enc) frame_capture_encoder(self, enc, FRAME_ENC_TYPE_COMPUTE, nil);
    return enc;
}

static id swz_cb_compute_dispatch(id self, SEL _cmd, NSUInteger dt) {
    id enc = g_orig_cb_compute_dispatch(self, _cmd, dt);
    if (enc) frame_capture_encoder(self, enc, FRAME_ENC_TYPE_COMPUTE, nil);
    return enc;
}

static id swz_cb_blit(id self, SEL _cmd) {
    id enc = g_orig_cb_blit(self, _cmd);
    if (enc) frame_capture_encoder(self, enc, FRAME_ENC_TYPE_BLIT, nil);
    return enc;
}

static id swz_cb_blit_desc(id self, SEL _cmd, id desc) {
    id enc = g_orig_cb_blit_desc(self, _cmd, desc);
    if (enc) frame_capture_encoder(self, enc, FRAME_ENC_TYPE_BLIT, nil);
    return enc;
}

// --- Swizzle thunks: MTLRenderCommandEncoder -------------------------------

static void swz_enc_set_rps(id self, SEL _cmd, id rps) {
    g_orig_enc_set_rps(self, _cmd, rps);
    if (!g_frame_capture_armed) return;
    FrameEncoderEntry *e = frame_find_active_encoder((__bridge void *)self);
    if (e) e->current_rps_ptr = (__bridge void *)rps;
}

// Common draw recording (called from each variant's thunk). All counts are
// recorded as captured; primitive_type is the raw MTLPrimitiveType numeric.
static void frame_record_draw(id self, BOOL indexed,
                              NSUInteger primitive_type,
                              NSUInteger vertex_count,
                              NSUInteger instance_count,
                              NSUInteger index_count) {
    if (!g_frame_capture_armed) return;
    FrameEncoderEntry *e = frame_find_active_encoder((__bridge void *)self);
    if (!e) return;
    if (g_draws_n_captured >= MAX_CAPTURED_DRAWS) return;
    FrameDrawEntry *d = &g_draws_captured[g_draws_n_captured];
    d->draw_index_global = g_draws_n_captured;
    d->encoder_index = e->index;
    d->draw_in_encoder = e->draw_count;
    d->rps_ptr = e->current_rps_ptr;
    d->call_index = controller_last_call_index(g_ctx.controller);
    d->primitive_type = (int)primitive_type;
    d->vertex_count = vertex_count;
    d->instance_count = instance_count;
    d->index_count = index_count;
    d->indexed = indexed;
    if (e->draw_first < 0) e->draw_first = d->draw_index_global;
    e->draw_count++;
    g_draws_n_captured++;
}

static void swz_enc_draw_v(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc) {
    g_orig_enc_draw_v(self, _cmd, pt, vs, vc);
    frame_record_draw(self, NO, pt, vc, 1, 0);
}
static void swz_enc_draw_vi(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic) {
    g_orig_enc_draw_vi(self, _cmd, pt, vs, vc, ic);
    frame_record_draw(self, NO, pt, vc, ic, 0);
}
static void swz_enc_draw_vib(id self, SEL _cmd, NSUInteger pt, NSUInteger vs, NSUInteger vc, NSUInteger ic, NSUInteger bi) {
    g_orig_enc_draw_vib(self, _cmd, pt, vs, vc, ic, bi);
    frame_record_draw(self, NO, pt, vc, ic, 0);
}
static void swz_enc_draw_idx(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo) {
    g_orig_enc_draw_idx(self, _cmd, pt, ic, it, ib, ibo);
    frame_record_draw(self, YES, pt, 0, 1, ic);
}
static void swz_enc_draw_idxi(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo, NSUInteger inst) {
    g_orig_enc_draw_idxi(self, _cmd, pt, ic, it, ib, ibo, inst);
    frame_record_draw(self, YES, pt, 0, inst, ic);
}
static void swz_enc_draw_idxib(id self, SEL _cmd, NSUInteger pt, NSUInteger ic, NSUInteger it, id ib, NSUInteger ibo, NSUInteger inst, NSInteger bv, NSUInteger bi) {
    g_orig_enc_draw_idxib(self, _cmd, pt, ic, it, ib, ibo, inst, bv, bi);
    frame_record_draw(self, YES, pt, 0, inst, ic);
}

static void swz_enc_end(id self, SEL _cmd) {
    if (g_frame_capture_armed) {
        FrameEncoderEntry *e = frame_find_active_encoder((__bridge void *)self);
        if (e) {
            e->last_call_index = controller_last_call_index(g_ctx.controller);
            e->ended = YES;
            e->current_rps_ptr = NULL;
        }
    }
    g_orig_enc_end(self, _cmd);
}

// --- Swizzle install helpers -----------------------------------------------

// Walk the class hierarchy starting at `cls` until a class that owns the
// instance method `sel` is found, swizzle it, and store the original IMP via
// `orig_slot`. Returns the class that was modified, or Nil on miss.
static Class swizzle_in_hierarchy(Class cls, SEL sel, IMP newImp, void **orig_slot) {
    Class c = cls;
    while (c && c != [NSObject class]) {
        Method m = class_getInstanceMethod(c, sel);
        if (m) {
            // class_getInstanceMethod walks up the hierarchy; check that this
            // class actually owns the method to avoid corrupting NSObject.
            unsigned int n = 0;
            Method *methods = class_copyMethodList(c, &n);
            BOOL owns = NO;
            for (unsigned int i = 0; i < n; i++) {
                if (method_getName(methods[i]) == sel) { owns = YES; break; }
            }
            if (methods) free(methods);
            if (owns) {
                *orig_slot = (void *)method_getImplementation(m);
                method_setImplementation(m, newImp);
                return c;
            }
        }
        c = class_getSuperclass(c);
    }
    return Nil;
}

static void frame_install_render_encoder_swizzles(Class encoderClass) {
    if (!encoderClass) return;
    swizzle_in_hierarchy(encoderClass, @selector(setRenderPipelineState:),
                         (IMP)swz_enc_set_rps, (void **)&g_orig_enc_set_rps);
    swizzle_in_hierarchy(encoderClass, @selector(endEncoding),
                         (IMP)swz_enc_end, (void **)&g_orig_enc_end);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawPrimitives:vertexStart:vertexCount:),
                         (IMP)swz_enc_draw_v, (void **)&g_orig_enc_draw_v);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),
                         (IMP)swz_enc_draw_vi, (void **)&g_orig_enc_draw_vi);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:),
                         (IMP)swz_enc_draw_vib, (void **)&g_orig_enc_draw_vib);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:),
                         (IMP)swz_enc_draw_idx, (void **)&g_orig_enc_draw_idx);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:),
                         (IMP)swz_enc_draw_idxi, (void **)&g_orig_enc_draw_idxi);
    swizzle_in_hierarchy(encoderClass,
                         @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:),
                         (IMP)swz_enc_draw_idxib, (void **)&g_orig_enc_draw_idxib);
}

// Install MTLCommandQueue/MTLCommandBuffer swizzles up-front. Render encoder
// swizzles are installed lazily on first encoder creation (see swz_cb_render).
//
// Strategy: we need concrete impl classes for queue/buffer. The cheap way is
// to create a throwaway queue+cb from MTLCreateSystemDefaultDevice() once,
// take object_getClass on the instances, then walk the class hierarchy. The
// throwaway pair is released immediately (frame_capture_armed is still 0 at
// this point so capture is silent — the captured array stays empty).
static void frame_install_swizzles(void) {
    if (g_frame_swizzles_installed) return;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return;
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        if (!queue) return;
        Class queueClass = object_getClass(queue);

        // commandBuffer / commandBufferWithUnretainedReferences
        swizzle_in_hierarchy(queueClass, @selector(commandBuffer),
                             (IMP)swz_queue_cb, (void **)&g_orig_queue_cb);
        swizzle_in_hierarchy(queueClass, @selector(commandBufferWithUnretainedReferences),
                             (IMP)swz_queue_cb_unret, (void **)&g_orig_queue_cb_unret);

        // Now create a CB to discover its concrete class. The capture gate is
        // still closed so this throwaway CB doesn't pollute g_cb_captured.
        id<MTLCommandBuffer> probeCB = nil;
        @try { probeCB = [queue commandBuffer]; } @catch (NSException *ex) {}
        if (probeCB) {
            Class cbClass = object_getClass(probeCB);
            swizzle_in_hierarchy(cbClass, @selector(renderCommandEncoderWithDescriptor:),
                                 (IMP)swz_cb_render, (void **)&g_orig_cb_render);
            swizzle_in_hierarchy(cbClass, @selector(computeCommandEncoder),
                                 (IMP)swz_cb_compute, (void **)&g_orig_cb_compute);
            swizzle_in_hierarchy(cbClass, @selector(computeCommandEncoderWithDispatchType:),
                                 (IMP)swz_cb_compute_dispatch, (void **)&g_orig_cb_compute_dispatch);
            swizzle_in_hierarchy(cbClass, @selector(blitCommandEncoder),
                                 (IMP)swz_cb_blit, (void **)&g_orig_cb_blit);
            swizzle_in_hierarchy(cbClass, @selector(blitCommandEncoderWithDescriptor:),
                                 (IMP)swz_cb_blit_desc, (void **)&g_orig_cb_blit_desc);
        }
    }
    g_frame_swizzles_installed = 1;
}

// Reset capture buffers between subcommand invocations (rare — only matters
// if the same process is used multiple times, e.g. in tests).
static void frame_capture_reset(void) {
    g_cb_n_captured = 0;
    g_encoder_n_captured = 0;
    g_draws_n_captured = 0;
}

// ============================================================
#pragma mark - Subcommand: replay
// ============================================================

/// Parse replay options from argv:
///   replay <trace> [--playto N] [--list-resources] [--export ID output_path] [--bounds]
typedef struct {
    const char *trace_path;
    int64_t playto_index;      // -1 = playAll (default), >=0 = playTo target
    BOOL list_resources;
    int64_t export_id;         // -1 = no export
    const char *export_path;
    BOOL bounds_only;          // R7.1 — print only total_call_count and exit
} ReplayOptions;

static ReplayOptions parse_replay_options(int argc, const char *argv[]) {
    ReplayOptions opts = {0};
    opts.playto_index = -1;
    opts.export_id = -1;

    if (argc >= 1) opts.trace_path = argv[0];

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--playto") == 0 && i + 1 < argc) {
            opts.playto_index = strtoll(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--list-resources") == 0) {
            opts.list_resources = YES;
        } else if (strcmp(argv[i], "--export") == 0 && i + 2 < argc) {
            opts.export_id = strtoll(argv[++i], NULL, 10);
            opts.export_path = argv[++i];
        } else if (strcmp(argv[i], "--bounds") == 0) {
            opts.bounds_only = YES;
        }
    }
    return opts;
}

// Run playAll, capturing SIGSEGV/SIGBUS via the local signal handler.
// Returns playAll's rc on success, or a negative value with *out_signal set.
static int safe_playAll(double *out_elapsed_ms, int *out_signal) {
    *out_signal = 0;
    install_replay_signal_handlers();
    g_replay_signal = 0;
    int rc = -1;
    uint64_t t0 = mach_absolute_time();
    if (setjmp(g_replay_jmp) == 0) {
        @try {
            rc = g_ctx.fn_playAll(g_ctx.controller);
        } @catch (NSException *ex) {
            rc = -2;
        }
    } else {
        rc = -3;
        *out_signal = (int)g_replay_signal;
    }
    uint64_t t1 = mach_absolute_time();
    restore_replay_signal_handlers();
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    *out_elapsed_ms = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
    return rc;
}

// Run playTo(target), capturing SIGSEGV/SIGBUS via the local signal handler.
static int safe_playTo(uint32_t target, double *out_elapsed_ms, int *out_signal) {
    *out_signal = 0;
    install_replay_signal_handlers();
    g_replay_signal = 0;
    int rc = -1;
    uint64_t t0 = mach_absolute_time();
    if (setjmp(g_replay_jmp) == 0) {
        @try {
            rc = g_ctx.fn_playTo(g_ctx.controller, target);
        } @catch (NSException *ex) {
            rc = -2;
        }
    } else {
        rc = -3;
        *out_signal = (int)g_replay_signal;
    }
    uint64_t t1 = mach_absolute_time();
    restore_replay_signal_handlers();
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    *out_elapsed_ms = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
    return rc;
}

static int cmd_replay(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge replay <path-to-.gputrace> [options]\n");
        fprintf(stderr, "Options:\n");
        fprintf(stderr, "  --playto N           Replay to specific call index (default: playAll)\n");
        fprintf(stderr, "  --bounds             Probe total_call_count and exit (no resource ops)\n");
        fprintf(stderr, "  --list-resources     Enumerate all resources after replay\n");
        fprintf(stderr, "  --export ID PATH     Export resource ID to binary file\n");
        return EXIT_USAGE;
    }

    ReplayOptions opts = parse_replay_options(argc, argv);
    if (!opts.trace_path) return EXIT_USAGE;

    int rc = replay_context_init(opts.trace_path);
    if (rc != EXIT_OK) return rc;

    // R7.1 — Probe total_call_count by running playAll first. This serves
    // double duty: validates the trace replays cleanly, and gives us the
    // upper bound for any --playto request so we can fail gracefully on OOR.
    double probe_ms = 0;
    int probe_signal = 0;
    int probe_rc = safe_playAll(&probe_ms, &probe_signal);
    uint32_t total_call_count = controller_last_call_index(g_ctx.controller);

    // --- --bounds mode: just emit metadata and exit ---
    if (opts.bounds_only) {
        JSON_BEGIN();
        JSON_KV_STR("command", "replay");
        JSON_KV_STR("trace_path", opts.trace_path);
        JSON_KV_STR("device", [[g_ctx.device name] UTF8String]);
        JSON_KV_BOOL("bounds_only", YES);
        JSON_KV_INT("probe_rc", probe_rc);
        if (probe_signal != 0) JSON_KV_INT("probe_signal", probe_signal);
        JSON_KV_DOUBLE("probe_elapsed_ms", probe_ms);
        JSON_KV_UINT("total_call_count", total_call_count);
        JSON_END();
        replay_context_cleanup();
        return EXIT_OK;
    }

    // --- --playto N mode: validate target against total_call_count ---
    if (opts.playto_index >= 0) {
        if (probe_rc != 0 || total_call_count == 0) {
            // Probe failed — we cannot trust the bound; refuse rather than
            // attempt a possibly-OOR playTo.
            JSON_BEGIN();
            JSON_KV_STR("command", "replay");
            JSON_KV_STR("trace_path", opts.trace_path);
            JSON_KV_STR("error", "bounds_probe_failed");
            JSON_KV_INT("probe_rc", probe_rc);
            if (probe_signal != 0) JSON_KV_INT("probe_signal", probe_signal);
            JSON_KV_DOUBLE("probe_elapsed_ms", probe_ms);
            JSON_KV_UINT("total_call_count", total_call_count);
            JSON_END();
            replay_context_cleanup();
            return EXIT_REPLAY_FAIL;
        }
        if ((uint64_t)opts.playto_index > (uint64_t)total_call_count) {
            // Out of range — return structured error, do NOT call playTo (which
            // would SIGSEGV with no diagnostic in older bridge versions).
            JSON_BEGIN();
            JSON_KV_STR("command", "replay");
            JSON_KV_STR("trace_path", opts.trace_path);
            JSON_KV_STR("error", "playto_out_of_range");
            JSON_KV_INT("playto_index", opts.playto_index);
            JSON_KV_UINT("total_call_count", total_call_count);
            JSON_KV_UINT("max", total_call_count);
            JSON_END();
            replay_context_cleanup();
            return EXIT_PLAYTO_OOR;
        }
    }

    // At this point: playAll has already populated objectMap. For the default
    // (no --playto) path we keep its result. For --playto, rewind + playTo.
    int play_rc = probe_rc;
    double elapsed_ms = probe_ms;
    int play_signal = probe_signal;

    if (opts.playto_index >= 0) {
        @try { g_ctx.fn_rewind(g_ctx.controller); } @catch (NSException *ex) {}
        play_rc = safe_playTo((uint32_t)opts.playto_index, &elapsed_ms, &play_signal);
    }

    // Gather resources (post-replay)
    NSDictionary *resources = nil;
    @try {
        resources = [g_ctx.objectMap performSelector:@selector(resources)];
    } @catch (NSException *ex) {}
    NSUInteger resource_count = resources ? [resources count] : 0;

    // Output JSON
    JSON_BEGIN();
    JSON_KV_STR("command", "replay");
    JSON_KV_STR("trace_path", opts.trace_path);
    JSON_KV_STR("device", [[g_ctx.device name] UTF8String]);
    if (opts.playto_index >= 0) {
        JSON_KV_INT("playto_index", opts.playto_index);
    }
    JSON_KV_INT("replay_rc", play_rc);
    if (play_signal != 0) JSON_KV_INT("replay_signal", play_signal);
    JSON_KV_BOOL("success", play_rc == 0);
    JSON_KV_DOUBLE("elapsed_ms", elapsed_ms);
    JSON_KV_UINT("resource_count", resource_count);
    JSON_KV_UINT("total_call_count", total_call_count);
    JSON_KV_UINT("last_call_index", controller_last_call_index(g_ctx.controller));

    // --- Resource enumeration ---
    if (opts.list_resources && resources) {
        JSON_SEP();
        printf("\"resources\":[");
        BOOL first_res = YES;

        for (id key in resources) {
            id value = resources[key];
            if (!first_res) printf(",");
            first_res = NO;

            uint64_t resID = [key unsignedLongLongValue];
            printf("{\"id\":%llu", resID);

            if ([value conformsToProtocol:@protocol(MTLTexture)]) {
                id<MTLTexture> tex = (id<MTLTexture>)value;
                printf(",\"type\":\"texture\"");
                printf(",\"width\":%lu", (unsigned long)tex.width);
                printf(",\"height\":%lu", (unsigned long)tex.height);
                printf(",\"depth\":%lu", (unsigned long)tex.depth);
                printf(",\"pixelFormat\":%lu", (unsigned long)tex.pixelFormat);
                printf(",\"pixelFormatName\":");
                json_print_string(pixel_format_name(tex.pixelFormat));
                printf(",\"textureType\":");
                json_print_string(texture_type_name(tex.textureType));
                printf(",\"mipmapLevelCount\":%lu", (unsigned long)tex.mipmapLevelCount);
                // R7.1 §B — extended texture metadata
                printf(",\"sampleCount\":%lu", (unsigned long)tex.sampleCount);
                printf(",\"arrayLength\":%lu", (unsigned long)tex.arrayLength);
                printf(",\"storageMode\":");
                json_print_string(storage_mode_name(tex.storageMode));
                printf(",\"cpuCacheMode\":");
                json_print_string(cpu_cache_mode_name(tex.cpuCacheMode));
                printf(",\"hazardTrackingMode\":");
                json_print_string(hazard_tracking_mode_name(tex.hazardTrackingMode));
                printf(",\"usage\":");
                print_texture_usage_array(tex.usage);
                printf(",\"framebufferOnly\":%s", tex.framebufferOnly ? "true" : "false");
                BOOL memoryless = (tex.storageMode == MTLStorageModeMemoryless);
                printf(",\"memoryless\":%s", memoryless ? "true" : "false");
                printf(",\"isDepthStencil\":%s", is_depth_stencil_format(tex.pixelFormat) ? "true" : "false");
                if (tex.label) { printf(",\"label\":"); json_print_string([tex.label UTF8String]); }
            } else if ([value conformsToProtocol:@protocol(MTLBuffer)]) {
                id<MTLBuffer> buf = (id<MTLBuffer>)value;
                printf(",\"type\":\"buffer\"");
                printf(",\"length\":%lu", (unsigned long)buf.length);
                // R7.1 §B — extended buffer metadata
                printf(",\"storageMode\":");
                json_print_string(storage_mode_name(buf.storageMode));
                printf(",\"cpuCacheMode\":");
                json_print_string(cpu_cache_mode_name(buf.cpuCacheMode));
                printf(",\"hazardTrackingMode\":");
                json_print_string(hazard_tracking_mode_name(buf.hazardTrackingMode));
                if (buf.label) { printf(",\"label\":"); json_print_string([buf.label UTF8String]); }
            } else {
                printf(",\"type\":\"other\"");
                printf(",\"class\":");
                json_print_string(class_getName([value class]));
            }
            printf("}");
        }
        printf("]");
    }

    // --- Resource export ---
    if (opts.export_id >= 0 && opts.export_path && resources) {
        NSNumber *exportKey = @((uint64_t)opts.export_id);
        id exportObj = resources[exportKey];
        BOOL exported = NO;
        NSUInteger export_bytes = 0;

        if (!exportObj) {
            JSON_KV_STR("export_error", "resource ID not found");
        } else if ([exportObj conformsToProtocol:@protocol(MTLTexture)]) {
            id<MTLTexture> tex = (id<MTLTexture>)exportObj;
            if (is_depth_stencil_format(tex.pixelFormat)) {
                JSON_KV_STR("export_error", "depth/stencil format cannot be exported via getBytes");
            } else if (tex.textureType != MTLTextureType2D) {
                JSON_KV_STR("export_error", "only 2D textures supported for export");
            } else {
                NSUInteger bpp = bytes_per_pixel_for_format(tex.pixelFormat);
                NSUInteger bpr = tex.width * bpp;
                NSUInteger totalBytes = bpr * tex.height;
                void *pixelData = malloc(totalBytes);
                if (pixelData) {
                    @try {
                        [tex getBytes:pixelData
                          bytesPerRow:bpr
                           fromRegion:MTLRegionMake2D(0, 0, tex.width, tex.height)
                          mipmapLevel:0];
                        FILE *f = fopen(opts.export_path, "wb");
                        if (f) {
                            fwrite(pixelData, 1, totalBytes, f);
                            fclose(f);
                            exported = YES;
                            export_bytes = totalBytes;
                        } else {
                            JSON_KV_STR("export_error", "cannot open output file");
                        }
                    } @catch (NSException *ex) {
                        char err_buf[256];
                        snprintf(err_buf, sizeof(err_buf), "getBytes exception: %s", [[ex reason] UTF8String]);
                        JSON_KV_STR("export_error", err_buf);
                    }
                    free(pixelData);
                }
            }
        } else if ([exportObj conformsToProtocol:@protocol(MTLBuffer)]) {
            id<MTLBuffer> buf = (id<MTLBuffer>)exportObj;
            void *contents = [buf contents];
            if (contents && buf.length > 0) {
                FILE *f = fopen(opts.export_path, "wb");
                if (f) {
                    fwrite(contents, 1, buf.length, f);
                    fclose(f);
                    exported = YES;
                    export_bytes = buf.length;
                } else {
                    JSON_KV_STR("export_error", "cannot open output file");
                }
            } else {
                JSON_KV_STR("export_error", "buffer has no contents");
            }
        } else {
            JSON_KV_STR("export_error", "resource is neither texture nor buffer");
        }

        if (exported) {
            JSON_KV_UINT("export_id", (uint64_t)opts.export_id);
            JSON_KV_STR("export_path", opts.export_path);
            JSON_KV_UINT("export_bytes", export_bytes);
        }
    }

    JSON_END();

    replay_context_cleanup();
    return (play_rc == 0) ? EXIT_OK : EXIT_REPLAY_FAIL;
}

// ============================================================
#pragma mark - Subcommand: pipeline
// ============================================================

static int cmd_pipeline(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge pipeline <path-to-.gputrace> [output_dir]\n");
        fprintf(stderr, "\nEnumerates libraries, pipeline states, functions.\n");
        fprintf(stderr, "Exports metallib + AIR bitcode to output_dir.\n");
        return EXIT_USAGE;
    }

    const char *trace_path = argv[0];
    const char *output_dir_c = (argc >= 2) ? argv[1] : NULL;

    // R7.2 — install method swizzling on the device's
    // newRenderPipelineStateWithDescriptor:* BEFORE replay_context_init.
    // makeController triggers PSO compilation; if the swizzle isn't installed
    // by then, we miss every (rps, descriptor) pair.
    rps_install_swizzles();

    int rc = replay_context_init(trace_path);
    if (rc != EXIT_OK) return rc;

    // playAll to populate objectMap
    int play_rc = -1;
    @try {
        play_rc = g_ctx.fn_playAll(g_ctx.controller);
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] playAll exception: %s\n", [[ex reason] UTF8String]);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }
    if (play_rc != 0) {
        fprintf(stderr, "[ERROR] playAll failed (rc=%d)\n", play_rc);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }

    // Setup output directory
    NSString *outputDir = nil;
    if (output_dir_c) {
        outputDir = [NSString stringWithUTF8String:output_dir_c];
    } else {
        outputDir = @".";
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Determine max key from functionMap.
    // Note: render-pipeline-state keys live in a *different* numeric range than
    // function keys — they're typically larger (e.g. LYSK trace: max fn key
    // ~439 but RPS keys go up through ~496). We scan generously for RPS so
    // we don't silently truncate the upper tail; the cost is bounded by the
    // objectMap probe being a O(1) dictionary lookup per index.
    id funcMapRaw = [g_ctx.objectMap performSelector:@selector(functionMap)];
    uint64_t maxKey = 200;
    if (funcMapRaw && [funcMapRaw isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)funcMapRaw) {
            uint64_t kv = [key unsignedLongLongValue];
            if (kv > maxKey) maxKey = kv;
        }
        maxKey += 50;
    }
    // RPS-specific scan ceiling: rps keys may run well past fn keys. Add a
    // generous headroom; the probe is cheap (one objc_msgSend per slot).
    uint64_t rpsMaxKey = maxKey + 200;

    // === Scan libraries ===
    SEL libSel = @selector(libraryForKey:);
    SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
    SEL bcSel = NSSelectorFromString(@"bitcodeData");

    int libs_found = 0, metallibs_exported = 0, bitcodes_exported = 0;

    // Start JSON output
    JSON_BEGIN();
    JSON_KV_STR("command", "pipeline");
    JSON_KV_STR("trace_path", trace_path);
    JSON_KV_STR("device", [[g_ctx.device name] UTF8String]);
    JSON_KV_STR("output_dir", [outputDir UTF8String]);

    // Libraries array
    JSON_SEP();
    printf("\"libraries\":[");
    BOOL first_lib = YES;

    for (uint64_t k = 0; k <= maxKey; k++) {
        id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, libSel, k);
        if (!lib) continue;
        if (![lib conformsToProtocol:@protocol(MTLLibrary)]) continue;

        id<MTLLibrary> mtlLib = (id<MTLLibrary>)lib;
        libs_found++;

        if (!first_lib) printf(",");
        first_lib = NO;

        printf("{\"key\":%llu", k);
        printf(",\"class\":");
        json_print_string(class_getName([lib class]));

        NSArray *funcNames = [mtlLib functionNames];
        printf(",\"function_count\":%lu", (unsigned long)[funcNames count]);
        if (funcNames && [funcNames count] > 0) {
            printf(",\"functions\":[");
            for (NSUInteger fi = 0; fi < [funcNames count]; fi++) {
                if (fi > 0) printf(",");
                json_print_string([[funcNames objectAtIndex:fi] UTF8String]);
            }
            printf("]");
        }

        if (mtlLib.installName) {
            printf(",\"installName\":");
            json_print_string([mtlLib.installName UTF8String]);
        }
        if (mtlLib.label) {
            printf(",\"label\":");
            json_print_string([mtlLib.label UTF8String]);
        }

        // Export metallib
        if ([lib respondsToSelector:ldcSel]) {
            id data = [lib performSelector:ldcSel];
            if (data && [data isKindOfClass:[NSData class]]) {
                NSData *d = (NSData *)data;
                printf(",\"metallib_size\":%lu", (unsigned long)[d length]);

                if ([d length] >= 4) {
                    uint32_t magic = *(uint32_t *)[d bytes];
                    printf(",\"metallib_magic\":\"0x%08X\"", magic);

                    NSString *filename = [NSString stringWithFormat:@"library_%llu.metallib", k];
                    NSString *outPath = [outputDir stringByAppendingPathComponent:filename];
                    [d writeToFile:outPath atomically:YES];
                    printf(",\"metallib_file\":");
                    json_print_string([filename UTF8String]);
                    metallibs_exported++;
                }
            }
        }

        // Export AIR bitcode
        if ([lib respondsToSelector:bcSel]) {
            @try {
                id bcData = [lib performSelector:bcSel];
                if (bcData && [bcData isKindOfClass:[NSData class]]) {
                    NSData *d = (NSData *)bcData;
                    printf(",\"bitcode_size\":%lu", (unsigned long)[d length]);

                    if ([d length] >= 4) {
                        uint32_t magic = *(uint32_t *)[d bytes];
                        printf(",\"bitcode_magic\":\"0x%08X\"", magic);

                        NSString *filename = [NSString stringWithFormat:@"library_%llu.air", k];
                        NSString *outPath = [outputDir stringByAppendingPathComponent:filename];
                        [d writeToFile:outPath atomically:YES];
                        printf(",\"bitcode_file\":");
                        json_print_string([filename UTF8String]);
                        bitcodes_exported++;
                    }
                }
            } @catch (NSException *ex) {
                printf(",\"bitcode_error\":");
                json_print_string([[ex reason] UTF8String]);
            }
        }

        printf("}");
    }
    printf("]");

    // === Scan pipeline states ===
    SEL rpsSel = @selector(renderPipelineStateForKey:);
    SEL cpsSel = @selector(computePipelineStateForKey:);
    int render_ps_count = 0, compute_ps_count = 0;

    // R7.2 — build (fn_ptr → fn_key) map once for cross-referencing captured
    // descriptors. Captured pairs are populated by the swizzle during
    // makeController/playAll. If the swizzles never fired (e.g. the device
    // class hierarchy unexpectedly lacks the methods), we still emit basic
    // RPS info but the *_function_key / attachment fields will be absent.
    NSMutableDictionary *fnPtr2Key = rps_build_fn_ptr_to_key_map(g_ctx.objectMap);
    int rps_correlation_count = 0;

    JSON_SEP();
    printf("\"render_pipeline_states\":[");
    BOOL first_rps = YES;
    for (uint64_t k = 0; k <= rpsMaxKey; k++) {
        id rps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, rpsSel, k);
        if (!rps) continue;
        render_ps_count++;
        if (!first_rps) printf(",");
        first_rps = NO;
        printf("{\"key\":%llu,\"class\":", k);
        json_print_string(class_getName([rps class]));
        if ([rps respondsToSelector:@selector(label)]) {
            id lbl = [rps performSelector:@selector(label)];
            if (lbl) { printf(",\"label\":"); json_print_string([lbl UTF8String]); }
        }

        // R7.2 — RPS↔shader correlation, when the swizzle captured this RPS.
        const RPSCaptureEntry *e = rps_find_entry((__bridge void *)rps);
        if (e) {
            rps_correlation_count++;
            id v_fn_k = e->vfunc_ptr ? [fnPtr2Key objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)e->vfunc_ptr]] : nil;
            id f_fn_k = e->ffunc_ptr ? [fnPtr2Key objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)e->ffunc_ptr]] : nil;

            if (v_fn_k) {
                uint64_t vk = [v_fn_k unsignedLongLongValue];
                printf(",\"vertex_function_key\":%llu", vk);
                if (vk > 0) printf(",\"vertex_library_key\":%llu", vk - 1);
            }
            if (f_fn_k) {
                uint64_t fk = [f_fn_k unsignedLongLongValue];
                printf(",\"fragment_function_key\":%llu", fk);
                if (fk > 0) printf(",\"fragment_library_key\":%llu", fk - 1);
            }
            if (e->vfunc_name[0]) {
                printf(",\"vertex_function_name\":");
                json_print_string(e->vfunc_name);
            }
            if (e->ffunc_name[0]) {
                printf(",\"fragment_function_name\":");
                json_print_string(e->ffunc_name);
            }

            // Attachment summary — always emitted so consumers can branch on
            // color_attachment_count even if it's 0 (e.g. depth-only passes).
            printf(",\"color_attachment_count\":%d", e->color_attachment_count);
            printf(",\"color_attachments\":[");
            for (int ci = 0; ci < e->color_attachment_count; ci++) {
                if (ci > 0) printf(",");
                const RPSColorAttachmentInfo *c = &e->color[ci];
                printf("{\"index\":%d,\"format\":", c->index);
                json_print_string(c->format_name);
                printf(",\"pixelFormat\":%lu,\"writeMask\":", (unsigned long)c->format_value);
                json_print_string(c->write_mask);
                printf(",\"blendingEnabled\":%s}", c->blending_enabled ? "true" : "false");
            }
            printf("]");

            printf(",\"depth_format\":");
            json_print_string(e->depth_format);
            printf(",\"depth_format_value\":%lu", (unsigned long)e->depth_format_value);
            printf(",\"stencil_format\":");
            json_print_string(e->stencil_format);
            printf(",\"stencil_format_value\":%lu", (unsigned long)e->stencil_format_value);
            printf(",\"raster_sample_count\":%lu", (unsigned long)e->raster_sample_count);
        }

        printf("}");
    }
    printf("]");

    JSON_SEP();
    printf("\"compute_pipeline_states\":[");
    BOOL first_cps = YES;
    for (uint64_t k = 0; k <= rpsMaxKey; k++) {
        id cps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, cpsSel, k);
        if (!cps) continue;
        compute_ps_count++;
        if (!first_cps) printf(",");
        first_cps = NO;
        printf("{\"key\":%llu,\"class\":", k);
        json_print_string(class_getName([cps class]));
        if ([cps respondsToSelector:@selector(label)]) {
            id lbl = [cps performSelector:@selector(label)];
            if (lbl) { printf(",\"label\":"); json_print_string([lbl UTF8String]); }
        }
        printf("}");
    }
    printf("]");

    // === Scan functions ===
    int func_count = 0;
    JSON_SEP();
    printf("\"functions\":[");
    if (funcMapRaw && [funcMapRaw isKindOfClass:[NSDictionary class]]) {
        BOOL first_fn = YES;
        for (id key in (NSDictionary *)funcMapRaw) {
            id func = [(NSDictionary *)funcMapRaw objectForKey:key];
            func_count++;
            if (!first_fn) printf(",");
            first_fn = NO;

            printf("{\"key\":%llu", [key unsignedLongLongValue]);
            printf(",\"class\":");
            json_print_string(class_getName([func class]));

            if ([func respondsToSelector:@selector(name)]) {
                id name = [func performSelector:@selector(name)];
                if (name) { printf(",\"name\":"); json_print_string([name UTF8String]); }
            }
            if ([func respondsToSelector:@selector(functionType)]) {
                NSUInteger ft = ((NSUInteger (*)(id, SEL))objc_msgSend)(func, @selector(functionType));
                const char *ftStr = ft == 1 ? "vertex" : ft == 2 ? "fragment" : ft == 3 ? "kernel" : "unknown";
                printf(",\"functionType\":%lu,\"functionTypeStr\":", (unsigned long)ft);
                json_print_string(ftStr);
            }
            printf("}");
        }
    }
    printf("]");

    // Summary counts
    JSON_KV_INT("libraries_count", libs_found);
    JSON_KV_INT("metallibs_exported", metallibs_exported);
    JSON_KV_INT("bitcodes_exported", bitcodes_exported);
    JSON_KV_INT("render_pipeline_states_count", render_ps_count);
    JSON_KV_INT("compute_pipeline_states_count", compute_ps_count);
    JSON_KV_INT("functions_count", func_count);
    // R7.2 — swizzle correlation health: how many RPS in the trace got their
    // descriptor captured. If this is 0 while render_pipeline_states_count > 0,
    // the swizzle install path is broken (e.g. macOS update changed the device
    // class hierarchy) and downstream `shader-of-rps` will return errors.
    JSON_KV_INT("rps_correlated_count", rps_correlation_count);
    JSON_KV_INT("rps_captured_count", g_rps_n_captured);

    JSON_END();

    replay_context_cleanup();
    return EXIT_OK;
}

// ============================================================
#pragma mark - Subcommand: shader
// ============================================================

/// shader <trace> <lib_key> <metallib_path> [--verify] [--source <msl_path>]
///
/// Replaces a library in the replay objectMap with a new metallib binary.
/// --verify: after replacement, rewind+playAll and report success
/// --source: instead of metallib file, compile MSL source code

static int cmd_shader(int argc, const char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: gputrace_replay_bridge shader <.gputrace> <lib_key> <metallib_path> [--verify]\n");
        fprintf(stderr, "       gputrace_replay_bridge shader <.gputrace> <lib_key> --source <msl_path> [--verify]\n");
        fprintf(stderr, "\nReplaces library at lib_key with new metallib binary or compiled MSL source.\n");
        fprintf(stderr, "  --verify   Run rewind+playAll after replacement to confirm replay succeeds.\n");
        return EXIT_USAGE;
    }

    const char *trace_path = argv[0];
    uint64_t lib_key = strtoull(argv[1], NULL, 10);
    const char *metallib_path = NULL;
    const char *source_path = NULL;
    BOOL do_verify = NO;

    // Parse remaining args
    int arg_i = 2;
    while (arg_i < argc) {
        if (strcmp(argv[arg_i], "--verify") == 0) {
            do_verify = YES;
        } else if (strcmp(argv[arg_i], "--source") == 0 && arg_i + 1 < argc) {
            source_path = argv[++arg_i];
        } else if (!metallib_path && argv[arg_i][0] != '-') {
            metallib_path = argv[arg_i];
        }
        arg_i++;
    }

    if (!metallib_path && !source_path) {
        fprintf(stderr, "[ERROR] Must provide either <metallib_path> or --source <msl_path>\n");
        return EXIT_USAGE;
    }

    int rc = replay_context_init(trace_path);
    if (rc != EXIT_OK) return rc;

    // Initial playAll to populate objectMap
    int initial_rc = -1;
    @try { initial_rc = g_ctx.fn_playAll(g_ctx.controller); } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] initial playAll exception: %s\n", [[ex reason] UTF8String]);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }
    if (initial_rc != 0) {
        fprintf(stderr, "[ERROR] initial playAll failed (rc=%d)\n", initial_rc);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }

    // Get original library info
    SEL libSel = @selector(libraryForKey:);
    SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
    SEL setLibSel = NSSelectorFromString(@"setLibrary:forKey:");

    id origLib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, libSel, lib_key);
    NSUInteger orig_metallib_size = 0;
    NSArray *orig_functions = nil;
    if (origLib && [origLib conformsToProtocol:@protocol(MTLLibrary)]) {
        orig_functions = [(id<MTLLibrary>)origLib functionNames];
        NSData *origData = [origLib performSelector:ldcSel];
        orig_metallib_size = origData ? [origData length] : 0;
    }

    // Load or compile new library
    id<MTLLibrary> newLib = nil;
    NSUInteger new_metallib_size = 0;
    NSError *err = nil;

    if (source_path) {
        // Compile from MSL source
        NSString *msl = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:source_path]
                                                  encoding:NSUTF8StringEncoding error:&err];
        if (!msl) {
            fprintf(stderr, "[ERROR] Cannot read source file: %s\n", [[err localizedDescription] UTF8String]);
            replay_context_cleanup();
            return EXIT_BAD_INPUT;
        }
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        newLib = [g_ctx.device newLibraryWithSource:msl options:opts error:&err];
        if (!newLib) {
            fprintf(stderr, "[ERROR] Compile failed: %s\n", [[err localizedDescription] UTF8String]);
            replay_context_cleanup();
            return EXIT_SUBCMD_FAIL;
        }
        NSData *compiled = [newLib performSelector:ldcSel];
        new_metallib_size = compiled ? [compiled length] : 0;
    } else {
        // Load metallib binary from file
        NSData *metallibData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:metallib_path]];
        if (!metallibData || [metallibData length] == 0) {
            fprintf(stderr, "[ERROR] Cannot read metallib file: %s\n", metallib_path);
            replay_context_cleanup();
            return EXIT_BAD_INPUT;
        }
        new_metallib_size = [metallibData length];

        dispatch_data_t dd = dispatch_data_create(
            [metallibData bytes], [metallibData length], NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        newLib = [g_ctx.device newLibraryWithData:dd error:&err];
        if (!newLib) {
            fprintf(stderr, "[ERROR] newLibraryWithData failed: %s\n", [[err localizedDescription] UTF8String]);
            replay_context_cleanup();
            return EXIT_SUBCMD_FAIL;
        }
    }

    NSArray *new_functions = [newLib functionNames];

    // Perform replacement
    ((void (*)(id, SEL, id, uint64_t))objc_msgSend)(g_ctx.objectMap, setLibSel, (id)newLib, lib_key);

    // Optional verify: rewind + playAll
    int verify_rc = -1;
    double verify_ms = 0;
    if (do_verify) {
        g_ctx.fn_rewind(g_ctx.controller);
        uint64_t t0 = mach_absolute_time();
        @try {
            verify_rc = g_ctx.fn_playAll(g_ctx.controller);
        } @catch (NSException *ex) {
            fprintf(stderr, "[ERROR] verify playAll exception: %s\n", [[ex reason] UTF8String]);
            verify_rc = -1;
        }
        uint64_t t1 = mach_absolute_time();
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        verify_ms = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
    }

    // Output JSON
    JSON_BEGIN();
    JSON_KV_STR("command", "shader");
    JSON_KV_STR("trace_path", trace_path);
    JSON_KV_UINT("library_key", lib_key);
    JSON_KV_BOOL("replacement_done", YES);

    // Original library info
    JSON_SEP();
    printf("\"original\":{");
    printf("\"exists\":%s", origLib ? "true" : "false");
    if (origLib) {
        printf(",\"metallib_size\":%lu", (unsigned long)orig_metallib_size);
        if (orig_functions) {
            printf(",\"functions\":[");
            for (NSUInteger i = 0; i < [orig_functions count]; i++) {
                if (i > 0) printf(",");
                json_print_string([[orig_functions objectAtIndex:i] UTF8String]);
            }
            printf("]");
        }
    }
    printf("}");

    // New library info
    JSON_SEP();
    printf("\"replacement\":{");
    printf("\"metallib_size\":%lu", (unsigned long)new_metallib_size);
    if (source_path) {
        printf(",\"source_path\":"); json_print_string(source_path);
    } else {
        printf(",\"metallib_path\":"); json_print_string(metallib_path);
    }
    if (new_functions) {
        printf(",\"functions\":[");
        for (NSUInteger i = 0; i < [new_functions count]; i++) {
            if (i > 0) printf(",");
            json_print_string([[new_functions objectAtIndex:i] UTF8String]);
        }
        printf("]");
    }
    printf("}");

    // Verify results
    if (do_verify) {
        JSON_SEP();
        printf("\"verify\":{");
        printf("\"playAll_rc\":%d", verify_rc);
        printf(",\"success\":%s", verify_rc == 0 ? "true" : "false");
        printf(",\"elapsed_ms\":%.3f", verify_ms);
        printf("}");
    }

    JSON_END();

    replay_context_cleanup();
    return (do_verify && verify_rc != 0) ? EXIT_REPLAY_FAIL : EXIT_OK;
}

// ============================================================
#pragma mark - Subcommand: shader-of-rps (R7.4)
// ============================================================
//
// shader-of-rps <trace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]
//
// Walks the R7.2 swizzle table and the objectMap to answer the user-level
// question "what shader does this RPS use?" — a one-line semantic lookup that
// hides every intermediate abstraction (function key, library key, metallib,
// AIR bitcode, llvm-dis).
//
// Output (always JSON on stdout):
//   {
//     "command": "shader-of-rps",
//     "rps_key": 484,
//     "stage": "fragment",
//     "function_key": 357,
//     "function_name": "...",
//     "library_key": 356,
//     "library_metallib_path": ".../library_356.metallib",
//     "library_metallib_size": 4577,
//     "library_air_path": ".../library_356.air",   // when bitcode available
//     "library_air_size": 3920,
//     "ir_ll_path": ".../library_356.ll",          // present iff --with-ir succeeded
//     "ir_ll_size": ...,
//     "cache_key": "...."                          // PlayTools cacheKey on the metallib bytes
//   }
//
// On lookup failures emits a structured "error" string (see EXIT_SUBCMD_FAIL).
// Reuses `replay_context_init` + the swizzle-driven RPS↔function correlation,
// so it pays one playAll cost per invocation. That's the same cost as
// `pipeline`, and necessary to populate the objectMap.

// Compute the PlayTools cacheKey (FNV-style) on a binary blob. See
// LocalDocs/GPUTraceReplayAutomation/subdocs/20260521-R7-frame-inspection-gap.md §3.1.
static NSString *compute_playtools_cache_key(NSData *data) {
    if (!data) return nil;
    NSUInteger size = [data length];
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    uint64_t h = (uint64_t)size;
    NSUInteger head_n = size < 32 ? size : 32;
    for (NSUInteger i = 0; i < head_n; i++) {
        h = h * 31 + bytes[i];
    }
    if (size > 32) {
        NSUInteger tail_n = (size - 32) < 16 ? (size - 32) : 16;
        for (NSUInteger i = size - tail_n; i < size; i++) {
            h = h * 31 + bytes[i];
        }
    }
    return [NSString stringWithFormat:@"%016llX_%lu", (unsigned long long)h,
            (unsigned long)size];
}

// Locate llvm-dis on disk (Homebrew first, then $PATH). Returns nil if absent.
static NSString *find_llvm_dis(void) {
    NSArray *candidates = @[
        @"/opt/homebrew/opt/llvm/bin/llvm-dis",
        @"/opt/homebrew/bin/llvm-dis",
        @"/usr/local/opt/llvm/bin/llvm-dis",
        @"/usr/local/bin/llvm-dis",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    // Fall back to PATH lookup via /usr/bin/which.
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/which";
    t.arguments = @[@"llvm-dis"];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSPipe pipe];
    @try {
        [t launch];
        [t waitUntilExit];
        if (t.terminationStatus == 0) {
            NSData *d = [[out fileHandleForReading] readDataToEndOfFile];
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length && [fm isExecutableFileAtPath:s]) return s;
        }
    } @catch (NSException *ex) {}
    return nil;
}

static int cmd_shader_of_rps(int argc, const char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: gputrace_replay_bridge shader-of-rps <.gputrace> <rps_key> [--stage fragment|vertex] [--with-ir] [--output-dir DIR]\n");
        fprintf(stderr, "\nReverse-lookup the shader (vertex or fragment) attached to a RPS, optionally producing LLVM IR.\n");
        fprintf(stderr, "Default --stage = fragment.\n");
        return EXIT_USAGE;
    }

    const char *trace_path = argv[0];
    uint64_t target_rps_key = strtoull(argv[1], NULL, 10);
    const char *stage = "fragment";
    BOOL with_ir = NO;
    const char *output_dir_c = NULL;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--stage") == 0 && i + 1 < argc) {
            stage = argv[++i];
        } else if (strcmp(argv[i], "--with-ir") == 0) {
            with_ir = YES;
        } else if (strcmp(argv[i], "--output-dir") == 0 && i + 1 < argc) {
            output_dir_c = argv[++i];
        }
    }
    if (strcmp(stage, "fragment") != 0 && strcmp(stage, "vertex") != 0) {
        fprintf(stderr, "[ERROR] --stage must be 'fragment' or 'vertex'\n");
        return EXIT_USAGE;
    }

    // Output dir — needed even without --with-ir to keep paths predictable.
    NSString *outputDir = output_dir_c
        ? [NSString stringWithUTF8String:output_dir_c]
        : NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];

    // R7.2 — install swizzle BEFORE replay_context_init.
    rps_install_swizzles();

    int rc = replay_context_init(trace_path);
    if (rc != EXIT_OK) return rc;

    int play_rc = -1;
    @try {
        play_rc = g_ctx.fn_playAll(g_ctx.controller);
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] playAll exception: %s\n", [[ex reason] UTF8String]);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }
    if (play_rc != 0) {
        fprintf(stderr, "[ERROR] playAll failed (rc=%d)\n", play_rc);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }

    // Resolve target RPS by key.
    SEL rpsSel = @selector(renderPipelineStateForKey:);
    id rps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, rpsSel, target_rps_key);

    JSON_BEGIN();
    JSON_KV_STR("command", "shader-of-rps");
    JSON_KV_STR("trace_path", trace_path);
    JSON_KV_UINT("rps_key", target_rps_key);
    JSON_KV_STR("stage", stage);
    JSON_KV_STR("output_dir", [outputDir UTF8String]);

    if (!rps) {
        JSON_KV_STR("error", "rps_not_found");
        JSON_KV_INT("rps_captured_count", g_rps_n_captured);
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }

    if ([rps respondsToSelector:@selector(label)]) {
        id lbl = [rps performSelector:@selector(label)];
        if (lbl) { JSON_KV_STR("rps_label", [lbl UTF8String]); }
    }

    const RPSCaptureEntry *e = rps_find_entry((__bridge void *)rps);
    if (!e) {
        JSON_KV_STR("error", "descriptor_not_captured");
        JSON_KV_STR("hint", "swizzle either failed to install or this RPS was created before install");
        JSON_KV_INT("rps_captured_count", g_rps_n_captured);
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }

    BOOL is_fragment = (strcmp(stage, "fragment") == 0);
    void *target_fn_ptr = is_fragment ? e->ffunc_ptr : e->vfunc_ptr;
    const char *target_fn_name = is_fragment ? e->ffunc_name : e->vfunc_name;

    if (!target_fn_ptr) {
        JSON_KV_STR("error", "stage_function_absent");
        JSON_KV_STR("hint", "this RPS has no function for the requested stage (e.g. vertex-only / depth-only pass)");
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }

    if (target_fn_name && target_fn_name[0]) {
        JSON_KV_STR("function_name", target_fn_name);
    }

    NSMutableDictionary *fnPtr2Key = rps_build_fn_ptr_to_key_map(g_ctx.objectMap);
    id fn_k_obj = [fnPtr2Key objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)target_fn_ptr]];
    if (!fn_k_obj) {
        JSON_KV_STR("error", "function_key_unresolved");
        JSON_KV_STR("hint", "objectMap.functionMap does not contain the captured function pointer");
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }

    uint64_t fn_key = [fn_k_obj unsignedLongLongValue];
    JSON_KV_UINT("function_key", fn_key);

    // Library key — convention library_key = function_key - 1 (validated in
    // R5.1; documented in subdocs/20260521-R7-frame-inspection-gap.md §3 row 4).
    if (fn_key == 0) {
        JSON_KV_STR("error", "library_key_unresolved");
        JSON_KV_STR("hint", "function_key=0 makes library_key=-1, which is invalid");
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }
    uint64_t lib_key = fn_key - 1;
    JSON_KV_UINT("library_key", lib_key);

    // Look up the library and dump metallib + AIR.
    SEL libSel = @selector(libraryForKey:);
    SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
    SEL bcSel  = NSSelectorFromString(@"bitcodeData");

    id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, libSel, lib_key);
    if (!lib) {
        // Try fallback: scan even keys downward; rare safety net for traces
        // where the (-1) convention is broken.
        for (int64_t k = (int64_t)fn_key - 1; k >= 0; k -= 2) {
            id maybe = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, libSel, (uint64_t)k);
            if (maybe && [maybe conformsToProtocol:@protocol(MTLLibrary)]) {
                lib = maybe;
                lib_key = (uint64_t)k;
                break;
            }
        }
    }
    if (!lib || ![lib conformsToProtocol:@protocol(MTLLibrary)]) {
        JSON_KV_STR("error", "library_not_found");
        JSON_KV_UINT("attempted_library_key", lib_key);
        JSON_END();
        replay_context_cleanup();
        return EXIT_SUBCMD_FAIL;
    }

    NSData *metallibData = nil;
    if ([lib respondsToSelector:ldcSel]) {
        @try { metallibData = [lib performSelector:ldcSel]; } @catch (NSException *ex) {}
    }
    NSData *airData = nil;
    if ([lib respondsToSelector:bcSel]) {
        @try { airData = [lib performSelector:bcSel]; } @catch (NSException *ex) {}
    }

    if (metallibData && [metallibData length] > 0) {
        NSString *fn = [NSString stringWithFormat:@"library_%llu.metallib", lib_key];
        NSString *path = [outputDir stringByAppendingPathComponent:fn];
        if ([metallibData writeToFile:path atomically:YES]) {
            JSON_KV_STR("library_metallib_path", [path UTF8String]);
            JSON_KV_UINT("library_metallib_size", (uint64_t)[metallibData length]);
            NSString *cacheKey = compute_playtools_cache_key(metallibData);
            if (cacheKey) {
                JSON_KV_STR("cache_key_metallib", [cacheKey UTF8String]);
            }
        }
    }

    NSString *airPath = nil;
    if (airData && [airData length] > 0) {
        NSString *fn = [NSString stringWithFormat:@"library_%llu.air", lib_key];
        airPath = [outputDir stringByAppendingPathComponent:fn];
        if ([airData writeToFile:airPath atomically:YES]) {
            JSON_KV_STR("library_air_path", [airPath UTF8String]);
            JSON_KV_UINT("library_air_size", (uint64_t)[airData length]);
        } else {
            airPath = nil;
        }
    }

    // --with-ir — pipe AIR bitcode through llvm-dis to produce .ll.
    if (with_ir) {
        if (!airPath) {
            JSON_KV_STR("ir_error", "no_air_bitcode");
        } else {
            NSString *llvmDis = find_llvm_dis();
            if (!llvmDis) {
                JSON_KV_STR("ir_error", "llvm_dis_not_found");
                JSON_KV_STR("ir_hint", "install via 'brew install llvm' (Apple toolchain lacks llvm-dis)");
            } else {
                NSString *llPath = [outputDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"library_%llu.ll", lib_key]];
                NSTask *t = [[NSTask alloc] init];
                t.launchPath = llvmDis;
                t.arguments = @[airPath, @"-o", llPath];
                NSPipe *errPipe = [NSPipe pipe];
                t.standardError = errPipe;
                t.standardOutput = [NSPipe pipe];
                int dis_rc = -1;
                NSString *errStr = nil;
                @try {
                    [t launch];
                    [t waitUntilExit];
                    dis_rc = t.terminationStatus;
                    NSData *d = [[errPipe fileHandleForReading] readDataToEndOfFile];
                    if (d.length) errStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                } @catch (NSException *ex) {
                    errStr = [ex reason];
                }
                if (dis_rc == 0 && [fm fileExistsAtPath:llPath]) {
                    JSON_KV_STR("ir_ll_path", [llPath UTF8String]);
                    NSDictionary *attr = [fm attributesOfItemAtPath:llPath error:nil];
                    if (attr) JSON_KV_UINT("ir_ll_size", (uint64_t)[attr fileSize]);
                    JSON_KV_STR("ir_dis_path", [llvmDis UTF8String]);
                } else {
                    JSON_KV_STR("ir_error", "llvm_dis_failed");
                    JSON_KV_INT("ir_dis_rc", dis_rc);
                    if (errStr) JSON_KV_STR("ir_dis_stderr", [errStr UTF8String]);
                }
            }
        }
    }

    JSON_END();
    replay_context_cleanup();
    return EXIT_OK;
}

// ============================================================
#pragma mark - Subcommand: frame-list (R7.3)
// ============================================================
//
// frame-list <trace> [--with-draws] [--no-draws] [--with-timing]
//
// Replays the trace once with the R7.3 frame swizzles armed and emits a
// command_buffers / encoders / draws tree plus a flat draw_to_rps_map[]
// suitable for chaining into shader-of-rps.
//
// Defaults:
//   --with-draws  ON  (cheap; encoder.draws[] populated)
//   --no-draws    OFF (omit per-draw records, keep encoder list only)
//   --with-timing OFF (sets per-cb gpu_start/end_ms from MTLCommandBuffer
//                      properties; many replay-created CBs never commit so
//                      these properties remain 0 — flag is provided for
//                      forward compatibility)
//
// Reuses R7.2's `rps_install_swizzles` so the per-draw rps_ptr is also
// resolvable to a stable rps_key in the same invocation.

typedef struct {
    const char *trace_path;
    BOOL with_draws;       // default YES
    BOOL no_draws;          // explicit suppression overrides with_draws
    BOOL with_timing;       // default NO
} FrameListOptions;

static FrameListOptions parse_frame_list_options(int argc, const char *argv[]) {
    FrameListOptions o = {0};
    o.with_draws = YES;
    if (argc >= 1) o.trace_path = argv[0];
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--with-draws") == 0) o.with_draws = YES;
        else if (strcmp(argv[i], "--no-draws") == 0) o.no_draws = YES;
        else if (strcmp(argv[i], "--with-timing") == 0) o.with_timing = YES;
    }
    return o;
}

static const char *frame_encoder_type_name(FrameEncoderType t) {
    switch (t) {
        case FRAME_ENC_TYPE_RENDER:  return "render";
        case FRAME_ENC_TYPE_COMPUTE: return "compute";
        case FRAME_ENC_TYPE_BLIT:    return "blit";
    }
    return "other";
}

static const char *primitive_type_name(int pt) {
    switch (pt) {
        case 0: return "point";
        case 1: return "line";
        case 2: return "lineStrip";
        case 3: return "triangle";
        case 4: return "triangleStrip";
        default: return "other";
    }
}

static int cmd_frame_list(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge frame-list <path-to-.gputrace> [--with-draws] [--no-draws] [--with-timing]\n");
        fprintf(stderr, "\nEnumerates command buffers / encoders / draws captured during replay.\n");
        fprintf(stderr, "Outputs JSON tree (command_buffers[].encoders[].draws[]) plus flat draw_to_rps_map[].\n");
        return EXIT_USAGE;
    }
    FrameListOptions opts = parse_frame_list_options(argc, argv);
    if (!opts.trace_path) return EXIT_USAGE;
    BOOL emit_draws = opts.with_draws && !opts.no_draws;

    // Reset and install swizzles BEFORE replay_context_init — the framework's
    // PSO compilation in makeController would otherwise create CBs we don't
    // see. The capture gate stays closed until after init returns.
    frame_capture_reset();
    rps_install_swizzles();
    frame_install_swizzles();

    int rc = replay_context_init(opts.trace_path);
    if (rc != EXIT_OK) return rc;

    // Arm capture only for the actual playAll traversal.
    g_frame_capture_armed = 1;
    int play_signal = 0;
    double elapsed_ms = 0;
    int play_rc = safe_playAll(&elapsed_ms, &play_signal);
    g_frame_capture_armed = 0;

    uint32_t total_call_count = controller_last_call_index(g_ctx.controller);

    // R7.3 timing — derived from MTLCommandBuffer.GPU{Start,End}Time which
    // are populated by Metal once the cb completes. For replay-internal CBs
    // these properties may remain 0 if the framework batches differently.
    if (opts.with_timing) {
        for (int i = 0; i < g_cb_n_captured; i++) {
            FrameCBEntry *cb = &g_cb_captured[i];
            id obj = (__bridge id)cb->cb_ptr;
            CFTimeInterval s = 0, e = 0;
            @try { s = [obj GPUStartTime]; } @catch (NSException *ex) {}
            @try { e = [obj GPUEndTime];   } @catch (NSException *ex) {}
            cb->gpu_start_ms = s * 1000.0;
            cb->gpu_end_ms = e * 1000.0;
            cb->gpu_duration_ms = (e > s) ? (e - s) * 1000.0 : -1.0;
        }
    }

    // Build (rps_ptr -> rps_key) for the draw_to_rps_map. Reuse R7.2's
    // ptr-to-key map via an objectMap probe.
    //
    // NB: g_rps_captured[].rps_ptr is the ptr Metal returned to the
    // application; objectMap.renderPipelineStateForKey: returns the same
    // pointer, so a probe round-trip is O(N) over keys but the constant is
    // small (we already do this in `pipeline`).
    NSMutableDictionary *rpsPtr2Key = [NSMutableDictionary dictionary];
    if (g_ctx.objectMap) {
        SEL rpsSel = @selector(renderPipelineStateForKey:);
        // Establish the same scan ceiling the `pipeline` subcommand uses.
        id funcMapRaw = nil;
        @try { funcMapRaw = [g_ctx.objectMap performSelector:@selector(functionMap)]; } @catch (NSException *ex) {}
        uint64_t maxKey = 200;
        if (funcMapRaw && [funcMapRaw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)funcMapRaw) {
                uint64_t kv = [key unsignedLongLongValue];
                if (kv > maxKey) maxKey = kv;
            }
            maxKey += 50;
        }
        uint64_t rpsScan = maxKey + 200;
        for (uint64_t k = 0; k <= rpsScan; k++) {
            id rps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(g_ctx.objectMap, rpsSel, k);
            if (rps) {
                [rpsPtr2Key setObject:@(k) forKey:[NSValue valueWithNonretainedObject:rps]];
            }
        }
    }

    // ===== Emit JSON =====
    JSON_BEGIN();
    JSON_KV_STR("command", "frame-list");
    JSON_KV_STR("trace_path", opts.trace_path);
    JSON_KV_STR("device", [[g_ctx.device name] UTF8String]);
    JSON_KV_INT("replay_rc", play_rc);
    if (play_signal != 0) JSON_KV_INT("replay_signal", play_signal);
    JSON_KV_BOOL("success", play_rc == 0);
    JSON_KV_DOUBLE("elapsed_ms", elapsed_ms);
    JSON_KV_UINT("total_call_count", total_call_count);
    JSON_KV_BOOL("with_draws", emit_draws);
    JSON_KV_BOOL("with_timing", opts.with_timing);
    JSON_KV_INT("command_buffer_count", g_cb_n_captured);
    JSON_KV_INT("encoder_count", g_encoder_n_captured);
    JSON_KV_INT("draw_count", g_draws_n_captured);
    JSON_KV_INT("rps_correlated_count", (int)[rpsPtr2Key count]);

    // command_buffers tree
    JSON_SEP();
    printf("\"command_buffers\":[");
    for (int ci = 0; ci < g_cb_n_captured; ci++) {
        if (ci > 0) printf(",");
        FrameCBEntry *cb = &g_cb_captured[ci];
        printf("{\"index\":%d", cb->index);
        if (cb->label[0]) { printf(",\"label\":"); json_print_string(cb->label); }
        printf(",\"encoder_count\":%d", cb->encoder_count);
        if (opts.with_timing) {
            if (cb->gpu_duration_ms >= 0) {
                printf(",\"gpu_start_ms\":%.6f", cb->gpu_start_ms);
                printf(",\"gpu_end_ms\":%.6f",   cb->gpu_end_ms);
                printf(",\"gpu_duration_ms\":%.6f", cb->gpu_duration_ms);
            } else {
                printf(",\"gpu_start_ms\":null,\"gpu_end_ms\":null,\"gpu_duration_ms\":null");
            }
        }
        // encoders[] inline
        printf(",\"encoders\":[");
        BOOL first_e = YES;
        for (int ei = 0; ei < g_encoder_n_captured; ei++) {
            FrameEncoderEntry *e = &g_encoder_captured[ei];
            if (e->cb_index != cb->index) continue;
            if (!first_e) printf(",");
            first_e = NO;
            printf("{\"index\":%d", e->index);
            printf(",\"type\":");
            json_print_string(frame_encoder_type_name(e->type));
            if (e->label[0]) { printf(",\"label\":"); json_print_string(e->label); }
            printf(",\"first_call_index\":%u", e->first_call_index);
            printf(",\"last_call_index\":%u",  e->last_call_index);
            printf(",\"draw_count\":%d", e->draw_count);
            if (e->type == FRAME_ENC_TYPE_RENDER) {
                printf(",\"color_attachment_count\":%d", e->color_attachment_count);
                printf(",\"color_attachments\":[");
                for (int ai = 0; ai < e->color_attachment_count; ai++) {
                    if (ai > 0) printf(",");
                    printf("{\"index\":%d,\"texture_id\":%llu,\"pixelFormat\":%lu,\"format\":",
                           ai,
                           (unsigned long long)e->color_attachment_ids[ai],
                           (unsigned long)e->color_attachment_pf[ai]);
                    json_print_string(e->color_attachment_pf_name[ai]);
                    printf("}");
                }
                printf("]");
                if (e->depth_attachment_id) {
                    printf(",\"depth_attachment\":{\"texture_id\":%llu,\"pixelFormat\":%lu,\"format\":",
                           (unsigned long long)e->depth_attachment_id,
                           (unsigned long)e->depth_attachment_pf);
                    json_print_string(e->depth_attachment_pf_name);
                    printf("}");
                } else {
                    printf(",\"depth_attachment\":null");
                }
                if (e->stencil_attachment_id) {
                    printf(",\"stencil_attachment\":{\"texture_id\":%llu,\"pixelFormat\":%lu,\"format\":",
                           (unsigned long long)e->stencil_attachment_id,
                           (unsigned long)e->stencil_attachment_pf);
                    json_print_string(e->stencil_attachment_pf_name);
                    printf("}");
                } else {
                    printf(",\"stencil_attachment\":null");
                }
            } else if (e->type == FRAME_ENC_TYPE_COMPUTE) {
                printf(",\"compute_dispatch_count\":%d", e->compute_dispatch_count);
            }
            if (emit_draws) {
                printf(",\"draws\":[");
                BOOL first_d = YES;
                for (int di = 0; di < g_draws_n_captured; di++) {
                    FrameDrawEntry *d = &g_draws_captured[di];
                    if (d->encoder_index != e->index) continue;
                    if (!first_d) printf(",");
                    first_d = NO;
                    printf("{\"draw_index_global\":%d", d->draw_index_global);
                    printf(",\"draw_in_encoder\":%d", d->draw_in_encoder);
                    printf(",\"call_index\":%u", d->call_index);
                    printf(",\"primitive_type\":%d,\"primitive_type_name\":", d->primitive_type);
                    json_print_string(primitive_type_name(d->primitive_type));
                    printf(",\"vertex_count\":%lu", (unsigned long)d->vertex_count);
                    printf(",\"instance_count\":%lu", (unsigned long)d->instance_count);
                    printf(",\"indexed\":%s", d->indexed ? "true" : "false");
                    if (d->indexed) printf(",\"index_count\":%lu", (unsigned long)d->index_count);
                    // RPS lookup
                    id rpsKey = d->rps_ptr
                        ? [rpsPtr2Key objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)d->rps_ptr]]
                        : nil;
                    if (rpsKey) printf(",\"rps_key\":%llu", [rpsKey unsignedLongLongValue]);
                    else        printf(",\"rps_key\":null");
                    // Optional label/function from R7.2 capture
                    if (d->rps_ptr) {
                        const RPSCaptureEntry *rc = rps_find_entry(d->rps_ptr);
                        if (rc) {
                            if (rc->label[0]) { printf(",\"rps_label\":"); json_print_string(rc->label); }
                            id fnK = rc->ffunc_ptr
                                ? [rps_build_fn_ptr_to_key_map(g_ctx.objectMap)
                                       objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)rc->ffunc_ptr]]
                                : nil;
                            if (fnK) printf(",\"fragment_function_key\":%llu", [fnK unsignedLongLongValue]);
                        }
                    }
                    printf("}");
                }
                printf("]");
            }
            printf("}");
        }
        printf("]");
        printf("}");
    }
    printf("]");

    // Flat draw_to_rps_map
    if (emit_draws) {
        JSON_SEP();
        printf("\"draw_to_rps_map\":[");
        for (int di = 0; di < g_draws_n_captured; di++) {
            if (di > 0) printf(",");
            FrameDrawEntry *d = &g_draws_captured[di];
            id rpsKey = d->rps_ptr
                ? [rpsPtr2Key objectForKey:[NSValue valueWithNonretainedObject:(__bridge id)d->rps_ptr]]
                : nil;
            printf("{\"draw_index_global\":%d", d->draw_index_global);
            printf(",\"encoder_index\":%d", d->encoder_index);
            printf(",\"draw_in_encoder\":%d", d->draw_in_encoder);
            printf(",\"call_index\":%u", d->call_index);
            if (rpsKey) printf(",\"rps_key\":%llu", [rpsKey unsignedLongLongValue]);
            else        printf(",\"rps_key\":null");
            printf("}");
        }
        printf("]");
    }

    JSON_END();
    replay_context_cleanup();
    return (play_rc == 0) ? EXIT_OK : EXIT_REPLAY_FAIL;
}

// ============================================================
#pragma mark - Subcommand: config
// ============================================================

/// config <trace> [key=value ...]
///
/// Supported keys:
///   disableOptimizeRestores=0|1   (default 1 in bridge; set to 0 to enable optimizeRestores)
///   forceLoadUnusedResources=0|1  (default 1; set to 0 to skip populateUnusedResources)
///   enableValidation=0|1          (default 0; set to 1 to enable g_runningValidationCI)
///
/// Runs replay with specified config and outputs timing/resource JSON.
/// Without any key=value, shows available config keys and their defaults.

typedef struct {
    int disable_optimize_restores;   // 1=skip optimizeRestores (default), 0=call it
    int force_load_unused;           // 1=call populateUnused (default), 0=skip
    int enable_validation;           // 0=off (default), 1=on
} ConfigOptions;

static ConfigOptions parse_config_options(int argc, const char *argv[]) {
    ConfigOptions cfg = { .disable_optimize_restores = 1, .force_load_unused = 1, .enable_validation = 0 };
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "disableOptimizeRestores=", 24) == 0) {
            cfg.disable_optimize_restores = atoi(argv[i] + 24);
        } else if (strncmp(argv[i], "forceLoadUnusedResources=", 25) == 0) {
            cfg.force_load_unused = atoi(argv[i] + 25);
        } else if (strncmp(argv[i], "enableValidation=", 17) == 0) {
            cfg.enable_validation = atoi(argv[i] + 17);
        }
    }
    return cfg;
}

/// Perform a complete replay with given config, measuring timing.
/// Returns playAll result code; sets *elapsed_ms and *resource_count.
static int config_replay_with_options(const char *trace_path, ConfigOptions cfg,
                                      double *elapsed_ms, NSUInteger *resource_count) {
    // We need a fresh context for each config test.
    // Re-do full init sequence with config-specific steps.

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pathStr = [NSString stringWithUTF8String:trace_path];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) return -1;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return -2;

    const char *fw_path = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
    void *handle = dlopen(fw_path, RTLD_NOW);
    if (!handle) return -3;

    void *gt_env = dlsym(handle, "GT_ENV");
    void *cli_fn = dlsym(handle, "GTMTLReplay_CLI");
    if (!gt_env || !cli_fn) { dlclose(handle); return -4; }

    apr_pool_create_fn fn_apr = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
    makeDataSource_fn fn_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
    supportInit_fn fn_si = (supportInit_fn)resolve_bl(cli_fn, 0x888);
    initArgBuf_fn fn_iab = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
    populateUnused_fn fn_pu = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
    makeController_fn fn_mc = (makeController_fn)resolve_bl(cli_fn, 0x954);
    optimizeRestores_fn fn_or = (optimizeRestores_fn)resolve_bl(cli_fn, 0x96c);
    playAll_fn fn_pa = (playAll_fn)dlsym(handle, "GTMTLReplayController_playAll");

    if (!fn_apr || !fn_ds || !fn_mc || !fn_pa) { dlclose(handle); return -5; }

    // APR bootstrap
    void **gpp = (void **)((uint8_t *)gt_env - 0x30);
    if (*gpp == NULL) {
        void *blk = calloc(1, 0x4000);
        void *gp = (uint8_t *)blk + 0x100;
        *(uint64_t *)blk = 20; *(uint64_t *)((uint8_t *)blk + 8) = 20;
        *(void **)gp = blk; *(void **)((uint8_t *)gp + 0x30) = blk;
        *gpp = gp;
    }

    // enableValidation via global
    void *g_val_ptr = dlsym(handle, "g_runningValidationCI");
    if (g_val_ptr) {
        *(BOOL *)g_val_ptr = cfg.enable_validation ? YES : NO;
    }

    void *pool = NULL;
    fn_apr(&pool, NULL, NULL, NULL);
    if (!pool) { dlclose(handle); return -6; }

    void *dataSource = fn_ds(trace_path, pool);
    if (!dataSource) { dlclose(handle); return -7; }

    if (fn_si) fn_si((__bridge void *)device);

    Class mapCls = NSClassFromString(@"GTMTLReplayObjectMap");
    if (!mapCls) { dlclose(handle); return -8; }
    id objectMap = [[mapCls alloc] performSelector:@selector(initWithDevice:) withObject:device];
    if (!objectMap) { dlclose(handle); return -9; }

    if (fn_iab) fn_iab(dataSource, (__bridge void *)device, (__bridge void *)objectMap);

    // forceLoadUnusedResources
    if (cfg.force_load_unused && fn_pu) {
        fn_pu(dataSource, (__bridge void *)objectMap);
    }

    void *ctrl = fn_mc(dataSource, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
    if (!ctrl) { dlclose(handle); return -10; }

    // disableOptimizeRestores: if NOT disabled (=0), call optimizeRestores
    if (!cfg.disable_optimize_restores && fn_or) {
        fn_or(ctrl);
    }

    // playAll with timing
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t t0 = mach_absolute_time();
    int play_rc = fn_pa(ctrl);
    uint64_t t1 = mach_absolute_time();
    *elapsed_ms = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;

    // Resource count
    @try {
        NSDictionary *res = [objectMap performSelector:@selector(resources)];
        *resource_count = [res count];
    } @catch (NSException *ex) { *resource_count = 0; }

    // Restore validation state
    if (g_val_ptr) *(BOOL *)g_val_ptr = NO;

    dlclose(handle);
    return play_rc;
}

static int cmd_config(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge config <path-to-.gputrace> [key=value ...]\n");
        fprintf(stderr, "\nSupported config keys:\n");
        fprintf(stderr, "  disableOptimizeRestores=0|1   (default=1, skip restore optimization)\n");
        fprintf(stderr, "  forceLoadUnusedResources=0|1  (default=1, load unused resources)\n");
        fprintf(stderr, "  enableValidation=0|1          (default=0, Metal validation layer)\n");
        fprintf(stderr, "\nRuns replay with specified config and reports timing/resource JSON.\n");
        return EXIT_USAGE;
    }

    const char *trace_path = argv[0];

    // Parse config options from argv[1..]
    ConfigOptions cfg = parse_config_options(argc - 1, argv + 1);

    // Validate trace exists
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pathStr = [NSString stringWithUTF8String:trace_path];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) {
        fprintf(stderr, "[ERROR] Not a valid .gputrace bundle: %s\n", trace_path);
        return EXIT_BAD_INPUT;
    }

    // Run replay with config
    double elapsed_ms = 0;
    NSUInteger resource_count = 0;
    int play_rc = config_replay_with_options(trace_path, cfg, &elapsed_ms, &resource_count);

    // Output JSON
    JSON_BEGIN();
    JSON_KV_STR("command", "config");
    JSON_KV_STR("trace_path", trace_path);

    JSON_SEP();
    printf("\"config\":{");
    printf("\"disableOptimizeRestores\":%s", cfg.disable_optimize_restores ? "true" : "false");
    printf(",\"forceLoadUnusedResources\":%s", cfg.force_load_unused ? "true" : "false");
    printf(",\"enableValidation\":%s", cfg.enable_validation ? "true" : "false");
    printf("}");

    JSON_KV_INT("playAll_rc", play_rc);
    JSON_KV_BOOL("success", play_rc == 0);
    JSON_KV_DOUBLE("elapsed_ms", elapsed_ms);
    JSON_KV_UINT("resource_count", resource_count);
    JSON_END();

    return (play_rc == 0) ? EXIT_OK : EXIT_REPLAY_FAIL;
}

// ============================================================
#pragma mark - Main: Subcommand Dispatch
// ============================================================

typedef struct {
    const char *name;
    int (*handler)(int argc, const char *argv[]);
} Subcommand;

static Subcommand g_commands[] = {
    { "help",          cmd_help },
    { "replay",        cmd_replay },
    { "pipeline",      cmd_pipeline },
    { "shader",        cmd_shader },
    { "shader-of-rps", cmd_shader_of_rps },
    { "frame-list",    cmd_frame_list },
    { "config",        cmd_config },
    { NULL, NULL }
};

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: gputrace_replay_bridge <command> [args...]\n");
            fprintf(stderr, "Run 'gputrace_replay_bridge help' for available commands.\n");
            return EXIT_USAGE;
        }

        const char *cmd_name = argv[1];

        for (Subcommand *cmd = g_commands; cmd->name != NULL; cmd++) {
            if (strcmp(cmd_name, cmd->name) == 0) {
                return cmd->handler(argc - 2, argv + 2);
            }
        }

        fprintf(stderr, "[ERROR] Unknown command: %s\n", cmd_name);
        fprintf(stderr, "Run 'gputrace_replay_bridge help' for available commands.\n");
        return EXIT_USAGE;
    }
}
