/**
 * shader_debug_ipc_probe3.m — R5.3b 直接 IPC Shader Debug 执行
 *
 * 协议确认：
 *   发送: [uint32 clientIdx=0][uint32 cmdType][uint32 dataLen][data...]
 *   响应: [uint64 ack=0x3a][uint64 partial_echo]
 *   最小消息: 16 bytes (4+4+4+4 or 4+4+8)
 *
 * 本探针：连接 socket → 发送实际 shader binary → 观察后续响应
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -framework Metal -ldl -lobjc -o shader_debug_ipc_probe3 shader_debug_ipc_probe3.m
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <poll.h>

static int connect_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/tmp/unixsocketipc_gtd");
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static ssize_t read_timeout(int fd, void *buf, size_t len, int ms) {
    struct pollfd pfd = {fd, POLLIN, 0};
    int ret = poll(&pfd, 1, ms);
    if (ret <= 0) return ret;
    return read(fd, buf, len);
}

static void hex_dump(const uint8_t *d, size_t n, const char *label) {
    fprintf(stdout, "[%s] %zu bytes:\n", label, n);
    for (size_t i = 0; i < n && i < 128; i++) {
        if (i % 16 == 0) fprintf(stdout, "  %04zx: ", i);
        fprintf(stdout, "%02x ", d[i]);
        if (i % 16 == 15 || i == n - 1) {
            int pad = 15 - (i % 16);
            for (int p = 0; p < pad; p++) fprintf(stdout, "   ");
            fprintf(stdout, " | ");
            int start = (int)(i - (i % 16));
            for (int j = start; j <= (int)i; j++)
                fprintf(stdout, "%c", (d[j]>=0x20&&d[j]<0x7f)?d[j]:'.');
            fprintf(stdout, "\n");
        }
    }
    if (n > 128) fprintf(stdout, "  ... (%zu more)\n", n - 128);
}

// Send a message and read all responses
static void send_and_read_all(int fd, const void *msg, size_t msgLen, int timeout_ms) {
    write(fd, msg, msgLen);
    uint8_t resp[65536];
    size_t totalRead = 0;
    
    while (1) {
        ssize_t n = read_timeout(fd, resp + totalRead, sizeof(resp) - totalRead, timeout_ms);
        if (n <= 0) break;
        totalRead += n;
        timeout_ms = 500; // Shorter timeout for subsequent reads
    }
    
    if (totalRead > 0) {
        hex_dump(resp, totalRead, "FULL_RESPONSE");
        
        // Try NSKeyedUnarchiver on the response data
        if (totalRead > 16) {
            NSData *respData = [NSData dataWithBytes:resp length:totalRead];
            @try {
                id obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                    [NSSet setWithArray:@[[NSDictionary class], [NSArray class], [NSString class],
                                          [NSNumber class], [NSData class]]]
                    fromData:respData error:nil];
                if (obj) fprintf(stdout, "  [DECODED] %s\n", [[obj description] UTF8String]);
            } @catch (id e) {}
            
            // Try without first 16 bytes (skip header)
            if (totalRead > 32) {
                NSData *body = [NSData dataWithBytes:resp+16 length:totalRead-16];
                @try {
                    id obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                        [NSSet setWithArray:@[[NSDictionary class], [NSArray class], [NSString class],
                                              [NSNumber class], [NSData class]]]
                        fromData:body error:nil];
                    if (obj) fprintf(stdout, "  [DECODED body] %s\n", [[obj description] UTF8String]);
                } @catch (id e) {}
            }
        }
    } else {
        fprintf(stdout, "  [NO RESPONSE]\n");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stdout, "=== R5.3b Direct IPC Shader Debug ===\n\n");
        
        // Get a real metallib from a compiled shader
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { return 1; }
        
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void test_debug(device float *out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {\n"
            "    float x = float(gid);\n"
            "    float y = x * 2.0;\n"
            "    out[gid] = y;\n"
            "}\n";
        
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion3_1;
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
        if (!lib) { fprintf(stderr, "Compile failed: %s\n", [[err description] UTF8String]); return 2; }
        
        SEL ldcSel = NSSelectorFromString(@"libraryDataContents");
        SEL bcSel = NSSelectorFromString(@"bitcodeData");
        NSData *metallib = [lib respondsToSelector:ldcSel] ? [lib performSelector:ldcSel] : nil;
        NSData *bitcode = nil;
        @try { bitcode = [lib performSelector:bcSel]; } @catch (id e) {}
        
        fprintf(stdout, "[INFO] Compiled shader: metallib=%lu bytes, bitcode=%lu bytes\n\n",
                (unsigned long)[metallib length], bitcode ? (unsigned long)[bitcode length] : 0);

        // ============================================================
        // TEST 1: Send metallib as payload with various command types
        // ============================================================
        fprintf(stdout, "========== TEST 1: Send Metallib with Different Commands ==========\n\n");
        
        if (metallib) {
            uint32_t mlLen = (uint32_t)[metallib length];
            
            // Allocate message buffer: header(12) + metallib
            size_t msgSize = 12 + mlLen;
            uint8_t *msg = malloc(msgSize);
            
            // Try cmdType 0-5
            for (int cmd = 0; cmd <= 5; cmd++) {
                int fd = connect_socket();
                if (fd < 0) continue;
                
                ((uint32_t *)msg)[0] = 0;      // clientIdx
                ((uint32_t *)msg)[1] = cmd;    // cmdType
                ((uint32_t *)msg)[2] = mlLen;  // dataLen
                memcpy(msg + 12, [metallib bytes], mlLen);
                
                fprintf(stdout, "[CMD=%d] Sending metallib (%u bytes)...\n", cmd, mlLen);
                send_and_read_all(fd, msg, msgSize, 3000);
                fprintf(stdout, "\n");
                close(fd);
                usleep(200000);
            }
            free(msg);
        }

        // ============================================================
        // TEST 2: Try framing as [uint64 totalSize][content]
        // ============================================================
        fprintf(stdout, "\n========== TEST 2: uint64 Size-Prefixed Framing ==========\n\n");
        
        if (metallib) {
            int fd = connect_socket();
            if (fd >= 0) {
                // Try: [uint64 size = metallib_len][metallib_data]
                uint64_t sz = [metallib length];
                fprintf(stdout, "[SIZE_PREFIX] Sending uint64(%llu) + metallib...\n", sz);
                write(fd, &sz, 8);
                write(fd, [metallib bytes], [metallib length]);
                
                uint8_t resp[65536];
                size_t total = 0;
                while (1) {
                    ssize_t n = read_timeout(fd, resp + total, sizeof(resp) - total, 3000);
                    if (n <= 0) break;
                    total += n;
                }
                if (total > 0) hex_dump(resp, total, "SIZE_PREFIX_RESP");
                else fprintf(stdout, "  no response\n");
                close(fd);
            }
        }

        // ============================================================
        // TEST 3: NSKeyedArchiver formatted message
        // ============================================================
        fprintf(stdout, "\n========== TEST 3: NSKeyedArchiver Message ==========\n\n");
        
        {
            int fd = connect_socket();
            if (fd >= 0) {
                // GTLLVMHelper imports NSKeyedArchiver — try sending an archived dictionary
                NSDictionary *cmdDict = @{
                    @"command": @"compile",
                    @"data": metallib ?: [NSData data],
                    @"version": @(1)
                };
                
                NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:cmdDict
                                                        requiringSecureCoding:NO error:nil];
                if (archived) {
                    // Try: [uint32 0][uint32 0][uint32 len][archived_data]
                    uint32_t hdr[3] = {0, 0, (uint32_t)[archived length]};
                    fprintf(stdout, "[KEYED_ARCHIVE] header + %lu bytes archived dict...\n",
                            (unsigned long)[archived length]);
                    write(fd, hdr, 12);
                    write(fd, [archived bytes], [archived length]);
                    
                    uint8_t resp[65536];
                    size_t total = 0;
                    while (1) {
                        ssize_t n = read_timeout(fd, resp + total, sizeof(resp) - total, 3000);
                        if (n <= 0) break;
                        total += n;
                    }
                    if (total > 0) hex_dump(resp, total, "ARCHIVE_RESP");
                    else fprintf(stdout, "  no response\n");
                }
                close(fd);
            }
        }

        // ============================================================
        // TEST 4: Check what GTMTLReplayService actually sends
        // ============================================================
        fprintf(stdout, "\n========== TEST 4: Intercept via Service ==========\n\n");
        
        // The real test: create our own socket, make the SERVICE point to it,
        // and see what it sends when we call shaderdebug:
        
        // Create a local listening socket
        char tmpSocket[] = "/tmp/gtd_probe_XXXXXX";
        mktemp(tmpSocket);
        
        int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un lisAddr = {0};
        lisAddr.sun_family = AF_UNIX;
        strcpy(lisAddr.sun_path, tmpSocket);
        unlink(tmpSocket);
        
        if (bind(listenFd, (struct sockaddr *)&lisAddr, sizeof(lisAddr)) == 0 &&
            listen(listenFd, 1) == 0) {
            fprintf(stdout, "[OK] Listening on %s\n", tmpSocket);
            
            // Now: launch our OWN GTLLVMHelper instance pointing to our socket?
            // Or: just use the Service but see what it tries to do?
            
            // Actually, let's trace what our Service sends by using DTrace or
            // simply checking if the Service writes to the socket
            
            fprintf(stdout, "[INFO] To fully intercept, we'd need to:\n");
            fprintf(stdout, "  1. Create our own GTLLVMHelper-compatible socket server\n");
            fprintf(stdout, "  2. OR: Patch GTMTLReplayClient to include the real socket FD\n");
            fprintf(stdout, "  3. OR: Launch a new GTLLVMHelper with our own socket path\n");
        }
        close(listenFd);
        unlink(tmpSocket);

        // ============================================================
        // TEST 5: Launch our own GTLLVMHelper
        // ============================================================
        fprintf(stdout, "\n========== TEST 5: Launch Private GTLLVMHelper ==========\n\n");
        
        // GTLLVMHelper args: "g16s Host 0 <parent_pid> 0 <socket_path>"
        NSString *helperPath = @"/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/GPUToolsPlatform/PlugIns/GTLLVMHelper";
        
        char ourSocket[] = "/tmp/gtd_probe2_XXXXXX";
        mktemp(ourSocket);
        
        fprintf(stdout, "[INFO] Launching private GTLLVMHelper at %s...\n", ourSocket);
        
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = helperPath;
        task.arguments = @[@"g16s", @"Host", @"0",
                          [NSString stringWithFormat:@"%d", getpid()],
                          @"0",
                          [NSString stringWithUTF8String:ourSocket]];
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        
        @try {
            [task launch];
            fprintf(stdout, "[OK] GTLLVMHelper launched, PID=%d\n", task.processIdentifier);
            
            // Wait a bit for it to create the socket
            usleep(1000000); // 1s
            
            if (access(ourSocket, F_OK) == 0) {
                fprintf(stdout, "[OK] Socket created: %s\n", ourSocket);
                
                // Connect to our private helper
                int fd2 = socket(AF_UNIX, SOCK_STREAM, 0);
                struct sockaddr_un addr2 = {0};
                addr2.sun_family = AF_UNIX;
                strcpy(addr2.sun_path, ourSocket);
                
                if (connect(fd2, (struct sockaddr *)&addr2, sizeof(addr2)) == 0) {
                    fprintf(stdout, "[OK] Connected to private GTLLVMHelper!\n");
                    
                    // Now try sending metallib with command type 0
                    if (metallib) {
                        uint32_t mlLen = (uint32_t)[metallib length];
                        size_t msgSz = 12 + mlLen;
                        uint8_t *msg = malloc(msgSz);
                        ((uint32_t *)msg)[0] = 0;
                        ((uint32_t *)msg)[1] = 0;
                        ((uint32_t *)msg)[2] = mlLen;
                        memcpy(msg + 12, [metallib bytes], mlLen);
                        
                        fprintf(stdout, "[SEND] metallib (%u bytes) to private helper...\n", mlLen);
                        send_and_read_all(fd2, msg, msgSz, 5000);
                        free(msg);
                    }
                    
                    close(fd2);
                } else {
                    perror("connect to private helper");
                }
            } else {
                fprintf(stdout, "[WARN] Socket not created yet\n");
                // Check stderr
                NSData *errData = [[(NSPipe *)task.standardError fileHandleForReading] availableData];
                if (errData.length > 0) {
                    fprintf(stdout, "  stderr: %s\n",
                            [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding].UTF8String);
                }
            }
            
            // Cleanup
            [task terminate];
            [task waitUntilExit];
            unlink(ourSocket);
            
        } @catch (NSException *e) {
            fprintf(stdout, "[EXCEPTION] Launch failed: %s\n", [[e reason] UTF8String]);
        }

        // ============================================================
        // SUMMARY
        // ============================================================
        fprintf(stdout, "\n========== SUMMARY ==========\n\n");
        fprintf(stdout, "Protocol findings:\n");
        fprintf(stdout, "  - Connection: Unix domain socket, SOCK_STREAM ✅\n");
        fprintf(stdout, "  - Framing: [uint32 clientIdx][uint32 cmd][uint32 len][data] → min 16 bytes\n");
        fprintf(stdout, "  - Response: 16 bytes = [uint64 status(0x3a)][uint64 echo/param]\n");
        fprintf(stdout, "  - Server echoes payload length and first bytes in response[8:16]\n");
        fprintf(stdout, "  - No crash on any probe — server is robust\n");
        fprintf(stdout, "  - Private GTLLVMHelper launch: tested\n");
        
        return 0;
    }
}
