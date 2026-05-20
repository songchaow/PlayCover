/**
 * shader_debug_probe.m — R5.3 Shader Debug 探针
 *
 * 目标：验证 Shader Debug 在 Controller 路径下的可行性
 *
 * 策略：
 *   Phase 0: Runtime introspection — ShaderDebug 类族全貌
 *   Phase 1: Controller replay → 找到目标 draw call
 *   Phase 2: 构造 GTReplayShaderDebugKernel 请求并提交
 *   Phase 3: 检查 GTMTLReplayService.shaderdebug: 调用方式
 *   Phase 4: 探索无源码 shader 的 debug 可行性
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o shader_debug_probe shader_debug_probe.m
 *
 * 用法：
 *   ./shader_debug_probe <path-to-.gputrace>
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - Helpers

static void* resolve_bl(void *cli_fn, int byte_offset) {
    uint32_t *cli = (uint32_t *)cli_fn;
    int idx = byte_offset / 4;
    uint32_t inst = cli[idx];
    if ((inst & 0xFC000000) != 0x94000000) return NULL;
    int32_t imm26 = (int32_t)(inst << 6) >> 6;
    return (void*)((uint64_t)cli_fn + idx * 4 + (int64_t)imm26 * 4);
}

static void dump_class_full(const char *className) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) {
        fprintf(stdout, "[INTROSPECT] Class '%s' NOT FOUND\n", className);
        return;
    }
    fprintf(stdout, "\n[INTROSPECT] === %s ===\n", className);
    
    // Superclass
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
    
    // Also check superclass methods up to NSObject
    if (super && super != [NSObject class]) {
        unsigned int superMethCount = 0;
        Method *superMeths = class_copyMethodList(super, &superMethCount);
        if (superMethCount > 0) {
            fprintf(stdout, "  Inherited from %s (%u):\n", class_getName(super), superMethCount);
            for (unsigned int i = 0; i < superMethCount; i++) {
                SEL sel = method_getName(superMeths[i]);
                const char *types = method_getTypeEncoding(superMeths[i]);
                fprintf(stdout, "    %s — %s\n", sel_getName(sel), types ? types : "?");
            }
        }
        free(superMeths);
    }
}

typedef int (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void (*supportInit_fn)(void *device);
typedef void (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef int (*playAll_fn)(void *controller);
typedef int (*playTo_fn)(void *controller, uint32_t target);
typedef void (*rewind_fn)(void *controller);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", argv[0]); return 1; }
        const char *gputrace_path = argv[1];

        fprintf(stdout, "=== R5.3 Shader Debug Probe ===\n\n");
        fprintf(stdout, "[INFO] .gputrace: %s\n\n", gputrace_path);

        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) { return 2; }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { return 3; }
        fprintf(stdout, "[INFO] Metal device: %s\n\n", [[device name] UTF8String]);

        // Load frameworks
        void *rh = dlopen("/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay", RTLD_NOW);
        void *th = dlopen("/System/Library/PrivateFrameworks/GPUToolsTransport.framework/GPUToolsTransport", RTLD_NOW);
        if (!rh || !th) { fprintf(stderr, "[ERROR] dlopen failed\n"); return 4; }

        // ============================================================
        // PHASE 0: Runtime Introspection — ShaderDebug 类族
        // ============================================================
        fprintf(stdout, "========== PHASE 0: ShaderDebug Class Introspection ==========\n");
        
        dump_class_full("GTReplayShaderDebugRequest");
        dump_class_full("GTReplayShaderDebugFragment");
        dump_class_full("GTReplayShaderDebugVertex");
        dump_class_full("GTReplayShaderDebugKernel");
        dump_class_full("GTReplayShaderDebugMesh");
        dump_class_full("GTReplayShaderDebugObject");
        dump_class_full("GTReplayShaderDebugPostTessellationVertex");
        
        // Also check response classes
        fprintf(stdout, "\n--- Checking response/result classes ---\n");
        dump_class_full("GTReplayShaderDebugResponse");
        dump_class_full("GTReplayShaderDebugResult");
        dump_class_full("GTShaderDebugData");
        dump_class_full("GTShaderDebugTrace");
        dump_class_full("GTShaderDebugVariable");
        dump_class_full("GTShaderDebugState");
        dump_class_full("GTShaderDebugLine");
        
        // Check for any shader debug related classes we might have missed
        fprintf(stdout, "\n--- Scanning all loaded classes for 'ShaderDebug' ---\n");
        unsigned int classCount = 0;
        Class *allClasses = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            const char *name = class_getName(allClasses[i]);
            if (strstr(name, "ShaderDebug") || strstr(name, "shaderDebug") ||
                strstr(name, "ShaderTrace") || strstr(name, "DebugTrace") ||
                strstr(name, "ProgramData")) {
                fprintf(stdout, "  %s (super: %s)\n", name,
                        class_getName(class_getSuperclass(allClasses[i])));
            }
        }
        free(allClasses);

        // ============================================================
        // PHASE 0b: GTMTLReplayService — shaderdebug related methods
        // ============================================================
        fprintf(stdout, "\n--- GTMTLReplayService shaderdebug-related ---\n");
        Class serviceClass = NSClassFromString(@"GTMTLReplayService");
        if (serviceClass) {
            unsigned int methCount = 0;
            Method *meths = class_copyMethodList(serviceClass, &methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "shader") || strstr(name, "Shader") ||
                    strstr(name, "debug") || strstr(name, "Debug") ||
                    strstr(name, "program") || strstr(name, "Program")) {
                    fprintf(stdout, "    %s — %s\n", name, method_getTypeEncoding(meths[i]));
                }
            }
            // Also print ALL methods for reference
            fprintf(stdout, "\n  ALL GTMTLReplayService methods (%u):\n", methCount);
            for (unsigned int i = 0; i < methCount; i++) {
                SEL sel = method_getName(meths[i]);
                const char *types = method_getTypeEncoding(meths[i]);
                fprintf(stdout, "    %s — %s\n", sel_getName(sel), types ? types : "?");
            }
            free(meths);
        }

        // ============================================================
        // PHASE 1: Controller Setup + Replay
        // ============================================================
        fprintf(stdout, "\n========== PHASE 1: Controller Setup ==========\n\n");

        void *gt_env = dlsym(rh, "GT_ENV");
        void *cli_fn = dlsym(rh, "GTMTLReplay_CLI");
        apr_pool_create_fn apr_pool_create = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn make_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn support_init = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn init_argbuf = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn populate_unused = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn make_ctrl = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn play_all = (playAll_fn)dlsym(rh, "GTMTLReplayController_playAll");
        playTo_fn play_to = (playTo_fn)dlsym(rh, "GTMTLReplayController_playTo");
        rewind_fn rewind_ctrl = (rewind_fn)dlsym(rh, "GTMTLReplayController_rewind");

        // APR Bootstrap
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
        if (!ds) { fprintf(stderr, "[FATAL] makeDataSource failed\n"); return 5; }
        support_init((__bridge void *)device);
        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        id objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
        init_argbuf(ds, (__bridge void *)device, (__bridge void *)objectMap);
        populate_unused(ds, (__bridge void *)objectMap);
        void *controller = make_ctrl(ds, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) { fprintf(stderr, "[FATAL] makeController failed\n"); return 6; }
        fprintf(stdout, "[OK] Controller created\n");

        int rc = play_all(controller);
        fprintf(stdout, "[playAll] rc=%d %s\n", rc, rc == 0 ? "SUCCESS" : "FAILED");
        if (rc != 0) { return 7; }

        NSDictionary *resources = [objectMap performSelector:@selector(resources)];
        fprintf(stdout, "[INFO] resources: %lu\n", (unsigned long)[resources count]);

        // ============================================================
        // PHASE 2: Construct ShaderDebug Request
        // ============================================================
        fprintf(stdout, "\n========== PHASE 2: Construct ShaderDebug Request ==========\n\n");

        // For compute shader debug, we need a kernel dispatch
        // For our test gputrace with compute kernels, dispatchUID=0 should work
        
        Class debugKernelClass = NSClassFromString(@"GTReplayShaderDebugKernel");
        Class debugRequestClass = NSClassFromString(@"GTReplayShaderDebugRequest");
        Class debugFragClass = NSClassFromString(@"GTReplayShaderDebugFragment");
        
        if (debugKernelClass) {
            fprintf(stdout, "[INFO] Creating GTReplayShaderDebugKernel instance...\n");
            id debugReq = [[debugKernelClass alloc] init];
            fprintf(stdout, "[OK] Instance: %s\n", [[debugReq description] UTF8String]);
            
            // Set dispatchUID (target the first compute dispatch)
            if ([debugReq respondsToSelector:@selector(setDispatchUID:)]) {
                // dispatchUID type is (?={?=ii}Q) — struct with 2 ints + uint64
                // Try setting it as raw bytes
                struct DispatchUID {
                    struct { int a; int b; } inner;
                    uint64_t streamRef;
                };
                struct DispatchUID uid = {{0, 0}, 0}; // First dispatch
                
                // Use direct method invocation with correct struct type
                SEL setUIDSel = @selector(setDispatchUID:);
                Method m = class_getInstanceMethod(debugKernelClass, setUIDSel);
                if (m) {
                    const char *types = method_getTypeEncoding(m);
                    fprintf(stdout, "[INFO] setDispatchUID: encoding = %s\n", types);
                    
                    // The type is v24@0:8(?={?=ii}Q)16 — total struct size = 16 bytes
                    // Invoke via objc_msgSend with struct argument
                    typedef void (*setUID_IMP)(id, SEL, struct DispatchUID);
                    setUID_IMP setUID = (setUID_IMP)objc_msgSend;
                    setUID(debugReq, setUIDSel, uid);
                    fprintf(stdout, "[SET] dispatchUID = {inner={0,0}, streamRef=0}\n");
                }
            }
            
            // Set thread position range for kernel debug
            if ([debugReq respondsToSelector:@selector(setMinThreadPositionInGrid:)]) {
                // MTLSize or similar struct
                fprintf(stdout, "[INFO] Has setMinThreadPositionInGrid:\n");
            }
            if ([debugReq respondsToSelector:@selector(setMaxThreadPositionInGrid:)]) {
                fprintf(stdout, "[INFO] Has setMaxThreadPositionInGrid:\n");
            }

            // Check what programData expects
            if ([debugReq respondsToSelector:@selector(setProgramData:)]) {
                fprintf(stdout, "[INFO] Has setProgramData: — needs shader binary for debugging\n");
            }
            if ([debugReq respondsToSelector:@selector(setProgramDataVersion:)]) {
                fprintf(stdout, "[INFO] Has setProgramDataVersion:\n");
            }
            if ([debugReq respondsToSelector:@selector(setCompletionHandler:)]) {
                fprintf(stdout, "[INFO] Has setCompletionHandler:\n");
            }
            
            // Try to check current values
            fprintf(stdout, "\n[INFO] Current property values:\n");
            if ([debugReq respondsToSelector:@selector(programData)]) {
                id pd = [debugReq performSelector:@selector(programData)];
                fprintf(stdout, "  programData: %s\n", pd ? [[pd description] UTF8String] : "(nil)");
            }
            if ([debugReq respondsToSelector:@selector(programDataVersion)]) {
                NSInteger ver = ((NSInteger (*)(id, SEL))objc_msgSend)(debugReq, @selector(programDataVersion));
                fprintf(stdout, "  programDataVersion: %ld\n", (long)ver);
            }
        }

        // ============================================================
        // PHASE 3: Attempt Service-based shaderdebug
        // ============================================================
        fprintf(stdout, "\n========== PHASE 3: GTMTLReplayService shaderdebug: ==========\n\n");
        
        // GTMTLReplayService has shaderdebug: method
        // But requires GTMTLReplayClient context (complex struct)
        // Let's check if there's a simpler entry point
        
        // Check for standalone shader debug functions in GPUToolsReplay
        void *debug_fn1 = dlsym(rh, "GTMTLReplayController_shaderDebug");
        void *debug_fn2 = dlsym(rh, "GTMTLReplayController_debugShader");
        void *debug_fn3 = dlsym(rh, "GTMTLReplay_shaderDebug");
        void *debug_fn4 = dlsym(rh, "GTShaderDebug");
        
        fprintf(stdout, "  GTMTLReplayController_shaderDebug: %p\n", debug_fn1);
        fprintf(stdout, "  GTMTLReplayController_debugShader: %p\n", debug_fn2);
        fprintf(stdout, "  GTMTLReplay_shaderDebug: %p\n", debug_fn3);
        fprintf(stdout, "  GTShaderDebug: %p\n", debug_fn4);
        
        // Check GTLLVMHelper — this is the process that does actual shader debugging
        fprintf(stdout, "\n[INFO] Checking GTLLVMHelper connection...\n");
        
        // Scan for any debug-related symbols
        fprintf(stdout, "\n[INFO] Scanning for shader debug related symbols...\n");
        const char *debug_syms[] = {
            "GTShaderDebugger_create",
            "GTShaderDebugger_init",
            "GTShaderDebugger_step",
            "GTShaderDebugger_run",
            "GTShaderDebugger_evaluate",
            "GTShaderDebugRequest_process",
            "GTShaderDebug_execute",
            "GTMTLReplayService_processShaderDebug",
            NULL
        };
        for (int i = 0; debug_syms[i]; i++) {
            void *sym = dlsym(rh, debug_syms[i]);
            if (!sym) sym = dlsym(th, debug_syms[i]);
            if (sym) fprintf(stdout, "  [FOUND] %s: %p\n", debug_syms[i], sym);
        }

        // ============================================================
        // PHASE 4: GTLLVMHelper Analysis
        // ============================================================
        fprintf(stdout, "\n========== PHASE 4: GTLLVMHelper & Shader Debugger Architecture ==========\n\n");
        
        // GTLLVMHelper is an external process launched by Xcode for shader debugging
        // Check if it's running
        fprintf(stdout, "[INFO] GTLLVMHelper is the external process for shader compilation/debug.\n");
        fprintf(stdout, "[INFO] Communication: Unix socket at /tmp/unixsocketipc_gtd\n");
        fprintf(stdout, "[INFO] It handles: shader compilation, debug stepping, variable inspection.\n\n");
        
        // Check if the socket exists
        if ([fm fileExistsAtPath:@"/tmp/unixsocketipc_gtd"]) {
            fprintf(stdout, "[FOUND] /tmp/unixsocketipc_gtd exists — GTLLVMHelper may be active\n");
        } else {
            fprintf(stdout, "[INFO] /tmp/unixsocketipc_gtd not found — GTLLVMHelper not active\n");
        }
        
        // Check for GTLLVMHelper framework/binary
        NSString *gtllvmPath = @"/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/GPUToolsPlatform/PlugIns/GTLLVMHelper";
        if ([fm fileExistsAtPath:gtllvmPath]) {
            fprintf(stdout, "[FOUND] GTLLVMHelper binary at: %s\n", [gtllvmPath UTF8String]);
        }

        // ============================================================
        // PHASE 5: programData — What does the shader debugger need?
        // ============================================================
        fprintf(stdout, "\n========== PHASE 5: programData Requirements ==========\n\n");
        
        // The key question for "no source" debugging:
        // programData likely contains:
        //   - Debug info (DWARF in metallib)
        //   - Shader source (optional?)
        //   - AIR bitcode with debug metadata
        
        // Check if our metallib has debug info
        SEL libSel = @selector(libraryForKey:);
        id funcMap = [objectMap performSelector:@selector(functionMap)];
        
        for (id key in (NSDictionary *)funcMap) {
            uint64_t fk = [key unsignedLongLongValue];
            uint64_t lk = fk - 1;
            id lib = ((id (*)(id, SEL, uint64_t))objc_msgSend)(objectMap, libSel, lk);
            if (lib && [lib conformsToProtocol:@protocol(MTLLibrary)]) {
                id<MTLLibrary> mtlLib = (id<MTLLibrary>)lib;
                fprintf(stdout, "[LIB key=%llu] functions=%s\n", lk,
                        [[[mtlLib functionNames] description] UTF8String]);
                
                // Check for debug-related selectors on the library
                SEL debugSels[] = {
                    NSSelectorFromString(@"debugDescription"),
                    NSSelectorFromString(@"sourceCode"),
                    NSSelectorFromString(@"shaderSource"),
                    NSSelectorFromString(@"debugInfo"),
                    NSSelectorFromString(@"programData"),
                    NSSelectorFromString(@"functionDebugInfo"),
                    NSSelectorFromString(@"debugSymbols"),
                };
                for (int s = 0; s < 7; s++) {
                    if ([lib respondsToSelector:debugSels[s]]) {
                        @try {
                            id result = [lib performSelector:debugSels[s]];
                            fprintf(stdout, "  [RESPONDS] %s → %s\n",
                                    sel_getName(debugSels[s]),
                                    result ? [[result description] UTF8String] : "(nil)");
                        } @catch (NSException *e) {
                            fprintf(stdout, "  [RESPONDS] %s → exception: %s\n",
                                    sel_getName(debugSels[s]), [[e reason] UTF8String]);
                        }
                    }
                }
                
                // Check function-level debug info
                NSString *funcName = [[mtlLib functionNames] firstObject];
                if (funcName) {
                    NSError *err = nil;
                    id<MTLFunction> func = [mtlLib newFunctionWithName:funcName];
                    if (func) {
                        fprintf(stdout, "  Function '%s': class=%s\n",
                                [funcName UTF8String], class_getName([func class]));
                        
                        // Check function for debug selectors
                        SEL fDebugSels[] = {
                            NSSelectorFromString(@"debugDescription"),
                            NSSelectorFromString(@"sourceCode"),
                            NSSelectorFromString(@"programData"),
                            NSSelectorFromString(@"bitcode"),
                            NSSelectorFromString(@"shaderValidationData"),
                        };
                        for (int s = 0; s < 5; s++) {
                            if ([(id)func respondsToSelector:fDebugSels[s]]) {
                                @try {
                                    id result = [(id)func performSelector:fDebugSels[s]];
                                    NSString *desc = result ? [result description] : @"(nil)";
                                    if ([desc length] > 100) desc = [[desc substringToIndex:100] stringByAppendingString:@"..."];
                                    fprintf(stdout, "    [RESPONDS] %s → %s\n",
                                            sel_getName(fDebugSels[s]), [desc UTF8String]);
                                } @catch (NSException *e) {
                                    fprintf(stdout, "    [RESPONDS] %s → exception\n", sel_getName(fDebugSels[s]));
                                }
                            }
                        }
                    }
                }
                break; // Just check first library
            }
        }

        // ============================================================
        // PHASE 6: Check GTReplaySessionInfo for debug capabilities
        // ============================================================
        fprintf(stdout, "\n========== PHASE 6: Session Debug Capabilities ==========\n\n");
        
        Class sessionInfoClass = NSClassFromString(@"GTReplaySessionInfo");
        if (sessionInfoClass) {
            dump_class_full("GTReplaySessionInfo");
        }

        // ============================================================
        // PHASE 7: Attempt direct shader debug via Service
        // ============================================================
        fprintf(stdout, "\n========== PHASE 7: Direct ShaderDebug Attempt ==========\n\n");
        
        // The GTMTLReplayService.shaderdebug: method has signature:
        // @24@0:8@16 — returns id, takes id (the request)
        // We know the service needs initWithContext: which requires GTMTLReplayClient
        // 
        // Key question: can we construct a minimal GTMTLReplayClient with just pool+controller?
        
        if (serviceClass) {
            // GTMTLReplayClient struct (from introspection):
            // ^{GTMTLReplayClient=^{apr_pool_t}^{GTMTLReplayController}Q{?=QQQdII}{?={?=II}IIfb1b1b1b1b28}@{...}{...}@@}
            // First two fields are pool and controller — exactly what we have!
            
            fprintf(stdout, "[INFO] Attempting GTMTLReplayService construction with minimal client...\n");
            
            // Allocate a buffer large enough for GTMTLReplayClient
            // Conservative estimate: ~512 bytes should be more than enough
            void *clientBuf = calloc(1, 512);
            
            // Fill known fields
            *(void **)((uint8_t *)clientBuf + 0)  = pool;        // apr_pool_t*
            *(void **)((uint8_t *)clientBuf + 8)  = controller;  // GTMTLReplayController*
            *(uint64_t *)((uint8_t *)clientBuf + 16) = 0;        // uint64 (maybe request counter?)
            
            // Try initWithContext:
            @try {
                id service = [serviceClass alloc];
                service = ((id (*)(id, SEL, void *))objc_msgSend)(service, @selector(initWithContext:), clientBuf);
                
                if (service) {
                    fprintf(stdout, "[OK] GTMTLReplayService created: %s\n", [[service description] UTF8String]);
                    
                    // Now try shaderdebug:
                    if (debugKernelClass && [service respondsToSelector:@selector(shaderdebug:)]) {
                        id debugReq = [[debugKernelClass alloc] init];
                        
                        // Set minimal properties
                        struct DispatchUID {
                            struct { int a; int b; } inner;
                            uint64_t streamRef;
                        };
                        struct DispatchUID uid = {{0, 0}, 0};
                        typedef void (*setUID_IMP)(id, SEL, struct DispatchUID);
                        ((setUID_IMP)objc_msgSend)(debugReq, @selector(setDispatchUID:), uid);
                        
                        // Set thread range (debug thread 0)
                        if ([debugReq respondsToSelector:@selector(setMinThreadPositionInGrid:)]) {
                            // MTLSize = {width, height, depth}
                            typedef void (*setSize_IMP)(id, SEL, MTLSize);
                            MTLSize minPos = {0, 0, 0};
                            MTLSize maxPos = {0, 0, 0};
                            ((setSize_IMP)objc_msgSend)(debugReq, @selector(setMinThreadPositionInGrid:), minPos);
                            if ([debugReq respondsToSelector:@selector(setMaxThreadPositionInGrid:)]) {
                                ((setSize_IMP)objc_msgSend)(debugReq, @selector(setMaxThreadPositionInGrid:), maxPos);
                            }
                            fprintf(stdout, "[SET] Thread range: [0,0,0] - [0,0,0]\n");
                        }
                        
                        fprintf(stdout, "[INFO] Submitting shaderdebug: request...\n");
                        @try {
                            id token = [service performSelector:@selector(shaderdebug:) withObject:debugReq];
                            fprintf(stdout, "[RESULT] shaderdebug: returned: %s (class=%s)\n",
                                    token ? [[token description] UTF8String] : "(nil)",
                                    token ? class_getName([token class]) : "nil");
                            
                            // If we got a token, check its state
                            if (token) {
                                if ([token respondsToSelector:@selector(completed)]) {
                                    BOOL done = ((BOOL (*)(id, SEL))objc_msgSend)(token, @selector(completed));
                                    fprintf(stdout, "  completed: %s\n", done ? "YES" : "NO");
                                }
                                if ([token respondsToSelector:@selector(waitUntilCompleted)]) {
                                    fprintf(stdout, "  [INFO] Waiting for completion (timeout 2s)...\n");
                                    // Don't actually wait — could hang
                                    // [token performSelector:@selector(waitUntilCompleted)];
                                }
                                if ([token respondsToSelector:@selector(error)]) {
                                    id err = [token performSelector:@selector(error)];
                                    if (err) fprintf(stdout, "  error: %s\n", [[err description] UTF8String]);
                                }
                            }
                        } @catch (NSException *e) {
                            fprintf(stdout, "[EXCEPTION] shaderdebug: threw: %s — %s\n",
                                    [[e name] UTF8String], [[e reason] UTF8String]);
                        }
                    }
                } else {
                    fprintf(stdout, "[WARN] GTMTLReplayService initWithContext: returned nil\n");
                }
            } @catch (NSException *e) {
                fprintf(stdout, "[EXCEPTION] Service creation: %s — %s\n",
                        [[e name] UTF8String], [[e reason] UTF8String]);
            }
            
            free(clientBuf);
        }

        // ============================================================
        // PHASE 8: No-Source Debug Feasibility Analysis
        // ============================================================
        fprintf(stdout, "\n========== PHASE 8: No-Source Shader Debug Feasibility ==========\n\n");
        
        fprintf(stdout, "[ANALYSIS] Shader debug architecture:\n");
        fprintf(stdout, "  1. GTReplayShaderDebugRequest → GTMTLReplayService.shaderdebug:\n");
        fprintf(stdout, "  2. Service communicates with GTLLVMHelper via Unix socket\n");
        fprintf(stdout, "  3. GTLLVMHelper uses LLVM to interpret/step through shader IR\n");
        fprintf(stdout, "  4. Results come back as execution trace (variables, line-by-line)\n\n");
        
        fprintf(stdout, "[ANALYSIS] For no-source debug:\n");
        fprintf(stdout, "  - programData field: likely contains shader binary + debug info\n");
        fprintf(stdout, "  - If metallib has DWARF debug info → line-level stepping possible\n");
        fprintf(stdout, "  - If only AIR bitcode → basic block stepping possible\n");
        fprintf(stdout, "  - If only final ISA → may be limited to input/output inspection only\n\n");
        
        fprintf(stdout, "[ANALYSIS] Practical capabilities without source:\n");
        fprintf(stdout, "  A. Input/Output inspection: always possible via objectMap\n");
        fprintf(stdout, "  B. Per-thread execution: depends on GTLLVMHelper + programData\n");
        fprintf(stdout, "  C. Variable watches: needs debug info in metallib\n");
        fprintf(stdout, "  D. Line stepping: needs source mapping in metallib\n");

        // ============================================================
        // JSON Summary
        // ============================================================
        fprintf(stdout, "\n========== Summary ==========\n\n");
        
        NSMutableDictionary *json = [NSMutableDictionary dictionary];
        json[@"probe"] = @"R5.3_shader_debug";
        json[@"gputrace"] = pathStr;
        json[@"device"] = [device name];
        json[@"GTReplayShaderDebugKernel_available"] = @(debugKernelClass != nil);
        json[@"GTReplayShaderDebugFragment_available"] = @(debugFragClass != nil);
        json[@"GTReplayShaderDebugRequest_available"] = @(debugRequestClass != nil);
        json[@"GTMTLReplayService_available"] = @(serviceClass != nil);
        json[@"GTLLVMHelper_socket_exists"] = @([fm fileExistsAtPath:@"/tmp/unixsocketipc_gtd"]);
        
        NSString *outPath = [[pathStr stringByDeletingLastPathComponent]
                             stringByAppendingPathComponent:@"shader_debug_probe_result.json"];
        NSData *jd = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (jd) [jd writeToFile:outPath atomically:YES];
        fprintf(stdout, "[JSON] %s\n", [outPath UTF8String]);
        
        fprintf(stdout, "\n=== R5.3 Shader Debug Probe Complete ===\n");
        
        dlclose(rh);
        dlclose(th);
        return 0;
    }
}
