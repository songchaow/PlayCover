//
//  MetallibParser.swift
//  PlayTools
//
//  E-004: metallib 二进制格式解析器
//  从 metallib Data 中提取 header、section 信息和函数 tag 元数据。
//  参考: https://worthdoingbadly.com/metalbitcode/
//         https://github.com/YuAo/MetalLibraryArchive
//

import Foundation

// MARK: - MetallibParser

/// 解析 metallib (MTLB) 二进制格式，提取 header、section 和函数 tag 信息。
///
/// metallib 文件布局:
/// ```
/// [Header 88 bytes]
///   magic: "MTLB" (4 bytes)
///   platform, version, fileSize, sections offsets/sizes ...
/// [Function List]
///   per-function tag groups (NAME, TYPE, HASH, MDSZ, OFFT, VERS ... ENDT)
/// [Public Metadata]
/// [Private Metadata]
/// [Bitcode / Module Data]
/// [Sources] (optional, present when compiled with -frecord-sources)
/// ```
struct MetallibParser {

    // MARK: - Error types

    enum ParseError: LocalizedError {
        case dataTooShort(expected: Int, actual: Int)
        case invalidMagic(Data)
        case unsupportedHeaderSize(UInt16)
        case sectionOutOfBounds(name: String, offset: UInt64, size: UInt64, fileSize: UInt64)
        case tagOutOfBounds(offset: Int, remaining: Int)
        case invalidTagGroup

        var errorDescription: String? {
            switch self {
            case .dataTooShort(let expected, let actual):
                return "metallib data too short: expected ≥\(expected) bytes, got \(actual)"
            case .invalidMagic(let magic):
                let hex = magic.map { String(format: "%02X", $0) }.joined()
                return "invalid metallib magic: expected 4D544C42 (MTLB), got \(hex)"
            case .unsupportedHeaderSize(let size):
                return "unsupported metallib header size: \(size)"
            case .sectionOutOfBounds(let name, let offset, let size, let fileSize):
                return "section '\(name)' out of bounds: offset=\(offset), size=\(size), fileSize=\(fileSize)"
            case .tagOutOfBounds(let offset, let remaining):
                return "tag at offset \(offset) exceeds data bounds (remaining=\(remaining))"
            case .invalidTagGroup:
                return "invalid tag group structure"
            }
        }
    }

    // MARK: - Parsed types

    /// metallib header 信息
    struct Header {
        let magic: UInt32            // 0x424C544D = "MTLB"
        let platformAndVersion: UInt32
        let osVersion: UInt32
        let headerSize: UInt16
        let fileType: UInt8          // 0x00 = executable, 0x02 = dynamic
        let targetPlatform: UInt8
        let fileSize: UInt64
        let functionListOffset: UInt64
        let functionListSize: UInt64
        let publicMetadataOffset: UInt64
        let publicMetadataSize: UInt64
        let privateMetadataOffset: UInt64
        let privateMetadataSize: UInt64
        let bitcodeOffset: UInt64
        let bitcodeSize: UInt64

        /// 平台描述字符串
        var platformDescription: String {
            switch targetPlatform {
            case 0x01: return "iOS"
            case 0x81: return "macOS"
            case 0x02: return "tvOS"
            case 0x03: return "watchOS"
            case 0x04: return "bridgeOS"
            case 0x05: return "macCatalyst"
            case 0x06: return "iOSSimulator"
            case 0x07: return "tvOSSimulator"
            case 0x08: return "watchOSSimulator"
            default: return "unknown(0x\(String(format: "%02x", targetPlatform)))"
            }
        }

        var summary: String {
            [
                "magic=MTLB",
                "platform=\(platformDescription)",
                "fileSize=\(fileSize)",
                "headerSize=\(headerSize)",
                "funcList=(\(functionListOffset),\(functionListSize))",
                "pubMeta=(\(publicMetadataOffset),\(publicMetadataSize))",
                "privMeta=(\(privateMetadataOffset),\(privateMetadataSize))",
                "bitcode=(\(bitcodeOffset),\(bitcodeSize))",
            ].joined(separator: ", ")
        }
    }

    /// 函数 tag 中的一个标签
    struct Tag {
        let name: String     // 4 char code, e.g. "NAME", "TYPE", "MDSZ", "OFFT"
        let payload: Data
    }

    /// 一个函数的全部 tag 元数据
    struct FunctionEntry {
        let tags: [Tag]

        /// 函数名称（从 NAME tag 提取）
        var functionName: String? {
            guard let nameTag = tags.first(where: { $0.name == "NAME" }) else { return nil }
            // NAME payload 是 null-terminated string
            return String(data: nameTag.payload, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        /// 函数类型（从 TYPE tag 提取）
        var functionType: UInt8? {
            guard let typeTag = tags.first(where: { $0.name == "TYPE" }) else { return nil }
            return typeTag.payload.first
        }

        /// 函数类型描述
        var functionTypeDescription: String {
            guard let type = functionType else { return "unknown" }
            switch type {
            case 0: return "vertex"
            case 1: return "fragment"
            case 2: return "kernel"
            case 3: return "unqualified"
            case 4: return "visible"
            case 5: return "extern"
            case 6: return "intersection"
            case 7: return "mesh"
            case 8: return "object"
            default: return "unknown(\(type))"
            }
        }

        /// bitcode 偏移和大小（从 OFFT tag 提取；偏移量是相对于 bitcode section 起始位置的）
        var bitcodeOffset: UInt64? {
            guard let offtTag = tags.first(where: { $0.name == "OFFT" }) else { return nil }
            guard offtTag.payload.count >= 8 else { return nil }
            return offtTag.payload.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }

        /// bitcode 数据大小（从 MDSZ tag 提取）
        var bitcodeSize: UInt64? {
            guard let mdszTag = tags.first(where: { $0.name == "MDSZ" }) else { return nil }
            guard mdszTag.payload.count >= 8 else { return nil }
            return mdszTag.payload.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }

        /// SHA256 hash（从 HASH tag 提取）
        var hash: Data? {
            tags.first(where: { $0.name == "HASH" })?.payload
        }

        var summary: String {
            let name = functionName ?? "?"
            let type = functionTypeDescription
            let offset = bitcodeOffset.map { "\($0)" } ?? "?"
            let size = bitcodeSize.map { "\($0)" } ?? "?"
            let hashHex = hash?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "?"
            return "\(name) (\(type)) bitcode=[\(offset)+\(size)] hash=\(hashHex)..."
        }
    }

    /// metallib 中检测到的额外 section（如 SOURCES）
    struct ExtraSection {
        let name: String
        let offset: UInt64
        let size: UInt64
    }

    /// 解析结果
    struct ParseResult {
        let header: Header
        let functions: [FunctionEntry]
        let extraSections: [ExtraSection]
        /// 原始数据的引用（方便后续提取 bitcode）
        let data: Data

        /// 文件中是否包含 SOURCES section
        var hasSources: Bool {
            extraSections.contains { $0.name == "SOURCES" }
        }

        /// 提取指定函数的 bitcode 数据
        func extractBitcode(for function: FunctionEntry) -> Data? {
            guard let relOffset = function.bitcodeOffset,
                  let size = function.bitcodeSize else { return nil }
            let absOffset = header.bitcodeOffset + relOffset
            let end = absOffset + size
            guard end <= UInt64(data.count) else { return nil }
            return data.subdata(in: Int(absOffset)..<Int(end))
        }

        /// 提取所有函数的 bitcode 数据，返回 [(函数名, bitcode Data)]
        func extractAllBitcode() -> [(name: String, data: Data)] {
            functions.compactMap { entry in
                guard let name = entry.functionName,
                      let bc = extractBitcode(for: entry) else { return nil }
                return (name, bc)
            }
        }

        var summary: String {
            var lines = [
                "metallib: \(header.summary)",
                "functions: \(functions.count)",
            ]
            for (i, f) in functions.enumerated() {
                lines.append("  [\(i)] \(f.summary)")
            }
            if !extraSections.isEmpty {
                lines.append("extra sections: \(extraSections.map { "\($0.name)(\($0.offset),\($0.size))" }.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Parsing

    /// 从 Data 解析 metallib。
    /// 这是主入口方法，供 swizzle hook 在拦截到 metallib 数据后调用。
    static func parse(_ data: Data) throws -> ParseResult {
        // 1. 解析 header
        let header = try parseHeader(data)

        // 2. 解析函数列表中的 tag group
        let functions = try parseFunctionList(data, header: header)

        // 3. 探测额外 section（如 SOURCES）
        let extraSections = detectExtraSections(data, header: header)

        return ParseResult(
            header: header,
            functions: functions,
            extraSections: extraSections,
            data: data
        )
    }

    /// 从 __DispatchData 解析 metallib（供 swizzle hook 直接调用）。
    static func parse(dispatchData: __DispatchData) throws -> ParseResult {
        // dispatch_data_t → Data
        let nsData = dispatchData as AnyObject
        let data: Data
        if let d = nsData as? Data {
            data = d
        } else {
            // 通过 NSData 桥接
            let dd = unsafeBitCast(dispatchData, to: DispatchData.self)
            var collected = Data()
            dd.enumerateBytes { buffer, _, _ in
                collected.append(contentsOf: buffer)
            }
            data = collected
        }
        return try parse(data)
    }

    // MARK: - Header parsing

    /// 最小 header 大小（MTLB 基础 header）
    private static let minimumHeaderSize = 56

    private static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= minimumHeaderSize else {
            throw ParseError.dataTooShort(expected: minimumHeaderSize, actual: data.count)
        }

        // Validate magic "MTLB" = 0x424C544D (little-endian: 4D 54 4C 42)
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let expectedMagic: UInt32 = 0x424C544D
        guard magic == expectedMagic else {
            throw ParseError.invalidMagic(data.subdata(in: 0..<4))
        }

        let platformAndVersion = readUInt32(data, offset: 4)
        let osVersion = readUInt32(data, offset: 8)
        let headerSize = readUInt16(data, offset: 12)
        let fileType = readUInt8(data, offset: 14)
        let targetPlatform = readUInt8(data, offset: 15)
        let fileSize = readUInt64(data, offset: 16)

        let funcListOffset = readUInt64(data, offset: 24)
        let funcListSize = readUInt64(data, offset: 32)

        // 根据 header size 决定后续 section 信息的布局
        // 最常见的 headerSize: 56 (0x38) 或 88 (0x58)
        let pubMetaOffset: UInt64
        let pubMetaSize: UInt64
        let privMetaOffset: UInt64
        let privMetaSize: UInt64
        let bitcodeOffset: UInt64
        let bitcodeSize: UInt64

        if headerSize >= 80 && data.count >= 80 {
            // 扩展 header 格式（常见于较新版本的 metallib）
            pubMetaOffset = readUInt64(data, offset: 40)
            pubMetaSize = readUInt64(data, offset: 48)
            privMetaOffset = readUInt64(data, offset: 56)
            privMetaSize = readUInt64(data, offset: 64)
            bitcodeOffset = readUInt64(data, offset: 72)
            bitcodeSize = readUInt64(data, offset: 80)
        } else if headerSize >= 56 && data.count >= 56 {
            // 紧凑 header 格式
            pubMetaOffset = readUInt64(data, offset: 40)
            pubMetaSize = readUInt64(data, offset: 48)
            // 私有元数据和 bitcode 通过推算得出
            privMetaOffset = pubMetaOffset + pubMetaSize
            let remainingAfterPubMeta = UInt64(data.count) - privMetaOffset
            // 简单启发：私有元数据和 bitcode 各占剩余空间一半
            // 实际上需要从函数 tag OFFT 中推断，先用保守估计
            privMetaSize = 0
            bitcodeOffset = privMetaOffset
            bitcodeSize = remainingAfterPubMeta
        } else {
            throw ParseError.unsupportedHeaderSize(headerSize)
        }

        return Header(
            magic: magic,
            platformAndVersion: platformAndVersion,
            osVersion: osVersion,
            headerSize: headerSize,
            fileType: fileType,
            targetPlatform: targetPlatform,
            fileSize: fileSize,
            functionListOffset: funcListOffset,
            functionListSize: funcListSize,
            publicMetadataOffset: pubMetaOffset,
            publicMetadataSize: pubMetaSize,
            privateMetadataOffset: privMetaOffset,
            privateMetadataSize: privMetaSize,
            bitcodeOffset: bitcodeOffset,
            bitcodeSize: bitcodeSize
        )
    }

    // MARK: - Function list parsing

    private static func parseFunctionList(_ data: Data, header: Header) throws -> [FunctionEntry] {
        let start = Int(header.functionListOffset)
        let end = start + Int(header.functionListSize)
        guard start >= 0, end <= data.count, start < end else {
            if header.functionListSize == 0 { return [] }
            throw ParseError.sectionOutOfBounds(
                name: "FunctionList",
                offset: header.functionListOffset,
                size: header.functionListSize,
                fileSize: UInt64(data.count)
            )
        }

        var functions: [FunctionEntry] = []
        var cursor = start

        // 函数列表由连续的 tag group 组成，每个 tag group 以 ENDT 结束
        while cursor < end {
            let remaining = end - cursor
            guard remaining >= 4 else { break }

            var tags: [Tag] = []
            var tagGroupValid = false

            while cursor < end {
                guard cursor + 6 <= end else { break }  // tag name(4) + size(2) minimum

                let tagName = readFourCC(data, offset: cursor)
                cursor += 4

                // ENDT 标签标记 tag group 结束
                if tagName == "ENDT" {
                    tagGroupValid = true
                    break
                }

                // 读取 payload 大小
                let payloadSize: Int
                if tagName == "SARC" {
                    // SARC tag 使用 4 字节大小
                    guard cursor + 4 <= end else { break }
                    payloadSize = Int(readUInt32(data, offset: cursor))
                    cursor += 4
                } else {
                    guard cursor + 2 <= end else { break }
                    payloadSize = Int(readUInt16(data, offset: cursor))
                    cursor += 2
                }

                guard cursor + payloadSize <= end else { break }
                let payload = data.subdata(in: cursor..<(cursor + payloadSize))
                cursor += payloadSize

                tags.append(Tag(name: tagName, payload: payload))
            }

            if tagGroupValid && !tags.isEmpty {
                functions.append(FunctionEntry(tags: tags))
            } else if !tags.isEmpty {
                // 部分解析的 tag group（可能数据截断）
                functions.append(FunctionEntry(tags: tags))
                break
            } else {
                break
            }
        }

        return functions
    }

    // MARK: - Extra section detection

    /// 检测 bitcode section 之后的额外 section（如 SOURCES）。
    /// `-frecord-sources` 编译的 metallib 在 bitcode 之后会有 SOURCES section。
    private static func detectExtraSections(_ data: Data, header: Header) -> [ExtraSection] {
        var sections: [ExtraSection] = []

        // 计算已知 section 的结束位置
        let knownEnd = max(
            header.functionListOffset + header.functionListSize,
            max(
                header.publicMetadataOffset + header.publicMetadataSize,
                max(
                    header.privateMetadataOffset + header.privateMetadataSize,
                    header.bitcodeOffset + header.bitcodeSize
                )
            )
        )

        // 如果文件大小超过已知 section 的结束位置，可能有额外 section
        if UInt64(data.count) > knownEnd + 16 {
            let extraStart = Int(knownEnd)
            let extraSize = data.count - extraStart

            // 尝试识别 section 类型
            // SOURCES section 通常以 bzip2 压缩数据开始（magic: "BZ"），或以特定标记开头
            let sectionName = identifySectionType(data, offset: extraStart, size: extraSize)
            sections.append(ExtraSection(
                name: sectionName,
                offset: knownEnd,
                size: UInt64(extraSize)
            ))
        }

        return sections
    }

    /// 尝试识别额外 section 的类型
    private static func identifySectionType(_ data: Data, offset: Int, size: Int) -> String {
        guard offset + 4 <= data.count else { return "UNKNOWN" }

        // 检查是否有 section tag（metal-objdump 输出中看到的 section 名称）
        let fourcc = readFourCC(data, offset: offset)
        if fourcc == "SRCS" || fourcc == "SOUR" {
            return "SOURCES"
        }

        // 检查 bzip2 magic（SOURCES 通常是 bzip2 压缩的）
        if size >= 2 {
            let b0 = data[offset]
            let b1 = data[offset + 1]
            if b0 == 0x42 && b1 == 0x5A { // "BZ"
                return "SOURCES(bzip2)"
            }
        }

        // 检查 MSL 文本特征
        if size >= 16 {
            let sample = data.subdata(in: offset..<min(offset + 256, data.count))
            if let text = String(data: sample, encoding: .utf8),
               text.contains("#include") || text.contains("metal_stdlib") || text.contains("using namespace") {
                return "SOURCES(text)"
            }
        }

        return "EXTRA(\(fourcc))"
    }

    // MARK: - Binary reading helpers

    private static func readUInt8(_ data: Data, offset: Int) -> UInt8 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt8.self) }
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }

    private static func readFourCC(_ data: Data, offset: Int) -> String {
        guard offset + 4 <= data.count else { return "????" }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}

// MARK: - Integration with LibrarySourceInjectionService

extension MetallibParser {
    /// 安全地尝试解析 metallib 数据并记录结果。
    /// 解析失败不会中断 library 创建流程。
    static func safeParseAndLog(_ data: Data, selector: String) {
        do {
            let result = try parse(data)
            NSLog("[PlayTools] MetallibParser: %@ — %@",
                  selector,
                  result.summary.replacingOccurrences(of: "\n", with: " | "))
        } catch {
            NSLog("[PlayTools] MetallibParser: %@ — parse failed: %@",
                  selector, error.localizedDescription)
        }
    }

    /// 安全地尝试解析 dispatch_data_t 并记录结果。
    static func safeParseAndLog(dispatchData: __DispatchData, selector: String) {
        let nsData = dispatchData as AnyObject
        let data: Data
        if let d = nsData as? Data {
            data = d
        } else {
            let dd = unsafeBitCast(dispatchData, to: DispatchData.self)
            var collected = Data()
            dd.enumerateBytes { buffer, _, _ in
                collected.append(contentsOf: buffer)
            }
            data = collected
        }
        safeParseAndLog(data, selector: selector)
    }
}
