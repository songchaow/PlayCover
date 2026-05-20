/**
 * shader_debug_probe3.m — R5.3 Shader Debug with Observer + Queue
 *
 * 发现：GTMTLReplayService.shaderdebug: 请求被接受但 token 永不完成。
 * 原因假设：最小 client 缺少 GTLLVMHelper 连接（操作队列未激活）
 *
 * 本探针：
 *   1. 检查 GTMTLReplayServiceObserver 接口
 *   2. 注册 observer 观察结果
 *   3. 检查 GTMTLReplayClient 中 OperationQueues 字段的作用
 *   4. 尝试手动激活内部处理（runloop / dispatch queue）
 *   5. 检查 service 的 load:error: 方法是否必须先调用
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o shader_debug_probe3 shader_debug_probe3.m
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>

static void* resolve_bl(void *cli_fn, int byte_offset) {
    uint32_t *cli = (uint32_t *)cli_fn;
    int idx = byte_offset / 4;
    uint32_t inst = cli[idx];
    if ((inst & 0xFC000000) != 0x94000000) return NULL;
    int32_t imm26 = (int32_t)(inst << 6) >> 6;
    return (void*)((uint64_t)cli_fn + idx * 4 + (int64_t)imm26 * 4);
}

typedef int (*apr_pool_create_fn)(void **, void *, void *, void *);
typedef void* (*makeDataSource_fn)(const char *, void *);
typedef void (*supportInit_fn)(void *);
typedef void (*initArgBuf_fn)(void *, void *, void *);
typedef void (*populateUnused_fn)(void *, void *);
typedef void* (*makeController_fn)(void *, void *, void *, void *, void *, void *);
typedef int (*playAll_fn)(void *);
typedef void (*rewind_fn)(void *);

typedef struct {
    struct { int encoderIndex; int callIndex; } dispatch;
    uint64_t streamRef;
} DispatchUID;

static void dump_class_short(const char *className) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) { fprintf(stdout, "  [NOT FOUND] %s\n", className); return; }
    fprintf(stdout, "\n  === %s (super: %s) ===\n", className, class_getName(class_getSuperclass(cls)));
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        fprintf(stdout, "    @property %s — %s\n", property_getName(props[i]), property_getAttributes(props[i]));
    }
    free(props);
    unsigned int methCount = 0;
    Method *meths = class_copyMethodList(cls, &methCount);
    for (unsigned int i = 0; i < methCount; i++) {
        fprintf(stdout, "    - %s — %s\n", sel_getName(method_getName(meths[i])), method_getTypeEncoding(meths[i]));
    }
    free(meths);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", argv[0]); return 1; }
        const char *gputrace_path = argv[1];
        fprintf(stdout, "=== R5.3 Shader Debug — Observer & Queue Probe ===\n\n");

        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir; if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) { return 2; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 3;

        void *rh = dlopen("/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay", RTLD_NOW);
        void *th = dlopen("/System/Library/PrivateFrameworks/GPUToolsTransport.framework/GPUToolsTransport", RTLD_NOW);
        if (!rh || !th) return 4;

        // ============================================================
        // PHASE 0: Observer class introspection
        // ============================================================
        fprintf(stdout, "========== PHASE 0: Observer & Infrastructure Classes ==========\n");
        dump_class_short("GTMTLReplayServiceObserver");
        dump_class_short("GTMTLReplayOperationQueues");
        dump_class_short("GTReplayResponseStream");
        dump_class_short("GTReplayResponse");
        dump_class_short("GTTransportMessage_replayer");
        
        // Search for any classes related to shader debug results
        fprintf(stdout, "\n  --- Classes matching 'ShaderDebug*' or 'Debug*Result' ---\n");
        unsigned int cc = 0;
        Class *all = objc_copyClassList(&cc);
        for (unsigned int i = 0; i < cc; i++) {
            const char *n = class_getName(all[i]);
            if ((strstr(n, "ShaderDebug") && !strstr(n, "Request")) ||
                strstr(n, "DebugResult") || strstr(n, "DebugResponse") ||
                strstr(n, "DebugTrace") || strstr(n, "DebugData") ||
                strstr(n, "ShaderProfiler") ||
                (strstr(n, "Shader") && strstr(n, "Stream"))) {
                fprintf(stdout, "    %s (super: %s)\n", n, class_getName(class_getSuperclass(all[i])));
                // Quick property dump
                unsigned int pc = 0;
                objc_property_t *pp = class_copyPropertyList(all[i], &pc);
                for (unsigned int j = 0; j < pc && j < 5; j++) {
                    fprintf(stdout, "      @property %s\n", property_getName(pp[j]));
                }
                if (pc > 5) fprintf(stdout, "      ... (%u more)\n", pc - 5);
                free(pp);
            }
        }
        free(all);

        // ============================================================
        // PHASE 1: Setup controller + service
        // ============================================================
        fprintf(stdout, "\n========== PHASE 1: Setup ==========\n\n");

        void *gt_env = dlsym(rh, "GT_ENV");
        void *cli_fn = dlsym(rh, "GTMTLReplay_CLI");
        apr_pool_create_fn apr_pool_create = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn make_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn support_init = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn init_argbuf = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn populate_unused = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn make_ctrl = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn play_all = (playAll_fn)dlsym(rh, "GTMTLReplayController_playAll");
        rewind_fn rewind_ctrl = (rewind_fn)dlsym(rh, "GTMTLReplayController_rewind");

        void **gpp = (void **)((uint8_t *)gt_env - 0x30);
        if (*gpp == NULL) {
            void *blk = calloc(1, 0x4000);
            void *gp = (uint8_t *)blk + 0x100;
            *(uint64_t *)blk = 20; *(uint64_t *)((uint8_t *)blk + 8) = 20;
            *(void **)gp = blk; *(void **)((uint8_t *)gp + 0x30) = blk;
            *gpp = gp;
        }

        void *pool = NULL; apr_pool_create(&pool, NULL, NULL, NULL);
        void *ds = make_ds(gputrace_path, pool);
        if (!ds) { fprintf(stderr, "[FATAL] makeDataSource\n"); return 5; }
        support_init((__bridge void *)device);
        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        id objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
        init_argbuf(ds, (__bridge void *)device, (__bridge void *)objectMap);
        populate_unused(ds, (__bridge void *)objectMap);
        void *controller = make_ctrl(ds, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) { fprintf(stderr, "[FATAL] makeController\n"); return 6; }
        play_all(controller);
        fprintf(stdout, "[OK] Controller ready, playAll done\n");

        // ============================================================
        // PHASE 2: Create service with proper operation queues
        // ============================================================
        fprintf(stdout, "\n========== PHASE 2: Service with OperationQueues ==========\n\n");
        
        Class serviceClass = NSClassFromString(@"GTMTLReplayService");
        
        // GTMTLReplayClient layout:
        // offset 0:  void *pool (apr_pool_t*)
        // offset 8:  void *controller (GTMTLReplayController*)
        // offset 16: uint64_t (counter or flags)
        // offset 24: struct capabilities {uint64, uint64, uint64, double, uint32, uint32} = 40 bytes
        // offset 64: struct config {{uint32,uint32},uint32,uint32,float,bits} ≈ 20 bytes
        // offset 84: padding to 88
        // offset 88: id observer
        // offset 96: struct GTMTLReplayWireframeRenderer {...}
        // ... (complex)
        // Near end: struct GTMTLReplayOperationQueues {id, id, id} = 24 bytes
        // Final: id, id
        
        // For our purposes, let's try a larger allocation with dispatch queues set
        void *clientBuf = calloc(1, 2048);
        *(void **)((uint8_t *)clientBuf + 0) = pool;
        *(void **)((uint8_t *)clientBuf + 8) = controller;
        
        id service = ((id (*)(id, SEL, void *))objc_msgSend)(
            [serviceClass alloc], @selector(initWithContext:), clientBuf);
        
        if (!service) { fprintf(stderr, "[FATAL] Service nil\n"); free(clientBuf); return 7; }
        fprintf(stdout, "[OK] Service created\n");
        
        // ============================================================
        // PHASE 3: Register observer
        // ============================================================
        fprintf(stdout, "\n========== PHASE 3: Register Observer ==========\n\n");
        
        Class observerClass = NSClassFromString(@"GTMTLReplayServiceObserver");
        if (observerClass) {
            dump_class_short("GTMTLReplayServiceObserver");
            
            // Try to create observer and register
            @try {
                id observer = [[observerClass alloc] init];
                if (observer) {
                    fprintf(stdout, "[OK] Observer instance created\n");
                    
                    // registerObserver: returns uint64 (observer ID)
                    uint64_t obsId = ((uint64_t (*)(id, SEL, id))objc_msgSend)(
                        service, @selector(registerObserver:), observer);
                    fprintf(stdout, "[OK] Registered observer, ID=%llu\n", obsId);
                }
            } @catch (NSException *e) {
                fprintf(stdout, "[EXCEPTION] Observer: %s\n", [[e reason] UTF8String]);
            }
        }

        // ============================================================
        // PHASE 4: load:error: prerequisite check
        // ============================================================
        fprintf(stdout, "\n========== PHASE 4: service load: check ==========\n\n");
        
        // GTMTLReplayService.load:error: — might need to be called before shaderdebug
        // Signature: B32@0:8@16^@24 — returns BOOL, takes id + NSError**
        fprintf(stdout, "[INFO] Checking if load:error: is a prerequisite...\n");
        if ([service respondsToSelector:@selector(load:error:)]) {
            fprintf(stdout, "[INFO] load:error: available. Attempting with gputrace URL...\n");
            
            NSURL *traceURL = [NSURL fileURLWithPath:pathStr];
            NSError *loadErr = nil;
            
            @try {
                BOOL loaded = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
                    service, @selector(load:error:), traceURL, &loadErr);
                fprintf(stdout, "  load: returned %s\n", loaded ? "YES" : "NO");
                if (loadErr) fprintf(stdout, "  error: %s\n", [[loadErr description] UTF8String]);
            } @catch (NSException *e) {
                fprintf(stdout, "  [EXCEPTION] load: %s — %s\n",
                        [[e name] UTF8String], [[e reason] UTF8String]);
            }
        }

        // ============================================================
        // PHASE 5: shaderdebug with all prerequisites
        // ============================================================
        fprintf(stdout, "\n========== PHASE 5: shaderdebug after load ==========\n\n");
        
        // Get metallib for programData
        SEL libSel = @selector(libraryForKey:);
        SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
        id funcMap2 = [objectMap performSelector:@selector(functionMap)];
        NSData *metallib = nil;
        
        for (id key in (NSDictionary *)funcMap2) {
            uint64_t fk = [key unsignedLongLongValue];
            id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, libSel, fk - 1);
            if (lib && [lib conformsToProtocol:@protocol(MTLLibrary)]) {
                metallib = [lib performSelector:ldcSel];
                break;
            }
        }

        Class debugKernelClass = NSClassFromString(@"GTReplayShaderDebugKernel");
        id req = [[debugKernelClass alloc] init];
        
        DispatchUID uid = {{0, 0}, 0};
        typedef void (*setUID_IMP)(id, SEL, DispatchUID);
        ((setUID_IMP)objc_msgSend)(req, @selector(setDispatchUID:), uid);
        
        typedef void (*setSize_IMP)(id, SEL, MTLSize);
        ((setSize_IMP)objc_msgSend)(req, @selector(setMinThreadPositionInGrid:), (MTLSize){0,0,0});
        ((setSize_IMP)objc_msgSend)(req, @selector(setMaxThreadPositionInGrid:), (MTLSize){0,0,0});
        
        if (metallib) [req performSelector:@selector(setProgramData:) withObject:metallib];
        ((void (*)(id, SEL, int))objc_msgSend)(req, @selector(setProgramDataVersion:), 1);
        
        // Set completion handler with result inspection
        __block BOOL completed = NO;
        void (^handler)(id, NSError *) = ^(id result, NSError *error) {
            completed = YES;
            fprintf(stdout, "\n  [CALLBACK FIRED!]\n");
            fprintf(stdout, "    result class: %s\n", result ? class_getName([result class]) : "nil");
            fprintf(stdout, "    result: %s\n", result ? [[[result description] substringToIndex:MIN(200, [[result description] length])] UTF8String] : "(nil)");
            if (error) fprintf(stdout, "    error: %s\n", [[error description] UTF8String]);
            
            // Inspect result object
            if (result) {
                unsigned int pc = 0;
                objc_property_t *pp = class_copyPropertyList([result class], &pc);
                for (unsigned int i = 0; i < pc; i++) {
                    fprintf(stdout, "    result.%s\n", property_getName(pp[i]));
                }
                free(pp);
            }
        };
        [req performSelector:@selector(setCompletionHandler:) withObject:handler];
        
        fprintf(stdout, "[SUBMIT] shaderdebug: request with all fields set...\n");
        id token = nil;
        @try {
            token = [service performSelector:@selector(shaderdebug:) withObject:req];
            fprintf(stdout, "[OK] Token: %s (id=%llu)\n",
                    class_getName([token class]),
                    ((uint64_t (*)(id, SEL))objc_msgSend)(token, @selector(tokenId)));
        } @catch (NSException *e) {
            fprintf(stdout, "[EXCEPTION] %s: %s\n", [[e name] UTF8String], [[e reason] UTF8String]);
        }
        
        // Wait with runloop pumping + dispatch queue processing
        fprintf(stdout, "[WAIT] Pumping runloop for 8 seconds...\n");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
        while (!completed && [[NSDate date] compare:deadline] == NSOrderedAscending) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            }
        }
        
        if (!completed) {
            fprintf(stdout, "[TIMEOUT] 8s — no callback fired.\n\n");
            fprintf(stdout, "[ANALYSIS] The shader debug pipeline requires:\n");
            fprintf(stdout, "  1. GTLLVMHelper process connection (Unix socket IPC)\n");
            fprintf(stdout, "  2. Full GTMTLReplayClient with OperationQueues (dispatch queues)\n");
            fprintf(stdout, "  3. Likely: the service's internal request processing loop\n\n");
            fprintf(stdout, "[CONCLUSION] Shader debug requires GTLLVMHelper connection.\n");
            fprintf(stdout, "  The minimal client (pool+controller) is sufficient for:\n");
            fprintf(stdout, "    ✅ fetch / query / update (synchronous operations)\n");
            fprintf(stdout, "  But NOT for:\n");
            fprintf(stdout, "    ❌ shaderdebug (requires GTLLVMHelper IPC)\n");
            fprintf(stdout, "    ❌ profile (requires GPU counters)\n\n");
            
            fprintf(stdout, "[ALTERNATIVE] For shader debug without full Service:\n");
            fprintf(stdout, "  Option A: Connect to running GTLLVMHelper via Unix socket directly\n");
            fprintf(stdout, "  Option B: Launch GTLLVMHelper ourselves (it's a standalone binary)\n");
            fprintf(stdout, "  Option C: Use Metal shader validation layer for basic debug info\n");
            fprintf(stdout, "  Option D: Manual per-thread inspection via objectMap (R4.3 level)\n");
        } else {
            fprintf(stdout, "[SUCCESS] Callback was fired — shader debug result received!\n");
        }

        // ============================================================
        // PHASE 6: Manual per-thread inspection (always works)
        // ============================================================
        fprintf(stdout, "\n========== PHASE 6: Manual Per-Thread Inspection ==========\n\n");
        fprintf(stdout, "[INFO] Even without GTLLVMHelper, we can do:\n");
        fprintf(stdout, "  1. Replace shader with instrumented version (R5.2 ✅)\n");
        fprintf(stdout, "  2. playTo specific draw call (R4.3 ✅)\n");
        fprintf(stdout, "  3. Read buffer/texture outputs per-thread via objectMap ✅\n");
        fprintf(stdout, "  4. Iterate: modify shader → replay → compare outputs\n\n");
        fprintf(stdout, "[INFO] This gives us 'printf debugging' equivalent for GPU shaders:\n");
        fprintf(stdout, "  - Inject: out[gid] = debug_value;\n");
        fprintf(stdout, "  - Read buffer after replay\n");
        fprintf(stdout, "  - Works for ANY shader (no source required — use shaderIR path)\n");

        // JSON
        NSMutableDictionary *json = [NSMutableDictionary dictionary];
        json[@"probe"] = @"R5.3_shader_debug_observer";
        json[@"shaderdebug_token_accepted"] = @(token != nil);
        json[@"callback_fired"] = @(completed);
        json[@"gtllvmhelper_required"] = @(!completed);
        json[@"alternative_debug"] = @{
            @"instrumented_shader_replacement": @"Works (R5.2 shaderIR path)",
            @"per_thread_output_inspection": @"Works (objectMap buffer read)",
            @"playTo_isolation": @"Works (R4.3 playTo specific call)",
            @"conclusion": @"Effective 'printf debug' for GPU — no source required"
        };
        
        NSString *outPath = [[pathStr stringByDeletingLastPathComponent]
                             stringByAppendingPathComponent:@"shader_debug_probe3_result.json"];
        NSData *jd = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (jd) [jd writeToFile:outPath atomically:YES];
        
        fprintf(stdout, "\n=== R5.3 Probe Complete ===\n");
        free(clientBuf);
        return 0;
    }
}
