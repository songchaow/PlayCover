/**
 * replay_probe.m — R3.1 最小 ObjC 探针
 *
 * 目标：dlopen GPUToolsReplay.framework，dlsym GTMTLReplay_CLI，
 *       用已有 .gputrace 样本做实际 headless replay 调用。
 *
 * 编译：
 *   clang -framework Foundation -framework Metal -ldl -o replay_probe replay_probe.m
 *
 * 用法：
 *   ./replay_probe /path/to/capture.gputrace
 *
 * 发现记录（R3.1）：
 *   - GPUToolsReplay 内部静态链接了 APR (Apache Portable Runtime) 库
 *   - GTMTLReplay_CLI 第一步调用 apr_pool_create_ex，需要全局 allocator 已初始化
 *   - 正常调用路径：GPUToolsReplayService.xpc main() → apr_initialize() → GTMTLReplay_CLI()
 *   - 由于 apr_initialize 是非导出符号，本探针通过已知导出符号偏移定位并手动初始化
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

// GTMTLReplay_CLI 函数指针类型
typedef void (*GTMTLReplay_CLI_Callback)(NSData *data, NSURL *url);

typedef int (*GTMTLReplay_CLI_fn)(
    const char *captureArchivePath,
    void *options,   // GTMTLReplayCLIOptions* (~0xC0 bytes)
    GTMTLReplay_CLI_Callback completionCallback
);

/**
 * 手动 bootstrap GPUToolsReplay 内部的 APR 全局状态。
 *
 * 原理：GPUToolsReplay 的 apr_pool_create_ex 内部读取一个全局变量作为 "parent pool"。
 * 当此全局变量为 NULL 时，所有 pool 创建都会崩溃。
 * 
 * 通过逆向分析确认：
 *   - 全局变量位于导出符号 GT_ENV 地址 - 0x30 处
 *   - 该变量是 "global pool" 指针（非 allocator 指针）
 *   - apr_pool_create_ex 从 global_pool[0x30] 读取 allocator 指针
 *   - allocator_alloc(allocator, size) 使用 allocator[0x00] 作为 max_index,
 *     allocator[0x28..] 作为 free list 数组
 *
 * Bootstrap 策略（模拟 apr_initialize）：
 *   1. 通过 vm_allocate 分配一个大内存块（2 pages = 0x2000）
 *   2. 在块内构造 allocator 结构 + memnode + global pool
 *   3. 设置 global pool[0x30] = allocator
 *   4. 写入全局变量
 *
 * 注意：此偏移量基于 macOS 26.4.1 / GPUToolsReplay 314.12 验证。
 */
static int init_apr_for_replay(void *handle) {
    // 1. 通过导出符号 GT_ENV 定位全局 pool 指针位置
    void *gt_env = dlsym(handle, "GT_ENV");
    if (!gt_env) {
        fprintf(stderr, "[APR-INIT] Failed to find GT_ENV symbol\n");
        return -1;
    }
    fprintf(stdout, "[APR-INIT] GT_ENV at: %p\n", gt_env);
    
    // 全局 pool 指针位于 GT_ENV - 0x30
    void **global_pool_ptr = (void **)((uint8_t *)gt_env - 0x30);
    fprintf(stdout, "[APR-INIT] Global pool pointer at: %p\n", (void*)global_pool_ptr);
    fprintf(stdout, "[APR-INIT] Current value: %p\n", *global_pool_ptr);
    
    if (*global_pool_ptr != NULL) {
        fprintf(stdout, "[APR-INIT] Already initialized, skipping\n");
        return 0;
    }
    
    // 2. 分配大块内存用于 bootstrap（allocator + memnode + pool）
    // APR allocator 内部使用 2-page (0x2000) 块，memnode header 0x28 bytes
    // 我们在一块连续内存中布局：
    //   [0x000 .. 0x0C7]: allocator struct (0xC8 bytes)
    //   [0x100 .. 0x17F]: fake global pool struct (0x80 bytes)
    size_t block_size = 0x200;  // 足够放 allocator + pool
    void *block = calloc(1, block_size);
    if (!block) {
        fprintf(stderr, "[APR-INIT] Failed to allocate bootstrap block\n");
        return -2;
    }
    
    void *allocator = block;  // allocator 从 block 开头开始
    void *global_pool = (uint8_t *)block + 0x100;  // pool 在 +0x100
    
    // 3. 设置 allocator 字段
    // allocator[0x00] = max_index (allocator_alloc 用它判断 free list 大小)
    *(uint64_t *)((uint8_t *)allocator + 0x00) = 20;
    // allocator[0x08] = max_free_index (用于 +360 处 store 后的上限比较)
    *(uint64_t *)((uint8_t *)allocator + 0x08) = 20;
    // allocator[0x10] = current_free_index
    *(uint64_t *)((uint8_t *)allocator + 0x10) = 0;
    // allocator[0x18] = mutex (NULL = no locking)
    *(void **)((uint8_t *)allocator + 0x18) = NULL;
    // allocator[0x28..0xC7] = free list (all NULL, no pre-allocated blocks)
    // Already zeroed by calloc
    
    // 4. 设置 global pool 字段
    // pool[0x00] = allocator pointer (用于 apr_pool_create_ex +124: stp x21, xzr, [x22])
    *(void **)((uint8_t *)global_pool + 0x00) = allocator;
    // pool[0x08] = next sibling (NULL)
    // pool[0x10] = child list head (NULL initially)
    // pool[0x18] = parent back-link (NULL for root)
    // pool[0x30] = allocator pointer (读取点: apr_pool_create_ex +64)
    *(void **)((uint8_t *)global_pool + 0x30) = allocator;
    // pool[0x40] = abort_fn (NULL)
    
    // 5. 写入全局 pool 指针
    *global_pool_ptr = global_pool;
    
    fprintf(stdout, "[APR-INIT] Bootstrap block at: %p\n", block);
    fprintf(stdout, "[APR-INIT] Allocator at: %p\n", allocator);
    fprintf(stdout, "[APR-INIT] Global pool at: %p\n", global_pool);
    fprintf(stdout, "[APR-INIT] *global_pool_ptr = %p\n", *global_pool_ptr);
    fprintf(stdout, "[APR-INIT] pool[0x30] (allocator ref) = %p\n", *(void **)((uint8_t *)global_pool + 0x30));
    
    return 0;
}

// completionCallback — C function pointer
static void replay_completion(NSData *data, NSURL *url) {
    fprintf(stdout, "[CALLBACK] called!\n");
    fprintf(stdout, "[CALLBACK] NSData: %s, length: %lu\n",
            data ? "non-nil" : "nil",
            (unsigned long)(data ? [data length] : 0));
    if (url) {
        fprintf(stdout, "[CALLBACK] NSURL: %s\n", [[url absoluteString] UTF8String]);
    } else {
        fprintf(stdout, "[CALLBACK] NSURL: (nil)\n");
    }
    if (data && [data length] > 0) {
        NSUInteger printLen = [data length] < 128 ? [data length] : 128;
        const uint8_t *bytes = (const uint8_t *)[data bytes];
        fprintf(stdout, "[CALLBACK] First %lu bytes (hex): ", (unsigned long)printLen);
        for (NSUInteger i = 0; i < printLen; i++) {
            fprintf(stdout, "%02x", bytes[i]);
        }
        fprintf(stdout, "\n");
    }
}

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", prog);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            print_usage(argv[0]);
            return 1;
        }

        const char *gputrace_path = argv[1];

        // --- 验证 .gputrace 路径存在 ---
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithUTF8String:gputrace_path];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "[ERROR] .gputrace path does not exist or is not a directory: %s\n", gputrace_path);
            return 2;
        }
        fprintf(stdout, "[INFO] .gputrace path: %s\n", gputrace_path);

        // --- 验证 Metal 设备可用 ---
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[ERROR] MTLCreateSystemDefaultDevice() returned nil — no Metal device available\n");
            return 3;
        }
        fprintf(stdout, "[INFO] Metal device: %s\n", [[device name] UTF8String]);

        // --- dlopen GPUToolsReplay.framework ---
        const char *fw_path = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
        void *handle = dlopen(fw_path, RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "[ERROR] dlopen GPUToolsReplay failed: %s\n", dlerror());
            return 4;
        }
        fprintf(stdout, "[INFO] dlopen GPUToolsReplay success\n");

        // --- 初始化 APR (必须在 GTMTLReplay_CLI 之前) ---
        int apr_rc = init_apr_for_replay(handle);
        if (apr_rc != 0) {
            fprintf(stderr, "[ERROR] APR initialization failed: %d\n", apr_rc);
            dlclose(handle);
            return 6;
        }

        // --- dlsym GTMTLReplay_CLI ---
        GTMTLReplay_CLI_fn cli_fn = (GTMTLReplay_CLI_fn)dlsym(handle, "GTMTLReplay_CLI");
        if (!cli_fn) {
            fprintf(stderr, "[ERROR] dlsym GTMTLReplay_CLI failed: %s\n", dlerror());
            dlclose(handle);
            return 5;
        }
        fprintf(stdout, "[INFO] dlsym GTMTLReplay_CLI success: %p\n", (void*)cli_fn);

        // --- 创建临时输出目录 ---
        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.gputools.profiling"];
        [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
        fprintf(stdout, "[INFO] Profiling temp dir: %s\n", [tmpDir UTF8String]);

        // --- 准备 options 结构体 ---
        // ~0xC0 字节，清零 + loopCount=1 + 填入字符串字段以避免 NULL cString 崩溃
        char options[0xC0];
        memset(options, 0, sizeof(options));
        *(int32_t *)(options + 0x18) = 1;  // loopCount = 1
        *(uint8_t *)(options + 0x25) = 1;  // waitForCompletion = 1 (R3.3: 确保 finish→rewind 完成)

        // R3.2: 修复 NULL 字符串字段
        // +0x28: errorLogPath (推测) — 填入 /dev/null 防止 NSString stringWithUTF8String: NULL
        const char *errorLogPath = "/dev/null";
        *(const char **)(options + 0x28) = errorLogPath;
        // +0x30: saveDestination — 日志中确认为 "options.saveDestination=%s"
        const char *saveDestination = "/tmp/replay_output";
        *(const char **)(options + 0x30) = saveDestination;

        // R3.3: gpuStateLevel 和 profilingFlags
        // +0xa4: gpuStateLevel — bit31=禁用; 正值时 clamp≥2, 作为 @"GPUState" 值
        //        设置为 2 以触发 DerivedCounters 收集 → completionCallback
        *(int32_t *)(options + 0xa4) = 2;  // gpuStateLevel = 2
        // +0xb8: profilingFlags 位域 — bit6=ATF_RESULTSDIRECTORY override
        //        设置 bit6 以启用结果目录输出
        *(uint32_t *)(options + 0xb8) = (1 << 6);  // profilingFlags = 0x40

        // 创建 saveDestination 目录（清空旧内容）
        NSString *saveDest = @"/tmp/replay_output";
        [fm removeItemAtPath:saveDest error:nil];
        [fm createDirectoryAtPath:saveDest withIntermediateDirectories:YES attributes:nil error:nil];

        // 设置环境变量 ATF_RESULTSDIRECTORY（与 profilingFlags bit6 配合）
        setenv("ATF_RESULTSDIRECTORY", "/tmp/replay_output", 1);

        fprintf(stdout, "[INFO] Options fields set:\n");
        fprintf(stdout, "  +0x18 loopCount       = 1\n");
        fprintf(stdout, "  +0x25 waitForComplete = 1\n");
        fprintf(stdout, "  +0x28 errorLogPath    = %s\n", errorLogPath);
        fprintf(stdout, "  +0x30 saveDest        = %s\n", saveDestination);
        fprintf(stdout, "  +0xa4 gpuStateLevel   = 2\n");
        fprintf(stdout, "  +0xb8 profilingFlags  = 0x%x\n", *(uint32_t *)(options + 0xb8));

        // --- 执行 GTMTLReplay_CLI (with @try/@catch) ---
        fprintf(stdout, "\n[INFO] Calling GTMTLReplay_CLI(\"%s\", options, callback)...\n", gputrace_path);
        fprintf(stdout, "[INFO] Options: loopCount=1, size=0x%lx\n", sizeof(options));
        fflush(stdout);
        fflush(stderr);

        int result = -999;
        @try {
            result = cli_fn(gputrace_path, options, replay_completion);
        } @catch (NSException *exception) {
            fprintf(stderr, "\n[EXCEPTION] %s: %s\n",
                    [[exception name] UTF8String],
                    [[exception reason] UTF8String]);
            NSArray *symbols = [exception callStackSymbols];
            if (symbols) {
                fprintf(stderr, "[EXCEPTION] Call stack:\n");
                for (NSString *sym in symbols) {
                    fprintf(stderr, "  %s\n", [sym UTF8String]);
                }
            }
            // 如果仍然是 NULL cString 问题，尝试逐步试探其他偏移
            if ([[exception reason] containsString:@"NULL cString"]) {
                fprintf(stderr, "\n[R3.2-DIAG] Still hitting NULL cString after setting +0x28 and +0x30.\n");
                fprintf(stderr, "[R3.2-DIAG] Next step: try additional offsets (+0x38, +0x40, etc.)\n");
            }
        }

        fprintf(stdout, "\n[RESULT] GTMTLReplay_CLI returned: %d\n", result);

        // R3.3: callback 可能在 async dispatch queue 上执行
        // 等待一段时间让 async 操作完成
        fprintf(stdout, "[R3.3] Waiting 5 seconds for async callback...\n");
        fflush(stdout);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.0]];

        if (result == 0) {
            fprintf(stdout, "[SUCCESS] Headless replay completed successfully!\n");
        } else {
            fprintf(stderr, "[FAILURE] Replay returned non-zero: %d\n", result);
            fprintf(stderr, "[HINT] Possible causes:\n");
            fprintf(stderr, "  - Invalid .gputrace bundle structure\n");
            fprintf(stderr, "  - Metal device mismatch (trace captured on different GPU)\n");
            fprintf(stderr, "  - SIP restrictions preventing framework access\n");
            fprintf(stderr, "  - Missing entitlements\n");
            fprintf(stderr, "  - APR allocator struct incomplete\n");
        }

        // R3.3: 检查 saveDestination 目录产物
        fprintf(stdout, "\n[R3.3-CHECK] Checking /tmp/replay_output for output files...\n");
        NSError *listErr = nil;
        NSArray *outputFiles = [fm contentsOfDirectoryAtPath:saveDest error:&listErr];
        if (listErr) {
            fprintf(stderr, "[R3.3-CHECK] Error listing dir: %s\n", [[listErr localizedDescription] UTF8String]);
        } else if ([outputFiles count] == 0) {
            fprintf(stdout, "[R3.3-CHECK] Directory is empty — no profiling output produced.\n");
        } else {
            fprintf(stdout, "[R3.3-CHECK] Found %lu file(s):\n", (unsigned long)[outputFiles count]);
            for (NSString *f in outputFiles) {
                NSString *fullPath = [saveDest stringByAppendingPathComponent:f];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                unsigned long long sz = [attrs fileSize];
                fprintf(stdout, "  %s (%llu bytes)\n", [f UTF8String], sz);
            }
        }

        // 也检查 /tmp/com.apple.gputools.profiling
        NSString *profilingDir = @"/var/folders";  // 已知缓存可能在 var/folders
        NSString *gpuToolsProf = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.gputools.profiling"];
        NSArray *profFiles = [fm contentsOfDirectoryAtPath:gpuToolsProf error:nil];
        if (profFiles && [profFiles count] > 0) {
            fprintf(stdout, "[R3.3-CHECK] Profiling temp dir (%s) has %lu file(s):\n",
                    [gpuToolsProf UTF8String], (unsigned long)[profFiles count]);
            for (NSString *f in profFiles) {
                NSString *fullPath = [gpuToolsProf stringByAppendingPathComponent:f];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                unsigned long long sz = [attrs fileSize];
                fprintf(stdout, "  %s (%llu bytes)\n", [f UTF8String], sz);
            }
        }

        dlclose(handle);
        return result;
    }
}
