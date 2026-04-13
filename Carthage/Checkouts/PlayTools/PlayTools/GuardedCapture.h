//
//  GuardedCapture.h
//  PlayTools
//
//  RC-013: SIGSEGV-safe stopCapture wrapper for GPUToolsCapture compatibility.
//
//  GPUToolsCapture's internal GTTraceContextDumpEmptyCapture crashes with SIGSEGV
//  when stopCapture is called on a trace context with no captured GPU commands.
//  This C module provides a guarded wrapper using sigsetjmp/siglongjmp to recover
//  from the crash gracefully, since Swift cannot use setjmp/sigsetjmp directly
//  (they are annotated with returns_twice which Swift forbids).
//

#ifndef GuardedCapture_h
#define GuardedCapture_h

#import <Foundation/Foundation.h>

/// Block type for the stopCapture callback.
typedef void (^GuardedCaptureBlock)(void);

/// Execute a block (intended to call MTLCaptureManager.stopCapture) with SIGSEGV protection.
///
/// If a SIGSEGV occurs during execution of the block, the signal is caught via
/// sigsetjmp/siglongjmp, the previous signal handler is restored, and the function
/// returns NO. If the block completes normally, returns YES.
///
/// @param block The block to execute (should call manager.stopCapture()).
/// @return YES if the block completed normally, NO if SIGSEGV was caught and recovered.
BOOL PlayTools_guardedStopCapture(GuardedCaptureBlock _Nonnull block);

/// RC-014: Install nil-returning fallback stubs for GPUToolsCapture private selectors
/// (`traceStream`, `streamReference`) on NSObject.
///
/// This is called automatically via __attribute__((constructor)) at dyld load time,
/// BEFORE GPUToolsCapture's hooks can trigger MakeLayerInfos on CAMetalLayer instances.
/// This fixes the SIGABRT crash when using DYLD_INSERT_LIBRARIES startup-time injection
/// with apps like Genshin Impact whose Metal objects don't respond to these selectors.
///
/// Safe to call multiple times — only installs stubs once.
void PlayTools_installGPUToolsCaptureEarlyStubs(void);

/// RC-015: Enumerate all ObjC classes with "Capture", "GTTrace", or "GPUTools" prefix
/// and log them via NSLog. Uses pure C runtime calls to avoid Swift dynamic casting
/// crashes on partially-initialized classes.
void PlayTools_logGPUToolsCaptureClasses(void);

#endif /* GuardedCapture_h */
