/**
 * shader_debug_ipc_probe2.m — R5.3b GTLLVMHelper IPC 协议逆向
 *
 * TEST 6 已确认：发送 {uint32 clientIdx, uint32 msgType, uint32 len, payload} 可获得响应
 * 响应格式：16 bytes = {0x3a, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0, 0, 0, 0}
 *
 * 本探针：系统性探测不同 messageType 的响应
 *
 * 编译：
 *   cd Scripts/ && clang -framework Foundation -ldl -lobjc -o shader_debug_ipc_probe2 shader_debug_ipc_probe2.m
 */

#import <Foundation/Foundation.h>
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

static void hex_line(const uint8_t *d, size_t n) {
    for (size_t i = 0; i < n && i < 64; i++) fprintf(stdout, "%02x ", d[i]);
    if (n > 64) fprintf(stdout, "...");
    fprintf(stdout, " | ");
    for (size_t i = 0; i < n && i < 64; i++) fprintf(stdout, "%c", (d[i]>=0x20&&d[i]<0x7f)?d[i]:'.');
    fprintf(stdout, "\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stdout, "=== R5.3b GTLLVMHelper Protocol Reverse Engineering ===\n\n");
        
        uint8_t resp[8192];
        
        // ============================================================
        // PHASE 1: Replay the exact working message from TEST 6
        // ============================================================
        fprintf(stdout, "========== PHASE 1: Confirm Protocol ==========\n\n");
        
        int fd = connect_socket();
        if (fd < 0) { fprintf(stderr, "Connect failed\n"); return 1; }
        
        // Original working message: 28 bytes
        // [clientIndex=0][messageType=0][dataLength=16][4x uint32 payload]
        // But wait — re-analyze: maybe the format is different
        // Let's try: [total_size (uint64)][payload]
        // Response was: 3a000000 00000000 10000000 00000000
        // = 58 (uint64_le), 16 (uint64_le)
        // Interesting: 58 = our sent size (28) + 30? Or something else
        
        // Let me try different sizes to see if response correlates
        
        // Try 1: send just 8 bytes (two uint32)
        fprintf(stdout, "[T1] 8 bytes: {0,0}...\n");
        uint32_t msg8[2] = {0, 0};
        write(fd, msg8, 8);
        ssize_t n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // Try 2: send 12 bytes
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T2] 12 bytes: {0,0,0}...\n");
        uint32_t msg12[3] = {0, 0, 0};
        write(fd, msg12, 12);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // Try 3: send 16 bytes (4x uint32)
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T3] 16 bytes: {0,0,0,0}...\n");
        uint32_t msg16[4] = {0, 0, 0, 0};
        write(fd, msg16, 16);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // Try 4: send 20 bytes
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T4] 20 bytes: {0,0,0,0,0}...\n");
        uint32_t msg20[5] = {0, 0, 0, 0, 0};
        write(fd, msg20, 20);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // Try 5: send 24 bytes
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T5] 24 bytes: {0,0,0,0,0,0}...\n");
        uint32_t msg24[6] = {0, 0, 0, 0, 0, 0};
        write(fd, msg24, 24);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // ============================================================
        // PHASE 2: Vary message type field
        // ============================================================
        fprintf(stdout, "\n========== PHASE 2: Vary Message Fields ==========\n\n");
        
        // Keep structure from TEST 6 (28 bytes) but vary fields
        struct __attribute__((packed)) {
            uint32_t f0, f1, f2, f3, f4, f5, f6;
        } msg = {0};
        
        for (int type = 0; type < 10; type++) {
            fd = connect_socket(); if (fd < 0) continue;
            msg.f0 = 0; msg.f1 = type; msg.f2 = 16; // Keep payload length=16
            msg.f3 = 0; msg.f4 = 0; msg.f5 = 0; msg.f6 = 0;
            fprintf(stdout, "[msgType=%d] ", type);
            write(fd, &msg, 28);
            n = read_timeout(fd, resp, sizeof(resp), 1000);
            if (n > 0) { fprintf(stdout, "resp(%zd): ", n); hex_line(resp, n); }
            else fprintf(stdout, "no response\n");
            close(fd);
            usleep(100000); // 100ms between attempts
        }
        
        // ============================================================
        // PHASE 3: Try uint64 size prefix (like GTTransport)
        // ============================================================
        fprintf(stdout, "\n========== PHASE 3: uint64 Size Prefix ==========\n\n");
        
        // Maybe the protocol is: [uint64 total_msg_size][message_data]
        // And response is: [uint64 resp_size][resp_data]
        // Response was: 3a(58) 00 00 00 00 00 00 00 | 10(16) 00 00 00 00 00 00 00
        // Could be: size=58 then 8 bytes of header/data?
        // Or: two uint64 fields: {58, 16}
        
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T6] uint64 size=8, then 8 bytes payload...\n");
        uint64_t size_prefix = 8;
        uint64_t payload = 0;
        write(fd, &size_prefix, 8);
        write(fd, &payload, 8);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        fd = connect_socket(); if (fd < 0) return 1;
        fprintf(stdout, "[T7] uint64 size=16, then 16 bytes...\n");
        size_prefix = 16;
        uint64_t payload2[2] = {0, 0};
        write(fd, &size_prefix, 8);
        write(fd, payload2, 16);
        n = read_timeout(fd, resp, sizeof(resp), 2000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // ============================================================
        // PHASE 4: Interpret previous response
        // ============================================================
        fprintf(stdout, "\n========== PHASE 4: Response Interpretation ==========\n\n");
        
        // Response from TEST 6 was: 3a 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00
        // As uint64_le: [58, 16]
        // 58 could be: response total size? Or some status/error code?
        // 16 could be: payload size? Or echo of our dataLength field?
        //
        // Key insight: our message was 28 bytes total:
        //   [0, 0, 16, 0, 0, 0, 0] (7 x uint32)
        //   = clientIndex=0, type=0, payloadLen=16, payload=0000...
        //
        // Response 58 = 0x3a. In ASCII that's ':'
        // Could be an error code? Or a "ready" indicator?
        
        // Let's see what the GTMessageTransportIPC protocol looks like
        // by trying to understand the framing
        
        // The fact that only 28-byte messages get responses suggests
        // there might be a fixed header size the server expects
        
        fprintf(stdout, "[HYPOTHESIS] Protocol framing:\n");
        fprintf(stdout, "  Message: [uint32 f0][uint32 f1][uint32 dataLen][...data...]\n");
        fprintf(stdout, "  Response: [uint64 code/size][uint64 param]\n");
        fprintf(stdout, "  28-byte msg worked (header=12 + payload=16)\n\n");

        // ============================================================
        // PHASE 5: Try with actual shader debug data format
        // ============================================================
        fprintf(stdout, "========== PHASE 5: Shader Debug Command Attempt ==========\n\n");
        
        // Based on the flatbuffers usage and the protocol structure,
        // let's try sending a command that might trigger shader debug
        // The GTLLVMHelper likely expects:
        //   - A command/request type
        //   - Shader binary data (metallib/AIR)
        //   - Thread coordinates
        
        // Try different f1 (possible command type) values with larger payloads
        fd = connect_socket(); if (fd < 0) return 1;
        
        // Build a message with a small metallib-like payload
        uint32_t header[3] = {0, 1, 64}; // clientIdx=0, type=1, len=64
        uint8_t data64[64] = {0};
        // Fill with a recognizable pattern
        memcpy(data64, "MTLB", 4); // metallib magic
        
        fprintf(stdout, "[CMD] type=1, payload=64 bytes (MTLB header)...\n");
        write(fd, header, 12);
        write(fd, data64, 64);
        n = read_timeout(fd, resp, sizeof(resp), 3000);
        if (n > 0) { fprintf(stdout, "  resp(%zd): ", n); hex_line(resp, n); }
        else fprintf(stdout, "  no response\n");
        close(fd);
        
        // ============================================================
        // PHASE 6: Intercept Xcode's communication via our Service
        // ============================================================
        fprintf(stdout, "\n========== PHASE 6: Service shaderdebug with socket monitor ==========\n\n");
        
        // The best approach: use our GTMTLReplayService.shaderdebug:
        // but THIS TIME also monitor the socket for what actually gets sent
        
        // Actually, let's check: does GTMTLReplayService communicate directly
        // with GTLLVMHelper? Or does it go through the XPC replay service?
        
        // From Phase 0 in probe3: service.shaderdebug token never completes
        // BUT we just confirmed socket connection works.
        // The issue might be that the SERVICE doesn't have the socket connection
        // configured in its GTMTLReplayClient.
        
        fprintf(stdout, "[ANALYSIS] Key insight from protocol probing:\n");
        fprintf(stdout, "  1. We CAN connect to GTLLVMHelper socket ✅\n");
        fprintf(stdout, "  2. Server responds to 28-byte messages (header+16 payload) ✅\n");
        fprintf(stdout, "  3. Protocol likely: [uint32 clientIdx][uint32 cmdType][uint32 dataLen][data...]\n");
        fprintf(stdout, "  4. Response: [uint64][uint64] — status/size pair\n\n");
        
        fprintf(stdout, "[NEXT STEPS]\n");
        fprintf(stdout, "  - Vary cmdType systematically to map command space\n");
        fprintf(stdout, "  - Feed actual metallib/AIR binary as payload with debug commands\n");
        fprintf(stdout, "  - OR: patch our GTMTLReplayClient to include socket FD\n");
        
        return 0;
    }
}
