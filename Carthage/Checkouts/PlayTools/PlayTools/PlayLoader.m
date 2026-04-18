//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

@import MachO;

// Get device model from playcover .plist
// With a null terminator
#define DEVICE_MODEL [[[PlaySettings shared] deviceModel] cStringUsingEncoding:NSUTF8StringEncoding]
#define OEM_ID [[[PlaySettings shared] oemID] cStringUsingEncoding:NSUTF8StringEncoding]
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[PlaySettings shared] playChain]) {
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, O_CREAT, mod);
    }

    return open(filename, oflag);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return stat(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    return access(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    return rename(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    return unlink(ue_fix_filename(path));
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int pt_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[PlaySettings shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);
        
        int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
        int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];
        
        if (time == 100000) {
            int timestamp = (int)[[NSDate date] timeIntervalSince1970];
            // If it sleeps too fast, increase counter
            if (timestamp - last_sleep_attempt < 2) {
                thread_sleep_counter++;
            } else {
                thread_sleep_counter = 1;
            }
            last_sleep_attempt = timestamp;
            thread_sleep_counters[threadKey] = @(thread_sleep_counter);
            last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            
        }
        
        if (thread_sleep_counter > 100) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

// ---------------------------------------------------------------------------
// HOK-013: Preheat `com.tencent.ngr` 的 `__DATA,__common` slot `0x10e2146f8`。
//
// 背景（见 LocalDocs/HOKCrash/00-Dashboard.md / HOK-013 子文档）：
//   - NGR 主 image 的 `__init_offsets[1563]` reader (`0x1047e83f4`) 直接从
//     `0x10e2146f8` 读对象指针后调用其虚函数（vtable offset `+0x10`），
//     没有 null check。
//   - HOK-011 离线证明：NGR 自身 init 链不可达 slot 的 writer，真正 prime
//     它的代码在 iOS 下一定来自外部 framework / ObjC `+load` / 跨 dylib
//     ctor。macOS 下这条外部路径缺失，于是 slot 保持 dyld 零填，reader
//     拿到 null、`ldr x8, [x19]` 触发 deref。
//   - HOK-012-C.3-b.3 live 已证实：abort 现场 `0x10e2146f8 = 0x0`、writer
//     bp hit=0、writer 在 LLDB 捕获窗口内从未被调用。
//
// 修复思路：不尝试调用 NGR 内部的 Logger accessor（这些函数的 calling
// convention 不是 "无参" 的——live 验证显示裸调 `0x107e5df10` 会因为
// x0/x1 残留任意值、继续走到 writer 函数内部虚调用、再在 `ldrh w9, [x0]`
// 上崩掉）。改走「最小 stub 对象 + 最小 stub vtable」方案：
//   1. PlayTools 内部预留一个 stub object（第 0 字节是 vtable 指针）；
//   2. 一个 8-slot 的 stub vtable，每个 slot 指向 `pt_ngr_stub_vfunc_noop`
//      （`mov x0, #0; ret`），保证 reader `ldr x8, [x8, #0x10]; blr x8`
//      链调用到任意 offset 都是安全 no-op；
//   3. PlayTools constructor 在 NGR 主 image 所有 `__init_offsets` 跑起来
//      之前，把 `0x10e2146f8` slot 直接写成 stub object 的地址。
//
// reader 原 faulting 指令 `ldr x8, [x19]` 读到 stub vtable、再
// `ldr x8, [x8, #0x10]` 读到 stub vfunc、`blr x8` no-op 返回；faulting
// window 被跨过，不再依赖 HOK-007B 的候选 E 磁盘 patch。reader 全二进制
// 扫描确认 `0x10e2146f8` 只有 **一个** reader（`0x1047e83f4`），stub
// 不会被其它代码消费，stub vtable 的大小（8 slots）是保守上限。
//
// 约束：
//   - Bundle-scoped：**仅对 `com.tencent.ngr` 生效**；其它 bundle 完全跳过。
//   - 只 touch 一次：`dispatch_once`。
//   - image 识别：遍历 `_dyld_image_count` / `_dyld_get_image_header(i)`
//     找 `MH_EXECUTE`（主 image），读取其 `__TEXT` segment 的 vmaddr 决定
//     slide 计算基准；若 unslid `__TEXT.vmaddr` 与离线分析锁定值不一致
//     （NGR 被重链接），直接放弃 preheat 让候选 E 兜住。
//   - 失败时 no-op：任何一步不成功就静默放行。
//   - 写诊断事件到 `RuntimeLaunchDiagnostics`（Swift 侧）以便 live 核验。
// ---------------------------------------------------------------------------

// NGR 主二进制的 **unslid vmaddr**（即 Mach-O header 里 __TEXT.vmaddr =
// 0x100000000 基准下的绝对地址）：
//   - NGRSLOT_PREHEAT_SLOT_ADDR:   0x10e2146f8，目标 __DATA,__common 槽位。
//   - NGRSLOT_PREHEAT_TEXT_VMADDR: 0x100000000，unslid __TEXT.vmaddr；
//     slide = (uintptr_t)mh - this constant。
//   - NGRSLOT_PREHEAT_BUNDLE_ID:   "com.tencent.ngr"。
#define NGRSLOT_PREHEAT_SLOT_ADDR        0x10e2146f8ULL
#define NGRSLOT_PREHEAT_TEXT_VMADDR      0x100000000ULL
#define NGRSLOT_PREHEAT_BUNDLE_ID        "com.tencent.ngr"

// Stub vfunc：`mov x0, #0; ret`。作为 stub vtable 的所有 slot 目标。
// reader 的虚调用 `blr x8`（传 x0=this）命中此函数后立即返回 0，不修改
// 任何状态。`used` 防 LTO 清理；`naked` 防止 Clang 产生 prologue。
__attribute__((used, naked))
static void pt_ngr_stub_vfunc_noop(void) {
    __asm__ volatile (
        "mov x0, #0\n"
        "ret\n"
    );
}

// Stub vtable：8 个 slot 覆盖保守上限（reader 静态只消费 `+0x10` 一个
// slot；多余 slot 防御未来 symbol 变化）。
static void * const pt_ngr_stub_vtable[8] = {
    (void *)pt_ngr_stub_vfunc_noop, // +0x00
    (void *)pt_ngr_stub_vfunc_noop, // +0x08
    (void *)pt_ngr_stub_vfunc_noop, // +0x10 ← reader 实际消费点
    (void *)pt_ngr_stub_vfunc_noop, // +0x18
    (void *)pt_ngr_stub_vfunc_noop, // +0x20
    (void *)pt_ngr_stub_vfunc_noop, // +0x28
    (void *)pt_ngr_stub_vfunc_noop, // +0x30
    (void *)pt_ngr_stub_vfunc_noop, // +0x38
};

// Stub object：第 0 字节是 vtable 指针，reader 的 `ldr x8, [x19]` 读到
// 的就是 `pt_ngr_stub_vtable` 地址。后面的 padding 保证对象本身有合法
// 存储（reader 之外若有代码用 offset 访问也不会落到野内存）。
static struct {
    void *vtable;
    uint8_t padding[56];
} pt_ngr_stub_object __attribute__((used, aligned(16))) = {
    .vtable = (void *)pt_ngr_stub_vtable,
    .padding = {0},
};

// 解析 main executable 的 mach_header_64 与 __TEXT vmaddr。返回 YES 时
// `*outHeader` 指向主 image 的 mach_header_64、`*outTextVMAddr` 写入
// __TEXT 段的 unslid vmaddr（Mach-O 里记录的原始 vmaddr，不含 slide）。
static BOOL pt_ngr_find_main_image(const struct mach_header_64 **outHeader,
                                   uint64_t *outTextVMAddr) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh == NULL) { continue; }
        if (mh->magic != MH_MAGIC_64 && mh->magic != MH_CIGAM_64) { continue; }
        if (mh->filetype != MH_EXECUTE) { continue; }

        const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
        const uint8_t *cmdPtr = (const uint8_t *)mh64 + sizeof(struct mach_header_64);
        BOOL found = NO;
        uint64_t textVMAddr = 0;
        for (uint32_t c = 0; c < mh64->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmdPtr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
                if (strncmp(sc->segname, "__TEXT", sizeof(sc->segname)) == 0) {
                    textVMAddr = sc->vmaddr;
                    found = YES;
                    break;
                }
            }
            cmdPtr += lc->cmdsize;
        }
        if (!found) { continue; }

        if (outHeader) { *outHeader = mh64; }
        if (outTextVMAddr) { *outTextVMAddr = textVMAddr; }
        return YES;
    }
    return NO;
}

// Bundle-scoped gate：只有 `CFBundleGetMainBundle()` 的 bundle identifier
// 精确匹配 NGRSLOT_PREHEAT_BUNDLE_ID 时才返回 YES。使用 CFBundle 而不是
// Foundation 层是为了避免在 constructor 窗口里先触发 Swift runtime init。
static BOOL pt_ngr_should_preheat_slot(void) {
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    if (mainBundle == NULL) { return NO; }
    CFStringRef bid = CFBundleGetIdentifier(mainBundle);
    if (bid == NULL) { return NO; }
    char buf[128] = {0};
    if (!CFStringGetCString(bid, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        return NO;
    }
    return strcmp(buf, NGRSLOT_PREHEAT_BUNDLE_ID) == 0;
}

// 记录 HOK-013 的 preheat 诊断事件。NSLog + 走 Swift entry point
// `PlayCover.recordHOK013PreheatDiagnosticWithDetails:` 落到
// `launch-events.jsonl`。
static void pt_ngr_log_preheat_event(const char *phase,
                                     const char *status,
                                     uint64_t stubObjectAddr,
                                     uint64_t slotAddr,
                                     uint64_t slotValueBefore,
                                     uint64_t slotValueAfter,
                                     uint64_t slide) {
    NSLog(@"[PlayTools] HOK-013 preheat: phase=%s status=%s "
          @"stubObject=0x%llx slotAddr=0x%llx "
          @"slotBefore=0x%llx slotAfter=0x%llx slide=0x%llx",
          phase ?: "", status ?: "", stubObjectAddr, slotAddr,
          slotValueBefore, slotValueAfter, slide);
    NSDictionary<NSString *, NSString *> *details = @{
        @"phase": phase ? [NSString stringWithUTF8String:phase] : @"",
        @"status": status ? [NSString stringWithUTF8String:status] : @"",
        @"stubObject": [NSString stringWithFormat:@"0x%llx", stubObjectAddr],
        @"slotAddr": [NSString stringWithFormat:@"0x%llx", slotAddr],
        @"slotBefore": [NSString stringWithFormat:@"0x%llx", slotValueBefore],
        @"slotAfter": [NSString stringWithFormat:@"0x%llx", slotValueAfter],
        @"slide": [NSString stringWithFormat:@"0x%llx", slide],
    };
    [PlayCover recordHOK013PreheatDiagnosticWithDetails:details];
}

// 唯一的 preheat 触发点。**必须在 NGR 主 image 的 `__init_offsets` 跑起来
// 之前**完成：PlayTools 的 constructor 由 dyld 在所有依赖 dylib 的
// initializer 阶段调用，早于主 image 的 init_offsets，因此这里的窗口
// 是安全的。
static void pt_ngr_preheat_slot_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!pt_ngr_should_preheat_slot()) {
            // 非目标 bundle，完全跳过；不写事件、不改状态。
            return;
        }

        const struct mach_header_64 *mh = NULL;
        uint64_t unslidTextVMAddr = 0;
        if (!pt_ngr_find_main_image(&mh, &unslidTextVMAddr)) {
            pt_ngr_log_preheat_event("locate", "main-image-not-found",
                                     (uint64_t)(uintptr_t)&pt_ngr_stub_object,
                                     NGRSLOT_PREHEAT_SLOT_ADDR,
                                     0, 0, 0);
            return;
        }

        uint64_t slide = (uint64_t)(uintptr_t)mh - unslidTextVMAddr;
        if (unslidTextVMAddr != NGRSLOT_PREHEAT_TEXT_VMADDR) {
            // NGR 重链接后 __TEXT.vmaddr 可能变化；不同基准会算出错误的
            // runtime 地址，直接放弃 preheat。
            pt_ngr_log_preheat_event("locate", "unexpected-text-vmaddr",
                                     (uint64_t)(uintptr_t)&pt_ngr_stub_object,
                                     NGRSLOT_PREHEAT_SLOT_ADDR,
                                     0, 0, slide);
            return;
        }

        uintptr_t slotRuntimeAddr = (uintptr_t)(NGRSLOT_PREHEAT_SLOT_ADDR + slide);
        void *slotPtr = (void *)slotRuntimeAddr;

        uint64_t slotValueBefore = 0;
        memcpy(&slotValueBefore, slotPtr, sizeof(slotValueBefore));
        if (slotValueBefore != 0) {
            // 已经被其它代码 prime 过了。什么都不用做。
            pt_ngr_log_preheat_event("probe", "already-primed",
                                     (uint64_t)(uintptr_t)&pt_ngr_stub_object,
                                     slotRuntimeAddr,
                                     slotValueBefore, slotValueBefore, slide);
            return;
        }

        // 把 stub object 地址直接写进 slot。reader 读到 stub.vtable、
        // 再读 vtable[2]（offset 0x10）、blr 到 no-op vfunc 安全返回。
        uint64_t stubAddr = (uint64_t)(uintptr_t)&pt_ngr_stub_object;
        memcpy(slotPtr, &stubAddr, sizeof(stubAddr));

        uint64_t slotValueAfter = 0;
        memcpy(&slotValueAfter, slotPtr, sizeof(slotValueAfter));
        const char *status = (slotValueAfter == stubAddr) ? "primed"
                                                          : "write-verify-failed";
        pt_ngr_log_preheat_event("write", status,
                                 stubAddr,
                                 slotRuntimeAddr,
                                 0, slotValueAfter, slide);
    });
}
// ---------------------------------------------------------------------------

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    // HOK-013: 最早时机预热 `com.tencent.ngr` 的 `__common` slot
    // `0x10e2146f8`。`pt_ngr_preheat_slot_once()` 内含 bundle-scoped
    // gate，非目标 bundle 会直接 return，不影响其它 app。
    pt_ngr_preheat_slot_once();

    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
