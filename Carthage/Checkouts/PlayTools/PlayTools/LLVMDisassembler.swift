//
//  LLVMDisassembler.swift
//  PlayTools
//
//  E-004d / E-006a: 调用 llvm-dis 将 LLVM Bitcode → LLVM IR 文本
//  优先通过 bridge 请求宿主 PlayCover 进程执行 llvm-dis；若宿主桥接不可用，
//  再回退到本地 posix_spawn 路径（主要用于兼容旧宿主或保留诊断能力）。
//
//  注意：PlayTools 是 iOS target，不能使用 Foundation.Process (NSTask)。
//  且目标 app 运行在 PlayCover 的 macOS sandbox 中时，本地 posix_spawn 可能被
//  `process-fork` 规则拦截，因此宿主代理执行是当前主路径。
//

import Foundation
import Network
import Darwin

/// C environ 全局变量（posix_spawn 传递环境变量需要）
private let posixEnviron: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
    // 在 Darwin/iOS SDK 中 environ 不一定直接暴露给 Swift，
    // 通过 dlsym 获取是最可靠的方式
    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
    if let ptr = dlsym(RTLD_DEFAULT, "environ") {
        return ptr.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
    }
    // fallback: 空环境
    return UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
}()

// MARK: - LLVMDisassembler

/// 将 LLVM Bitcode 二进制数据反汇编为 LLVM IR 文本。
///
/// 主路径：通过运行时 bridge 请求宿主 PlayCover 进程执行 `llvm-dis`，
/// 避免 injected runtime 受到目标 app sandbox 的 `process-fork` 限制。
///
/// fallback：若宿主桥接不可用，再尝试本地 `posix_spawn`，便于兼容旧宿主版本
/// 或保留离线诊断能力。
struct LLVMDisassembler {

    // MARK: - Error types

    enum DisassemblerError: LocalizedError {
        case llvmDisNotFound(searchedPaths: [String])
        case invalidBitcode(reason: String)
        case processLaunchFailed(Error)
        case processTimeout(seconds: Int)
        case processNonZeroExit(code: Int32, stderr: String)
        case outputFileNotFound(path: String)
        case outputReadFailed(path: String, Error)

        var errorDescription: String? {
            switch self {
            case .llvmDisNotFound(let paths):
                return "llvm-dis not found. Searched: \(paths.joined(separator: ", "))"
            case .invalidBitcode(let reason):
                return "Invalid bitcode data: \(reason)"
            case .processLaunchFailed(let error):
                return "Failed to launch llvm-dis: \(error.localizedDescription)"
            case .processTimeout(let seconds):
                return "llvm-dis timed out after \(seconds) seconds"
            case .processNonZeroExit(let code, let stderr):
                return "llvm-dis exited with code \(code): \(stderr.prefix(500))"
            case .outputFileNotFound(let path):
                return "llvm-dis output file not found: \(path)"
            case .outputReadFailed(let path, let error):
                return "Failed to read llvm-dis output at \(path): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Result type

    /// 反汇编结果
    struct DisassemblyResult {
        /// LLVM IR 文本内容
        let irText: String
        /// 源 bitcode 模块的函数名
        let functionNames: [String]
        /// llvm-dis 执行耗时（秒）
        let elapsedSeconds: Double
        /// bitcode 输入数据大小
        let inputSize: Int
        /// IR 文本输出大小
        let outputSize: Int

        var summary: String {
            let funcs = functionNames.prefix(3).joined(separator: ",")
            let suffix = functionNames.count > 3 ? "..." : ""
            return "irSize=\(outputSize), bcSize=\(inputSize), " +
                   "elapsed=\(String(format: "%.2f", elapsedSeconds))s, " +
                   "funcs=\(functionNames.count)(\(funcs)\(suffix))"
        }
    }

    // MARK: - Configuration

    /// llvm-dis 进程超时时间（秒）
    static let defaultTimeoutSeconds: Int = 30
    private static let hostBridgeCommandTimeout: TimeInterval = 5.0
    private static let hostBridgeCommandName = "host_disassemble_bitcode"
    private static let hostBridgeQueue = DispatchQueue(label: "com.playtools.llvm-dis.host-bridge")

    private enum HostBridgeError: LocalizedError {
        case sessionUnavailable
        case invalidPort(UInt16)
        case connectionFailed(String)
        case connectionTimedOut(TimeInterval)
        case sendTimedOut(TimeInterval)
        case invalidResponse(String)
        case remoteError(String)

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "Host bridge session is unavailable"
            case .invalidPort(let port):
                return "Invalid host bridge port: \(port)"
            case .connectionFailed(let message):
                return "Failed to connect to host bridge: \(message)"
            case .connectionTimedOut(let timeout):
                return "Timed out connecting to host bridge after \(String(format: "%.1f", timeout))s"
            case .sendTimedOut(let timeout):
                return "Timed out sending host bridge request after \(String(format: "%.1f", timeout))s"
            case .invalidResponse(let message):
                return "Invalid host bridge response: \(message)"
            case .remoteError(let message):
                return "Host bridge reported an error: \(message)"
            }
        }
    }

    // MARK: - Known install paths

    /// 解析当前登录用户的宿主 Home 目录。
    ///
    /// 注意：PlayTools 运行在 PlayCover 管理的 app 容器内时，`NSHomeDirectory()`
    /// 返回的是 app 自己的容器路径，而不是 macOS 用户主目录；直接拿它去拼
    /// `~/Library/Containers/io.playcover.PlayCover/...` 会得到错误的双层容器路径。
    private static var hostUserHomeDirectoryPath: String {
        let currentUID = getuid()
        if let pw = getpwuid(currentUID), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())").path
    }

    /// llvm-dis 的已知安装位置（按优先级排序）
    private static var knownLLVMDisPaths: [String] {
        [
            // LLVMToolManager 安装位置（PlayCover 主应用管理）
            "\(hostUserHomeDirectoryPath)/Library/Containers/io.playcover.PlayCover/llvm-tools/llvm-dis",
            // Homebrew (ARM)
            "/opt/homebrew/bin/llvm-dis",
            // Homebrew (x86)
            "/usr/local/bin/llvm-dis",
            // Xcode toolchain (unlikely but check)
            "/usr/bin/llvm-dis",
        ]
    }

    // MARK: - Public API

    /// 描述某个 llvm-dis 候选路径的探测结果。
    private static func describeLLVMDisCandidate(at path: String) -> String {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        let executable = exists && fm.isExecutableFile(atPath: path)
        let accessXOK = exists && access(path, X_OK) == 0
        return "\(path) [exists=\(exists), isExecutable=\(executable), accessXOK=\(accessXOK)]"
    }

    /// llvm-dis 候选路径的诊断摘要。
    private static var knownLLVMDisPathDiagnostics: [String] {
        knownLLVMDisPaths.map { describeLLVMDisCandidate(at: $0) }
    }

    /// 查找 llvm-dis 二进制路径。
    ///
    /// 优先返回首个已存在且通过 `isExecutableFile` 或 `access(X_OK)` 校验的路径；
    /// 若候选路径已存在但执行位探测异常，也先返回它，让后续 `posix_spawn`
    /// 给出更准确的错误，而不是过早降级成“not found”。
    static func findLLVMDis() -> String? {
        let fm = FileManager.default
        var existingButNotExecutablePath: String?

        for path in knownLLVMDisPaths {
            guard fm.fileExists(atPath: path) else {
                continue
            }
            let executable = fm.isExecutableFile(atPath: path)
            let accessXOK = access(path, X_OK) == 0
            if executable || accessXOK {
                return path
            }
            if existingButNotExecutablePath == nil {
                existingButNotExecutablePath = path
            }
        }

        return existingButNotExecutablePath
    }

    /// 将单个 BitcodeModule 反汇编为 LLVM IR 文本。
    ///
    /// - Parameters:
    ///   - module: 从 MetallibParser 提取的 bitcode 模块
    ///   - timeoutSeconds: 超时时间（秒），默认 30s
    /// - Returns: 反汇编结果
    /// - Throws: `DisassemblerError`
    static func disassemble(
        module: MetallibParser.BitcodeModule,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) throws -> DisassemblyResult {
        return try disassemble(
            bitcodeData: module.data,
            functionNames: module.functionNames,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// 将 bitcode 数据反汇编为 LLVM IR 文本。
    ///
    /// - Parameters:
    ///   - bitcodeData: LLVM bitcode 二进制数据
    ///   - functionNames: 关联的函数名（用于日志和结果标识）
    ///   - timeoutSeconds: 超时时间（秒）
    /// - Returns: 反汇编结果
    /// - Throws: `DisassemblerError`
    static func disassemble(
        bitcodeData: Data,
        functionNames: [String] = [],
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) throws -> DisassemblyResult {
        // 1. 校验 bitcode 数据
        guard bitcodeData.count >= 4 else {
            throw DisassemblerError.invalidBitcode(reason: "data too short (\(bitcodeData.count) bytes)")
        }

        let isValid = bitcodeData.withUnsafeBytes { buf -> Bool in
            let b0 = buf.load(fromByteOffset: 0, as: UInt8.self)
            let b1 = buf.load(fromByteOffset: 1, as: UInt8.self)
            // LLVM bitcode wrapper magic: DE C0 17 0B
            if b0 == 0xDE && b1 == 0xC0 { return true }
            // Raw LLVM bitstream magic: "BC" (0x42 0x43)
            if b0 == 0x42 && b1 == 0x43 { return true }
            return false
        }
        guard isValid else {
            let hex = bitcodeData.prefix(4).map { String(format: "%02X", $0) }.joined()
            throw DisassemblerError.invalidBitcode(reason: "unrecognized magic: \(hex)")
        }

        // 2. 优先尝试让宿主 PlayCover 进程代跑 llvm-dis，绕开 injected runtime 的 spawn 权限限制。
        if let hostBridgeResult = safeDisassembleViaHostBridge(
            bitcodeData: bitcodeData,
            functionNames: functionNames,
            timeoutSeconds: timeoutSeconds
        ) {
            return hostBridgeResult
        }

        // 3. fallback：直接在当前 runtime 中查找并调用 llvm-dis。
        guard let llvmDisPath = findLLVMDis() else {
            throw DisassemblerError.llvmDisNotFound(searchedPaths: knownLLVMDisPathDiagnostics)
        }

        // 4. 创建临时文件
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("playtools-llvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let inputPath = tmpDir.appendingPathComponent("input.bc")
        let outputPath = tmpDir.appendingPathComponent("output.ll")

        try bitcodeData.write(to: inputPath)

        // 5. 调用 llvm-dis（使用 posix_spawn，因为 PlayTools 是 iOS target 无法使用 Foundation.Process）
        let startTime = CFAbsoluteTimeGetCurrent()

        // 设置 stderr 重定向到管道
        var stderrPipe: [Int32] = [0, 0]
        pipe(&stderrPipe)

        let spawnResult = spawnLLVMDis(
            executablePath: llvmDisPath,
            arguments: [llvmDisPath, inputPath.path, "-o", outputPath.path],
            stderrWriteFD: stderrPipe[1]
        )
        // 关闭写端（父进程）
        close(stderrPipe[1])

        guard case .success(let pid) = spawnResult else {
            close(stderrPipe[0])
            if case .failure(let error) = spawnResult {
                throw error
            }
            throw DisassemblerError.processLaunchFailed(
                NSError(domain: "LLVMDisassembler", code: -1, userInfo: nil)
            )
        }

        // 6. 等待完成（带超时）
        let (exitCode, completed) = waitForPid(pid, timeoutSeconds: timeoutSeconds)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // 读取 stderr
        let stderrData = readAllFromFD(stderrPipe[0])
        close(stderrPipe[0])

        guard completed else {
            kill(pid, SIGKILL)
            var dummy: Int32 = 0
            waitpid(pid, &dummy, 0)
            throw DisassemblerError.processTimeout(seconds: timeoutSeconds)
        }

        // 7. 检查退出状态
        if exitCode != 0 {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "<binary>"
            throw DisassemblerError.processNonZeroExit(code: exitCode, stderr: stderrText)
        }

        // 8. 读取输出
        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw DisassemblerError.outputFileNotFound(path: outputPath.path)
        }

        let irText: String
        do {
            irText = try String(contentsOf: outputPath, encoding: .utf8)
        } catch {
            throw DisassemblerError.outputReadFailed(path: outputPath.path, error)
        }

        return DisassemblyResult(
            irText: irText,
            functionNames: functionNames,
            elapsedSeconds: elapsed,
            inputSize: bitcodeData.count,
            outputSize: irText.utf8.count
        )
    }

    /// 批量反汇编多个 bitcode 模块。
    /// 返回成功和失败的结果。不会因单个模块失败而中断。
    ///
    /// - Parameters:
    ///   - modules: bitcode 模块列表
    ///   - timeoutSeconds: 每个模块的超时时间
    /// - Returns: (成功的结果, 失败信息)
    static func disassembleBatch(
        modules: [MetallibParser.BitcodeModule],
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) -> (successes: [DisassemblyResult], failures: [(module: MetallibParser.BitcodeModule, error: Error)]) {
        var successes: [DisassemblyResult] = []
        var failures: [(module: MetallibParser.BitcodeModule, error: Error)] = []

        for module in modules {
            // 只处理有效的 LLVM bitcode
            guard module.isValidLLVMBitcode else {
                failures.append((module, DisassemblerError.invalidBitcode(
                    reason: "module magic=\(module.magicDescription)"
                )))
                continue
            }

            do {
                let result = try disassemble(module: module, timeoutSeconds: timeoutSeconds)
                successes.append(result)
            } catch {
                failures.append((module, error))
            }
        }

        return (successes, failures)
    }

    // MARK: - Safe wrappers (for integration with hook pipeline)

    /// 安全地反汇编单个模块，失败时记录日志并返回 nil。
    static func safeDisassemble(
        module: MetallibParser.BitcodeModule,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) -> DisassemblyResult? {
        do {
            let result = try disassemble(module: module, timeoutSeconds: timeoutSeconds)
            NSLog("[PlayTools] LLVMDisassembler: success — %@", result.summary)
            return result
        } catch {
            NSLog("[PlayTools] LLVMDisassembler: failed for module[offset=%llu,size=%llu,funcs=%d] — %@",
                  module.relativeOffset, module.size, module.functionNames.count,
                  error.localizedDescription)
            return nil
        }
    }

    /// 安全地批量反汇编，返回所有成功的结果。失败仅记录日志。
    static func safeDisassembleBatch(
        modules: [MetallibParser.BitcodeModule],
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) -> [DisassemblyResult] {
        let (successes, failures) = disassembleBatch(
            modules: modules,
            timeoutSeconds: timeoutSeconds
        )

        if !failures.isEmpty {
            NSLog("[PlayTools] LLVMDisassembler: batch completed — %d/%d succeeded, %d failed",
                  successes.count, modules.count, failures.count)
            for (mod, err) in failures.prefix(5) {
                let names = mod.functionNames.prefix(2).joined(separator: ",")
                NSLog("[PlayTools] LLVMDisassembler:   failed module[offset=%llu,funcs=%@]: %@",
                      mod.relativeOffset, names, err.localizedDescription)
            }
        } else if !successes.isEmpty {
            let totalIR = successes.reduce(0) { $0 + $1.outputSize }
            let totalElapsed = successes.reduce(0.0) { $0 + $1.elapsedSeconds }
            NSLog("[PlayTools] LLVMDisassembler: batch completed — %d/%d succeeded, totalIR=%d bytes, elapsed=%.2fs",
                  successes.count, modules.count, totalIR, totalElapsed)
        }

        return successes
    }

    private static func safeDisassembleViaHostBridge(
        bitcodeData: Data,
        functionNames: [String],
        timeoutSeconds: Int
    ) -> DisassemblyResult? {
        do {
            let result = try disassembleViaHostBridge(
                bitcodeData: bitcodeData,
                functionNames: functionNames,
                timeoutSeconds: timeoutSeconds
            )
            NSLog("[PlayTools] LLVMDisassembler: host bridge success — %@", result.summary)
            return result
        } catch {
            NSLog("[PlayTools] LLVMDisassembler: host bridge unavailable, fallback to local spawn — %@",
                  error.localizedDescription)
            return nil
        }
    }

    private static func disassembleViaHostBridge(
        bitcodeData: Data,
        functionNames: [String],
        timeoutSeconds: Int
    ) throws -> DisassemblyResult {
        guard let sessionId = BridgeListener.shared.sessionId else {
            throw HostBridgeError.sessionUnavailable
        }

        guard let port = NWEndpoint.Port(rawValue: BridgeListener.defaultRegistrationPort) else {
            throw HostBridgeError.invalidPort(BridgeListener.defaultRegistrationPort)
        }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }

        let readySemaphore = DispatchSemaphore(value: 0)
        var readyError: Error?
        var isReady = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isReady = true
                readySemaphore.signal()
            case .failed(let error):
                readyError = error
                readySemaphore.signal()
            case .cancelled:
                if !isReady {
                    readyError = HostBridgeError.connectionFailed("connection cancelled")
                    readySemaphore.signal()
                }
            default:
                break
            }
        }
        connection.start(queue: hostBridgeQueue)

        if readySemaphore.wait(timeout: .now() + hostBridgeCommandTimeout) == .timedOut {
            throw HostBridgeError.connectionTimedOut(hostBridgeCommandTimeout)
        }
        if let readyError {
            throw HostBridgeError.connectionFailed(readyError.localizedDescription)
        }

        let commandId = "llvm-dis-\(UUID().uuidString.lowercased())"
        try sendHostBridgeMessage(
            [
                "type": "command",
                "sessionId": sessionId,
                "commandId": commandId,
                "command": hostBridgeCommandName,
                "params": [
                    "bitcode_base64": bitcodeData.base64EncodedString(),
                    "timeout_seconds": timeoutSeconds,
                ],
            ],
            on: connection,
            timeout: hostBridgeCommandTimeout
        )

        let response = try receiveSingleHostBridgeMessage(
            on: connection,
            timeout: max(hostBridgeCommandTimeout, Double(timeoutSeconds) + 5.0)
        )

        guard hostBridgeStringValue("type", in: response) == "commandResponse" else {
            throw HostBridgeError.invalidResponse("unexpected message type")
        }
        guard hostBridgeStringValue("commandId", in: response) == commandId else {
            throw HostBridgeError.invalidResponse("commandId mismatch")
        }

        let status = hostBridgeStringValue("status", in: response) ?? ""
        let result = response["result"] as? [String: Any]

        if status != "ok" {
            let message = hostBridgeStringValue("message", in: result) ?? "unknown host bridge error"
            throw HostBridgeError.remoteError(message)
        }

        guard let irText = hostBridgeStringValue("ir_text", in: result) else {
            throw HostBridgeError.invalidResponse("missing ir_text")
        }

        return DisassemblyResult(
            irText: irText,
            functionNames: functionNames,
            elapsedSeconds: hostBridgeDoubleValue("elapsed_seconds", in: result) ?? 0,
            inputSize: hostBridgeIntValue("input_size", in: result) ?? bitcodeData.count,
            outputSize: hostBridgeIntValue("output_size", in: result) ?? irText.utf8.count
        )
    }

    private static func sendHostBridgeMessage(
        _ message: [String: Any],
        on connection: NWConnection,
        timeout: TimeInterval
    ) throws {
        let framedData = try frameHostBridgeMessage(message)
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: framedData, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw HostBridgeError.sendTimedOut(timeout)
        }
        if let sendError {
            throw HostBridgeError.connectionFailed(sendError.localizedDescription)
        }
    }

    private static func frameHostBridgeMessage(_ message: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        var framed = data
        framed.append("\n".data(using: .utf8)!)
        return framed
    }

    private static func receiveSingleHostBridgeMessage(
        on connection: NWConnection,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        var localBuffer = Data()
        let semaphore = DispatchSemaphore(value: 0)
        var receivedMessage: [String: Any]?
        var receiveError: Error?

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    localBuffer.append(data)
                    let (messages, remaining) = parseHostBridgeMessages(localBuffer)
                    localBuffer = remaining
                    if let first = messages.first {
                        receivedMessage = first
                        semaphore.signal()
                    } else {
                        receiveNextChunk()
                    }
                    return
                }

                if let error {
                    receiveError = error
                } else if isComplete {
                    receiveError = HostBridgeError.connectionFailed("connection closed")
                } else {
                    receiveError = HostBridgeError.invalidResponse("empty response from host bridge")
                }
                semaphore.signal()
            }
        }

        receiveNextChunk()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw HostBridgeError.connectionTimedOut(timeout)
        }
        if let receiveError {
            throw receiveError
        }
        if let receivedMessage {
            return receivedMessage
        }
        throw HostBridgeError.invalidResponse("missing host bridge payload")
    }

    private static func parseHostBridgeMessages(_ data: Data) -> ([[String: Any]], Data) {
        var messages: [[String: Any]] = []
        var remaining = data
        let newline = Data("\n".utf8)

        while let newlineRange = remaining.range(of: newline) {
            let line = Data(remaining[..<newlineRange.lowerBound])
            remaining = Data(remaining[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: line, options: []),
               let dictionary = object as? [String: Any] {
                messages.append(dictionary)
            }
        }

        return (messages, remaining)
    }

    private static func hostBridgeStringValue(_ key: String, in dictionary: [String: Any]?) -> String? {
        dictionary?[key] as? String
    }

    private static func hostBridgeDoubleValue(_ key: String, in dictionary: [String: Any]?) -> Double? {
        if let value = dictionary?[key] as? Double {
            return value
        }
        if let value = dictionary?[key] as? Int {
            return Double(value)
        }
        if let value = dictionary?[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func hostBridgeIntValue(_ key: String, in dictionary: [String: Any]?) -> Int? {
        if let value = dictionary?[key] as? Int {
            return value
        }
        if let value = dictionary?[key] as? Double {
            return Int(value)
        }
        if let value = dictionary?[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    // MARK: - Private helpers (posix_spawn based)

    /// 使用 posix_spawn 启动 llvm-dis 进程。
    /// PlayTools 运行在 iOS target 上，不能使用 Foundation.Process；
    /// 此路径现在只作为 host bridge 不可用时的本地 fallback / 诊断手段。
    private static func spawnLLVMDis(
        executablePath: String,
        arguments: [String],
        stderrWriteFD: Int32
    ) -> Result<pid_t, DisassemblerError> {
        // 构造 C 字符串数组
        var cArgs = arguments.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        // 设置 file actions：重定向 stderr，关闭 stdout
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // 重定向 stderr (fd 2) 到管道写端
        posix_spawn_file_actions_adddup2(&fileActions, stderrWriteFD, STDERR_FILENO)
        // 关闭 stdout (fd 1) → /dev/null
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &fileActions, nil, &cArgs, posixEnviron)

        if status != 0 {
            let errMsg = String(cString: strerror(status))
            return .failure(.processLaunchFailed(
                NSError(domain: "posix_spawn", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: errMsg])
            ))
        }

        return .success(pid)
    }

    /// 等待子进程完成，带超时。
    /// 使用 WNOHANG 轮询 + sleep 实现超时。
    private static func waitForPid(
        _ pid: pid_t,
        timeoutSeconds: Int
    ) -> (exitCode: Int32, completed: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutSeconds)
        var status: Int32 = 0

        while CFAbsoluteTimeGetCurrent() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                // 子进程已结束 — 手动实现 wait 宏（Swift 中不可用）
                // WIFEXITED(s) = ((s) & 0x7f) == 0
                if (status & 0x7F) == 0 {
                    // WEXITSTATUS(s) = ((s >> 8) & 0xff)
                    let exitCode = (status >> 8) & 0xFF
                    return (exitCode, true)
                }
                // WIFSIGNALED(s) = ((s) & 0x7f) != 0x7f && ((s) & 0x7f) != 0
                let termsig = status & 0x7F
                if termsig != 0 && termsig != 0x7F {
                    return (termsig + 128, true)
                }
                return (status, true)
            } else if result == -1 && errno != EINTR {
                // 错误（如 ECHILD）
                return (-1, true)
            }
            // 尚未结束，短暂 sleep 后重试
            usleep(50_000) // 50ms
        }

        return (0, false)
    }

    /// 从 file descriptor 读取所有数据。
    private static func readAllFromFD(_ fd: Int32) -> Data {
        var result = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(fd, buf, bufSize)
            if bytesRead <= 0 { break }
            result.append(buf, count: bytesRead)
        }
        return result
    }
}
