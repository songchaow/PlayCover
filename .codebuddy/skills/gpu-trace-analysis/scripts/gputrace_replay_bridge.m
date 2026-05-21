/**
 * gputrace_replay_bridge.m — R6.1a 统一 ObjC Bridge CLI
 *
 * 单一多子命令二进制，覆盖所有已验证的 GPU Trace Replay 能力，JSON 输出。
 *
 * 子命令：
 *   help      — 输出子命令列表
 *   replay    — headless replay（playAll），输出 JSON 摘要
 *   pipeline  — library 枚举 + metallib/AIR 导出（R6.1c）
 *   shader    — setLibrary:forKey: 热替换 + 验证（R6.1d）
 *   config    — 调用链控制 + validation 全局变量（R6.1e）
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
    JSON_KV_STR("version", "0.2.0");
    JSON_SEP();
    printf("\"commands\":[");
    printf("{\"name\":\"help\",\"description\":\"Show available commands\"}");
    printf(",{\"name\":\"replay\",\"description\":\"Headless replay with playAll/playTo + resource enumeration/export. Always reports total_call_count; --playto N is bounds-checked and returns error \\\"playto_out_of_range\\\" instead of crashing when N > total_call_count.\",\"usage\":\"replay <.gputrace> [--bounds] [--playto N] [--list-resources] [--export ID output_path]\"}");
    printf(",{\"name\":\"pipeline\",\"description\":\"Library enumeration + metallib/AIR export\",\"usage\":\"pipeline <.gputrace> [output_dir]\"}");
    printf(",{\"name\":\"shader\",\"description\":\"Hot-replace library via setLibrary:forKey:\",\"usage\":\"shader <.gputrace> <lib_key> <metallib_path>\"}");
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

    // Determine max key from functionMap
    id funcMapRaw = [g_ctx.objectMap performSelector:@selector(functionMap)];
    uint64_t maxKey = 200;
    if (funcMapRaw && [funcMapRaw isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)funcMapRaw) {
            uint64_t kv = [key unsignedLongLongValue];
            if (kv > maxKey) maxKey = kv;
        }
        maxKey += 50;
    }

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

    JSON_SEP();
    printf("\"render_pipeline_states\":[");
    BOOL first_rps = YES;
    for (uint64_t k = 0; k <= maxKey; k++) {
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
        printf("}");
    }
    printf("]");

    JSON_SEP();
    printf("\"compute_pipeline_states\":[");
    BOOL first_cps = YES;
    for (uint64_t k = 0; k <= maxKey; k++) {
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
    { "help",     cmd_help },
    { "replay",   cmd_replay },
    { "pipeline", cmd_pipeline },
    { "shader",   cmd_shader },
    { "config",   cmd_config },
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
