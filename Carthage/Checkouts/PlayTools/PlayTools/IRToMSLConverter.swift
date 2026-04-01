//
//  IRToMSLConverter.swift
//  PlayTools
//
//  E-004e: LLVM IR → MSL 转换器
//  从 llvm-dis 生成的 LLVM IR 文本中提取 Metal shader 函数信息，
//  生成可通过 makeLibrary(source:) 编译的 MSL 源码。
//
//  完成阶段：
//  - E-004e1: 基础骨架 + stub MSL 生成 ✅
//  - E-004e2: addrspace → MSL 地址空间限定符完整映射 ✅
//    · 扩展 AddressSpace 枚举覆盖 Metal 2+ 地址空间 (0-6)
//    · 从 IR 参数中精确提取指针指向的元素类型 (opaque ptr / typed ptr)
//    · 生成正确的 MSL 参数声明 (地址空间 + 精确元素类型 + 属性标注)
//    · 支持 const/non-const 推断 (constant → const device)
//    · 区分 buffer/threadgroup/stage_in 等不同 attribute 类型
//
//  后续阶段将逐步提升转换保真度：
//  - E-004e3: air.* 内建 → MSL 等效调用
//  - E-004e4: 完整函数体转换
//

import Foundation

// MARK: - IRToMSLConverter

/// 将 LLVM IR 文本转换为可编译的 MSL (Metal Shading Language) 源码。
///
/// Metal 编译器（metal -c）将 MSL 编译为 AIR (Apple Intermediate Representation)，
/// 它是 LLVM IR 的一个 Metal 特化方言。llvm-dis 将 AIR 反汇编回标准 LLVM IR 文本格式。
/// 本转换器从 LLVM IR 文本中提取 shader 函数信息，重建可编译的 MSL 源码。
struct IRToMSLConverter {

    // MARK: - Error types

    enum ConversionError: LocalizedError {
        case emptyIR
        case noShaderFunctionsFound
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .emptyIR:
                return "Empty IR text provided"
            case .noShaderFunctionsFound:
                return "No Metal shader functions found in IR"
            case .parseError(let detail):
                return "IR parse error: \(detail)"
            }
        }
    }

    // MARK: - Parsed types

    /// Metal shader 函数的地址空间（对应 LLVM IR 中的 addrspace(N)）
    ///
    /// Metal AIR (Apple Intermediate Representation) 使用 LLVM 地址空间标注：
    /// - addrspace(0): thread — 线程私有内存（默认）
    /// - addrspace(1): device — 设备内存，可读写
    /// - addrspace(2): constant — 常量内存，只读（硬件优化路径）
    /// - addrspace(3): threadgroup — 线程组共享内存
    /// - addrspace(4): threadgroup_imageblock — Metal 2+ imageblock 内存
    /// - addrspace(5): ray_data — Metal raytracing intersection 数据
    /// - addrspace(6): object_data — Metal mesh shader object 数据
    enum AddressSpace: Int {
        case thread = 0              // addrspace(0) → thread (default, no qualifier)
        case device = 1              // addrspace(1) → device
        case constant = 2            // addrspace(2) → constant
        case threadgroup = 3         // addrspace(3) → threadgroup
        case threadgroupImageblock = 4  // addrspace(4) → threadgroup_imageblock
        case rayData = 5             // addrspace(5) → ray_data
        case objectData = 6          // addrspace(6) → object_data

        /// MSL 地址空间限定符
        var mslQualifier: String {
            switch self {
            case .thread: return ""
            case .device: return "device"
            case .constant: return "constant"
            case .threadgroup: return "threadgroup"
            case .threadgroupImageblock: return "threadgroup_imageblock"
            case .rayData: return "ray_data"
            case .objectData: return "object_data"
            }
        }

        /// 该地址空间是否表示需要 [[buffer(N)]] 标注的参数
        var isBufferAddressSpace: Bool {
            switch self {
            case .device, .constant: return true
            default: return false
            }
        }

        /// 该地址空间是否表示只读（constant 地址空间在 MSL 中是只读的）
        var isReadOnly: Bool {
            return self == .constant
        }

        /// 该地址空间是否需要 [[threadgroup(N)]] 标注
        var isThreadgroupAddressSpace: Bool {
            return self == .threadgroup
        }
    }

    /// 从 IR 参数中解析出的指针信息
    struct PointerInfo {
        /// 地址空间
        let addressSpace: AddressSpace
        /// 指针指向的元素类型（MSL 类型字符串）
        /// 对于 opaque pointer (`ptr addrspace(N)`)，需要从上下文推断
        let pointedMSLType: String
        /// 是否为 opaque pointer（LLVM 15+ 默认使用 opaque pointer）
        let isOpaquePointer: Bool
    }

    /// Metal shader 函数类型
    enum ShaderType: String {
        case vertex
        case fragment
        case kernel

        /// 从 IR 函数属性中推断 shader 类型
        static func fromIRAttributes(_ attributes: String) -> ShaderType? {
            // Metal shader functions are annotated in IR metadata
            // "air.vertex" / "air.fragment" / "air.kernel"
            if attributes.contains("vertex") { return .vertex }
            if attributes.contains("fragment") { return .fragment }
            if attributes.contains("kernel") { return .kernel }
            return nil
        }
    }

    /// 从 IR 中解析出的 shader 函数参数
    struct ParsedParameter {
        let name: String
        let irType: String
        let addressSpace: AddressSpace?
        /// buffer 绑定索引（如果有 [[buffer(N)]]）
        let bufferIndex: Int?
        /// 属性标注（如 [[stage_in]], [[position]] 等）
        let attribute: String?
        /// 指针信息（如果参数是指针类型）
        let pointerInfo: PointerInfo?

        /// 生成该参数的 MSL 声明字符串
        var mslDeclaration: String? {
            // 有指针信息时生成精确声明
            if let ptr = pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { return nil }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = bufferIndex ?? 0
                    return "\(constPrefix)\(qualifier) \(elemType)* \(name) [[buffer(\(idx))]]"
                } else if ptr.addressSpace.isThreadgroupAddressSpace {
                    let idx = bufferIndex ?? 0
                    return "threadgroup \(elemType)* \(name) [[threadgroup(\(idx))]]"
                } else {
                    return "\(qualifier) \(elemType)* \(name)"
                }
            }

            // 非指针参数
            if let attr = attribute {
                let mslType = IRToMSLConverter.irScalarTypeToMSL(irType)
                return "\(mslType) \(name) \(attr)"
            }

            return nil
        }
    }

    /// 从 IR 中解析出的 shader 函数
    struct ParsedShaderFunction {
        let name: String
        let shaderType: ShaderType
        let returnType: String
        let parameters: [ParsedParameter]
        /// 从 IR metadata 中提取的原始函数签名
        let irSignature: String
        /// 是否成功解析了完整签名
        let isFullyParsed: Bool
    }

    /// 转换结果
    struct ConversionResult {
        /// 生成的 MSL 源码
        let mslSource: String
        /// 解析出的 shader 函数列表
        let functions: [ParsedShaderFunction]
        /// 转换耗时（秒）
        let elapsedSeconds: Double
        /// 转换统计
        let stats: ConversionStats

        var summary: String {
            "functions=\(functions.count), " +
            "mslSize=\(mslSource.utf8.count), " +
            "elapsed=\(String(format: "%.3f", elapsedSeconds))s, " +
            "\(stats.summary)"
        }
    }

    /// 转换统计
    struct ConversionStats {
        var totalIRFunctions: Int = 0
        var shaderFunctions: Int = 0
        var fullyParsedFunctions: Int = 0
        var stubFunctions: Int = 0

        var summary: String {
            "irFuncs=\(totalIRFunctions), " +
            "shaders=\(shaderFunctions), " +
            "parsed=\(fullyParsedFunctions), " +
            "stubs=\(stubFunctions)"
        }
    }

    // MARK: - Public API

    /// 将 LLVM IR 文本转换为 MSL 源码。
    ///
    /// - Parameters:
    ///   - irText: llvm-dis 生成的 LLVM IR 文本
    ///   - functionNames: 原始 metallib 中的函数名列表（从 MetallibParser 获取）
    ///   - functionTypes: 函数类型列表（vertex/fragment/kernel，与 functionNames 对应）
    /// - Returns: 转换结果
    /// - Throws: `ConversionError`
    static func convert(
        irText: String,
        functionNames: [String] = [],
        functionTypes: [String] = []
    ) throws -> ConversionResult {
        guard !irText.isEmpty else {
            throw ConversionError.emptyIR
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 解析 IR 中的函数定义
        let (irFunctions, totalCount) = parseIRFunctions(irText)

        // 2. 结合 metallib 函数信息，识别 shader 函数
        let shaderFunctions = identifyShaderFunctions(
            irFunctions: irFunctions,
            metallibNames: functionNames,
            metallibTypes: functionTypes
        )

        // 3. 生成 MSL 源码
        let mslSource = generateMSL(functions: shaderFunctions)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        var stats = ConversionStats()
        stats.totalIRFunctions = totalCount
        stats.shaderFunctions = shaderFunctions.count
        stats.fullyParsedFunctions = shaderFunctions.filter { $0.isFullyParsed }.count
        stats.stubFunctions = shaderFunctions.filter { !$0.isFullyParsed }.count

        return ConversionResult(
            mslSource: mslSource,
            functions: shaderFunctions,
            elapsedSeconds: elapsed,
            stats: stats
        )
    }

    /// 安全地转换 IR 到 MSL，失败时返回 nil 并记录日志。
    static func safeConvert(
        irText: String,
        functionNames: [String] = [],
        functionTypes: [String] = []
    ) -> ConversionResult? {
        do {
            let result = try convert(
                irText: irText,
                functionNames: functionNames,
                functionTypes: functionTypes
            )
            NSLog("[PlayTools] IRToMSLConverter: success — %@", result.summary)
            return result
        } catch {
            NSLog("[PlayTools] IRToMSLConverter: failed — %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - IR Parsing

    /// 从 IR 文本中匹配的函数定义信息
    private struct IRFunctionDef {
        let name: String
        let returnType: String
        let parameterList: String
        let attributes: String
        let fullDefinition: String
    }

    /// 解析 IR 文本中的所有函数定义。
    /// 返回 (解析的函数列表, 总函数定义数)
    private static func parseIRFunctions(_ irText: String) -> ([IRFunctionDef], Int) {
        var functions: [IRFunctionDef] = []

        // LLVM IR 函数定义格式：
        // define <return_type> @<name>(<params>) #N { ... }
        // 或 declare <return_type> @<name>(<params>)
        //
        // Metal shader 函数通常是 define，有 body
        let lines = irText.components(separatedBy: "\n")
        var totalDefines = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 匹配 define 行
            guard trimmed.hasPrefix("define ") else { continue }
            totalDefines += 1

            // 提取函数名：@"function_name" 或 @function_name
            guard let funcDef = parseDefineLine(trimmed) else { continue }
            functions.append(funcDef)
        }

        return (functions, totalDefines)
    }

    /// 解析单行 define 语句
    private static func parseDefineLine(_ line: String) -> IRFunctionDef? {
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
            fullDefinition: line
        )
    }

    /// 从 define 行的前缀中提取返回类型
    private static func extractReturnType(from prefix: String) -> String {
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
        for cc in ["spir_func ", "spir_kernel ", "cc75 ", "cc76 ", "cc77 "] {
            cleaned = cleaned.replacingOccurrences(of: cc, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shader Function Identification

    /// 结合 IR 函数定义和 metallib 元数据，识别 shader 函数并推断其类型。
    private static func identifyShaderFunctions(
        irFunctions: [IRFunctionDef],
        metallibNames: [String],
        metallibTypes: [String]
    ) -> [ParsedShaderFunction] {
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

        var shaderFunctions: [ParsedShaderFunction] = []

        for irFunc in irFunctions {
            // 跳过 LLVM 内部函数和 air 运行时函数
            if irFunc.name.hasPrefix("llvm.") { continue }

            // 判断是否是 shader 入口函数
            let shaderType: ShaderType?

            // 优先使用 metallib 元数据中的类型信息
            if let type = nameToType[irFunc.name] {
                shaderType = type
            } else if irFunc.name.contains("vertex") || irFunc.attributes.contains("vertex") {
                shaderType = .vertex
            } else if irFunc.name.contains("fragment") || irFunc.attributes.contains("fragment") {
                shaderType = .fragment
            } else if irFunc.name.contains("kernel") || irFunc.attributes.contains("kernel") {
                shaderType = .kernel
            } else if metallibNames.contains(irFunc.name) {
                // 名字在 metallib 中但无法确定类型，默认 vertex
                shaderType = .vertex
            } else if irFunc.name.hasPrefix("air.") {
                // air.* 是运行时内建，不是用户 shader
                continue
            } else {
                // 不在 metallib 名字列表中的内部辅助函数，跳过
                if !metallibNames.isEmpty { continue }
                // 如果没有 metallib 信息，尝试启发式判断
                shaderType = inferShaderType(from: irFunc)
            }

            guard let type = shaderType else { continue }

            // 解析参数
            let params = parseParameters(irFunc.parameterList, shaderType: type)

            // 推断 MSL 返回类型
            let mslReturnType = irTypeToMSL(irFunc.returnType, forShaderType: type)

            shaderFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: type,
                returnType: mslReturnType,
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: false // 当前阶段均为 stub
            ))
        }

        // 如果 IR 中没找到匹配的函数，为 metallib 中的每个函数生成 stub
        if shaderFunctions.isEmpty && !metallibNames.isEmpty {
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

                shaderFunctions.append(ParsedShaderFunction(
                    name: name,
                    shaderType: type,
                    returnType: defaultReturnType(for: type),
                    parameters: [],
                    irSignature: "(metallib-only, no IR match)",
                    isFullyParsed: false
                ))
            }
        }

        return shaderFunctions
    }

    /// 从 IR 函数特征启发式推断 shader 类型
    private static func inferShaderType(from irFunc: IRFunctionDef) -> ShaderType? {
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
    private static func parseParameters(
        _ paramList: String,
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        guard !paramList.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let rawParams = splitIRParameters(paramList)
        var params: [ParsedParameter] = []
        var bufferIdx = 0
        var threadgroupIdx = 0

        for (index, rawParam) in rawParams.enumerated() {
            let trimmed = rawParam.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "..." { continue }

            // 提取地址空间
            let addrSpace = extractAddressSpace(from: trimmed)

            // 提取参数名（%name 或 %N）
            let paramName = extractParamName(from: trimmed) ?? "param\(index)"

            // 提取指针信息
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)

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
                irType: trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                pointerInfo: ptrInfo
            ))
        }

        return params
    }

    /// 将 IR 参数列表按逗号分割，但保持尖括号嵌套（如 <4 x float>）
    private static func splitIRParameters(_ paramList: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0

        for char in paramList {
            if char == "<" || char == "{" || char == "(" { depth += 1 }
            else if char == ">" || char == "}" || char == ")" { depth -= 1 }

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
    private static func extractAddressSpace(from irType: String) -> AddressSpace? {
        guard let range = irType.range(of: "addrspace(") else { return nil }
        let afterParen = irType[range.upperBound...]
        guard let closeParen = afterParen.firstIndex(of: ")") else { return nil }
        let numStr = String(afterParen[afterParen.startIndex..<closeParen])
        guard let num = Int(numStr) else { return nil }
        return AddressSpace(rawValue: num)
    }

    /// 从 IR 参数字符串中提取完整的指针信息（地址空间 + 指向的元素类型）。
    ///
    /// Metal LLVM IR 中指针参数的常见形式：
    /// 1. Opaque pointer (LLVM 15+): `ptr addrspace(1) %buf`
    /// 2. Typed pointer (旧式): `float addrspace(1)* %buf`, `<4 x float> addrspace(1)* %buf`
    /// 3. 结构体指针: `%struct.MyStruct addrspace(1)* %buf`
    private static func extractPointerInfo(
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
    private static func extractPointedType(from irParam: String) -> String? {
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
    private static func inferDefaultElementType(for space: AddressSpace) -> String {
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
    /// 处理 IR 中出现的所有基本类型：
    /// - 整数: i1→bool, i8→char/uint8_t, i16→short, i32→int, i64→long
    /// - 浮点: half, float, double
    /// - 向量: <4 x float>→float4, <2 x i32>→int2
    /// - 结构体名: %struct.X→X
    static func irScalarTypeToMSL(_ irType: String) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

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
                let elemType = irScalarTypeToMSL(
                    parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                )
                return "\(elemType)\(count)"
            }
        }

        // 结构体名: %struct.VertexIn → VertexIn, %"class::Name" → class_Name
        if cleaned.hasPrefix("%struct.") {
            let structName = String(cleaned.dropFirst("%struct.".count))
            return sanitizeTypeName(structName)
        }
        if cleaned.hasPrefix("%") {
            let typeName = String(cleaned.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeTypeName(typeName)
        }

        // 指针类型 → void* 等效
        if cleaned.contains("*") || cleaned == "ptr" {
            return "uint8_t"
        }

        return cleaned.isEmpty ? "uint8_t" : cleaned
    }

    /// 将类型名清理为合法的 MSL 标识符
    private static func sanitizeTypeName(_ name: String) -> String {
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        return result.isEmpty ? "UnknownType" : result
    }

    /// 从 IR 参数字符串中提取参数名
    private static func extractParamName(from irParam: String) -> String? {
        // 参数名格式: %name 或 %0, %1 等
        guard let percentIndex = irParam.lastIndex(of: "%") else { return nil }
        let afterPercent = irParam[irParam.index(after: percentIndex)...]
        let name = afterPercent.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - IR Type → MSL Type Mapping

    /// 将 IR 返回类型转换为 MSL 类型
    private static func irTypeToMSL(_ irType: String, forShaderType shaderType: ShaderType) -> String {
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

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.contains(" x ") {
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

        // 结构体类型 → 使用默认
        if cleaned.hasPrefix("{") || cleaned.hasPrefix("%struct") {
            return defaultReturnType(for: shaderType)
        }

        // 指针类型
        if cleaned.contains("ptr") || cleaned.contains("*") {
            return defaultReturnType(for: shaderType)
        }

        return defaultReturnType(for: shaderType)
    }

    /// Shader 类型的默认返回类型
    private static func defaultReturnType(for shaderType: ShaderType) -> String {
        switch shaderType {
        case .vertex: return "float4"
        case .fragment: return "float4"
        case .kernel: return "void"
        }
    }

    // MARK: - MSL Generation

    /// 生成完整的 MSL 源码
    private static func generateMSL(functions: [ParsedShaderFunction]) -> String {
        var lines: [String] = []

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

        if functions.isEmpty {
            lines.append("// No shader functions found in IR")
            return lines.joined(separator: "\n")
        }

        // 用于去重
        var emittedNames: Set<String> = []

        for (index, func_) in functions.enumerated() {
            // MSL 不允许重复的函数名
            let safeName = sanitizeFunctionName(func_.name)
            if emittedNames.contains(safeName) { continue }
            emittedNames.insert(safeName)

            lines.append("// [\(index)] \(func_.shaderType.rawValue): \(func_.name)")
            if !func_.isFullyParsed {
                lines.append("// (stub — IR signature not fully converted)")
                lines.append("// IR: \(func_.irSignature.prefix(200))")
            }

            // 生成函数
            let funcCode = generateFunction(func_, safeName: safeName)
            lines.append(funcCode)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// 生成单个 shader 函数的 MSL 代码
    private static func generateFunction(
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
        }
    }

    /// 生成 vertex shader stub
    private static func generateVertexFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let bufferParams = generateBufferParams(func_.parameters)
        let paramStr: String
        if bufferParams.isEmpty {
            paramStr = "uint vid [[vertex_id]]"
        } else {
            paramStr = "uint vid [[vertex_id]], \(bufferParams)"
        }

        return """
        vertex \(func_.returnType) \(safeName)(\(paramStr)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 fragment shader stub
    private static func generateFragmentFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let bufferParams = generateBufferParams(func_.parameters)
        let paramStr: String
        if bufferParams.isEmpty {
            paramStr = "float4 position [[position]]"
        } else {
            paramStr = "float4 position [[position]], \(bufferParams)"
        }

        return """
        fragment \(func_.returnType) \(safeName)(\(paramStr)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 kernel (compute) shader stub
    private static func generateKernelFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let bufferParams = generateBufferParams(func_.parameters)
        let paramStr: String
        if bufferParams.isEmpty {
            paramStr = "uint tid [[thread_position_in_grid]]"
        } else {
            paramStr = "uint tid [[thread_position_in_grid]], \(bufferParams)"
        }

        return """
        kernel void \(safeName)(\(paramStr)) {
            // stub kernel
        }
        """
    }

    /// 为 buffer/threadgroup 参数生成 MSL 参数列表。
    ///
    /// 根据参数的地址空间生成正确的 MSL 声明：
    /// - device (addrspace 1) → `device T* name [[buffer(N)]]`
    /// - constant (addrspace 2) → `const constant T* name [[buffer(N)]]` （注意 constant 隐含只读）
    /// - threadgroup (addrspace 3) → `threadgroup T* name [[threadgroup(N)]]`
    /// - 其他地址空间 → 使用对应的 MSL 限定符
    private static func generateBufferParams(_ params: [ParsedParameter]) -> String {
        var mslParams: [String] = []

        for param in params {
            // 优先使用 ParsedParameter 自身的 mslDeclaration
            if let decl = param.mslDeclaration {
                mslParams.append(decl)
                continue
            }

            // 回退：如果有地址空间但没有指针信息，使用旧逻辑
            guard let addrSpace = param.addressSpace else { continue }
            let qualifier = addrSpace.mslQualifier
            if qualifier.isEmpty { continue }

            let idx = param.bufferIndex ?? 0
            let constPrefix = addrSpace.isReadOnly ? "const " : ""

            if addrSpace.isBufferAddressSpace {
                mslParams.append("\(constPrefix)\(qualifier) uint8_t* \(param.name) [[buffer(\(idx))]]")
            } else if addrSpace.isThreadgroupAddressSpace {
                mslParams.append("threadgroup uint8_t* \(param.name) [[threadgroup(\(idx))]]")
            } else {
                mslParams.append("\(qualifier) uint8_t* \(param.name)")
            }
        }

        return mslParams.joined(separator: ", ")
    }

    /// 生成给定类型的默认返回值
    private static func defaultReturnValue(for mslType: String) -> String {
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
    private static func sanitizeFunctionName(_ name: String) -> String {
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
