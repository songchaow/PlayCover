//
//  LibrarySourceInjectionSwizzles.swift
//  PlayTools
//
//  E-003: Hook MTLDevice.makeLibrary 系列 API（log-only 骨架）
//  参考 CommandQueueDiscoverySwizzles 模式实现
//

import CryptoKit
import Foundation
import Metal
import ObjectiveC

// MARK: - Swizzled method implementations

/// Swizzle 替换方法容器类。
/// swizzle 后 `self` 指向 MTLDevice 实例（与 CommandQueueDiscoverySwizzles 一致）。
/// 对 metallib 路径会在安全条件下尝试源码重编译替换；源码路径仍以日志观测为主。
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
        return attemptReplacementForMetallibData(
            metallibData,
            originalLibrary: library,
            selector: "newLibraryWithData:error:"
        )
    }

    // MARK: 2. newLibraryWithURL:error: — 从文件 URL 加载 metallib
    @objc dynamic func pc_newLibraryWithURL(
        _ url: URL,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithURL(url, error: error)
        let metallibData = try? Data(contentsOf: url)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithURL:error:",
            device: self,
            library: library,
            dataSize: metallibData?.count,
            extraInfo: "url=\(url.path)"
        )
        guard let metallibData else {
            NSLog("[PlayTools] LibrarySourceInjection: newLibraryWithURL:error: — unable to read metallib at %@", url.path)
            return library
        }
        return attemptReplacementForMetallibData(
            metallibData,
            originalLibrary: library,
            selector: "newLibraryWithURL:error:"
        )
    }

    // MARK: 3. newDefaultLibrary — 从 App Bundle 加载默认 metallib
    @objc dynamic func pc_newDefaultLibrary() -> AnyObject? {
        let library = self.pc_newDefaultLibrary()
        let defaultMetallib = Self.loadDefaultMetallibData(from: Bundle.main)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newDefaultLibrary",
            device: self,
            library: library,
            dataSize: defaultMetallib?.data.count,
            extraInfo: "bundle=main, metallib=\(defaultMetallib?.url.path ?? "unresolved")"
        )
        guard let defaultMetallib else {
            NSLog("[PlayTools] LibrarySourceInjection: newDefaultLibrary — unable to resolve default metallib in main bundle")
            return library
        }
        return attemptReplacementForMetallibData(
            defaultMetallib.data,
            originalLibrary: library,
            selector: "newDefaultLibrary"
        )
    }

    // MARK: 4. newDefaultLibraryWithBundle:error: — 从指定 Bundle 加载 metallib
    @objc dynamic func pc_newDefaultLibraryWithBundle(
        _ bundle: Bundle,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newDefaultLibraryWithBundle(bundle, error: error)
        let defaultMetallib = Self.loadDefaultMetallibData(from: bundle)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newDefaultLibraryWithBundle:error:",
            device: self,
            library: library,
            dataSize: defaultMetallib?.data.count,
            extraInfo: "bundle=\(bundle.bundlePath), metallib=\(defaultMetallib?.url.path ?? "unresolved")"
        )
        guard let defaultMetallib else {
            NSLog("[PlayTools] LibrarySourceInjection: newDefaultLibraryWithBundle:error: — unable to resolve default metallib in %@", bundle.bundlePath)
            return library
        }
        return attemptReplacementForMetallibData(
            defaultMetallib.data,
            originalLibrary: library,
            selector: "newDefaultLibraryWithBundle:error:"
        )
    }

    // MARK: 5. newLibraryWithFile:error: — 从文件路径加载（已废弃但部分 App 仍用）
    @objc dynamic func pc_newLibraryWithFile(
        _ filepath: NSString,
        error: UnsafeMutablePointer<NSError?>?
    ) -> AnyObject? {
        let library = self.pc_newLibraryWithFile(filepath, error: error)
        let fileURL = URL(fileURLWithPath: filepath as String)
        let metallibData = try? Data(contentsOf: fileURL)
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithFile:error:",
            device: self,
            library: library,
            dataSize: metallibData?.count,
            extraInfo: "path=\(filepath)"
        )
        guard let metallibData else {
            NSLog("[PlayTools] LibrarySourceInjection: newLibraryWithFile:error: — unable to read metallib at %@", fileURL.path)
            return library
        }
        return attemptReplacementForMetallibData(
            metallibData,
            originalLibrary: library,
            selector: "newLibraryWithFile:error:"
        )
    }

    private func attemptReplacementForMetallibData(
        _ metallibData: Data,
        originalLibrary: AnyObject?,
        selector: String
    ) -> AnyObject? {
        guard PlaySettings.shared.shaderSourceReplacementEnabled else {
            NSLog("[PlayTools] LibrarySourceInjection: %@ — replacement disabled by settings; returning original library", selector)
            return originalLibrary
        }
        let cacheKey = LibrarySourceInjectionService.shared.cacheKey(for: metallibData)
        let modules = LibrarySourceInjectionService.shared.extractAndCacheBitcodeModules(
            from: metallibData,
            selector: selector
        )
        return LibrarySourceInjectionService.shared.attemptLibraryReplacement(
            originalLibrary: originalLibrary,
            device: self,
            modules: modules,
            selector: selector,
            cacheKey: cacheKey,
            compileSource: { source, options, compileError in
                self.pc_newLibraryWithSource(source, options: options, error: compileError)
            }
        ) ?? originalLibrary
    }

    private static func loadDefaultMetallibData(from bundle: Bundle) -> (data: Data, url: URL)? {
        var candidateURLs: [URL] = []
        func appendCandidate(_ url: URL?) {
            guard let url else { return }
            guard !candidateURLs.contains(url) else { return }
            candidateURLs.append(url)
        }

        let explicitNames = [
            bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundle.bundleURL.deletingPathExtension().lastPathComponent,
            "default"
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for name in explicitNames {
            appendCandidate(bundle.url(forResource: name, withExtension: "metallib"))
        }

        if let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            let discoveredURLs = enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "metallib" }
                .sorted { $0.path < $1.path }
            for url in discoveredURLs {
                appendCandidate(url)
            }
        }

        for url in candidateURLs {
            if let data = try? Data(contentsOf: url) {
                return (data, url)
            }
        }
        return nil
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
    private lazy var runtimeBundleIdentifier: String = {
        Bundle.main.bundleIdentifier ?? "unknown.bundle"
    }()
    private lazy var playCoverContainerURL: URL = {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover", isDirectory: true)
    }()
    private lazy var shaderSourceDiagnosticDirectoryURL: URL = {
        playCoverContainerURL
            .appendingPathComponent("ShaderSourceDiagnostics", isDirectory: true)
            .appendingPathComponent(runtimeBundleIdentifier, isDirectory: true)
    }()
    private lazy var shaderCorpusDirectoryURL: URL = {
        playCoverContainerURL
            .appendingPathComponent("ShaderCorpus", isDirectory: true)
            .appendingPathComponent(runtimeBundleIdentifier, isDirectory: true)
    }()
    private lazy var shaderCorpusModulesDirectoryURL: URL = {
        shaderCorpusDirectoryURL.appendingPathComponent("modules", isDirectory: true)
    }()
    private lazy var shaderCorpusReplacementsDirectoryURL: URL = {
        shaderCorpusDirectoryURL.appendingPathComponent("replacements", isDirectory: true)
    }()
    private lazy var shaderCorpusManifestIndexURL: URL = {
        shaderCorpusDirectoryURL.appendingPathComponent("manifest.jsonl")
    }()
    private let corpusManifestSchemaVersion = 3

    // MARK: - E-004b: Bitcode 模块缓存

    /// 缓存的 bitcode 提取结果。
    /// Key: metallib 数据的快速 cache key，Value: 提取的模块列表。
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

    /// **E-005a / E-005b**: 在 `newLibraryWithData:error:` 成功后，
    /// 尝试将一个或多个 bitcode module 反编译为 MSL，再聚合后单次重编译。
    /// 当前策略保持保守：任一步失败都回退原始 library。
    func attemptLibraryReplacement(
        originalLibrary: AnyObject?,
        device: AnyObject,
        modules: [MetallibParser.BitcodeModule],
        selector: String,
        cacheKey: String,
        compileSource: (_ source: NSString, _ options: MTLCompileOptions?, _ error: UnsafeMutablePointer<NSError?>?) -> AnyObject?
    ) -> AnyObject? {
        let moduleKeys = modules.map { stableCorpusModuleKey(for: $0) }.sorted()
        let replacementDetails = [
            "selector": selector,
            "cacheKey": cacheKey,
            "moduleCount": String(modules.count),
            "moduleKeyCount": String(moduleKeys.count),
            "moduleKeys": moduleKeys.joined(separator: ","),
        ]
        if let bypassReason = bypassReasonForReplacement(selector: selector, cacheKey: cacheKey) {
            RuntimeLaunchDiagnostics.record(
                event: "replacement_attempt_skipped",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging(["reason": bypassReason]) { _, new in new }
            )
            appendReplacementAttemptEvent(
                selector: selector,
                cacheKey: cacheKey,
                modules: modules,
                outcome: "skipped",
                reasonCode: bypassReason,
                detail: "targeted runtime bypass",
                dumpPath: nil,
                invalidModuleCount: nil
            )
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement via targeted bypass (bundle=%@, cacheKey=%@)",
                  selector,
                  runtimeBundleIdentifier,
                  cacheKey)
            return nil
        }
        guard originalLibrary != nil else {
            RuntimeLaunchDiagnostics.record(
                event: "replacement_attempt_skipped",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging(["reason": "original_library_missing"]) { _, new in new }
            )
            appendReplacementAttemptEvent(
                selector: selector,
                cacheKey: cacheKey,
                modules: modules,
                outcome: "skipped",
                reasonCode: "original_library_missing",
                detail: "original library creation failed",
                dumpPath: nil,
                invalidModuleCount: nil
            )
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement, original library creation failed", selector)
            return nil
        }
        guard !modules.isEmpty else {
            RuntimeLaunchDiagnostics.record(
                event: "replacement_attempt_skipped",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging(["reason": "no_bitcode_modules"]) { _, new in new }
            )
            appendReplacementAttemptEvent(
                selector: selector,
                cacheKey: cacheKey,
                modules: modules,
                outcome: "skipped",
                reasonCode: "no_bitcode_modules",
                detail: "no valid bitcode modules extracted from metallib payload",
                dumpPath: nil,
                invalidModuleCount: nil
            )
            return nil
        }

        let invalidModules = modules.filter { !$0.isValidLLVMBitcode }
        guard invalidModules.isEmpty else {
            let invalidSummary = invalidModules.map(\.summary).joined(separator: "; ")
            RuntimeLaunchDiagnostics.record(
                event: "replacement_attempt_skipped",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging([
                    "reason": "invalid_llvm_bitcode",
                    "invalidModuleCount": String(invalidModules.count),
                ]) { _, new in new }
            )
            appendReplacementAttemptEvent(
                selector: selector,
                cacheKey: cacheKey,
                modules: modules,
                outcome: "skipped",
                reasonCode: "invalid_llvm_bitcode",
                detail: invalidSummary,
                dumpPath: nil,
                invalidModuleCount: invalidModules.count
            )
            NSLog("[PlayTools] LibrarySourceInjection: %@ — skip replacement, %d/%d modules are invalid LLVM (%@)",
                  selector,
                  invalidModules.count,
                  modules.count,
                  invalidSummary)
            return nil
        }

        RuntimeLaunchDiagnostics.record(
            event: "replacement_attempt_started",
            bundleId: runtimeBundleIdentifier,
            details: replacementDetails
        )

        var preparedModules: [PreparedModuleReplacement] = []
        do {
            preparedModules.reserveCapacity(modules.count)

            for (index, module) in modules.enumerated() {
                let irResult = try LLVMDisassembler.disassemble(module: module)
                let conversion = try IRToMSLConverter.convert(
                    irText: irResult.irText,
                    functionNames: module.functionNames,
                    functionTypes: module.functionTypes
                )
                preparedModules.append(PreparedModuleReplacement(
                    module: module,
                    irResult: irResult,
                    conversion: conversion
                ))
                NSLog("[PlayTools] LibrarySourceInjection: %@ — prepared module %d/%d (%@, %@)",
                      selector,
                      index + 1,
                      modules.count,
                      irResult.summary,
                      module.summary)
            }

            RuntimeLaunchDiagnostics.record(
                event: "replacement_modules_prepared",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging([
                    "preparedModuleCount": String(preparedModules.count),
                ]) { _, new in new }
            )

            let aggregate = try buildAggregateReplacementSource(from: preparedModules)
            let validationIssues = validateAggregateReplacementSource(aggregate.source)
            if !validationIssues.isEmpty {
                let issueSummary = validationIssues.prefix(3).map(\.summary).joined(separator: " | ")
                RuntimeLaunchDiagnostics.record(
                    event: "replacement_preflight_rejected",
                    bundleId: runtimeBundleIdentifier,
                    details: replacementDetails.merging([
                        "issueSummary": issueSummary,
                        "sourceFunctionCount": String(aggregate.functionCount),
                    ]) { _, new in new }
                )
                let dumpPath = dumpAggregateReplacementSource(
                    aggregate.source,
                    selector: selector,
                    reason: "preflight_rejected",
                    detail: issueSummary,
                    moduleSummaries: aggregate.moduleSummaries,
                    validationIssues: validationIssues,
                    compilerErrorDescription: nil,
                    preparedModules: preparedModules
                ) ?? "n/a"
                appendReplacementAttemptEvent(
                    selector: selector,
                    cacheKey: cacheKey,
                    modules: modules,
                    outcome: "failed",
                    reasonCode: "preflight_rejected",
                    detail: issueSummary,
                    dumpPath: dumpPath,
                    invalidModuleCount: nil
                )
                NSLog("[PlayTools] LibrarySourceInjection: %@ — source preflight rejected: %@ (modules=%d, sourceFuncs=%d, dump=%@)",
                      selector,
                      issueSummary,
                      aggregate.moduleCount,
                      aggregate.functionCount,
                      dumpPath)
                return nil
            }

            let compileDecision = resolveAggregateReplacementCompileDecision(for: preparedModules)
            let compileDetails = replacementDetails.merging([
                "sourceFunctionCount": String(aggregate.functionCount),
                "sourceLength": String(aggregate.source.utf8.count),
                "fastMathMode": compileDecision.fastMathMode?.rawValue ?? "default",
                "fastMathDecision": compileDecision.reason,
                "usesExplicitCompileOptions": compileDecision.options == nil ? "false" : "true",
            ]) { _, new in new }
            NSLog("[PlayTools] LibrarySourceInjection: %@ — aggregate compile posture %@ (fastMath=%@, explicitOptions=%d)",
                  selector,
                  compileDecision.reason,
                  compileDecision.fastMathMode?.rawValue ?? "default",
                  compileDecision.options == nil ? 0 : 1)
            RuntimeLaunchDiagnostics.record(
                event: "replacement_compile_started",
                bundleId: runtimeBundleIdentifier,
                details: compileDetails
            )

            var compileError: NSError?
            let replacementLibrary = compileSource(aggregate.source as NSString, compileDecision.options, &compileError)
            guard let replacementLibrary else {
                let compilerMessage = compileError?.localizedDescription ?? "unknown error"
                RuntimeLaunchDiagnostics.record(
                    event: "replacement_compile_failed",
                    bundleId: runtimeBundleIdentifier,
                    details: compileDetails.merging([
                        "compilerMessage": compilerMessage,
                    ]) { _, new in new }
                )
                let dumpPath = dumpAggregateReplacementSource(
                    aggregate.source,
                    selector: selector,
                    reason: "compile_failed",
                    detail: compilerMessage,
                    moduleSummaries: aggregate.moduleSummaries,
                    validationIssues: [],
                    compilerErrorDescription: compilerMessage,
                    preparedModules: preparedModules
                ) ?? "n/a"
                let compilerContext = compileErrorContext(in: aggregate.source, errorDescription: compilerMessage)
                appendReplacementAttemptEvent(
                    selector: selector,
                    cacheKey: cacheKey,
                    modules: modules,
                    outcome: "failed",
                    reasonCode: "compile_failed",
                    detail: compilerMessage,
                    dumpPath: dumpPath,
                    invalidModuleCount: nil
                )
                NSLog("[PlayTools] LibrarySourceInjection: %@ — source recompile failed: %@ (modules=%d, sourceFuncs=%d, dump=%@%@)",
                      selector,
                      compilerMessage,
                      aggregate.moduleCount,
                      aggregate.functionCount,
                      dumpPath,
                      compilerContext.map { ", \($0)" } ?? "")
                return nil
            }

            let replacedFunctionCount = functionCount(of: replacementLibrary)
            let dumpedCorpusPaths = dumpSuccessfulReplacementCorpus(
                preparedModules,
                aggregate: aggregate,
                selector: selector,
                cacheKey: cacheKey
            )
            appendReplacementAttemptEvent(
                selector: selector,
                cacheKey: cacheKey,
                modules: modules,
                outcome: "succeeded",
                reasonCode: nil,
                detail: nil,
                dumpPath: nil,
                invalidModuleCount: nil
            )
            RuntimeLaunchDiagnostics.record(
                event: "replacement_succeeded",
                bundleId: runtimeBundleIdentifier,
                details: compileDetails.merging([
                    "functionCount": String(replacedFunctionCount),
                    "corpusDumpCount": String(dumpedCorpusPaths.count),
                ]) { _, new in new }
            )
            let deviceClassName = NSStringFromClass(object_getClass(device)!)
            NSLog("[PlayTools] LibrarySourceInjection: %@ — replacement success (device=%@, functions=%d, modules=%d, sourceFuncs=%d, irSize=%d, mslSize=%d, corpus=%d, cacheKey=%@, moduleSummaries=%@)",
                  selector,
                  deviceClassName,
                  replacedFunctionCount,
                  aggregate.moduleCount,
                  aggregate.functionCount,
                  aggregate.totalIRSize,
                  aggregate.source.utf8.count,
                  dumpedCorpusPaths.count,
                  cacheKey,
                  aggregate.moduleSummaries)
            return replacementLibrary
        } catch {
            let moduleSummaries = modules.map(\.summary).joined(separator: "; ")
            RuntimeLaunchDiagnostics.record(
                event: "replacement_exception",
                bundleId: runtimeBundleIdentifier,
                details: replacementDetails.merging([
                    "error": error.localizedDescription,
                    "preparedModuleCount": String(preparedModules.count),
                ]) { _, new in new }
            )
            NSLog("[PlayTools] LibrarySourceInjection: %@ — replacement fallback: %@ (modules=%d, %@)",
                  selector,
                  error.localizedDescription,
                  modules.count,
                  moduleSummaries)
            // E-004f4: Dump available module artifacts for partial-failure offline replay
            if !preparedModules.isEmpty {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let baseName = sanitizeDiagnosticFilenameComponent("\(timestamp)_\(selector)_exception")
                let dumpPath = dumpPartialFailureModuleArtifacts(
                    allModules: modules,
                    preparedModules: preparedModules,
                    baseName: baseName,
                    selector: selector,
                    reason: "exception: \(error.localizedDescription)"
                )
                if let dumpPath {
                    appendReplacementAttemptEvent(
                        selector: selector,
                        cacheKey: cacheKey,
                        modules: modules,
                        outcome: "failed",
                        reasonCode: "exception",
                        detail: error.localizedDescription,
                        dumpPath: dumpPath,
                        invalidModuleCount: nil
                    )
                    NSLog("[PlayTools] LibrarySourceInjection: partial module artifacts dumped to %@", dumpPath)
                } else {
                    appendReplacementAttemptEvent(
                        selector: selector,
                        cacheKey: cacheKey,
                        modules: modules,
                        outcome: "failed",
                        reasonCode: "exception",
                        detail: error.localizedDescription,
                        dumpPath: nil,
                        invalidModuleCount: nil
                    )
                }
            } else {
                appendReplacementAttemptEvent(
                    selector: selector,
                    cacheKey: cacheKey,
                    modules: modules,
                    outcome: "failed",
                    reasonCode: "exception",
                    detail: error.localizedDescription,
                    dumpPath: nil,
                    invalidModuleCount: nil
                )
            }
            return nil
        }
    }

    private enum AggregateReplacementFastMathMode: String {
        case enable
        case disable

        var fastMathEnabled: Bool {
            switch self {
            case .enable:
                return true
            case .disable:
                return false
            }
        }
    }

    private struct AggregateReplacementCompileDecision {
        let fastMathMode: AggregateReplacementFastMathMode?
        let options: MTLCompileOptions?
        let reason: String
    }

    private func inferAggregateReplacementFastMathMode(from irText: String) -> AggregateReplacementFastMathMode? {
        let hasDisable = irText.contains("air.compile.fast_math_disable")
        let hasEnable = irText.contains("air.compile.fast_math_enable")
        if hasDisable && !hasEnable {
            return .disable
        }
        if hasEnable && !hasDisable {
            return .enable
        }
        return nil
    }

    private func resolveAggregateReplacementCompileDecision(
        for preparedModules: [PreparedModuleReplacement]
    ) -> AggregateReplacementCompileDecision {
        let inferredModes = preparedModules.map { inferAggregateReplacementFastMathMode(from: $0.irResult.irText) }
        let knownModes = inferredModes.compactMap { $0 }
        guard let firstKnownMode = knownModes.first else {
            return AggregateReplacementCompileDecision(
                fastMathMode: nil,
                options: nil,
                reason: "fast_math_unavailable"
            )
        }
        guard knownModes.allSatisfy({ $0 == firstKnownMode }) else {
            return AggregateReplacementCompileDecision(
                fastMathMode: nil,
                options: nil,
                reason: "fast_math_conflict"
            )
        }
        guard knownModes.count == inferredModes.count else {
            return AggregateReplacementCompileDecision(
                fastMathMode: nil,
                options: nil,
                reason: "fast_math_partial"
            )
        }

        let options = MTLCompileOptions()
        options.fastMathEnabled = firstKnownMode.fastMathEnabled
        return AggregateReplacementCompileDecision(
            fastMathMode: firstKnownMode,
            options: options,
            reason: "fast_math_aligned"
        )
    }

    private struct PreparedModuleReplacement {
        let module: MetallibParser.BitcodeModule
        let irResult: LLVMDisassembler.DisassemblyResult
        let conversion: IRToMSLConverter.ConversionResult
    }

    private struct AggregateReplacementSource {
        let source: String
        let moduleCount: Int
        let functionCount: Int
        let totalIRSize: Int
        let moduleSummaries: String
    }

    private struct CorpusArtifactPaths: Codable {
        let bitcodePath: String
        let llvmIRPath: String
        let generatedMSLPath: String
        let metadataPath: String
    }

    private struct CorpusModuleManifest: Codable {
        let schemaVersion: Int
        let bundleId: String
        let moduleKey: String
        let moduleKeyStrategy: String
        let selector: String
        let observedSelectors: [String]
        let cacheKey: String
        let sourceCacheKeys: [String]
        let moduleRelativeOffset: UInt64
        let moduleSize: UInt64
        let functionNames: [String]
        let functionTypes: [String]
        let generatedFunctionNames: [String]
        let generatedFunctionTypes: [String]
        let timestamp: String
        let firstCapturedAt: String
        let lastCapturedAt: String
        let captureCount: Int
        let baselineConflictCount: Int
        let llvmDisStatus: String
        let converterStatus: String
        let compileStatus: String
        let bitcodeBytes: Int
        let llvmIRBytes: Int
        let generatedMSLBytes: Int
        let moduleSummary: String
        let irSummary: String
        let conversionSummary: String
        let corpusRelativeDirectory: String
        let artifactPaths: CorpusArtifactPaths
    }

    private struct CorpusManifestIndexEntry: Codable {
        let schemaVersion: Int
        let event: String
        let bundleId: String
        let selector: String
        let cacheKey: String
        let moduleKey: String
        let timestamp: String
        let captureAction: String
        let moduleRelativeOffset: UInt64
        let moduleSize: UInt64
        let corpusRelativeDirectory: String
        let metadataPath: String
        let artifactStatuses: [String: String]
        let functionNames: [String]
        let generatedFunctionNames: [String]
    }

    private struct ReplacementCorpusManifest: Codable {
        let schemaVersion: Int
        let bundleId: String
        let selector: String
        let cacheKey: String
        let timestamp: String
        let moduleKeys: [String]
        let moduleCount: Int
        let functionCount: Int
        let totalIRSize: Int
        let aggregateMSLBytes: Int
        let sourceFunctionNames: [String]
        let sourceFunctionTypes: [String]
        let moduleSummaries: [String]
        let aggregateSourcePath: String
        let corpusRelativeDirectory: String
    }

    private struct ReplacementManifestIndexEntry: Codable {
        let schemaVersion: Int
        let event: String
        let bundleId: String
        let selector: String
        let cacheKey: String
        let timestamp: String
        let corpusRelativeDirectory: String
        let aggregateSourcePath: String
        let moduleKeys: [String]
        let moduleCount: Int
        let functionCount: Int
        let totalIRSize: Int
        let aggregateMSLBytes: Int
        let sourceFunctionNames: [String]
        let sourceFunctionTypes: [String]
    }

    private struct ReplacementAttemptManifestIndexEntry: Codable {
        let schemaVersion: Int
        let event: String
        let bundleId: String
        let selector: String
        let cacheKey: String
        let timestamp: String
        let outcome: String
        let reasonCode: String?
        let detail: String?
        let dumpPath: String?
        let moduleKeys: [String]
        let moduleCount: Int
        let invalidModuleCount: Int?
    }

    private enum CorpusArtifactWriteStatus: String {
        case created
        case reused
        case conflictPreserved
    }

    private struct CorpusArtifactWriteResult {
        let path: String
        let status: CorpusArtifactWriteStatus
    }

    private struct ReplacementSourceValidationRule {
        let reason: String
        let regex: NSRegularExpression

        init(reason: String, pattern: String) {
            self.reason = reason
            self.regex = try! NSRegularExpression(pattern: pattern)
        }
    }

    private struct ReplacementSourceValidationIssue {
        let lineNumber: Int
        let reason: String
        let line: String

        var summary: String {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
            return "L\(lineNumber): \(reason) — \(preview)"
        }
    }

    private static let replacementSourceValidationRules: [ReplacementSourceValidationRule] = [
        ReplacementSourceValidationRule(
            reason: "LLVM vector syntax leaked into generated MSL",
            pattern: #"<\s*\d+\s+x\s+"#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM opaque pointer token leaked into generated MSL",
            pattern: #"(^|[^A-Za-z0-9_])ptr([^A-Za-z0-9_]|$)"#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM addrspace token leaked into generated MSL",
            pattern: #"addrspace\s*\("#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM SSA or struct token leaked into generated MSL",
            pattern: #"%[A-Za-z0-9_\.\"]+"#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM raw integer type leaked into generated MSL",
            pattern: #"(^|[^A-Za-z0-9_])(i1|i8|i16|i32|i64)([^A-Za-z0-9_]|$)"#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM symbol token leaked into generated MSL",
            pattern: #"@[A-Za-z0-9_\.\"]+"#
        ),
        ReplacementSourceValidationRule(
            reason: "LLVM placeholder token leaked into generated MSL",
            pattern: #"\b(?:undef|poison|zeroinitializer)\b"#
        )
    ]

    private static let compilerErrorLocationRegex = try! NSRegularExpression(
        pattern: #"program_source:(\d+):(\d+):"#
    )

    private enum ReplacementAggregationError: LocalizedError {
        case emptyModuleBody(String)

        var errorDescription: String? {
            switch self {
            case .emptyModuleBody(let moduleSummary):
                return "Aggregated MSL module body is empty: \(moduleSummary)"
            }
        }
    }

    private func buildAggregateReplacementSource(
        from preparedModules: [PreparedModuleReplacement]
    ) throws -> AggregateReplacementSource {
        // E-006c: 多模块 metallib（如 Unity 编译产物）可能包含同名函数的多个 shader variant。
        // MSL 不允许同一源文件中出现同名函数，因此对同名函数去重：保留首个模块，跳过后续重复。
        var seenFunctionNames: Set<String> = []
        var duplicateFunctionNames: Set<String> = []
        for prepared in preparedModules {
            for function in prepared.conversion.functions {
                let sanitized = sanitizeMSLIdentifier(function.name)
                if !seenFunctionNames.insert(sanitized).inserted {
                    duplicateFunctionNames.insert(sanitized)
                }
            }
        }

        // 去重：对每个唯一函数名只保留第一个出现的模块
        var deduplicatedModules: [PreparedModuleReplacement] = []
        var dedupSeenNames: Set<String> = []
        var skippedModuleCount = 0
        for prepared in preparedModules {
            let moduleFuncNames = prepared.conversion.functions.map { sanitizeMSLIdentifier($0.name) }
            let hasNewFunction = moduleFuncNames.contains { !dedupSeenNames.contains($0) }
            if hasNewFunction {
                deduplicatedModules.append(prepared)
                for name in moduleFuncNames {
                    dedupSeenNames.insert(name)
                }
            } else {
                skippedModuleCount += 1
            }
        }

        if !duplicateFunctionNames.isEmpty {
            NSLog("[PlayTools] LibrarySourceInjection: deduplicating %d modules with shared function name(s): %@ (keeping first occurrence of each, skipping %d modules)",
                  preparedModules.count,
                  duplicateFunctionNames.sorted().joined(separator: ", "),
                  skippedModuleCount)
        }

        guard !deduplicatedModules.isEmpty else {
            throw ReplacementAggregationError.emptyModuleBody("all modules deduplicated away")
        }

        var lines: [String] = [
            "//",
            "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection",
            "// E-005b: multi-module source aggregation",
            "// Generated at: \(ISO8601DateFormatter().string(from: Date()))",
            "// Modules: \(deduplicatedModules.count)/\(preparedModules.count)",
            "// Functions: \(deduplicatedModules.reduce(0) { $0 + $1.conversion.functions.count })",
            "//",
            "",
            "#include <metal_stdlib>",
            "using namespace metal;",
            ""
        ]

        for (index, prepared) in deduplicatedModules.enumerated() {
            let body = stripGeneratedMSLHeader(from: prepared.conversion.mslSource)
            guard !body.isEmpty else {
                throw ReplacementAggregationError.emptyModuleBody(prepared.module.summary)
            }
            lines.append("// ===== Module \(index) \(prepared.module.summary) =====")
            lines.append(body)
            lines.append("")
        }

        return AggregateReplacementSource(
            source: lines.joined(separator: "\n"),
            moduleCount: deduplicatedModules.count,
            functionCount: deduplicatedModules.reduce(0) { $0 + $1.conversion.functions.count },
            totalIRSize: deduplicatedModules.reduce(0) { $0 + $1.irResult.outputSize },
            moduleSummaries: deduplicatedModules.map { $0.module.summary }.joined(separator: "; ")
        )
    }

    private func stripGeneratedMSLHeader(from source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        if let headerIndex = lines.firstIndex(of: "using namespace metal;") {
            var bodyStart = headerIndex + 1
            while bodyStart < lines.count, lines[bodyStart].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodyStart += 1
            }
            return lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateAggregateReplacementSource(_ source: String) -> [ReplacementSourceValidationIssue] {
        let lines = source.components(separatedBy: "\n")
        var issues: [ReplacementSourceValidationIssue] = []

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }

            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for rule in Self.replacementSourceValidationRules {
                if rule.regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    issues.append(ReplacementSourceValidationIssue(
                        lineNumber: index + 1,
                        reason: rule.reason,
                        line: rawLine
                    ))
                    break
                }
            }

            if issues.count >= 12 {
                break
            }
        }

        return issues
    }

    private func compileErrorContext(in source: String, errorDescription: String) -> String? {
        guard let location = extractCompilerErrorLocation(from: errorDescription) else {
            return nil
        }

        let lines = source.components(separatedBy: "\n")
        guard location.line > 0, location.line <= lines.count else {
            return "errorLine=\(location.line), errorColumn=\(location.column)"
        }

        let sourceLine = lines[location.line - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return "errorLine=\(location.line), errorColumn=\(location.column), sourceLine=\(sourceLine)"
    }

    private func extractCompilerErrorLocation(from errorDescription: String) -> (line: Int, column: Int)? {
        let range = NSRange(errorDescription.startIndex..<errorDescription.endIndex, in: errorDescription)
        guard let match = Self.compilerErrorLocationRegex.firstMatch(in: errorDescription, options: [], range: range),
              match.numberOfRanges == 3,
              let lineRange = Range(match.range(at: 1), in: errorDescription),
              let columnRange = Range(match.range(at: 2), in: errorDescription),
              let line = Int(errorDescription[lineRange]),
              let column = Int(errorDescription[columnRange]) else {
            return nil
        }
        return (line, column)
    }

    @discardableResult
    private func dumpAggregateReplacementSource(
        _ source: String,
        selector: String,
        reason: String,
        detail: String,
        moduleSummaries: String,
        validationIssues: [ReplacementSourceValidationIssue],
        compilerErrorDescription: String?,
        preparedModules: [PreparedModuleReplacement]? = nil
    ) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: shaderSourceDiagnosticDirectoryURL, withIntermediateDirectories: true)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let baseName = sanitizeDiagnosticFilenameComponent("\(timestamp)_\(selector)_\(reason)")
            let sourceURL = shaderSourceDiagnosticDirectoryURL.appendingPathComponent("\(baseName).metal")
            let metaURL = shaderSourceDiagnosticDirectoryURL.appendingPathComponent("\(baseName).txt")

            try source.write(to: sourceURL, atomically: true, encoding: .utf8)

            var metadataLines: [String] = [
                "selector=\(selector)",
                "reason=\(reason)",
                "detail=\(detail)",
                "source_bytes=\(source.utf8.count)",
                "module_summaries=\(moduleSummaries)"
            ]

            if !validationIssues.isEmpty {
                metadataLines.append("validation_issue_count=\(validationIssues.count)")
                metadataLines.append(contentsOf: validationIssues.map { "validation_issue=\($0.summary)" })
            }

            if let compilerErrorDescription {
                metadataLines.append("compiler_error=\(compilerErrorDescription)")
                if let location = extractCompilerErrorLocation(from: compilerErrorDescription) {
                    metadataLines.append("compiler_error_line=\(location.line)")
                    metadataLines.append("compiler_error_column=\(location.column)")
                    let sourceLines = source.components(separatedBy: "\n")
                    let lowerBound = max(1, location.line - 2)
                    let upperBound = min(sourceLines.count, location.line + 2)
                    for lineNumber in lowerBound...upperBound {
                        metadataLines.append(String(format: "context_%03d=%@", lineNumber, sourceLines[lineNumber - 1]))
                    }
                }
            }

            try metadataLines.joined(separator: "\n").write(to: metaURL, atomically: true, encoding: .utf8)

            // E-004f4: Also dump per-module .bc/.ll/.metal for offline replay closure
            if let preparedModules, !preparedModules.isEmpty {
                let modulesDumpPath = dumpFailureModuleArtifacts(
                    preparedModules: preparedModules,
                    baseName: baseName,
                    selector: selector,
                    compileStatus: reason
                )
                if let modulesDumpPath {
                    NSLog("[PlayTools] LibrarySourceInjection: per-module artifacts dumped to %@", modulesDumpPath)
                }
            }

            return sourceURL.path
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to dump aggregate source diagnostic — %@",
                  error.localizedDescription)
            return nil
        }
    }

    // MARK: - E-004f4: Failure path module artifact export

    /// Dump per-module .bc/.ll/.metal/.meta.json for failed replacement samples.
    /// Enables offline replay of compile_failed / preflight_rejected samples.
    @discardableResult
    private func dumpFailureModuleArtifacts(
        preparedModules: [PreparedModuleReplacement],
        baseName: String,
        selector: String,
        compileStatus: String
    ) -> String? {
        let modulesBaseURL = shaderSourceDiagnosticDirectoryURL.appendingPathComponent("\(baseName)_modules", isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: modulesBaseURL, withIntermediateDirectories: true)

            for prepared in preparedModules {
                let moduleKey = stableCorpusModuleKey(for: prepared.module)
                let moduleDir = modulesBaseURL.appendingPathComponent(moduleKey, isDirectory: true)
                try fileManager.createDirectory(at: moduleDir, withIntermediateDirectories: true)

                try prepared.module.data.write(to: moduleDir.appendingPathComponent("module.bc"), options: .atomic)
                try Data(prepared.irResult.irText.utf8).write(to: moduleDir.appendingPathComponent("module.ll"), options: .atomic)
                try Data(prepared.conversion.mslSource.utf8).write(to: moduleDir.appendingPathComponent("module.generated.metal"), options: .atomic)

                let meta: [String: Any] = [
                    "schemaVersion": 2,
                    "bundleId": runtimeBundleIdentifier,
                    "moduleKey": moduleKey,
                    "moduleKeyStrategy": "sha256(module.bc)",
                    "selector": selector,
                    "functionNames": prepared.module.functionNames,
                    "functionTypes": prepared.module.functionTypes,
                    "generatedFunctionNames": prepared.conversion.functions.map(\.name),
                    "generatedFunctionTypes": prepared.conversion.functions.map(\.shaderType.rawValue),
                    "llvmDisStatus": "success",
                    "converterStatus": "success",
                    "compileStatus": compileStatus,
                    "bitcodeBytes": prepared.module.data.count,
                    "llvmIRBytes": prepared.irResult.outputSize,
                    "generatedMSLBytes": prepared.conversion.mslSource.utf8.count,
                    "captureSource": "failure_path",
                ]
                let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                try metaData.write(to: moduleDir.appendingPathComponent("module.meta.json"), options: .atomic)
            }

            NSLog("[PlayTools] LibrarySourceInjection: dumped %d module artifacts for offline replay (%@)",
                  preparedModules.count, compileStatus)
            return modulesBaseURL.path
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to dump failure module artifacts — %@",
                  error.localizedDescription)
            return nil
        }
    }

    /// Dump per-module .bc/.ll for partially prepared modules (exception path).
    /// Saves .bc for all modules, .ll/.metal only for successfully prepared ones.
    @discardableResult
    private func dumpPartialFailureModuleArtifacts(
        allModules: [MetallibParser.BitcodeModule],
        preparedModules: [PreparedModuleReplacement],
        baseName: String,
        selector: String,
        reason: String
    ) -> String? {
        let modulesBaseURL = shaderSourceDiagnosticDirectoryURL.appendingPathComponent("\(baseName)_modules", isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: modulesBaseURL, withIntermediateDirectories: true)

            let preparedCount = preparedModules.count
            for (index, module) in allModules.enumerated() {
                let moduleKey = stableCorpusModuleKey(for: module)
                let moduleDir = modulesBaseURL.appendingPathComponent(moduleKey, isDirectory: true)
                try fileManager.createDirectory(at: moduleDir, withIntermediateDirectories: true)

                // Always save .bc for every module
                try module.data.write(to: moduleDir.appendingPathComponent("module.bc"), options: .atomic)

                if index < preparedCount {
                    let prepared = preparedModules[index]
                    // Save .ll and .metal for successfully prepared modules
                    try Data(prepared.irResult.irText.utf8).write(to: moduleDir.appendingPathComponent("module.ll"), options: .atomic)
                    try Data(prepared.conversion.mslSource.utf8).write(to: moduleDir.appendingPathComponent("module.generated.metal"), options: .atomic)

                    // Minimal meta for offline replay
                    var metaLines: [String] = [
                        "schemaVersion=2",
                        "bundleId=\(runtimeBundleIdentifier)",
                        "moduleKey=\(moduleKey)",
                        "selector=\(selector)",
                        "functionNames=\(module.functionNames.joined(separator: ","))",
                        "functionTypes=\(module.functionTypes.joined(separator: ","))",
                        "llvmDisStatus=success",
                        "converterStatus=success",
                        "compileStatus=exception",
                        "captureSource=partial_failure_path",
                        "reason=\(reason)",
                    ]
                    try Data(metaLines.joined(separator: "\n").utf8).write(to: moduleDir.appendingPathComponent("module.meta.json"), options: .atomic)
                } else {
                    // Module not prepared — save minimal metadata
                    var metaLines: [String] = [
                        "schemaVersion=2",
                        "bundleId=\(runtimeBundleIdentifier)",
                        "moduleKey=\(moduleKey)",
                        "selector=\(selector)",
                        "functionNames=\(module.functionNames.joined(separator: ","))",
                        "functionTypes=\(module.functionTypes.joined(separator: ","))",
                        "llvmDisStatus=not_attempted",
                        "converterStatus=not_attempted",
                        "compileStatus=exception",
                        "captureSource=partial_failure_path",
                        "reason=\(reason)",
                    ]
                    try Data(metaLines.joined(separator: "\n").utf8).write(to: moduleDir.appendingPathComponent("module.meta.json"), options: .atomic)
                }
            }

            NSLog("[PlayTools] LibrarySourceInjection: dumped %d module artifacts for partial failure (%d/%d prepared)",
                  allModules.count, preparedCount, allModules.count)
            return modulesBaseURL.path
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to dump partial failure module artifacts — %@",
                  error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func dumpSuccessfulReplacementCorpus(
        _ preparedModules: [PreparedModuleReplacement],
        aggregate: AggregateReplacementSource,
        selector: String,
        cacheKey: String
    ) -> [String] {
        let fileManager = FileManager.default
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let indexEncoder = JSONEncoder()
        indexEncoder.outputFormatting = [.sortedKeys]

        do {
            try fileManager.createDirectory(at: shaderCorpusDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: shaderCorpusModulesDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: shaderCorpusReplacementsDirectoryURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: shaderCorpusManifestIndexURL.path) {
                fileManager.createFile(atPath: shaderCorpusManifestIndexURL.path, contents: nil)
            }
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to create shader corpus root %@ — %@",
                  shaderCorpusDirectoryURL.path,
                  error.localizedDescription)
            return []
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        var dumpedDirectories: [String] = []
        dumpedDirectories.reserveCapacity(preparedModules.count + 1)

        do {
            let replacementDirectoryName = sanitizeDiagnosticFilenameComponent("\(timestamp)_\(selector)_\(cacheKey)")
            let replacementDirectoryURL = shaderCorpusReplacementsDirectoryURL.appendingPathComponent(replacementDirectoryName, isDirectory: true)
            let aggregateSourceURL = replacementDirectoryURL.appendingPathComponent("aggregate.generated.metal")
            let metadataURL = replacementDirectoryURL.appendingPathComponent("replacement.meta.json")
            let relativeDirectory = corpusRelativePath(for: replacementDirectoryURL)
            let aggregateSourceRelativePath = corpusRelativePath(for: aggregateSourceURL)
            let sourceFunctionNames = Array(Set(preparedModules.flatMap { prepared in
                prepared.conversion.functions.map { $0.name }
            })).sorted()
            let sourceFunctionTypes = Array(Set(preparedModules.flatMap { $0.conversion.functions.map { $0.shaderType.rawValue } })).sorted()
            let moduleKeys = preparedModules.map { stableCorpusModuleKey(for: $0.module) }.sorted()
            let moduleSummaries = preparedModules.map { $0.module.summary }

            try fileManager.createDirectory(at: replacementDirectoryURL, withIntermediateDirectories: true)
            try Data(aggregate.source.utf8).write(to: aggregateSourceURL, options: .atomic)

            let replacementManifest = ReplacementCorpusManifest(
                schemaVersion: corpusManifestSchemaVersion,
                bundleId: runtimeBundleIdentifier,
                selector: selector,
                cacheKey: cacheKey,
                timestamp: timestamp,
                moduleKeys: moduleKeys,
                moduleCount: aggregate.moduleCount,
                functionCount: aggregate.functionCount,
                totalIRSize: aggregate.totalIRSize,
                aggregateMSLBytes: aggregate.source.utf8.count,
                sourceFunctionNames: sourceFunctionNames,
                sourceFunctionTypes: sourceFunctionTypes,
                moduleSummaries: moduleSummaries,
                aggregateSourcePath: aggregateSourceRelativePath,
                corpusRelativeDirectory: relativeDirectory
            )
            let replacementMetadataData = try manifestEncoder.encode(replacementManifest)
            try replacementMetadataData.write(to: metadataURL, options: .atomic)

            let replacementIndexEntry = ReplacementManifestIndexEntry(
                schemaVersion: corpusManifestSchemaVersion,
                event: "replacement",
                bundleId: runtimeBundleIdentifier,
                selector: selector,
                cacheKey: cacheKey,
                timestamp: timestamp,
                corpusRelativeDirectory: relativeDirectory,
                aggregateSourcePath: aggregateSourceRelativePath,
                moduleKeys: moduleKeys,
                moduleCount: aggregate.moduleCount,
                functionCount: aggregate.functionCount,
                totalIRSize: aggregate.totalIRSize,
                aggregateMSLBytes: aggregate.source.utf8.count,
                sourceFunctionNames: sourceFunctionNames,
                sourceFunctionTypes: sourceFunctionTypes
            )
            try appendCorpusManifestIndexEntry(replacementIndexEntry, encoder: indexEncoder)
            dumpedDirectories.append(replacementDirectoryURL.path)
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to dump replacement aggregate corpus for %@ — %@",
                  selector,
                  error.localizedDescription)
        }

        for prepared in preparedModules {
            let moduleKey = stableCorpusModuleKey(for: prepared.module)
            let moduleDirectoryURL = shaderCorpusModuleDirectoryURL(moduleKey: moduleKey)
            let bitcodeURL = moduleDirectoryURL.appendingPathComponent("module.bc")
            let irURL = moduleDirectoryURL.appendingPathComponent("module.ll")
            let generatedMSLURL = moduleDirectoryURL.appendingPathComponent("module.generated.metal")
            let metadataURL = moduleDirectoryURL.appendingPathComponent("module.meta.json")
            let relativeDirectory = corpusRelativePath(for: moduleDirectoryURL)
            let artifactPaths = CorpusArtifactPaths(
                bitcodePath: corpusRelativePath(for: bitcodeURL),
                llvmIRPath: corpusRelativePath(for: irURL),
                generatedMSLPath: corpusRelativePath(for: generatedMSLURL),
                metadataPath: corpusRelativePath(for: metadataURL)
            )

            do {
                try fileManager.createDirectory(at: moduleDirectoryURL, withIntermediateDirectories: true)

                let bitcodeWrite = try writeCorpusArtifact(prepared.module.data, to: bitcodeURL)
                let irWrite = try writeCorpusArtifact(Data(prepared.irResult.irText.utf8), to: irURL)
                let generatedMSLWrite = try writeCorpusArtifact(Data(prepared.conversion.mslSource.utf8), to: generatedMSLURL)
                let artifactResults = [
                    "module.bc": bitcodeWrite,
                    "module.ll": irWrite,
                    "module.generated.metal": generatedMSLWrite,
                ]
                let existingManifest = loadCorpusModuleManifest(at: metadataURL)
                let hasConflict = artifactResults.values.contains { $0.status == .conflictPreserved }
                let mergedSelectors = appendingUnique(existingManifest?.observedSelectors ?? [existingManifest?.selector].compactMap { $0 }, value: selector)
                let mergedCacheKeys = appendingUnique(existingManifest?.sourceCacheKeys ?? [existingManifest?.cacheKey].compactMap { $0 }, value: cacheKey)
                let manifest = CorpusModuleManifest(
                    schemaVersion: corpusManifestSchemaVersion,
                    bundleId: runtimeBundleIdentifier,
                    moduleKey: moduleKey,
                    moduleKeyStrategy: "sha256(module.bc)",
                    selector: existingManifest?.selector ?? selector,
                    observedSelectors: mergedSelectors,
                    cacheKey: existingManifest?.cacheKey ?? cacheKey,
                    sourceCacheKeys: mergedCacheKeys,
                    moduleRelativeOffset: existingManifest?.moduleRelativeOffset ?? prepared.module.relativeOffset,
                    moduleSize: prepared.module.size,
                    functionNames: prepared.module.functionNames,
                    functionTypes: prepared.module.functionTypes,
                    generatedFunctionNames: prepared.conversion.functions.map(\.name),
                    generatedFunctionTypes: prepared.conversion.functions.map { $0.shaderType.rawValue },
                    timestamp: timestamp,
                    firstCapturedAt: existingManifest?.firstCapturedAt ?? timestamp,
                    lastCapturedAt: timestamp,
                    captureCount: (existingManifest?.captureCount ?? 0) + 1,
                    baselineConflictCount: (existingManifest?.baselineConflictCount ?? 0) + (hasConflict ? 1 : 0),
                    llvmDisStatus: "success",
                    converterStatus: "success",
                    compileStatus: "success",
                    bitcodeBytes: prepared.module.data.count,
                    llvmIRBytes: prepared.irResult.outputSize,
                    generatedMSLBytes: prepared.conversion.mslSource.utf8.count,
                    moduleSummary: prepared.module.summary,
                    irSummary: prepared.irResult.summary,
                    conversionSummary: prepared.conversion.summary,
                    corpusRelativeDirectory: relativeDirectory,
                    artifactPaths: artifactPaths
                )
                let metadataData = try manifestEncoder.encode(manifest)
                try metadataData.write(to: metadataURL, options: .atomic)

                let captureAction: String
                if hasConflict {
                    captureAction = "conflict_preserved"
                } else if existingManifest == nil {
                    captureAction = "new"
                } else {
                    captureAction = "reused"
                }

                let indexEntry = CorpusManifestIndexEntry(
                    schemaVersion: corpusManifestSchemaVersion,
                    event: "capture",
                    bundleId: runtimeBundleIdentifier,
                    selector: selector,
                    cacheKey: cacheKey,
                    moduleKey: moduleKey,
                    timestamp: timestamp,
                    captureAction: captureAction,
                    moduleRelativeOffset: prepared.module.relativeOffset,
                    moduleSize: prepared.module.size,
                    corpusRelativeDirectory: relativeDirectory,
                    metadataPath: artifactPaths.metadataPath,
                    artifactStatuses: artifactResults.mapValues { $0.status.rawValue },
                    functionNames: prepared.module.functionNames,
                    generatedFunctionNames: prepared.conversion.functions.map(\.name)
                )
                try appendCorpusManifestIndexEntry(indexEntry, encoder: indexEncoder)

                if hasConflict {
                    NSLog("[PlayTools] LibrarySourceInjection: corpus baseline preserved for %@ (moduleKey=%@, statuses=%@)",
                          prepared.module.summary,
                          moduleKey,
                          artifactResults.map { "\($0.key)=\($0.value.status.rawValue)" }.sorted().joined(separator: ", "))
                }

                dumpedDirectories.append(moduleDirectoryURL.path)
            } catch {
                NSLog("[PlayTools] LibrarySourceInjection: failed to dump shader corpus module %@ — %@",
                      prepared.module.summary,
                      error.localizedDescription)
            }
        }

        return dumpedDirectories
    }

    private func shaderCorpusModuleDirectoryURL(moduleKey: String) -> URL {
        shaderCorpusModulesDirectoryURL.appendingPathComponent(moduleKey, isDirectory: true)
    }

    private func stableCorpusModuleKey(for module: MetallibParser.BitcodeModule) -> String {
        sha256Hex(for: module.data)
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func corpusRelativePath(for url: URL) -> String {
        let rootPath = shaderCorpusDirectoryURL.path
        let fullPath = url.path
        guard fullPath.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }
        let relativePath = String(fullPath.dropFirst(rootPath.count))
        return relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
    }

    private func appendingUnique(_ values: [String], value: String) -> [String] {
        guard !values.contains(value) else {
            return values
        }
        return values + [value]
    }

    private func loadCorpusModuleManifest(at url: URL) -> CorpusModuleManifest? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CorpusModuleManifest.self, from: data)
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to decode existing corpus manifest %@ — %@",
                  url.path,
                  error.localizedDescription)
            return nil
        }
    }

    private func writeCorpusArtifact(_ data: Data, to url: URL) throws -> CorpusArtifactWriteResult {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let existingData = try Data(contentsOf: url)
            if existingData == data {
                return CorpusArtifactWriteResult(path: corpusRelativePath(for: url), status: .reused)
            }
            return CorpusArtifactWriteResult(path: corpusRelativePath(for: url), status: .conflictPreserved)
        }
        try data.write(to: url, options: .atomic)
        return CorpusArtifactWriteResult(path: corpusRelativePath(for: url), status: .created)
    }

    private func appendCorpusManifestIndexEntry<Entry: Encodable>(
        _ entry: Entry,
        encoder: JSONEncoder
    ) throws {
        let entryData = try encoder.encode(entry)
        if !FileManager.default.fileExists(atPath: shaderCorpusManifestIndexURL.path) {
            FileManager.default.createFile(atPath: shaderCorpusManifestIndexURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: shaderCorpusManifestIndexURL)
        defer {
            try? handle.close()
        }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: entryData)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private func appendReplacementAttemptEvent(
        selector: String,
        cacheKey: String,
        modules: [MetallibParser.BitcodeModule],
        outcome: String,
        reasonCode: String?,
        detail: String?,
        dumpPath: String?,
        invalidModuleCount: Int?
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entry = ReplacementAttemptManifestIndexEntry(
            schemaVersion: corpusManifestSchemaVersion,
            event: "replacement_attempt",
            bundleId: runtimeBundleIdentifier,
            selector: selector,
            cacheKey: cacheKey,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            outcome: outcome,
            reasonCode: reasonCode,
            detail: detail,
            dumpPath: dumpPath,
            moduleKeys: modules.map { stableCorpusModuleKey(for: $0) }.sorted(),
            moduleCount: modules.count,
            invalidModuleCount: invalidModuleCount
        )

        do {
            try appendCorpusManifestIndexEntry(entry, encoder: encoder)
        } catch {
            NSLog("[PlayTools] LibrarySourceInjection: failed to append replacement attempt event for %@ — %@",
                  selector,
                  error.localizedDescription)
        }
    }

    private func sanitizeDiagnosticFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return sanitized.isEmpty ? "diagnostic" : sanitized
    }

    private func sanitizeMSLIdentifier(_ name: String) -> String {
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        return result.isEmpty ? "_unnamed" : result
    }

    private func functionCount(of library: AnyObject) -> Int {
        if library.responds(to: NSSelectorFromString("functionNames")) {
            let names = library.value(forKey: "functionNames") as? [String] ?? []
            return names.count
        }
        return -1
    }

    func cacheKey(for data: Data) -> String {
        computeCacheKey(data)
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

    private func bypassReasonForReplacement(selector: String, cacheKey: String) -> String? {
        _ = selector
        _ = cacheKey
        return nil
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
