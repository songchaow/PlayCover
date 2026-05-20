/**
 * pipeline_probe.m — R5.1 Pipeline 查看探针
 *
 * 在 headless replay 后，从 objectMap 中提取 pipeline state、library、function 对象，
 * 并导出 pipeline binary（metallib + AIR bitcode）。
 *
 * 核心发现（R5.1 验证结果）：
 *   - objectMap 的 ForKey: 方法接受 uint64_t 参数（非 NSObject）
 *   - libraryForKey: 返回 _MTLLibrary（MTLLibrary 协议）
 *   - _MTLLibrary.libraryDataContents → NSData (metallib binary，BLTM magic)
 *   - _MTLLibrary.bitcodeData → NSData (AIR/LLVM bitcode，0x0B17C0DE magic)
 *   - _MTLLibrary.serializeToURL:error: → 直接序列化到文件
 *   - computePipelineStateForKey: → AGX*ComputePipeline
 *   - renderPipelineStateForKey: → AGX*RenderPipeline
 *   - Library keys 与 function keys 相邻：func key N 对应 library key N-1
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o pipeline_probe pipeline_probe.m
 *
 * 用法：
 *   ./pipeline_probe <path-to-.gputrace> [output_dir]
 *
 * 输出：
 *   - JSON metadata (pipeline_export.json)
 *   - .metallib 文件（每个 library 一个）
 *   - .air 文件（每个有 bitcode 的 library 一个）
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

// === Helper: resolve internal function via CLI BL offset ===
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

// === Function signatures ===
typedef int (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void (*supportInit_fn)(void *device);
typedef void (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef int (*playAll_fn)(void *controller);
typedef void (*rewind_fn)(void *controller);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path-to-.gputrace> [output_dir]\n", argv[0]);
            return 1;
        }
        const char *gputrace_path = argv[1];
        NSString *outputDir = argc >= 3
            ? [NSString stringWithUTF8String:argv[2]]
            : [[NSString stringWithUTF8String:gputrace_path] stringByAppendingPathComponent:@"../pipeline_export"];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];

        fprintf(stdout, "=== R5.1 Pipeline Probe ===\n\n");
        fprintf(stdout, "[INFO] .gputrace: %s\n", gputrace_path);
        fprintf(stdout, "[INFO] output: %s\n", [outputDir UTF8String]);

        // === Validate input ===
        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "[ERROR] Not a valid .gputrace bundle: %s\n", gputrace_path);
            return 2;
        }

        // === Metal device ===
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[ERROR] No Metal device available\n");
            return 3;
        }
        fprintf(stdout, "[INFO] Metal device: %s\n", [[device name] UTF8String]);

        // === dlopen ===
        const char *fw_path = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
        void *handle = dlopen(fw_path, RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "[ERROR] dlopen failed: %s\n", dlerror());
            return 4;
        }

        // === Resolve symbols ===
        void *gt_env = dlsym(handle, "GT_ENV");
        void *cli_fn = dlsym(handle, "GTMTLReplay_CLI");
        if (!gt_env || !cli_fn) {
            fprintf(stderr, "[ERROR] Missing GT_ENV or GTMTLReplay_CLI\n");
            dlclose(handle);
            return 5;
        }

        apr_pool_create_fn apr_pool_create = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn make_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn support_init = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn init_argbuf = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn populate_unused = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn make_ctrl = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn play_all = (playAll_fn)dlsym(handle, "GTMTLReplayController_playAll");

        if (!play_all) {
            fprintf(stderr, "[ERROR] Missing GTMTLReplayController_playAll\n");
            dlclose(handle);
            return 5;
        }
        fprintf(stdout, "[OK] All symbols resolved\n");

        // === APR Bootstrap ===
        void **global_pool_ptr = (void **)((uint8_t *)gt_env - 0x30);
        if (*global_pool_ptr == NULL) {
            void *block = calloc(1, 0x4000);
            void *allocator = block;
            void *global_pool = (uint8_t *)block + 0x100;
            *(uint64_t *)((uint8_t *)allocator + 0x00) = 20;
            *(uint64_t *)((uint8_t *)allocator + 0x08) = 20;
            *(void **)((uint8_t *)global_pool + 0x00) = allocator;
            *(void **)((uint8_t *)global_pool + 0x30) = allocator;
            *global_pool_ptr = global_pool;
            fprintf(stdout, "[APR] Bootstrap complete\n");
        }

        // === Create Controller ===
        void *pool = NULL;
        int rc = apr_pool_create(&pool, NULL, NULL, NULL);
        if (rc != 0 || !pool) {
            fprintf(stderr, "[FATAL] APR pool creation failed\n");
            dlclose(handle);
            return 6;
        }

        void *dataSource = make_ds(gputrace_path, pool);
        if (!dataSource) {
            fprintf(stderr, "[FATAL] makeDataSource failed\n");
            dlclose(handle);
            return 7;
        }

        support_init((__bridge void *)device);

        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        if (!mapClass) {
            fprintf(stderr, "[ERROR] GTMTLReplayObjectMap class not found\n");
            dlclose(handle);
            return 8;
        }
        id objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
        if (!objectMap) {
            fprintf(stderr, "[FATAL] objectMap creation failed\n");
            dlclose(handle);
            return 9;
        }

        init_argbuf(dataSource, (__bridge void *)device, (__bridge void *)objectMap);
        populate_unused(dataSource, (__bridge void *)objectMap);

        void *controller = make_ctrl(dataSource, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) {
            fprintf(stderr, "[FATAL] makeController failed\n");
            dlclose(handle);
            return 10;
        }
        fprintf(stdout, "[OK] Controller created\n");

        // === playAll ===
        int play_rc = play_all(controller);
        fprintf(stdout, "[playAll] returned: %d %s\n\n", play_rc, play_rc == 0 ? "[SUCCESS]" : "[FAILED]");
        if (play_rc != 0) {
            fprintf(stderr, "[FATAL] playAll failed\n");
            dlclose(handle);
            return 11;
        }

        // ============================================================
        // PHASE 1: Enumerate & Export Libraries (metallib + AIR)
        // ============================================================
        fprintf(stdout, "========== PHASE 1: Library Export ==========\n\n");

        SEL libSel = @selector(libraryForKey:);
        SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
        SEL bcSel = NSSelectorFromString(@"bitcodeData");
        SEL serSel = NSSelectorFromString(@"serializeToURL:error:");

        NSMutableArray *libraryResults = [NSMutableArray array];
        int libsExported = 0;
        int bitcodesExported = 0;

        // Determine key range from functionMap
        id funcMapForRange = [objectMap performSelector:@selector(functionMap)];
        uint64_t maxKey = 200;
        if (funcMapForRange && [funcMapForRange isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)funcMapForRange) {
                uint64_t kv = [key unsignedLongLongValue];
                if (kv > maxKey) maxKey = kv;
            }
            maxKey += 50; // extra headroom
        }
        fprintf(stdout, "[INFO] Scanning library keys 0..%llu\n", maxKey);

        // Scan keys for libraries
        for (uint64_t k = 0; k <= maxKey; k++) {
            id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, libSel, k);
            if (!lib) continue;
            if (![lib conformsToProtocol:@protocol(MTLLibrary)]) continue;

            id<MTLLibrary> mtlLib = (id<MTLLibrary>)lib;
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"key"] = @(k);
            entry[@"class"] = NSStringFromClass([lib class]);
            entry[@"functionNames"] = [mtlLib functionNames] ?: @[];
            entry[@"installName"] = mtlLib.installName ?: @"";
            entry[@"label"] = mtlLib.label ?: @"";
            entry[@"type"] = @(mtlLib.type); // 0=executable, 1=dynamic

            fprintf(stdout, "  Library key=%llu: %s functions=%lu\n",
                    k, mtlLib.installName ? [mtlLib.installName UTF8String] : "(no installName)",
                    (unsigned long)[[mtlLib functionNames] count]);

            // Export metallib via libraryDataContents
            if ([lib respondsToSelector:ldcSel]) {
                id data = [lib performSelector:ldcSel];
                if (data && [data isKindOfClass:[NSData class]]) {
                    NSData *d = (NSData *)data;
                    entry[@"metallib_size"] = @([d length]);

                    if ([d length] >= 4) {
                        uint32_t magic = *(uint32_t *)[d bytes];
                        entry[@"metallib_magic"] = [NSString stringWithFormat:@"0x%08X", magic];
                        // Metal library magic: "BLTM" (0x424C544D) or "MTLB" (0x4D544C42)
                        BOOL valid = (magic == 0x424C544D || magic == 0x4D544C42 || magic == 0x4C54424D);
                        entry[@"valid_metallib"] = @(valid);

                        NSString *filename = [NSString stringWithFormat:@"library_%llu.metallib", k];
                        NSString *outPath = [outputDir stringByAppendingPathComponent:filename];
                        [d writeToFile:outPath atomically:YES];
                        entry[@"metallib_file"] = filename;
                        libsExported++;

                        fprintf(stdout, "    [EXPORT] %s (%lu bytes, magic=0x%08X %s)\n",
                                [filename UTF8String], (unsigned long)[d length], magic,
                                valid ? "✓" : "?");
                    }
                }
            }

            // Export AIR bitcode via bitcodeData
            if ([lib respondsToSelector:bcSel]) {
                @try {
                    id bcData = [lib performSelector:bcSel];
                    if (bcData && [bcData isKindOfClass:[NSData class]]) {
                        NSData *d = (NSData *)bcData;
                        entry[@"bitcode_size"] = @([d length]);

                        if ([d length] >= 4) {
                            uint32_t magic = *(uint32_t *)[d bytes];
                            entry[@"bitcode_magic"] = [NSString stringWithFormat:@"0x%08X", magic];
                            BOOL valid = (magic == 0x0B17C0DE) ||
                                         ([d length] >= 2 && ((const char *)[d bytes])[0] == 'B' &&
                                          ((const char *)[d bytes])[1] == 'C');
                            entry[@"valid_bitcode"] = @(valid);

                            NSString *filename = [NSString stringWithFormat:@"library_%llu.air", k];
                            NSString *outPath = [outputDir stringByAppendingPathComponent:filename];
                            [d writeToFile:outPath atomically:YES];
                            entry[@"bitcode_file"] = filename;
                            bitcodesExported++;

                            fprintf(stdout, "    [EXPORT] %s (%lu bytes, magic=0x%08X %s)\n",
                                    [filename UTF8String], (unsigned long)[d length], magic,
                                    valid ? "✓" : "?");
                        }
                    }
                } @catch (NSException *ex) {
                    entry[@"bitcode_error"] = [ex reason];
                }
            }

            [libraryResults addObject:entry];
        }

        // ============================================================
        // PHASE 2: Enumerate Pipeline States
        // ============================================================
        fprintf(stdout, "\n========== PHASE 2: Pipeline States ==========\n\n");

        SEL rpsSel = @selector(renderPipelineStateForKey:);
        SEL cpsSel = @selector(computePipelineStateForKey:);

        NSMutableArray *renderPSResults = [NSMutableArray array];
        NSMutableArray *computePSResults = [NSMutableArray array];

        fprintf(stdout, "[INFO] Scanning pipeline state keys 0..%llu\n", maxKey);
        for (uint64_t k = 0; k <= maxKey; k++) {
            // Render pipeline states
            id rps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, rpsSel, k);
            if (rps) {
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"key"] = @(k);
                entry[@"class"] = NSStringFromClass([rps class]);
                if ([rps respondsToSelector:@selector(label)]) {
                    id lbl = [rps performSelector:@selector(label)];
                    if (lbl) entry[@"label"] = lbl;
                }
                [renderPSResults addObject:entry];
                fprintf(stdout, "  RenderPipelineState key=%llu class=%s\n", k, class_getName([rps class]));
            }

            // Compute pipeline states
            id cps = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, cpsSel, k);
            if (cps) {
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"key"] = @(k);
                entry[@"class"] = NSStringFromClass([cps class]);
                if ([cps respondsToSelector:@selector(label)]) {
                    id lbl = [cps performSelector:@selector(label)];
                    if (lbl) entry[@"label"] = lbl;
                }
                [computePSResults addObject:entry];
                fprintf(stdout, "  ComputePipelineState key=%llu class=%s\n", k, class_getName([cps class]));
            }
        }

        // ============================================================
        // PHASE 3: Enumerate Functions
        // ============================================================
        fprintf(stdout, "\n========== PHASE 3: Functions ==========\n\n");

        id funcMap = [objectMap performSelector:@selector(functionMap)];
        NSMutableArray *functionResults = [NSMutableArray array];

        if (funcMap && [funcMap isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)funcMap) {
                id func = [(NSDictionary *)funcMap objectForKey:key];
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"key"] = [key description];
                entry[@"class"] = NSStringFromClass([func class]);

                if ([func respondsToSelector:@selector(name)]) {
                    id name = [func performSelector:@selector(name)];
                    if (name) entry[@"name"] = name;
                }
                if ([func respondsToSelector:@selector(functionType)]) {
                    // functionType is NSUInteger, use objc_msgSend for non-object return
                    NSUInteger ft = ((NSUInteger (*)(id, SEL))objc_msgSend)(func, @selector(functionType));
                    entry[@"functionType"] = @(ft);
                    // 1=vertex, 2=fragment, 3=kernel
                    NSString *typeStr = ft == 1 ? @"vertex" : ft == 2 ? @"fragment" : ft == 3 ? @"kernel" : @"unknown";
                    entry[@"functionTypeStr"] = typeStr;
                }

                [functionResults addObject:entry];
                fprintf(stdout, "  Function key=%s name=%s type=%s\n",
                        [[key description] UTF8String],
                        entry[@"name"] ? [entry[@"name"] UTF8String] : "?",
                        entry[@"functionTypeStr"] ? [entry[@"functionTypeStr"] UTF8String] : "?");
            }
        }

        // ============================================================
        // Write JSON result
        // ============================================================
        NSMutableDictionary *jsonResult = [NSMutableDictionary dictionary];
        jsonResult[@"probe"] = @"R5.1_pipeline_probe";
        jsonResult[@"gputrace"] = pathStr;
        jsonResult[@"device"] = [device name];
        jsonResult[@"playAll_rc"] = @(play_rc);

        jsonResult[@"libraries"] = libraryResults;
        jsonResult[@"libraries_count"] = @([libraryResults count]);
        jsonResult[@"metallibs_exported"] = @(libsExported);
        jsonResult[@"bitcodes_exported"] = @(bitcodesExported);

        jsonResult[@"render_pipeline_states"] = renderPSResults;
        jsonResult[@"compute_pipeline_states"] = computePSResults;
        jsonResult[@"render_pipeline_states_count"] = @([renderPSResults count]);
        jsonResult[@"compute_pipeline_states_count"] = @([computePSResults count]);

        jsonResult[@"functions"] = functionResults;
        jsonResult[@"functions_count"] = @([functionResults count]);

        // Export methods documentation
        jsonResult[@"export_methods"] = @{
            @"metallib": @"_MTLLibrary.libraryDataContents → NSData",
            @"bitcode": @"_MTLLibrary.bitcodeData → NSData (AIR/LLVM bitcode)",
            @"serialize": @"_MTLLibrary.serializeToURL:error: → BOOL",
            @"key_type": @"uint64_t (Q encoding, NOT NSObject)",
            @"key_pattern": @"library key = function key - 1 (observed)"
        };

        NSString *jsonPath = [outputDir stringByAppendingPathComponent:@"pipeline_export.json"];
        NSError *jsonErr = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonResult
                                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                             error:&jsonErr];
        if (jsonData) {
            [jsonData writeToFile:jsonPath atomically:YES];
            fprintf(stdout, "\n[OK] JSON written to: %s\n", [jsonPath UTF8String]);
        } else {
            fprintf(stderr, "[ERROR] JSON serialization failed: %s\n", [[jsonErr localizedDescription] UTF8String]);
        }

        // === Final Summary ===
        fprintf(stdout, "\n========== R5.1 Pipeline Probe Summary ==========\n");
        fprintf(stdout, "  Libraries found: %lu\n", (unsigned long)[libraryResults count]);
        fprintf(stdout, "  Metallibs exported: %d\n", libsExported);
        fprintf(stdout, "  AIR bitcodes exported: %d\n", bitcodesExported);
        fprintf(stdout, "  Render pipeline states: %lu\n", (unsigned long)[renderPSResults count]);
        fprintf(stdout, "  Compute pipeline states: %lu\n", (unsigned long)[computePSResults count]);
        fprintf(stdout, "  Functions: %lu\n", (unsigned long)[functionResults count]);
        fprintf(stdout, "\n=== R5.1 Probe Complete ===\n");

        dlclose(handle);
        return 0;
    }
}
