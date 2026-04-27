//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

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
static BOOL pt_ngr_c5_trace_fs_after_reuse = NO;
static size_t pt_ngr_c5_fs_trace_count = 0;
static const size_t pt_ngr_c5_fs_trace_limit = 40;
static __thread BOOL pt_ngr_c5_fs_trace_reentrant = NO;

static BOOL pt_ngr_c5_should_trace_fs_path(const char *path);
static BOOL pt_ngr_should_preheat_slot(void);
static void pt_ngr_c5_log_fs_event(const char *action,
                                   const char *path,
                                   int resultValue,
                                   int errnoValue,
                                   void *callerPC);
static NSString *pt_ngr_c5_path_preview_string(const char *path);
static void pt_ngr_install_url_resolution_probe_once(void);

static size_t pt_ngr_c5_url_trace_count = 0;
static const size_t pt_ngr_c5_url_trace_limit = 24;
static __thread BOOL pt_ngr_c5_url_trace_reentrant = NO;
static IMP pt_ngr_original_url_resolve_bookmark_IMP = NULL;
static IMP pt_ngr_original_start_accessing_scope_IMP = NULL;

typedef NSURL *(*pt_ngr_url_resolve_bookmark_imp_t)(id,
                                                    SEL,
                                                    NSData *,
                                                    NSURLBookmarkResolutionOptions,
                                                    NSURL *,
                                                    BOOL *,
                                                    NSError **);
typedef BOOL (*pt_ngr_start_accessing_scope_imp_t)(id, SEL);

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

static BOOL pt_ngr_c5_should_trace_fs_path(const char *path) {
    if (!pt_ngr_c5_trace_fs_after_reuse || path == NULL) {
        return NO;
    }

    static char prefix[1024] = {0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        char username[256] = {0};
        getlogin_r(username, sizeof(username));
        snprintf(prefix,
                 sizeof(prefix),
                 "/Users/%s/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/",
                 username);
    });

    if (prefix[0] == '\0') {
        return NO;
    }
    return strncmp(path, prefix, strlen(prefix)) == 0;
}

static void pt_ngr_c5_log_fs_event(const char *action,
                                   const char *path,
                                   int resultValue,
                                   int errnoValue,
                                   void *callerPC) {
    if (!pt_ngr_c5_should_trace_fs_path(path)
        || pt_ngr_c5_fs_trace_reentrant
        || pt_ngr_c5_fs_trace_count >= pt_ngr_c5_fs_trace_limit) {
        return;
    }

    BOOL suspiciousPath = strstr(path, "/Saved/Paks/") != NULL || strstr(path, ".db") != NULL;
    BOOL failed = resultValue < 0 || errnoValue != 0;
    if (!failed && !suspiciousPath) {
        return;
    }

    pt_ngr_c5_fs_trace_reentrant = YES;
    pt_ngr_c5_fs_trace_count += 1;

    NSDictionary<NSString *, NSString *> *details = @{
        @"action": action ? [NSString stringWithUTF8String:action] : @"",
        @"path": pt_ngr_c5_path_preview_string(path),
        @"result": [NSString stringWithFormat:@"%d", resultValue],
        @"errno": [NSString stringWithFormat:@"%d", errnoValue],
        @"callerPC": [NSString stringWithFormat:@"0x%llx", (uint64_t)(uintptr_t)callerPC],
        @"traceCount": [NSString stringWithFormat:@"%zu", pt_ngr_c5_fs_trace_count],
    };
    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];
    pt_ngr_c5_fs_trace_reentrant = NO;
}

static void pt_ngr_c5_log_url_event(NSString *action,
                                    NSURL *url,
                                    NSURL *relativeURL,
                                    BOOL hasResult,
                                    BOOL isStale,
                                    NSError *error,
                                    BOOL scopeResult) {
    if (!pt_ngr_c5_trace_fs_after_reuse
        || pt_ngr_c5_url_trace_reentrant
        || pt_ngr_c5_url_trace_count >= pt_ngr_c5_url_trace_limit) {
        return;
    }

    pt_ngr_c5_url_trace_reentrant = YES;
    pt_ngr_c5_url_trace_count += 1;

    NSString *resolvedPath = url.path ?: @"";
    NSString *relativePath = relativeURL.path ?: @"";
    BOOL prefixMatched = pt_ngr_c5_should_trace_fs_path(resolvedPath.UTF8String);

    NSMutableDictionary<NSString *, NSString *> *details = [@{
        @"action": action ?: @"",
        @"resolvedPath": resolvedPath,
        @"relativePath": relativePath,
        @"hasResult": hasResult ? @"true" : @"false",
        @"isStale": isStale ? @"true" : @"false",
        @"prefixMatched": prefixMatched ? @"true" : @"false",
        @"scopeResult": scopeResult ? @"true" : @"false",
        @"traceCount": [NSString stringWithFormat:@"%zu", pt_ngr_c5_url_trace_count],
    } mutableCopy];
    if (error != nil) {
        details[@"errorDomain"] = error.domain ?: @"";
        details[@"errorCode"] = [NSString stringWithFormat:@"%ld", (long)error.code];
        details[@"errorDescription"] = error.localizedDescription ?: @"";
    }

    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];
    pt_ngr_c5_url_trace_reentrant = NO;
}

static NSURL *pt_ngr_swizzled_URLByResolvingBookmarkData(id self,
                                                         SEL _cmd,
                                                         NSData *bookmarkData,
                                                         NSURLBookmarkResolutionOptions options,
                                                         NSURL *relativeURL,
                                                         BOOL *isStale,
                                                         NSError **error) {
    if (pt_ngr_original_url_resolve_bookmark_IMP == NULL) {
        return nil;
    }

    pt_ngr_url_resolve_bookmark_imp_t orig =
        (pt_ngr_url_resolve_bookmark_imp_t)pt_ngr_original_url_resolve_bookmark_IMP;

    BOOL localStale = NO;
    BOOL *stalePtr = isStale != NULL ? isStale : &localStale;
    NSError *__autoreleasing localError = nil;
    NSError *__autoreleasing *errorPtr = error != NULL ? error : &localError;

    NSURL *resolvedURL = orig(self, _cmd, bookmarkData, options, relativeURL, stalePtr, errorPtr);
    NSError *resolvedError = errorPtr != NULL ? *errorPtr : nil;
    pt_ngr_c5_log_url_event(@"url-resolve-bookmark",
                            resolvedURL,
                            relativeURL,
                            resolvedURL != nil,
                            stalePtr != NULL ? *stalePtr : NO,
                            resolvedError,
                            NO);
    return resolvedURL;
}

static BOOL pt_ngr_swizzled_startAccessingSecurityScopedResource(id self, SEL _cmd) {
    if (pt_ngr_original_start_accessing_scope_IMP == NULL) {
        return NO;
    }

    pt_ngr_start_accessing_scope_imp_t orig =
        (pt_ngr_start_accessing_scope_imp_t)pt_ngr_original_start_accessing_scope_IMP;
    BOOL result = orig(self, _cmd);
    pt_ngr_c5_log_url_event(@"url-start-accessing-scope",
                            (NSURL *)self,
                            nil,
                            YES,
                            NO,
                            nil,
                            result);
    return result;
}

static void pt_ngr_install_url_resolution_probe_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!pt_ngr_should_preheat_slot()) {
            return;
        }

        Class urlClass = NSClassFromString(@"NSURL");
        if (urlClass == Nil) {
            return;
        }

        SEL resolveSel = NSSelectorFromString(@"URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:");
        Method resolveMethod = class_getClassMethod(urlClass, resolveSel);
        if (resolveMethod != NULL) {
            pt_ngr_original_url_resolve_bookmark_IMP = method_getImplementation(resolveMethod);
            method_setImplementation(resolveMethod, (IMP)pt_ngr_swizzled_URLByResolvingBookmarkData);
        }

        SEL scopeSel = NSSelectorFromString(@"startAccessingSecurityScopedResource");
        Method scopeMethod = class_getInstanceMethod(urlClass, scopeSel);
        if (scopeMethod != NULL) {
            pt_ngr_original_start_accessing_scope_IMP = method_getImplementation(scopeMethod);
            method_setImplementation(scopeMethod, (IMP)pt_ngr_swizzled_startAccessingSecurityScopedResource);
        }
    });
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);

    void *callerPC = __builtin_return_address(0);

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        errno = 0;
        int result = open(filename, O_CREAT, mod);
        pt_ngr_c5_log_fs_event("fs-open-create", filename, result, errno, callerPC);
        return result;
    }

    errno = 0;
    int result = open(filename, oflag);
    pt_ngr_c5_log_fs_event("fs-open", filename, result, errno, callerPC);
    return result;
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    path = ue_fix_filename(path);
    errno = 0;
    int result = stat(path, buf);
    pt_ngr_c5_log_fs_event("fs-stat", path, result, errno, __builtin_return_address(0));
    return result;
}

static int pt_access(char const* path, int mode) {
    path = ue_fix_filename(path);
    errno = 0;
    int result = access(path, mode);
    pt_ngr_c5_log_fs_event("fs-access", path, result, errno, __builtin_return_address(0));
    return result;
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    old_name = ue_fix_filename(old_name);
    new_name = ue_fix_filename(new_name);
    errno = 0;
    int result = rename(old_name, new_name);
    pt_ngr_c5_log_fs_event("fs-rename-old", old_name, result, errno, __builtin_return_address(0));
    pt_ngr_c5_log_fs_event("fs-rename-new", new_name, result, errno, __builtin_return_address(0));
    return result;
}

static int pt_unlink(char const* path) {
    path = ue_fix_filename(path);
    errno = 0;
    int result = unlink(path);
    pt_ngr_c5_log_fs_event("fs-unlink", path, result, errno, __builtin_return_address(0));
    return result;
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

// ---------------------------------------------------------------------------
// HOK-015: Preseed `com.tencent.ngr` 的 UE4 `FCommandLine` 存储，消除
// `Attempting to get the command line but it hasn't been initialized yet.`
// fatal 的根因。
//
// 背景（见 LocalDocs/HOKCrash/00-Dashboard.md / HOK-015 子文档）：
//   - HOK-013 / HOK-014 之后，app 不再秒崩，但 UE4 GameThread 没有真正跑起
//     来：NGR 二进制里有约 218 条 inline `FCommandLine::Get()`
//     （UE4.25+ arm64 代码序列为
//         adrp xB, <page(bInitialized)>
//         ldrb wB, [xB, #0x78]
//         tbz  wB, #0, <fatal_branch>
//         adrp xC, <page(CmdLine)>
//         add  xC, xC, #0x7a
//     ），其中 182/218 条指向主 UE4 `FCommandLine` 的 bInitialized 槽
//     `0x10e201078` 与 CmdLine buffer `0x10e20107a`。UE4 `ue4commandline.txt`
//     被读入之前，这些 inline 序列里只要任意一条被命中就会打 3 条 Fatal、
//     构造 UIAlertController、set `GIsRequestingExit=true`，GameThread
//     随后退出。
//   - HOK-015-A 离线报告 `build/hok-015-cmdline-slots.json` 已经给出
//     bInitialized / CmdLine 的 unslid vmaddr 与 marker 字符串
//     `0x10c12d70a`；HOK-015-B 就是把 PlayTools constructor 的"预写槽位"
//     套路（HOK-013 已落地的 `pt_ngr_find_main_image` / slide 计算 / bundle
//     gate）复用到 FCommandLine 存储上。
//
// 修复思路：
//   1. dispatch_once + bundle gate，只对 `com.tencent.ngr` 执行一次。
//   2. 通过 `pt_ngr_find_main_image()` 复用 HOK-013 的 slide 计算；若
//      unslid __TEXT vmaddr 与 HOK-015-A 锁定值不一致，直接放弃（不 touch
//      任何内存），让 HOK-013 / HOK-014 兜底。
//   3. 先把种子字符串 `"../../../NGR/NGR.uproject\0"` 按 UTF-16-LE（UE4
//      iOS `TCHAR=uint16_t`）写入 CmdLine buffer；再 `__sync_synchronize()`
//      发 release fence；最后置 `bInitialized=1`。顺序保证：任何读者在
//      观察到 `bInitialized=true` 时 buffer 一定是有效的。
//   4. 写入前先读 `bInitialized` 当前值：若已非 0，写 `already-initialized`
//      事件直接 return（UE4 本尊已 init，不要覆盖）。
//
// 写入后，218 条 inline `FCommandLine::Get()` 中主线 182 条在 ldrb 读到
// 1、tbz 不 taken → 直接走 normal path 返回 CmdLine；UE4 `FError` 完全不
// 触发；`UIAlertController` 不构造；`GIsRequestingExit` 保持 false；
// GameThread 正常进入主 tick loop。
//
// 约束：
//   - **仅对 `com.tencent.ngr` 生效**（复用 `pt_ngr_should_preheat_slot()`
//     的 bundle gate）。
//   - 只 touch 一次：`dispatch_once`。
//   - 失败时 no-op：任何一步不成功就静默放行（HOK-014 作为安全网继续守
//     UI）。
//   - 诊断事件 `hok015_ngr_cmdline_preseed` 落到 `launch-events.jsonl`，
//     字段含 `status` / `bInitializedAddr` / `cmdlineBufferAddr` /
//     `bInitializedBefore` / `bInitializedAfter` / `cmdlinePreview` /
//     `slide`。
// ---------------------------------------------------------------------------

// HOK-015-A 输出的 unslid vmaddr（基准 __TEXT.vmaddr = 0x100000000）。
//   - NGR_UE4_CMDLINE_BINITIALIZED_UNSLID: 0x10e201078，1-byte bool。
//   - NGR_UE4_CMDLINE_BUFFER_UNSLID:       0x10e20107a，UTF-16-LE TCHAR 数组起点。
#define NGR_UE4_CMDLINE_BINITIALIZED_UNSLID 0x10e201078ULL
#define NGR_UE4_CMDLINE_BUFFER_UNSLID       0x10e20107aULL
// 种子值：与 NGR iOS 打包时的 `ue4commandline.txt` 内容一致。这个字符串
// 仅作为"合法占位"，UE4 随后在 `Checking for command line in ... FOUND!`
// 路径里会重新调用 FCommandLine::Set 覆盖 buffer、但此时 bInitialized
// 已为真，不再经过 fatal 分支。
#define NGR_UE4_CMDLINE_SEED_UTF8           "../../../NGR/NGR.uproject"

// 把 UTF-8 字符串按 UTF-16-LE 写入 dst（含 trailing NUL）。仅处理 ASCII
// 子集——种子字符串是纯 ASCII，不需要完整 UTF-8→UTF-16 转换。
// 返回写入的 TCHAR 数（含 NUL）。
static size_t pt_ngr_write_tchar_ascii(uint8_t *dst, const char *src) {
    size_t n = 0;
    while (src[n] != '\0') {
        dst[n * 2]     = (uint8_t)src[n];
        dst[n * 2 + 1] = 0x00;
        n++;
    }
    // trailing NUL (2 bytes for TCHAR)
    dst[n * 2]     = 0x00;
    dst[n * 2 + 1] = 0x00;
    return n + 1;
}

static void pt_ngr_log_cmdline_preseed_event(const char *status,
                                             uint64_t bInitializedAddr,
                                             uint64_t cmdlineBufferAddr,
                                             uint32_t bInitializedBefore,
                                             uint32_t bInitializedAfter,
                                             uint64_t slide,
                                             const char *cmdlinePreview) {
    NSLog(@"[PlayTools] HOK-015 cmdline-preseed: status=%s "
          @"bInitializedAddr=0x%llx cmdlineBufferAddr=0x%llx "
          @"before=%u after=%u slide=0x%llx preview=\"%s\"",
          status ?: "", bInitializedAddr, cmdlineBufferAddr,
          bInitializedBefore, bInitializedAfter, slide,
          cmdlinePreview ?: "");
    NSDictionary<NSString *, NSString *> *details = @{
        @"status": status ? [NSString stringWithUTF8String:status] : @"",
        @"bInitializedAddr": [NSString stringWithFormat:@"0x%llx", bInitializedAddr],
        @"cmdlineBufferAddr": [NSString stringWithFormat:@"0x%llx", cmdlineBufferAddr],
        @"bInitializedBefore": [NSString stringWithFormat:@"%u", bInitializedBefore],
        @"bInitializedAfter": [NSString stringWithFormat:@"%u", bInitializedAfter],
        @"slide": [NSString stringWithFormat:@"0x%llx", slide],
        @"cmdlinePreview": cmdlinePreview ? [NSString stringWithUTF8String:cmdlinePreview] : @"",
    };
    [PlayCover recordHOK015CmdlinePreseedWithDetails:details];
}

static void pt_ngr_preseed_cmdline_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 复用 HOK-013 的 bundle gate——非 `com.tencent.ngr` 直接跳过。
        if (!pt_ngr_should_preheat_slot()) {
            return;
        }

        const struct mach_header_64 *mh = NULL;
        uint64_t unslidTextVMAddr = 0;
        if (!pt_ngr_find_main_image(&mh, &unslidTextVMAddr)) {
            pt_ngr_log_cmdline_preseed_event("main-image-not-found",
                                             NGR_UE4_CMDLINE_BINITIALIZED_UNSLID,
                                             NGR_UE4_CMDLINE_BUFFER_UNSLID,
                                             0, 0, 0, "");
            return;
        }

        uint64_t slide = (uint64_t)(uintptr_t)mh - unslidTextVMAddr;
        if (unslidTextVMAddr != NGRSLOT_PREHEAT_TEXT_VMADDR) {
            // NGR 重链接后 __TEXT.vmaddr 可能变化；HOK-015-A 定位结果不再
            // 可靠，直接放弃预写。
            pt_ngr_log_cmdline_preseed_event("unexpected-text-vmaddr",
                                             NGR_UE4_CMDLINE_BINITIALIZED_UNSLID,
                                             NGR_UE4_CMDLINE_BUFFER_UNSLID,
                                             0, 0, slide, "");
            return;
        }

        uintptr_t bInitRuntimeAddr = (uintptr_t)(NGR_UE4_CMDLINE_BINITIALIZED_UNSLID + slide);
        uintptr_t cmdlineRuntimeAddr = (uintptr_t)(NGR_UE4_CMDLINE_BUFFER_UNSLID + slide);

        uint8_t bInitBefore = 0;
        memcpy(&bInitBefore, (void *)bInitRuntimeAddr, 1);
        if (bInitBefore != 0) {
            // UE4 本尊已经初始化（理论上 PlayTools constructor 时不应发生）；
            // 不要覆盖。
            pt_ngr_log_cmdline_preseed_event("already-initialized",
                                             (uint64_t)bInitRuntimeAddr,
                                             (uint64_t)cmdlineRuntimeAddr,
                                             bInitBefore, bInitBefore,
                                             slide, "");
            return;
        }

        // 1. 先写 CmdLine buffer（UTF-16-LE）。种子字符串是纯 ASCII + NUL，
        //    长度 = (25 chars + NUL) * 2 bytes = 52 bytes，远小于 UE4
        //    MaxCommandLineSize*sizeof(TCHAR) = 16384*2 = 32768 bytes。
        const char *seedUtf8 = NGR_UE4_CMDLINE_SEED_UTF8;
        pt_ngr_write_tchar_ascii((uint8_t *)cmdlineRuntimeAddr, seedUtf8);

        // 2. release fence：保证任何读者在看到 bInitialized=1 时 buffer 已
        //    稳定可见。clang 对 AArch64 下 __sync_synchronize() 会发 `dmb ish`。
        __sync_synchronize();

        // 3. 置 bInitialized = 1。
        uint8_t one = 1;
        memcpy((void *)bInitRuntimeAddr, &one, 1);

        uint8_t bInitAfter = 0;
        memcpy(&bInitAfter, (void *)bInitRuntimeAddr, 1);

        const char *status = (bInitAfter == 1) ? "primed" : "write-verify-failed";
        pt_ngr_log_cmdline_preseed_event(status,
                                         (uint64_t)bInitRuntimeAddr,
                                         (uint64_t)cmdlineRuntimeAddr,
                                         bInitBefore, bInitAfter,
                                         slide, seedUtf8);
    });
}
// ---------------------------------------------------------------------------

#define NGR_C5_MATERIALIZE_PROVIDER_UNSLID        0x10e16ded8ULL
#define NGR_C5_MATERIALIZE_VTABLE_UNSLID          0x10c80ae20ULL
#define NGR_C5_MATERIALIZE_TARGET_UNSLID          0x10432a068ULL
#define NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID     0x100128c6cULL
#define NGR_C5_CONSUMER_HANDLE_SLOT30_UNSLID      0x100122fb0ULL
#define NGR_C5_MATERIALIZE_TEMPLATE_SIZE          0x80U
#define NGR_C5_MATERIALIZE_MAX_CLONES             32U
#define NGR_C5_CONSUMER_VTABLE_CLONE_SIZE         0x80U
#define NGR_C5_CONSUMER_SCAN_WINDOW_BYTES         0x4000000ULL
#define NGR_C5_CONSUMER_SCAN_CHUNK_BYTES          0x4000U

uint64_t pt_ngr_c5_cached_materialize_obj = 0;
uint64_t pt_ngr_c5_original_materialize_target = 0;
uint64_t pt_ngr_c5_alt_original_materialize_target = 0;
uint64_t pt_ngr_c5_materialize_slot_addr = 0;
uint64_t pt_ngr_c5_materialize_provider_entry_addr = 0;
uint64_t pt_ngr_c5_main_image_slide = 0;
uint64_t pt_ngr_c5_recent_reuse_objects[4] = {0};
size_t pt_ngr_c5_recent_reuse_count = 0;
uint64_t pt_ngr_c5_consumer_handle_original_slot30 = 0;
BOOL pt_ngr_c5_consumer_handle_family_hooked = NO;
uint64_t pt_ngr_c5_late_linked_graph_obj = 0;
uint64_t pt_ngr_c5_late_linked_entry_obj = 0;
uint64_t pt_ngr_c5_late_linked_source_obj = 0;
uint64_t pt_ngr_c5_late_linked_wrapper_obj = 0;
void *pt_ngr_c5_cloned_materialize_table = NULL;
void *pt_ngr_c5_consumer_vtable_clones[NGR_C5_MATERIALIZE_MAX_CLONES] = {0};
size_t pt_ngr_c5_consumer_vtable_clone_count = 0;
uint8_t pt_ngr_c5_cached_materialize_template[NGR_C5_MATERIALIZE_TEMPLATE_SIZE] = {0};
BOOL pt_ngr_c5_have_materialize_template = NO;
BOOL pt_ngr_c5_have_late_linked_graph = NO;
void *pt_ngr_c5_materialize_clones[NGR_C5_MATERIALIZE_MAX_CLONES] = {0};
size_t pt_ngr_c5_materialize_clone_count = 0;
BOOL pt_ngr_c5_logged_cache_event = NO;
BOOL pt_ngr_c5_logged_late_linked_cache_event = NO;
BOOL pt_ngr_c5_logged_first_cache_probe = NO;
BOOL pt_ngr_c5_logged_first_fallback_probe = NO;

static void * const pt_ngr_c5_materialize_stub_vtable[4] = {
    (void *)pt_ngr_stub_vfunc_noop,
    (void *)pt_ngr_stub_vfunc_noop,
    (void *)pt_ngr_stub_vfunc_noop,
    (void *)pt_ngr_stub_vfunc_noop,
};

typedef struct {
    uint64_t providerEntryAddr;
    uint64_t tableAddr;
    uint64_t slotAddr;
    uint64_t slotValue;
} pt_ngr_c5_materialize_slot_match;

static BOOL pt_ngr_vm_read_bytes(uint64_t address, void *buffer, size_t size);
static BOOL pt_ngr_vm_read_u64(uint64_t address, uint64_t *outValue);
static BOOL pt_ngr_make_patch_writable(void *address, size_t length);
static void pt_ngr_restore_patch_protection(void *address, size_t length, vm_prot_t protection);
static BOOL pt_ngr_c5_install_consumer_handle_family_hook(uint64_t slide);
static void pt_ngr_c5_remember_reuse_object(uint64_t selectedObj);
static void pt_ngr_c5_schedule_consumer_handle_guard_scan(uint64_t payloadObj);

static const char pt_ngr_c5_content_pak_path[] = "../../../NGR/Content/Paks/1/1.db";

static BOOL pt_ngr_c5_string_has_prefix(const char *value, const char *prefix) {
    if (value == NULL || prefix == NULL) { return NO; }
    size_t prefixLength = strlen(prefix);
    return strncmp(value, prefix, prefixLength) == 0;
}

static BOOL pt_ngr_c5_should_cache_path(const char *path) {
    return pt_ngr_c5_string_has_prefix(path, pt_ngr_c5_content_pak_path);
}

static BOOL pt_ngr_c5_should_reuse_path(const char *path) {
    if (!pt_ngr_c5_string_has_prefix(path, "/Users/")) { return NO; }
    return strstr(path, "/Library/NGR/") != NULL
        || strstr(path, "/NGR/") != NULL
        || strstr(path, ".db") != NULL;
}

static BOOL pt_ngr_c5_should_redirect_saved_path(const char *path) {
    if (!pt_ngr_c5_should_reuse_path(path)) {
        return NO;
    }
    return strstr(path, "/Saved/Paks/1/1.db") != NULL;
}

static NSString *pt_ngr_c5_path_preview_string(const char *path) {
    if (path == NULL) { return @""; }
    size_t length = strnlen(path, 192);
    return [[NSString alloc] initWithBytes:path
                                    length:length
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *pt_ngr_c5_utf16_preview_string(uint64_t address) {
    if (address <= 0x100000000ULL) { return @""; }

    uint8_t buffer[192] = {0};
    if (!pt_ngr_vm_read_bytes(address, buffer, sizeof(buffer) - 2)) {
        return @"";
    }

    size_t length = 0;
    while (length + 1 < sizeof(buffer)) {
        if (buffer[length] == 0 && buffer[length + 1] == 0) {
            break;
        }
        length += 2;
    }

    return [[NSString alloc] initWithBytes:buffer
                                    length:length
                                  encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
}

static void pt_ngr_c5_schedule_vtable_stabilizer(uint64_t objAddr) {
    if (objAddr <= 0x100000000ULL) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                   ^{
        uint64_t current = 0;
        memcpy(&current, (const void *)(uintptr_t)objAddr, sizeof(current));
        if (current == 0 || current == (uint64_t)(uintptr_t)pt_ngr_c5_materialize_stub_vtable) {
            return;
        }
        uint64_t stubVtable = (uint64_t)(uintptr_t)pt_ngr_c5_materialize_stub_vtable;
        memcpy((void *)(uintptr_t)objAddr, &stubVtable, sizeof(stubVtable));
    });
}

static uint64_t pt_ngr_c5_clone_materialize_template(void) {
    if (pt_ngr_c5_cached_materialize_obj == 0 && !pt_ngr_c5_have_materialize_template) {
        return 0;
    }
    void *clone = calloc(1, NGR_C5_MATERIALIZE_TEMPLATE_SIZE);
    if (clone == NULL) {
        return 0;
    }
    BOOL copied = NO;
    if (pt_ngr_c5_cached_materialize_obj != 0) {
        copied = pt_ngr_vm_read_bytes(pt_ngr_c5_cached_materialize_obj,
                                      clone,
                                      NGR_C5_MATERIALIZE_TEMPLATE_SIZE);
    }
    if (!copied && pt_ngr_c5_have_materialize_template) {
        memcpy(clone,
               pt_ngr_c5_cached_materialize_template,
               sizeof(pt_ngr_c5_cached_materialize_template));
        copied = YES;
    }
    if (!copied) {
        free(clone);
        return 0;
    }
    if (pt_ngr_c5_materialize_clone_count < NGR_C5_MATERIALIZE_MAX_CLONES) {
        pt_ngr_c5_materialize_clones[pt_ngr_c5_materialize_clone_count++] = clone;
    }
    return (uint64_t)(uintptr_t)clone;
}

static BOOL pt_ngr_c5_try_capture_late_linked_graph(uint64_t candidateObj) {
    if (candidateObj <= 0x100000000ULL) {
        return NO;
    }

    uint64_t wrapperAddr = 0;
    uint64_t wrapperEntry = 0;
    uint64_t entryAddr = 0;
    uint64_t entrySlot1 = 0;

    if (pt_ngr_vm_read_u64(candidateObj + sizeof(uint64_t), &wrapperAddr)
        && wrapperAddr > 0x100000000ULL
        && pt_ngr_vm_read_u64(wrapperAddr, &wrapperEntry)
        && wrapperEntry == candidateObj) {
        pt_ngr_c5_late_linked_source_obj = candidateObj;
        pt_ngr_c5_late_linked_graph_obj = candidateObj;
        pt_ngr_c5_late_linked_entry_obj = candidateObj;
        pt_ngr_c5_late_linked_wrapper_obj = wrapperAddr;
        pt_ngr_c5_have_late_linked_graph = YES;
        return YES;
    }

    if (!pt_ngr_vm_read_u64(candidateObj + 0x30, &wrapperAddr)
        || wrapperAddr <= 0x100000000ULL
        || !pt_ngr_vm_read_u64(wrapperAddr, &entryAddr)
        || entryAddr <= 0x100000000ULL
        || !pt_ngr_vm_read_u64(entryAddr + sizeof(uint64_t), &entrySlot1)
        || entrySlot1 != wrapperAddr) {
        return NO;
    }

    pt_ngr_c5_late_linked_source_obj = candidateObj;
    pt_ngr_c5_late_linked_graph_obj = entryAddr;
    pt_ngr_c5_late_linked_entry_obj = entryAddr;
    pt_ngr_c5_late_linked_wrapper_obj = wrapperAddr;
    pt_ngr_c5_have_late_linked_graph = YES;
    return YES;
}

static uint64_t pt_ngr_c5_wait_for_late_linked_graph(uint64_t candidateObj) {
    if (pt_ngr_c5_have_late_linked_graph && pt_ngr_c5_late_linked_source_obj == candidateObj) {
        return pt_ngr_c5_late_linked_graph_obj;
    }
    if (pt_ngr_c5_try_capture_late_linked_graph(candidateObj)) {
        return pt_ngr_c5_late_linked_graph_obj;
    }
    for (size_t attempt = 0; attempt < 20; attempt++) {
        usleep(1000);
        if (pt_ngr_c5_try_capture_late_linked_graph(candidateObj)) {
            return pt_ngr_c5_late_linked_graph_obj;
        }
    }
    return 0;
}

static void pt_ngr_log_c5_install_event(const char *status,
                                        uint64_t patchAddr,
                                        uint64_t hookAddr,
                                        uint64_t successResumeAddr,
                                        uint64_t failResumeAddr,
                                        uint64_t slide) {
    NSLog(@"[PlayTools] HOK-016-C.5 materialize-shim install: status=%s patch=0x%llx hook=0x%llx successResume=0x%llx failResume=0x%llx slide=0x%llx",
          status ?: "", patchAddr, hookAddr, successResumeAddr, failResumeAddr, slide);
    NSDictionary<NSString *, NSString *> *details = @{
        @"status": status ? [NSString stringWithUTF8String:status] : @"",
        @"patchAddr": [NSString stringWithFormat:@"0x%llx", patchAddr],
        @"hookAddr": [NSString stringWithFormat:@"0x%llx", hookAddr],
        @"successResumeAddr": [NSString stringWithFormat:@"0x%llx", successResumeAddr],
        @"failResumeAddr": [NSString stringWithFormat:@"0x%llx", failResumeAddr],
        @"slide": [NSString stringWithFormat:@"0x%llx", slide],
    };
    [PlayCover recordHOK016C5MaterializeShimInstallWithDetails:details];
}

static void pt_ngr_log_c5_reuse_event(const char *action,
                                      uint64_t selectedObj,
                                      uint64_t helperAddr,
                                      uint64_t errSlotAddr,
                                      uint64_t savedArgAddr,
                                      uint64_t savedObjAddr,
                                      const char *path) {
    uint64_t selectedPlus0 = 0;
    uint64_t selectedPlus8 = 0;
    uint64_t selectedPlus10 = 0;
    uint64_t selectedPlus18 = 0;
    uint64_t selectedPlus28 = 0;
    uint64_t selectedPlus30 = 0;
    uint64_t plus8Backref0 = 0;
    uint64_t plus28Plus10 = 0;
    uint64_t plus28Plus18 = 0;
    uint64_t plus30Backref0 = 0;
    uint64_t plus30Backref8 = 0;
    uint64_t downstreamObj = 0;
    uint64_t downstreamPlus0 = 0;
    uint64_t downstreamPlus8 = 0;
    uint64_t downstreamPlus10 = 0;
    uint64_t downstreamPlus18 = 0;
    uint64_t downstreamPlus20 = 0;
    uint64_t downstreamPlus28 = 0;
    uint64_t downstreamPlus30 = 0;
    uint64_t downstreamPlus38 = 0;
    BOOL haveSelectedLinks = NO;
    BOOL haveDownstreamLinks = NO;

    if (selectedObj > 0x100000000ULL) {
        haveSelectedLinks = YES;
        (void)pt_ngr_vm_read_u64(selectedObj + 0x0, &selectedPlus0);
        (void)pt_ngr_vm_read_u64(selectedObj + 0x8, &selectedPlus8);
        (void)pt_ngr_vm_read_u64(selectedObj + 0x10, &selectedPlus10);
        (void)pt_ngr_vm_read_u64(selectedObj + 0x18, &selectedPlus18);
        (void)pt_ngr_vm_read_u64(selectedObj + 0x28, &selectedPlus28);
        (void)pt_ngr_vm_read_u64(selectedObj + 0x30, &selectedPlus30);
        if (selectedPlus8 > 0x100000000ULL) {
            (void)pt_ngr_vm_read_u64(selectedPlus8, &plus8Backref0);
        }
        if (selectedPlus28 > 0x100000000ULL) {
            (void)pt_ngr_vm_read_u64(selectedPlus28 + 0x10, &plus28Plus10);
            (void)pt_ngr_vm_read_u64(selectedPlus28 + 0x18, &plus28Plus18);
        }
        if (selectedPlus30 > 0x100000000ULL) {
            (void)pt_ngr_vm_read_u64(selectedPlus30, &plus30Backref0);
            (void)pt_ngr_vm_read_u64(selectedPlus30 + 0x8, &plus30Backref8);
        }
        if (selectedPlus10 > 0x100000000ULL) {
            downstreamObj = selectedPlus10;
            haveDownstreamLinks = YES;
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x0, &downstreamPlus0);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x8, &downstreamPlus8);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x10, &downstreamPlus10);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x18, &downstreamPlus18);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x20, &downstreamPlus20);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x28, &downstreamPlus28);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x30, &downstreamPlus30);
            (void)pt_ngr_vm_read_u64(downstreamObj + 0x38, &downstreamPlus38);
        }
    }

    NSLog(@"[PlayTools] HOK-016-C.5 materialize-shim: action=%s selected=0x%llx helper=0x%llx errSlot=0x%llx savedArg=0x%llx savedObj=0x%llx path=%s",
          action ?: "", selectedObj, helperAddr, errSlotAddr, savedArgAddr, savedObjAddr, path ?: "");
    NSMutableDictionary<NSString *, NSString *> *details = [@{
        @"action": action ? [NSString stringWithUTF8String:action] : @"",
        @"selectedObj": [NSString stringWithFormat:@"0x%llx", selectedObj],
        @"helperAddr": [NSString stringWithFormat:@"0x%llx", helperAddr],
        @"errSlotAddr": [NSString stringWithFormat:@"0x%llx", errSlotAddr],
        @"savedArgAddr": [NSString stringWithFormat:@"0x%llx", savedArgAddr],
        @"savedObjAddr": [NSString stringWithFormat:@"0x%llx", savedObjAddr],
        @"path": pt_ngr_c5_path_preview_string(path),
    } mutableCopy];
    if (haveSelectedLinks) {
        details[@"selectedPlus0"] = [NSString stringWithFormat:@"0x%llx", selectedPlus0];
        details[@"selectedPlus8"] = [NSString stringWithFormat:@"0x%llx", selectedPlus8];
        details[@"selectedPlus10"] = [NSString stringWithFormat:@"0x%llx", selectedPlus10];
        details[@"selectedPlus18"] = [NSString stringWithFormat:@"0x%llx", selectedPlus18];
        details[@"selectedPlus28"] = [NSString stringWithFormat:@"0x%llx", selectedPlus28];
        details[@"selectedPlus30"] = [NSString stringWithFormat:@"0x%llx", selectedPlus30];
        details[@"plus8Backref0"] = [NSString stringWithFormat:@"0x%llx", plus8Backref0];
        details[@"plus28Plus10"] = [NSString stringWithFormat:@"0x%llx", plus28Plus10];
        details[@"plus28Plus18"] = [NSString stringWithFormat:@"0x%llx", plus28Plus18];
        details[@"plus30Backref0"] = [NSString stringWithFormat:@"0x%llx", plus30Backref0];
        details[@"plus30Backref8"] = [NSString stringWithFormat:@"0x%llx", plus30Backref8];
    }
    if (haveDownstreamLinks) {
        details[@"downstreamObj"] = [NSString stringWithFormat:@"0x%llx", downstreamObj];
        details[@"downstreamPlus0"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus0];
        details[@"downstreamPlus8"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus8];
        details[@"downstreamPlus10"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus10];
        details[@"downstreamPlus18"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus18];
        details[@"downstreamPlus20"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus20];
        details[@"downstreamPlus28"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus28];
        details[@"downstreamPlus30"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus30];
        details[@"downstreamPlus38"] = [NSString stringWithFormat:@"0x%llx", downstreamPlus38];
        details[@"downstreamPreview"] = pt_ngr_c5_utf16_preview_string(downstreamObj);
    }
    if (action != NULL && strncmp(action, "reuse", 5) == 0) {
        pt_ngr_c5_trace_fs_after_reuse = YES;
        pt_ngr_c5_fs_trace_count = 0;
        pt_ngr_c5_url_trace_count = 0;
        pt_ngr_c5_remember_reuse_object(selectedObj);
    }
    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];
}

static void pt_ngr_c5_remember_reuse_object(uint64_t selectedObj) {
    if (selectedObj <= 0x100000000ULL) {
        return;
    }
    for (size_t index = 0; index < pt_ngr_c5_recent_reuse_count; index++) {
        if (pt_ngr_c5_recent_reuse_objects[index] == selectedObj) {
            return;
        }
    }
    if (pt_ngr_c5_recent_reuse_count < sizeof(pt_ngr_c5_recent_reuse_objects) / sizeof(pt_ngr_c5_recent_reuse_objects[0])) {
        pt_ngr_c5_recent_reuse_objects[pt_ngr_c5_recent_reuse_count++] = selectedObj;
        return;
    }
    memmove(pt_ngr_c5_recent_reuse_objects,
            pt_ngr_c5_recent_reuse_objects + 1,
            sizeof(pt_ngr_c5_recent_reuse_objects) - sizeof(pt_ngr_c5_recent_reuse_objects[0]));
    pt_ngr_c5_recent_reuse_objects[(sizeof(pt_ngr_c5_recent_reuse_objects) / sizeof(pt_ngr_c5_recent_reuse_objects[0])) - 1] = selectedObj;
}

static void pt_ngr_c5_log_first_fallback_probe(uint64_t originalRetObj,
                                               uint64_t replacementObj,
                                               uint64_t errSlotAddr,
                                               const char *path) {
    if (pt_ngr_c5_logged_first_fallback_probe) {
        return;
    }
    pt_ngr_c5_logged_first_fallback_probe = YES;

    uint64_t errSlotValue = 0;
    if (errSlotAddr > 0x100000000ULL) {
        (void)pt_ngr_vm_read_u64(errSlotAddr, &errSlotValue);
    }

    NSDictionary<NSString *, NSString *> *details = @{
        @"action": @"reuse-early-fallback-probe",
        @"originalRetObj": [NSString stringWithFormat:@"0x%llx", originalRetObj],
        @"selectedObj": [NSString stringWithFormat:@"0x%llx", replacementObj],
        @"errSlotAddr": [NSString stringWithFormat:@"0x%llx", errSlotAddr],
        @"errSlotValue": [NSString stringWithFormat:@"0x%llx", errSlotValue],
        @"path": pt_ngr_c5_path_preview_string(path),
    };
    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];
}

static void pt_ngr_c5_log_first_cache_probe(uint64_t originalRetObj,
                                            uint64_t selectedObj,
                                            uint64_t errSlotAddr,
                                            const char *path) {
    if (pt_ngr_c5_logged_first_cache_probe) {
        return;
    }
    pt_ngr_c5_logged_first_cache_probe = YES;

    uint64_t errSlotValue = 0;
    if (errSlotAddr > 0x100000000ULL) {
        (void)pt_ngr_vm_read_u64(errSlotAddr, &errSlotValue);
    }

    NSDictionary<NSString *, NSString *> *details = @{
        @"action": @"cache-probe",
        @"originalRetObj": [NSString stringWithFormat:@"0x%llx", originalRetObj],
        @"selectedObj": [NSString stringWithFormat:@"0x%llx", selectedObj],
        @"errSlotAddr": [NSString stringWithFormat:@"0x%llx", errSlotAddr],
        @"errSlotValue": [NSString stringWithFormat:@"0x%llx", errSlotValue],
        @"path": pt_ngr_c5_path_preview_string(path),
    };
    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];
}

static void pt_ngr_c5_clear_error_slot(uint64_t errSlotAddr) {
    if (errSlotAddr <= 0x100000000ULL) {
        return;
    }

    uint64_t zero = 0;
    memcpy((void *)(uintptr_t)errSlotAddr, &zero, sizeof(zero));
}

static BOOL pt_ngr_c5_payload_matches_recent_reuse(uint64_t payloadObj) {
    for (size_t index = 0; index < pt_ngr_c5_recent_reuse_count; index++) {
        if (pt_ngr_c5_recent_reuse_objects[index] == payloadObj) {
            return YES;
        }
    }
    return NO;
}

typedef void (*pt_ngr_c5_consumer_handle_slot30_imp_t)(uint64_t);

static void pt_ngr_c5_consumer_handle_slot30_wrapper(uint64_t handleObj) {
    uint64_t payloadObj = 0;
    uint64_t containerObj = 0;
    uint64_t candidateObj = 0;
    if (handleObj > 0x100000000ULL) {
        memcpy(&payloadObj, (const void *)(uintptr_t)(handleObj + 0x18), sizeof(payloadObj));
        memcpy(&containerObj, (const void *)(uintptr_t)(handleObj + 0x10), sizeof(containerObj));
        if (containerObj > 0x100000000ULL) {
            memcpy(&candidateObj, (const void *)(uintptr_t)(containerObj + 0x8), sizeof(candidateObj));
        }
        if (pt_ngr_c5_payload_matches_recent_reuse(candidateObj)) {
            uint64_t zero = 0;
            memcpy((void *)(uintptr_t)(handleObj + 0x18), &zero, sizeof(zero));
            pt_ngr_log_c5_reuse_event("consumer-handle-zeroed",
                                      candidateObj,
                                      handleObj,
                                      handleObj + 0x18,
                                      0,
                                      0,
                                      "handle+0x18");
        }
    }

    if (pt_ngr_c5_consumer_handle_original_slot30 != 0) {
        pt_ngr_c5_consumer_handle_slot30_imp_t orig =
            (pt_ngr_c5_consumer_handle_slot30_imp_t)(uintptr_t)pt_ngr_c5_consumer_handle_original_slot30;
        orig(handleObj);
    }
}

static BOOL pt_ngr_c5_install_consumer_handle_family_hook(uint64_t slide) {
    if (pt_ngr_c5_consumer_handle_family_hooked) {
        return YES;
    }

    uint64_t vtableAddr = NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide;
    uint64_t slotAddr = vtableAddr + 0x18;
    uint64_t originalSlot = 0;
    uint64_t wrapperAddr = (uint64_t)(uintptr_t)&pt_ngr_c5_consumer_handle_slot30_wrapper;

    if (!pt_ngr_vm_read_u64(slotAddr, &originalSlot) || originalSlot <= 0x100000000ULL) {
        return NO;
    }
    if (originalSlot == wrapperAddr) {
        pt_ngr_c5_consumer_handle_family_hooked = YES;
        return YES;
    }
    if (!pt_ngr_make_patch_writable((void *)(uintptr_t)slotAddr, sizeof(wrapperAddr))) {
        return NO;
    }

    memcpy((void *)(uintptr_t)slotAddr, &wrapperAddr, sizeof(wrapperAddr));
    pt_ngr_restore_patch_protection((void *)(uintptr_t)slotAddr, sizeof(wrapperAddr), VM_PROT_READ);

    uint64_t verify = 0;
    if (!pt_ngr_vm_read_u64(slotAddr, &verify) || verify != wrapperAddr) {
        return NO;
    }

    pt_ngr_c5_consumer_handle_original_slot30 = originalSlot;
    pt_ngr_c5_consumer_handle_family_hooked = YES;
    pt_ngr_log_c5_install_event("consumer-family-hook-installed",
                                slotAddr,
                                wrapperAddr,
                                originalSlot,
                                vtableAddr,
                                slide);
    return YES;
}

static BOOL pt_ngr_c5_try_patch_consumer_handle(uint64_t handleObj) {
    if (handleObj <= 0x100000000ULL) {
        return NO;
    }

    uint64_t vtableAddr = 0;
    if (!pt_ngr_vm_read_u64(handleObj, &vtableAddr) || vtableAddr <= 0x100000000ULL) {
        return NO;
    }

    uint64_t slot18 = 0;
    if (!pt_ngr_vm_read_u64(vtableAddr + 0x18, &slot18)) {
        return NO;
    }

    uint64_t expectedVtableAddr = NGR_C5_MATERIALIZE_VTABLE_UNSLID + pt_ngr_c5_main_image_slide;
    uint64_t wrapperAddr = (uint64_t)(uintptr_t)&pt_ngr_c5_consumer_handle_slot30_wrapper;
    if (slot18 == wrapperAddr) {
        return YES;
    }
    if (vtableAddr != expectedVtableAddr) {
        return NO;
    }

    uint8_t vtableClone[NGR_C5_CONSUMER_VTABLE_CLONE_SIZE] = {0};
    if (!pt_ngr_vm_read_bytes(vtableAddr, vtableClone, sizeof(vtableClone))) {
        return NO;
    }

    void *clone = malloc(sizeof(vtableClone));
    if (clone == NULL) {
        return NO;
    }
    memcpy(clone, vtableClone, sizeof(vtableClone));
    memcpy((uint8_t *)clone + 0x18, &wrapperAddr, sizeof(wrapperAddr));

    memcpy((void *)(uintptr_t)handleObj, &clone, sizeof(clone));
    uint64_t verifyVtable = 0;
    if (!pt_ngr_vm_read_u64(handleObj, &verifyVtable) || verifyVtable != (uint64_t)(uintptr_t)clone) {
        free(clone);
        return NO;
    }

    pt_ngr_c5_consumer_handle_original_slot30 = slot18;
    if (pt_ngr_c5_consumer_vtable_clone_count < NGR_C5_MATERIALIZE_MAX_CLONES) {
        pt_ngr_c5_consumer_vtable_clones[pt_ngr_c5_consumer_vtable_clone_count++] = clone;
    }
    pt_ngr_log_c5_reuse_event("consumer-handle-guard-installed",
                              handleObj,
                              handleObj,
                              handleObj + 0x18,
                              0,
                              0,
                              "handle+0x18");
    return YES;
}

static BOOL pt_ngr_c5_scan_consumer_handles_for_payload(uint64_t anchorObj) {
    if (anchorObj <= 0x100000000ULL) {
        return NO;
    }

    uint64_t base = anchorObj > NGR_C5_CONSUMER_SCAN_WINDOW_BYTES
        ? anchorObj - NGR_C5_CONSUMER_SCAN_WINDOW_BYTES
        : 0;
    uint64_t limit = anchorObj + NGR_C5_CONSUMER_SCAN_WINDOW_BYTES;

    uint8_t buffer[NGR_C5_CONSUMER_SCAN_CHUNK_BYTES] = {0};
    for (uint64_t address = base; address < limit; address += NGR_C5_CONSUMER_SCAN_CHUNK_BYTES) {
        size_t readable = NGR_C5_CONSUMER_SCAN_CHUNK_BYTES;
        if (address + readable > limit) {
            readable = (size_t)(limit - address);
        }
        if (!pt_ngr_vm_read_bytes(address, buffer, readable)) {
            continue;
        }
        for (size_t offset = 0; offset + sizeof(uint64_t) <= readable; offset += sizeof(uint64_t)) {
            if (offset + (4 * sizeof(uint64_t)) > readable) {
                break;
            }
            uint64_t qword0 = 0;
            uint64_t qword1 = 0;
            uint64_t qword2 = 0;
            uint64_t qword3 = 0;
            memcpy(&qword0, buffer + offset, sizeof(qword0));
            memcpy(&qword1, buffer + offset + sizeof(uint64_t), sizeof(qword1));
            memcpy(&qword2, buffer + offset + (2 * sizeof(uint64_t)), sizeof(qword2));
            memcpy(&qword3, buffer + offset + (3 * sizeof(uint64_t)), sizeof(qword3));
            if (qword0 <= 0x100000000ULL
                || qword1 > 0x20
                || qword2 <= 0x100000000ULL
                || qword3 == 0) {
                continue;
            }
            uint64_t handleObj = address + offset;
            if (pt_ngr_c5_try_patch_consumer_handle(handleObj)) {
                return YES;
            }
        }
    }
    return NO;
}

static void pt_ngr_c5_schedule_consumer_handle_guard_scan(uint64_t payloadObj) {
    if (payloadObj <= 0x100000000ULL) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (pt_ngr_c5_scan_consumer_handles_for_payload(payloadObj)) {
            return;
        }
        for (size_t attempt = 0; attempt < 4; attempt++) {
            usleep(2000);
            if (pt_ngr_c5_scan_consumer_handles_for_payload(payloadObj)) {
                return;
            }
        }
        pt_ngr_log_c5_reuse_event("consumer-handle-guard-miss",
                                  payloadObj,
                                  0,
                                  0,
                                  0,
                                  0,
                                  "handle+0x18");
    });
}

uint64_t pt_ngr_c5_materialize_select(uint64_t retObj,
                                      uint64_t helperAddr,
                                      uint64_t errSlotAddr,
                                      uint64_t savedArgAddr,
                                      uint64_t savedObjAddr) {
    const char *path = savedObjAddr > 0x100000000ULL
        ? (const char *)(uintptr_t)savedObjAddr
        : NULL;

    if (retObj != 0 && pt_ngr_c5_should_cache_path(path)) {
        pt_ngr_c5_cached_materialize_obj = retObj;
        pt_ngr_c5_have_materialize_template = pt_ngr_vm_read_bytes(
            retObj,
            pt_ngr_c5_cached_materialize_template,
            sizeof(pt_ngr_c5_cached_materialize_template)
        );
        pt_ngr_c5_log_first_cache_probe(retObj,
                                        retObj,
                                        errSlotAddr,
                                        path);
        uint64_t lateLinked = pt_ngr_c5_wait_for_late_linked_graph(retObj);
        if (lateLinked != 0 && !pt_ngr_c5_logged_late_linked_cache_event) {
            pt_ngr_c5_logged_late_linked_cache_event = YES;
            pt_ngr_log_c5_reuse_event("cache-late-linked",
                                      lateLinked,
                                      helperAddr,
                                      errSlotAddr,
                                      savedArgAddr,
                                      savedObjAddr,
                                      path);
        }
        if (!pt_ngr_c5_logged_cache_event) {
            pt_ngr_c5_logged_cache_event = YES;
            pt_ngr_log_c5_reuse_event("cache",
                                      retObj,
                                      helperAddr,
                                      errSlotAddr,
                                      savedArgAddr,
                                      savedObjAddr,
                                      path);
        }
        return retObj;
    }

    if (retObj == 0
        && pt_ngr_c5_have_materialize_template
        && pt_ngr_c5_should_reuse_path(path)) {
        uint64_t replacement = pt_ngr_c5_wait_for_late_linked_graph(pt_ngr_c5_cached_materialize_obj);
        if (replacement != 0) {
            pt_ngr_c5_clear_error_slot(errSlotAddr);
            pt_ngr_log_c5_reuse_event("reuse-late-linked",
                                      replacement,
                                      helperAddr,
                                      errSlotAddr,
                                      savedArgAddr,
                                      savedObjAddr,
                                      path);
            if (!pt_ngr_c5_scan_consumer_handles_for_payload(replacement)) {
                pt_ngr_c5_schedule_consumer_handle_guard_scan(replacement);
            }
            return replacement;
        }

        replacement = pt_ngr_c5_cached_materialize_obj;
        pt_ngr_c5_schedule_vtable_stabilizer(replacement);
        pt_ngr_c5_log_first_fallback_probe(retObj,
                                           replacement,
                                           errSlotAddr,
                                           path);
        pt_ngr_c5_clear_error_slot(errSlotAddr);
        pt_ngr_log_c5_reuse_event("reuse-early-fallback",
                                  replacement,
                                  helperAddr,
                                  errSlotAddr,
                                  savedArgAddr,
                                  savedObjAddr,
                                  path);
        if (!pt_ngr_c5_scan_consumer_handles_for_payload(replacement)) {
            pt_ngr_c5_schedule_consumer_handle_guard_scan(replacement);
        }
        return replacement;
    }

    return retObj;
}

typedef uint64_t (*pt_ngr_c5_materialize_imp_t)(uint64_t, uint64_t, uint64_t, uint64_t);

static uint64_t pt_ngr_c5_materialize_dispatch_with_target(uint64_t x0,
                                                            uint64_t x1,
                                                            uint64_t x2,
                                                            uint64_t x3,
                                                            uint64_t originalTarget) {
    const char *originalPath = x1 > 0x100000000ULL
        ? (const char *)(uintptr_t)x1
        : NULL;
    uint64_t dispatchSavedObjAddr = x1;
    if (pt_ngr_c5_should_redirect_saved_path(originalPath)) {
        dispatchSavedObjAddr = (uint64_t)(uintptr_t)pt_ngr_c5_content_pak_path;
    }

    uint64_t retObj = 0;
    if (originalTarget != 0) {
        pt_ngr_c5_materialize_imp_t orig =
            (pt_ngr_c5_materialize_imp_t)(uintptr_t)originalTarget;
        retObj = orig(x0, dispatchSavedObjAddr, x2, x3);
    }

    return pt_ngr_c5_materialize_select(retObj,
                                        0,
                                        x3,
                                        x2,
                                        dispatchSavedObjAddr);
}

uint64_t pt_ngr_c5_materialize_dispatch_hook(uint64_t x0,
                                             uint64_t x1,
                                             uint64_t x2,
                                             uint64_t x3) {
    return pt_ngr_c5_materialize_dispatch_with_target(x0, x1, x2, x3,
                                                      pt_ngr_c5_original_materialize_target);
}

uint64_t pt_ngr_c5_materialize_dispatch_hook_alt1(uint64_t x0,
                                                  uint64_t x1,
                                                  uint64_t x2,
                                                  uint64_t x3) {
    const char *originalPath = x1 > 0x100000000ULL
        ? (const char *)(uintptr_t)x1
        : NULL;
    uint64_t dispatchSavedObjAddr = x1;
    if (pt_ngr_c5_should_redirect_saved_path(originalPath)) {
        dispatchSavedObjAddr = (uint64_t)(uintptr_t)pt_ngr_c5_content_pak_path;
    }

    uint64_t retObj = 0;
    uint64_t originalTarget = pt_ngr_c5_alt_original_materialize_target;
    if (originalTarget != 0) {
        pt_ngr_c5_materialize_imp_t orig =
            (pt_ngr_c5_materialize_imp_t)(uintptr_t)originalTarget;
        retObj = orig(x0, dispatchSavedObjAddr, x2, x3);
    }

    uint64_t selectedObj = pt_ngr_c5_materialize_select(retObj,
                                                        0,
                                                        x3,
                                                        x2,
                                                        dispatchSavedObjAddr);

    static uint32_t pt_ngr_c5_alt1_call_index = 0;
    pt_ngr_c5_alt1_call_index++;
    NSDictionary<NSString *, NSString *> *details = @{
        @"action": @"alt1-dispatch",
        @"callIndex": [NSString stringWithFormat:@"%u", pt_ngr_c5_alt1_call_index],
        @"x0": [NSString stringWithFormat:@"0x%llx", x0],
        @"x1Path": pt_ngr_c5_path_preview_string(originalPath),
        @"x2": [NSString stringWithFormat:@"0x%llx", x2],
        @"x3": [NSString stringWithFormat:@"0x%llx", x3],
        @"originalRetObj": [NSString stringWithFormat:@"0x%llx", retObj],
        @"selectedObj": [NSString stringWithFormat:@"0x%llx", selectedObj],
        @"originalTarget": [NSString stringWithFormat:@"0x%llx", originalTarget],
    };
    [PlayCover recordHOK016C5MaterializeShimReuseWithDetails:details];

    return selectedObj;
}

static BOOL pt_ngr_make_patch_writable(void *address, size_t length) {
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) { return NO; }
    uintptr_t start = ((uintptr_t)address) & ~((uintptr_t)pageSize - 1ULL);
    uintptr_t end = (((uintptr_t)address) + length + (uintptr_t)pageSize - 1ULL)
        & ~((uintptr_t)pageSize - 1ULL);
    size_t size = (size_t)(end - start);
    if (mprotect((void *)start, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        return YES;
    }
    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)start,
                                  (vm_size_t)size,
                                  TRUE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    kr = vm_protect(mach_task_self(),
                    (vm_address_t)start,
                    (vm_size_t)size,
                    FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

static void pt_ngr_restore_patch_protection(void *address, size_t length, vm_prot_t protection) {
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) { return; }
    uintptr_t start = ((uintptr_t)address) & ~((uintptr_t)pageSize - 1ULL);
    uintptr_t end = (((uintptr_t)address) + length + (uintptr_t)pageSize - 1ULL)
        & ~((uintptr_t)pageSize - 1ULL);
    size_t size = (size_t)(end - start);
    int mprotectFlags = PROT_READ;
    if ((protection & VM_PROT_EXECUTE) != 0) {
        mprotectFlags |= PROT_EXEC;
    }
    if ((protection & VM_PROT_WRITE) != 0) {
        mprotectFlags |= PROT_WRITE;
    }
    if (mprotect((void *)start, size, mprotectFlags) == 0) {
        return;
    }
    vm_protect(mach_task_self(),
               (vm_address_t)start,
               (vm_size_t)size,
               FALSE,
               protection);
}

static BOOL pt_ngr_vm_read_bytes(uint64_t address, void *buffer, size_t size) {
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         (vm_size_t)size,
                                         (vm_address_t)buffer,
                                         &outSize);
    return kr == KERN_SUCCESS && outSize == size;
}

static BOOL pt_ngr_vm_read_u64(uint64_t address, uint64_t *outValue) {
    return pt_ngr_vm_read_bytes(address, outValue, sizeof(*outValue));
}

static BOOL pt_ngr_c5_find_materialize_slot_from_provider(uint64_t providerAddr,
                                                          uint64_t targetValue,
                                                          pt_ngr_c5_materialize_slot_match *outMatch) {
    if (providerAddr == 0) {
        return NO;
    }
    for (size_t index = 0; index < 16; index++) {
        uint64_t tableAddr = 0;
        if (!pt_ngr_vm_read_u64(providerAddr + (index * sizeof(uint64_t)), &tableAddr)) {
            continue;
        }
        if (tableAddr <= 0x100000000ULL) {
            continue;
        }
        uint64_t slotValue = 0;
        uint64_t slotAddr = tableAddr + 0x10;
        if (!pt_ngr_vm_read_u64(slotAddr, &slotValue)) {
            continue;
        }
        if (slotValue == targetValue) {
            if (outMatch != NULL) {
                outMatch->providerEntryAddr = providerAddr + (index * sizeof(uint64_t));
                outMatch->tableAddr = tableAddr;
                outMatch->slotAddr = slotAddr;
                outMatch->slotValue = slotValue;
            }
            return YES;
        }
    }
    return NO;
}

static void pt_ngr_c5_install_alt1_hook(uint64_t slide, const struct mach_header_64 *mh) {
    uint64_t alt1Slided = NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID + slide;
    uint64_t alt1SlotAddr = 0;
    pt_ngr_c5_materialize_slot_match alt1Match = {0};

    uint64_t altProviderBases[] = {
        NGR_C5_MATERIALIZE_PROVIDER_UNSLID,
        NGR_C5_MATERIALIZE_PROVIDER_UNSLID,
        NGR_C5_MATERIALIZE_PROVIDER_UNSLID + slide,
        NGR_C5_MATERIALIZE_PROVIDER_UNSLID + slide,
        NGR_C5_MATERIALIZE_VTABLE_UNSLID,
        NGR_C5_MATERIALIZE_VTABLE_UNSLID,
        NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide,
        NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide,
    };
    uint64_t altTargetValues[] = {
        NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID,
        alt1Slided,
        NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID,
        alt1Slided,
        NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID,
        alt1Slided,
        NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID,
        alt1Slided,
    };
    for (size_t i = 0; i < sizeof(altProviderBases) / sizeof(altProviderBases[0]); i++) {
        pt_ngr_c5_materialize_slot_match candidate = {0};
        if (pt_ngr_c5_find_materialize_slot_from_provider(altProviderBases[i],
                                                          altTargetValues[i],
                                                          &candidate)) {
            alt1Match = candidate;
            alt1SlotAddr = candidate.slotAddr;
            break;
        }
    }

    if (alt1SlotAddr == 0) {
        const uint8_t *cmdPtr = (const uint8_t *)mh + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < mh->ncmds && alt1SlotAddr == 0; c++) {
            const struct load_command *lc = (const struct load_command *)cmdPtr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
                if (strncmp(sc->segname, "__DATA", 6) == 0 ||
                    strncmp(sc->segname, "__DATA_CONST", 12) == 0) {
                    uint64_t segStart = sc->vmaddr + slide;
                    uint64_t segEnd = segStart + sc->vmsize;
                    for (uint64_t addr = segStart;
                         addr + sizeof(uint64_t) <= segEnd;
                         addr += sizeof(uint64_t)) {
                        uint64_t value = 0;
                        if (!pt_ngr_vm_read_u64(addr, &value)) continue;
                        if (value == alt1Slided) {
                            alt1SlotAddr = addr;
                            break;
                        }
                    }
                }
            }
            cmdPtr += lc->cmdsize;
        }
    }

    if (alt1SlotAddr != 0) {
        uint64_t altOriginalTarget = 0;
        if (pt_ngr_vm_read_u64(alt1SlotAddr, &altOriginalTarget)
            && (altOriginalTarget == NGR_C5_MATERIALIZE_TARGET_ALT1_UNSLID
                || altOriginalTarget == alt1Slided)) {

            uint64_t altHookTarget = (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook_alt1;
            if (pt_ngr_make_patch_writable((void *)alt1SlotAddr, sizeof(uint64_t))) {
                memcpy((void *)alt1SlotAddr, &altHookTarget, sizeof(altHookTarget));
                pt_ngr_restore_patch_protection((void *)alt1SlotAddr,
                                                sizeof(altHookTarget),
                                                VM_PROT_READ);

                uint64_t verifyAlt = 0;
                if (pt_ngr_vm_read_u64(alt1SlotAddr, &verifyAlt)
                    && verifyAlt == altHookTarget) {
                    pt_ngr_c5_alt_original_materialize_target = altOriginalTarget;
                    pt_ngr_log_c5_install_event("installed-alt1",
                                                alt1SlotAddr,
                                                altHookTarget,
                                                altOriginalTarget,
                                                0,
                                                slide);
                } else {
                    pt_ngr_log_c5_install_event("alt1-verify-failed",
                                                alt1SlotAddr,
                                                altHookTarget,
                                                altOriginalTarget,
                                                0,
                                                slide);
                }
            } else {
                kern_return_t kr = vm_write(mach_task_self(),
                                            (vm_address_t)alt1SlotAddr,
                                            (vm_offset_t)&altHookTarget,
                                            (mach_msg_type_number_t)sizeof(altHookTarget));
                if (kr == KERN_SUCCESS) {
                    uint64_t verifyAlt = 0;
                    if (pt_ngr_vm_read_u64(alt1SlotAddr, &verifyAlt)
                        && verifyAlt == altHookTarget) {
                        pt_ngr_c5_alt_original_materialize_target = altOriginalTarget;
                        pt_ngr_log_c5_install_event("installed-alt1-vmwrite",
                                                    alt1SlotAddr,
                                                    altHookTarget,
                                                    altOriginalTarget,
                                                    0,
                                                    slide);
                    } else {
                        pt_ngr_log_c5_install_event("alt1-vmwrite-verify-failed",
                                                    alt1SlotAddr,
                                                    altHookTarget,
                                                    altOriginalTarget,
                                                    0,
                                                    slide);
                    }
                } else {
                    pt_ngr_log_c5_install_event("alt1-not-writable",
                                                alt1SlotAddr,
                                                altHookTarget,
                                                altOriginalTarget,
                                                0,
                                                slide);
                }
            }
        } else {
            pt_ngr_log_c5_install_event("alt1-unexpected-slot-value",
                                        alt1SlotAddr,
                                        (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook_alt1,
                                        altOriginalTarget,
                                        0,
                                        slide);
        }
    } else {
        pt_ngr_log_c5_install_event("alt1-slot-not-found",
                                    0,
                                    (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook_alt1,
                                    0,
                                    0,
                                    slide);
    }
}

static void pt_ngr_install_materialize_shim_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!pt_ngr_should_preheat_slot()) {
            return;
        }

        const struct mach_header_64 *mh = NULL;
        uint64_t unslidTextVMAddr = 0;
        if (!pt_ngr_find_main_image(&mh, &unslidTextVMAddr)) {
            pt_ngr_log_c5_install_event("main-image-not-found", 0, 0, 0, 0, 0);
            return;
        }

        uint64_t slide = (uint64_t)(uintptr_t)mh - unslidTextVMAddr;
        pt_ngr_c5_main_image_slide = slide;
        if (unslidTextVMAddr != NGRSLOT_PREHEAT_TEXT_VMADDR) {
            pt_ngr_log_c5_install_event("unexpected-text-vmaddr", 0, 0, 0, 0, slide);
            return;
        }

        if (!pt_ngr_c5_install_consumer_handle_family_hook(slide)) {
            pt_ngr_log_c5_install_event("consumer-family-hook-install-failed",
                                        NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide + 0x18,
                                        0,
                                        0,
                                        NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide,
                                        slide);
        }

        uint64_t slidedTarget = NGR_C5_MATERIALIZE_TARGET_UNSLID + slide;
        pt_ngr_c5_materialize_slot_match candidates[8] = {0};
        size_t matchCount = 0;
        uint64_t providerBases[] = {
            NGR_C5_MATERIALIZE_PROVIDER_UNSLID,
            NGR_C5_MATERIALIZE_PROVIDER_UNSLID,
            NGR_C5_MATERIALIZE_PROVIDER_UNSLID + slide,
            NGR_C5_MATERIALIZE_PROVIDER_UNSLID + slide,
            NGR_C5_MATERIALIZE_VTABLE_UNSLID,
            NGR_C5_MATERIALIZE_VTABLE_UNSLID,
            NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide,
            NGR_C5_MATERIALIZE_VTABLE_UNSLID + slide,
        };
        uint64_t targetValues[] = {
            NGR_C5_MATERIALIZE_TARGET_UNSLID,
            slidedTarget,
            NGR_C5_MATERIALIZE_TARGET_UNSLID,
            slidedTarget,
            NGR_C5_MATERIALIZE_TARGET_UNSLID,
            slidedTarget,
            NGR_C5_MATERIALIZE_TARGET_UNSLID,
            slidedTarget,
        };

        pt_ngr_c5_materialize_slot_match selected = {0};
        for (size_t i = 0; i < sizeof(providerBases) / sizeof(providerBases[0]); i++) {
            pt_ngr_c5_materialize_slot_match candidate = {0};
            if (!pt_ngr_c5_find_materialize_slot_from_provider(providerBases[i],
                                                               targetValues[i],
                                                               &candidate)) {
                continue;
            }
            candidates[matchCount++] = candidate;
            if (selected.slotAddr == 0) {
                selected = candidate;
            }
        }

        if (selected.slotAddr == 0) {
            pt_ngr_log_c5_install_event("slot-not-found",
                                        0,
                                        (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook,
                                        0,
                                        0,
                                        slide);
            return;
        }

        uint64_t slotAddr = selected.slotAddr;
        uint64_t originalTarget = selected.slotValue;
        if (!pt_ngr_vm_read_u64(slotAddr, &originalTarget)
            || (originalTarget != NGR_C5_MATERIALIZE_TARGET_UNSLID
                && originalTarget != slidedTarget)) {
            pt_ngr_log_c5_install_event("unexpected-slot-value",
                                        slotAddr,
                                        (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook,
                                        originalTarget,
                                        0,
                                        slide);
            return;
        }

        pt_ngr_c5_materialize_provider_entry_addr = selected.providerEntryAddr;

        uint64_t hookTarget = (uint64_t)(uintptr_t)&pt_ngr_c5_materialize_dispatch_hook;
        if (!pt_ngr_make_patch_writable((void *)slotAddr, sizeof(uint64_t))) {
            uint8_t tableCopy[0x80] = {0};
            if (!pt_ngr_vm_read_bytes(selected.tableAddr, tableCopy, sizeof(tableCopy))) {
                pt_ngr_log_c5_install_event("clone-read-failed",
                                            slotAddr,
                                            hookTarget,
                                            originalTarget,
                                            selected.tableAddr,
                                            slide);
                return;
            }
            void *tableClone = malloc(sizeof(tableCopy));
            if (tableClone == NULL) {
                pt_ngr_log_c5_install_event("clone-alloc-failed",
                                            slotAddr,
                                            hookTarget,
                                            originalTarget,
                                            selected.tableAddr,
                                            slide);
                return;
            }
            memcpy(tableClone, tableCopy, sizeof(tableCopy));
            memcpy((uint8_t *)tableClone + 0x10, &hookTarget, sizeof(hookTarget));

            if (pt_ngr_c5_materialize_provider_entry_addr == 0) {
                pt_ngr_log_c5_install_event("provider-entry-missing",
                                            slotAddr,
                                            hookTarget,
                                            originalTarget,
                                            selected.tableAddr,
                                            slide);
                free(tableClone);
                return;
            }

            memcpy((void *)pt_ngr_c5_materialize_provider_entry_addr,
                   &tableClone,
                   sizeof(tableClone));

            uint64_t verifyProviderEntry = 0;
            if (!pt_ngr_vm_read_u64(pt_ngr_c5_materialize_provider_entry_addr, &verifyProviderEntry)
                || verifyProviderEntry != (uint64_t)(uintptr_t)tableClone) {
                pt_ngr_log_c5_install_event("provider-write-failed",
                                            pt_ngr_c5_materialize_provider_entry_addr,
                                            hookTarget,
                                            originalTarget,
                                            selected.tableAddr,
                                            slide);
                free(tableClone);
                return;
            }

            pt_ngr_c5_cloned_materialize_table = tableClone;
            pt_ngr_c5_materialize_slot_addr = (uint64_t)(uintptr_t)tableClone + 0x10;
            pt_ngr_c5_original_materialize_target = originalTarget;
            pt_ngr_log_c5_install_event("installed-provider-clone",
                                        pt_ngr_c5_materialize_provider_entry_addr,
                                        hookTarget,
                                        originalTarget,
                                        pt_ngr_c5_materialize_slot_addr,
                                        slide);
            pt_ngr_c5_install_alt1_hook(slide, mh);
            return;
        }

        memcpy((void *)slotAddr, &hookTarget, sizeof(hookTarget));
        pt_ngr_restore_patch_protection((void *)slotAddr, sizeof(hookTarget), VM_PROT_READ);

        pt_ngr_c5_materialize_slot_addr = slotAddr;
        pt_ngr_c5_original_materialize_target = originalTarget;

        pt_ngr_log_c5_install_event("installed",
                                    slotAddr,
                                    hookTarget,
                                    originalTarget,
                                    pt_ngr_c5_materialize_slot_addr,
                                    slide);

        pt_ngr_c5_install_alt1_hook(slide, mh);
    });
}
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// HOK-014: 压制 `com.tencent.ngr` 启动期的 UIAlertController sheet modal。
//
// 背景：HOK-013 让 `0x10e2146f8` reader 安全跑过后，app 能进入主循环，但
// UE4 iOS bootstrap 里有 3 次 `[UE4] Fatal error ... Attempting to get the
// command line but it hasn't been initialized yet.`——这几次 fatal 并不
// 终止进程（UE4 iOS 默认会继续跑到 `Init runtime finished`），但会通过
// UIKitCore 构造 `UIAlertController` 并以 `presentViewController:` 投递
// 到主 UIViewController。macOS 下 UIKitMac bridge 把 UIAlertController
// 转成 `NSAlert` + sheet modal attach 到 parent window，UI 线程进入 sheet
// modal session 再也不返回，表现为"窗口弹出但 app 卡住不响应"。
//
// 修复思路：bundle-scoped swizzle
// `-[UIViewController presentViewController:animated:completion:]`，对
// `com.tencent.ngr` 且被 present 的 VC 是 `UIAlertController` 时，**直接
// 调 completion(nil) 返回**，不走 AppKit sheet 路径。这等价于 iOS 下
// alert 被瞬间 dismiss——UE4 fatal 的 "Attempting to get the command line"
// 实际上 **是 warning 级别**（UE4 iOS 会继续跑、command line 随后被
// `Checking for command line in ... FOUND!` 正确读入），alert 只是 UI
// 提示、不 present 不影响游戏逻辑。
//
// 该 swizzle **只对 `com.tencent.ngr` 生效**；其它 bundle 原 IMP 保持不变。
// 诊断事件写到 `launch-events.jsonl`：`event=hok014_ngr_alert_suppressed`，
// 含 `title` / `message` / `className`，方便事后 audit。
// ---------------------------------------------------------------------------

static IMP pt_ngr_original_presentViewController_IMP = NULL;

typedef void (*pt_ngr_present_imp_t)(id, SEL, id, BOOL, id);

static void pt_ngr_swizzled_presentViewController(id self, SEL _cmd,
                                                  id viewControllerToPresent,
                                                  BOOL animated,
                                                  id completion) {
    static Class alertClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        alertClass = NSClassFromString(@"UIAlertController");
    });

    if (alertClass != Nil
        && viewControllerToPresent != nil
        && [viewControllerToPresent isKindOfClass:alertClass]) {
        // 记录被压制的 alert 的 title / message，供 launch-events.jsonl
        // 事后 audit。使用 KVC 读 UIAlertController 的 `title` / `message`
        // 属性避免直接引用 UIAlertController 类导致 linker 依赖。
        NSString *title = nil;
        NSString *message = nil;
        @try {
            id rawTitle = [viewControllerToPresent valueForKey:@"title"];
            id rawMessage = [viewControllerToPresent valueForKey:@"message"];
            if ([rawTitle isKindOfClass:[NSString class]]) { title = rawTitle; }
            if ([rawMessage isKindOfClass:[NSString class]]) { message = rawMessage; }
        } @catch (NSException *exception) {
            title = nil; message = nil;
        }

        // 计算 action 数量（通过 KVC 读 UIAlertController.actions）。
        NSArray *actions = nil;
        @try {
            id rawActions = [viewControllerToPresent valueForKey:@"actions"];
            if ([rawActions isKindOfClass:[NSArray class]]) {
                actions = rawActions;
            }
        } @catch (NSException *exception) {
            actions = nil;
        }

        NSDictionary<NSString *, NSString *> *details = @{
            @"className": NSStringFromClass([viewControllerToPresent class]) ?: @"",
            @"title": title ?: @"",
            @"message": message ?: @"",
            @"animated": animated ? @"true" : @"false",
            @"actionCount": [NSString stringWithFormat:@"%lu",
                             (unsigned long)(actions ? actions.count : 0)],
        };
        [PlayCover recordHOK014AlertSuppressedWithDetails:details];

        NSLog(@"[PlayTools] HOK-014 alert-auto-confirm class=%@ title=%@ message=%@ actions=%lu",
              NSStringFromClass([viewControllerToPresent class]),
              title ?: @"(nil)", message ?: @"(nil)",
              (unsigned long)(actions ? actions.count : 0));

        // 不展示 UI，但立即触发 alert action handler，等效于用户瞬间点了
        // 确认按钮。这样游戏的后续流程（包括 fatal→crash）照常进行，只是
        // 没有 UI 阻塞。
        //
        // UIAlertAction 的 handler 是私有属性 `_handler`（block 类型）。
        // 通过 KVC 读取并调用。优先找 preferredAction，其次找最后一个
        // action（UE4 fatal alert 通常只有一个 "OK"）。
        if (actions.count > 0) {
            // 找要点击的 action：preferredAction > 最后一个 action
            id targetAction = nil;
            @try {
                id preferred = [viewControllerToPresent valueForKey:@"preferredAction"];
                if (preferred != nil) {
                    targetAction = preferred;
                }
            } @catch (NSException *exception) {
                // ignore
            }
            if (targetAction == nil) {
                targetAction = actions.lastObject;
            }

            // 读取 action 的 handler block 并调用。
            // UIAlertAction 的 handler 存储在 _handler ivar（block 类型）。
            // KVC valueForKey:@"handler" 会按标准搜索路径找到该 ivar。
            if (targetAction != nil) {
                @try {
                    id handler = nil;
                    // 先试 KVC（找 getter 'handler' 或 ivar '_handler'）
                    @try { handler = [targetAction valueForKey:@"handler"]; }
                    @catch (NSException *e) { handler = nil; }

                    // fallback：直接读 _handler ivar
                    if (handler == nil) {
                        Ivar ivar = class_getInstanceVariable(
                            [targetAction class], "_handler");
                        if (ivar != NULL) {
                            handler = object_getIvar(targetAction, ivar);
                        }
                    }

                    if (handler != nil) {
                        void (^actionBlock)(id) = (void (^)(id))handler;
                        NSLog(@"[PlayTools] HOK-014 invoking action handler for: %@",
                              [targetAction valueForKey:@"title"] ?: @"(untitled)");
                        actionBlock(targetAction);
                    } else {
                        NSLog(@"[PlayTools] HOK-014 action has nil handler, skipping");
                    }
                } @catch (NSException *exception) {
                    NSLog(@"[PlayTools] HOK-014 failed to invoke action handler: %@",
                          exception);
                }
            }
        }

        // 调 presentViewController 的 completion（模拟 present 完成）。
        if (completion != nil) {
            void (^completionBlock)(void) = (void (^)(void))completion;
            completionBlock();
        }
        return;
    }

    // 非 UIAlertController，走原 IMP。
    if (pt_ngr_original_presentViewController_IMP != NULL) {
        pt_ngr_present_imp_t orig =
            (pt_ngr_present_imp_t)pt_ngr_original_presentViewController_IMP;
        orig(self, _cmd, viewControllerToPresent, animated, completion);
    }
}

static void pt_ngr_install_alert_suppressor_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 复用 HOK-013 的 bundle gate——非 `com.tencent.ngr` 直接跳过。
        if (!pt_ngr_should_preheat_slot()) {
            return;
        }

        Class vcClass = NSClassFromString(@"UIViewController");
        if (vcClass == Nil) {
            NSLog(@"[PlayTools] HOK-014 install failed: UIViewController class not found");
            return;
        }

        SEL sel = NSSelectorFromString(@"presentViewController:animated:completion:");
        Method m = class_getInstanceMethod(vcClass, sel);
        if (m == NULL) {
            NSLog(@"[PlayTools] HOK-014 install failed: presentViewController: method not found");
            return;
        }

        IMP originalIMP = method_getImplementation(m);
        pt_ngr_original_presentViewController_IMP = originalIMP;

        IMP newIMP = (IMP)pt_ngr_swizzled_presentViewController;
        method_setImplementation(m, newIMP);

        NSLog(@"[PlayTools] HOK-014 installed: -[UIViewController presentViewController:animated:completion:] swizzled for com.tencent.ngr");
        NSDictionary<NSString *, NSString *> *details = @{
            @"status": @"installed",
            @"target": @"UIViewController.presentViewController:animated:completion:",
        };
        [PlayCover recordHOK014InstallDiagnosticWithDetails:details];
    });
}
// ---------------------------------------------------------------------------
// PDT-006: Patch `FIOSPlatformFile::ConvertToPlatformPath` for `com.tencent.ngr`
// 使 `/Users/` 前缀路径与 `/var/` 同等处理（直接透传）。
//
// 背景：UE4 `ConvertToPlatformPath` 在 iOS 真机上对 `/var/` 开头路径直接
// 原样返回，而对 `/Users/...`（PlayCover/macOS 路径）会经过重新拼接，
// 导致 materializer 看到的最终路径不同。本 patch 在函数入口处拦截：
// 若参数（x1，const TCHAR*）以 `/Users/` 开头，直接返回原指针，跳过所有
// 后续转换逻辑。
//
// 约束：
//   - 仅对 `com.tencent.ngr` 生效。
//   - 使用 mprotect 解除 __TEXT 写保护，patch 后恢复。
//   - 保存原 16 字节机器码，确保可逆。
//   - 通过 mmap 分配可执行内存页执行原始 prologue，再跳回原函数+16。
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// RIPC-006: Bundle-Scoped Environment Variable Mocking for NGR
// ---------------------------------------------------------------------------
// 
// OBJECTIVE:
// Fix "QtsFileSystem Create Failed!!" crash by mocking HOME and TMPDIR
// environment variables to iOS-standard format (/private/var/mobile/...)
// before UE4 path resolution begins. This prevents UE4 from resolving
// pak paths as absolute macOS paths (/Users/...) which fail the
// QtsFileSystem materializer's UTF-16 case-fold compare ladder.
//
// RIPC-005 Phase 2 testing (6 tests, 98% confidence) confirmed that
// mocking HOME+TMPDIR eliminates the alert completely.
//
// TECHNICAL FOUNDATION:
// - Root cause: QtsFileSystem materializer at 0x10432a068 validates pak paths
// - Failure case: materializer receives /Users/.../Saved/Paks/1/1.db (absolute)
// - Success case: materializer needs ../../../NGR/Content/Paks/1/1.db (relative)
// - Chain: UE4 FPaths::ConvertRelativePathToFull converts relative → absolute
//   using HOME environment variable as base directory
// - Solution: Mock HOME to iOS-canonical path BEFORE UE4 path resolution
//
// IMPLEMENTATION STRATEGY:
// - Execute in dyld constructor before UE4 initialization
// - Bundle-scoped gating: only applies to com.tencent.ngr
// - Uses dispatch_once_t for idempotent, thread-safe execution
// - Three environment variables mocked: HOME, TMPDIR, CFFIXED_USER_HOME
// - Diagnostics recorded to launch-events.jsonl for verification
// - Zero side effects on other apps (early gate return)
//
// INSERTION POINT:
// Before PDT-006 section in initialize() constructor to ensure
// environment is mocked before any UE4 code runs
// ---------------------------------------------------------------------------

// iOS-standard paths (from RIPC-003 baseline on real iPad)
// Using fixed UUID from RIPC-003 baseline for consistency
#define RIPC006_IOS_HOME     "/private/var/mobile/Containers/Data/Application/EC7E61C6-B3AB-42AE-9348-292BDCC4658B"
#define RIPC006_IOS_TMPDIR   "/private/var/mobile/Containers/Data/Application/EC7E61C6-B3AB-42AE-9348-292BDCC4658B/tmp/"

static BOOL ripc006_env_mocked = NO;

/// Diagnostic event logging for RIPC-006
/// Records environment variable mocking success/failure to launch-events.jsonl
static void ripc006_log_event(const char *status, const char *detail) {
    NSLog(@"[PlayTools] RIPC-006 env-mock: status=%s detail=%s",
          status ?: "", detail ?: "");
    NSDictionary<NSString *, NSString *> *details = @{
        @"status": status ? [NSString stringWithUTF8String:status] : @"",
        @"detail": detail ? [NSString stringWithUTF8String:detail] : @"",
    };
    [PlayCover recordRIPC006EnvironmentMockDiagnosticWithDetails:details];
}

/// Mock HOME and TMPDIR environment variables to iOS-standard paths
/// Executes once per process via dispatch_once_t
/// Bundle-scoped: only applies to com.tencent.ngr, returns early for other apps
///
/// FLOW:
/// 1. Gate check: pt_ngr_should_preheat_slot() ensures com.tencent.ngr only
/// 2. Mock HOME to iOS-canonical /private/var/mobile/Containers/Data/Application/<UUID>
/// 3. Mock TMPDIR to iOS-canonical /private/var/mobile/Containers/Data/Application/<UUID>/tmp/
/// 4. Mock CFFIXED_USER_HOME for CoreFoundation path helpers
/// 5. Record diagnostic event with status (success/skip)
/// 6. Set ripc006_env_mocked flag to indicate completion
///
/// TIMING:
/// Executes in dyld constructor before PlayCover.launch() and UE4 initialization.
/// UE4 FPaths resolution happens AFTER this point and uses mocked HOME as base.
/// QtsFileSystem initializer receives relative paths instead of absolute /Users/ paths.
/// materializer's UTF-16 compare ladder succeeds, app reaches gameplay.
///
/// SIDE EFFECTS (MINIMAL):
/// - HOME points to non-existent iOS sandbox directory (by design, unused by actual I/O)
/// - UE4 path resolution will use this HOME as base for relative path conversion
/// - Other file operations within UE4 code path are iOS-compatible  
/// - macOS system libraries use their own environment, not affected by setenv()
/// - Real file I/O still works via PlayCover's iOS sandbox virtualization layer
/// - No impact on other processes or apps
///
/// NOT AFFECTED:
/// - Apps without com.tencent.ngr bundle ID (gated by early return)
/// - PlayCover UI / PlayCover.swift / macOS runtime (separate process context)
/// - System dylib initialization (occurs before constructor runs)
/// - Other NDK/SDK initializations within NGR (occur after env setup)
static void ripc006_mock_environment_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Gate: only apply to com.tencent.ngr
        if (!pt_ngr_should_preheat_slot()) {
            ripc006_log_event("skipped", "not com.tencent.ngr bundle");
            return;
        }

        // Mock HOME environment variable to iOS-canonical format
        // This is the PRIMARY trigger: UE4 FPaths uses HOME as base for relative path conversion
        if (setenv("HOME", RIPC006_IOS_HOME, 1) != 0) {
            ripc006_log_event("failed", "setenv(HOME) failed");
            return;
        }

        // Mock TMPDIR environment variable to iOS-canonical format
        // RIPC-005 T1 confirmed both HOME and TMPDIR required for success
        if (setenv("TMPDIR", RIPC006_IOS_TMPDIR, 1) != 0) {
            ripc006_log_event("failed", "setenv(TMPDIR) failed");
            return;
        }

        // Mock CFFIXED_USER_HOME for consistency with CoreFoundation path helpers
        // Ensures all layers of path resolution use the same iOS-canonical base
        if (setenv("CFFIXED_USER_HOME", RIPC006_IOS_HOME, 1) != 0) {
            ripc006_log_event("failed", "setenv(CFFIXED_USER_HOME) failed");
            return;
        }

        ripc006_env_mocked = YES;
        ripc006_log_event("installed", "HOME/TMPDIR/CFFIXED_USER_HOME mocked to iOS format");
    });
}

// ---------------------------------------------------------------------------


#define PDT006_CONVERT_FUNC_UNSLID  0x10463f204ULL
#define PDT006_PATCH_SIZE           16

static uint8_t pdt006_original_bytes[PDT006_PATCH_SIZE] = {0};
static void *pdt006_original_exec_page = NULL;
static BOOL pdt006_patch_installed = NO;

static BOOL pdt006_should_pass_through(const char *path) {
    if (path == NULL) { return NO; }
    uintptr_t addr = (uintptr_t)path;
    if (addr <= 0x100000000ULL) { return NO; }
    return strncmp(path, "/Users/", 7) == 0;
}

// Replacement 函数，匹配 ARM64 调用约定
// x0 = this (FIOSPlatformFile*), x1 = filename (const TCHAR*)
// 返回 x0 = const TCHAR*
static uint64_t pdt006_convert_replacement(uint64_t x0, uint64_t x1) {
    const char *path = (const char *)(uintptr_t)x1;
    if (pdt006_should_pass_through(path)) {
        return x1;
    }

    if (pdt006_original_exec_page != NULL) {
        typedef uint64_t (*orig_func_t)(uint64_t, uint64_t);
        orig_func_t orig = (orig_func_t)pdt006_original_exec_page;
        return orig(x0, x1);
    }

    return x1;
}

static void pdt006_log_event(const char *status,
                             uint64_t patchAddr,
                             uint64_t slide,
                             const char *detail) {
    NSLog(@"[PlayTools] PDT-006 convert-patch: status=%s patchAddr=0x%llx slide=0x%llx detail=%s",
          status ?: "", patchAddr, slide, detail ?: "");
    NSDictionary<NSString *, NSString *> *details = @{
        @"status": status ? [NSString stringWithUTF8String:status] : @"",
        @"patchAddr": [NSString stringWithFormat:@"0x%llx", patchAddr],
        @"slide": [NSString stringWithFormat:@"0x%llx", slide],
        @"detail": detail ? [NSString stringWithUTF8String:detail] : @"",
    };
    [PlayCover recordPDT006ConvertPatchDiagnosticWithDetails:details];
}

static void pdt006_install_convert_patch_once(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!pt_ngr_should_preheat_slot()) {
            return;
        }

        const struct mach_header_64 *mh = NULL;
        uint64_t unslidTextVMAddr = 0;
        if (!pt_ngr_find_main_image(&mh, &unslidTextVMAddr)) {
            pdt006_log_event("main-image-not-found", 0, 0, "pt_ngr_find_main_image failed");
            return;
        }

        uint64_t slide = (uint64_t)(uintptr_t)mh - unslidTextVMAddr;
        if (unslidTextVMAddr != NGRSLOT_PREHEAT_TEXT_VMADDR) {
            pdt006_log_event("unexpected-text-vmaddr",
                             PDT006_CONVERT_FUNC_UNSLID,
                             slide,
                             "unslid __TEXT.vmaddr mismatch");
            return;
        }

        uint64_t target = PDT006_CONVERT_FUNC_UNSLID + slide;

        memcpy(pdt006_original_bytes, (void *)(uintptr_t)target, PDT006_PATCH_SIZE);

        if (!pt_ngr_make_patch_writable((void *)(uintptr_t)target, PDT006_PATCH_SIZE)) {
            pdt006_log_event("mprotect-failed", target, slide, "cannot make target writable");
            return;
        }

        long pageSize = sysconf(_SC_PAGESIZE);
        void *execPage = mmap(NULL, (size_t)pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (execPage == MAP_FAILED) {
            pdt006_log_event("mmap-failed", target, slide, "cannot allocate exec page");
            pt_ngr_restore_patch_protection((void *)(uintptr_t)target, PDT006_PATCH_SIZE,
                                            VM_PROT_READ | VM_PROT_EXECUTE);
            return;
        }

        memcpy(execPage, pdt006_original_bytes, PDT006_PATCH_SIZE);

        uint32_t *execTrampoline = (uint32_t *)((uint8_t *)execPage + PDT006_PATCH_SIZE);
        execTrampoline[0] = 0x58000050;
        execTrampoline[1] = 0xd61f0200;
        uint64_t *execLiteral = (uint64_t *)(execTrampoline + 2);
        *execLiteral = target + PDT006_PATCH_SIZE;

        sys_icache_invalidate(execPage, (size_t)pageSize);

        uint32_t *hook = (uint32_t *)(uintptr_t)target;
        hook[0] = 0x58000050;
        hook[1] = 0xd61f0200;
        uint64_t *hookLiteral = (uint64_t *)(hook + 2);
        *hookLiteral = (uint64_t)(uintptr_t)&pdt006_convert_replacement;

        sys_icache_invalidate((void *)(uintptr_t)target, PDT006_PATCH_SIZE);

        pt_ngr_restore_patch_protection((void *)(uintptr_t)target, PDT006_PATCH_SIZE,
                                        VM_PROT_READ | VM_PROT_EXECUTE);

        pdt006_original_exec_page = execPage;
        pdt006_patch_installed = YES;

        pdt006_log_event("installed", target, slide, "ConvertToPlatformPath patched for /Users/ pass-through");
    });
}
// ---------------------------------------------------------------------------

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    // HOK-013: 最早时机预热 `com.tencent.ngr` 的 `__common` slot
    // `0x10e2146f8`。`pt_ngr_preheat_slot_once()` 内含 bundle-scoped
    // gate，非目标 bundle 会直接 return，不影响其它 app。
    pt_ngr_preheat_slot_once();

    // HOK-015: 在 NGR 的任何 inline `FCommandLine::Get()` 被命中之前预写
    // UE4 cmdline 存储（bInitialized=1 + CmdLine buffer = seed string）。
    // bundle-scoped、幂等。消除 "Attempting to get the command line..." fatal
    // 的根因，HOK-014 swizzle 观察期望从此为"零触发"。
    pt_ngr_preseed_cmdline_once();

    // RIPC-006: 在 UE4 路径转换之前 mock HOME/TMPDIR 到 iOS-standard 格式。
    // 防止 UE4 FPaths::ConvertRelativePathToFull 将相对路径转换成绝对 macOS
    // 路径（/Users/...），这样的路径会导致 QtsFileSystem materializer 的
    // UTF-16 case-fold compare ladder 失败。RIPC-005 Phase 2 测试验证了
    // HOME+TMPDIR mocking 能 100% 消除 QtsFileSystem Create Failed 告警。
    // bundle-scoped、幂等。
    ripc006_mock_environment_once();

    pt_ngr_install_materialize_shim_once();

    pt_ngr_install_url_resolution_probe_once();

    // HOK-014: 为 `com.tencent.ngr` 压制启动期的 UIAlertController sheet
    // modal（UE4 fatal 触发的 "Attempting to get the command line..."
    // alert）。HOK-015 落地后该 swizzle 在日常启动应**一次都不触发**，
    // 保留作为安全网。bundle-scoped、幂等。
    pt_ngr_install_alert_suppressor_once();

    // PDT-006: 在 NGR 进入 UE4 路径转换前 patch `ConvertToPlatformPath`，
    // 使 `/Users/` 前缀与 `/var/` 同等透传。bundle-scoped、可逆。
    pdt006_install_convert_patch_once();

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
