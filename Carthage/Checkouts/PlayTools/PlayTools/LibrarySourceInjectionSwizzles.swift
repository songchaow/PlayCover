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
        LibrarySourceInjectionService.shared.logLibraryCreation(
            selector: "newLibraryWithData:error:",
            device: self,
            library: library,
            dataSize: (data as? Data)?.count,
            extraInfo: nil
        )
        // E-004: 解析 metallib 二进制格式，提取函数和 section 信息
        MetallibParser.safeParseAndLog(dispatchData: data, selector: "newLibraryWithData:error:")
        return library
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
