import Foundation

extension IRToMSLConverter {
    // MARK: - IR Metadata Types

    /// 从 IR metadata 中解析出的参数信息。
    ///
    /// Metal AIR 在 LLVM IR 的 named metadata (!air.vertex, !air.fragment, !air.kernel)
    /// 中包含完整的函数签名信息，包括参数类型名、参数名、绑定索引等。
    /// 这些信息在 opaque pointer 时代（LLVM 15+）是获取精确类型的唯一途径。
    struct MetadataArgInfo {
        /// 参数在 IR define 中的位置索引
        let argIndex: Int
        /// 参数种类: "air.buffer", "air.texture", "air.sampler",
        /// "air.vertex_input", "air.fragment_input", "air.vertex_id",
        /// "air.base_vertex", "air.base_instance", "air.thread_position_in_grid" 等
        let kind: String
        /// MSL 类型名 (来自 "air.arg_type_name"): "float4", "uint", "Uniforms" 等
        let typeName: String
        /// MSL 参数名 (来自 "air.arg_name"): "positions", "uniforms" 等
        let argName: String
        /// `user(TEXCOORD0)` 这类 stage-in 语义字符串
        let stageInAttribute: String?
        /// buffer/texture/sampler 绑定索引 (来自 "air.location_index")
        let locationIndex: Int?
        /// 地址空间 (来自 "air.address_space")
        let addressSpace: Int?
        /// 是否只读 (有 "air.read" 标记)
        let isReadOnly: Bool
        /// 参数 qualifier（如 `air.flat` / `air.center` / `air.perspective`）
        let qualifiers: [String]
        /// 结构体字段信息（来自 "air.struct_type_info"），仅 buffer 参数有
        let structFieldInfo: [StructFieldInfo]
    }

    /// 从 IR metadata 中解析出的返回值字段信息。
    struct MetadataReturnInfo {
        /// 返回字段种类，如 `air.position` / `air.vertex_output` / `air.render_target`
        let kind: String
        /// MSL 类型名（来自 `air.arg_type_name`）
        let typeName: String
        /// 字段名（来自 `air.arg_name`，若缺失则使用推导名）
        let argName: String
        /// 颜色附件等输出槽位（若 metadata 提供）
        let locationIndex: Int?
        /// 返回字段 qualifier（如 `air.invariant`）
        let qualifiers: [String]
    }

    /// 从 IR metadata 中解析出的函数信息
    struct MetadataFuncInfo {
        /// 函数名
        let name: String
        /// shader 类型
        let shaderType: ShaderType
        /// 返回值字段描述（按 metadata 顺序）
        let returns: [MetadataReturnInfo]
        /// 参数列表（按 argIndex 排序）
        let args: [MetadataArgInfo]
    }

    // MARK: - Struct Type Info (E-004e4c)

    /// 从 IR 结构体定义中解析出的字段信息
    struct StructFieldInfo {
        /// 字段在结构体中的索引（0, 1, 2, ...）
        let index: Int
        /// MSL 字段类型名（如 "float3", "float4x4", "float"）
        let typeName: String
        /// MSL 字段名（如 "position", "velocity", "mass"）
        let fieldName: String
        /// 字段在结构体中的偏移量（字节）
        let offset: Int
        /// 字段大小（字节）
        let size: Int
        /// air.struct_type_info 第三个 i32：element count（数组长度，>1 时字段是数组类型）
        let elementCount: Int
    }

    /// IR 中解析出的结构体类型定义
    struct IRStructTypeDef {
        /// IR 结构体名（如 "%struct.Particle"）
        let irName: String
        /// 字段的 IR 类型列表
        let fieldIRTypes: [String]
        /// 是否为 packed struct（<{ ... }>）
        let isPacked: Bool
    }

    // MARK: - IR Metadata Parsing

    /// 从 IR 文本中解析 !air.vertex / !air.fragment / !air.kernel metadata，
    /// 提取每个 shader 函数的完整参数信息。
    ///
    /// IR metadata 格式示例:
    /// ```
    /// !air.vertex = !{!9, !22}          ← 顶层：列出所有 vertex 函数
    /// !9 = !{ptr @test_vertex, !10, !14} ← 函数节点：函数指针 + 返回描述 + 参数描述
    /// !14 = !{!15, !16, !17, !18, !20, !21}  ← 参数列表节点
    /// !18 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 144,
    ///         !"air.location_index", i32 0, i32 1, !"air.read",
    ///         !"air.address_space", i32 2,
    ///         !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
    /// ```
    static func parseIRMetadata(_ irText: String) -> [MetadataFuncInfo] {
        let lines = irText.components(separatedBy: "\n")

        // Step 1: 构建 metadata 节点表 (!N → content)
        var metadataNodes: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配 !N = !{...} 或 !N = distinct !{...}
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            let nodeId = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            metadataNodes[nodeId] = content
        }

        // Step 2: 找到 !air.vertex, !air.fragment, !air.kernel 的入口
        var results: [MetadataFuncInfo] = []

        let shaderTypeMap: [(String, ShaderType)] = [
            ("!air.vertex", .vertex),
            ("!air.fragment", .fragment),
            ("!air.kernel", .kernel),
        ]

        for (metaKey, shaderType) in shaderTypeMap {
            // 找 !air.vertex = !{!9, !22} 这样的行
            guard let topContent = metadataNodes[metaKey] else { continue }
            let funcNodeIds = parseMetadataRefList(topContent)

            for funcNodeId in funcNodeIds {
                guard let funcContent = metadataNodes[funcNodeId] else { continue }
                if let funcInfo = parseMetadataFuncNode(
                    funcContent,
                    shaderType: shaderType,
                    nodes: metadataNodes,
                    irText: irText
                ) {
                    results.append(funcInfo)
                }
            }
        }

        return results
    }

    /// 解析 metadata 引用列表: !{!9, !22} → ["!9", "!22"]
    static func parseMetadataRefList(_ content: String) -> [String] {
        // content 格式: !{!9, !22} 或 !{}
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return [] }
        let inner = String(content.dropFirst(2).dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        return inner.components(separatedBy: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("!") ? trimmed : nil
        }
    }

    /// 解析函数 metadata 节点。
    ///
    /// AIR 中常见两种形态都要支持：
    /// - `!{ptr @test_vertex, !10, !14}`：返回节点 + 参数列表分组节点
    /// - `!{ptr @xlatMtlMain, !1, !2, !4}`：返回节点 + 多个参数节点直接并列
    static func parseMetadataFuncNode(
        _ content: String,
        shaderType: ShaderType,
        nodes: [String: String],
        irText: String
    ) -> MetadataFuncInfo? {
        _ = irText
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())

        // 提取函数名: "ptr @test_vertex" 或 "ptr @\"quoted.name\""
        let funcName: String
        if let atRange = inner.range(of: "@") {
            let afterAt = inner[atRange.upperBound...]
            if afterAt.hasPrefix("\"") {
                let nameStart = afterAt.index(after: afterAt.startIndex)
                if let quoteEnd = afterAt[nameStart...].firstIndex(of: "\"") {
                    funcName = String(afterAt[nameStart..<quoteEnd])
                } else {
                    return nil
                }
            } else {
                let nameEnd = afterAt.firstIndex(where: { $0 == "," || $0 == " " }) ?? afterAt.endIndex
                funcName = String(afterAt[afterAt.startIndex..<nameEnd])
            }
        } else {
            return nil
        }

        // `parseMetadataRefList(...)` 会返回函数节点里出现的所有 `!N` 引用。
        // 除了传统的 `[返回节点, 参数列表节点]`，还要兼容 `[返回节点, 参数节点, 参数节点, ...]`。
        let refs = parseMetadataRefList(content)
        guard let firstRef = refs.first else {
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: [], args: [])
        }

        let returns = parseMetadataReturnListNode(fromRefs: [firstRef], nodes: nodes)
        let args = parseMetadataArgListNode(fromRefs: Array(refs.dropFirst()), nodes: nodes)

        return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: returns, args: args)
    }

    static func parseMetadataReturnListNode(
        fromRefs refs: [String],
        nodes: [String: String]
    ) -> [MetadataReturnInfo] {
        var returns: [MetadataReturnInfo] = []

        for ref in refs {
            guard let nodeContent = nodes[ref] else { continue }

            let nestedRefs = parseMetadataRefList(nodeContent)
            if !nestedRefs.isEmpty {
                let nestedReturns = parseMetadataReturnListNode(fromRefs: nestedRefs, nodes: nodes)
                if !nestedReturns.isEmpty {
                    returns.append(contentsOf: nestedReturns)
                    continue
                }
            }

            if let returnInfo = parseMetadataReturnNode(nodeContent) {
                returns.append(returnInfo)
            }
        }

        return returns
    }

    static func parseMetadataArgListNode(
        fromRefs refs: [String],
        nodes: [String: String]
    ) -> [MetadataArgInfo] {
        var args: [MetadataArgInfo] = []

        for ref in refs {
            guard let nodeContent = nodes[ref] else { continue }

            let nestedRefs = parseMetadataRefList(nodeContent)
            if !nestedRefs.isEmpty {
                let nestedArgs = parseMetadataArgListNode(fromRefs: nestedRefs, nodes: nodes)
                if !nestedArgs.isEmpty {
                    args.append(contentsOf: nestedArgs)
                    continue
                }
            }

            if let argInfo = parseMetadataArgNode(nodeContent) {
                args.append(argInfo)
            }
        }

        return args.sorted { $0.argIndex < $1.argIndex }
    }

    static func parseMetadataReturnNode(_ content: String) -> MetadataReturnInfo? {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)
        guard !tokens.isEmpty else { return nil }

        let kind = unquoteMetadataString(tokens[0])
        var typeName = ""
        var argName = ""
        var locationIndex: Int?
        var qualifiers: [String] = []
        var i = 1

        while i < tokens.count {
            let token = unquoteMetadataString(tokens[i])

            switch token {
            case "air.arg_type_name":
                if i + 1 < tokens.count {
                    typeName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            case "air.arg_name":
                if i + 1 < tokens.count {
                    argName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            case "air.location_index":
                if i + 1 < tokens.count {
                    locationIndex = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            default:
                if locationIndex == nil,
                   token.hasPrefix("i32 "),
                   (kind == "air.render_target" || kind == "air.vertex_output") {
                    locationIndex = parseMetadataInt(tokens[i])
                } else if token.hasPrefix("air."), token != kind, token != "air.arg_unused" {
                    qualifiers.append(token)
                }
                i += 1
            }
        }

        let fallbackName: String
        switch kind {
        case "air.position":
            fallbackName = "position"
        case "air.render_target":
            fallbackName = "color\(locationIndex ?? 0)"
        case "air.vertex_output":
            fallbackName = "varying\(locationIndex ?? 0)"
        default:
            fallbackName = "out\(locationIndex ?? 0)"
        }

        return MetadataReturnInfo(
            kind: kind,
            typeName: typeName,
            argName: argName.isEmpty ? fallbackName : argName,
            locationIndex: locationIndex,
            qualifiers: Array(Set(qualifiers)).sorted()
        )
    }

    /// 解析单个参数 metadata 节点。
    ///
    /// 格式示例:
    /// ```
    /// !{i32 3, !"air.buffer", !"air.buffer_size", i32 144,
    ///   !"air.location_index", i32 0, i32 1, !"air.read",
    ///   !"air.address_space", i32 2,
    ///   !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
    ///
    /// !{i32 5, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
    /// ```
    static func parseMetadataArgNode(_ content: String) -> MetadataArgInfo? {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)

        guard tokens.count >= 2 else { return nil }

        // 第一个 token: i32 N (参数索引)
        let argIndex: Int
        if tokens[0].hasPrefix("i32 ") {
            argIndex = Int(String(tokens[0].dropFirst(4))) ?? 0
        } else {
            return nil
        }

        // 第二个 token: !"air.buffer" 或 !"air.vertex_id" 等（参数种类）
        let kind = unquoteMetadataString(tokens[1])
        guard kind.hasPrefix("air.") else { return nil }

        // 扫描后续 token 提取 key-value 对
        var typeName = ""
        var argName = ""
        var stageInAttribute: String?
        var locationIndex: Int?
        var addressSpace: Int?
        var isReadOnly = false
        var qualifiers: [String] = []
        var structFieldInfo: [StructFieldInfo] = []

        var i = 2
        while i < tokens.count {
            let token = unquoteMetadataString(tokens[i])

            switch token {
            case "air.arg_type_name":
                if i + 1 < tokens.count {
                    typeName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.arg_name":
                if i + 1 < tokens.count {
                    argName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.location_index":
                if i + 1 < tokens.count {
                    locationIndex = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.address_space":
                if i + 1 < tokens.count {
                    addressSpace = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.read":
                isReadOnly = true
                i += 1
            case "air.read_write":
                isReadOnly = false
                i += 1
            case "air.struct_type_info":
                // air.struct_type_info 的值是一个 metadata 引用 !N
                // 但在这里它已经被 inline 展开了（从 nodes lookup 替换）
                // 格式: 后续 tokens 是字段描述序列:
                // i32 offset, i32 size, i32 alignment, !"typeName", !"fieldName", ...
                // 跳过这个 key，字段信息在后续 tokens 中
                if i + 1 < tokens.count {
                    let ref = tokens[i + 1].trimmingCharacters(in: .whitespaces)
                    if ref.hasPrefix("!") && !ref.hasPrefix("!\"") {
                        // 这是一个 metadata 引用，记录下来稍后在外部处理
                        // 标记使用特殊值让调用方知道
                        i += 2
                    } else {
                        i += 1
                    }
                } else { i += 1 }
            default:
                if token.hasPrefix("air.") && token != kind {
                    qualifiers.append(token)
                } else if stageInAttribute == nil,
                          (kind == "air.fragment_input" || kind == "air.vertex_input"),
                          token.contains("(") {
                    stageInAttribute = token
                }
                i += 1
            }
        }

        return MetadataArgInfo(
            argIndex: argIndex,
            kind: kind,
            typeName: typeName,
            argName: argName.isEmpty ? "arg\(argIndex)" : argName,
            stageInAttribute: stageInAttribute,
            locationIndex: locationIndex,
            addressSpace: addressSpace,
            isReadOnly: isReadOnly,
            qualifiers: Array(Set(qualifiers)).sorted(),
            structFieldInfo: structFieldInfo
        )
    }

    /// 分割 metadata 节点内容为 token 列表。
    /// 处理逗号分割，但保持 !{} 嵌套。
    static func splitMetadataTokens(_ content: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var inQuotedString = false
        var previousChar: Character?

        for char in content {
            if char == "\"" && previousChar != "\\" {
                inQuotedString.toggle()
            } else if !inQuotedString {
                if char == "{" || char == "(" || char == "[" { depth += 1 }
                else if char == "}" || char == ")" || char == "]" { depth -= 1 }
            }

            if char == "," && depth == 0 && !inQuotedString {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }

            previousChar = char
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { tokens.append(trimmed) }
        return tokens
    }

    /// 去掉 metadata 字符串的引号: !"air.buffer" → "air.buffer"
    static func unquoteMetadataString(_ token: String) -> String {
        var s = token
        if s.hasPrefix("!\"") && s.hasSuffix("\"") {
            s = String(s.dropFirst(2).dropLast())
        } else if s.hasPrefix("!") {
            s = String(s.dropFirst())
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// 从 metadata token 中提取整数: "i32 2" → 2
    static func parseMetadataInt(_ token: String) -> Int? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("i32 ") {
            return Int(String(trimmed.dropFirst(4)))
        }
        return Int(trimmed)
    }

    // MARK: - IR Struct Type Parsing (E-004e4c)

    /// 从 IR 文本中解析所有结构体类型定义。
    ///
    /// IR 格式示例：
    /// ```
    /// %struct.Particle = type { <3 x float>, <3 x float>, float, [12 x i8] }
    /// %struct.Uniforms = type <{ %"struct.metal::matrix", float, [12 x i8] }>
    /// ```
    static func parseIRStructTypes(_ irText: String) -> [String: IRStructTypeDef] {
        var structDefs: [String: IRStructTypeDef] = [:]
        let lines = irText.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配: %XXX = type { ... } 或 %XXX = type <{ ... }>
            guard trimmed.hasPrefix("%") else { continue }
            guard let eqRange = trimmed.range(of: " = type ") else { continue }

            let irName = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var bodyStr = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            let isPacked = bodyStr.hasPrefix("<{")
            // 去掉外层 <{ }> 或 { }
            if isPacked {
                if bodyStr.hasPrefix("<{") && bodyStr.hasSuffix("}>") {
                    bodyStr = String(bodyStr.dropFirst(2).dropLast(2))
                }
            } else {
                if bodyStr.hasPrefix("{") && bodyStr.hasSuffix("}") {
                    bodyStr = String(bodyStr.dropFirst().dropLast())
                }
            }

            // 解析字段类型（用 splitIRParameters 正确处理嵌套 < > { }）
            let fieldTypes = splitIRParameters(bodyStr).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            structDefs[irName] = IRStructTypeDef(
                irName: irName,
                fieldIRTypes: fieldTypes,
                isPacked: isPacked
            )
        }

        return structDefs
    }

    /// 从 metadata 的 air.struct_type_info 引用中解析结构体字段信息。
    ///
    /// metadata 格式示例：
    /// ```
    /// !31 = !{i32 0, i32 16, i32 0, !"float3", !"position",
    ///         i32 16, i32 16, i32 0, !"float3", !"velocity",
    ///         i32 32, i32 4, i32 0, !"float", !"mass"}
    /// ```
    /// 每个字段由 5 个 token 组成：offset, size, alignment, typeName, fieldName
    static func parseStructTypeInfoNode(
        _ content: String
    ) -> [StructFieldInfo] {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return [] }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)

        var fields: [StructFieldInfo] = []
        var i = 0
        var fieldIndex = 0

        // 每个字段由 5 个 token 组成: i32 offset, i32 size, i32 elementCount, !"typeName", !"fieldName"
        // 注意：第三个 i32 是 element count（数组长度），而非 alignment；element_count > 1 表示数组字段
        while i + 4 < tokens.count {
            let offset = parseMetadataInt(tokens[i]) ?? 0
            let size = parseMetadataInt(tokens[i + 1]) ?? 0
            let elementCount = parseMetadataInt(tokens[i + 2]) ?? 1
            let typeName = unquoteMetadataString(tokens[i + 3])
            let fieldName = unquoteMetadataString(tokens[i + 4])

            fields.append(StructFieldInfo(
                index: fieldIndex,
                typeName: typeName,
                fieldName: fieldName,
                offset: offset,
                size: size,
                elementCount: elementCount
            ))
            fieldIndex += 1
            i += 5
        }

        return fields
    }

    /// 从 IR metadata 中提取所有结构体字段信息。
    ///
    /// 扫描所有参数的 metadata，提取 air.struct_type_info 引用，
    /// 构建 MSL 类型名 → [StructFieldInfo] 的映射表。
    static func parseStructFieldInfoFromMetadata(
        _ irText: String,
        metadataFuncs: [MetadataFuncInfo]
    ) -> [String: [StructFieldInfo]] {
        _ = metadataFuncs
        var result: [String: [StructFieldInfo]] = [:]

        let lines = irText.components(separatedBy: "\n")

        // Step 1: 构建 metadata 节点表
        var metadataNodes: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            let nodeId = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            metadataNodes[nodeId] = content
        }

        // Step 2: 从参数 metadata 中找 air.struct_type_info 引用
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配包含 air.struct_type_info 的行
            guard trimmed.contains("air.struct_type_info") else { continue }
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }

            var nodeContent = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if nodeContent.hasPrefix("distinct ") {
                nodeContent = String(nodeContent.dropFirst("distinct ".count))
            }
            guard nodeContent.hasPrefix("!{") && nodeContent.hasSuffix("}") else { continue }

            let tokens = splitMetadataTokens(
                String(nodeContent.dropFirst(2).dropLast())
            )

            // 找到 air.struct_type_info 之后的 metadata 引用
            var typeName = ""
            for (idx, tok) in tokens.enumerated() {
                let unquoted = unquoteMetadataString(tok)
                if unquoted == "air.struct_type_info" {
                    // 下一个 token 是 !N 引用
                    if idx + 1 < tokens.count {
                        let ref = tokens[idx + 1].trimmingCharacters(in: .whitespaces)
                        if let nodeContent = metadataNodes[ref] {
                            let fields = parseStructTypeInfoNode(nodeContent)
                            // 找到这个参数的 air.arg_type_name
                            for (j, t) in tokens.enumerated() {
                                if unquoteMetadataString(t) == "air.arg_type_name" && j + 1 < tokens.count {
                                    typeName = unquoteMetadataString(tokens[j + 1])
                                    break
                                }
                            }
                            if !typeName.isEmpty && !fields.isEmpty {
                                result[typeName] = fields
                            }
                        }
                    }
                }
            }
        }

        return result
    }

    /// 从 IR 顶层解析简单的 `constant` 全局定义，供 GEP/load 访问全局常量数组时发射到 MSL。
    static func parseIRGlobalConstants(_ irText: String) -> [IRGlobalConstant] {
        var result: [IRGlobalConstant] = []

        for line in irText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@"), let eqRange = trimmed.range(of: " = ") else { continue }
            guard trimmed.contains(" constant ") else { continue }

            let irName = String(trimmed[trimmed.startIndex..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let constantRange = rhs.range(of: " constant ") else { continue }

            let afterConstant = String(rhs[constantRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let (irType, afterType) = parseIRType(afterConstant)
            guard !irType.isEmpty else { continue }

            let (initializer, _) = parseIRValue(afterType)
            guard !initializer.isEmpty else { continue }

            result.append(IRGlobalConstant(irName: irName, irType: irType, initializer: initializer))
        }

        return result
    }

    static func collectCompareSamplerStateGlobals(_ irText: String) -> Set<String> {
        let symbolPattern = try? NSRegularExpression(pattern: #"@[^,\s\)]+"#)
        var globals: Set<String> = []

        for rawLine in irText.components(separatedBy: "\n") where rawLine.contains("@air.sample_compare_depth") {
            guard let symbolPattern else { continue }
            let line = rawLine as NSString
            let matches = symbolPattern.matches(in: rawLine, range: NSRange(location: 0, length: line.length))
            guard matches.count >= 2 else { continue }
            let symbol = line.substring(with: matches[1].range)
            globals.insert(symbol)
        }

        return globals
    }

    static func parseUInt64IRLiteral(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let signed = Int64(trimmed) {
            return UInt64(bitPattern: signed)
        }
        if let unsigned = UInt64(trimmed) {
            return unsigned
        }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return nil
    }

    static func parseSamplerStateRawValue(irType: String, initializer: String) -> UInt64? {
        let trimmedType = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInit = initializer.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedType == "i64" {
            return parseUInt64IRLiteral(trimmedInit)
        }

        if trimmedType == "[2 x i64]" {
            let firstElementPattern = try? NSRegularExpression(pattern: #"i64\s+(-?(?:0x[0-9A-Fa-f]+|\d+))"#)
            guard let firstElementPattern else { return nil }
            let nsInit = trimmedInit as NSString
            guard let match = firstElementPattern.firstMatch(in: trimmedInit, range: NSRange(location: 0, length: nsInit.length)) else {
                return nil
            }
            let token = nsInit.substring(with: match.range(at: 1))
            return parseUInt64IRLiteral(token)
        }

        return nil
    }

    static func renderSamplerStateDeclaration(
        irName: String,
        irType: String,
        initializer: String,
        usedBySampleCompare: Bool
    ) -> String? {
        guard irName.contains("__air_sampler_state"),
              let rawValue = parseSamplerStateRawValue(irType: irType, initializer: initializer) else {
            return nil
        }

        let symbolName = sanitizeIdentifier(
            String(irName.dropFirst()).replacingOccurrences(of: "\"", with: ""),
            fallback: "air_sampler_state",
            uppercaseFirst: false
        )
        let payload = rawValue & 0x000F_FFFF

        let coordMode = (payload & 0x8000) != 0 ? "coord::pixel" : "coord::normalized"

        let addressMode: String
        switch payload & 0x00FF {
        case 0x00:
            addressMode = "clamp_to_zero"
        case 0x49:
            addressMode = "clamp_to_edge"
        case 0x92:
            addressMode = "repeat"
        case 0xDB:
            addressMode = "mirrored_repeat"
        default:
            addressMode = "clamp_to_edge"
        }

        let filterMode = (payload & 0x0A00) != 0 ? "filter::linear" : "filter::nearest"
        var options = [coordMode, "address::\(addressMode)", filterMode]

        if (payload & 0x4000) != 0 {
            options.append("mip_filter::linear")
        } else if (payload & 0x2000) != 0 {
            options.append("mip_filter::nearest")
        }

        let compareCode = Int((payload >> 16) & 0xF)
        let compareFunction: String?
        switch compareCode {
        case 1:
            compareFunction = "less"
        case 2:
            compareFunction = "less_equal"
        case 3:
            compareFunction = "greater"
        case 4:
            compareFunction = "greater_equal"
        case 5:
            compareFunction = "equal"
        case 6:
            compareFunction = "not_equal"
        case 7:
            compareFunction = "always"
        case 8 where usedBySampleCompare:
            compareFunction = "never"
        default:
            compareFunction = nil
        }

        if let compareFunction {
            options.append("compare_func::\(compareFunction)")
        }

        return "constexpr sampler \(symbolName)(\(options.joined(separator: ", ")));"
    }
}
