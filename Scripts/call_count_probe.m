/**
 * call_count_probe.m — R7.1 evidence probe.
 *
 * Established (LYSK trace, macOS Sequoia, GPUToolsReplay framework loaded
 * from dyld shared cache):
 *
 *   GTMTLReplayController_playTo prologue contains:
 *       +0x024: mov  x20, x0        ; x20 = controller (arg0)
 *       +0x020: mov  x19, x1        ; x19 = target call index (arg1, w19 = w1)
 *       +0x038: add  x23, x0, #0x5000  ; x23 = controller + 0x5000
 *       +0x110: ldr  w8, [x23, #0x810] ; w8 = *(controller + 0x5810)
 *       +0x114: cmp  w8, w19
 *       +0x118: b.cs +0x1b4         ; HS = w8 (current) >= w19 (target) -> skip
 *
 *   Field semantics (verified at runtime):
 *     *(uint32_t *)(controller + 0x5810) is the LAST PLAYED CALL INDEX.
 *     - Before playAll       : 0
 *     - After playTo(N)      : N
 *     - After playAll        : total_call_count of the trace
 *       (LYSK capture_20260518_110050.gputrace -> 3425 after playAll)
 *
 *   So the bridge can derive total_call_count by running playAll once and
 *   reading [controller + 0x5810]; then for an --playto N request, compare N
 *   against total_call_count and return a structured error if N exceeds it.
 *
 * Build:
 *   clang -O0 -fobjc-arc -framework Foundation -framework Metal -ldl -lobjc \
 *         -o call_count_probe call_count_probe.m && codesign -s - call_count_probe
 *
 * Usage:
 *   ./call_count_probe <path-to-.gputrace>
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

typedef int   (*apr_pool_create_fn)(void **newpool, void *parent, void *abort_fn, void *allocator);
typedef void* (*makeDataSource_fn)(const char *path, void *pool);
typedef void  (*supportInit_fn)(void *device);
typedef void  (*initArgBuf_fn)(void *dataSource, void *device, void *objectMap);
typedef void  (*populateUnused_fn)(void *dataSource, void *objectMap);
typedef void* (*makeController_fn)(void *dataSource, void *pool, void *device, void *objectMap, void *arg4, void *arg5);
typedef int   (*playAll_fn)(void *controller);
typedef int   (*playTo_fn)(void *controller, uint32_t target);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: %s <.gputrace>\n", argv[0]); return 1; }
        const char *gputrace_path = argv[1];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;

        void *handle = dlopen("/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay", RTLD_NOW);
        if (!handle) return 3;

        void *gt_env = dlsym(handle, "GT_ENV");
        void *cli_fn = dlsym(handle, "GTMTLReplay_CLI");
        if (!gt_env || !cli_fn) return 4;

        apr_pool_create_fn fn_apr = (apr_pool_create_fn)resolve_bl(cli_fn, 0x50);
        makeDataSource_fn fn_ds = (makeDataSource_fn)resolve_bl(cli_fn, 0x13c);
        supportInit_fn fn_si = (supportInit_fn)resolve_bl(cli_fn, 0x888);
        initArgBuf_fn fn_iab = (initArgBuf_fn)resolve_bl(cli_fn, 0x898);
        populateUnused_fn fn_pu = (populateUnused_fn)resolve_bl(cli_fn, 0x8a4);
        makeController_fn fn_mc = (makeController_fn)resolve_bl(cli_fn, 0x954);
        playAll_fn fn_pa = (playAll_fn)dlsym(handle, "GTMTLReplayController_playAll");
        playTo_fn fn_pt = (playTo_fn)dlsym(handle, "GTMTLReplayController_playTo");

        void **gpp = (void **)((uint8_t *)gt_env - 0x30);
        if (*gpp == NULL) {
            void *blk = calloc(1, 0x4000);
            void *gp = (uint8_t *)blk + 0x100;
            *(uint64_t *)blk = 20; *(uint64_t *)((uint8_t *)blk + 8) = 20;
            *(void **)gp = blk; *(void **)((uint8_t *)gp + 0x30) = blk;
            *gpp = gp;
        }

        void *pool = NULL;
        fn_apr(&pool, NULL, NULL, NULL);
        if (!pool) return 5;

        void *dataSource = fn_ds(gputrace_path, pool);
        if (!dataSource) { fprintf(stderr, "no dataSource\n"); return 6; }

        if (fn_si) fn_si((__bridge void *)device);

        Class mapCls = NSClassFromString(@"GTMTLReplayObjectMap");
        id objectMap = [[mapCls alloc] performSelector:@selector(initWithDevice:) withObject:device];
        if (fn_iab) fn_iab(dataSource, (__bridge void *)device, (__bridge void *)objectMap);
        if (fn_pu)  fn_pu(dataSource, (__bridge void *)objectMap);

        void *controller = fn_mc(dataSource, pool, (__bridge void *)device, (__bridge void *)objectMap, NULL, NULL);
        if (!controller) return 7;

        // BEFORE playAll: read [controller + 0x5810]
        uint32_t before = *(uint32_t *)((uint8_t *)controller + 0x5810);
        fprintf(stdout, "[BEFORE playAll] *(controller+0x5810) = %u (0x%x)\n", before, before);

        // Sample a few neighboring offsets
        for (int off = 0x5800; off <= 0x5840; off += 4) {
            uint32_t v = *(uint32_t *)((uint8_t *)controller + off);
            fprintf(stdout, "  +0x%04x = %u (0x%x)\n", off, v, v);
        }

        // Try playTo with a small target to see how the field changes
        fprintf(stdout, "\nCalling playAll...\n");
        int rc = fn_pa(controller);
        fprintf(stdout, "playAll rc=%d\n", rc);

        uint32_t after = *(uint32_t *)((uint8_t *)controller + 0x5810);
        fprintf(stdout, "[AFTER playAll] *(controller+0x5810) = %u (0x%x)\n", after, after);

        for (int off = 0x5800; off <= 0x5840; off += 4) {
            uint32_t v = *(uint32_t *)((uint8_t *)controller + off);
            fprintf(stdout, "  +0x%04x = %u (0x%x)\n", off, v, v);
        }

        return 0;
    }
}
