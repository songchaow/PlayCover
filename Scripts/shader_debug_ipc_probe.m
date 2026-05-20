/**
 * shader_debug_ipc_probe.m — R5.3b GTLLVMHelper IPC 连接探针
 *
 * 直接连接到 GTLLVMHelper 的 Unix domain socket，探测协议格式。
 *
 * 已知信息：
 *   - GTLLVMHelper 是 server (listen=true)
 *   - Socket: /tmp/unixsocketipc_gtd
 *   - 消息格式: 可能是 flatbuffers 或自定义二进制
 *   - GTMessageTransportIPC 结构已知
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -ldl -lobjc -o shader_debug_ipc_probe shader_debug_ipc_probe.m
 */

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <poll.h>
#import <errno.h>

#pragma mark - Socket helpers

static int connect_unix_socket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }
    return fd;
}

static ssize_t read_with_timeout(int fd, void *buf, size_t len, int timeout_ms) {
    struct pollfd pfd = {fd, POLLIN, 0};
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0) return ret; // timeout or error
    return read(fd, buf, len);
}

static void hex_dump(const uint8_t *data, size_t len, const char *label) {
    fprintf(stdout, "[%s] %zu bytes:\n", label, len);
    for (size_t i = 0; i < len && i < 256; i++) {
        if (i % 16 == 0) fprintf(stdout, "  %04zx: ", i);
        fprintf(stdout, "%02x ", data[i]);
        if (i % 16 == 15 || i == len - 1) {
            // ASCII
            int pad = 15 - (i % 16);
            for (int p = 0; p < pad; p++) fprintf(stdout, "   ");
            fprintf(stdout, " | ");
            int start = (int)(i - (i % 16));
            for (int j = start; j <= (int)i; j++) {
                fprintf(stdout, "%c", (data[j] >= 0x20 && data[j] < 0x7f) ? data[j] : '.');
            }
            fprintf(stdout, "\n");
        }
    }
    if (len > 256) fprintf(stdout, "  ... (%zu more bytes)\n", len - 256);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stdout, "=== R5.3b GTLLVMHelper IPC Probe ===\n\n");
        
        const char *socket_path = "/tmp/unixsocketipc_gtd";
        
        // Check socket exists
        if (access(socket_path, F_OK) != 0) {
            fprintf(stderr, "[ERROR] Socket not found: %s\n", socket_path);
            return 1;
        }
        fprintf(stdout, "[INFO] Socket: %s\n\n", socket_path);
        
        // ============================================================
        // TEST 1: Basic connection
        // ============================================================
        fprintf(stdout, "========== TEST 1: Connect to GTLLVMHelper ==========\n\n");
        
        int fd = connect_unix_socket(socket_path);
        if (fd < 0) {
            fprintf(stderr, "[ERROR] Cannot connect to socket\n");
            return 2;
        }
        fprintf(stdout, "[OK] Connected! fd=%d\n\n", fd);
        
        // ============================================================
        // TEST 2: Read initial data (server might send greeting)
        // ============================================================
        fprintf(stdout, "========== TEST 2: Check for Server Greeting ==========\n\n");
        
        uint8_t buf[4096];
        ssize_t n = read_with_timeout(fd, buf, sizeof(buf), 2000); // 2s timeout
        if (n > 0) {
            hex_dump(buf, n, "SERVER GREETING");
        } else if (n == 0) {
            fprintf(stdout, "[INFO] No greeting — server waits for client message first\n");
        } else {
            fprintf(stdout, "[INFO] No data within 2s — server is passive (waits for client)\n");
        }
        
        // ============================================================
        // TEST 3: Try sending a minimal message
        // ============================================================
        fprintf(stdout, "\n========== TEST 3: Protocol Probing ==========\n\n");
        
        // The IPC likely uses a length-prefixed binary protocol.
        // Common patterns:
        //   [4-byte length][payload]
        //   [4-byte msg_type][4-byte length][payload]
        //   [flatbuffer message]
        
        // Strategy: try sending a minimal "hello" and see what happens
        
        // Approach A: 4-byte length prefix = 0 (empty message)
        fprintf(stdout, "[PROBE A] Sending 4-byte zero (empty length-prefixed message)...\n");
        uint32_t zero = 0;
        ssize_t sent = write(fd, &zero, 4);
        fprintf(stdout, "  sent=%zd\n", sent);
        
        n = read_with_timeout(fd, buf, sizeof(buf), 2000);
        if (n > 0) {
            hex_dump(buf, n, "RESPONSE A");
        } else {
            fprintf(stdout, "  No response (timeout)\n");
        }
        
        close(fd);
        
        // ============================================================
        // TEST 4: Try with a different message format
        // ============================================================
        fprintf(stdout, "\n========== TEST 4: Alternative Protocol Probes ==========\n\n");
        
        // Reconnect
        fd = connect_unix_socket(socket_path);
        if (fd < 0) {
            fprintf(stderr, "[ERROR] Cannot reconnect\n");
            return 3;
        }
        
        // Approach B: Try NSKeyedArchiver format (GTLLVMHelper imports NSKeyedArchiver)
        // Send an archived NSDictionary with a "command" key
        NSDictionary *helloMsg = @{
            @"command": @"hello",
            @"version": @(1),
            @"clientType": @"replay"
        };
        
        NSError *archiveErr = nil;
        NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:helloMsg
                                               requiringSecureCoding:NO
                                                               error:&archiveErr];
        if (archived) {
            fprintf(stdout, "[PROBE B] Sending NSKeyedArchiver message (%lu bytes)...\n",
                    (unsigned long)[archived length]);
            
            // Try with length prefix
            uint32_t msgLen = (uint32_t)[archived length];
            write(fd, &msgLen, 4);
            write(fd, [archived bytes], [archived length]);
            
            n = read_with_timeout(fd, buf, sizeof(buf), 2000);
            if (n > 0) {
                hex_dump(buf, n, "RESPONSE B");
                
                // Try to unarchive response
                if (n > 4) {
                    uint32_t respLen = *(uint32_t *)buf;
                    fprintf(stdout, "  Possible length prefix: %u\n", respLen);
                    if (respLen > 0 && respLen <= n - 4) {
                        NSData *respData = [NSData dataWithBytes:buf+4 length:respLen];
                        @try {
                            id respObj = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class]
                                                                          fromData:respData error:nil];
                            if (respObj) {
                                fprintf(stdout, "  [DECODED] Response: %s\n", [[respObj description] UTF8String]);
                            }
                        } @catch (id e) {}
                    }
                }
            } else {
                fprintf(stdout, "  No response\n");
            }
        }
        
        close(fd);
        
        // ============================================================
        // TEST 5: Try raw bytes that might trigger a response
        // ============================================================
        fprintf(stdout, "\n========== TEST 5: Raw Byte Probes ==========\n\n");
        
        fd = connect_unix_socket(socket_path);
        if (fd < 0) { return 4; }
        
        // Try: single byte '1' (possible command ID)
        fprintf(stdout, "[PROBE C] Sending single byte 0x01...\n");
        uint8_t one = 1;
        write(fd, &one, 1);
        n = read_with_timeout(fd, buf, sizeof(buf), 1000);
        if (n > 0) { hex_dump(buf, n, "RESPONSE C"); }
        else { fprintf(stdout, "  No response\n"); }
        
        close(fd);
        
        // ============================================================
        // TEST 6: Larger message with header
        // ============================================================
        fprintf(stdout, "\n========== TEST 6: Structured Message Probe ==========\n\n");
        
        fd = connect_unix_socket(socket_path);
        if (fd < 0) { return 5; }
        
        // Try a message with: [clientIndex(4)][messageType(4)][length(4)][data...]
        // Based on GTMessageTransportIPC having clientIndex tracking
        struct {
            uint32_t clientIndex;
            uint32_t messageType;
            uint32_t dataLength;
            uint32_t payload[4]; // Some dummy data
        } __attribute__((packed)) msg = {0, 0, 16, {0, 0, 0, 0}};
        
        fprintf(stdout, "[PROBE D] Sending structured header (28 bytes)...\n");
        write(fd, &msg, sizeof(msg));
        
        n = read_with_timeout(fd, buf, sizeof(buf), 2000);
        if (n > 0) {
            hex_dump(buf, n, "RESPONSE D");
        } else {
            fprintf(stdout, "  No response\n");
        }
        
        // Now try just waiting for the server to talk after raw connection
        fprintf(stdout, "\n[PROBE E] Waiting 3 more seconds for any delayed response...\n");
        n = read_with_timeout(fd, buf, sizeof(buf), 3000);
        if (n > 0) {
            hex_dump(buf, n, "DELAYED RESPONSE");
        } else {
            fprintf(stdout, "  No delayed response\n");
        }
        
        close(fd);
        
        // ============================================================
        // TEST 7: Observe what Xcode sends (lsof on GTLLVMHelper)
        // ============================================================
        fprintf(stdout, "\n========== TEST 7: GTLLVMHelper Process Analysis ==========\n\n");
        
        // Check open files of GTLLVMHelper
        fprintf(stdout, "[INFO] GTLLVMHelper (PID 32192) open files:\n");
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/sbin/lsof";
        task.arguments = @[@"-p", @"32192"];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSPipe pipe];
        @try {
            [task launch];
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            // Filter for interesting lines
            for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
                if ([line containsString:@"unix"] || [line containsString:@"socket"] ||
                    [line containsString:@"pipe"] || [line containsString:@"LISTEN"] ||
                    [line containsString:@"gtd"] || [line containsString:@"tmp"]) {
                    fprintf(stdout, "  %s\n", [line UTF8String]);
                }
            }
        } @catch (id e) {
            fprintf(stdout, "  (lsof failed)\n");
        }

        // ============================================================
        // SUMMARY
        // ============================================================
        fprintf(stdout, "\n========== SUMMARY ==========\n\n");
        fprintf(stdout, "[INFO] Connection to GTLLVMHelper Unix socket succeeded.\n");
        fprintf(stdout, "[INFO] Protocol analysis will depend on responses received.\n");
        fprintf(stdout, "[INFO] GTLLVMHelper uses:\n");
        fprintf(stdout, "  - GTMessageTransportIPC (custom binary protocol)\n");
        fprintf(stdout, "  - Flatbuffers for data serialization\n");
        fprintf(stdout, "  - NSKeyedArchiver/Unarchiver (Foundation serialization)\n");
        fprintf(stdout, "  - Client indexing (supports multiple connections)\n");
        
        return 0;
    }
}
