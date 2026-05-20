/**
 * objectmap_probe.m — R4.3 ObjectMap 数据提取 + playTo 定向 replay
 *
 * 阶段 A：playAll 后枚举 objectMap.resources，提取 MTLTexture/MTLBuffer 属性与 raw data
 * 阶段 B：使用 playTo 定向 replay 到特定 draw call，对比 objectMap 状态差异
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o objectmap_probe objectmap_probe.m
 *
 * 用法：
 *   ./objectmap_probe <path-to-.gputrace> [output_dir]
 *
 * 输出：
 *   - JSON metadata (resources summary, texture/buffer attributes)
 *   - Binary files for first exportable texture pixel data
 *   - playTo comparison results
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
typedef int (*playTo_fn)(void *controller, uint32_t targetCallIndex);
typedef void (*rewind_fn)(void *controller);

// === JSON output helpers ===
static void json_write_string(FILE *f, const char *key, const char *val) {
    fprintf(f, "    \"%s\": \"%s\"", key, val ? val : "null");
}

static void json_write_uint(FILE *f, const char *key, uint64_t val) {
    fprintf(f, "    \"%s\": %llu", key, val);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path-to-.gputrace> [output_dir]\n", argv[0]);
            return 1;
        }
        const char *gputrace_path = argv[1];
        NSString *outputDir = argc >= 3
            ? [NSString stringWithUTF8String:argv[2]]
            : [[NSString stringWithUTF8String:gputrace_path] stringByAppendingPathComponent:@"../objectmap_export"];
        
        // Create output directory
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        fprintf(stdout, "=== R4.3 ObjectMap Data Extraction + playTo Probe ===\n\n");
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
        playTo_fn play_to = (playTo_fn)dlsym(handle, "GTMTLReplayController_playTo");
        rewind_fn ctrl_rewind = (rewind_fn)dlsym(handle, "GTMTLReplayController_rewind");
        
        if (!play_all || !play_to || !ctrl_rewind) {
            fprintf(stderr, "[ERROR] Missing exported play functions\n");
            dlclose(handle);
            return 5;
        }
        fprintf(stdout, "[OK] All symbols resolved (playTo=%p)\n", (void*)play_to);
        
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
        
        // ============================================================
        // PHASE A: playAll + ObjectMap data extraction
        // ============================================================
        fprintf(stdout, "\n========== PHASE A: ObjectMap Data Extraction ==========\n\n");
        
        int play_rc = play_all(controller);
        fprintf(stdout, "[playAll] returned: %d %s\n", play_rc, play_rc == 0 ? "[SUCCESS]" : "[FAILED]");
        if (play_rc != 0) {
            fprintf(stderr, "[FATAL] playAll failed, cannot proceed\n");
            dlclose(handle);
            return 11;
        }
        
        // --- Enumerate objectMap.resources ---
        fprintf(stdout, "\n--- Enumerating objectMap.resources ---\n");
        NSDictionary *resources = nil;
        @try {
            resources = [objectMap performSelector:@selector(resources)];
        } @catch (NSException *ex) {
            fprintf(stderr, "[EXCEPTION] resources: %s\n", [[ex reason] UTF8String]);
        }
        
        if (!resources || ![resources isKindOfClass:[NSDictionary class]]) {
            fprintf(stderr, "[ERROR] objectMap.resources is not a valid NSDictionary\n");
            dlclose(handle);
            return 12;
        }
        
        NSUInteger totalCount = [resources count];
        fprintf(stdout, "  Total resource entries: %lu\n", (unsigned long)totalCount);
        
        // Classify resources
        NSMutableArray *textureKeys = [NSMutableArray array];
        NSMutableArray *bufferKeys = [NSMutableArray array];
        NSMutableArray *otherKeys = [NSMutableArray array];
        
        for (id key in resources) {
            id value = resources[key];
            if ([value conformsToProtocol:@protocol(MTLTexture)]) {
                [textureKeys addObject:key];
            } else if ([value conformsToProtocol:@protocol(MTLBuffer)]) {
                [bufferKeys addObject:key];
            } else {
                [otherKeys addObject:key];
            }
        }
        
        fprintf(stdout, "  MTLTexture: %lu\n", (unsigned long)[textureKeys count]);
        fprintf(stdout, "  MTLBuffer:  %lu\n", (unsigned long)[bufferKeys count]);
        fprintf(stdout, "  Other:      %lu\n", (unsigned long)[otherKeys count]);
        
        // --- Export texture metadata + first texture raw data ---
        NSString *jsonPath = [outputDir stringByAppendingPathComponent:@"resources_metadata.json"];
        FILE *jsonFile = fopen([jsonPath UTF8String], "w");
        if (!jsonFile) {
            fprintf(stderr, "[ERROR] Cannot create JSON output file\n");
            dlclose(handle);
            return 13;
        }
        
        fprintf(jsonFile, "{\n");
        fprintf(jsonFile, "  \"total_resources\": %lu,\n", (unsigned long)totalCount);
        fprintf(jsonFile, "  \"texture_count\": %lu,\n", (unsigned long)[textureKeys count]);
        fprintf(jsonFile, "  \"buffer_count\": %lu,\n", (unsigned long)[bufferKeys count]);
        fprintf(jsonFile, "  \"other_count\": %lu,\n", (unsigned long)[otherKeys count]);
        fprintf(jsonFile, "  \"textures\": [\n");
        
        int textureExported = 0;
        int maxTextureDetail = 20; // limit detailed output
        BOOL firstBinaryExported = NO;
        
        for (NSUInteger i = 0; i < [textureKeys count] && i < (NSUInteger)maxTextureDetail; i++) {
            id key = textureKeys[i];
            id<MTLTexture> tex = (id<MTLTexture>)resources[key];
            
            NSUInteger w = tex.width;
            NSUInteger h = tex.height;
            MTLPixelFormat fmt = tex.pixelFormat;
            NSUInteger usage = tex.usage;
            MTLTextureType texType = tex.textureType;
            
            if (i > 0) fprintf(jsonFile, ",\n");
            fprintf(jsonFile, "    {\n");
            fprintf(jsonFile, "      \"key\": \"%s\",\n", [[key description] UTF8String]);
            fprintf(jsonFile, "      \"width\": %lu,\n", (unsigned long)w);
            fprintf(jsonFile, "      \"height\": %lu,\n", (unsigned long)h);
            fprintf(jsonFile, "      \"pixelFormat\": %lu,\n", (unsigned long)fmt);
            fprintf(jsonFile, "      \"textureType\": %lu,\n", (unsigned long)texType);
            fprintf(jsonFile, "      \"usage\": %lu,\n", (unsigned long)usage);
            fprintf(jsonFile, "      \"label\": \"%s\"", tex.label ? [tex.label UTF8String] : "");
            
            // Try to export pixel data for the first 2D texture with reasonable size
            // Skip Depth/Stencil formats (fmt >= 250 && fmt <= 260 are depth/stencil)
            BOOL isDepthStencil = (fmt >= 250 && fmt <= 260) || fmt == 252 || fmt == 253 || fmt == 255 || fmt == 260;
            if (!firstBinaryExported && !isDepthStencil && texType == MTLTextureType2D && w > 0 && h > 0 && w <= 4096 && h <= 4096) {
                // Calculate bytes per row (assume 4 bytes per pixel for RGBA8/BGRA8, adjust for others)
                NSUInteger bytesPerPixel = 4; // default assumption
                if (fmt == MTLPixelFormatRGBA8Unorm || fmt == MTLPixelFormatBGRA8Unorm ||
                    fmt == MTLPixelFormatRGBA8Unorm_sRGB || fmt == MTLPixelFormatBGRA8Unorm_sRGB) {
                    bytesPerPixel = 4;
                } else if (fmt == MTLPixelFormatRGBA16Float) {
                    bytesPerPixel = 8;
                } else if (fmt == MTLPixelFormatRGBA32Float) {
                    bytesPerPixel = 16;
                } else if (fmt == MTLPixelFormatR8Unorm) {
                    bytesPerPixel = 1;
                } else if (fmt == MTLPixelFormatRG8Unorm) {
                    bytesPerPixel = 2;
                } else if (fmt == MTLPixelFormatR16Float) {
                    bytesPerPixel = 2;
                } else if (fmt == MTLPixelFormatRG16Float) {
                    bytesPerPixel = 4;
                } else if (fmt == MTLPixelFormatR32Float) {
                    bytesPerPixel = 4;
                } else if (fmt == MTLPixelFormatDepth32Float) {
                    bytesPerPixel = 4;
                }
                
                NSUInteger bytesPerRow = w * bytesPerPixel;
                NSUInteger totalBytes = bytesPerRow * h;
                
                void *pixelData = malloc(totalBytes);
                if (pixelData) {
                    @try {
                        [tex getBytes:pixelData
                          bytesPerRow:bytesPerRow
                           fromRegion:MTLRegionMake2D(0, 0, w, h)
                          mipmapLevel:0];
                        
                        // Write binary file
                        NSString *binName = [NSString stringWithFormat:@"texture_%lu_%lux%lu_fmt%lu.bin",
                                            (unsigned long)i, (unsigned long)w, (unsigned long)h, (unsigned long)fmt];
                        NSString *binPath = [outputDir stringByAppendingPathComponent:binName];
                        FILE *binFile = fopen([binPath UTF8String], "wb");
                        if (binFile) {
                            fwrite(pixelData, 1, totalBytes, binFile);
                            fclose(binFile);
                            fprintf(jsonFile, ",\n      \"exported_binary\": \"%s\"", [binName UTF8String]);
                            fprintf(jsonFile, ",\n      \"binary_size\": %lu", (unsigned long)totalBytes);
                            firstBinaryExported = YES;
                            textureExported++;
                            fprintf(stdout, "  [EXPORT] Texture %lu: %lux%lu fmt=%lu -> %s (%lu bytes)\n",
                                    (unsigned long)i, (unsigned long)w, (unsigned long)h,
                                    (unsigned long)fmt, [binName UTF8String], (unsigned long)totalBytes);
                        }
                    } @catch (NSException *ex) {
                        fprintf(jsonFile, ",\n      \"export_error\": \"%s\"", [[ex reason] UTF8String]);
                        fprintf(stderr, "  [WARN] getBytes failed for texture %lu: %s\n",
                                (unsigned long)i, [[ex reason] UTF8String]);
                    }
                    free(pixelData);
                }
            }
            
            fprintf(jsonFile, "\n    }");
        }
        
        fprintf(jsonFile, "\n  ],\n");
        
        // --- Export buffer metadata ---
        fprintf(jsonFile, "  \"buffers\": [\n");
        int maxBufferDetail = 20;
        
        for (NSUInteger i = 0; i < [bufferKeys count] && i < (NSUInteger)maxBufferDetail; i++) {
            id key = bufferKeys[i];
            id<MTLBuffer> buf = (id<MTLBuffer>)resources[key];
            
            NSUInteger length = buf.length;
            
            if (i > 0) fprintf(jsonFile, ",\n");
            fprintf(jsonFile, "    {\n");
            fprintf(jsonFile, "      \"key\": \"%s\",\n", [[key description] UTF8String]);
            fprintf(jsonFile, "      \"length\": %lu,\n", (unsigned long)length);
            fprintf(jsonFile, "      \"label\": \"%s\"", buf.label ? [buf.label UTF8String] : "");
            
            // Export first small buffer's raw data
            if (i == 0 && length > 0 && length <= 1048576) { // max 1MB
                void *contents = [buf contents];
                if (contents) {
                    NSString *bufBinName = [NSString stringWithFormat:@"buffer_%lu_len%lu.bin",
                                           (unsigned long)i, (unsigned long)length];
                    NSString *bufBinPath = [outputDir stringByAppendingPathComponent:bufBinName];
                    FILE *bufFile = fopen([bufBinPath UTF8String], "wb");
                    if (bufFile) {
                        fwrite(contents, 1, length, bufFile);
                        fclose(bufFile);
                        fprintf(jsonFile, ",\n      \"exported_binary\": \"%s\"", [bufBinName UTF8String]);
                        fprintf(stdout, "  [EXPORT] Buffer %lu: %lu bytes -> %s\n",
                                (unsigned long)i, (unsigned long)length, [bufBinName UTF8String]);
                    }
                }
            }
            
            fprintf(jsonFile, "\n    }");
        }
        
        fprintf(jsonFile, "\n  ],\n");
        
        // Phase A summary
        fprintf(jsonFile, "  \"phase_a_summary\": {\n");
        fprintf(jsonFile, "    \"playAll_rc\": %d,\n", play_rc);
        fprintf(jsonFile, "    \"textures_exported\": %d,\n", textureExported);
        fprintf(jsonFile, "    \"first_binary_exported\": %s\n", firstBinaryExported ? "true" : "false");
        fprintf(jsonFile, "  }");
        
        // ============================================================
        // PHASE B: playTo directed replay
        // ============================================================
        fprintf(stdout, "\n========== PHASE B: playTo Directed Replay ==========\n\n");
        
        // Rewind first
        ctrl_rewind(controller);
        fprintf(stdout, "[rewind] done\n");
        
        // playTo target index 1 (first draw call)
        uint32_t targetA = 1;
        fprintf(stdout, "[playTo] target=%u ...\n", targetA);
        int playto_rc = 0;
        @try {
            playto_rc = play_to(controller, targetA);
            fprintf(stdout, "[playTo(%u)] returned: %d %s\n", targetA, playto_rc,
                    playto_rc == 0 ? "[SUCCESS]" : "[NON-ZERO]");
        } @catch (NSException *ex) {
            fprintf(stderr, "[playTo EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
            playto_rc = -999;
        }
        
        // Capture resource state after playTo(1)
        NSUInteger resourcesAfterPlayTo1 = 0;
        @try {
            NSDictionary *res1 = [objectMap performSelector:@selector(resources)];
            resourcesAfterPlayTo1 = [res1 count];
            fprintf(stdout, "  resources count after playTo(%u): %lu\n", targetA, (unsigned long)resourcesAfterPlayTo1);
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s\n", [[ex reason] UTF8String]);
        }
        
        // Now playTo a higher index and compare
        ctrl_rewind(controller);
        uint32_t targetB = 10;
        fprintf(stdout, "\n[playTo] target=%u ...\n", targetB);
        int playto_rc2 = 0;
        @try {
            playto_rc2 = play_to(controller, targetB);
            fprintf(stdout, "[playTo(%u)] returned: %d %s\n", targetB, playto_rc2,
                    playto_rc2 == 0 ? "[SUCCESS]" : "[NON-ZERO]");
        } @catch (NSException *ex) {
            fprintf(stderr, "[playTo EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
            playto_rc2 = -999;
        }
        
        NSUInteger resourcesAfterPlayTo10 = 0;
        @try {
            NSDictionary *res2 = [objectMap performSelector:@selector(resources)];
            resourcesAfterPlayTo10 = [res2 count];
            fprintf(stdout, "  resources count after playTo(%u): %lu\n", targetB, (unsigned long)resourcesAfterPlayTo10);
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s\n", [[ex reason] UTF8String]);
        }
        
        // Compare first texture content between playTo(1) and playTo(10) if possible
        BOOL contentDiffers = NO;
        if ([textureKeys count] > 0 && playto_rc == 0 && playto_rc2 == 0) {
            // Re-do playTo(1) and capture first texture
            ctrl_rewind(controller);
            play_to(controller, targetA);
            
            id<MTLTexture> tex0 = (id<MTLTexture>)resources[textureKeys[0]];
            NSUInteger w = tex0.width, h = tex0.height;
            if (tex0.textureType == MTLTextureType2D && w > 0 && h > 0 && w <= 4096 && h <= 4096) {
                NSUInteger bpp = 4;
                NSUInteger bpr = w * bpp;
                NSUInteger total = bpr * h;
                void *dataA = malloc(total);
                void *dataB = malloc(total);
                
                if (dataA && dataB) {
                    @try {
                        [tex0 getBytes:dataA bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
                        
                        ctrl_rewind(controller);
                        play_to(controller, targetB);
                        [tex0 getBytes:dataB bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
                        
                        contentDiffers = (memcmp(dataA, dataB, total) != 0);
                        fprintf(stdout, "\n  [COMPARE] Texture '%s' (%lux%lu):\n",
                                tex0.label ? [tex0.label UTF8String] : [[[textureKeys[0] description] substringToIndex:MIN(30, [[textureKeys[0] description] length])] UTF8String],
                                (unsigned long)w, (unsigned long)h);
                        fprintf(stdout, "    playTo(%u) vs playTo(%u): %s\n",
                                targetA, targetB, contentDiffers ? "DIFFERENT" : "SAME");
                    } @catch (NSException *ex) {
                        fprintf(stderr, "  [COMPARE EXCEPTION] %s\n", [[ex reason] UTF8String]);
                    }
                }
                if (dataA) free(dataA);
                if (dataB) free(dataB);
            }
        }
        
        // Write Phase B results to JSON
        fprintf(jsonFile, ",\n  \"phase_b_playTo\": {\n");
        fprintf(jsonFile, "    \"playTo_symbol\": \"GTMTLReplayController_playTo\",\n");
        fprintf(jsonFile, "    \"signature\": \"int (void *controller, uint32_t targetCallIndex)\",\n");
        fprintf(jsonFile, "    \"playTo_%u_rc\": %d,\n", targetA, playto_rc);
        fprintf(jsonFile, "    \"playTo_%u_rc\": %d,\n", targetB, playto_rc2);
        fprintf(jsonFile, "    \"resources_after_playTo_%u\": %lu,\n", targetA, (unsigned long)resourcesAfterPlayTo1);
        fprintf(jsonFile, "    \"resources_after_playTo_%u\": %lu,\n", targetB, (unsigned long)resourcesAfterPlayTo10);
        fprintf(jsonFile, "    \"content_differs\": %s\n", contentDiffers ? "true" : "false");
        fprintf(jsonFile, "  }\n");
        fprintf(jsonFile, "}\n");
        fclose(jsonFile);
        
        fprintf(stdout, "\n[OK] JSON metadata written to: %s\n", [jsonPath UTF8String]);
        
        // === Final Summary ===
        fprintf(stdout, "\n========== R4.3 Summary ==========\n");
        fprintf(stdout, "Phase A (ObjectMap Data Extraction):\n");
        fprintf(stdout, "  - resources enumerated: %lu entries\n", (unsigned long)totalCount);
        fprintf(stdout, "  - MTLTexture objects: %lu\n", (unsigned long)[textureKeys count]);
        fprintf(stdout, "  - MTLBuffer objects: %lu\n", (unsigned long)[bufferKeys count]);
        fprintf(stdout, "  - Binary texture exported: %s\n", firstBinaryExported ? "YES" : "NO");
        fprintf(stdout, "\nPhase B (playTo Directed Replay):\n");
        fprintf(stdout, "  - playTo(%u): rc=%d\n", targetA, playto_rc);
        fprintf(stdout, "  - playTo(%u): rc=%d\n", targetB, playto_rc2);
        fprintf(stdout, "  - Content differs between targets: %s\n", contentDiffers ? "YES" : "NO");
        fprintf(stdout, "\n=== R4.3 Probe Complete ===\n");
        
        dlclose(handle);
        return 0;
    }
}
