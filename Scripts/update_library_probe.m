/**
 * update_library_probe.m — R5.2 Shader 热替换探针
 *
 * 目标：验证 GTReplayUpdateLibrary 在 Controller 路径下的调用可行性
 *
 * 策略：
 *   Phase 0: Runtime introspection — 列出 GTReplayUpdateLibrary 和
 *            GTMTLReplayService 的所有方法/属性
 *   Phase 1: Controller replay + baseline 数据导出
 *   Phase 2: 实例化 GTReplayUpdateLibrary，设置属性并提交
 *   Phase 3: 对比替换前后输出差异
 *
 * 特别关注：shaderIR 路径 — 即直接提供 metallib/AIR binary 替换，
 *           无需 shader source。这是 Xcode UI 未暴露的能力。
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o update_library_probe update_library_probe.m
 *
 * 用法：
 *   ./update_library_probe <path-to-.gputrace>
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - Helper: resolve internal function via CLI BL offset

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

#pragma mark - Function signatures

typedef int (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void (*supportInit_fn)(void *device);
typedef void (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef int (*playAll_fn)(void *controller);
typedef int (*playTo_fn)(void *controller, uint32_t target);
typedef void (*rewind_fn)(void *controller);

#pragma mark - Runtime introspection helper

static void dump_class_info(const char *className) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) {
        fprintf(stdout, "[INTROSPECT] Class '%s' NOT FOUND\n", className);
        return;
    }
    fprintf(stdout, "\n[INTROSPECT] === %s ===\n", className);
    
    // Superclass chain
    Class super = class_getSuperclass(cls);
    fprintf(stdout, "  Superclass: %s\n", super ? class_getName(super) : "(none)");
    
    // Properties
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    fprintf(stdout, "  Properties (%u):\n", propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        fprintf(stdout, "    %s — %s\n", name, attrs);
    }
    free(props);
    
    // Instance methods
    unsigned int methCount = 0;
    Method *meths = class_copyMethodList(cls, &methCount);
    fprintf(stdout, "  Instance methods (%u):\n", methCount);
    for (unsigned int i = 0; i < methCount; i++) {
        SEL sel = method_getName(meths[i]);
        const char *types = method_getTypeEncoding(meths[i]);
        fprintf(stdout, "    %s — %s\n", sel_getName(sel), types ? types : "?");
    }
    free(meths);
    
    // Class methods
    Class metaCls = object_getClass((id)cls);
    unsigned int cMethCount = 0;
    Method *cMeths = class_copyMethodList(metaCls, &cMethCount);
    if (cMethCount > 0) {
        fprintf(stdout, "  Class methods (%u):\n", cMethCount);
        for (unsigned int i = 0; i < cMethCount; i++) {
            SEL sel = method_getName(cMeths[i]);
            fprintf(stdout, "    +%s\n", sel_getName(sel));
        }
    }
    free(cMeths);
    
    // Protocols
    unsigned int protoCount = 0;
    __unsafe_unretained Protocol **protos = class_copyProtocolList(cls, &protoCount);
    if (protoCount > 0) {
        fprintf(stdout, "  Protocols (%u):\n", protoCount);
        for (unsigned int i = 0; i < protoCount; i++) {
            fprintf(stdout, "    %s\n", protocol_getName(protos[i]));
        }
    }
    free(protos);
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", argv[0]);
            return 1;
        }
        const char *gputrace_path = argv[1];

        fprintf(stdout, "=== R5.2 Shader Hot-Replace Probe ===\n\n");
        fprintf(stdout, "[INFO] .gputrace: %s\n\n", gputrace_path);

        // === Validate input ===
        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        NSFileManager *fm = [NSFileManager defaultManager];
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
        fprintf(stdout, "[INFO] Metal device: %s\n\n", [[device name] UTF8String]);

        // === dlopen frameworks ===
        const char *replay_fw = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
        const char *transport_fw = "/System/Library/PrivateFrameworks/GPUToolsTransport.framework/GPUToolsTransport";
        
        void *replay_handle = dlopen(replay_fw, RTLD_NOW);
        void *transport_handle = dlopen(transport_fw, RTLD_NOW);
        if (!replay_handle) {
            fprintf(stderr, "[ERROR] dlopen GPUToolsReplay failed: %s\n", dlerror());
            return 4;
        }
        if (!transport_handle) {
            fprintf(stderr, "[ERROR] dlopen GPUToolsTransport failed: %s\n", dlerror());
            dlclose(replay_handle);
            return 4;
        }
        fprintf(stdout, "[OK] Both frameworks loaded\n");

        // ============================================================
        // PHASE 0: Runtime Introspection
        // ============================================================
        fprintf(stdout, "\n========== PHASE 0: Runtime Introspection ==========\n");
        
        dump_class_info("GTReplayUpdateLibrary");
        dump_class_info("GTReplayUpdateLibraryCache");
        dump_class_info("GTReplayUpdateConfiguration");
        dump_class_info("GTMTLReplayService");
        dump_class_info("GTReplayRequestBatch");
        dump_class_info("GTReplayRequestToken");
        
        // Also check if there's a GTMTLReplayController class (may not exist as ObjC class)
        dump_class_info("GTMTLReplayController");
        
        // Check GTMTLReplayObjectMap for update-related methods
        fprintf(stdout, "\n[INTROSPECT] GTMTLReplayObjectMap update-related methods:\n");
        Class omClass = NSClassFromString(@"GTMTLReplayObjectMap");
        if (omClass) {
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(omClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "update") || strstr(name, "Update") ||
                    strstr(name, "replace") || strstr(name, "Replace") ||
                    strstr(name, "reload") || strstr(name, "Reload") ||
                    strstr(name, "setLibrary") || strstr(name, "setShader") ||
                    strstr(name, "replaceLibrary")) {
                    const char *types = method_getTypeEncoding(meths[i]);
                    fprintf(stdout, "    %s — %s\n", name, types ? types : "?");
                }
            }
            free(meths);
        }

        // ============================================================
        // PHASE 1: Controller Replay + Baseline
        // ============================================================
        fprintf(stdout, "\n========== PHASE 1: Controller Replay + Baseline ==========\n\n");

        // Resolve symbols
        void *gt_env = dlsym(replay_handle, "GT_ENV");
        void *cli_fn = dlsym(replay_handle, "GTMTLReplay_CLI");
        if (!gt_env || !cli_fn) {
            fprintf(stderr, "[ERROR] Missing GT_ENV or GTMTLReplay_CLI\n");
            return 5;
        }

        apr_pool_create_fn apr_pool_create = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn make_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn support_init = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn init_argbuf = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn populate_unused = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn make_ctrl = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn play_all = (playAll_fn)dlsym(replay_handle, "GTMTLReplayController_playAll");
        playTo_fn play_to = (playTo_fn)dlsym(replay_handle, "GTMTLReplayController_playTo");
        rewind_fn rewind_ctrl = (rewind_fn)dlsym(replay_handle, "GTMTLReplayController_rewind");

        if (!play_all || !play_to || !rewind_ctrl) {
            fprintf(stderr, "[ERROR] Missing playAll/playTo/rewind\n");
            return 5;
        }
        fprintf(stdout, "[OK] All symbols resolved\n");

        // APR Bootstrap
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

        // Create Controller
        void *pool = NULL;
        int rc = apr_pool_create(&pool, NULL, NULL, NULL);
        if (rc != 0 || !pool) {
            fprintf(stderr, "[FATAL] APR pool creation failed\n");
            return 6;
        }

        void *dataSource = make_ds(gputrace_path, pool);
        if (!dataSource) {
            fprintf(stderr, "[FATAL] makeDataSource failed\n");
            return 7;
        }

        support_init((__bridge void *)device);

        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        id objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
        if (!objectMap) {
            fprintf(stderr, "[FATAL] objectMap creation failed\n");
            return 8;
        }

        init_argbuf(dataSource, (__bridge void *)device, (__bridge void *)objectMap);
        populate_unused(dataSource, (__bridge void *)objectMap);

        void *controller = make_ctrl(dataSource, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) {
            fprintf(stderr, "[FATAL] makeController failed\n");
            return 9;
        }
        fprintf(stdout, "[OK] Controller created\n");

        // === Baseline playAll ===
        int play_rc = play_all(controller);
        fprintf(stdout, "[playAll] returned: %d %s\n", play_rc, play_rc == 0 ? "[SUCCESS]" : "[FAILED]");
        if (play_rc != 0) {
            fprintf(stderr, "[FATAL] playAll failed — cannot proceed\n");
            return 10;
        }

        // Get baseline resources
        NSDictionary *resources = [objectMap performSelector:@selector(resources)];
        fprintf(stdout, "[BASELINE] resources count: %lu\n", (unsigned long)[resources count]);

        // Find first library for replacement target
        SEL libSel = @selector(libraryForKey:);
        id funcMap = [objectMap performSelector:@selector(functionMap)];
        
        uint64_t targetLibKey = 0;
        id targetLib = nil;
        BOOL foundLib = NO;
        
        if (funcMap && [funcMap isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)funcMap) {
                uint64_t fk = [key unsignedLongLongValue];
                uint64_t lk = fk - 1; // library key = function key - 1
                id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, libSel, lk);
                if (lib && [lib conformsToProtocol:@protocol(MTLLibrary)]) {
                    targetLibKey = lk;
                    targetLib = lib;
                    foundLib = YES;
                    break;
                }
            }
        }
        
        if (!foundLib) {
            fprintf(stderr, "[WARN] No library found for replacement target\n");
            // Try scanning keys 0..300
            for (uint64_t k = 0; k <= 300; k++) {
                id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, libSel, k);
                if (lib && [lib conformsToProtocol:@protocol(MTLLibrary)]) {
                    targetLibKey = k;
                    targetLib = lib;
                    foundLib = YES;
                    break;
                }
            }
        }

        if (!foundLib) {
            fprintf(stderr, "[FATAL] No library found in objectMap\n");
            return 11;
        }

        id<MTLLibrary> mtlLib = (id<MTLLibrary>)targetLib;
        fprintf(stdout, "\n[TARGET] Library key=%llu class=%s\n", targetLibKey, class_getName([targetLib class]));
        fprintf(stdout, "[TARGET] Functions: %s\n", [[[mtlLib functionNames] description] UTF8String]);

        // Export baseline metallib for reference
        NSData *baselineMetallib = nil;
        SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
        if ([targetLib respondsToSelector:ldcSel]) {
            baselineMetallib = [targetLib performSelector:ldcSel];
            fprintf(stdout, "[TARGET] metallib size: %lu bytes\n", (unsigned long)[baselineMetallib length]);
        }
        
        // Export baseline bitcode (AIR)
        NSData *baselineBitcode = nil;
        SEL bcSel = NSSelectorFromString(@"bitcodeData");
        if ([targetLib respondsToSelector:bcSel]) {
            @try {
                baselineBitcode = [targetLib performSelector:bcSel];
                fprintf(stdout, "[TARGET] bitcode size: %lu bytes\n",
                        baselineBitcode ? (unsigned long)[baselineBitcode length] : 0);
            } @catch (NSException *e) {
                fprintf(stdout, "[TARGET] bitcode: exception %s\n", [[e reason] UTF8String]);
            }
        }

        // Capture a baseline texture for comparison
        NSData *baselineTexData = nil;
        id baselineTex = nil;
        uint64_t baselineTexKey = 0;
        for (id key in resources) {
            id res = [resources objectForKey:key];
            if ([res conformsToProtocol:@protocol(MTLTexture)]) {
                id<MTLTexture> tex = (id<MTLTexture>)res;
                if (tex.width >= 32 && tex.height >= 32 && tex.pixelFormat == MTLPixelFormatRGBA8Unorm) {
                    NSUInteger bpr = tex.width * 4;
                    NSUInteger totalBytes = bpr * tex.height;
                    NSMutableData *data = [NSMutableData dataWithLength:totalBytes];
                    [tex getBytes:[data mutableBytes]
                      bytesPerRow:bpr
                       fromRegion:MTLRegionMake2D(0, 0, tex.width, tex.height)
                      mipmapLevel:0];
                    baselineTexData = data;
                    baselineTex = tex;
                    baselineTexKey = [key unsignedLongLongValue];
                    fprintf(stdout, "[BASELINE] Captured texture key=%llu %lux%lu (%lu bytes)\n",
                            baselineTexKey, (unsigned long)tex.width, (unsigned long)tex.height,
                            (unsigned long)[data length]);
                    break;
                }
            }
        }

        // ============================================================
        // PHASE 2: GTReplayUpdateLibrary — Attempt Update
        // ============================================================
        fprintf(stdout, "\n========== PHASE 2: GTReplayUpdateLibrary Attempt ==========\n\n");

        Class updateLibClass = NSClassFromString(@"GTReplayUpdateLibrary");
        if (!updateLibClass) {
            fprintf(stderr, "[ERROR] GTReplayUpdateLibrary class not found\n");
            return 12;
        }

        // Create an update request object
        id updateReq = [[updateLibClass alloc] init];
        fprintf(stdout, "[OK] GTReplayUpdateLibrary instance: %s\n", [[updateReq description] UTF8String]);

        // Set dispatchUID and streamRef (use 0 = first dispatch)
        if ([updateReq respondsToSelector:@selector(setDispatchUID:)]) {
            ((void (*)(id, SEL, uint64_t))objc_msgSend)(updateReq, @selector(setDispatchUID:), (uint64_t)0);
            fprintf(stdout, "[SET] dispatchUID = 0\n");
        }
        if ([updateReq respondsToSelector:@selector(setStreamRef:)]) {
            ((void (*)(id, SEL, uint64_t))objc_msgSend)(updateReq, @selector(setStreamRef:), (uint64_t)0);
            fprintf(stdout, "[SET] streamRef = 0\n");
        }

        // === Strategy A: shaderIR (metallib binary) ===
        // Use the SAME metallib data (identity replacement) to verify the mechanism works
        if (baselineMetallib && [updateReq respondsToSelector:@selector(setShaderIR:)]) {
            [updateReq performSelector:@selector(setShaderIR:) withObject:baselineMetallib];
            fprintf(stdout, "[SET] shaderIR = baseline metallib (%lu bytes) — identity replacement\n",
                    (unsigned long)[baselineMetallib length]);
        } else {
            fprintf(stdout, "[WARN] shaderIR setter not available or no baseline metallib\n");
        }

        // === Strategy B: shaderSource (Metal Shading Language) ===
        // Create a trivial modified shader source
        NSString *trivialShader = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void trivial_test(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]]) { out[gid] = 42.0; }\n";
        
        // Don't set shaderSource if we already set shaderIR (test one path at a time)
        // We'll test shaderSource in a second pass if shaderIR fails

        // ============================================================
        // PHASE 2b: Find Update Entry Point on Controller/Service
        // ============================================================
        fprintf(stdout, "\n--- Finding update entry point ---\n\n");

        // Check 1: GTMTLReplayService — does it have an 'update:' or 'processRequest:' method?
        Class serviceClass = NSClassFromString(@"GTMTLReplayService");
        if (serviceClass) {
            fprintf(stdout, "[INFO] GTMTLReplayService found, checking for update/request methods...\n");
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(serviceClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "update") || strstr(name, "Update") ||
                    strstr(name, "request") || strstr(name, "Request") ||
                    strstr(name, "process") || strstr(name, "handle") ||
                    strstr(name, "submit") || strstr(name, "perform") ||
                    strstr(name, "replay") || strstr(name, "library") ||
                    strstr(name, "Library")) {
                    const char *types = method_getTypeEncoding(meths[i]);
                    fprintf(stdout, "    [CANDIDATE] %s — %s\n", name, types ? types : "?");
                }
            }
            free(meths);
        }
        
        // Check 2: Is there a Controller ObjC wrapper or C function for update?
        // The controller is a C void* — check if there's a GTMTLReplayController_update export
        void *update_fn = dlsym(replay_handle, "GTMTLReplayController_update");
        void *update_lib_fn = dlsym(replay_handle, "GTMTLReplayController_updateLibrary");
        void *process_fn = dlsym(replay_handle, "GTMTLReplayController_processRequest");
        void *handle_fn = dlsym(replay_handle, "GTMTLReplayController_handleRequest");
        
        fprintf(stdout, "  GTMTLReplayController_update: %p\n", update_fn);
        fprintf(stdout, "  GTMTLReplayController_updateLibrary: %p\n", update_lib_fn);
        fprintf(stdout, "  GTMTLReplayController_processRequest: %p\n", process_fn);
        fprintf(stdout, "  GTMTLReplayController_handleRequest: %p\n", handle_fn);

        // Check 3: GTMTLReplayService XPC Dispatcher — processUpdate method
        Class dispatcherClass = NSClassFromString(@"GTMTLReplayServiceXPCDispatcher");
        if (dispatcherClass) {
            fprintf(stdout, "\n[INFO] GTMTLReplayServiceXPCDispatcher methods related to update:\n");
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(dispatcherClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "update") || strstr(name, "Update") ||
                    strstr(name, "library") || strstr(name, "Library") ||
                    strstr(name, "shader") || strstr(name, "Shader") ||
                    strstr(name, "replay") || strstr(name, "process")) {
                    const char *types = method_getTypeEncoding(meths[i]);
                    fprintf(stdout, "    %s — %s\n", name, types ? types : "?");
                }
            }
            free(meths);
        }
        
        // Check 4: Try to find update through the "replayer" (controller wrapper in ObjC?)
        // GTMTLReplayService might wrap the controller
        if (serviceClass) {
            fprintf(stdout, "\n[INFO] GTMTLReplayService ALL methods:\n");
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(serviceClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *types = method_getTypeEncoding(meths[i]);
                fprintf(stdout, "    %s — %s\n", sel_getName(sel), types ? types : "?");
            }
            free(meths);
        }

        // ============================================================
        // PHASE 2c: Direct ObjectMap Library Replacement Attempt
        // ============================================================
        fprintf(stdout, "\n--- Phase 2c: Direct ObjectMap Library Replacement ---\n\n");
        
        // The ObjectMap stores libraries by key. If we can create a new MTLLibrary from
        // modified metallib data and put it back, the controller might use it on next playAll.
        
        // First, let's check if objectMap has a setLibrary:forKey: or similar setter
        fprintf(stdout, "[INFO] Checking ObjectMap for library setter methods...\n");
        if (omClass) {
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(omClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "setLibrary") || strstr(name, "setObject") ||
                    strstr(name, "ForKey") || strstr(name, "forKey") ||
                    strstr(name, "register") || strstr(name, "Register") ||
                    strstr(name, "add") || strstr(name, "put")) {
                    // Only show ForKey setters or register methods
                    if (strstr(name, "set") || strstr(name, "register") ||
                        strstr(name, "Register") || strstr(name, "add") || strstr(name, "put")) {
                        const char *types = method_getTypeEncoding(meths[i]);
                        fprintf(stdout, "    %s — %s\n", name, types ? types : "?");
                    }
                }
            }
            free(meths);
        }
        
        // Try creating a new library from metallib data and see if we can swap
        if (baselineMetallib) {
            fprintf(stdout, "\n[TEST] Creating new MTLLibrary from baseline metallib data...\n");
            NSError *libErr = nil;
            dispatch_data_t dd = dispatch_data_create(
                [baselineMetallib bytes], [baselineMetallib length],
                dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            id<MTLLibrary> newLib = [device newLibraryWithData:dd error:&libErr];
            if (newLib) {
                fprintf(stdout, "[OK] New MTLLibrary created from metallib: %s functions=%s\n",
                        class_getName([newLib class]),
                        [[[newLib functionNames] description] UTF8String]);
                
                // Check if we can replace in objectMap
                SEL setLibSel = NSSelectorFromString(@"setLibrary:forKey:");
                SEL setObjSel = NSSelectorFromString(@"setObject:forKey:");
                SEL replaceLibSel = NSSelectorFromString(@"replaceLibraryForKey:withLibrary:");
                
                if ([objectMap respondsToSelector:setLibSel]) {
                    fprintf(stdout, "[FOUND] objectMap responds to setLibrary:forKey:\n");
                } else if ([objectMap respondsToSelector:setObjSel]) {
                    fprintf(stdout, "[FOUND] objectMap responds to setObject:forKey:\n");
                } else if ([objectMap respondsToSelector:replaceLibSel]) {
                    fprintf(stdout, "[FOUND] objectMap responds to replaceLibraryForKey:withLibrary:\n");
                } else {
                    fprintf(stdout, "[INFO] objectMap does NOT have obvious library setter\n");
                }
            } else {
                fprintf(stdout, "[ERROR] newLibraryWithData failed: %s\n", [[libErr localizedDescription] UTF8String]);
            }
        }

        // ============================================================
        // PHASE 3: GTMTLReplayService — Attempt instantiation & update
        // ============================================================
        fprintf(stdout, "\n========== PHASE 3: GTMTLReplayService Update Path ==========\n\n");
        
        if (serviceClass) {
            // Try to create a service instance
            // GTMTLReplayService might need specific init params...
            fprintf(stdout, "[INFO] Attempting GTMTLReplayService instantiation...\n");
            
            // Check init methods
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(serviceClass, &methCount);
            NSMutableArray *initMethods = [NSMutableArray array];
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strncmp(name, "init", 4) == 0) {
                    [initMethods addObject:[NSString stringWithUTF8String:name]];
                    fprintf(stdout, "    init: %s — %s\n", name, method_getTypeEncoding(meths[i]));
                }
            }
            free(meths);
        }

        // ============================================================
        // PHASE 4: Alternative — Direct Controller Update via BL scan
        // ============================================================
        fprintf(stdout, "\n========== PHASE 4: BL Scan for Update Functions ==========\n\n");
        
        // The GTMTLReplayService likely calls internal C functions for update operations
        // Let's scan the GTMTLReplayService implementation for update-related selectors
        // by checking what selectors are referenced
        
        // Try scanning GTMTLReplay_CLI BL targets beyond known offsets
        // Known: 0x50 (apr_pool_create), 0x13c (makeDS), 0x888-0x954 (init chain)
        // The CLI doesn't do updates, but GTMTLReplayController_init (offset 0x00211C44)
        // might have update-related BL calls
        
        // Let's check if GTMTLReplayController_init has BL instructions we can scan
        void *ctrl_init = dlsym(replay_handle, "GTMTLReplayController_init");
        if (ctrl_init) {
            fprintf(stdout, "[INFO] GTMTLReplayController_init at %p\n", ctrl_init);
            // Scan first 200 instructions for BL calls
            uint32_t *code = (uint32_t *)ctrl_init;
            int bl_count = 0;
            for (int i = 0; i < 200; i++) {
                uint32_t inst = code[i];
                if ((inst & 0xFC000000) == 0x94000000) {
                    int32_t imm26 = (int32_t)(inst << 6) >> 6;
                    void *target = (void*)((uint64_t)ctrl_init + i * 4 + (int64_t)imm26 * 4);
                    // Check if target matches any known symbol
                    Dl_info info;
                    if (dladdr(target, &info) && info.dli_sname) {
                        if (strstr(info.dli_sname, "update") || strstr(info.dli_sname, "Update") ||
                            strstr(info.dli_sname, "library") || strstr(info.dli_sname, "Library") ||
                            strstr(info.dli_sname, "shader") || strstr(info.dli_sname, "Shader") ||
                            strstr(info.dli_sname, "replace") || strstr(info.dli_sname, "Replace")) {
                            fprintf(stdout, "    [BL+%04x] → %s (%p)\n", i*4, info.dli_sname, target);
                        }
                    }
                    bl_count++;
                }
                // Stop at RET
                if (inst == 0xD65F03C0) break;
            }
            fprintf(stdout, "  (scanned %d BL instructions)\n", bl_count);
        }
        
        // ============================================================
        // PHASE 5: Summary & JSON Output
        // ============================================================
        fprintf(stdout, "\n========== PHASE 5: Summary ==========\n\n");
        
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"probe"] = @"R5.2_update_library_probe";
        result[@"gputrace"] = pathStr;
        result[@"device"] = [device name];
        result[@"playAll_rc"] = @(play_rc);
        result[@"baseline_resources_count"] = @([resources count]);
        result[@"target_library_key"] = @(targetLibKey);
        result[@"target_library_class"] = targetLib ? NSStringFromClass([targetLib class]) : @"none";
        result[@"target_library_functions"] = targetLib ? [[mtlLib functionNames] description] : @"none";
        result[@"baseline_metallib_size"] = @(baselineMetallib ? [baselineMetallib length] : 0);
        result[@"baseline_bitcode_size"] = @(baselineBitcode ? [baselineBitcode length] : 0);
        result[@"GTReplayUpdateLibrary_available"] = @(updateLibClass != nil);
        result[@"GTMTLReplayService_available"] = @(serviceClass != nil);
        result[@"controller_update_fn"] = @(update_fn != NULL);
        result[@"controller_updateLibrary_fn"] = @(update_lib_fn != NULL);
        result[@"controller_processRequest_fn"] = @(process_fn != NULL);
        
        NSString *outputPath = [[pathStr stringByDeletingLastPathComponent]
                                stringByAppendingPathComponent:@"update_probe_result.json"];
        NSError *jsonErr = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result
                                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                             error:&jsonErr];
        if (jsonData) {
            [jsonData writeToFile:outputPath atomically:YES];
            fprintf(stdout, "[OK] JSON written: %s\n", [outputPath UTF8String]);
        }
        
        fprintf(stdout, "\n=== R5.2 Probe Complete ===\n");
        
        dlclose(replay_handle);
        dlclose(transport_handle);
        return 0;
    }
}
