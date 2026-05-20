/**
 * harvester_probe.m — R4.1 Harvester API 验证探针
 *
 * 目标：验证 GTHarvesterGetData/GetMetadata/GetTexturePlane/GetTexturePlaneCount
 *       可直接解析 .gputrace 中的资源 blob 并提取纹理/buffer 数据。
 *
 * 编译：
 *   clang -framework Foundation -framework Metal -ldl -o harvester_probe harvester_probe.m
 *
 * 用法：
 *   ./harvester_probe /path/to/capture.gputrace
 *
 * 发现（R4.1）：
 *   - Harvester 函数是纯数据解析器，操作 .gputrace 中预存的资源 blob
 *   - 纹理 blob 带有 "capture\0" (0x0063617074757265) 的 8 字节 magic header
 *   - 函数签名：GTHarvesterGetXxx(void *blob, uint64_t blob_size, ...) → 返回数据指针/计数
 *   - 不需要 replay 运行时状态，可完全离线使用
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

// Harvester 函数指针类型
typedef void* (*GTHarvesterGetData_fn)(const void *blob, uint64_t blob_size);
typedef void* (*GTHarvesterGetMetadata_fn)(const void *blob, uint64_t blob_size);
typedef void* (*GTHarvesterGetTexturePlane_fn)(const void *blob, uint64_t plane_index);
typedef uint64_t (*GTHarvesterGetTexturePlaneCount_fn)(const void *blob);

static void print_hex(const uint8_t *data, size_t len, size_t max_print) {
    size_t print_len = len < max_print ? len : max_print;
    for (size_t i = 0; i < print_len; i++) {
        if (i > 0 && i % 16 == 0) fprintf(stdout, "\n    ");
        fprintf(stdout, "%02x ", data[i]);
    }
    if (len > max_print) fprintf(stdout, "...(total %zu bytes)", len);
    fprintf(stdout, "\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path-to-.gputrace>\n", argv[0]);
            return 1;
        }

        const char *gputrace_path = argv[1];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *basePath = [NSString stringWithUTF8String:gputrace_path];

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:basePath isDirectory:&isDir] || !isDir) {
            fprintf(stderr, "[ERROR] Path does not exist or is not a directory: %s\n", gputrace_path);
            return 2;
        }
        fprintf(stdout, "[INFO] .gputrace: %s\n", gputrace_path);

        // --- dlopen GPUToolsReplay ---
        const char *fw_path = "/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay";
        void *handle = dlopen(fw_path, RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "[ERROR] dlopen failed: %s\n", dlerror());
            return 3;
        }
        fprintf(stdout, "[INFO] dlopen GPUToolsReplay success\n");

        // --- dlsym Harvester 函数 ---
        GTHarvesterGetData_fn getData = (GTHarvesterGetData_fn)dlsym(handle, "GTHarvesterGetData");
        GTHarvesterGetMetadata_fn getMetadata = (GTHarvesterGetMetadata_fn)dlsym(handle, "GTHarvesterGetMetadata");
        GTHarvesterGetTexturePlane_fn getTexturePlane = (GTHarvesterGetTexturePlane_fn)dlsym(handle, "GTHarvesterGetTexturePlane");
        GTHarvesterGetTexturePlaneCount_fn getTexturePlaneCount = (GTHarvesterGetTexturePlaneCount_fn)dlsym(handle, "GTHarvesterGetTexturePlaneCount");

        fprintf(stdout, "[INFO] GTHarvesterGetData: %p\n", (void*)getData);
        fprintf(stdout, "[INFO] GTHarvesterGetMetadata: %p\n", (void*)getMetadata);
        fprintf(stdout, "[INFO] GTHarvesterGetTexturePlane: %p\n", (void*)getTexturePlane);
        fprintf(stdout, "[INFO] GTHarvesterGetTexturePlaneCount: %p\n", (void*)getTexturePlaneCount);

        if (!getData || !getMetadata || !getTexturePlane || !getTexturePlaneCount) {
            fprintf(stderr, "[ERROR] Failed to resolve one or more Harvester symbols\n");
            dlclose(handle);
            return 4;
        }

        // --- 在 .gputrace 中查找资源文件 ---
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
        NSString *file;
        NSString *testTextureFile = nil;
        NSString *testBufferFile = nil;

        while ((file = [enumerator nextObject])) {
            if ([file hasPrefix:@"MTLTexture-"] && !testTextureFile) {
                NSString *fullPath = [basePath stringByAppendingPathComponent:file];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                if ([attrs fileSize] >= 32768 && ![[attrs fileType] isEqualToString:NSFileTypeDirectory]) {
                    testTextureFile = fullPath;
                }
            }
            if ([file hasPrefix:@"MTLBuffer-"] && !testBufferFile) {
                NSString *fullPath = [basePath stringByAppendingPathComponent:file];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                if ([attrs fileSize] >= 1024 && ![[attrs fileType] isEqualToString:NSFileTypeDirectory]) {
                    testBufferFile = fullPath;
                }
            }
            if (testTextureFile && testBufferFile) break;
        }

        // === TEST 1: GTHarvesterGetData / GetMetadata on texture blob ===
        fprintf(stdout, "\n=== TEST 1: GTHarvesterGetData on texture blob ===\n");
        if (testTextureFile) {
            fprintf(stdout, "[TEST1] File: %s\n", [testTextureFile UTF8String]);
            NSData *blob = [NSData dataWithContentsOfFile:testTextureFile options:NSDataReadingMappedIfSafe error:nil];
            if (blob) {
                fprintf(stdout, "[TEST1] Blob size: %lu bytes\n", (unsigned long)[blob length]);
                fprintf(stdout, "[TEST1] Blob header: ");
                print_hex([blob bytes], 32, 32);

                // 验证 magic
                const uint8_t *bytes = [blob bytes];
                uint64_t magic = *(uint64_t*)bytes;
                fprintf(stdout, "[TEST1] Magic: 0x%016llx", (unsigned long long)magic);
                if (magic == 0x0063617074757265ULL) {
                    fprintf(stdout, " (matches 'capture\\0')\n");
                } else {
                    fprintf(stdout, " (NOT 'capture\\0')\n");
                }

                // GetMetadata
                fprintf(stdout, "\n[TEST1] Calling GTHarvesterGetMetadata(%p, %lu)...\n", [blob bytes], (unsigned long)[blob length]);
                @try {
                    void *metadata = getMetadata([blob bytes], [blob length]);
                    fprintf(stdout, "[TEST1] GTHarvesterGetMetadata returned: %p\n", metadata);
                    if (metadata) {
                        fprintf(stdout, "[TEST1] Metadata content (first 64 bytes):\n    ");
                        print_hex((const uint8_t*)metadata, 64, 64);
                    }
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST1] EXCEPTION in GetMetadata: %s: %s\n",
                            [[e name] UTF8String], [[e reason] UTF8String]);
                }

                // GetData
                fprintf(stdout, "\n[TEST1] Calling GTHarvesterGetData(%p, %lu)...\n", [blob bytes], (unsigned long)[blob length]);
                @try {
                    void *data = getData([blob bytes], [blob length]);
                    fprintf(stdout, "[TEST1] GTHarvesterGetData returned: %p\n", data);
                    if (data) {
                        ptrdiff_t offset = (uint8_t*)data - (uint8_t*)[blob bytes];
                        fprintf(stdout, "[TEST1] Data offset from blob start: +%td bytes\n", offset);
                        fprintf(stdout, "[TEST1] Data first 64 bytes:\n    ");
                        print_hex((const uint8_t*)data, 64, 64);

                        size_t avail = [blob length] - (size_t)offset;
                        fprintf(stdout, "[TEST1] Available payload: %zu bytes\n", avail);
                    }
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST1] EXCEPTION in GetData: %s: %s\n",
                            [[e name] UTF8String], [[e reason] UTF8String]);
                }

                // GetTexturePlaneCount
                fprintf(stdout, "\n[TEST1] Calling GTHarvesterGetTexturePlaneCount(%p)...\n", [blob bytes]);
                @try {
                    uint64_t planeCount = getTexturePlaneCount([blob bytes]);
                    fprintf(stdout, "[TEST1] GTHarvesterGetTexturePlaneCount returned: %llu\n", (unsigned long long)planeCount);

                    if (planeCount > 0 && planeCount < 100) {
                        for (uint64_t i = 0; i < planeCount && i < 4; i++) {
                            fprintf(stdout, "\n[TEST1] Calling GTHarvesterGetTexturePlane(%p, %llu)...\n",
                                    [blob bytes], (unsigned long long)i);
                            void *plane = getTexturePlane([blob bytes], i);
                            fprintf(stdout, "[TEST1] Plane %llu: %p\n", (unsigned long long)i, plane);
                            if (plane) {
                                ptrdiff_t off = (uint8_t*)plane - (uint8_t*)[blob bytes];
                                fprintf(stdout, "[TEST1] Plane %llu offset: +%td\n", (unsigned long long)i, off);
                                fprintf(stdout, "[TEST1] Plane %llu first 32 bytes:\n    ", (unsigned long long)i);
                                print_hex((const uint8_t*)plane, 32, 32);
                            }
                        }
                    }
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST1] EXCEPTION in GetTexturePlane: %s: %s\n",
                            [[e name] UTF8String], [[e reason] UTF8String]);
                }
            }
        } else {
            fprintf(stdout, "[TEST1] No suitable texture file found\n");
        }

        // === TEST 2: Buffer blob (should return NULL — no capture magic) ===
        fprintf(stdout, "\n=== TEST 2: GTHarvesterGetData on buffer blob (no capture magic expected) ===\n");
        if (testBufferFile) {
            fprintf(stdout, "[TEST2] File: %s\n", [testBufferFile UTF8String]);
            NSData *blob = [NSData dataWithContentsOfFile:testBufferFile options:NSDataReadingMappedIfSafe error:nil];
            if (blob) {
                fprintf(stdout, "[TEST2] Blob size: %lu bytes\n", (unsigned long)[blob length]);
                fprintf(stdout, "[TEST2] Blob header: ");
                print_hex([blob bytes], 16, 16);

                fprintf(stdout, "\n[TEST2] Calling GTHarvesterGetMetadata...\n");
                @try {
                    void *metadata = getMetadata([blob bytes], [blob length]);
                    fprintf(stdout, "[TEST2] Result: %p %s\n", metadata,
                            metadata ? "(unexpected non-NULL!)" : "(NULL as expected)");
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST2] EXCEPTION: %s\n", [[e reason] UTF8String]);
                }

                fprintf(stdout, "[TEST2] Calling GTHarvesterGetData...\n");
                @try {
                    void *data = getData([blob bytes], [blob length]);
                    fprintf(stdout, "[TEST2] Result: %p %s\n", data,
                            data ? "(unexpected non-NULL!)" : "(NULL as expected)");
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST2] EXCEPTION: %s\n", [[e reason] UTF8String]);
                }
            }
        } else {
            fprintf(stdout, "[TEST2] No suitable buffer file found\n");
        }

        // === TEST 3: Export parsed data to file ===
        fprintf(stdout, "\n=== TEST 3: Export parsed texture data to file ===\n");
        if (testTextureFile) {
            NSData *blob = [NSData dataWithContentsOfFile:testTextureFile options:NSDataReadingMappedIfSafe error:nil];
            if (blob && [blob length] >= 16) {
                @try {
                    void *data = getData([blob bytes], [blob length]);
                    if (data) {
                        ptrdiff_t offset = (uint8_t*)data - (uint8_t*)[blob bytes];
                        size_t dataLen = [blob length] - (size_t)offset;

                        NSString *outputPath = @"/tmp/harvester_texture_data.bin";
                        NSData *exportData = [NSData dataWithBytesNoCopy:data length:dataLen freeWhenDone:NO];
                        BOOL ok = [exportData writeToFile:outputPath atomically:YES];
                        if (ok) {
                            fprintf(stdout, "[TEST3] Exported %zu bytes to %s\n", dataLen, [outputPath UTF8String]);
                            fprintf(stdout, "[TEST3] SUCCESS: Texture data extracted via GTHarvesterGetData!\n");
                        } else {
                            fprintf(stderr, "[TEST3] Failed to write export file\n");
                        }
                    } else {
                        fprintf(stdout, "[TEST3] GetData returned NULL\n");
                    }
                } @catch (NSException *e) {
                    fprintf(stderr, "[TEST3] EXCEPTION: %s\n", [[e reason] UTF8String]);
                }
            }
        }

        fprintf(stdout, "\n=== SUMMARY ===\n");
        fprintf(stdout, "Harvester API: pure offline blob parsers for .gputrace resource files.\n");
        fprintf(stdout, "Magic: 'capture\\0' (0x0063617074757265) at offset 0.\n");
        fprintf(stdout, "No replay runtime state required.\n");

        dlclose(handle);
        return 0;
    }
}
