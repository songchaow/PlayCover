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
import ObjectiveC
import zlib

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

    // MARK: - Bitcode module

    /// 一个从 metallib 中提取出的 LLVM Bitcode 模块。
    /// 多个函数可能共享同一个模块（相同偏移/大小），此类型对其进行去重和验证。
    struct BitcodeModule {
        /// 模块在 bitcode section 内的相对偏移
        let relativeOffset: UInt64
        /// 模块数据大小
        let size: UInt64
        /// 提取出的原始 bitcode 数据
        let data: Data
        /// 引用此模块的函数名列表
        let functionNames: [String]
        /// 引用此模块的函数类型列表
        let functionTypes: [String]

        /// bitcode 是否以有效的 LLVM bitcode magic 开头。
        /// LLVM bitcode wrapper: 0xDEC04342 ("BC\xC0\xDE")
        /// LLVM IR bitstream:    0x4243      ("BC" at offset 0..1)
        var isValidLLVMBitcode: Bool {
            guard data.count >= 4 else { return false }
            return data.withUnsafeBytes { buf in
                let b0 = buf.load(fromByteOffset: 0, as: UInt8.self)
                let b1 = buf.load(fromByteOffset: 1, as: UInt8.self)
                // LLVM bitcode wrapper magic: DE C0 17 0B
                if b0 == 0xDE && b1 == 0xC0 { return true }
                // Raw LLVM bitstream magic: "BC" (0x42 0x43)
                if b0 == 0x42 && b1 == 0x43 { return true }
                return false
            }
        }

        /// bitcode magic 描述（用于调试日志）
        var magicDescription: String {
            guard data.count >= 4 else { return "too_short" }
            let hex = data.prefix(4).map { String(format: "%02X", $0) }.joined()
            if isValidLLVMBitcode {
                return data.withUnsafeBytes { buf in
                    let b0 = buf.load(fromByteOffset: 0, as: UInt8.self)
                    return b0 == 0xDE ? "llvm_wrapper(\(hex))" : "llvm_bitstream(\(hex))"
                }
            }
            return "unknown(\(hex))"
        }

        var summary: String {
            let names = functionNames.prefix(3).joined(separator: ",")
            let suffix = functionNames.count > 3 ? "..." : ""
            return "module[offset=\(relativeOffset),size=\(size)," +
                   "magic=\(magicDescription),funcs=\(functionNames.count)(\(names)\(suffix))]"
        }
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
            extraSections.contains { $0.name.hasPrefix("SOURCES") }
        }

        /// 提取指定函数的 bitcode 数据
        func extractBitcode(for function: FunctionEntry) -> Data? {
            guard let relOffset = function.bitcodeOffset,
                  let size = function.bitcodeSize,
                  size > 0 else { return nil }
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

        /// **E-004b 核心方法**：提取去重后的 LLVM Bitcode 模块列表。
        ///
        /// metallib 中多个函数可能引用同一个 bitcode 模块（相同的 offset+size），
        /// 此方法将它们合并为唯一的 `BitcodeModule`，并附带引用它的所有函数名。
        ///
        /// - Returns: 去重后的 bitcode 模块数组，按偏移量排序
        func extractBitcodeModules() -> [BitcodeModule] {
            // 按 (relativeOffset, size) 分组函数
            struct ModuleKey: Hashable {
                let offset: UInt64
                let size: UInt64
            }

            var groups: [ModuleKey: (names: [String], types: [String])] = [:]
            var orderedKeys: [ModuleKey] = []

            for entry in functions {
                guard let relOffset = entry.bitcodeOffset,
                      let size = entry.bitcodeSize,
                      size > 0 else { continue }
                let key = ModuleKey(offset: relOffset, size: size)
                if groups[key] == nil {
                    orderedKeys.append(key)
                    groups[key] = (names: [], types: [])
                }
                let name = entry.functionName ?? "<unnamed>"
                let type = entry.functionTypeDescription
                groups[key]!.names.append(name)
                groups[key]!.types.append(type)
            }

            // 按偏移量排序并提取数据
            return orderedKeys.sorted(by: { $0.offset < $1.offset }).compactMap { key in
                let absOffset = header.bitcodeOffset + key.offset
                let end = absOffset + key.size
                guard end <= UInt64(data.count) else { return nil }
                let bcData = data.subdata(in: Int(absOffset)..<Int(end))
                guard let group = groups[key] else { return nil }
                return BitcodeModule(
                    relativeOffset: key.offset,
                    size: key.size,
                    data: bcData,
                    functionNames: group.names,
                    functionTypes: group.types
                )
            }
        }

        /// 整个 bitcode section 的原始数据
        var rawBitcodeSection: Data? {
            guard header.bitcodeSize > 0 else { return nil }
            let start = Int(header.bitcodeOffset)
            let end = start + Int(header.bitcodeSize)
            guard end <= data.count else { return nil }
            return data.subdata(in: start..<end)
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

    private struct UnwrappedPayload {
        let data: Data
        let strategy: String
    }

    private struct EmbeddedDataCandidate {
        let path: String
        let data: Data
    }

    private struct ZipArchiveEntry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let payloadOffset: Int
    }

    private struct XarArchiveHeader {
        let headerSize: Int
        let tocCompressedSize: Int
        let tocUncompressedSize: Int
    }

    private struct XarArchiveEntry {
        let path: String
        let encodingStyle: String?
        let payloadOffset: Int
        let payloadLength: Int
        let uncompressedSize: Int?
    }

    private final class XarXMLNode {
        let name: String
        let attributes: [String: String]
        var children: [XarXMLNode] = []
        private var textParts: [String] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func appendText(_ text: String) {
            textParts.append(text)
        }

        var textContent: String {
            textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func firstChild(named childName: String) -> XarXMLNode? {
            children.first { $0.name == childName }
        }

        func childText(named childName: String) -> String? {
            firstChild(named: childName)?.textContent
        }

        func childElements(named childName: String) -> [XarXMLNode] {
            children.filter { $0.name == childName }
        }
    }

    private final class XarTOCXMLParser: NSObject, XMLParserDelegate {
        private var stack: [XarXMLNode] = []
        private(set) var root: XarXMLNode?

        func parse(_ data: Data) -> XarXMLNode? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else {
                return nil
            }
            return root
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String : String] = [:]
        ) {
            let node = XarXMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.appendText(string)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            _ = stack.popLast()
        }
    }

    private struct PayloadDiagnosticContext {
        let selector: String
        let dispatchClassName: String
        let callStackLines: [String]

        var metadataLines: [String] {
            [
                "originSelector=\(selector)",
                "dispatchClass=\(dispatchClassName)",
            ] + callStackLines
        }

        var logSummary: String {
            callStackLines.joined(separator: "\n")
        }
    }

    private static let payloadDumpLock = NSLock()
    private static var dumpedPayloadKeys: Set<String> = []
    private static let maxPayloadDumpsPerLaunch = 8
    private static let payloadDiagnosticContextLock = NSLock()
    private static var payloadDiagnosticContexts: [String: PayloadDiagnosticContext] = [:]

    /// dispatch_data_t → Data 转换辅助方法
    static func convertDispatchData(_ dispatchData: __DispatchData) -> Data {
        let nsData = dispatchData as AnyObject
        if let d = nsData as? Data {
            return d
        }
        let dd = unsafeBitCast(dispatchData, to: DispatchData.self)
        var collected = Data()
        dd.enumerateBytes { buffer, _, _ in
            collected.append(contentsOf: buffer)
        }
        if collected.isEmpty {
            NSLog("[PlayTools] MetallibParser: dispatch_data converted to empty Data (class=%@)",
                  objectClassName(nsData))
        }
        return collected
    }

    /// **E-005e1**: 对 `newLibraryWithData` 收到的 payload 做前导字节指纹识别，
    /// 用于定位非原始 MTLB wrapper / archive / compression 形态。
    static func payloadDebugSummary(_ data: Data) -> String {
        guard !data.isEmpty else {
            return "kind=empty, bytes=0"
        }

        let prefixBytes = Array(data.prefix(16))
        let prefixHex = prefixBytes.map { String(format: "%02X", $0) }.joined()
        let asciiPreview = String(prefixBytes.map { byte in
            if byte >= 0x20 && byte <= 0x7E {
                return Character(UnicodeScalar(byte))
            }
            return "."
        })

        let kind: String
        switch payloadKindLabel(for: data) {
        case "mtlb_like", "mtlb_suspicious":
            let headerSize = data.count >= 14 ? readUInt16(data, offset: 12) : 0
            let fileType = data.count >= 15 ? readUInt8(data, offset: 14) : 0
            let targetPlatform = data.count >= 16 ? readUInt8(data, offset: 15) : 0
            let fileSize = data.count >= 24 ? readUInt64(data, offset: 16) : 0
            let base = payloadKindLabel(for: data)
            if let reason = suspiciousMTLBReason(for: data) {
                kind = "\(base)(\(reason),headerSize=\(headerSize),fileType=\(fileType),target=0x\(String(format: "%02X", targetPlatform)),fileSize=\(fileSize))"
            } else {
                kind = "\(base)(headerSize=\(headerSize),fileType=\(fileType),target=0x\(String(format: "%02X", targetPlatform)),fileSize=\(fileSize))"
            }
        default:
            kind = payloadKindLabel(for: data)
        }

        return "kind=\(kind), bytes=\(data.count), prefixHex=\(prefixHex), ascii=\(asciiPreview)"
    }

    private static func payloadKindLabel(for data: Data) -> String {
        guard !data.isEmpty else {
            return "empty"
        }
        if hasPrefix(data, ascii: "MTLB") {
            return isPlausibleRawMetallib(data) ? "mtlb_like" : "mtlb_suspicious"
        }
        if hasPrefix(data, ascii: "bplist00") {
            return "bplist"
        }
        if hasPrefix(data, ascii: "BC") {
            return "llvm_bitstream"
        }
        if data.count >= 2 && data[0] == 0xDE && data[1] == 0xC0 {
            return "llvm_wrapper"
        }
        if data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B {
            return "gzip"
        }
        if data.count >= 2 && data[0] == 0x42 && data[1] == 0x5A {
            return "bzip2"
        }
        if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
            return "zip"
        }
        if data.count >= 4 && data[0] == 0x78 && data[1] == 0x61 && data[2] == 0x72 && data[3] == 0x21 {
            return "xar"
        }
        if data.count >= 1 && (data[0] == 0x7B || data[0] == 0x5B) {
            return "json_like"
        }
        return "unknown"
    }

    private static func hasPrefix(_ data: Data, ascii: String) -> Bool {
        data.starts(with: ascii.utf8)
    }

    private static func suspiciousMTLBReason(for data: Data) -> String? {
        guard hasPrefix(data, ascii: "MTLB") else {
            return nil
        }
        if data.count < minimumHeaderSize {
            return "too_short=\(data.count)"
        }

        let headerSize = data.count >= 14 ? readUInt16(data, offset: 12) : 0
        if headerSize < minimumHeaderSize {
            return "headerSize=\(headerSize)"
        }

        let declaredFileSize = data.count >= 24 ? readUInt64(data, offset: 16) : 0
        if declaredFileSize == 0 {
            return "fileSize=0"
        }
        if declaredFileSize < UInt64(minimumHeaderSize) {
            return "fileSize=\(declaredFileSize)"
        }
        if declaredFileSize > UInt64(data.count) {
            return "fileSize=\(declaredFileSize)>bytes=\(data.count)"
        }

        return nil
    }

    private static func isPlausibleRawMetallib(_ data: Data) -> Bool {
        suspiciousMTLBReason(for: data) == nil
    }

    private static func payloadFingerprint(_ data: Data) -> String {
        let kind = payloadKindLabel(for: data)
        let prefixHex = data.prefix(8).map { String(format: "%02X", $0) }.joined()
        let suffixHex = data.suffix(8).map { String(format: "%02X", $0) }.joined()
        return "\(kind)|\(data.count)|\(prefixHex)|\(suffixHex)"
    }

    static func shouldCapturePayloadOrigin(_ data: Data) -> Bool {
        !data.isEmpty && payloadKindLabel(for: data) != "mtlb_like"
    }

    /// **E-005e1b**: 对首次观测到的非 `MTLB` payload 记录上游调用上下文，
    /// 便于下一轮 live 复现时直接从日志或样本元数据反推是谁喂给了 `newLibraryWithData`。
    static func capturePayloadOriginIfNeeded(
        _ data: Data,
        selector: String,
        dispatchClassName: String,
        callStackSymbols: [String]
    ) -> String? {
        guard shouldCapturePayloadOrigin(data) else {
            return nil
        }

        let key = payloadFingerprint(data)
        let context = PayloadDiagnosticContext(
            selector: selector,
            dispatchClassName: dispatchClassName,
            callStackLines: formatPayloadCallStack(callStackSymbols)
        )

        payloadDiagnosticContextLock.lock()
        defer { payloadDiagnosticContextLock.unlock() }
        guard payloadDiagnosticContexts[key] == nil else {
            return nil
        }
        payloadDiagnosticContexts[key] = context
        return context.logSummary
    }

    private static func formatPayloadCallStack(_ callStackSymbols: [String]) -> [String] {
        let frames = callStackSymbols
            .dropFirst(2)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let limitedFrames = Array(frames.prefix(12))
        if limitedFrames.isEmpty {
            return ["callStack=unavailable"]
        }
        return limitedFrames.enumerated().map { index, frame in
            "callStack[\(index)]=\(frame)"
        }
    }

    private static func objectClassName(_ object: AnyObject) -> String {
        if let runtimeClass = object_getClass(object) {
            return NSStringFromClass(runtimeClass)
        }
        return NSStringFromClass(type(of: object))
    }

    private static let maxPayloadUnwrapDepth = 4
    private static let maxDecompressedPayloadBytes = 64 * 1024 * 1024

    private static func unwrapMetallibPayloadIfNeeded(_ data: Data, depth: Int = 0) -> UnwrappedPayload? {
        guard depth < maxPayloadUnwrapDepth else {
            return nil
        }

        let kind = payloadKindLabel(for: data)
        guard kind != "mtlb_like" else {
            return nil
        }

        if kind == "mtlb_suspicious" {
            return recoverMetallibCandidate(data, path: "payload", depth: depth + 1)
        }

        if kind == "gzip",
           let decompressed = decompressGzipPayload(data),
           let recovered = recoverMetallibCandidate(decompressed, path: "gzip", depth: depth + 1) {
            return recovered
        }

        if kind == "zip",
           let embedded = unwrapMetallibFromZipPayload(data, depth: depth + 1) {
            return embedded
        }

        if kind == "xar",
           let embedded = unwrapMetallibFromXarPayload(data, depth: depth + 1) {
            return embedded
        }

        if hasPrefix(data, ascii: "bplist00"),
           let embedded = unwrapMetallibFromPropertyList(data, depth: depth + 1) {
            return embedded
        }

        if let embedded = findEmbeddedMetallib(in: data, path: "payload", includeZeroOffset: false) {
            return UnwrappedPayload(data: embedded.data, strategy: embedded.strategy)
        }

        return nil
    }

    private static func recoverMetallibCandidate(
        _ data: Data,
        path: String,
        depth: Int
    ) -> UnwrappedPayload? {
        let kind = payloadKindLabel(for: data)
        switch kind {
        case "mtlb_like":
            let trimmed = trimMetallibDataIfNeeded(data)
            return UnwrappedPayload(data: trimmed, strategy: path)
        case "mtlb_suspicious":
            if let embedded = findEmbeddedMetallib(in: data, path: path, includeZeroOffset: false) {
                return embedded
            }
            return nil
        default:
            break
        }

        if let nested = unwrapMetallibPayloadIfNeeded(data, depth: depth) {
            return UnwrappedPayload(data: nested.data, strategy: "\(path)→\(nested.strategy)")
        }
        if let embedded = findEmbeddedMetallib(in: data, path: path, includeZeroOffset: false) {
            return UnwrappedPayload(data: embedded.data, strategy: embedded.strategy)
        }
        return nil
    }

    private static func unwrapMetallibFromPropertyList(_ data: Data, depth: Int) -> UnwrappedPayload? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
            return nil
        }

        let candidates = collectEmbeddedDataCandidates(from: propertyList, path: "$root")
        for candidate in candidates {
            if let recovered = recoverMetallibCandidate(
                candidate.data,
                path: "bplist:\(candidate.path)",
                depth: depth
            ) {
                return recovered
            }
        }

        return nil
    }

    private static func decompressGzipPayload(_ data: Data) -> Data? {
        inflatePayload(data, windowBits: 15 + 32)
    }

    private static func decompressDeflatedZipEntry(_ data: Data, uncompressedSizeHint: Int) -> Data? {
        inflatePayload(data, windowBits: -15, sizeHint: uncompressedSizeHint)
    }

    private static func inflatePayload(_ data: Data, windowBits: Int32, sizeHint: Int? = nil) -> Data? {
        guard !data.isEmpty, data.count <= Int(UInt32.max) else {
            return nil
        }

        var stream = z_stream()
        let initStatus = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(data.count)
            return inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard initStatus == Z_OK else {
            return nil
        }
        defer {
            inflateEnd(&stream)
        }

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()
        if let sizeHint, sizeHint > 0 {
            output.reserveCapacity(min(sizeHint, maxDecompressedPayloadBytes))
        }

        while true {
            let status = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_BUF_ERROR
                }
                stream.next_out = baseAddress
                stream.avail_out = uInt(chunkSize)
                return inflate(&stream, Z_NO_FLUSH)
            }

            let producedBytes = chunkSize - Int(stream.avail_out)
            if producedBytes > 0 {
                output.append(contentsOf: buffer[..<producedBytes])
                if output.count > maxDecompressedPayloadBytes {
                    return nil
                }
            }

            if status == Z_STREAM_END {
                return output
            }
            if status != Z_OK {
                return nil
            }
            if producedBytes == 0 && stream.avail_in == 0 {
                return nil
            }
        }
    }

    private static func unwrapMetallibFromZipPayload(_ data: Data, depth: Int) -> UnwrappedPayload? {
        let entries = zipArchiveEntries(in: data)
        guard !entries.isEmpty else {
            return nil
        }

        for entry in entries {
            guard let entryData = extractZipEntryPayload(data, entry: entry), !entryData.isEmpty else {
                continue
            }

            let entryPath = "zip:\(entry.path)"
            if let recovered = recoverMetallibCandidate(entryData, path: entryPath, depth: depth) {
                return recovered
            }
        }

        return nil
    }

    private static func zipArchiveEntries(in data: Data) -> [ZipArchiveEntry] {
        let centralDirectoryEntries = parseZipCentralDirectoryEntries(in: data)
        if !centralDirectoryEntries.isEmpty {
            return centralDirectoryEntries
        }
        return parseZipLocalFileEntries(in: data)
    }

    private static func parseZipCentralDirectoryEntries(in data: Data) -> [ZipArchiveEntry] {
        guard let endOfCentralDirectoryOffset = findZipEndOfCentralDirectory(in: data),
              endOfCentralDirectoryOffset + 22 <= data.count else {
            return []
        }

        let totalEntries = Int(readUInt16(data, offset: endOfCentralDirectoryOffset + 10))
        let centralDirectorySize = Int(readUInt32(data, offset: endOfCentralDirectoryOffset + 12))
        let centralDirectoryOffset = Int(readUInt32(data, offset: endOfCentralDirectoryOffset + 16))
        guard totalEntries > 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            return []
        }

        var entries: [ZipArchiveEntry] = []
        var cursor = centralDirectoryOffset
        while cursor + 46 <= data.count,
              readUInt32(data, offset: cursor) == 0x02014B50,
              entries.count < totalEntries {
            let compressionMethod = readUInt16(data, offset: cursor + 10)
            let compressedSize = readUInt32(data, offset: cursor + 20)
            let uncompressedSize = readUInt32(data, offset: cursor + 24)
            let fileNameLength = Int(readUInt16(data, offset: cursor + 28))
            let extraFieldLength = Int(readUInt16(data, offset: cursor + 30))
            let commentLength = Int(readUInt16(data, offset: cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, offset: cursor + 42))
            let recordEnd = cursor + 46 + fileNameLength + extraFieldLength + commentLength
            guard recordEnd <= data.count else {
                break
            }

            let fileNameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + fileNameLength))
            let path = sanitizeZipEntryPath(fileNameData, fallbackIndex: entries.count)
            if let payloadOffset = zipLocalFilePayloadOffset(in: data, localHeaderOffset: localHeaderOffset),
               !path.hasSuffix("/") {
                entries.append(ZipArchiveEntry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    payloadOffset: payloadOffset
                ))
            }
            cursor = recordEnd
        }

        return entries
    }

    private static func parseZipLocalFileEntries(in data: Data) -> [ZipArchiveEntry] {
        var entries: [ZipArchiveEntry] = []
        var cursor = 0

        while cursor + 30 <= data.count {
            let signature = readUInt32(data, offset: cursor)
            if signature == 0x02014B50 || signature == 0x06054B50 {
                break
            }
            guard signature == 0x04034B50 else {
                return entries.isEmpty ? [] : entries
            }

            let generalPurposeFlags = readUInt16(data, offset: cursor + 6)
            let compressionMethod = readUInt16(data, offset: cursor + 8)
            let compressedSize = readUInt32(data, offset: cursor + 18)
            let uncompressedSize = readUInt32(data, offset: cursor + 22)
            let fileNameLength = Int(readUInt16(data, offset: cursor + 26))
            let extraFieldLength = Int(readUInt16(data, offset: cursor + 28))
            let payloadOffset = cursor + 30 + fileNameLength + extraFieldLength
            guard payloadOffset <= data.count else {
                break
            }

            let fileNameData = data.subdata(in: (cursor + 30)..<(cursor + 30 + fileNameLength))
            let path = sanitizeZipEntryPath(fileNameData, fallbackIndex: entries.count)
            let usesDataDescriptor = (generalPurposeFlags & 0x0008) != 0
            if !path.hasSuffix("/"), !usesDataDescriptor {
                entries.append(ZipArchiveEntry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    payloadOffset: payloadOffset
                ))
            }

            let nextCursor = payloadOffset + Int(compressedSize)
            guard nextCursor > cursor else {
                break
            }
            cursor = nextCursor
        }

        return entries
    }

    private static func findZipEndOfCentralDirectory(in data: Data) -> Int? {
        let minimumEOCDSize = 22
        guard data.count >= minimumEOCDSize else {
            return nil
        }

        let searchStart = max(0, data.count - minimumEOCDSize - 65_535)
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else {
            return nil
        }

        var offset = bytes.count - signature.count
        while offset >= searchStart {
            if bytes[offset] == signature[0],
               bytes[offset + 1] == signature[1],
               bytes[offset + 2] == signature[2],
               bytes[offset + 3] == signature[3] {
                return offset
            }
            offset -= 1
        }

        return nil
    }

    private static func zipLocalFilePayloadOffset(in data: Data, localHeaderOffset: Int) -> Int? {
        guard localHeaderOffset >= 0,
              localHeaderOffset + 30 <= data.count,
              readUInt32(data, offset: localHeaderOffset) == 0x04034B50 else {
            return nil
        }

        let fileNameLength = Int(readUInt16(data, offset: localHeaderOffset + 26))
        let extraFieldLength = Int(readUInt16(data, offset: localHeaderOffset + 28))
        let payloadOffset = localHeaderOffset + 30 + fileNameLength + extraFieldLength
        guard payloadOffset <= data.count else {
            return nil
        }
        return payloadOffset
    }

    private static func extractZipEntryPayload(_ archiveData: Data, entry: ZipArchiveEntry) -> Data? {
        let compressedSize = Int(entry.compressedSize)
        guard compressedSize >= 0,
              entry.payloadOffset >= 0,
              entry.payloadOffset + compressedSize <= archiveData.count else {
            return nil
        }

        let compressedData = archiveData.subdata(in: entry.payloadOffset..<(entry.payloadOffset + compressedSize))
        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return decompressDeflatedZipEntry(compressedData, uncompressedSizeHint: Int(entry.uncompressedSize))
        default:
            return nil
        }
    }

    private static func sanitizeZipEntryPath(_ data: Data, fallbackIndex: Int) -> String {
        if let path = String(data: data, encoding: .utf8), !path.isEmpty {
            return path
        }
        let hex = data.prefix(12).map { String(format: "%02X", $0) }.joined()
        return "entry_\(fallbackIndex)_\(hex.isEmpty ? "unknown" : hex)"
    }

    private static func unwrapMetallibFromXarPayload(_ data: Data, depth: Int) -> UnwrappedPayload? {
        let entries = parseXarArchiveEntries(in: data)
        guard !entries.isEmpty else {
            return nil
        }

        for entry in entries {
            guard let entryData = extractXarEntryPayload(data, entry: entry), !entryData.isEmpty else {
                continue
            }

            let entryPath = "xar:\(entry.path)"
            if let recovered = recoverMetallibCandidate(entryData, path: entryPath, depth: depth) {
                return recovered
            }
        }

        return nil
    }

    private static func parseXarArchiveEntries(in data: Data) -> [XarArchiveEntry] {
        guard let header = parseXarArchiveHeader(data) else {
            return []
        }

        let tocStart = header.headerSize
        let tocEnd = tocStart + header.tocCompressedSize
        guard tocStart >= 0,
              tocEnd >= tocStart,
              tocEnd <= data.count else {
            return []
        }

        let compressedTOC = data.subdata(in: tocStart..<tocEnd)
        guard let tocXMLData = decompressXarTOC(compressedTOC, expectedSize: header.tocUncompressedSize) else {
            return []
        }

        let parser = XarTOCXMLParser()
        guard let rootNode = parser.parse(tocXMLData) else {
            return []
        }

        let heapStart = tocEnd
        let tocNode = rootNode.name == "toc" ? rootNode : rootNode.firstChild(named: "toc")
        guard let tocNode else {
            return []
        }

        var entries: [XarArchiveEntry] = []
        for fileNode in tocNode.childElements(named: "file") {
            collectXarArchiveEntries(
                from: fileNode,
                parentPath: "",
                heapStart: heapStart,
                archiveSize: data.count,
                into: &entries
            )
        }
        return entries
    }

    private static func parseXarArchiveHeader(_ data: Data) -> XarArchiveHeader? {
        let minimumHeaderBytes = 28
        guard data.count >= minimumHeaderBytes,
              readBigEndianUInt32(data, offset: 0) == 0x78617221 else {
            return nil
        }

        let headerSize = Int(readBigEndianUInt16(data, offset: 4))
        let tocCompressedSize = Int(readBigEndianUInt64(data, offset: 8))
        let tocUncompressedSize = Int(readBigEndianUInt64(data, offset: 16))
        guard headerSize >= minimumHeaderBytes,
              headerSize <= data.count,
              tocCompressedSize >= 0,
              tocUncompressedSize >= 0,
              headerSize + tocCompressedSize <= data.count else {
            return nil
        }

        return XarArchiveHeader(
            headerSize: headerSize,
            tocCompressedSize: tocCompressedSize,
            tocUncompressedSize: tocUncompressedSize
        )
    }

    private static func decompressXarTOC(_ data: Data, expectedSize: Int) -> Data? {
        inflatePayload(data, windowBits: 15, sizeHint: expectedSize)
            ?? inflatePayload(data, windowBits: 15 + 32, sizeHint: expectedSize)
            ?? inflatePayload(data, windowBits: -15, sizeHint: expectedSize)
    }

    private static func collectXarArchiveEntries(
        from fileNode: XarXMLNode,
        parentPath: String,
        heapStart: Int,
        archiveSize: Int,
        into entries: inout [XarArchiveEntry]
    ) {
        let rawName = fileNode.childText(named: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryName = sanitizeXarEntryName(rawName, fallbackIndex: entries.count)
        let fullPath = parentPath.isEmpty ? entryName : "\(parentPath)/\(entryName)"

        if let dataNode = fileNode.firstChild(named: "data"),
           let offsetText = dataNode.childText(named: "offset")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let lengthText = dataNode.childText(named: "length")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let relativeOffset = Int(offsetText),
           let payloadLength = Int(lengthText),
           relativeOffset >= 0,
           payloadLength > 0 {
            let payloadOffset = heapStart + relativeOffset
            if payloadOffset >= 0, payloadOffset + payloadLength <= archiveSize {
                let uncompressedSize = dataNode.childText(named: "size")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap(Int.init)
                let encodingStyle = dataNode.firstChild(named: "encoding")?.attributes["style"]
                entries.append(XarArchiveEntry(
                    path: fullPath,
                    encodingStyle: encodingStyle,
                    payloadOffset: payloadOffset,
                    payloadLength: payloadLength,
                    uncompressedSize: uncompressedSize
                ))
            }
        }

        for childFile in fileNode.childElements(named: "file") {
            collectXarArchiveEntries(
                from: childFile,
                parentPath: fullPath,
                heapStart: heapStart,
                archiveSize: archiveSize,
                into: &entries
            )
        }
    }

    private static func sanitizeXarEntryName(_ value: String?, fallbackIndex: Int) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.replacingOccurrences(of: "/", with: "_")
        if !normalized.isEmpty {
            return normalized
        }
        return "entry_\(fallbackIndex)"
    }

    private static func extractXarEntryPayload(_ archiveData: Data, entry: XarArchiveEntry) -> Data? {
        guard entry.payloadOffset >= 0,
              entry.payloadLength > 0,
              entry.payloadOffset + entry.payloadLength <= archiveData.count else {
            return nil
        }

        let storedData = archiveData.subdata(in: entry.payloadOffset..<(entry.payloadOffset + entry.payloadLength))
        let encodingStyle = normalizedXarEncodingStyle(entry.encodingStyle)
        switch encodingStyle {
        case "none":
            return storedData
        case "gzip", "zlib":
            return inflatePayload(storedData, windowBits: 15 + 32, sizeHint: entry.uncompressedSize)
                ?? inflatePayload(storedData, windowBits: 15, sizeHint: entry.uncompressedSize)
                ?? inflatePayload(storedData, windowBits: -15, sizeHint: entry.uncompressedSize)
                ?? storedData
        default:
            return storedData
        }
    }

    private static func normalizedXarEncodingStyle(_ style: String?) -> String {
        guard let normalized = style?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return "none"
        }

        switch normalized {
        case "application/octet-stream", "application/x-raw", "application/x-uncompressed", "none":
            return "none"
        case "application/x-gzip", "application/gzip", "gzip":
            return "gzip"
        case "application/zlib", "application/x-zlib", "zlib":
            return "zlib"
        default:
            return normalized
        }
    }

    private static func readBigEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).bigEndian }
    }

    private static func readBigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }

    private static func readBigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self).bigEndian }
    }

    private static func collectEmbeddedDataCandidates(from value: Any, path: String) -> [EmbeddedDataCandidate] {
        var results: [EmbeddedDataCandidate] = []
        collectEmbeddedDataCandidates(from: value, path: path, into: &results)
        return results
    }

    private static func collectEmbeddedDataCandidates(
        from value: Any,
        path: String,
        into results: inout [EmbeddedDataCandidate]
    ) {
        if results.count >= 64 {
            return
        }

        switch value {
        case let data as Data:
            results.append(EmbeddedDataCandidate(path: path, data: data))
        case let array as NSArray:
            for (index, element) in array.enumerated() {
                collectEmbeddedDataCandidates(from: element, path: "\(path)[\(index)]", into: &results)
                if results.count >= 64 {
                    return
                }
            }
        case let dictionary as NSDictionary:
            let sortedKeys = dictionary.allKeys.sorted {
                String(describing: $0) < String(describing: $1)
            }
            for key in sortedKeys {
                guard let element = dictionary[key] else { continue }
                collectEmbeddedDataCandidates(from: element, path: "\(path).\(String(describing: key))", into: &results)
                if results.count >= 64 {
                    return
                }
            }
        default:
            break
        }
    }

    private static func findEmbeddedMetallib(
        in data: Data,
        path: String,
        includeZeroOffset: Bool
    ) -> UnwrappedPayload? {
        guard data.count >= 8 else {
            return nil
        }

        let magic = Array("MTLB".utf8)
        let bytes = [UInt8](data)
        let startOffset = includeZeroOffset ? 0 : 1
        guard startOffset <= bytes.count - magic.count else {
            return nil
        }

        for offset in startOffset...(bytes.count - magic.count) {
            let matches = bytes[offset] == magic[0]
                && bytes[offset + 1] == magic[1]
                && bytes[offset + 2] == magic[2]
                && bytes[offset + 3] == magic[3]
            guard matches else { continue }

            let candidate = data.subdata(in: offset..<data.count)
            do {
                let parsed = try parse(candidate)
                let trimmed = trimMetallibDataIfNeeded(candidate, parsedHeader: parsed.header)
                return UnwrappedPayload(data: trimmed, strategy: "\(path).embeddedMTLB@\(offset)")
            } catch {
                continue
            }
        }

        return nil
    }

    private static func trimMetallibDataIfNeeded(_ data: Data, parsedHeader: Header? = nil) -> Data {
        let header: Header
        if let parsedHeader {
            header = parsedHeader
        } else if let parsed = try? parse(data) {
            header = parsed.header
        } else {
            return data
        }

        let declaredSize = Int(header.fileSize)
        guard declaredSize > 0, declaredSize <= data.count else {
            return data
        }
        return data.subdata(in: 0..<declaredSize)
    }

    private static func dumpPayloadSampleIfNeeded(
        _ data: Data,
        reason: String,
        recoveredBy strategy: String? = nil
    ) {
        let kind = payloadKindLabel(for: data)
        guard kind != "mtlb_like", !data.isEmpty else {
            return
        }

        let dumpKey = payloadFingerprint(data)

        payloadDumpLock.lock()
        defer { payloadDumpLock.unlock() }

        guard dumpedPayloadKeys.count < maxPayloadDumpsPerLaunch else {
            return
        }
        guard dumpedPayloadKeys.insert(dumpKey).inserted else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let dumpDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("ShaderPayloadSamples", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true)

            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let baseName = sanitizeFilenameComponent("\(timestamp)_\(kind)_\(data.count)B")
            let binaryURL = dumpDirectory.appendingPathComponent("\(baseName).bin")
            let metaURL = dumpDirectory.appendingPathComponent("\(baseName).txt")
            try data.write(to: binaryURL, options: .atomic)

            var metadataLines = [
                "reason=\(reason)",
                "bundleIdentifier=\(bundleIdentifier)",
                "summary=\(payloadDebugSummary(data))",
            ]
            if let strategy {
                metadataLines.append("recoveredBy=\(strategy)")
            }

            payloadDiagnosticContextLock.lock()
            let diagnosticContext = payloadDiagnosticContexts[dumpKey]
            payloadDiagnosticContextLock.unlock()
            if let diagnosticContext {
                metadataLines.append(contentsOf: diagnosticContext.metadataLines)
            }

            try metadataLines.joined(separator: "\n").write(to: metaURL, atomically: true, encoding: .utf8)

            if kind == "bplist" {
                var format = PropertyListSerialization.PropertyListFormat.binary
                if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
                   let xmlData = try? PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0) {
                    let plistURL = dumpDirectory.appendingPathComponent("\(baseName).plist")
                    try? xmlData.write(to: plistURL, options: .atomic)
                }
            }

            NSLog("[PlayTools] MetallibParser: dumped payload sample to %@ (reason=%@)",
                  binaryURL.path, reason)
        } catch {
            NSLog("[PlayTools] MetallibParser: payload dump failed: %@ (%@)",
                  error.localizedDescription, payloadDebugSummary(data))
        }
    }

    private static func sanitizeFilenameComponent(_ value: String) -> String {
        let invalid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).inverted
        return value.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 安全地尝试解析 metallib 数据并记录结果。
    /// 解析失败不会中断 library 创建流程。
    static func safeParseAndLog(_ data: Data, selector: String) {
        do {
            let result = try parse(data)
            NSLog("[PlayTools] MetallibParser: %@ — %@",
                  selector,
                  result.summary.replacingOccurrences(of: "\n", with: " | "))

            // E-004b: 提取并记录 bitcode 模块信息
            let modules = result.extractBitcodeModules()
            let validCount = modules.filter { $0.isValidLLVMBitcode }.count
            let totalSize = modules.reduce(0) { $0 + $1.size }
            NSLog("[PlayTools] MetallibParser: %@ — bitcode modules: %d (valid_llvm=%d, total_size=%llu)",
                  selector, modules.count, validCount, totalSize)
            for (i, mod) in modules.enumerated() {
                NSLog("[PlayTools] MetallibParser:   [%d] %@", i, mod.summary)
            }
        } catch {
            if let unwrapped = unwrapMetallibPayloadIfNeeded(data),
               let result = try? parse(unwrapped.data) {
                let modules = result.extractBitcodeModules()
                NSLog("[PlayTools] MetallibParser: %@ — recovered wrapped metallib via %@ (%@)",
                      selector, unwrapped.strategy, payloadDebugSummary(data))
                NSLog("[PlayTools] MetallibParser: %@ — %@",
                      selector,
                      result.summary.replacingOccurrences(of: "\n", with: " | "))
                for (i, mod) in modules.enumerated() {
                    NSLog("[PlayTools] MetallibParser:   [%d] %@", i, mod.summary)
                }
                dumpPayloadSampleIfNeeded(data, reason: "safeParseAndLog_recovered", recoveredBy: unwrapped.strategy)
                return
            }

            dumpPayloadSampleIfNeeded(data, reason: "safeParseAndLog_failed")
            NSLog("[PlayTools] MetallibParser: %@ — parse failed: %@ (%@)",
                  selector,
                  error.localizedDescription,
                  payloadDebugSummary(data))
        }
    }

    /// 安全地尝试解析 dispatch_data_t 并记录结果。
    static func safeParseAndLog(dispatchData: __DispatchData, selector: String) {
        let data = convertDispatchData(dispatchData)
        safeParseAndLog(data, selector: selector)
    }

    /// **E-004b**: 安全地提取 bitcode 模块。
    /// 返回 nil 表示解析失败或无有效 bitcode；失败不会中断调用方流程。
    static func safeExtractBitcodeModules(from data: Data) -> (result: ParseResult, modules: [BitcodeModule])? {
        do {
            let result = try parse(data)
            let modules = result.extractBitcodeModules()
            return (result, modules)
        } catch {
            if let unwrapped = unwrapMetallibPayloadIfNeeded(data) {
                do {
                    let result = try parse(unwrapped.data)
                    let modules = result.extractBitcodeModules()
                    NSLog("[PlayTools] MetallibParser: extractBitcodeModules recovered via %@ — original=%@, unwrapped=%@",
                          unwrapped.strategy,
                          payloadDebugSummary(data),
                          payloadDebugSummary(unwrapped.data))
                    dumpPayloadSampleIfNeeded(data, reason: "extractBitcodeModules_recovered", recoveredBy: unwrapped.strategy)
                    return (result, modules)
                } catch {
                    NSLog("[PlayTools] MetallibParser: unwrap candidate failed via %@: %@",
                          unwrapped.strategy, error.localizedDescription)
                }
            }

            dumpPayloadSampleIfNeeded(data, reason: "extractBitcodeModules_failed")
            NSLog("[PlayTools] MetallibParser: extractBitcodeModules failed: %@ (%@)",
                  error.localizedDescription,
                  payloadDebugSummary(data))
            return nil
        }
    }

    /// **E-004b**: 安全地从 dispatch_data_t 提取 bitcode 模块。
    static func safeExtractBitcodeModules(
        from dispatchData: __DispatchData
    ) -> (result: ParseResult, modules: [BitcodeModule])? {
        let data = convertDispatchData(dispatchData)
        return safeExtractBitcodeModules(from: data)
    }
}
