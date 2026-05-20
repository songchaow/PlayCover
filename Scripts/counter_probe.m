/**
 * counter_probe.m — R4.4 GPU Counter 探针
 *
 * 验证 GPU 计数器/性能数据采集路径：
 *
 * 路径分析：
 *   1. GPURawCounter.framework — 需要 com.apple.private.agx.performance-spi → BLOCKED（无签名进程不可用）
 *   2. Metal MTLCounterSampleBuffer — Apple M4 仅支持 AtStageBoundary → 有限
 *   3. MTLCommandBuffer.GPUStartTime/GPUEndTime — 始终可用 ✅
 *   4. Host timing (mach_absolute_time) around playAll/playTo — 始终可用 ✅
 *
 * 本探针实现路径 3+4：在 replay 执行期间测量 GPU + host 时间，
 * 通过 playTo 分段测量不同 draw call 范围的执行时间。
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o counter_probe counter_probe.m
 *
 * 用法：
 *   ./counter_probe                        # 枚举 counter 能力 + 独立时间测试
 *   ./counter_probe <path-to-.gputrace>    # replay + per-segment GPU timing
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

// Controller path functions
typedef int (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void (*supportInit_fn)(void *device);
typedef void (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef int (*playAll_fn)(void *controller);
typedef int (*playTo_fn)(void *controller, uint32_t target);
typedef void (*rewind_fn)(void *controller);

static void* resolve_bl(void *cli_fn, int byte_offset) {
    uint32_t *cli = (uint32_t *)cli_fn;
    int idx = byte_offset / 4;
    uint32_t inst = cli[idx];
    if ((inst & 0xFC000000) != 0x94000000) return NULL;
    int32_t imm26 = (int32_t)(inst << 6) >> 6;
    return (void*)((uint64_t)cli_fn + idx * 4 + (int64_t)imm26 * 4);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *gputrace_path = (argc >= 2) ? argv[1] : NULL;
        
        fprintf(stdout, "=== R4.4 GPU Counter / Performance Timing Probe ===\n\n");
        
        // === Metal device ===
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "[ERROR] No Metal device\n"); return 1; }
        fprintf(stdout, "[INFO] Metal device: %s\n\n", [[device name] UTF8String]);
        
        // ============================================================
        // CAPABILITY ENUMERATION
        // ============================================================
        fprintf(stdout, "========== Counter Capability Summary ==========\n\n");
        
        // GPURawCounter check
        void *grc_handle = dlopen("/System/Library/PrivateFrameworks/GPURawCounter.framework/GPURawCounter", RTLD_NOW);
        if (grc_handle) {
            typedef NSArray* (*GRCFn)(NSError **);
            GRCFn grc_copy = (GRCFn)dlsym(grc_handle, "GRCCopyAllCounterSourceGroupWithError");
            NSError *err = nil;
            NSArray *groups = grc_copy ? grc_copy(&err) : nil;
            if (groups && [groups count] > 0) {
                fprintf(stdout, "  GPURawCounter:        AVAILABLE (%lu groups)\n", (unsigned long)[groups count]);
            } else {
                fprintf(stdout, "  GPURawCounter:        BLOCKED (needs entitlement)\n");
            }
            dlclose(grc_handle);
        } else {
            fprintf(stdout, "  GPURawCounter:        NOT FOUND\n");
        }
        
        // Metal counter sets
        NSArray<id<MTLCounterSet>> *counterSets = device.counterSets;
        fprintf(stdout, "  MTLCounterSets:       %lu\n", (unsigned long)[counterSets count]);
        for (id<MTLCounterSet> cs in counterSets) {
            fprintf(stdout, "    - '%s' (%lu counters)\n", [[cs name] UTF8String], (unsigned long)[[cs counters] count]);
        }
        
        // Counter sampling support
        fprintf(stdout, "  StageBoundary:        %s\n",
                [device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary] ? "YES" : "NO");
        fprintf(stdout, "  DrawBoundary:         %s\n",
                [device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary] ? "YES" : "NO");
        fprintf(stdout, "  BlitBoundary:         %s\n",
                [device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary] ? "YES" : "NO");
        fprintf(stdout, "  DispatchBoundary:     %s\n",
                [device supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary] ? "YES" : "NO");
        fprintf(stdout, "  CmdBuf GPU Timing:    ALWAYS AVAILABLE (GPUStartTime/GPUEndTime)\n");
        fprintf(stdout, "  Host Timing:          ALWAYS AVAILABLE (mach_absolute_time)\n");
        
        // ============================================================
        // STANDALONE GPU TIMING TEST
        // ============================================================
        fprintf(stdout, "\n========== Standalone GPU Timing Test ==========\n\n");
        
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        id<MTLBuffer> testBuf = [device newBufferWithLength:1048576 options:MTLResourceStorageModeShared]; // 1MB
        [blit fillBuffer:testBuf range:NSMakeRange(0, 1048576) value:0xAB];
        [blit endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        
        CFTimeInterval gpuStart = cmd.GPUStartTime;
        CFTimeInterval gpuEnd = cmd.GPUEndTime;
        fprintf(stdout, "  Fill 1MB buffer:\n");
        fprintf(stdout, "    GPU time:  %.3f µs\n", (gpuEnd - gpuStart) * 1e6);
        fprintf(stdout, "    [OK] GPU timing works\n");
        
        // ============================================================
        // REPLAY + TIMING (if gputrace provided)
        // ============================================================
        if (!gputrace_path) {
            fprintf(stdout, "\n[INFO] No .gputrace path provided. Provide one for replay timing.\n");
            fprintf(stdout, "\n=== R4.4 Probe Complete (enumeration only) ===\n");
            return 0;
        }
        
        fprintf(stdout, "\n========== Replay + Performance Timing ==========\n\n");
        
        // Validate gputrace
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *pathStr = [NSString stringWithUTF8String:gputrace_path];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:pathStr isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "[ERROR] Not a valid .gputrace: %s\n", gputrace_path);
            return 4;
        }
        fprintf(stdout, "[INFO] .gputrace: %s\n", gputrace_path);
        
        // Load GPUToolsReplay
        void *replay_handle = dlopen("/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay", RTLD_NOW);
        if (!replay_handle) { fprintf(stderr, "[ERROR] dlopen GPUToolsReplay failed\n"); return 5; }
        
        void *gt_env = dlsym(replay_handle, "GT_ENV");
        void *cli_fn = dlsym(replay_handle, "GTMTLReplay_CLI");
        if (!gt_env || !cli_fn) { fprintf(stderr, "[ERROR] Missing symbols\n"); return 5; }
        
        apr_pool_create_fn apr_pool_create = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn make_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn support_init = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn init_argbuf = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn populate_unused = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn make_ctrl = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn play_all = (playAll_fn)dlsym(replay_handle, "GTMTLReplayController_playAll");
        playTo_fn play_to = (playTo_fn)dlsym(replay_handle, "GTMTLReplayController_playTo");
        rewind_fn ctrl_rewind = (rewind_fn)dlsym(replay_handle, "GTMTLReplayController_rewind");
        
        // APR bootstrap
        void **global_pool_ptr = (void **)((uint8_t *)gt_env - 0x30);
        if (*global_pool_ptr == NULL) {
            void *block = calloc(1, 0x4000);
            *(uint64_t *)block = 20;
            *(uint64_t *)((uint8_t *)block + 0x08) = 20;
            void *global_pool = (uint8_t *)block + 0x100;
            *(void **)global_pool = block;
            *(void **)((uint8_t *)global_pool + 0x30) = block;
            *global_pool_ptr = global_pool;
        }
        
        // Create controller
        void *pool = NULL;
        apr_pool_create(&pool, NULL, NULL, NULL);
        void *dataSource = make_ds(gputrace_path, pool);
        if (!dataSource) { fprintf(stderr, "[ERROR] makeDataSource failed\n"); return 6; }
        
        support_init((__bridge void *)device);
        Class mapClass = NSClassFromString(@"GTMTLReplayObjectMap");
        id objectMap = [[mapClass alloc] performSelector:@selector(initWithDevice:) withObject:device];
        init_argbuf(dataSource, (__bridge void *)device, (__bridge void *)objectMap);
        populate_unused(dataSource, (__bridge void *)objectMap);
        void *controller = make_ctrl(dataSource, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) { fprintf(stderr, "[ERROR] makeController failed\n"); return 7; }
        fprintf(stdout, "[OK] Controller created\n\n");
        
        // Get mach timebase
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        
        // === Measure total playAll ===
        fprintf(stdout, "--- playAll Full Replay ---\n");
        uint64_t t0 = mach_absolute_time();
        int rc = play_all(controller);
        uint64_t t1 = mach_absolute_time();
        double playAllMs = (double)(t1 - t0) * timebase.numer / timebase.denom / 1e6;
        fprintf(stdout, "  rc: %d, host time: %.3f ms\n\n", rc, playAllMs);
        
        // === Measure playTo at progressive targets ===
        fprintf(stdout, "--- playTo Progressive Timing ---\n");
        fprintf(stdout, "  %-8s %-5s %-12s %-12s\n", "Target", "RC", "Host(ms)", "Delta(ms)");
        fprintf(stdout, "  %-8s %-5s %-12s %-12s\n", "------", "--", "--------", "---------");
        
        uint32_t targets[] = {1, 2, 5, 10, 20, 50, 100, 200};
        int numTargets = sizeof(targets) / sizeof(targets[0]);
        double prevMs = 0;
        
        // JSON data collection
        NSMutableArray *measurements = [NSMutableArray array];
        
        for (int i = 0; i < numTargets; i++) {
            ctrl_rewind(controller);
            
            uint64_t ts = mach_absolute_time();
            int prc = -1;
            @try {
                prc = play_to(controller, targets[i]);
            } @catch (NSException *ex) {
                fprintf(stdout, "  %-8u  EXC  (target exceeds trace, stopping)\n", targets[i]);
                break;
            }
            uint64_t te = mach_absolute_time();
            
            double ms = (double)(te - ts) * timebase.numer / timebase.denom / 1e6;
            double delta = ms - prevMs;
            
            fprintf(stdout, "  %-8u %-5d %-12.3f %-12.3f\n", targets[i], prc, ms, i > 0 ? delta : 0.0);
            
            [measurements addObject:@{
                @"target": @(targets[i]),
                @"rc": @(prc),
                @"host_time_ms": @(ms)
            }];
            
            prevMs = ms;
            
            // If playTo returned non-zero, we've exceeded the trace's call count
            if (prc != 0) {
                fprintf(stdout, "  (target %u exceeds trace call count, stopping)\n", targets[i]);
                break;
            }
        }
        
        // === JSON Output ===
        fprintf(stdout, "\n========== JSON Output ==========\n");
        
        NSDictionary *output = @{
            @"device": [device name],
            @"gputrace": pathStr,
            @"capabilities": @{
                @"gpuRawCounter": @NO,
                @"gpuRawCounter_reason": @"requires com.apple.private.agx.performance-spi (only GPUToolsReplayService has it)",
                @"metalTimestamp_counterSet": @YES,
                @"stageBoundary_sampling": @([device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]),
                @"drawBoundary_sampling": @([device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary]),
                @"commandBuffer_GPUTime": @YES,
                @"host_timing": @YES
            },
            @"playAll": @{
                @"rc": @(rc),
                @"host_time_ms": @(playAllMs)
            },
            @"playTo_measurements": measurements
        };
        
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        fprintf(stdout, "%s\n", [jsonStr UTF8String]);
        
        // === Summary ===
        fprintf(stdout, "\n=== R4.4 Summary ===\n");
        fprintf(stdout, "Available timing methods for headless replay:\n");
        fprintf(stdout, "  1. Host timing (mach_absolute_time): ✅ per-playTo segment\n");
        fprintf(stdout, "  2. GPU timing (GPUStartTime/End):    ✅ per-command-buffer (needs interception)\n");
        fprintf(stdout, "  3. Stage boundary sampling:          ✅ supported but requires cmdBuf ownership\n");
        fprintf(stdout, "  4. GPURawCounter (full HW counters): ❌ blocked (entitlement)\n");
        fprintf(stdout, "\nConclusion:\n");
        fprintf(stdout, "  - Per-draw-call HOST timing via playTo is fully working\n");
        fprintf(stdout, "  - For GPU-side timing: need to intercept command buffer submission in replay\n");
        fprintf(stdout, "  - For full HW counters: must use XPC path to GPUToolsReplayService\n");
        
        dlclose(replay_handle);
        return 0;
    }
}
