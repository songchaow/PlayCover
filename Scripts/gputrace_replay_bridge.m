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
};

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
    printf(",{\"name\":\"replay\",\"description\":\"Headless replay with playAll/playTo + resource enumeration/export\",\"usage\":\"replay <.gputrace> [--playto N] [--list-resources] [--export ID output_path]\"}");
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
#pragma mark - Subcommand: replay
// ============================================================

/// Parse replay options from argv:
///   replay <trace> [--playto N] [--list-resources] [--export ID output_path]
typedef struct {
    const char *trace_path;
    int32_t playto_index;      // -1 = playAll (default)
    BOOL list_resources;
    int64_t export_id;         // -1 = no export
    const char *export_path;
} ReplayOptions;

static ReplayOptions parse_replay_options(int argc, const char *argv[]) {
    ReplayOptions opts = {0};
    opts.playto_index = -1;
    opts.export_id = -1;

    if (argc >= 1) opts.trace_path = argv[0];

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--playto") == 0 && i + 1 < argc) {
            opts.playto_index = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--list-resources") == 0) {
            opts.list_resources = YES;
        } else if (strcmp(argv[i], "--export") == 0 && i + 2 < argc) {
            opts.export_id = strtoll(argv[++i], NULL, 10);
            opts.export_path = argv[++i];
        }
    }
    return opts;
}

static int cmd_replay(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge replay <path-to-.gputrace> [options]\n");
        fprintf(stderr, "Options:\n");
        fprintf(stderr, "  --playto N           Replay to specific call index (default: playAll)\n");
        fprintf(stderr, "  --list-resources     Enumerate all resources after replay\n");
        fprintf(stderr, "  --export ID PATH     Export resource ID to binary file\n");
        return EXIT_USAGE;
    }

    ReplayOptions opts = parse_replay_options(argc, argv);
    if (!opts.trace_path) return EXIT_USAGE;

    int rc = replay_context_init(opts.trace_path);
    if (rc != EXIT_OK) return rc;

    // Execute replay with timing
    uint64_t t0 = mach_absolute_time();
    int play_rc = -1;
    @try {
        if (opts.playto_index >= 0) {
            play_rc = g_ctx.fn_playTo(g_ctx.controller, (uint32_t)opts.playto_index);
        } else {
            play_rc = g_ctx.fn_playAll(g_ctx.controller);
        }
    } @catch (NSException *ex) {
        fprintf(stderr, "[ERROR] replay exception: %s\n", [[ex reason] UTF8String]);
        replay_context_cleanup();
        return EXIT_REPLAY_FAIL;
    }
    uint64_t t1 = mach_absolute_time();

    // Convert to milliseconds
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double elapsed_ms = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;

    // Gather resources
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
    JSON_KV_BOOL("success", play_rc == 0);
    JSON_KV_DOUBLE("elapsed_ms", elapsed_ms);
    JSON_KV_UINT("resource_count", resource_count);

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
                if (tex.label) { printf(",\"label\":"); json_print_string([tex.label UTF8String]); }
            } else if ([value conformsToProtocol:@protocol(MTLBuffer)]) {
                id<MTLBuffer> buf = (id<MTLBuffer>)value;
                printf(",\"type\":\"buffer\"");
                printf(",\"length\":%lu", (unsigned long)buf.length);
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
#pragma mark - Subcommand: pipeline (stub — R6.1c)
// ============================================================

static int cmd_pipeline(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge pipeline <path-to-.gputrace> [output_dir]\n");
        return EXIT_USAGE;
    }
    fprintf(stderr, "[INFO] pipeline subcommand: not yet implemented (R6.1c)\n");
    JSON_BEGIN();
    JSON_KV_STR("command", "pipeline");
    JSON_KV_STR("status", "not_implemented");
    JSON_KV_STR("planned", "R6.1c");
    JSON_END();
    return EXIT_SUBCMD_FAIL;
}

// ============================================================
#pragma mark - Subcommand: shader (stub — R6.1d)
// ============================================================

static int cmd_shader(int argc, const char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: gputrace_replay_bridge shader <path-to-.gputrace> <lib_key> <metallib_path>\n");
        return EXIT_USAGE;
    }
    fprintf(stderr, "[INFO] shader subcommand: not yet implemented (R6.1d)\n");
    JSON_BEGIN();
    JSON_KV_STR("command", "shader");
    JSON_KV_STR("status", "not_implemented");
    JSON_KV_STR("planned", "R6.1d");
    JSON_END();
    return EXIT_SUBCMD_FAIL;
}

// ============================================================
#pragma mark - Subcommand: config (stub — R6.1e)
// ============================================================

static int cmd_config(int argc, const char *argv[]) {
    if (argc < 1) {
        fprintf(stderr, "Usage: gputrace_replay_bridge config <path-to-.gputrace> [key=value ...]\n");
        return EXIT_USAGE;
    }
    fprintf(stderr, "[INFO] config subcommand: not yet implemented (R6.1e)\n");
    JSON_BEGIN();
    JSON_KV_STR("command", "config");
    JSON_KV_STR("status", "not_implemented");
    JSON_KV_STR("planned", "R6.1e");
    JSON_END();
    return EXIT_SUBCMD_FAIL;
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
