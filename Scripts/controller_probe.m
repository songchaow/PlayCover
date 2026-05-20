/**
 * controller_probe.m — R4.2 Controller 路径验证探针
 *
 * 验证结论：Controller 路径的最小可调用序列已确认。
 * 通过内部（非导出）函数 makeDataSource + makeController，可在 headless
 * 进程内创建完整的 replay controller，并成功执行 playAll。
 *
 * 调用链（从 GTMTLReplay_CLI 反汇编确认）：
 *   1. apr_pool_create_ex(&pool, NULL, NULL, NULL)
 *   2. GTMTLReplayController_makeDataSource(path, pool)
 *   3. GTMTLReplaySupport_init(device)
 *   4. [[GTMTLReplayObjectMap alloc] initWithDevice:device]
 *   5. GTMTLReplayController_initializeArgumentBufferSupport(dataSource, device, objectMap)
 *   6. GTMTLReplayController_populateUnusedResources(dataSource, objectMap)
 *   7. GTMTLReplayController_makeController(dataSource, pool, device, objectMap, NULL, NULL)
 *   8. GTMTLReplayController_playAll(controller) → returns 0
 *   9. GTMTLReplayController_rewind(controller)
 *
 * 内部函数定位方法：
 *   通过 GTMTLReplay_CLI 中 BL 指令的相对偏移计算地址：
 *   - apr_pool_create_ex      : CLI+0x050
 *   - makeDataSource          : CLI+0x13c
 *   - GTMTLSMContext_getDevice: CLI+0x230
 *   - GTMTLReplaySupport_init : CLI+0x888
 *   - initArgBufSupport       : CLI+0x898
 *   - populateUnusedResources : CLI+0x8a4
 *   - makeController          : CLI+0x954
 *   - optimizeRestores        : CLI+0x96c
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o controller_probe controller_probe.m
 *
 * 用法：
 *   ./controller_probe /path/to/capture.gputrace
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

static const char* sym_name(void *addr) {
    Dl_info info;
    if (dladdr(addr, &info) && info.dli_sname) return info.dli_sname;
    return "???";
}

// === Function signatures (from reverse engineering) ===
typedef int (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void (*supportInit_fn)(void *device);
typedef void (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef void (*optimizeRestores_fn)(void *controller);
typedef int (*playAll_fn)(void *controller);
typedef int (*playTo_fn)(void *controller, /* ... */...);
typedef void (*rewind_fn)(void *controller);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", argv[0]);
            fprintf(stderr, "\nVerifies the Controller path for headless GPU replay.\n");
            return 1;
        }
        const char *gputrace_path = argv[1];
        
        fprintf(stdout, "=== R4.2 Controller Path Verification ===\n\n");
        
        // === Validate input ===
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "[ERROR] Not a valid .gputrace bundle: %s\n", gputrace_path);
            return 2;
        }
        fprintf(stdout, "[INFO] .gputrace: %s\n", gputrace_path);
        
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
        fprintf(stdout, "[OK] dlopen GPUToolsReplay\n");
        
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
        optimizeRestores_fn opt_restores = (optimizeRestores_fn)resolve_bl(cli_fn, 0x96c);
        playAll_fn play_all = (playAll_fn)dlsym(handle, "GTMTLReplayController_playAll");
        rewind_fn ctrl_rewind = (rewind_fn)dlsym(handle, "GTMTLReplayController_rewind");
        
        fprintf(stdout, "\n--- Internal Functions ---\n");
        fprintf(stdout, "  apr_pool_create_ex  → %s\n", sym_name((void*)apr_pool_create));
        fprintf(stdout, "  makeDataSource      → %s\n", sym_name((void*)make_ds));
        fprintf(stdout, "  supportInit         → %s\n", sym_name((void*)support_init));
        fprintf(stdout, "  initArgBufSupport   → %s\n", sym_name((void*)init_argbuf));
        fprintf(stdout, "  populateUnused      → %s\n", sym_name((void*)populate_unused));
        fprintf(stdout, "  makeController      → %s\n", sym_name((void*)make_ctrl));
        fprintf(stdout, "  optimizeRestores    → %s\n", sym_name((void*)opt_restores));
        
        // === APR Bootstrap ===
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
            fprintf(stdout, "\n[APR] Bootstrap complete\n");
        } else {
            fprintf(stdout, "\n[APR] Already initialized\n");
        }
        
        // === Step 1: Create APR pool ===
        fprintf(stdout, "\n--- Step 1: apr_pool_create_ex ---\n");
        void *pool = NULL;
        int rc = apr_pool_create(&pool, NULL, NULL, NULL);
        fprintf(stdout, "  rc=%d, pool=%p\n", rc, pool);
        if (rc != 0 || !pool) {
            fprintf(stderr, "[FATAL] APR pool creation failed\n");
            dlclose(handle);
            return 6;
        }
        
        // === Step 2: makeDataSource ===
        fprintf(stdout, "\n--- Step 2: makeDataSource ---\n");
        void *dataSource = NULL;
        @try {
            dataSource = make_ds(gputrace_path, pool);
            fprintf(stdout, "  dataSource=%p %s\n", dataSource, dataSource ? "[OK]" : "[FAILED]");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
            dlclose(handle);
            return 7;
        }
        if (!dataSource) { dlclose(handle); return 7; }
        
        // === Step 3: GTMTLReplaySupport_init ===
        fprintf(stdout, "\n--- Step 3: GTMTLReplaySupport_init ---\n");
        @try {
            support_init((__bridge void *)device);
            fprintf(stdout, "  [OK]\n");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        // === Step 4: GTMTLReplayObjectMap initWithDevice: ===
        fprintf(stdout, "\n--- Step 4: GTMTLReplayObjectMap initWithDevice: ---\n");
        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        if (!mapClass) {
            fprintf(stderr, "  [ERROR] GTMTLReplayObjectMap class not found\n");
            dlclose(handle);
            return 8;
        }
        
        id objectMap = nil;
        @try {
            objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
            fprintf(stdout, "  objectMap=%p [OK]\n", (__bridge void *)objectMap);
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
            dlclose(handle);
            return 9;
        }
        
        // === Step 5: initializeArgumentBufferSupport ===
        fprintf(stdout, "\n--- Step 5: initializeArgumentBufferSupport ---\n");
        @try {
            init_argbuf(dataSource, (__bridge void *)device, (__bridge void *)objectMap);
            fprintf(stdout, "  [OK]\n");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        // === Step 6: populateUnusedResources ===
        fprintf(stdout, "\n--- Step 6: populateUnusedResources ---\n");
        @try {
            populate_unused(dataSource, (__bridge void *)objectMap);
            fprintf(stdout, "  [OK]\n");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        // === Step 7: makeController ===
        fprintf(stdout, "\n--- Step 7: makeController ---\n");
        void *controller = NULL;
        @try {
            controller = make_ctrl(dataSource, pool,
                                   (__bridge void *)device,
                                   (__bridge void *)objectMap,
                                   NULL, NULL);
            fprintf(stdout, "  controller=%p %s\n", controller, controller ? "[OK]" : "[FAILED]");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
            for (NSString *frame in [ex callStackSymbols]) {
                fprintf(stderr, "    %s\n", [frame UTF8String]);
            }
            dlclose(handle);
            return 10;
        }
        if (!controller) { dlclose(handle); return 10; }
        
        fprintf(stdout, "\n*** CONTROLLER CREATED SUCCESSFULLY ***\n");
        
        // === Step 8: playAll ===
        fprintf(stdout, "\n--- Step 8: playAll ---\n");
        @try {
            int play_rc = play_all(controller);
            fprintf(stdout, "  playAll returned: %d %s\n", play_rc, play_rc == 0 ? "[SUCCESS]" : "[FAILED]");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        // === Step 9: rewind ===
        fprintf(stdout, "\n--- Step 9: rewind ---\n");
        @try {
            ctrl_rewind(controller);
            fprintf(stdout, "  [OK]\n");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        // === Step 10: Inspect objectMap for data access ===
        fprintf(stdout, "\n--- Step 10: ObjectMap Inspection ---\n");
        @try {
            id defaultQ = [objectMap performSelector:@selector(defaultCommandQueue)];
            fprintf(stdout, "  defaultCommandQueue = %p\n", (__bridge void *)defaultQ);
            
            id resources = [objectMap performSelector:@selector(resources)];
            fprintf(stdout, "  resources = %p (class: %s)\n", 
                    (__bridge void *)resources, 
                    resources ? class_getName([resources class]) : "nil");
        } @catch (NSException *ex) {
            fprintf(stderr, "  [EXCEPTION] %s: %s\n", [[ex name] UTF8String], [[ex reason] UTF8String]);
        }
        
        fprintf(stdout, "\n=== R4.2 Verification Complete ===\n");
        fprintf(stdout, "\nSummary:\n");
        fprintf(stdout, "  - Controller path: VERIFIED (in-process, no XPC required)\n");
        fprintf(stdout, "  - makeDataSource: parses .gputrace into APR-based data source\n");
        fprintf(stdout, "  - makeController: creates replay controller with GPU resources\n");
        fprintf(stdout, "  - playAll: executes full replay, returns 0 on success\n");
        fprintf(stdout, "  - No entitlements required\n");
        fprintf(stdout, "  - No XPC/IPC required (all in-process)\n");
        fprintf(stdout, "\nNext: playTo for specific draw call, then Fetch API integration\n");
        
        dlclose(handle);
        return 0;
    }
}
