import Foundation

extension IRToMSLConverter {
    // MARK: - IR Parsing

    /// 从 IR 文本中匹配的函数定义信息
    struct IRFunctionDef {
        let name: String
        let returnType: String
        let parameterList: String
        let attributes: String
        let fullDefinition: String
        /// 函数体 IR 文本（define 行之后到 } 之前的所有行）
        let body: String
    }

    /// 解析 IR 文本中的所有函数定义。
    /// 返回 (解析的函数列表, 总函数定义数)
    static func parseIRFunctions(_ irText: String) -> ([IRFunctionDef], Int) {
        var functions: [IRFunctionDef] = []

        let lines = irText.components(separatedBy: "\n")
        var totalDefines = 0
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // 匹配 define 行
            guard trimmed.hasPrefix("define ") else { i += 1; continue }
            totalDefines += 1

            guard let funcDef = parseDefineLine(trimmed) else { i += 1; continue }

            // 提取函数体：从 define 行之后到 } 行
            var bodyLines: [String] = []
            i += 1
            while i < lines.count {
                let bodyLine = lines[i]
                let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                if bodyTrimmed == "}" {
                    i += 1
                    break
                }
                bodyLines.append(bodyLine)
                i += 1
            }
            let body = bodyLines.joined(separator: "\n")

            functions.append(IRFunctionDef(
                name: funcDef.name,
                returnType: funcDef.returnType,
                parameterList: funcDef.parameterList,
                attributes: funcDef.attributes,
                fullDefinition: funcDef.fullDefinition,
                body: body
            ))
        }

        return (functions, totalDefines)
    }

    /// 解析单行 define 语句
    static func parseDefineLine(_ line: String) -> IRFunctionDef? {
        // 格式: define [linkage] [visibility] [cconv] <ret_type> @<name>(<params>) [attrs]
        // 示例: define void @"air.vertex_shader"(ptr addrspace(1) %0, ...) #0 {
        // 示例: define <4 x float> @myVertexShader(...) local_unnamed_addr #2 {

        // 查找函数名: @"xxx" 或 @xxx
        guard let atIndex = line.firstIndex(of: "@") else { return nil }
        let afterAt = line[line.index(after: atIndex)...]

        let funcName: String
        let afterName: Substring

        if afterAt.hasPrefix("\"") {
            // 带引号的名字 @"some.name"
            let nameStart = afterAt.index(after: afterAt.startIndex)
            guard let quoteEnd = afterAt[nameStart...].firstIndex(of: "\"") else { return nil }
            funcName = String(afterAt[nameStart..<quoteEnd])
            afterName = afterAt[afterAt.index(after: quoteEnd)...]
        } else {
            // 不带引号的名字 @myFunc
            let nameEnd = afterAt.firstIndex(where: { $0 == "(" || $0 == " " }) ?? afterAt.endIndex
            funcName = String(afterAt[afterAt.startIndex..<nameEnd])
            afterName = afterAt[nameEnd...]
        }

        // 提取参数列表
        guard let parenStart = afterName.firstIndex(of: "(") else { return nil }
        let paramStart = afterName.index(after: parenStart)

        // 找匹配的闭括号（注意嵌套）
        var depth = 1
        var cursor = paramStart
        while cursor < afterName.endIndex && depth > 0 {
            if afterName[cursor] == "(" { depth += 1 }
            else if afterName[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterName.index(after: cursor) }
        }
        let paramList = String(afterName[paramStart..<cursor])

        // 提取返回类型：在 @name 之前、define 之后
        let beforeAt = line[line.startIndex..<atIndex]
        let returnType = extractReturnType(from: String(beforeAt))

        // 提取属性（#N 标记之后的部分）
        let afterParams = cursor < afterName.endIndex ? String(afterName[cursor...]) : ""

        return IRFunctionDef(
            name: funcName,
            returnType: returnType,
            parameterList: paramList,
            attributes: afterParams,
            fullDefinition: line,
            body: ""  // filled by parseIRFunctions
        )
    }

    /// 从 define 行的前缀中提取返回类型
    static func extractReturnType(from prefix: String) -> String {
        // prefix 格式: "define [linkage] [visibility] <ret_type> "
        // 常见返回类型: void, <4 x float>, i32, float, { <4 x float>, float }
        var cleaned = prefix
            .replacingOccurrences(of: "define ", with: "")
            .replacingOccurrences(of: "internal ", with: "")
            .replacingOccurrences(of: "external ", with: "")
            .replacingOccurrences(of: "private ", with: "")
            .replacingOccurrences(of: "linkonce_odr ", with: "")
            .replacingOccurrences(of: "weak ", with: "")
            .replacingOccurrences(of: "hidden ", with: "")
            .replacingOccurrences(of: "default ", with: "")
            .replacingOccurrences(of: "dso_local ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // 处理尾部可能存在的 calling convention
        for cc in ["spir_func ", "spir_kernel ", "cc75 ", "cc76 ", "cc77 ", "fastcc "] {
            cleaned = cleaned.replacingOccurrences(of: cc, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shader Function Identification

    // MARK: E-006b2: Attribute Group & Orphaned Metadata Helpers

    /// 从 IR 文本中解析所有 attributes #N = { ... } 声明，返回 [ref → content] 映射。
    ///
    /// Metal AIR 中 shader 类型信息同时出现在两个位置：
    /// 1. `!air.vertex` / `!air.fragment` / `!air.kernel` 顶层 metadata（最可靠）
    /// 2. `attributes #N = { "air.fragment" ... }` 声明（define 行通过 #N 引用）
    ///
    /// 当顶层 metadata 缺失时（如某些合成 / 裁剪后的 IR），需要回退到 attributes 声明。
    static func parseAttributeGroupDeclarations(_ irText: String) -> [String: String] {
        var groups: [String: String] = [:]
        for line in irText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("attributes #") else { continue }
            guard let hashRange = trimmed.range(of: "#") else { continue }
            let afterHash = trimmed[hashRange.upperBound...]
            guard let eqRange = afterHash.range(of: " = ") else { continue }
            let numStr = String(afterHash[afterHash.startIndex..<eqRange.lowerBound])
            guard let openBrace = trimmed.range(of: "{"),
                  let closeBrace = trimmed.range(of: "}", range: openBrace.upperBound..<trimmed.endIndex) else { continue }
            let content = String(trimmed[openBrace.upperBound..<closeBrace.lowerBound])
            groups["#\(numStr)"] = content
        }
        return groups
    }

    /// 从 define 行的 attribute 字符串中提取 #N 引用列表。
    ///
    /// 示例: `local_unnamed_addr #0` → `["#0"]`
    static func extractAttributeGroupRefs(from attributes: String) -> [String] {
        var refs: [String] = []
        var searchStart = attributes.startIndex
        while searchStart < attributes.endIndex,
              let range = attributes.range(of: "#", range: searchStart..<attributes.endIndex) {
            let afterHash = attributes[range.upperBound...]
            var numEnd = afterHash.startIndex
            while numEnd < afterHash.endIndex, afterHash[numEnd].isNumber {
                numEnd = afterHash.index(after: numEnd)
            }
            if numEnd > afterHash.startIndex {
                refs.append("#" + String(afterHash[afterHash.startIndex..<numEnd]))
            }
            searchStart = range.upperBound
        }
        return refs
    }

    /// 从 attributes 声明内容中检测 shader 类型。
    ///
    /// 在 `attributes #N = { "air.fragment" ... }` 中查找 shader 类型标记。
    static func shaderTypeFromAttributeContent(_ content: String) -> ShaderType? {
        if content.contains("\"air.fragment\"") { return .fragment }
        if content.contains("\"air.vertex\"") { return .vertex }
        if content.contains("\"air.kernel\"") { return .kernel }
        return nil
    }

    /// 扫描所有 metadata 节点，收集 air.texture / air.sampler 类型的孤立参数信息。
    ///
    /// 某些 IR 中，`!air.vertex` / `!air.fragment` 顶层 metadata 缺失，但 `air.texture` / `air.sampler`
    /// 的参数 metadata 节点仍然存在（只是未被函数 metadata 节点的 args 列表引用）。
    /// 此函数扫描所有 `!N = !{...}` 节点，尝试解析为 MetadataArgInfo，
    /// 并按 `air.arg_name` 构建查找表，供 metadata 缺失时的回退路径使用。
    static func parseOrphanedMetadataArgLookup(_ irText: String) -> [String: MetadataArgInfo] {
        var lookup: [String: MetadataArgInfo] = [:]
        let lines = irText.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            guard let argInfo = parseMetadataArgNode(content) else { continue }
            let kind = argInfo.kind
            guard kind == "air.texture" || kind == "air.sampler" else { continue }
            let argName = argInfo.argName
            guard !argName.isEmpty, !argName.hasPrefix("arg") else { continue }
            // 只在同名 key 不存在时写入，避免后面的覆盖前面的
            if lookup[argName] == nil {
                lookup[argName] = argInfo
            }
        }
        return lookup
    }

    /// 结合 IR 函数定义、metallib 元数据和 IR metadata，识别 shader entry，
    /// 并补发射 entry 递归依赖的 internal helper 函数。
    static func identifyShaderFunctions(
        irFunctions: [IRFunctionDef],
        metallibNames: [String],
        metallibTypes: [String],
        metadataFuncs: [MetadataFuncInfo] = [],
        airBuiltinCalls: [AirBuiltinCall] = [],
        irText: String = ""
    ) -> [ParsedShaderFunction] {
        // 构建 metadata 函数名→信息的映射
        var metadataMap: [String: MetadataFuncInfo] = [:]
        for mf in metadataFuncs {
            metadataMap[mf.name] = mf
        }

        // 构建 metallib 函数名→类型的映射
        var nameToType: [String: ShaderType] = [:]
        for (i, name) in metallibNames.enumerated() {
            if i < metallibTypes.count {
                let typeStr = metallibTypes[i].lowercased()
                if typeStr.contains("vertex") { nameToType[name] = .vertex }
                else if typeStr.contains("fragment") { nameToType[name] = .fragment }
                else if typeStr.contains("kernel") { nameToType[name] = .kernel }
            }
        }

        // E-006b2: 预解析 attributes #N 声明和孤立 texture/sampler metadata 参数
        let attrGroups = !irText.isEmpty ? parseAttributeGroupDeclarations(irText) : [:]
        let orphanedArgLookup = !irText.isEmpty ? parseOrphanedMetadataArgLookup(irText) : [:]
        let irFunctionsByName = Dictionary(uniqueKeysWithValues: irFunctions.map { ($0.name, $0) })

        var parsedFunctions: [ParsedShaderFunction] = []
        var entryNames: Set<String> = []

        for irFunc in irFunctions {
            // 跳过 LLVM 内部函数和 air 运行时函数
            if irFunc.name.hasPrefix("llvm.") || irFunc.name.hasPrefix("air.") { continue }

            guard let type = detectEntryShaderType(
                for: irFunc,
                metadataMap: metadataMap,
                nameToType: nameToType,
                attrGroups: attrGroups,
                metallibNames: metallibNames
            ) else {
                continue
            }

            let params: [ParsedParameter]
            let outputs: [MetadataReturnInfo]
            let isFullyParsed: Bool
            if let metaInfo = metadataMap[irFunc.name] {
                params = buildParametersFromMetadata(
                    metaInfo.args,
                    irParamList: irFunc.parameterList,
                    irBody: irFunc.body,
                    shaderType: type
                )
                outputs = metaInfo.returns
                isFullyParsed = true
            } else {
                params = parseParameters(
                    irFunc.parameterList,
                    irBody: irFunc.body,
                    shaderType: type,
                    orphanedArgLookup: orphanedArgLookup
                )
                outputs = []
                isFullyParsed = false
            }

            let mslReturnType = deriveEntryReturnType(
                irReturnType: irFunc.returnType,
                shaderType: type,
                outputs: outputs,
                functionName: irFunc.name
            )

            parsedFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: type,
                isEntryPoint: true,
                returnType: mslReturnType,
                outputs: outputs,
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: isFullyParsed,
                airBuiltinCalls: airBuiltinCalls,
                irBody: irFunc.body
            ))
            entryNames.insert(irFunc.name)
        }

        // 如果 IR 中没找到匹配的函数，为 metallib 中的每个函数生成 stub
        if parsedFunctions.isEmpty && !metallibNames.isEmpty {
            for (i, name) in metallibNames.enumerated() {
                let type: ShaderType
                if i < metallibTypes.count {
                    let typeStr = metallibTypes[i].lowercased()
                    if typeStr.contains("fragment") { type = .fragment }
                    else if typeStr.contains("kernel") { type = .kernel }
                    else { type = .vertex }
                } else {
                    type = .vertex
                }

                parsedFunctions.append(ParsedShaderFunction(
                    name: name,
                    shaderType: type,
                    isEntryPoint: true,
                    returnType: defaultReturnType(for: type),
                    outputs: [],
                    parameters: [],
                    irSignature: "(metallib-only, no IR match)",
                    isFullyParsed: false,
                    airBuiltinCalls: [],
                    irBody: ""
                ))
                entryNames.insert(name)
            }
        }

        let reachableHelperNames = collectReachableHelperFunctionNames(
            entryNames: entryNames,
            irFunctionsByName: irFunctionsByName
        )

        for irFunc in irFunctions where reachableHelperNames.contains(irFunc.name) {
            let params = parseParameters(
                irFunc.parameterList,
                irBody: irFunc.body,
                shaderType: .helper,
                orphanedArgLookup: [:]
            )
            let mslReturnType = irTypeToMSL(irFunc.returnType, forShaderType: .helper)

            parsedFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: .helper,
                isEntryPoint: false,
                returnType: mslReturnType,
                outputs: [],
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: true,
                airBuiltinCalls: airBuiltinCalls,
                irBody: irFunc.body
            ))
        }

        return parsedFunctions
    }

    static func detectEntryShaderType(
        for irFunc: IRFunctionDef,
        metadataMap: [String: MetadataFuncInfo],
        nameToType: [String: ShaderType],
        attrGroups: [String: String],
        metallibNames: [String]
    ) -> ShaderType? {
        if let metaInfo = metadataMap[irFunc.name] {
            return metaInfo.shaderType
        }
        if let type = nameToType[irFunc.name] {
            return type
        }
        if let attrType = extractAttributeGroupRefs(from: irFunc.attributes)
            .compactMap({ attrGroups[$0] })
            .compactMap({ shaderTypeFromAttributeContent($0) })
            .first {
            return attrType
        }
        if irFunc.name.contains("vertex") || irFunc.attributes.contains("vertex") {
            return .vertex
        }
        if irFunc.name.contains("fragment") || irFunc.attributes.contains("fragment") {
            return .fragment
        }
        if irFunc.name.contains("kernel") || irFunc.attributes.contains("kernel") {
            return .kernel
        }
        if metallibNames.contains(irFunc.name) {
            return .vertex
        }
        if !metallibNames.isEmpty && metadataMap.isEmpty {
            return nil
        }
        if isLikelyInternalHelperFunction(irFunc) {
            return nil
        }
        return inferShaderType(from: irFunc)
    }

    static func isLikelyInternalHelperFunction(_ irFunc: IRFunctionDef) -> Bool {
        let fullDefinition = irFunc.fullDefinition
        return fullDefinition.hasPrefix("define internal ") ||
            fullDefinition.contains(" internal ") ||
            fullDefinition.contains(" private ") ||
            fullDefinition.contains(" linkonce_odr ") ||
            fullDefinition.contains(" fastcc ")
    }

    static func collectReachableHelperFunctionNames(
        entryNames: Set<String>,
        irFunctionsByName: [String: IRFunctionDef]
    ) -> Set<String> {
        guard !entryNames.isEmpty else { return [] }

        var reachableHelpers: Set<String> = []
        var worklist = Array(entryNames)
        var visited: Set<String> = []

        while let current = worklist.popLast() {
            guard visited.insert(current).inserted,
                  let irFunc = irFunctionsByName[current] else {
                continue
            }

            for callee in parseCalledFunctionNames(from: irFunc.body) {
                guard !callee.hasPrefix("air."),
                      !callee.hasPrefix("llvm."),
                      !entryNames.contains(callee),
                      irFunctionsByName[callee] != nil else {
                    continue
                }

                if reachableHelpers.insert(callee).inserted {
                    worklist.append(callee)
                }
            }
        }

        return reachableHelpers
    }

    static func parseCalledFunctionNames(from irBody: String) -> [String] {
        guard !irBody.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"@(?:\"([^\"]+)\"|([A-Za-z0-9$._]+))\("#) else {
            return []
        }

        let range = NSRange(irBody.startIndex..<irBody.endIndex, in: irBody)
        var names: [String] = []
        var seen: Set<String> = []
        regex.enumerateMatches(in: irBody, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for groupIndex in 1...2 {
                let groupRange = match.range(at: groupIndex)
                guard groupRange.location != NSNotFound,
                      let swiftRange = Range(groupRange, in: irBody) else {
                    continue
                }
                let name = String(irBody[swiftRange])
                if seen.insert(name).inserted {
                    names.append(name)
                }
                break
            }
        }
        return names
    }

    static func deriveEntryReturnType(
        irReturnType: String,
        shaderType: ShaderType,
        outputs: [MetadataReturnInfo],
        functionName: String
    ) -> String {
        guard shaderType != .kernel else { return "void" }

        if shouldUseEntryOutputStruct(
            irReturnType: irReturnType,
            shaderType: shaderType,
            outputs: outputs,
            functionName: functionName
        ) {
            return entryOutputStructName(for: functionName)
        }

        if let onlyOutput = outputs.first {
            let normalizedType = onlyOutput.typeName
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedType.isEmpty {
                return irScalarTypeToMSL(normalizedType)
            }
        }

        return irTypeToMSL(irReturnType, forShaderType: shaderType)
    }

    static func shouldUseEntryOutputStruct(
        irReturnType: String,
        shaderType: ShaderType,
        outputs: [MetadataReturnInfo],
        functionName: String
    ) -> Bool {
        guard shaderType != .kernel, !outputs.isEmpty else { return false }
        if outputs.count > 1 { return true }
        guard let onlyOutput = outputs.first else { return false }
        let expectedFieldType = entryOutputFieldType(for: onlyOutput, index: 0)
        guard let unwrappedIRType = unwrapSingleFieldAggregateIRType(irReturnType) else {
            return false
        }
        return irTypeToMSL(unwrappedIRType, forShaderType: shaderType) == expectedFieldType
    }

    static func unwrapSingleFieldAggregateIRType(_ irType: String) -> String? {
        var current = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }

        var unwrappedAtLeastOnce = false
        while true {
            let inner: String
            if current.hasPrefix("<{") && current.hasSuffix("}>") {
                inner = String(current.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                unwrappedAtLeastOnce = true
            } else if current.hasPrefix("{") && current.hasSuffix("}") {
                inner = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                unwrappedAtLeastOnce = true
            } else {
                return unwrappedAtLeastOnce ? current : nil
            }

            let fields = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard fields.count == 1, let onlyField = fields.first else {
                return nil
            }
            current = onlyField
        }
    }

    static func entryOutputStructName(for functionName: String) -> String {
        sanitizeTypeName(functionName) + "_Out"
    }

    static func entryOutputFieldType(
        for output: MetadataReturnInfo,
        index: Int
    ) -> String {
        let rawTypeName = output.typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTypeName.isEmpty {
            return output.kind == "air.position" ? "float4" : "float"
        }
        return irScalarTypeToMSL(rawTypeName)
    }

    /// 从 IR metadata 参数信息构建 ParsedParameter 列表。
    ///
    /// metadata 提供了精确的 MSL 类型名、参数名、绑定索引和地址空间，
    /// 比从 opaque pointer 参数推断要准确得多。
    ///
    /// 但真实 live / corpus 中经常会遇到 metadata 只覆盖 resource 参数、漏掉普通值参数（如 UV / clamp 输入）的情况。
    /// 这类漏参若不补齐，body lowering 会能解析 `%uv` / `%2`，但函数签名里没有对应声明，最终在 Metal 编译阶段报
    /// `use of undeclared identifier`。因此这里需要在 metadata 参数之外，按 IR define 的原始参数列表把缺失项补回。
    static func buildParametersFromMetadata(
        _ metaArgs: [MetadataArgInfo],
        irParamList: String,
        irBody: String,
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        let rawIRParams = splitIRParameters(irParamList)
        var params: [ParsedParameter] = []
        var mappedArgIndices: Set<Int> = []

        for meta in metaArgs {
            let fallbackIRAddrSpace: AddressSpace?
            if meta.argIndex >= 0 && meta.argIndex < rawIRParams.count {
                fallbackIRAddrSpace = extractAddressSpace(from: rawIRParams[meta.argIndex])
            } else {
                fallbackIRAddrSpace = nil
            }

            let addrSpace: AddressSpace?
            if let as_ = meta.addressSpace {
                addrSpace = AddressSpace(rawValue: as_)
            } else {
                addrSpace = fallbackIRAddrSpace
            }

            // 根据参数种类确定 attribute 和 pointerInfo
            let attribute: String?
            let ptrInfo: PointerInfo?

            switch meta.kind {
            case "air.buffer":
                attribute = nil
                let space = addrSpace ?? (meta.isReadOnly ? .constant : .device)
                // E-006b9: metal::_atomic → 根据内部字段类型映射为 atomic_int/atomic_uint
                let resolvedTypeName: String
                if meta.typeName == "metal::_atomic" {
                    if let firstField = meta.structFieldInfo.first {
                        // struct_type_info 格式: {offset, size, align, "uint"/"int", "__s"}
                        resolvedTypeName = "atomic_\(firstField.typeName)"
                    } else {
                        resolvedTypeName = "atomic_int"
                    }
                } else {
                    let rawName = meta.typeName.isEmpty ? "uint8_t" : meta.typeName
                    if rawName.first.map({ $0.isLowercase }) == true && !isMSLScalarOrVectorType(rawName) {
                        resolvedTypeName = sanitizeUserTypeName(rawName)
                    } else {
                        resolvedTypeName = rawName
                    }
                }
                ptrInfo = PointerInfo(
                    addressSpace: space,
                    pointedMSLType: resolvedTypeName,
                    isOpaquePointer: true
                )
            case "air.vertex_input":
                // vertex attribute 需要后续在函数签名里聚合成合成的 `stage_in` struct。
                attribute = nil
                ptrInfo = nil
            case "air.fragment_input":
                // fragment varying 需要后续在函数签名里聚合成合成的 `stage_in` struct。
                attribute = nil
                ptrInfo = nil
            case "air.position":
                // fragment position 在无 fragment_input 时可直接作为 builtin；
                // 若存在 fragment_input，则会在签名生成阶段并入合成的 stage_in struct。
                attribute = "[[position]]"
                ptrInfo = nil
            case "air.front_facing":
                // E-006g3a: front-facing 不是 stage_in varying，而是 fragment entry builtin。
                // 必须生成为显式 `[[front_facing]]` 形参，否则函数体里引用 mtl_FrontFace 会未声明。
                attribute = "[[front_facing]]"
                ptrInfo = nil
            case "air.vertex_output":
                continue
            case "air.render_target":
                continue
            case "air.vertex_id":
                attribute = "[[vertex_id]]"
                ptrInfo = nil
            case "air.instance_id":
                attribute = "[[instance_id]]"
                ptrInfo = nil
            case "air.base_vertex":
                attribute = "[[base_vertex]]"
                ptrInfo = nil
            case "air.base_instance":
                attribute = "[[base_instance]]"
                ptrInfo = nil
            case "air.thread_position_in_grid":
                attribute = "[[thread_position_in_grid]]"
                ptrInfo = nil
            case "air.thread_position_in_threadgroup":
                attribute = "[[thread_position_in_threadgroup]]"
                ptrInfo = nil
            case "air.threadgroup_position_in_grid":
                attribute = "[[threadgroup_position_in_grid]]"
                ptrInfo = nil
            case "air.threads_per_threadgroup":
                attribute = "[[threads_per_threadgroup]]"
                ptrInfo = nil
            case "air.thread_index_in_threadgroup":
                attribute = "[[thread_index_in_threadgroup]]"
                ptrInfo = nil
            case "air.texture":
                // texture 参数需要特殊处理
                attribute = meta.locationIndex.map { "[[texture(\($0))]]" }
                ptrInfo = nil
            case "air.sampler":
                attribute = meta.locationIndex.map { "[[sampler(\($0))]]" }
                ptrInfo = nil
            default:
                attribute = nil
                ptrInfo = nil
            }

            params.append(ParsedParameter(
                name: meta.argName,
                irType: meta.typeName,
                addressSpace: addrSpace,
                bufferIndex: meta.locationIndex,
                attribute: attribute,
                stageInAttribute: meta.stageInAttribute,
                qualifiers: meta.qualifiers,
                pointerInfo: ptrInfo,
                irArgIndex: meta.argIndex,
                kind: meta.kind,
                hasNoAlias: meta.argIndex >= 0 && meta.argIndex < rawIRParams.count && irParameterHasNoAlias(rawIRParams[meta.argIndex]),
                emitAsValueParameter: false
            ))
            mappedArgIndices.insert(meta.argIndex)
        }

        params.append(contentsOf: buildSupplementalParametersFromIR(
            rawIRParams,
            irBody: irBody,
            mappedArgIndices: mappedArgIndices,
            shaderType: shaderType
        ))

        return params.sorted { ($0.irArgIndex ?? .max) < ($1.irArgIndex ?? .max) }
    }

    /// 当 metadata 没有完整覆盖 define 参数列表时，从原始 IR 参数里补齐缺失项。
    ///
    /// 目标：
    /// - 保留 metadata 已知的 resource / builtin 精确信息
    /// - 仅对缺失项做最小保守补齐，优先保证"body 中用到的 SSA 名在签名里确实有声明"
    /// - 对缺失 builtin 的场景，优先按默认 entry builtin 规则推断，而不是把它误当成普通值参数
    static func buildSupplementalParametersFromIR(
        _ rawIRParams: [String],
        irBody: String,
        mappedArgIndices: Set<Int>,
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        var supplemental: [ParsedParameter] = []
        for (index, rawParam) in rawIRParams.enumerated() where !mappedArgIndices.contains(index) {
            let trimmed = rawParam.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "..." {
                continue
            }

            if let inferredBuiltin = inferImplicitEntryBuiltinParameter(
                from: trimmed,
                index: index,
                totalIRParamCount: rawIRParams.count,
                shaderType: shaderType
            ) {
                supplemental.append(inferredBuiltin)
                continue
            }

            let addrSpace = extractAddressSpace(from: trimmed)
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)
            let bindingIndex = fallbackBindingIndex(for: rawIRParams, targetIndex: index, addressSpace: addrSpace)
            let cleanedValueType = extractIRValueParameterType(from: trimmed)
            let fallbackName = fallbackIRParameterName(from: trimmed, index: index)

            supplemental.append(ParsedParameter(
                name: fallbackName,
                irType: ptrInfo == nil ? cleanedValueType : trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                stageInAttribute: nil,
                qualifiers: [],
                pointerInfo: ptrInfo,
                irArgIndex: index,
                kind: nil,
                hasNoAlias: irParameterHasNoAlias(trimmed),
                emitAsValueParameter: ptrInfo == nil && !cleanedValueType.isEmpty && isIRParameterReferenced(trimmed, in: irBody)
            ))
        }
        return supplemental
    }

    /// metadata 缺失时，按常见 entry 函数布局保守推断默认 builtin 参数。
    static func inferImplicitEntryBuiltinParameter(
        from rawIRParam: String,
        index: Int,
        totalIRParamCount: Int,
        shaderType: ShaderType
    ) -> ParsedParameter? {
        let cleanedValueType = extractIRValueParameterType(from: rawIRParam)
        guard let builtinIRType = defaultBuiltinIRType(for: shaderType),
              cleanedValueType == builtinIRType else {
            return nil
        }

        let name: String
        let attribute: String
        let kind: String

        switch shaderType {
        case .fragment:
            guard index == 0 else { return nil }
            name = defaultBuiltinParamName(for: .fragment) ?? "position"
            attribute = "[[position]]"
            kind = "air.position"
        case .vertex:
            guard index == totalIRParamCount - 1 else { return nil }
            name = defaultBuiltinParamName(for: .vertex) ?? "vid"
            attribute = "[[vertex_id]]"
            kind = "air.vertex_id"
        case .kernel:
            guard index == totalIRParamCount - 1 else { return nil }
            name = defaultBuiltinParamName(for: .kernel) ?? "tid"
            attribute = "[[thread_position_in_grid]]"
            kind = "air.thread_position_in_grid"
        case .helper:
            return nil
        }

        return ParsedParameter(
            name: name,
            irType: cleanedValueType,
            addressSpace: nil,
            bufferIndex: nil,
            attribute: attribute,
            stageInAttribute: nil,
            qualifiers: [],
            pointerInfo: nil,
            irArgIndex: index,
            kind: kind,
            hasNoAlias: false,
            emitAsValueParameter: false
        )
    }

    /// 为 metadata 未覆盖的 IR 参数生成稳定可读的参数名。
    ///
    /// - 若 IR 自身有语义化名字（如 `%uv` / `%threshold`），优先保留
    /// - 若只剩数字 SSA（如 `%2`），退回为 `argN`
    static func fallbackIRParameterName(from rawIRParam: String, index: Int) -> String {
        guard let irName = extractParamName(from: rawIRParam), !irName.isEmpty else {
            return "arg\(index)"
        }
        if irName.allSatisfy({ $0.isNumber }) {
            return "arg\(index)"
        }
        return irName
    }

    /// 从原始 IR 参数字符串里提取"值类型"部分，去掉限定词与参数名。
    ///
    /// 示例：
    /// - `<2 x float> noundef %uv` → `<2 x float>`
    /// - `i32 noundef %3` → `i32`
    /// - `%struct.Foo %arg` → `%struct.Foo`
    static func extractIRValueParameterType(from rawIRParam: String) -> String {
        let trimmed = rawIRParam.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let candidate: String
        if let percentIndex = trimmed.lastIndex(of: "%") {
            candidate = String(trimmed[..<percentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        guard !candidate.isEmpty else { return "" }

        return extractLeadingIRType(from: candidate)
    }

    /// 判断原始 IR 参数是否真的在函数体里被引用。
    ///
    /// 只对 `%name` / `%2` 这种参数 SSA 做精确匹配，避免 `%1` 误命中 `%10`。
    static func isIRParameterReferenced(_ rawIRParam: String, in irBody: String) -> Bool {
        guard let irName = extractParamName(from: rawIRParam), !irName.isEmpty else {
            return false
        }

        let token = "%\(irName)"
        var searchStart = irBody.startIndex
        while searchStart < irBody.endIndex,
              let range = irBody.range(of: token, range: searchStart..<irBody.endIndex) {
            let after = range.upperBound < irBody.endIndex ? irBody[range.upperBound] : nil
            if after == nil || !(after!.isLetter || after!.isNumber || after! == "_" || after! == ".") {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// 从一段参数前缀中抽取最前面的 IR 类型 token，支持向量 / 聚合 / 括号嵌套。
    static func extractLeadingIRType(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let first = trimmed.first ?? " "
        if first == "<" || first == "{" || first == "(" {
            var angleDepth = 0
            var braceDepth = 0
            var parenDepth = 0
            var inQuotes = false

            for index in trimmed.indices {
                let char = trimmed[index]
                if char == "\"" {
                    inQuotes.toggle()
                } else if !inQuotes {
                    switch char {
                    case "<": angleDepth += 1
                    case ">": angleDepth -= 1
                    case "{": braceDepth += 1
                    case "}": braceDepth -= 1
                    case "(": parenDepth += 1
                    case ")": parenDepth -= 1
                    default: break
                    }
                    if angleDepth == 0 && braceDepth == 0 && parenDepth == 0 {
                        return String(trimmed[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            return trimmed
        }

        let firstToken = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
        return firstToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 对缺失 pointer 参数沿用 parseParameters 的顺序绑定规则，避免 buffer/threadgroup 索引错位。
    static func fallbackBindingIndex(
        for rawIRParams: [String],
        targetIndex: Int,
        addressSpace: AddressSpace?
    ) -> Int? {
        guard let addressSpace else { return nil }

        if addressSpace.isBufferAddressSpace {
            var count = 0
            for i in 0..<rawIRParams.count {
                guard i <= targetIndex else { break }
                if let space = extractAddressSpace(from: rawIRParams[i]), space.isBufferAddressSpace {
                    if i == targetIndex { return count }
                    count += 1
                }
            }
        }

        if addressSpace.isThreadgroupAddressSpace {
            var count = 0
            for i in 0..<rawIRParams.count {
                guard i <= targetIndex else { break }
                if let space = extractAddressSpace(from: rawIRParams[i]), space.isThreadgroupAddressSpace {
                    if i == targetIndex { return count }
                    count += 1
                }
            }
        }

        return targetIndex
    }

    /// 从 IR 函数特征启发式推断 shader 类型
    static func inferShaderType(from irFunc: IRFunctionDef) -> ShaderType? {
        // 检查 calling convention 标记
        if irFunc.fullDefinition.contains("spir_kernel") || irFunc.fullDefinition.contains("cc76") {
            return .kernel
        }
        // cc75 在 Metal IR 中通常用于 vertex，cc77 用于 fragment
        if irFunc.fullDefinition.contains("cc75") {
            return .vertex
        }
        if irFunc.fullDefinition.contains("cc77") {
            return .fragment
        }

        // 从返回类型推断
        let ret = irFunc.returnType
        if ret == "void" {
            // void 返回通常是 kernel
            return .kernel
        }
        if ret.contains("<4 x float>") || ret.contains("{ <4 x float>") {
            // float4 或包含 float4 的结构体 → 通常是 vertex
            return .vertex
        }

        return nil
    }

    // MARK: - Parameter Parsing

    /// 解析 IR 函数的参数列表
    static func parseParameters(
        _ paramList: String,
        irBody: String,
        shaderType: ShaderType,
        orphanedArgLookup: [String: MetadataArgInfo] = [:]
    ) -> [ParsedParameter] {
        guard !paramList.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let rawParams = splitIRParameters(paramList)
        var params: [ParsedParameter] = []
        var bufferIdx = 0
        var threadgroupIdx = 0

        for (index, rawParam) in rawParams.enumerated() {
            let trimmed = rawParam.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "..." { continue }

            if let inferredBuiltin = inferImplicitEntryBuiltinParameter(
                from: trimmed,
                index: index,
                totalIRParamCount: rawParams.count,
                shaderType: shaderType
            ) {
                params.append(inferredBuiltin)
                continue
            }

            // 提取地址空间
            let addrSpace = extractAddressSpace(from: trimmed)
            let paramName = fallbackIRParameterName(from: trimmed, index: index)

            // E-006b2: 检查孤立 metadata 中是否有 texture/sampler 信息
            if let orphaned = orphanedArgLookup[paramName] {
                let attribute: String?
                let ptrInfo: PointerInfo?
                let irType: String
                switch orphaned.kind {
                case "air.texture":
                    attribute = orphaned.locationIndex.map { "[[texture(\($0))]]" }
                    ptrInfo = nil
                    irType = orphaned.typeName.isEmpty ? "texture2d<float>" : orphaned.typeName
                case "air.sampler":
                    attribute = orphaned.locationIndex.map { "[[sampler(\($0))]]" }
                    ptrInfo = nil
                    irType = "sampler"
                default:
                    attribute = nil
                    ptrInfo = nil
                    irType = ""
                }
                params.append(ParsedParameter(
                    name: orphaned.argName,
                    irType: irType,
                    addressSpace: addrSpace,
                    bufferIndex: orphaned.locationIndex,
                    attribute: attribute,
                    stageInAttribute: orphaned.stageInAttribute,
                    qualifiers: orphaned.qualifiers,
                    pointerInfo: ptrInfo,
                    irArgIndex: index,
                    kind: orphaned.kind,
                    hasNoAlias: irParameterHasNoAlias(trimmed),
                    emitAsValueParameter: false
                ))
                continue
            }

            // 提取指针信息
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)
            let cleanedValueType = extractIRValueParameterType(from: trimmed)

            // 确定 buffer/threadgroup 绑定索引
            let bindingIndex: Int?
            if let space = addrSpace {
                if space.isBufferAddressSpace {
                    bindingIndex = bufferIdx
                    bufferIdx += 1
                } else if space.isThreadgroupAddressSpace {
                    bindingIndex = threadgroupIdx
                    threadgroupIdx += 1
                } else {
                    bindingIndex = index
                }
            } else {
                bindingIndex = index
            }

            params.append(ParsedParameter(
                name: paramName,
                irType: ptrInfo == nil ? cleanedValueType : trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                stageInAttribute: nil,
                qualifiers: [],
                pointerInfo: ptrInfo,
                irArgIndex: index,
                kind: nil,
                hasNoAlias: irParameterHasNoAlias(trimmed),
                emitAsValueParameter: ptrInfo == nil && !cleanedValueType.isEmpty && isIRParameterReferenced(trimmed, in: irBody)
            ))
        }

        return params
    }

    /// 将 IR 参数列表按逗号分割，但保持尖括号嵌套（如 <4 x float>）
    static func splitIRParameters(_ paramList: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0

        for char in paramList {
            if char == "<" || char == "{" || char == "(" || char == "[" { depth += 1 }
            else if char == ">" || char == "}" || char == ")" || char == "]" { depth -= 1 }

            if char == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 从 IR 类型字符串中提取 addrspace(N)
    static func extractAddressSpace(from irType: String) -> AddressSpace? {
        guard let range = irType.range(of: "addrspace(") else { return nil }
        let afterParen = irType[range.upperBound...]
        guard let closeParen = afterParen.firstIndex(of: ")") else { return nil }
        let numStr = String(afterParen[afterParen.startIndex..<closeParen])
        guard let num = Int(numStr) else { return nil }
        return AddressSpace(rawValue: num)
    }

    static func irParameterHasNoAlias(_ irParam: String) -> Bool {
        let sanitized = irParam
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "*", with: " ")
        return sanitized.split(whereSeparator: \.isWhitespace).contains { $0 == "noalias" }
    }

    /// 从 IR 参数字符串中提取完整的指针信息（地址空间 + 指向的元素类型）。
    ///
    /// Metal LLVM IR 中指针参数的常见形式：
    /// 1. Opaque pointer (LLVM 15+): `ptr addrspace(1) %buf`
    /// 2. Typed pointer (旧式): `float addrspace(1)* %buf`, `<4 x float> addrspace(1)* %buf`
    /// 3. 结构体指针: `%struct.MyStruct addrspace(1)* %buf`
    static func extractPointerInfo(
        from irParam: String,
        addressSpace: AddressSpace?
    ) -> PointerInfo? {
        guard let space = addressSpace else { return nil }

        let trimmed = irParam.trimmingCharacters(in: .whitespaces)

        // Case 1: Opaque pointer — `ptr addrspace(N)`
        // LLVM 15+ 默认使用 opaque pointer，不携带元素类型信息
        if trimmed.hasPrefix("ptr ") || trimmed == "ptr" {
            return PointerInfo(
                addressSpace: space,
                pointedMSLType: inferDefaultElementType(for: space),
                isOpaquePointer: true
            )
        }

        // Case 2 & 3: Typed pointer — 提取 addrspace 前面的元素类型
        let pointedType = extractPointedType(from: trimmed)
        let mslType: String
        if let pointed = pointedType {
            mslType = irScalarTypeToMSL(pointed)
        } else {
            mslType = inferDefaultElementType(for: space)
        }

        return PointerInfo(
            addressSpace: space,
            pointedMSLType: mslType,
            isOpaquePointer: false
        )
    }

    /// 从 typed pointer IR 参数中提取指针指向的元素类型。
    ///
    /// 输入示例:
    /// - `float addrspace(1)* %buf` → `float`
    /// - `<4 x float> addrspace(2)* %0` → `<4 x float>`
    /// - `%struct.VertexIn addrspace(1)* %input` → `%struct.VertexIn`
    /// - `i32 addrspace(1)* %idx` → `i32`
    static func extractPointedType(from irParam: String) -> String? {
        // 查找 "addrspace(" 位置
        guard let addrRange = irParam.range(of: "addrspace(") else { return nil }

        // addrspace 前面的部分就是元素类型
        let beforeAddr = irParam[irParam.startIndex..<addrRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)

        if beforeAddr.isEmpty { return nil }

        // 如果以 "ptr" 开头说明是 opaque pointer，没有元素类型
        if beforeAddr == "ptr" { return nil }

        return beforeAddr
    }

    /// 对于 opaque pointer (LLVM 15+)，无法从 IR 参数中直接获取元素类型，
    /// 根据地址空间推断合理的默认元素类型。
    static func inferDefaultElementType(for space: AddressSpace) -> String {
        switch space {
        case .device:
            // device buffer 最常见的是 float 或结构体指针，用 uint8_t 作为通用字节指针
            return "uint8_t"
        case .constant:
            // constant buffer 通常是 uniform 数据，用 uint8_t 作为通用字节指针
            return "uint8_t"
        case .threadgroup:
            // threadgroup 共享内存，用 uint8_t
            return "uint8_t"
        case .thread:
            // thread-local 默认 float
            return "float"
        case .threadgroupImageblock:
            return "float"
        case .rayData:
            return "uint8_t"
        case .objectData:
            return "uint8_t"
        }
    }

    /// 将单个 IR 标量/向量类型转换为 MSL 类型（公共方法，供 ParsedParameter 使用）。
    ///
    /// 将 IR 中出现的所有基本类型映射为 MSL 类型：
    /// - 整数: i1→bool, i8→char/uint8_t, i16→short, i32→int, i64→long
    /// - 浮点: half, float, double
    /// - 向量: <4 x float>→float4, <2 x i32>→int2
    /// - 结构体名: %struct.X→X
    /// - metal::_atomic: 需配合 structFieldInfo 确定具体 atomic_int/atomic_uint，
    ///   此处仅做基本映射回退，精确映射在 buildParametersFromMetadata 中完成
    static func irScalarTypeToMSL(_ irType: String) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        // E-006b9: metal::_atomic → atomic_int 默认回退
        // 精确映射（atomic_uint 等）在 buildParametersFromMetadata 中根据 structFieldInfo 完成
        if cleaned == "metal::_atomic" { return "atomic_int" }

        // 基本整数类型
        if cleaned == "i1" { return "bool" }
        if cleaned == "i8" { return "uint8_t" }
        if cleaned == "i16" { return "short" }
        if cleaned == "i32" { return "int" }
        if cleaned == "i64" { return "long" }

        // 无符号整数变体（来自 zext/sext 上下文）
        // LLVM IR 本身无符号区分，但 MSL 需要，此处默认有符号
        if cleaned == "float" { return "float" }
        if cleaned == "half" { return "half" }
        if cleaned == "double" { return "float" } // MSL 不支持 double，降级为 float
        if cleaned == "void" { return "void" }

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
            let inner = String(cleaned.dropFirst().dropLast())
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let count = parts[0].trimmingCharacters(in: .whitespaces)
                let elemRaw = parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                // E-006a2e10: i8 向量特殊处理 — MSL 不支持 uint8_tN，必须用 ucharN
                if elemRaw == "i8" {
                    return "uchar\(count)"
                }
                let elemType = irScalarTypeToMSL(elemRaw)
                return "\(elemType)\(count)"
            }
        }

        // 结构体名: %struct.VertexIn → VertexIn, %"class::Name" → class_Name
        if cleaned.hasPrefix("%struct.") {
            let structName = String(cleaned.dropFirst("%struct.".count))
            return sanitizeUserTypeName(structName)
        }
        if cleaned.hasPrefix("%") {
            let typeName = String(cleaned.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeUserTypeName(typeName)
        }

        // 指针类型 → void* 等效
        if cleaned.contains("*") || cleaned == "ptr" {
            return "uint8_t"
        }

        return cleaned.isEmpty ? "uint8_t" : cleaned
    }

    /// 判断类型名是否为 MSL 标量或向量基本类型（如 float, float2, float4, half, int, uint 等）。
    /// 这些类型在 metadata 中可能出现为 arg_type_name，但不应被 sanitizeTypeName 大写化。
    static func isMSLScalarOrVectorType(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let baseTypes: Set<String> = [
            "float", "half", "int", "uint", "short", "ushort", "char", "uchar",
            "bool", "double", "long", "ulong", "size_t", "ptrdiff_t",
            "float4x4", "float3x3", "float2x2", "half4x4", "half3x3", "half2x2",
            "texture1d", "texture2d", "texture3d", "texturecube",
            "texture1d_array", "texture2d_array",
            "sampler",
            "atomic_uint", "atomic_int",
            "thread", "device", "constant",
        ]
        if baseTypes.contains(trimmed) { return true }
        // 匹配 float2, float3, float4, int2, uint4 等向量类型
        let vectorPattern = "^(float|half|int|uint|short|ushort|char|uchar|bool|double|long|ulong)([2-4])$"
        if trimmed.range(of: vectorPattern, options: .regularExpression) != nil { return true }
        return false
    }

    /// 将类型名清理为合法的 MSL 标识符
    static func sanitizeTypeName(_ name: String) -> String {
        sanitizeIdentifier(name, fallback: "UnknownType", uppercaseFirst: true)
    }

    static func sanitizeUserTypeName(_ name: String) -> String {
        sanitizeIdentifier(name, fallback: "UnknownType", uppercaseFirst: false)
    }

    static func sanitizeIdentifier(
        _ name: String,
        fallback: String,
        uppercaseFirst: Bool
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        var result = ""
        for (index, char) in trimmed.enumerated() {
            let isAllowed = char.isLetter || char.isNumber || char == "_"
            let normalized: Character = isAllowed ? char : "_"
            if index == 0 && normalized.isNumber {
                result.append("_")
            }
            result.append(normalized)
        }

        if result.isEmpty { return fallback }
        if uppercaseFirst, let first = result.first {
            return String(first).uppercased() + result.dropFirst()
        }
        return result
    }

    /// 从 IR 参数字符串中提取参数名
    static func extractParamName(from irParam: String) -> String? {
        // 参数名格式: %name 或 %0, %1 等
        guard let percentIndex = irParam.lastIndex(of: "%") else { return nil }
        let afterPercent = irParam[irParam.index(after: percentIndex)...]
        let name = afterPercent.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        return name.isEmpty ? nil : String(name)
    }

    /// 从 `define ...(<params>)` 形式的 IR 签名里提取纯参数列表。
    static func extractIRParameterList(from irSignature: String) -> String {
        guard let openParen = irSignature.firstIndex(of: "(") else { return irSignature }
        var depth = 0
        var cursor = openParen
        while cursor < irSignature.endIndex {
            let char = irSignature[cursor]
            if char == "(" { depth += 1 }
            else if char == ")" {
                depth -= 1
                if depth == 0 {
                    let start = irSignature.index(after: openParen)
                    return String(irSignature[start..<cursor])
                }
            }
            cursor = irSignature.index(after: cursor)
        }
        return irSignature
    }

    /// 收集需要强制按指针参数发射的 constant struct buffer 参数。
    ///
    /// 某些 addrspace(2) 结构体参数虽然 metadata 看起来像“单个 uniforms 对象”，
    /// 但函数体里的 GEP 会对它做非零首索引（如 `%buf, i64 %instanceId, ...`），
    /// 这说明它在 IR 语义上其实是数组/指针根，而不是单对象引用。
    /// 这类参数若仍发射成 `constant T&`，后续 lowering 会生成 `buf[idx]` 之类非法 MSL。
    static func collectArrayIndexedConstantStructBufferArgs(
        params: [ParsedParameter],
        irParamList: String,
        irBody: String
    ) -> Set<Int> {
        let candidateArgIndices = Set(params.compactMap { param -> Int? in
            guard let irArgIndex = param.irArgIndex,
                  let ptr = param.pointerInfo,
                  ptr.addressSpace == .constant,
                  ptr.addressSpace.isBufferAddressSpace,
                  isStructTypeName(ptr.pointedMSLType),
                  !ptr.pointedMSLType.hasPrefix("atomic_") else {
                return nil
            }
            return irArgIndex
        })
        guard !candidateArgIndices.isEmpty else { return [] }

        let rawIRParams = splitIRParameters(irParamList)
        var argIndexBySSAName: [String: Int] = [:]
        for argIndex in candidateArgIndices where argIndex < rawIRParams.count {
            let irName = extractParamName(from: rawIRParams[argIndex]) ?? "\(argIndex)"
            argIndexBySSAName["%\(irName)"] = argIndex
        }
        guard !argIndexBySSAName.isEmpty else { return [] }

        var forcedPointerArgIndices: Set<Int> = []
        for line in irBody.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains("getelementptr ") else { continue }

            let rhs: String
            if let equalIndex = trimmed.firstIndex(of: "=") {
                rhs = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rhs = trimmed
            }
            guard rhs.hasPrefix("getelementptr ") else { continue }

            var cleaned = rhs.replacingOccurrences(of: "getelementptr ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.hasPrefix("inbounds ") {
                cleaned = String(cleaned.dropFirst("inbounds ".count))
            }

            let parts = splitTypedOperands(cleaned, count: 10)
            guard parts.count >= 3 else { continue }

            let baseSSAName = extractSSAName(from: parts[1].value)
            guard let argIndex = argIndexBySSAName[baseSSAName] else { continue }

            let firstIdx = parts[2].value.trimmingCharacters(in: .whitespacesAndNewlines)
            if firstIdx != "0" {
                forcedPointerArgIndices.insert(argIndex)
            }
        }

        return forcedPointerArgIndices
    }

    // MARK: - IR Type → MSL Type Mapping

    /// 将 IR 返回类型转换为 MSL 类型
    static func irTypeToMSL(_ irType: String, forShaderType shaderType: ShaderType) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        // 基本类型映射
        if cleaned == "void" { return "void" }
        if cleaned == "float" { return "float" }
        if cleaned == "half" { return "half" }
        if cleaned == "i32" { return "int" }
        if cleaned == "i16" { return "short" }
        if cleaned == "i8" { return "char" }
        if cleaned == "i1" { return "bool" }
        if cleaned == "i64" { return "long" }
        if cleaned == "double" { return "double" }

        // packed/anonymous aggregate 返回值（如 fragment 的 <{ <4 x float> }> 或 live 样本中的 <{ <4 x float>, i8 }>）
        // 必须先于向量分支处理，否则会被误识别成 `<N x T>` 并产出类似 `float4{ <4` 的坏签名。
        if cleaned.hasPrefix("<{") || cleaned.hasPrefix("{") || cleaned.hasPrefix("%struct") {
            return defaultReturnType(for: shaderType)
        }

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
            let inner = String(cleaned.dropFirst().dropLast())  // 去掉 < >
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let count = parts[0].trimmingCharacters(in: .whitespaces)
                let elemType = irTypeToMSL(
                    parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces),
                    forShaderType: shaderType
                )
                return "\(elemType)\(count)"
            }
        }

        // 指针类型
        if cleaned.contains("ptr") || cleaned.contains("*") {
            return defaultReturnType(for: shaderType)
        }

        return defaultReturnType(for: shaderType)
    }

    /// Shader 类型的默认返回类型
    static func defaultReturnType(for shaderType: ShaderType) -> String {
        switch shaderType {
        case .vertex: return "float4"
        case .fragment: return "float4"
        case .kernel: return "void"
        case .helper: return "float"
        }
    }
}
