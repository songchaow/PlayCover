import Foundation

extension IRToMSLConverter {
    /// 生成完整的 MSL 源码
    static func generateMSL(
        functions: [ParsedShaderFunction],
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        globalConstants: [IRGlobalConstant] = [],
        irText: String = ""
    ) -> String {
        var lines: [String] = []
        let emittedSamplerStateGlobals = Set(
            globalConstants.compactMap { global in
                renderSamplerStateDeclaration(
                    irName: global.irName,
                    irType: global.irType,
                    initializer: global.initializer,
                    usedBySampleCompare: false
                ) == nil ? nil : global.irName
            }
        )

        // Header
        lines.append("//")
        lines.append("// Auto-generated MSL source by PlayTools IRToMSLConverter")
        lines.append("// E-004e: LLVM IR → MSL stub conversion")
        lines.append("// Generated at: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("// Functions: \(functions.count)")
        lines.append("//")
        lines.append("")
        lines.append("#include <metal_stdlib>")
        lines.append("using namespace metal;")
        lines.append("")

        func parseIRArrayType(_ irType: String) -> (count: Int, elementType: String)? {
            let trimmed = irType.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let xRange = trimmed.range(of: " x ") else {
                return nil
            }
            let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let count = Int(countStr) else { return nil }
            let afterX = trimmed[xRange.upperBound...]
            let elementType = String(afterX[..<afterX.index(before: afterX.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            return (count, elementType)
        }

        func globalConstantDeclaration(irType: String, name: String) -> String {
            if let array = parseIRArrayType(irType) {
                return "\(globalConstantDeclaration(irType: array.elementType, name: name))[\(array.count)]"
            }
            return "\(irScalarTypeToMSL(irType)) \(name)"
        }

        func renderGlobalConstantInitializer(irType: String, initializer: String) -> String {
            let trimmedType = irType.trimmingCharacters(in: .whitespaces)
            let trimmedInit = initializer.trimmingCharacters(in: .whitespaces)

            if let array = parseIRArrayType(trimmedType) {
                if trimmedInit == "zeroinitializer" || trimmedInit == "undef" || trimmedInit == "poison" {
                    let zeroValue = renderGlobalConstantInitializer(irType: array.elementType, initializer: "zeroinitializer")
                    return "{ \(Array(repeating: zeroValue, count: array.count).joined(separator: ", ")) }"
                }
                guard trimmedInit.hasPrefix("["), trimmedInit.hasSuffix("]") else {
                    return trimmedInit
                }
                let inner = String(trimmedInit.dropFirst().dropLast())
                let rawElements = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let renderedElements = rawElements.map { rawElement -> String in
                    let (elementType, afterType) = parseIRType(rawElement)
                    if !elementType.isEmpty {
                        let (elementValue, _) = parseIRValue(afterType)
                        return renderGlobalConstantInitializer(irType: elementType, initializer: elementValue)
                    }
                    return renderGlobalConstantInitializer(irType: array.elementType, initializer: rawElement)
                }
                return "{ \(renderedElements.joined(separator: ", ")) }"
            }

            if trimmedInit == "zeroinitializer" || trimmedInit == "undef" || trimmedInit == "poison" {
                return "\(irScalarTypeToMSL(trimmedType))(0)"
            }
            if trimmedType.hasPrefix("<") {
                return parseVectorLiteral(trimmedInit)
            }
            return resolveIROperand(trimmedInit, ctx: SSAContext())
        }

        if functions.isEmpty {
            lines.append("// No shader functions found in IR")
            return lines.joined(separator: "\n")
        }

        let userStructDefinitions = generateUserStructDefinitions(structFieldInfo, structTypeDefs: structTypeDefs)
        if !userStructDefinitions.isEmpty {
            lines.append(contentsOf: userStructDefinitions)
            lines.append("")
        }

        if !globalConstants.isEmpty {
            let compareSamplerStateGlobals = collectCompareSamplerStateGlobals(irText)
            for global in globalConstants {
                if let samplerDeclaration = renderSamplerStateDeclaration(
                    irName: global.irName,
                    irType: global.irType,
                    initializer: global.initializer,
                    usedBySampleCompare: compareSamplerStateGlobals.contains(global.irName)
                ) {
                    lines.append(samplerDeclaration)
                    continue
                }

                let symbolName = sanitizeIdentifier(
                    String(global.irName.dropFirst()).replacingOccurrences(of: "\"", with: ""),
                    fallback: "globalConstant",
                    uppercaseFirst: false
                )
                let declaration = globalConstantDeclaration(irType: global.irType, name: symbolName)
                let initializer = renderGlobalConstantInitializer(irType: global.irType, initializer: global.initializer)
                lines.append("constant \(declaration) = \(initializer);")
            }
            lines.append("")
        }

        let helperFunctions = functions.filter { !$0.isEntryPoint }
        if !helperFunctions.isEmpty {
            var emittedHelperPrototypes: Set<String> = []
            for helper in helperFunctions {
                let safeName = sanitizeFunctionName(helper.name)
                guard emittedHelperPrototypes.insert(safeName).inserted else { continue }
                let params = generateAllParams(
                    helper.parameters,
                    safeName: safeName,
                    shaderType: .helper,
                    defaultBuiltin: ""
                )
                lines.append("\(helper.returnType) \(safeName)(\(params));")
            }
            lines.append("")
        }

        // 用于去重
        var emittedNames: Set<String> = []
        var emittedAuxiliaryStructs: Set<String> = []

        for (index, func_) in functions.enumerated() {
            // MSL 不允许重复的函数名
            let safeName = sanitizeFunctionName(func_.name)
            if emittedNames.contains(safeName) { continue }
            emittedNames.insert(safeName)

            if let outputStruct = generateEntryOutputStructDefinition(for: func_),
               emittedAuxiliaryStructs.insert(outputStruct.name).inserted {
                lines.append(outputStruct.definition)
                lines.append("")
            }

            if let stageInStruct = generateStageInStructDefinition(for: func_, safeName: safeName),
               emittedAuxiliaryStructs.insert(stageInStruct.name).inserted {
                lines.append(stageInStruct.definition)
                lines.append("")
            }

            lines.append("// [\(index)] \(func_.shaderType.rawValue): \(func_.name)")
            if func_.isEntryPoint && !func_.isFullyParsed {
                lines.append("// (stub — IR signature not fully converted)")
                lines.append("// IR: \(func_.irSignature.prefix(200))")
            }
            // 列出函数体中用到的 air 内建（去重汇总）
            if !func_.airBuiltinCalls.isEmpty {
                var seenBases: Set<String> = []
                var builtinSummary: [String] = []
                for call in func_.airBuiltinCalls {
                    guard seenBases.insert(call.airBaseName).inserted else { continue }
                    if let m = call.mapping {
                        builtinSummary.append("\(call.airBaseName) → \(m.mslFunction)")
                    } else {
                        builtinSummary.append("\(call.airBaseName) → ?")
                    }
                }
                lines.append("// air builtins: \(builtinSummary.joined(separator: ", "))")
            }

            // 生成函数
            let funcCode = generateFunction(
                func_, safeName: safeName,
                structTypeDefs: structTypeDefs,
                structFieldInfo: structFieldInfo,
                emittedSamplerStateGlobals: emittedSamplerStateGlobals
            )
            lines.append(funcCode)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func generateUserStructDefinitions(
        _ structFieldInfo: [String: [StructFieldInfo]],
        structTypeDefs: [String: IRStructTypeDef] = [:]
    ) -> [String] {
        guard !structFieldInfo.isEmpty else { return [] }

        let knownTypes = Set(structFieldInfo.keys)
        var emitted: Set<String> = []
        var lines: [String] = []

        /// 将 IR 数组类型 [N x T] 转为 MSL 数组声明 "elementType fieldName[N]"
        /// 返回 nil 表示不是数组类型
        func irArrayTypeToMSLField(_ irType: String, fieldName: String) -> String? {
            let trimmed = irType.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
            // 解析 "[N x T]" → (count, elementType)
            guard let xRange = trimmed.range(of: " x ") else { return nil }
            let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
            guard let count = Int(countStr.trimmingCharacters(in: .whitespaces)) else { return nil }
            let afterX = trimmed[xRange.upperBound...]
            // 去掉末尾的 ]
            let elementTypeIR = String(afterX[afterX.startIndex..<afterX.index(before: afterX.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let elementTypeMSL = irScalarTypeToMSL(elementTypeIR)
            return "\(elementTypeMSL) \(fieldName)[\(count)]"
        }

        func emitStruct(named rawTypeName: String) {
            let sanitizedTypeName = sanitizeUserTypeName(rawTypeName)
            guard emitted.insert(sanitizedTypeName).inserted else { return }
            guard let fields = structFieldInfo[rawTypeName], !fields.isEmpty else { return }

            for field in fields {
                if knownTypes.contains(field.typeName) {
                    emitStruct(named: field.typeName)
                }
            }

            // 尝试找到对应的 IR 结构体定义，用于交叉验证字段类型
            let irTypeDef = structTypeDefs.first { key, _ in
                sanitizeUserTypeName(String(key.dropFirst(key.hasPrefix("%") ? 1 : 0)).replacingOccurrences(of: "\"", with: "")) == sanitizedTypeName
            }

            lines.append("struct \(sanitizedTypeName) {")
            for field in fields.sorted(by: { $0.index < $1.index }) {
                let fieldName = sanitizeIdentifier(field.fieldName, fallback: "field\(field.index)", uppercaseFirst: false)

                // E-006c3: 优先使用 air.struct_type_info 的 elementCount（第三个 i32）判断数组字段。
                // elementCount > 1 说明该字段是数组，直接生成 "typeName fieldName[N]"，
                // 比 IR 交叉检查更直接，覆盖 elementCount > 1 但 IR 字段不是 [N x T] 的边缘情况。
                if field.elementCount > 1 {
                    let elementTypeMSL = knownTypes.contains(field.typeName)
                        ? sanitizeUserTypeName(field.typeName)
                        : field.typeName
                    lines.append("    \(elementTypeMSL) \(fieldName)[\(field.elementCount)];")
                    continue
                }

                // E-006c2: 交叉检查 IR 结构体字段类型与 metadata 类型
                // 当 metadata 声明为标量（如 "float"）但 IR 实际为 [N x T] 数组时，
                // 使用 IR 类型生成正确的 MSL 数组声明
                if let irDef = irTypeDef?.value, field.index < irDef.fieldIRTypes.count {
                    let irFieldType = irDef.fieldIRTypes[field.index].trimmingCharacters(in: .whitespaces)
                    if let arrayField = irArrayTypeToMSLField(irFieldType, fieldName: fieldName) {
                        lines.append("    \(arrayField);")
                        continue
                    }
                }

                let fieldType = knownTypes.contains(field.typeName)
                    ? sanitizeUserTypeName(field.typeName)
                    : field.typeName
                lines.append("    \(fieldType) \(fieldName);")
            }
            lines.append("};")
            lines.append("")
        }

        for rawTypeName in structFieldInfo.keys.sorted() {
            // E-006b9: metal::_atomic 是 MSL 内建 atomic 类型，不需要生成 struct 定义
            if rawTypeName == "metal::_atomic" { continue }
            emitStruct(named: rawTypeName)
        }

        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    static func generateEntryOutputStructDefinition(
        for func_: ParsedShaderFunction
    ) -> (name: String, definition: String)? {
        guard !func_.outputs.isEmpty else { return nil }
        let expectedStructName = entryOutputStructName(for: func_.name)
        guard func_.returnType == expectedStructName else { return nil }

        let structName = func_.returnType
        var lines: [String] = ["struct \(structName) {"]
        for (index, output) in func_.outputs.enumerated() {
            let fieldType = entryOutputFieldType(for: output, index: index)

            let fallbackName: String
            switch output.kind {
            case "air.position":
                fallbackName = "position"
            case "air.render_target":
                fallbackName = "color\(output.locationIndex ?? index)"
            case "air.vertex_output":
                fallbackName = "varying\(index)"
            case "air.depth":
                fallbackName = "depth"
            default:
                // E-006a2e11: heuristic — detect depth output by arg name
                let nameLC = output.argName.lowercased()
                fallbackName = nameLC.contains("depth") ? "depth" : "field\(index)"
            }
            let fieldName = sanitizeIdentifier(output.argName, fallback: fallbackName, uppercaseFirst: false)

            let attribute: String
            switch output.kind {
            case "air.position":
                attribute = output.qualifiers.contains("air.invariant")
                    ? " [[position, invariant]]"
                    : " [[position]]"
            case "air.render_target":
                attribute = " [[color(\(output.locationIndex ?? 0))]]"
            case "air.depth":
                attribute = " [[depth(any)]]"
            default:
                // E-006a2e11: heuristic — detect depth output by field name
                if fieldName.lowercased().contains("depth") {
                    attribute = " [[depth(any)]]"
                } else {
                    attribute = ""
                }
            }

            lines.append("    \(fieldType) \(fieldName)\(attribute);")
        }
        lines.append("};")
        return (structName, lines.joined(separator: "\n"))
    }

    static func stageInStructName(for safeName: String) -> String {
        sanitizeTypeName(safeName) + "_StageIn"
    }

    static func interpolationAttribute(for param: ParsedParameter) -> String? {
        let qualifierSet = Set(param.qualifiers)
        if qualifierSet.contains("air.flat") {
            return "[[flat]]"
        }

        let location: String?
        if qualifierSet.contains("air.centroid") {
            location = "centroid"
        } else if qualifierSet.contains("air.sample") {
            location = "sample"
        } else if qualifierSet.contains("air.center") {
            location = "center"
        } else {
            location = nil
        }

        let perspective: String?
        if qualifierSet.contains("air.no_perspective") {
            perspective = "no_perspective"
        } else if qualifierSet.contains("air.perspective") {
            perspective = "perspective"
        } else {
            perspective = nil
        }

        guard let location, let perspective else { return nil }
        return "[[\(location)_\(perspective)]]"
    }

    static func stageInFieldAttributes(for param: ParsedParameter) -> String {
        var attributes: [String] = []

        switch param.kind {
        case "air.position":
            attributes.append("[[position]]")
        case "air.vertex_input":
            if let location = param.bufferIndex {
                attributes.append("[[attribute(\(location))]]")
            }
        case "air.fragment_input":
            if let stageInAttribute = param.stageInAttribute,
               !stageInAttribute.isEmpty {
                attributes.append("[[\(stageInAttribute)]]")
            }
        default:
            break
        }

        if let interpolation = interpolationAttribute(for: param) {
            attributes.append(interpolation)
        }

        guard !attributes.isEmpty else { return "" }
        return " " + attributes.joined(separator: " ")
    }

    static func generateStageInStructDefinition(
        for func_: ParsedShaderFunction,
        safeName: String
    ) -> (name: String, definition: String)? {
        guard shouldUseStageInStruct(func_.parameters, shaderType: func_.shaderType) else {
            return nil
        }

        let stageParams = func_.parameters
            .filter { isStageInParameter($0, shaderType: func_.shaderType) }
            .sorted { ($0.irArgIndex ?? .min) < ($1.irArgIndex ?? .min) }
        guard !stageParams.isEmpty else { return nil }

        let structName = stageInStructName(for: safeName)
        var lines: [String] = ["struct \(structName) {"]
        for param in stageParams {
            let fieldType = irScalarTypeToMSL(param.irType.isEmpty ? "float" : param.irType)
            let fieldName = sanitizeIdentifier(param.name, fallback: "arg\(param.irArgIndex ?? 0)", uppercaseFirst: false)
            let attributes = stageInFieldAttributes(for: param)
            lines.append("    \(fieldType) \(fieldName)\(attributes);")
        }
        lines.append("};")
        return (structName, lines.joined(separator: "\n"))
    }

    /// 生成单个 shader 函数的 MSL 代码
    static func generateFunction(
        _ func_: ParsedShaderFunction,
        safeName: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        emittedSamplerStateGlobals: Set<String> = []
    ) -> String {
        // 如果有函数体 IR，尝试翻译为真实 MSL 语句（E-004e4a）
        if !func_.irBody.isEmpty {
            return generateFunctionWithBody(
                func_, safeName: safeName,
                structTypeDefs: structTypeDefs,
                structFieldInfo: structFieldInfo,
                emittedSamplerStateGlobals: emittedSamplerStateGlobals
            )
        }
        // 回退到 stub 生成
        return generateStubFunction(func_, safeName: safeName)
    }

    /// 生成带真实函数体的 MSL 代码（E-004e4a）
    static func generateFunctionWithBody(
        _ func_: ParsedShaderFunction,
        safeName: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        emittedSamplerStateGlobals: Set<String> = []
    ) -> String {
        let irParamList = extractIRParameterList(from: func_.irSignature)
        let forcedPointerArgIndices = collectArrayIndexedConstantStructBufferArgs(
            params: func_.parameters,
            irParamList: irParamList,
            irBody: func_.irBody
        )

        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: func_.shaderType,
            defaultBuiltin: defaultBuiltinParam(for: func_.shaderType),
            fragmentReturnType: func_.shaderType == .kernel ? "" : func_.returnType,
            forcedPointerArgIndices: forcedPointerArgIndices
        )

        let bodyStatements = translateFunctionBody(
            func_, irParamList: irParamList,
            structTypeDefs: structTypeDefs,
            structFieldInfo: structFieldInfo,
            forcedPointerArgIndices: forcedPointerArgIndices,
            emittedSamplerStateGlobals: emittedSamplerStateGlobals
        )

        let shaderQualifier = func_.isEntryPoint ? func_.shaderType.rawValue : ""
        let retType = func_.shaderType == .kernel ? "void" : func_.returnType

        var lines: [String] = []
        if shaderQualifier.isEmpty {
            lines.append("\(retType) \(safeName)(\(allParams)) {")
        } else {
            lines.append("\(shaderQualifier) \(retType) \(safeName)(\(allParams)) {")
        }
        for stmt in bodyStatements {
            lines.append("    \(stmt)")
        }
        // 确保非 void 函数有返回值
        if retType != "void" && !bodyStatements.contains(where: { $0.hasPrefix("return ") }) {
            lines.append("    return \(defaultReturnValue(for: retType));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// 生成 stub 函数（回退路径）
    static func generateStubFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        switch func_.shaderType {
        case .vertex:
            return generateVertexFunction(func_, safeName: safeName)
        case .fragment:
            return generateFragmentFunction(func_, safeName: safeName)
        case .kernel:
            return generateKernelFunction(func_, safeName: safeName)
        case .helper:
            return generateHelperFunction(func_, safeName: safeName)
        }
    }

    /// shader 类型对应的默认内置参数
    static func defaultBuiltinParam(for type: ShaderType) -> String {
        switch type {
        case .vertex: return "uint vid [[vertex_id]]"
        case .fragment: return ""
        case .kernel: return "uint tid [[thread_position_in_grid]]"
        case .helper: return ""
        }
    }

    /// 生成 vertex shader stub
    static func generateVertexFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .vertex,
            defaultBuiltin: "uint vid [[vertex_id]]"
        )

        return """
        vertex \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 fragment shader stub
    static func generateFragmentFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .fragment,
            defaultBuiltin: "",
            fragmentReturnType: func_.returnType
        )

        return """
        fragment \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 kernel (compute) shader stub
    static func generateKernelFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .kernel,
            defaultBuiltin: "uint tid [[thread_position_in_grid]]"
        )

        return """
        kernel void \(safeName)(\(allParams)) {
            // stub kernel
        }
        """
    }

    /// 生成普通 helper 函数 stub
    static func generateHelperFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .helper,
            defaultBuiltin: ""
        )

        if func_.returnType == "void" {
            return """
            void \(safeName)(\(allParams)) {
                // stub helper
            }
            """
        }

        return """
        \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成完整的参数列表，包括 buffer 参数、texture/sampler 参数和内置属性参数。
    ///
    /// 如果 metadata 提供了精确参数信息，使用它们；否则使用 defaultBuiltin 作为回退。
    static func generateAllParams(
        _ params: [ParsedParameter],
        safeName: String,
        shaderType: ShaderType,
        defaultBuiltin: String,
        fragmentReturnType: String = "",
        forcedPointerArgIndices: Set<Int> = []
    ) -> String {
        var mslParams: [String] = []
        let usesStageIn = shouldUseStageInStruct(params, shaderType: shaderType)
        var hasEntryInput = usesStageIn
        // E-006b2: fragment shader 中无 attribute 的 value 参数需要 [[color(N)]]
        // 当 fragment 返回非 void 标量/向量类型时，Metal 编译器隐式将返回值绑定到 [[color(0)]]，
        // 此时输入 value 参数的 color index 必须从 1 开始以避免冲突。
        var colorInputIdx: Int
        if shaderType == .fragment && fragmentReturnType != "void" && fragmentReturnType != "" {
            colorInputIdx = 1
        } else {
            colorInputIdx = 0
        }

        let stageInType = usesStageIn ? stageInStructName(for: safeName) : ""
        var didEmitStageInParam = false

        for param in params {
            if usesStageIn && isStageInParameter(param, shaderType: shaderType) {
                if !didEmitStageInParam {
                    mslParams.append("\(stageInType) \(stageInParamName) [[stage_in]]")
                    didEmitStageInParam = true
                }
                continue
            }

            let emittedName = sanitizeIdentifier(
                param.name,
                fallback: "arg\(param.irArgIndex ?? 0)",
                uppercaseFirst: false
            )

            // 有 pointerInfo 的是 buffer/threadgroup 参数
            if let ptr = param.pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { continue }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""
                let restrictPrefix = param.hasNoAlias ? "__restrict " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    // E-006b9: atomic 类型在 MSL 中是引用类型，使用 & 而非 *
                    let isAtomicType = elemType.hasPrefix("atomic_")
                    let shouldKeepReference = isStructTypeName(elemType) &&
                        ptr.addressSpace == .constant &&
                        !isAtomicType &&
                        !forcedPointerArgIndices.contains(param.irArgIndex ?? -1)
                    if shouldKeepReference {
                        // 仅当 IR 没把它当数组/指针根使用时，constant struct 才保留 `constant Uniforms& uniforms` 形式。
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)& \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    } else if isAtomicType {
                        // MSL 中 atomic 类型作为 buffer 参数使用引用: device atomic_uint& counter
                        mslParams.append("\(qualifier) \(elemType)& \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    } else {
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)* \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    }
                } else if ptr.addressSpace.isThreadgroupAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    mslParams.append("threadgroup \(elemType)* \(emittedName) [[threadgroup(\(idx))]]")
                } else {
                    mslParams.append("\(qualifier) \(elemType)* \(emittedName)")
                }
                continue
            }

            // 有 attribute 的是内置属性 或 texture/sampler
            if let attr = param.attribute {
                let rawTypeName = param.irType.isEmpty ? "uint" : param.irType.replacingOccurrences(of: "\"", with: "")

                if attr.hasPrefix("[[texture(") || rawTypeName.hasPrefix("texture") {
                    let cleanedTexType = cleanTextureTypeName(rawTypeName)
                    mslParams.append("\(cleanedTexType) \(emittedName) \(attr)")
                } else if attr.hasPrefix("[[sampler(") || rawTypeName == "sampler" {
                    mslParams.append("sampler \(emittedName) \(attr)")
                } else {
                    hasEntryInput = true
                    let emittedType = irScalarTypeToMSL(rawTypeName)
                    mslParams.append("\(emittedType) \(emittedName) \(attr)")
                }
                continue
            }

            if param.emitAsValueParameter {
                let rawTypeName = param.irType.isEmpty ? "float" : param.irType.replacingOccurrences(of: "\"", with: "")
                let emittedType = irScalarTypeToMSL(rawTypeName)
                // E-006b2: fragment shader 的 value 参数必须带 [[color(N)]]，否则 Metal 编译器报
                // "invalid implicit color input declarations"
                let colorAttr: String
                if shaderType == .fragment {
                    colorAttr = " [[color(\(colorInputIdx))]]"
                    colorInputIdx += 1
                    hasEntryInput = true
                } else {
                    colorAttr = ""
                }
                mslParams.append("\(emittedType) \(emittedName)\(colorAttr)")
                continue
            }

            // 回退：有地址空间但没有详细信息
            if let addrSpace = param.addressSpace {
                let qualifier = addrSpace.mslQualifier
                if qualifier.isEmpty { continue }
                let idx = param.bufferIndex ?? 0
                let constPrefix = addrSpace.isReadOnly ? "const " : ""
                let restrictPrefix = param.hasNoAlias ? "__restrict " : ""
                if addrSpace.isBufferAddressSpace {
                    mslParams.append("\(constPrefix)\(qualifier) uint8_t* \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                } else if addrSpace.isThreadgroupAddressSpace {
                    mslParams.append("threadgroup uint8_t* \(emittedName) [[threadgroup(\(idx))]]")
                }
            }
        }

        // 如果没有从 metadata 获取入口输入参数，添加默认的 builtin。
        if !hasEntryInput && !defaultBuiltin.isEmpty {
            mslParams.insert(defaultBuiltin, at: 0)
        }

        return mslParams.joined(separator: ", ")
    }

    /// 判断类型名是否像是用户定义结构体。
    ///
    /// 这里不能只看首字母是否大写：真实 shader 中常见的 constant buffer 结构体名还会出现
    /// `_ScreenSpaceShadowParams_Type`、`cb_SSAOBlur_Type` 这类前导下划线 / 小写前缀形式。
    /// 只要它不是 MSL 标量/向量/纹理等内建类型，且呈现典型用户类型命名特征，
    /// 都应视为结构体，以便在 constant buffer 上优先保留 `const constant T&`，
    /// 让 round-trip 后的 AIR 继续保留 `dereferenceable(N)`。
    static func isStructTypeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isMSLScalarOrVectorType(trimmed) else { return false }
        guard trimmed != "sampler", !trimmed.hasPrefix("texture"), !trimmed.hasPrefix("atomic_") else {
            return false
        }
        if trimmed.hasSuffix("_Type") {
            return true
        }
        guard let firstLetter = trimmed.first(where: { $0.isLetter }) else { return false }
        return firstLetter.isUppercase
    }

    /// 清理 texture 类型名，将 AIR access 限定符映射为 Metal 格式
    /// "texture2d<float, sample>"      → "texture2d<float>"          (默认，省略)
    /// "texture2d<float, read>"       → "texture2d<float, access::read>"
    /// "texture2d<float, write>"      → "texture2d<float, access::write>"
    /// "texture2d<float, read_write>" → "texture2d<float, access::read_write>"
    static func cleanTextureTypeName(_ name: String) -> String {
        let normalizedName = name.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ltIdx = normalizedName.firstIndex(of: "<"),
              let gtIdx = normalizedName.lastIndex(of: ">") else {
            return normalizedName
        }
        let innerContent = normalizedName[normalizedName.index(after: ltIdx)..<gtIdx]
        let parts = innerContent.components(separatedBy: ",")
        let elemType = parts[0].trimmingCharacters(in: .whitespaces)
        let prefix = String(normalizedName[normalizedName.startIndex...ltIdx])
        if parts.count > 1 {
            let access = parts[1].trimmingCharacters(in: .whitespaces)
            switch access {
            case "sample":
                // 默认 access，省略
                return "\(prefix)\(elemType)>"
            case "read":
                return "\(prefix)\(elemType), access::read>"
            case "write":
                return "\(prefix)\(elemType), access::write>"
            case "read_write":
                return "\(prefix)\(elemType), access::read_write>"
            default:
                // 未知 access 限定符，原样保留
                return "\(prefix)\(elemType), \(access)>"
            }
        }
        return normalizedName
    }

    /// 生成给定类型的默认返回值
    static func defaultReturnValue(for mslType: String) -> String {
        if mslType == "void" { return "" }
        if mslType == "float4" { return "float4(0.0)" }
        if mslType == "float3" { return "float3(0.0)" }
        if mslType == "float2" { return "float2(0.0)" }
        if mslType == "half4" { return "half4(0.0h)" }
        if mslType == "float" { return "0.0" }
        if mslType == "half" { return "0.0h" }
        if mslType == "int" { return "0" }
        if mslType == "uint" { return "0u" }
        if mslType == "bool" { return "false" }
        // 对于未知的复合类型，返回空初始化
        return "\(mslType)()"
    }

    /// 将函数名清理为合法的 MSL 标识符
    static func sanitizeFunctionName(_ name: String) -> String {
        // MSL 函数名只能包含字母、数字、下划线
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        // 确保不以数字开头
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        return result.isEmpty ? "_unnamed" : result
    }
}
