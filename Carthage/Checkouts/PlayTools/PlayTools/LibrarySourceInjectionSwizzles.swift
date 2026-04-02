//
//  LibrarySourceInjectionSwizzles.swift
//  PlayTools
//
//  E-003: Hook MTLDevice.makeLibrary 系列 API（log-only 骨架）
//  参考 CommandQueueDiscoverySwizzles 模式实现
//

import Foundation
import Metal
import ObjectiveC

// MARK: - Swizzled method implementations

/// Swizzle 替换方法容器类。
/// swizzle 后 `self` 指向 MTLDevice 实例（与 CommandQueueDiscoverySwizzles 一致）。
/// 当前阶段仅记录日志，不修改返回值。
private final class LibrarySourceInjectionSwizzles: NSObject {

    // MARK: 1. newLibraryWithData:error: — 最常用，从 metallib 二进制数据创建
    @objc dynamic func pc_newLibraryWithData(
        _ data: __DispatchData,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithData(data, error: error)
        let metallibData = MetallibParser.convertDispatchData(data)
        let dispatchObject = data as AnyObject
        let dispatchClassName = object_getClass(dispatchObject).map(NSStringFromClass) ?? NSStringFromClass(type(of: dispatchObject))
        let payloadSummary = MetallibParser.payloadDebugSummary(metallibData)
        if let originLog = MetallibParser.capturePayloadOriginIfNeeded(
            metallibData,
            selector: "newLibraryWithData:error:",
            dispatchClassName: dispatchClassName,
            callStackSymbols: Thread.callStackSymbols
        ) {
            NSLog("[PlayTools] LibrarySourceInjection: captured non-MTLB payload origin (dispatchClass=%@, payload={%@})\n%@",
                  dispatchClassName,
                  payloadSummary,
                  originLog)
        }
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithData:error:",
            device: self,
            library: library,
            dataSize: metallibData.count,
            extraInfo: "dispatchClass=\(dispatchClassName), payload={\(payloadSummary)}"
        )
        // E-004b / E-005a: 提取 bitcode，并在安全条件下尝试重编译带源码的替换 library。
        let modules = LibrarySourceInjectionService.shared.extractAndCacheBitcodeModules(
            from: metallibData,
            selector: "newLibraryWithData:error:"
        )
        return LibrarySourceInjectionService.shared.attemptLibraryReplacement(
            originalLibrary: library,
            device: self,
            modules: modules,
            selector: "newLibraryWithData:error:",
            compileSource: { source, compileError in
                self.pc_newLibraryWithSource(source, options: nil, error: compileError)
            }
        ) ?? library
    }

    // MARK: 2. newLibraryWithURL:error: — 从文件 URL 加载 metallib
    @objc dynamic func pc_newLibraryWithURL(
        _ url: URL,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithURL(url, error: error)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithURL:error:",
            device: self,
            library: library,
            dataSize: nil,
            extraInfo: "url=\(url.path)"
        )
        return library
    }

    // MARK: 3. newDefaultLibrary — 从 App Bundle 加载默认 metallib
    @objc dynamic func pc_newDefaultLibrary() -> AnyObject? {
        let library = self.pc_newDefaultLibrary()
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newDefaultLibrary",
            device: self,
            library: library,
            dataSize: nil,
            extraInfo: "bundle=main"
        )
        return library
    }

    // MARK: 4. newDefaultLibraryWithBundle:error: — 从指定 Bundle 加载 metallib
    @objc dynamic func pc_newDefaultLibraryWithBundle(
        _ bundle: Bundle,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newDefaultLibraryWithBundle(bundle, error: error)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newDefaultLibraryWithBundle:error:",
            device: self,
            library: library,
            dataSize: nil,
            extraInfo: "bundle=\(bundle.bundlePath)"
        )
        return library
    }

    // MARK: 5. newLibraryWithFile:error: — 从文件路径加载（已废弃但部分 App 仍用）
    @objc dynamic func pc_newLibraryWithFile(
        _ filepath: NSString,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithFile(filepath, error: error)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithFile:error:",
            device: self,
            library: library,
            dataSize: nil,
            extraInfo: "path=\(filepath)"
        )
        return library
    }

    // MARK: 6. newLibraryWithSource:options:error: — 从 MSL 源码编译（仅日志，源码已有）
    @objc dynamic func pc_newLibraryWithSource(
        _ source: NSString,
        options: MTLCompileOptions?,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithSource(source, options: options, error: error)
        let sourceLength = source.length
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithSource:options:error:",
            device: self,
            library: library,
            dataSize: sourceLength,
            extraInfo: "source_compile (source_len=\(sourceLength))"
        )
        return library
    }

    // MARK: 7. newLibraryWithSource:options:completionHandler: — 异步源码编译（仅日志）
    @objc dynamic func pc_newLibraryWithSourceAsync(
        _ source: NSString,
        options: MTLCompileOptions?,
        completionHandler: @escaping @convention(block) (AnyObject?, NSError?) -> Void
    ) {
        let sourceLength = source.length
        let wrappedHandler: @convention(block) (AnyObject?, NSError?) -> Void = { library, error in
            LibrarySourceInjectionService.shared.logLibraryCreation(
                selector: "newLibraryWithSource:options:completionHandler:",
                device: self,
                library: library,
                dataSize: sourceLength,
                extraInfo: "async_source_compile (source_len=\(sourceLength), error=\(error?.localizedDescription ?? "nil"))"
            )
            completionHandler(library, error)
        }
        self.pc_newLibraryWithSourceAsync(source, options: options, completionHandler: wrappedHandler)
    }
}

// MARK: - LibrarySourceInjectionService

/// 管理 Library hook 的安装与日志记录。
/// 遵循 MetalCaptureService 中 installQueueDiscoveryIfNeeded() 的模式。
class LibrarySourceInjectionService {
    static let shared = LibrarySourceInjectionService()

    private var installed = false
    private let lock = NSLock()

    /// 已观测到的 library 创建计数（按 selector 分类）
    private var creationCounts: [String: Int] = [:]
    private let countsLock = NSLock()

    // MARK: - E-004b: Bitcode 模块缓存

    /// 缓存的 bitcode 提取结果。
    /// Key: metallib 数据的 SHA256 hash（前 16 字节 hex），Value: 提取的模块列表。
    private var bitcodeCache: [String: [MetallibParser.BitcodeModule]] = [:]
    private let bitcodeCacheLock = NSLock()

    /// 已处理的 metallib 计数统计
    private(set) var extractionStats = ExtractionStats()

    struct ExtractionStats {
        var totalMetallibs: Int = 0
        var totalModulesExtracted: Int = 0
        var totalValidLLVMModules: Int = 0
        var totalFunctionsProcessed: Int = 0
        var cacheHits: Int = 0
        var alreadyHasSources: Int = 0

        var summary: String {
            "metallibs=\(totalMetallibs), modules=\(totalModulesExtracted), " +
            "valid_llvm=\(totalValidLLVMModules), functions=\(totalFunctionsProcessed), " +
            "cache_hits=\(cacheHits), has_sources=\(alreadyHasSources)"
        }
    }

    /// **E-004b**: 从 metallib 数据中提取 bitcode 模块并缓存。
    /// 如果 metallib 已经包含 SOURCES section，则跳过（无需重新注入）。
    ///
    /// - Parameters:
    ///   - data: metallib 的原始 Data
    ///   - selector: 调用来源的 selector 名（用于日志）
    /// - Returns: 提取的 bitcode 模块列表，如果不需要处理或失败则返回空数组
    func extractAndCacheBitcodeModules(from data: Data, selector: String) -> [MetallibParser.BitcodeModule] {
        // 计算 cache key（使用数据前 32 字节 + 大小作为快速指纹）
        let cacheKey = computeCacheKey(data)

        bitcodeCacheLock.lock()
        if let cached = bitcodeCache[cacheKey] {
            extractionStats.cacheHits += 1
            bitcodeCacheLock.unlock()
            NSLog("[PlayTools] BitcodeExtraction: %@ — cache hit (key=%@, modules=%d)",
                  selector, cacheKey, cached.count)
            return cached
        }
        bitcodeCacheLock.unlock()

        // 解析并提取
        guard let (result, modules) = MetallibParser.safeExtractBitcodeModules(from: data) else {
            return []
        }

        bitcodeCacheLock.lock()
        extractionStats.totalMetallibs += 1
        extractionStats.totalModulesExtracted += modules.count
        extractionStats.totalFunctionsProcessed += result.functions.count

        // 如果已有 SOURCES section，标记并跳过
        if result.hasSources {
            extractionStats.alreadyHasSources += 1
            bitcodeCacheLock.unlock()
            NSLog("[PlayTools] BitcodeExtraction: %@ — skipped, already has SOURCES section (%d functions)",
                  selector, result.functions.count)
            return []
        }

        let validCount = modules.filter { $0.isValidLLVMBitcode }.count
        extractionStats.totalValidLLVMModules += validCount

        // 缓存结果
        bitcodeCache[cacheKey] = modules
        let stats = extractionStats
        bitcodeCacheLock.unlock()

        NSLog("[PlayTools] BitcodeExtraction: %@ — extracted %d modules (%d valid LLVM) from %d functions [%@]",
              selector, modules.count, validCount, result.functions.count, stats.summary)

        return modules
    }

    /// **E-004b**: 从 dispatch_data_t 中提取 bitcode 模块。
    func extractAndCacheBitcodeModules(
        from dispatchData: __DispatchData,
        selector: String
    ) -> [MetallibParser.BitcodeModule] {
        let data = MetallibParser.convertDispatchData(dispatchData)
        return extractAndCacheBitcodeModules(from: data, selector: selector)
    }

    /// 获取当前缓存中所有 bitcode 模块的快照（供调试/诊断用）
    func cachedModulesSnapshot() -> [String: [MetallibParser.BitcodeModule]] {
        bitcodeCacheLock.lock()
        let snapshot = bitcodeCache
        bitcodeCacheLock.unlock()
        return snapshot
    }

    /// **E-005a**: 在 `newLibraryWithData:error:` 成功后，尝试将 bitcode 反编译为 MSL 再重编译。
    /// 仅做最小闭环：当前仅处理单个 bitcode module，任一步失败都回退原始 library。
    func attemptLibraryReplacement(
        originalLibrary: AnyObject?,
        device: AnyObject,
        modules: [MetallibParser.BitcodeModule],
        selector: String,
        compileSource: (_ source: NSString, _ error: UnsafeMutablePointer<NSError?>?) -> AnyObject?
    ) -> AnyObject? {
        guard originalLibrary != nil else {
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement, original library creation failed", selector)
            return nil
        }
        guard !modules.isEmpty else {
            return nil
        }
        guard modules.count == 1, let module = modules.first else {
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement, %d bitcode modules found (E-005b pending)",
                  selector, modules.count)
            return nil
        }
        guard module.isValidLLVMBitcode else {
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement, invalid LLVM bitcode (%@)",
                  selector, module.summary)
            return nil
        }

        do {
            let irResult = try LLVMDisassembler.disassemble(module: module)
            let conversion = try IRToMSLConverter.convert(
                irText: irResult.irText,
                functionNames: module.functionNames,
                functionTypes: module.functionTypes
            )

            var compileError: NSError?
            let replacementLibrary = compileSource(conversion.mslSource as NSString, &compileError)
            guard let replacementLibrary else {
                NSLog("[PlayTools] LibrarySourceInjection: %@ — source recompile failed: %@",
                      selector, compileError?.localizedDescription ?? "unknown error")
                return nil
            }

            let replacedFunctionCount: Int
            if replacementLibrary.responds(to: NSSelectorFromString("functionNames")) {
                let names = replacementLibrary.value(forKey: "functionNames") as? [String] ?? []
                replacedFunctionCount = names.count
            } else {
                replacedFunctionCount = -1
            }
            let deviceClassName = NSStringFromClass(object_getClass(device)!)
            NSLog("[PlayTools] LibrarySourceInjection: %@ — replacement success (device=%@, functions=%d, irSize=%d, mslSize=%d, module=%@)",
                  selector,
                  deviceClassName,
                  replacedFunctionCount,
                  irResult.outputSize,
                  conversion.mslSource.utf8.count,
                  module.summary)
            return replacementLibrary
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: %@ — replacement fallback: %@ (%@)",
                  selector, error.localizedDescription, module.summary)
            return nil
        }
    }

    private func computeCacheKey(_ data: Data) -> String {
        // 快速 hash：使用数据大小 + 前 32 字节 + 尾 16 字节的 hash
        let size = data.count
        var hashValue: UInt64 = UInt64(size)
        let headBytes = min(32, size)
        let tailBytes = min(16, max(0, size - 32))
        data.withUnsafeBytes { buf in
            for i in 0..<headBytes {
                hashValue = hashValue &* 31 &+ UInt64(buf.load(fromByteOffset: i, as: UInt8.self))
            }
            if tailBytes > 0 {
                let tailStart = size - tailBytes
                for i in tailStart..<size {
                    hashValue = hashValue &* 31 &+ UInt64(buf.load(fromByteOffset: i, as: UInt8.self))
                }
            }
        }
        return String(format: "%016llX_%d", hashValue, size)
    }

    /// 安装所有 makeLibrary swizzle。
    /// 应在 MetalCaptureService.initialize() 之后调用。
    func installIfNeeded() {
        guard !installed else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[PlayTools] LibrarySourceInjection: skipped — no default Metal device")
            return
        }

        let deviceClass: AnyClass = object_getClass(device)!
        NSLog("[PlayTools] LibrarySourceInjection: installing hooks on %@", NSStringFromClass(deviceClass))

        // 第一批：必须 hook（从 metallib 数据创建的主要路径）
        let batch1: [(original: String, swizzled: Selector)] = [
            ("newLibraryWithData:error:",
             #selector(LibrarySourceInjectionSwizzles.pc_newLibraryWithData(_:error:))),
            ("newLibraryWithURL:error:",
             #selector(LibrarySourceInjectionSwizzles.pc_newLibraryWithURL(_:error:))),
            ("newDefaultLibrary",
             #selector(LibrarySourceInjectionSwizzles.pc_newDefaultLibrary)),
            ("newDefaultLibraryWithBundle:error:",
             #selector(LibrarySourceInjectionSwizzles.pc_newDefaultLibraryWithBundle(_:error:))),
            ("newLibraryWithFile:error:",
             #selector(LibrarySourceInjectionSwizzles.pc_newLibraryWithFile(_:error:))),
        ]

        // 第二批：仅日志（源码编译路径）
        let batch2: [(original: String, swizzled: Selector)] = [
            ("newLibraryWithSource:options:error:",
             #selector(LibrarySourceInjectionSwizzles.pc_newLibraryWithSource(_:options:error:))),
            ("newLibraryWithSource:options:completionHandler:",
             #selector(LibrarySourceInjectionSwizzles.pc_newLibraryWithSourceAsync(_:options:completionHandler:))),
        ]

        var results: [(String, Bool)] = []
        for entry in batch1 + batch2 {
            let ok = swizzleInstanceMethod(
                on: deviceClass,
                original: NSSelectorFromString(entry.original),
                swizzled: entry.swizzled
            )
            results.append((entry.original, ok))
        }

        installed = true

        let summary = results.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        NSLog("[PlayTools] LibrarySourceInjection: install complete. %@", summary)
    }

    /// 记录一次 library 创建调用。
    func logLibraryCreation(
        selector: String,
        device: AnyObject,
        library: AnyObject?,
        dataSize: Int?,
        extraInfo: String?
    ) {
        countsLock.lock()
        let count = (creationCounts[selector] ?? 0) + 1
        creationCounts[selector] = count
        let totalCount = creationCounts.values.reduce(0, +)
        countsLock.unlock()

        let deviceClassName = NSStringFromClass(object_getClass(device)!)
        let libraryClassName = library.map { NSStringFromClass(object_getClass($0)!) } ?? "nil"
        let libraryLabel: String
        if let lib = library, lib.responds(to: NSSelectorFromString("label")) {
            libraryLabel = (lib.value(forKey: "label") as? String) ?? "nil"
        } else {
            libraryLabel = "nil"
        }
        let functionCount: String
        if let lib = library, lib.responds(to: NSSelectorFromString("functionNames")) {
            let names = lib.value(forKey: "functionNames") as? [String] ?? []
            functionCount = "\(names.count)"
        } else {
            functionCount = "?"
        }

        var parts: [String] = [
            "sel=\(selector)",
            "device=\(deviceClassName)",
            "library=\(libraryClassName)",
            "label=\(libraryLabel)",
            "functions=\(functionCount)",
            "call#\(count)/total#\(totalCount)",
        ]
        if let size = dataSize {
            parts.append("dataSize=\(size)")
        }
        if let extra = extraInfo {
            parts.append(extra)
        }

        NSLog("[PlayTools] LibrarySourceInjection: %@", parts.joined(separator: ", "))
    }

    /// 获取当前统计摘要
    func statisticsSummary() -> String {
        countsLock.lock()
        let snapshot = creationCounts
        let total = snapshot.values.reduce(0, +)
        countsLock.unlock()

        let details = snapshot.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "total=\(total), \(details)"
    }

    // MARK: - Private swizzle helper

    /// 与 MetalCaptureService.swizzleInstanceMethod 完全一致的实现
    private func swizzleInstanceMethod(
        on targetClass: AnyClass,
        original originalSelector: Selector,
        swizzled swizzledSelector: Selector
    ) -> Bool {
        guard
            let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
            let swizzledMethod = class_getInstanceMethod(LibrarySourceInjectionSwizzles.self, swizzledSelector)
        else {
            NSLog("[PlayTools] LibrarySourceInjection: swizzle skipped — method not found. class=%@, selector=%@",
                  NSStringFromClass(targetClass), NSStringFromSelector(originalSelector))
            return false
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            guard let addedMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
                return false
            }
            method_exchangeImplementations(originalMethod, addedMethod)
            return true
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        return true
    }
}
