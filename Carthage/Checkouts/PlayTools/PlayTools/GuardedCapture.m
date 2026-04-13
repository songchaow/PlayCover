//
//  GuardedCapture.m
//  PlayTools
//
//  RC-013: SIGSEGV-safe stopCapture wrapper using sigsetjmp/siglongjmp.
//  RC-014: Early compat stubs for GPUToolsCapture startup-time injection.
//

#import "GuardedCapture.h"
#import <signal.h>
#import <setjmp.h>
#import <objc/runtime.h>

// MARK: - RC-014: Early GPUToolsCapture compat stubs

/// Nil-returning IMP for GPUToolsCapture private selectors.
/// Used as a fallback so that MakeLayerInfos' `traceStream` / `streamReference`
/// calls return nil instead of triggering doesNotRecognizeSelector → SIGABRT.
static id guardedCapture_nilReturningStub(id self, SEL _cmd) {
    return nil;
}

/// Whether early stubs have already been installed.
static BOOL sEarlyStubsInstalled = NO;

void PlayTools_installGPUToolsCaptureEarlyStubs(void) {
    if (sEarlyStubsInstalled) return;
    sEarlyStubsInstalled = YES;

    // GPUToolsCapture's MakeLayerInfos calls these private selectors on Metal objects
    // (MTLDevice, CAMetalLayer, MTLTexture, etc.) through its Capture* proxy classes.
    // When using startup-time DYLD_INSERT_LIBRARIES injection, pre-existing Metal
    // objects (created before GPUToolsCapture wraps them) lack these methods.
    // Installing nil-returning fallbacks on NSObject prevents doesNotRecognizeSelector.
    const char *selectorNames[] = { "traceStream", "streamReference" };
    size_t count = sizeof(selectorNames) / sizeof(selectorNames[0]);

    Class nsObjectClass = [NSObject class];
    for (size_t i = 0; i < count; i++) {
        SEL sel = sel_registerName(selectorNames[i]);
        if (!class_getInstanceMethod(nsObjectClass, sel)) {
            // "@@:" = returns id, takes (id self, SEL _cmd)
            BOOL added = class_addMethod(nsObjectClass, sel,
                                         (IMP)guardedCapture_nilReturningStub, "@@:");
            NSLog(@"[PlayTools] RC-014: early stub NSObject.%s — added=%d",
                  selectorNames[i], (int)added);
        } else {
            NSLog(@"[PlayTools] RC-014: early stub NSObject.%s — already exists, skipped",
                  selectorNames[i]);
        }
    }
}

/// Constructor runs at dyld load time, before main() and before GPUToolsCapture's
/// CAMetalLayer hooks can trigger MakeLayerInfos on app-created layers.
__attribute__((constructor))
static void guardedCapture_earlyInit(void) {
    PlayTools_installGPUToolsCaptureEarlyStubs();
}

// MARK: - RC-015: GPUToolsCapture class enumeration (pure C)

void PlayTools_logGPUToolsCaptureClasses(void) {
    unsigned int classCount = 0;
    Class *classList = objc_copyClassList(&classCount);
    if (!classList) {
        NSLog(@"[PlayTools] RC-015: objc_copyClassList returned NULL");
        return;
    }

    // First pass: count matching classes
    NSMutableArray<NSString *> *captureClasses = [NSMutableArray array];
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classList[i]);
        if (!name) continue;
        if (strncmp(name, "Capture", 7) == 0 ||
            strncmp(name, "GTTrace", 7) == 0 ||
            strncmp(name, "GPUTools", 8) == 0) {
            [captureClasses addObject:[NSString stringWithUTF8String:name]];
        }
    }
    free(classList);

    [captureClasses sortUsingSelector:@selector(compare:)];
    NSLog(@"[PlayTools] RC-015: GPUToolsCapture classes found (%lu): %@",
          (unsigned long)captureClasses.count,
          [captureClasses componentsJoinedByString:@", "]);
}

// MARK: - RC-013: SIGSEGV-safe stopCapture wrapper

/// Thread-local state for the guarded capture region.
static __thread sigjmp_buf sJmpBuf;
static __thread volatile sig_atomic_t sInsideGuard = 0;

/// SIGSEGV handler: if we're inside the guarded region, longjmp back to safety.
static void guardedCapture_sigsegvHandler(int sig, siginfo_t *info, void *ctx) {
    if (sInsideGuard) {
        NSLog(@"[PlayTools] RC-013: SIGSEGV at addr %p caught inside stopCapture "
              @"(GTTraceContextDumpEmptyCapture), recovering via siglongjmp", info ? info->si_addr : NULL);
        siglongjmp(sJmpBuf, 1);
    }
    // Not inside our guard — restore default and re-raise for normal crash behavior.
    signal(SIGSEGV, SIG_DFL);
    raise(SIGSEGV);
}

BOOL PlayTools_guardedStopCapture(GuardedCaptureBlock _Nonnull block) {
    // Install our SIGSEGV handler, saving the old one.
    struct sigaction newAction;
    memset(&newAction, 0, sizeof(newAction));
    newAction.sa_sigaction = guardedCapture_sigsegvHandler;
    newAction.sa_flags = SA_SIGINFO;
    sigemptyset(&newAction.sa_mask);

    struct sigaction oldAction;
    sigaction(SIGSEGV, &newAction, &oldAction);

    BOOL success;
    sInsideGuard = 1;

    if (sigsetjmp(sJmpBuf, 1) == 0) {
        // Normal path: execute the block (calls manager.stopCapture()).
        block();
        success = YES;
    } else {
        // Recovery path: SIGSEGV was caught and we jumped back here.
        success = NO;
    }

    sInsideGuard = 0;

    // Restore previous handler.
    sigaction(SIGSEGV, &oldAction, NULL);

    return success;
}
